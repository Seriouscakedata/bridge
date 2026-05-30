# Monitoring Runbook — инструкция для Codex (и любого агента-монитора)

> Codex, это твой runbook для мониторинга, диагностики и восстановления моста на этой машине.
> Ты — отдельное desktop-приложение с полным доступом к PowerShell и файлам (НЕ в песочнице моста).
> Действуй так же, как это делал Claude: проверяй здоровье → находи проблему → лечи корень → проверяй результат.
> Машина: Windows, PowerShell 5.1. Корень моста: `C:\Users\rafie\OneDrive\Documents\bridge`.
> Дополнение к этому файлу — `DEVELOPER_GUIDE.md` (архитектура и механизмы). Прочти его тоже.

---

## 0. КАК ПОЛЬЗОВАТЬСЯ

1. Сначала прочти **§1 (правила безопасности)** — там грабли, на которые легко наступить.
2. Запусти **§2 (health check)** — одна команда даёт полную картину.
3. Сверься с **§3 (норма/тревога)**.
4. Если есть проблема — иди в **§4 (диагностика по симптому)**, потом **§5 (восстановление)**.
5. Все команды — copy-paste ready. Везде вначале задаётся `$src` — путь к мосту.

Во всех сниппетах:
```powershell
$src = 'C:\Users\rafie\OneDrive\Documents\bridge'
```

---

## 1. КРИТИЧЕСКИЕ ПРАВИЛА БЕЗОПАСНОСТИ (читай ПЕРВЫМ)

Эти ошибки реально случались — не повторяй их.

1. **НИКОГДА не делай `. driver.ps1` (dot-source).** `driver.ps1` имеет top-level код, который **запустит главный loop прямо в твоём процессе** и повиснет/начнёт второй драйвер. Чтобы проверить загрузку — используй `ParseFile` или `-SelfTest` (см. §6). То же касается `server.ps1`, `supervisor.ps1`.

2. **НЕ запускай вложенный скрытый PowerShell с Bypass.** Конструкция вида
   `powershell -Command "... Start-Process powershell -WindowStyle Hidden -ExecutionPolicy Bypass ..."`
   — сигнатура malware, **Windows Defender её блокирует** → ошибка `EPERM: uv_spawn`. Запускай команды напрямую (`powershell -File ...` или просто свои команды), без вложенного скрытого спавна.

3. **НЕ запускай `schtasks /change` и другие UAC-операции в фоне.** Они **зависнут** на UAC-промпте, на который некому ответить (висело 911 минут). `schtasks /run` и `/end` — безопасны (UAC не требуют).

4. **Перед `Stop-Process` ВСЕГДА проверь, что это не критичный процесс.** Не убивай:
   - `supervisor.ps1` / `watchdog.ps1` — это защита моста (только при осознанном recovery, §5);
   - чужой `codex.exe` (твой собственный desktop Codex!) или `claude.exe` пользователя;
   - проверяй `CommandLine` процесса перед kill (`Get-CimInstance Win32_Process`).

5. **PowerShell 5.1, не 7.** `$Mode:` парсится как drive-ref (используй `${Mode}:`), `if` не выражение (используй `$(if ...)`), нет `&&`/`||`/`?:`/`??`. Переменные регистронезависимы.

6. **Не плоди рестарты.** Каждый ручной рестарт приближает circuit-breaker storm (5 рестартов/30мин → cooldown). Один контролируемый рестарт за раз, и только когда канал idle.

---

## 2. БЫСТРАЯ ПРОВЕРКА ЗДОРОВЬЯ (health check)

Запусти это первым — одна команда, полная картина:

```powershell
$src = 'C:\Users\rafie\OneDrive\Documents\bridge'
Write-Output ("=== NOW: " + (Get-Date -Format 'HH:mm:ss') + " ===")

# 1. Процессы моста
$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -EA SilentlyContinue |
  Where-Object { $_.CommandLine -match 'supervisor\.ps1|server\.ps1|driver\.ps1|watchdog\.ps1' })
foreach ($p in $procs) {
  $role = if ($p.CommandLine -match 'supervisor') {'supervisor'}
          elseif ($p.CommandLine -match 'server') {'server'}
          elseif ($p.CommandLine -match 'driver.*main') {'driver-main'}
          elseif ($p.CommandLine -match 'driver.*travel') {'driver-travel'}
          elseif ($p.CommandLine -match 'watchdog') {'watchdog'} else {'?'}
  $pr = Get-Process -Id $p.ProcessId -EA SilentlyContinue
  Write-Output ("  " + $role.PadRight(13) + " PID=" + $p.ProcessId + " started=" + $(if($pr){$pr.StartTime.ToString('HH:mm:ss')}else{'?'}))
}
Write-Output ("  -> core count: " + $procs.Count + " (ждём ~5: supervisor+server+driver-main+driver-travel+watchdog)")

# 2. API (401 = ЖИВ, это норма; отказ соединения = МЁРТВ)
try { $r = Invoke-WebRequest 'http://127.0.0.1:8787/api/status' -UseBasicParsing -TimeoutSec 6
      Write-Output ("  API: HTTP " + $r.StatusCode + " ALIVE") }
catch { $m = $_.Exception.Message
        Write-Output ("  API: " + $(if ($m -match '401') {'401 ALIVE (норма)'} elseif ($m -match 'connect|refused|соедин') {'DOWN — сервер не слушает'} else {$m})) }

# 3. Рестарты (окно circuit-breaker = 5/30мин)
$rj = Join-Path $env:USERPROFILE '.bridge-runtime\restarts.jsonl'
$all = @(Get-Content $rj -EA SilentlyContinue)
$recent = @($all | ForEach-Object { try { $o=$_|ConvertFrom-Json; if (([datetimeoffset]$o.ts).LocalDateTime -ge (Get-Date).AddMinutes(-30)) {$o} } catch {} })
Write-Output ("  restarts(30min): " + $recent.Count + "/5  " + $(if($recent.Count -ge 5){'⚠ STORM/cooldown риск'}elseif($recent.Count -ge 3){'(повышено)'}else{'OK'}))

# 4. Каналы: статус + свежесть драйвера
foreach ($ch in @('main','travel')) {
  $sf = Join-Path $src ("channels\" + $ch + "\state.json")
  if (Test-Path $sf) {
    $age = [int]((Get-Date) - (Get-Item $sf).LastWriteTime).TotalSeconds
    try { $s = [IO.File]::ReadAllText($sf) | ConvertFrom-Json
          Write-Output ("  " + $ch + "=" + $s.status + " (state " + $age + "s old, driver " + $(if($age -lt 20){'ALIVE'}else{'STALE ⚠'}) + ")") }
    catch { Write-Output ("  " + $ch + ": STATE CORRUPT ⚠ — " + $_.Exception.Message) }
  }
}
```

---

## 3. ЧТО НОРМАЛЬНО, ЧТО ТРЕВОЖНО

| Наблюдение | Норма? | Комментарий |
|---|---|---|
| API отдаёт **401** без токена | ✅ норма | 401 = сервер жив, требует токен. Это НЕ ошибка. |
| 5 core-процессов (supervisor/server/2×driver/watchdog) | ✅ норма | Меньше — компонент упал. |
| Процессы с пустым `CommandLine`, start совпадает | ✅ норма | Часто session 0 (elevated через Task Scheduler) — CommandLine скрыт. |
| `state.json` свежеет каждые <15с | ✅ норма | Драйвер жив и крутит loop. |
| `restarts(30min)` = 0–2 | ✅ норма | Спокойно. |
| `restarts(30min)` ≥ 5 | ⚠ тревога | Circuit-breaker уйдёт/ушёл в cooldown → §4.2/§4.3. |
| API «DOWN — не слушает», но supervisor жив | ⚠ тревога | Возможен circuit-breaker deadlock → §4.3. |
| `state.json` старше 60с | ⚠ тревога | Драйвер завис/умер. |
| `state.json` не парсится | ⚠ тревога | Порча state (OneDrive шторм). Server должен пересоздать; если нет — §5. |
| Сообщение «git add/commit заблокирован ACL» | ✅ норма | Песочница кодера by-design; driver докоммитит сам (см. DEVELOPER_GUIDE §4.4). |
| Сообщение «Codex занят другим каналом» (часто) | ⚠ мелочь | Конкуренция каналов за Codex → §4.6. |
| Сообщение «🔍 Аудит запущен / ✅ Аудит завершён» | ✅ норма | Аудит работает и виден в чате. |

---

## 4. ДИАГНОСТИКА ПО СИМПТОМАМ

### 4.1 Мост не отвечает / частично мёртв
Симптом: API DOWN, мало процессов.
```powershell
$src='C:\Users\rafie\OneDrive\Documents\bridge'
# что живо?
@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? {$_.CommandLine -match 'supervisor|server|driver|watchdog'}) |
  % { $r=if($_.CommandLine -match 'supervisor'){'supervisor'}elseif($_.CommandLine -match 'server'){'server'}elseif($_.CommandLine -match 'driver'){'driver'}elseif($_.CommandLine -match 'watchdog'){'watchdog'}else{'?'}; "$r PID=$($_.ProcessId)" }
# config валиден? (битый config роняет server/driver на старте)
try { [IO.File]::ReadAllText("$src\config.json")|ConvertFrom-Json|Out-Null; 'config.json OK' } catch { 'config.json INVALID: ' + $_.Exception.Message }
```
Если только supervisor+watchdog живы, а server/driver нет → §4.3 (deadlock) или §5 (recovery).

### 4.2 Recycle-storm (частые рестарты)
```powershell
$rj = Join-Path $env:USERPROFILE '.bridge-runtime\restarts.jsonl'
@(Get-Content $rj -EA SilentlyContinue | Select-Object -Last 10) | % { try { $o=$_|ConvertFrom-Json; ([datetimeoffset]$o.ts).LocalDateTime.ToString('HH:mm:ss') + ' ' + $o.cause + ' | ' + $o.detail } catch {} }
```
Смотри на `cause`:
- `explicit-flag` = кто-то/что-то ставит `restart.flag` (правки .ps1 или ручные рестарты);
- `task-survived-3x` = задача пережила 3 рестарта (застряла) → §4.4;
- `state-corrupt` / `parse-fail` = порча state / битый .ps1.
Лечение: не плодить рестарты; если задача застряла — §4.4; если ≥5/30мин — §4.3 + §5.

### 4.3 Circuit-breaker (cooldown / бывший deadlock)
Окно: 5 рестартов / 30 мин → cooldown 15 мин. Проверь probe (выход из cooldown):
```powershell
$src='C:\Users\rafie\OneDrive\Documents\bridge'
$env:BRIDGE_CHANNEL='main'; . (Join-Path $src 'lib\common.ps1') | Out-Null
. (Join-Path $src 'lib\circuit-breaker.ps1') | Out-Null   # circuit-breaker.ps1 — библиотека, dot-source безопасен (в отличие от driver.ps1!)
$p = Invoke-HealthProbe; "probe green=$($p.green) reason=$($p.reason)"
```
- `green=True` → cooldown отпустит, мост поднимется (после фикса 2026-05-30 порча state НЕ блокирует — это лишь warning).
- `green=False` с `parse-fail` → есть битый core-файл (`driver/server/supervisor/watchdog/lib/tools`). Найди и почини:
```powershell
$src='C:\Users\rafie\OneDrive\Documents\bridge'
$bad=@(); foreach($f in (@(Get-ChildItem $src -Filter *.ps1 -File) + @(Get-ChildItem "$src\lib" -Filter *.ps1) + @(Get-ChildItem "$src\tools" -Filter *.ps1))){ $e=$null;$t=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$t,[ref]$e); if($e -and $e.Count){ $bad += $f.FullName } }
if($bad){ "BROKEN: " + ($bad -join ', ') } else { "all core .ps1 parse OK" }
```
Если probe красный из-за реального битого файла — почини файл, потом §5. Failsafe: после 3 продлений cooldown мост поднимется принудительно сам + напишет тебе в чат.

### 4.4 Застрявшая задача (`task-survived-3x`)
```powershell
$src='C:\Users\rafie\OneDrive\Documents\bridge'
$s=[IO.File]::ReadAllText("$src\channels\main\state.json")|ConvertFrom-Json
"status=$($s.status) claimed_at=$($s.claimed_at) task=$([string]$s.task) active_jobs=$(@($s.active_jobs).Count)"
```
Если `claimed_at` давний, `status=working`, но прогресса нет — задача застряла. Сбрось состояние (§5, шаг reset state).

### 4.5 Порча state.json
Server пересоздаёт state при старте. Если не помогает — сбрось вручную (§5). Корень — OneDrive sync во время шторма; долгосрочно вынести runtime из OneDrive.

### 4.6 Codex mutex «занят другим каналом»
```powershell
$src='C:\Users\rafie\OneDrive\Documents\bridge'
$lock="$src\runtime\codex.lock"
if(Test-Path $lock){ $c=(Get-Content $lock -Raw).Trim(); $lpid=($c -split '\|')[0]; $alive=[bool](Get-Process -Id $lpid -EA SilentlyContinue); "codex.lock держит PID=$lpid alive=$alive (age $([int]((Get-Date)-(Get-Item $lock).LastWriteTime).TotalSeconds)s)" } else { "codex.lock свободен" }
```
- Lock с **живым** PID < 920с → реально работает другой канал. Норма (сериализация).
- Lock с **мёртвым** PID → stale, мост сам заберёт; если нет — удали `runtime\codex.lock`.
- Часто появляется → оба канала автономны. Выключи автономию travel: в UI 🚫 у канала, или в `settings.json` добавь `"autonomyDisabledChannels": ["travel"]`.

### 4.7 Zombie-процессы / лишние supervisor
Два supervisor = конфликт. Проверь дерево:
```powershell
$all=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? {$_.CommandLine -match 'supervisor\.ps1|server\.ps1|driver\.ps1'})
$sups=@($all|?{$_.CommandLine -match 'supervisor'}); $kids=@($all|?{$_.CommandLine -match 'server\.ps1|driver\.ps1'})
foreach($s in $sups){ $c=@($kids|?{$_.ParentProcessId -eq $s.ProcessId}).Count; "supervisor PID=$($s.ProcessId) -> $c детей" }
```
Оставь supervisor с детьми, лишний (0 детей) — `Stop-Process` (предварительно убедись, что это точно дубль).

---

## 5. ВОССТАНОВЛЕНИЕ (recovery) — полный чистый рестарт

Применяй, когда мост в deadlock / storm / завис. Делай **только при необходимости** и по шагам:

```powershell
$src = 'C:\Users\rafie\OneDrive\Documents\bridge'

# 1. найди и убей supervisor (НЕ watchdog!)
@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? {$_.CommandLine -match 'supervisor\.ps1'}) | % { Stop-Process -Id $_.ProcessId -Force; "killed supervisor $($_.ProcessId)" }

# 2. убей повисшие server/driver (watchdog НЕ трогаем)
@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? {$_.CommandLine -match 'server\.ps1|driver\.ps1'}) | % { try{Stop-Process -Id $_.ProcessId -Force}catch{} }

# 3. сбрось окно circuit-breaker и флаги рестарта
Clear-Content "$env:USERPROFILE\.bridge-runtime\restarts.jsonl" -EA SilentlyContinue
foreach($f in @('control\restart.flag','control\restart.deferred','runtime\codex.lock')){ $p=Join-Path $src $f; if(Test-Path $p){ Remove-Item $p -Force -EA SilentlyContinue } }
$ext="$env:USERPROFILE\.bridge-runtime\cb-cooldown-extensions"; if(Test-Path $ext){ Remove-Item $ext -Force -EA SilentlyContinue }

# 4. (если state повреждён) сбрось застрявшее состояние каналов
$u8=New-Object System.Text.UTF8Encoding($false)
foreach($ch in @('main','travel')){ $sf=Join-Path $src "channels\$ch\state.json"; if(Test-Path $sf){ try{ $s=[IO.File]::ReadAllText($sf)|ConvertFrom-Json; $s.status='idle'; foreach($k in @('claimed_at','task','abort','phase')){ if($s.PSObject.Properties.Name -contains $k){ $s.$k=$null } }; [IO.File]::WriteAllText($sf,($s|ConvertTo-Json -Depth 10),$u8); "reset $ch" }catch{} } }

# 5. подними мост через autostart-задачу (НЕ через скрытый powershell — Defender!)
schtasks /end /tn "ClaudeCodexBridge" 2>$null
Start-Sleep -Seconds 2
schtasks /run /tn "ClaudeCodexBridge"

# 6. подожди ~35с и проверь (повтори health check из §2)
Start-Sleep -Seconds 35
try { (Invoke-WebRequest 'http://127.0.0.1:8787/api/status' -UseBasicParsing -TimeoutSec 8).StatusCode } catch { if($_.Exception.Message -match '401'){'401 ALIVE OK'}else{'DOWN'} }
"restarts after recovery: " + @(Get-Content "$env:USERPROFILE\.bridge-runtime\restarts.jsonl" -EA SilentlyContinue).Count
```
После recovery подожди 45–60с и убедись: API жив, `restarts.jsonl` НЕ растёт (иначе server крашится на старте — проверь §4.3 на parse-fail), `state.json` свежеет.

---

## 6. КАК БЕЗОПАСНО ПРОВЕРИТЬ КОД (без запуска loop)

Никогда не `. driver.ps1`. Вместо этого:
```powershell
$src='C:\Users\rafie\OneDrive\Documents\bridge'
# синтаксис (любой .ps1)
$e=$null;$t=$null; [void][System.Management.Automation.Language.Parser]::ParseFile("$src\driver.ps1",[ref]$t,[ref]$e); "ParseFile errors: $($e.Count)"
# загрузочный self-test драйвера (выходит до loop, ловит load-time ошибки)
powershell -NoProfile -ExecutionPolicy Bypass -File "$src\driver.ps1" -Channel main -SelfTest
# ждём exit 0 + "DRIVER SELFTEST OK"
```
`lib/*.ps1` и `tools/*.ps1` (кроме исполняемых скриптов вроде `deep-audit.ps1`, у которого есть top-level запуск) — это библиотеки, их dot-source безопасен. Если сомневаешься — только ParseFile.

---

## 7. ЧТЕНИЕ ЧАТА И СОБЫТИЙ МОСТА

Что мост сейчас делает и какие проблемы пишет:
```powershell
$src='C:\Users\rafie\OneDrive\Documents\bridge'
$env:BRIDGE_CHANNEL='main'; . (Join-Path $src 'lib\common.ps1') | Out-Null
$conv = Get-ConversationPath
Get-Content $conv -Tail 15 -EA SilentlyContinue | % { try { $o=$_|ConvertFrom-Json; $t=([string]$o.text -replace '\s+',' ').Trim(); if($t.Length-gt120){$t=$t.Substring(0,120)}; "[$($o.from)/$($o.kind)] $t" } catch {} }
```
(`common.ps1` dot-source безопасен — это библиотека.)

Аудит-результаты:
```powershell
$src='C:\Users\rafie\OneDrive\Documents\bridge'
Get-Content "$src\audit\audit.log" -Tail 5 -EA SilentlyContinue
"ledger entries: " + @(Get-Content "$src\audit\findings-ledger.jsonl" -EA SilentlyContinue).Count
Get-Content "$src\audit\usefulness.jsonl" -Tail 1 -EA SilentlyContinue
```

---

## 8. РЕГУЛЯРНЫЙ МОНИТОРИНГ (что проверять периодически)

- **Каждые ~10–15 мин (или по запросу пользователя):** health check (§2). Особое внимание на `restarts(30min)` и свежесть `state.json`.
- **При жалобе пользователя «мост тормозит/висит/умер»:** §2 → §4 по симптому → §5 при необходимости.
- **После любого рестарта:** убедись, что `restarts.jsonl` не растёт (нет crash-loop).
- **Раз в день:** проверь, что `jobs/` не разрастается мусором (старые `.cmd` старше 2ч можно чистить), и что аудит отрабатывает (`audit.log`, `findings-ledger.jsonl` наполняется).

Чистка мусора в `jobs/` (безопасно — это завершённые маркеры):
```powershell
$src='C:\Users\rafie\OneDrive\Documents\bridge'
@(Get-ChildItem "$src\jobs" -Filter *.cmd -EA SilentlyContinue | ? { ((Get-Date)-$_.LastWriteTime).TotalMinutes -gt 120 }) | Remove-Item -Force -EA SilentlyContinue
```

---

## 9. ГРАНИЦЫ: что делать, а что НЕ делать самому

**Можно сам (Codex):**
- Health check, чтение логов/чата/состояния, диагностика.
- Чистка `jobs/`-мусора, удаление stale `codex.lock` (мёртвый PID).
- Recovery по §5 при явном deadlock/storm.
- ParseFile / `-SelfTest` проверки.

**НЕ делай без подтверждения пользователя:**
- Правки в `supervisor.ps1` / `watchdog.ps1` / `.git` / Task Scheduler.
- `git push --force`, `reset --hard` на грязном дереве, удаление веток/каналов.
- Убийство процессов, которые не подтверждены как bridge-компоненты.
- Любые необратимые операции и решения по затратам (какие модели включать).

**Всегда:**
- Перед kill — проверь `CommandLine` (не watchdog/supervisor/твой Codex/claude пользователя).
- После правки .ps1 — ParseFile + `-SelfTest` перед применением.
- Один рестарт за раз, только при idle-канале.

---

*Если что-то не сходится с этим runbook — сверься с `DEVELOPER_GUIDE.md` и фактическим кодом (`lib/circuit-breaker.ps1`, `driver.ps1` coalescer, `supervisor.ps1`). Документ создан Claude (Opus) 2026-05-30; держи в актуальном состоянии.*
