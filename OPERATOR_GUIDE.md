# Bridge — Operator Guide (руководство оператора)

> Назначение: всё, что нужно ОПЕРАТОРУ (тебе), чтобы управлять мостом, смотреть пульт, ставить
> задачи и чинить проблемы — **без обращения к разработчику и без потери знаний при удалении чата**
> (bus factor = 100%). Для внутренней разработки моста см. `DEVELOPER_GUIDE.md`, для архитектуры —
> `PROJECT_MAP.md` / `ARCHITECTURE_V2.md`, для мониторинга — `MONITORING_RUNBOOK.md`.
>
> Последнее обновление: 2026-06-01.

---

## 0. Что такое мост (за 30 секунд)

Мост — автономная команда из AI-агентов (Claude + Codex + DeepSeek + Gemini), которая сама берёт
задачи из бэклога, обсуждает, пишет код, проверяет и коммитит. Управляется через веб-пульт и чат.

**Топология процессов** (поднимаются автоматически при старте Windows):
```
Task Scheduler (ClaudeCodexBridge, elevated)
        └─ supervisor.ps1   — следит, перезапускает упавшее, держит watchdog
              ├─ server.ps1   — веб-пульт + API (порт из config.json .port, обычно 8787)
              ├─ driver.ps1 -Channel aipartners   — рабочий цикл канала проекта
              ├─ driver.ps1 -Channel main          — рабочий цикл канала самого моста
              └─ watchdog.ps1 — аварийный откат (git) при поломке
        (по одному driver на КАЖДЫЙ активный канал; новый проект → новый канал)
```

**Ключевые пути:**
| Что | Путь |
|---|---|
| Корень моста (код, доки) | `C:\Users\rafie\OneDrive\Documents\bridge` |
| Runtime (НЕ на OneDrive, чтобы не било блокировками) | `C:\Users\rafie\.bridge-runtime` |
| Каналы (состояние, бэклог, история) | `bridge\channels\<канал>\` |
| Управляющие флаги/логи | `bridge\control\` |
| Проект AI Partners | `C:\Users\rafie\aipartners` |

---

## 1. Жив ли мост? (быстрая проверка)

```powershell
# пульт отвечает?
Invoke-WebRequest 'http://127.0.0.1:8787/api/health' -UseBasicParsing -TimeoutSec 4 | Select StatusCode
# процессы
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match 'supervisor|driver\.ps1|server\.ps1|watchdog' } |
  ForEach-Object { $_.CommandLine -replace '.*\\','' }
# свежесть канала (heartbeat должен быть < ~30с когда работает)
$s = [IO.File]::ReadAllText('C:\Users\rafie\OneDrive\Documents\bridge\channels\aipartners\state.json',[Text.Encoding]::UTF8) | ConvertFrom-Json
"status=$($s.status) turn=$($s.task_turn) hb=$([int]((Get-Date)-[datetime]$s.heartbeat).TotalSeconds)с"
```
- **HTTP 200 + heartbeat < 30с** = жив.
- `status=working` — выполняет задачу; `status=idle` — простаивает (нет работы — это норма, НЕ поломка).

> ⚠️ Не пугайся, если `Get-CimInstance` не показывает driver: у части процессов CommandLine не
> читается, и фильтр даёт ложный «0». Истина — **heartbeat в state.json**, а не список процессов.

---

## 2. Пульт (веб-UI)

Открой в браузере: **http://127.0.0.1:8787**

Что показывает:
- **Чат** — диалог с мостом: твои сообщения, ответы агентов, системные события (что берёт в работу, что сделал).
- **Статус канала** — working/idle, текущая задача, активный агент/модель.
- **Кнопки управления** (control actions): ⏸ Пауза · ▶ Продолжить · ⏹ Стоп · 🛑 Стоп-кран (kill) · ♻ Перезапуск.
- **Бэклог / решения** — очередь задач, журнал решений.

Канал переключается через пин (?channel=aipartners) — по умолчанию активный.

---

## 3. Как ставить задачи

### Способ A — просто написать в чат пульта (обычный режим)
Пишешь задачу — мост сам решает: обсудить (planner) или сразу делать (coder). Подходит для мелочей.

### Способ B — Discuss-First Delivery (РЕКОМЕНДУЕТСЯ для фич/проектов)
Наш основной флоу (см. §7). Кратко: сначала **обсуждение** → карта+план → ревью → и только потом
исполнение. Не «накидать беклог на скорую руку».

### Способ C — добавить задачу в бэклог напрямую (для оператора/скриптом)
Бэклог — это `channels\<канал>\backlog.jsonl` (append-log, сворачивается по id).
**ВАЖНО:** driver постоянно перезаписывает бэклог — прямой append во время его работы может затереться.
Поэтому добавляй **под паузой**:
```powershell
$sf='C:\Users\rafie\OneDrive\Documents\bridge\channels\aipartners\state.json'
# пауза
$st=[IO.File]::ReadAllText($sf,[Text.Encoding]::UTF8)|ConvertFrom-Json; $st.paused=$true
[IO.File]::WriteAllText($sf,($st|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($true)))
Start-Sleep 3
# ... здесь дописать задачи в backlog.jsonl (UTF8 БЕЗ BOM) ...
# resume
$st2=[IO.File]::ReadAllText($sf,[Text.Encoding]::UTF8)|ConvertFrom-Json; $st2.paused=$false
[IO.File]::WriteAllText($sf,($st2|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($true)))
```
Формат записи задачи (поля): `id, ts, from, status('approved'), project, scope, severity, text,
workpack_id, workpack_conflict_group('file:<путь>'), workpack_touch_set(['<путь>']), workpack_status('planned')`.
Чтобы задачи шли **параллельно** — у каждой свой `workpack_conflict_group` = свой целевой файл.

---

## 4. Как мост работает командой (параллель)

- **Packer** группирует независимые approved-задачи в **workpack-batch** (условие: ≥2 задачи с разными
  `conflict_group` и непересекающимися touch-set по целевому файлу).
- **Deterministic dispatch** спавнит по воркеру на поток в отдельных git-worktree.
- **Воркеры** — пул из config.json (codex разных уровней, claude sonnet/opus, deepseek, gemini).
  Роутинг по сложности задачи (`Get-TaskComplexityHeuristic`): простая → дешёвый/быстрый, сложная →
  сильный (opus только на architectural).
- **collect-then-commit** — после работы хост напрямую забирает изменённые файлы из всех worktree в
  репозиторий (минуя ненадёжный git воркеров). Доставка 100% независимо от поведения CLI.
- В чате при старте команды виден **план потоков** («🔀 Запускаю команду из N потоков: • поток wp1 …»).

Машина тянет до ~20 параллельных воркеров (проверено: CPU 6–16%, RAM 30 ГБ свободно).

---

## 4-bis. Управление КОМАНДОЙ (состав, масштаб, модели, стоимость)

Команда задаётся в `config.json → parallel.workers`. Сейчас 20 воркеров, `maxStreams=20`.

### Состав команды
| id (примеры) | CLI / модель | strength | cost | speed | для чего |
|---|---|---|---|---|---|
| codex-xhigh | codex gpt-5.5/xhigh | 5 | 5 | 1 | самое сложное, backend/scripts |
| codex-high ×3 | codex gpt-5.5/high | 4 | 4 | 2 | сложное, любой домен |
| codex-medium ×3 | codex gpt-5.5/medium | 3 | 3 | 3 | средние задачи |
| codex-alt ×2 | codex gpt-5.4/high | 3 | 2 | 3 | дешевле, запас |
| codex-specialist ×2 | codex gpt-5.3-codex/high | 3 | 3 | 2 | код-специфика |
| claude-sonnet ×3 | claude sonnet | 3 | 3 | 3 | frontend/docs/config |
| **claude-opus ×2** | claude opus-4-8 | **5** | **5** | 2 | **только сложное/architectural** |
| deepseek-pro ×2 | deepseek v4-pro | 4 | **2** | 3 | сильный и дешёвый |
| gemini-flash ×2 | gemini 2.5-flash | 3 | **1** | 4 | дешёвый, быстрый, простое |

`strength/cost/speed` — шкала 1–5. `domains` — backend / frontend / docs / config / scripts / any.

### Как масштабировать
- **Больше потоков:** добавь записи воркеров в `parallel.workers` (дублируй: `id-2`, `id-3`) и подними
  `parallel.maxStreams`. Реально параллелятся ровно столько, сколько НЕЗАВИСИМЫХ задач в batch.
- **Меньше / экономия:** убери записи дорогих воркеров или снизь `maxStreams`.
- После правки config → `restart.flag` (§5), чтобы driver перечитал пул.

### Как добавить нового воркера / модель
1. Запись в `parallel.workers`: `{id, cli, model, reasoning?, strength, cost, speed, domains[]}`.
2. CLI должен быть в реестре (`lib/parallel.ps1 → $Script:ParallelCliRegistry`): codex/claude/gemini/deepseek.
   Для нового CLI — добавь `Invoke-ParallelXxxCli` (см. DEVELOPER_GUIDE) и строку в реестр.
3. `restart.flag`.

### Роутинг — кто берёт задачу (`Select-WorkerForStream`)
1. `strength ≥ complexityFloor[сложность]` — порог силы: **simple→2, moderate→3, complex→4, architectural→5**.
2. Совпадение `domains` с доменом задачи (specialist'ы в приоритете).
3. **opus-guard:** claude-opus берётся ТОЛЬКО на `architectural` (или явный `[[OPUS]]`) — он дорогой.
4. Сортировка кандидатов: **дешевле (cost↑), потом быстрее (speed↓)** — экономия по умолчанию.
5. Без двойного бронирования (один воркер — один поток, пока пул не исчерпан).

Сложность определяется автоматически из текста задачи (`Get-TaskComplexityHeuristic`): «перепиши/рефактор»
→ complex; «схема БД/миграция/архитектура» → architectural; «создай файл одной строкой» → simple.

### Форсировать выбор (override в тексте задачи / [[PARALLEL]]-блоке)
- `worker: codex-xhigh` — взять конкретного воркера.
- `Complexity: complex` — задать сложность вручную (поднимет порог силы).

### Модель-политика (СТОИМОСТЬ — соблюдать!)
- ⛔ **НИКОГДА `gemini-2.5-pro`** — слишком дорогой. Удалять из конфига, если случайно вернётся.
- ⚠️ `gemini-3-flash` — **только резерв** (дорогой), когда основной агент недоступен/вернул пусто.
- Рутина (curator, intent-classifier, smoke) → `gemini-2.5-flash-lite` / `gemini-2.5-flash` (дёшево).
- `opus` — отличный кодер, но дорогой → держать на сложных/architectural, не на мелочь (opus-guard это и обеспечивает).
- Основная масса — codex (по подписке, prepaid) + дешёвый deepseek/gemini.

### Контроль стоимости
- `usage.jsonl` логирует каждый вызов: `kind` = **prepaid** (codex/claude по подписке, $0 сверху) или
  **paid** (deepseek/gemini API → `cost_usd`). Цены — `config.usage.prices`.
- Сводка burn-rate — через API пульта / `Get-UsageSummary` (см. MONITORING_RUNBOOK).
- Хочешь дешевле — больше gemini-flash/deepseek (cost 1–2) в пуле, меньше opus/codex-xhigh (cost 5).

---

## 5. Управление процессами

```powershell
# Перезапустить мост целиком (через планировщик — правильный способ)
Stop-ScheduledTask -TaskName 'ClaudeCodexBridge'; Start-Sleep 3; Start-ScheduledTask -TaskName 'ClaudeCodexBridge'

# Применить изменения в .ps1-коде моста без полного перезапуска (graceful):
Set-Content 'C:\Users\rafie\OneDrive\Documents\bridge\control\restart.flag' '1' -Encoding ASCII
#   supervisor подхватит и перезапустит драйверы, когда канал освободится

# Пауза/продолжение канала (через пульт-кнопки или вручную через state.paused, см. §3)

# Полная остановка
Stop-ScheduledTask -TaskName 'ClaudeCodexBridge'
```
Автозапуск при загрузке Windows уже настроен (`install-autostart.ps1`). Мост поднимается сам после
перезагрузки и **возобновляет прерванную задачу** (видно сообщение «♻ Мост перезапущен — возобновляю…»).

---

## 6. Каналы

| Канал | Что это |
|---|---|
| `aipartners` | проект — платформа видео-рецептов (`C:\Users\rafie\aipartners`) |
| `main` | развитие самого моста (его инфраструктура) |
| `_archive` | архив старых/тестовых каналов (напр. бывший `travel` — учебный прогон, к мосту не относится) |

Каждый канал — свой driver, своё состояние, свой бэклог, своя история. Codex общий на все каналы
(поэтому иногда «⏳ Codex занят другим каналом — жду»).

---

## 7. Discuss-First Delivery — основной рабочий флоу

**Принцип:** тяжёлое мышление (исследование, обсуждение, карта, план, код) — на мосте; оператор/Claude
формулируют вход и ревьюят выход; **беклог только после утверждённого плана**, не «на скорую руку».

| Фаза | Кто | Что |
|---|---|---|
| Ф0 Намерение | ты | даёшь цель одной формулировкой |
| Ф1 Обсуждение | **мост** (STATUS: DISCUSS) | сам исследует, вскрывает нестыковки, задаёт вопросы |
| Ф2 Карта+план | **мост** | формирует `PROJECT_MAP.md` + `PLAN.md` (durable) |
| Ф3 Ревью плана | Claude | архитектор-гейт: целостность/дыры/риски → итерация |
| Ф4 Ревью плана | ты | корректируешь/утверждаешь |
| Ф5 Заморозка | — | план зафиксирован → разрешён беклог |
| Ф6 Исполнение | **мост-команда** | параллель; verify обязан гонять project build |
| Ф7 Приёмка | ты | проверка против плана (сценарии), не «зелёный build» |

**Зачем:** прежняя «накидать беклог кусками» дала несвязный продукт (франкенштейн: страницы есть,
навигации нет). Обсуждение до беклога вскрывает такое заранее.

### Декомпозиция до АТОМОВ (между Ф2 и Ф6)
Крупная задача дробится как книга — и в беклог идут только атомы, а не «главы»:

| Уровень | Что | Пример | Кто ревьюит |
|---|---|---|---|
| 📕 Книга | проект/фича | «связный продукт aipartners» | оператор |
| 📑 Глава | крупный этап, законченная ценность | «Навигация», «Auth/logout» | **оператор (только этот уровень!)** |
| 📃 Параграф | подсистема главы | Header / Footer / admin-layout | Claude |
| ¶ Абзац | конкретный аспект | «Header: меню гостя» | Claude |
| · **Атом** | 1 файл / 1 маленькое проверяемое изменение, проходит tsc/build сам | «в Header добавить ссылку Войти для гостя» | Claude |

Правила:
- **В беклог идут ТОЛЬКО атомы.** Крупный этап в беклоге = большая задача = воркер ломает (как cart-syntax).
- Критерий атома: 1 файл (или 1 маленький компонент) + одно проверяемое изменение + само проходит `tsc`/build. Трогает >1–2 файла или «и ещё» — дробить дальше.
- **Поглавно:** декомпозировать главу → атомы → ревью → беклог → исполнить → следующая глава. Не все 100+ атомов разом.
- **Глубина по размеру:** мелкая глава → сразу атомы (2 уровня), крупная → через параграфы/абзацы.
- **Разграничение ревью: оператор смотрит ТОЛЬКО главы.** Параграфы/абзацы/атомы — на Claude (целостность + что атом реально атомарен). Оператора не таскать в мелкую декомпозицию.

---

## 8. Подводные камни (важно знать!)

1. **Сайт проекта (`:3100`) НЕ автозапускается.** Мост правит КОД, но не хостит сайт. После
   перезагрузки подними вручную:
   ```powershell
   cd C:\Users\rafie\aipartners; & .\node_modules\.bin\next.cmd start -p 3100   # prod (нужен build)
   # или для разработки: & .\node_modules\.bin\next.cmd dev -p 3100
   ```
2. **OneDrive.** `channels\` и бэклог лежат на OneDrive → бывают блокировки файлов под нагрузкой
   (видно в логах как IO-ошибки usage.jsonl — это шум, не краш). Runtime вынесен в `.bridge-runtime`.
3. **PowerShell 5.1.** Все `.ps1` с кириллицей ДОЛЖНЫ быть в UTF-8 **с BOM** (иначе парсер ломается).
   Никогда не редактируй скрипты моста в редакторе, который сохраняет без BOM.
4. **Circuit-breaker.** Если за 30 мин >5 «крашевых» рестартов — мост уходит в 15-мин cooldown
   (драйверы стоят). Чистые выходы (code 0) теперь НЕ считаются крахами. Сброс — см. §9.
5. **Verify-gate.** Для проектных каналов он должен гонять `tsc`/`next build` (не только bridge-smoke).
   Если задача «закрыта», но проект не собирается — это дыра verify (в процессе закрытия).

---

## 9. Troubleshooting (частые проблемы → решение)

**Пульт не отвечает / мост не работает после перезагрузки:**
```powershell
Stop-ScheduledTask -TaskName 'ClaudeCodexBridge'; Start-Sleep 3; Start-ScheduledTask -TaskName 'ClaudeCodexBridge'
```

**Канал застрял в `working`, но driver мёртв (застрявший lease) / завис в `paused`:**
```powershell
$sf='C:\Users\rafie\OneDrive\Documents\bridge\channels\aipartners\state.json'
$st=[IO.File]::ReadAllText($sf,[Text.Encoding]::UTF8)|ConvertFrom-Json
$st.status='idle'; $st.paused=$false; if($st.PSObject.Properties.Name -contains 'workpack_batch_active'){$st.workpack_batch_active=$false}
$st.heartbeat=(Get-Date).ToString('o')
[IO.File]::WriteAllText($sf,($st|ConvertTo-Json -Depth 30),(New-Object Text.UTF8Encoding($true)))
```

**Ложный cooldown (драйверы стоят, в логах «Circuit-breaker cooldown»):**
```powershell
$rf='C:\Users\rafie\.bridge-runtime\restarts.jsonl'
Move-Item $rf "$rf.bak" -Force; New-Item -ItemType File $rf | Out-Null   # очистить окно рестартов
```

**Два инстанса supervisor (мигание процессов):** оставь самый ранний по времени старта, убей новые
`Stop-Process -Id <pid> -Force`. Один supervisor сам удержит lock.

**Задача зацикливается (берётся снова и снова, re-claim):** причина — дубликаты id в backlog.jsonl.
Get-Backlog теперь сворачивает по id (last-wins) и лечит дубли при следующей мутации; проверь:
```powershell
. 'C:\Users\rafie\OneDrive\Documents\bridge\lib\common.ps1'; $env:BRIDGE_CHANNEL='aipartners'
@(@(Get-Backlog|%{[string]$_.id}|?{$_})|Group-Object|?{$_.Count -gt 1}).Count   # должно быть 0
```

**Сайт `:3100` не открывается:** он просто не запущен — см. §8 п.1 (это не поломка проекта).

**Осиротевшие worktree/ветки после прерванного batch:**
```powershell
cd C:\Users\rafie\aipartners; git worktree prune
git branch | Select-String 'wip/parallel' | %{ git branch -D ($_.ToString().Trim()) }
```

**Проверить, что проект жив (после правок мостом):**
```powershell
cd C:\Users\rafie\aipartners
& .\node_modules\.bin\tsc.cmd --noEmit          # 0 ошибок = типы целы
& .\node_modules\.bin\next.cmd build            # Compiled successfully = собирается
```

---

## 10. Карта файлов (где что лежит)

| Файл | Назначение |
|---|---|
| `channels\<ch>\state.json` | состояние канала: status, paused, current_task, heartbeat, lease |
| `channels\<ch>\backlog.jsonl` | очередь задач (append-log, свёртка по id) |
| `channels\<ch>\conversation.jsonl` | история чата/событий канала |
| `channels\<ch>\qa-results.jsonl` | результаты проверок |
| `control\restart.flag` | сигнал graceful-перезапуска драйверов |
| `control\driver.<ch>.out/err.log` | логи драйвера канала |
| `control\supervisor.log` | лог супервизора |
| `.bridge-runtime\restarts.jsonl` | окно рестартов для circuit-breaker |
| `config.json` | порт сервера, пул воркеров (parallel.workers), maxStreams |
| `lib\parallel.ps1` | параллель: dispatch, collect-then-commit, роутинг воркеров |
| `lib\backlog.ps1` | бэклог: packer, свёртка, классификация задач |
| `driver.ps1` | рабочий цикл канала (planner/coder, dispatch, verify, commit) |
| `supervisor.ps1` | надзор за процессами, circuit-breaker |

---

## 11. Шпаргалка: «хочу — команда»

| Хочу | Команда / действие |
|---|---|
| Проверить, жив ли мост | §1 |
| Открыть пульт | http://127.0.0.1:8787 |
| Поставить фичу/проект | Discuss-First (§7): дай цель, мост обсудит → план → ревью → исполнение |
| Поставить мелкую задачу | написать в чат пульта |
| Перезапустить мост | Stop/Start ScheduledTask `ClaudeCodexBridge` (§5) |
| Применить правку .ps1 | `restart.flag` (§5) |
| Поднять сайт проекта | §8 п.1 |
| Разморозить застрявший канал | §9 (lease/paused) |
| Сбросить ложный cooldown | §9 (restarts.jsonl) |
| Проверить, собирается ли проект | §9 (tsc + next build) |
| Больше/меньше потоков команды | правь `config.parallel.workers` + `maxStreams` → restart.flag (§4-bis) |
| Сделать команду дешевле | больше gemini/deepseek (cost 1–2), меньше opus/codex-xhigh (cost 5) (§4-bis) |
| Форсировать модель на задачу | `worker: <id>` в тексте задачи (§4-bis) |
| Посмотреть расходы | usage.jsonl / Get-UsageSummary (§4-bis) |

---

*Эта дока — операторская страховка (bus factor). Держи её в актуальном состоянии: при изменении
механизмов моста обновляй соответствующий раздел.*
