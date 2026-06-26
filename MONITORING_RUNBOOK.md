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
          elseif ($p.CommandLine -match 'driver') {'driver:' + $(if($p.CommandLine -match '-Channel\s+(\S+)'){$matches[1]}else{'?'})}
          elseif ($p.CommandLine -match 'watchdog') {'watchdog'} else {'?'}
  $pr = Get-Process -Id $p.ProcessId -EA SilentlyContinue
  Write-Output ("  " + $role.PadRight(18) + " PID=" + $p.ProcessId + " started=" + $(if($pr){$pr.StartTime.ToString('HH:mm:ss')}else{'?'}))
}
Write-Output ("  -> core count: " + $procs.Count + " (минимум ~4: supervisor+server+watchdog+≥1 driver; по 1 driver на активный канал)")

# 2. API (401 = ЖИВ, это норма; отказ соединения = МЁРТВ)
# /api/health — ЕДИНСТВЕННЫЙ маршрут БЕЗ авторизации (отдаёт 200 + JSON uptime/heartbeat/paused),
# поэтому это самый чистый liveness-пробник. /api/status тоже годится: без токена он даёт 401 = жив.
try { $r = Invoke-WebRequest 'http://127.0.0.1:8787/api/health' -UseBasicParsing -TimeoutSec 6
      Write-Output ("  API: HTTP " + $r.StatusCode + " ALIVE (/api/health)") }
catch { $m = $_.Exception.Message
        Write-Output ("  API: " + $(if ($m -match '401') {'401 ALIVE (норма)'} elseif ($m -match 'connect|refused|соедин') {'DOWN — сервер не слушает'} else {$m})) }

# 3. Рестарты (окно circuit-breaker = 5/30мин)
$rj = Join-Path $env:USERPROFILE '.bridge-runtime\restarts.jsonl'
$all = @(Get-Content $rj -EA SilentlyContinue)
$recent = @($all | ForEach-Object { try { $o=$_|ConvertFrom-Json; if (([datetimeoffset]$o.ts).LocalDateTime -ge (Get-Date).AddMinutes(-30)) {$o} } catch {} })
Write-Output ("  restarts(30min): " + $recent.Count + "/5  " + $(if($recent.Count -ge 5){'⚠ STORM/cooldown риск'}elseif($recent.Count -ge 3){'(повышено)'}else{'OK'}))

# 4. Каналы: статус + свежесть драйвера
# ⚠ Список захардкожен — на этой машине активны и другие каналы (claude, computer-control,
#    telegram-bridge-bot). Чтобы покрыть ВСЕ — перечисли по факту:
#    Get-ChildItem "$src\channels" -Directory | ? Name -ne '_archive' | % Name
foreach ($ch in @('main','oko')) {
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
| supervisor + server + watchdog + ≥1 driver | ✅ норма | По одному driver на активный канал (до 20). Нет server/watchdog/supervisor — компонент упал. |
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
$bad=@(); foreach($f in (@(Get-ChildItem $src -Filter *.ps1 -File) + @(Get-ChildItem "$src\driver" -Filter *.ps1) + @(Get-ChildItem "$src\lib" -Filter *.ps1) + @(Get-ChildItem "$src\tools" -Filter *.ps1))){ $e=$null;$t=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$t,[ref]$e); if($e -and $e.Count){ $bad += $f.FullName } }
if($bad){ "BROKEN: " + ($bad -join ', ') } else { "all core .ps1 parse OK" }
```
Если probe красный из-за реального битого файла — почини файл, потом §5. Failsafe: после 3 продлений cooldown мост поднимется принудительно сам + напишет тебе в чат.

**Script-integrity startup-block (supervisor отказывается запускать процесс).** Перед стартом supervisor SHA256-сверяет на-диске `server.ps1` И `driver.ps1` с манифестом `security/script-integrity.json` (гейт включён: `config.json` → `supervisor.scriptIntegrityEnabled=true` + `scriptIntegrityManifest='security/script-integrity.json'`; логика — `lib/script-integrity.ps1`, функции `Test-BridgeScriptIntegrity`/`Invoke-BridgeIntegrityGuard`, вызов из `supervisor.ps1` `Start-Srv`/`Start-Drv`). Если хэш файла ≠ манифесту — guard возвращает `Ok=false`, supervisor пишет в `control/supervisor.log` строку `ERROR: integrity check failed for <file> reason=hash_mismatch expected=<H> actual=<H>` и **НЕ запускает процесс**. Симптом: server не поднят → HTTP.sys отдаёт **503 на ВСЕ маршруты** (включая `/api/health`); driver не поднят → `lastSeq`/`state.json` перестаёт двигаться. Триггерится ЛЮБАЯ правка `server.ps1`/`driver.ps1` (ручная ИЛИ авто-коммит легитимной автозадачи) БЕЗ обновления хэша в манифесте. Гвардятся ТОЛЬКО `server.ps1` + `driver.ps1`; `driver/*.ps1` и `lib/*.ps1` — нет.

Диагностика:
```powershell
$src='C:\Users\rafie\OneDrive\Documents\bridge'
Get-Content "$src\control\supervisor.log" -Tail 30 -EA SilentlyContinue | Select-String 'integrity check failed'
```
Восстановление (оператор):
1. Убедись, что файл легитимен (не подмена): `git --git-dir=C:\Users\rafie\.bridge-runtime\bridge-git --work-tree=C:\Users\rafie\OneDrive\Documents\bridge status --short server.ps1 driver.ps1` должен быть чистым / совпадать с HEAD. Песочница кодера до этих файлов не дотянется — неожиданная грязная правка = реальная тревога (подмена), НЕ обновляй манифест вслепую.
2. Пересчитай хэш: `(Get-FileHash -Algorithm SHA256 "$src\server.ps1").Hash` (uppercase hex), то же для `driver.ps1`.
3. Впиши в `security/script-integrity.json` → `files."server.ps1"` (и/или `"driver.ps1"`) новый хэш. **ОБА** entry должны совпадать с текущими на-диске файлами — устаревший «чужой» entry тоже блокирует старт.
4. Рестарт: `Stop-ScheduledTask -TaskName 'ClaudeCodexBridge'; Start-Sleep 5; Start-ScheduledTask -TaskName 'ClaudeCodexBridge'`. Проверь, что в `control/supervisor.log` нет новых `integrity check failed`.

Самопроверка гейта: `tools/supervisor_script_integrity_test.ps1`.

> **Примечание про 503 vs 401.** Раньше «API отдаёт 503 на всё» означало только «server не слушает». Теперь 503 имеет ДВЕ причины: (а) server не запущен (в т.ч. из-за integrity-block выше); (б) server жив, но `Test-Auth` (`server.ps1`) при битом/непарсящемся `auth.json` **fail-closed** отдаёт `503 Authentication unavailable (auth config error)` — deny-all (а НЕ только 401). 401 теперь означает: auth-файл есть, но креды пустые/неверные. «Открыто без токена» возможно ТОЛЬКО когда auth-файла нет вовсе. То есть 503 на `/api/health` → сначала проверь `control/supervisor.log` на integrity-block, затем валидность `auth.json`.

**System Sentinel (детектор шторма в `watchdog.ps1`).** Heartbeat-проверка ловит «мёртв vs жив», но НЕ ловит живой драйвер, который рестарт-лупит или спамит одну и ту же ошибку. Этот пробел закрывает Sentinel: детерминистический подсчёт сигнатур (одна сигнатура ≥3 раз ИЛИ ≥4 рестарта за 15 мин = шторм), затем **grace ~8 мин на самолечение** (мост часто чинит себя сам — НЕ топчи это окно), потом dispatch в Doctor (`repair.signal`), и если за 15 мин не вылечилось — rollback + пейдж оператору в чат. Артефакты: `control/sentinel.suspect`, `control/sentinel.cooldown`, `control/sentinel.incidents.jsonl`. Если видишь запись об инциденте Sentinel — мост уже сам реагирует; дай ему отработать grace-окно прежде чем вмешиваться вручную (§5).

### 4.4 Застрявшая задача (`task-survived-3x`)
```powershell
$src='C:\Users\rafie\OneDrive\Documents\bridge'
$s=[IO.File]::ReadAllText("$src\channels\main\state.json")|ConvertFrom-Json
"status=$($s.status) claimed_at=$($s.claimed_at) task=$([string]$s.current_task) active_jobs=$(@($s.active_jobs).Count)"
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
- Часто появляется → оба канала автономны. Выключи автономию лишнего канала: в UI 🚫 у канала, или в `settings.json` добавь `"autonomyDisabledChannels": ["<slug>"]` (например `["oko"]`).

### 4.7 Zombie-процессы / лишние supervisor
Два supervisor = конфликт. Проверь дерево:
```powershell
$all=@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? {$_.CommandLine -match 'supervisor\.ps1|server\.ps1|driver\.ps1'})
$sups=@($all|?{$_.CommandLine -match 'supervisor'}); $kids=@($all|?{$_.CommandLine -match 'server\.ps1|driver\.ps1'})
foreach($s in $sups){ $c=@($kids|?{$_.ParentProcessId -eq $s.ProcessId}).Count; "supervisor PID=$($s.ProcessId) -> $c детей" }
```
Оставь supervisor с детьми, лишний (0 детей) — `Stop-Process` (предварительно убедись, что это точно дубль).

### 4.8 Doctor-активация по зацикливанию (`loop_detected` / `no_progress_loop`)
Драйвер сам ловит две разновидности «топтания на месте» внутри задачи и активирует Doctor (видно в чате и `metrics.jsonl` как `doctor_event reason=...`):
- **`loop_detected`** — 3 хода подряд с одинаковым fingerprint (`git diff --stat HEAD` + текст ответа); если зацикливание повторяется уже в режиме Doctor, задача прерывается (aborted). См. `driver/85-loop-mode-transitions.ps1`.
- **`no_progress_loop`** — ≥4 ходов кодера подряд без изменений файлов (`no_progress_count`). Driver просит Codex объяснить блокер и поднимает Doctor.

Это штатная самозащита — дай Doctor отработать; вмешивайся (§4.4/§5) только если задача после этого реально застряла.

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
# ⚠ Список захардкожен и НЕ покрывает все активные каналы (claude, computer-control,
#    telegram-bridge-bot). При полном сбросе перечисли по факту через Get-ChildItem "$src\channels".
$u8=New-Object System.Text.UTF8Encoding($false)
foreach($ch in @('main','oko')){ $sf=Join-Path $src "channels\$ch\state.json"; if(Test-Path $sf){ try{ $s=[IO.File]::ReadAllText($sf)|ConvertFrom-Json; $s.status='idle'; foreach($k in @('claimed_at','current_task','current_task_id','task_turn','task_mode','abort','current_backlog_id')){ if($s.PSObject.Properties.Name -contains $k){ $s.$k=$null } }; [IO.File]::WriteAllText($sf,($s|ConvertTo-Json -Depth 10),$u8); "reset $ch" }catch{} } }

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

> **Где живёт логика loop.** `driver.ps1` теперь тонкий entrypoint-загрузчик; реальная логика цикла разбита по модулям `driver/NN-*.ps1` (`80-loop-preflight.ps1`, `81-loop-idle-claim.ps1`, `82-loop-turn-setup.ps1`, `83-loop-agent-turn.ps1`, `84-loop-reply-markers.ps1`, `85-loop-mode-transitions.ps1`, completion разбит на `86-loop-completion.ps1` + `86-loop-completion-actions.ps1` / `-checks.ps1` / `-cleanup.ps1`, `87-loop-final-guard.ps1`, `90-main-loop.ps1`; обслуживание/аудит — `10-maintenance.ps1`). `-SelfTest` грузит все эти модули, так что ловит load-time ошибки и в них. При parse-fail (§4.3) проверяй и `driver\*.ps1`-модули, не только корневой `driver.ps1`.

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
