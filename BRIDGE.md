# BRIDGE — единый справочник моста

_Один документ про автономную команду Claude↔Codex: всё в одном месте для ЧТЕНИЯ, собрано из актуализированных доков и сверено с реальным кодом (2026-06-23)._

> **Это единственный файл, который нужно читать человеку.** Прежние разрозненные гайды (`OPERATOR_GUIDE.md`, `DEVELOPER_GUIDE.md`, `PROJECT_MAP.md` и др.) ОСТАВЛЕНЫ в репозитории — не потому что нужны для чтения, а потому что сам КОД моста читает их как функциональный контекст (architect → `goals.md`/`ARCHITECTURE_V2.md`/`external-systems.md`/`architecture-matrix.md`; autopilot/acceptance → `PROJECT_MAP.md`; self-model → гайды). Удалять их нельзя — мост сломается. Для тебя — достаточно этого файла.

## Оглавление

1. [Обзор и быстрый старт](#обзор-и-быстрый-старт)
2. [Архитектура](#архитектура)
3. [Модели и режимы работы](#модели-и-режимы-работы)
4. [Бэклог и жизненный цикл задач](#бэклог-и-жизненный-цикл-задач)
5. [Синтез решений и роутер глубины](#синтез-решений-и-роутер-глубины)
6. [Аудит и Доктор](#аудит-и-доктор)
7. [Надёжность и аварийное восстановление](#надёжность-и-аварийное-восстановление)
8. [Операции (управление мостом и командой)](#операции-управление-мостом-и-командой)
9. [API (эндпоинты сервера :8787)](#api-эндпоинты-сервера-8787)
10. [Справочник конфигурации](#справочник-конфигурации)
11. [Мониторинг и устранение неполадок](#мониторинг-и-устранение-неполадок)
12. [Каналы, проекты, внешние системы](#каналы-проекты-внешние-системы)
13. [Роли агентов](#роли-агентов)

---

## Обзор и быстрый старт

`bridge` — локальная Windows-система, превращающая чат в автономную команду разработки. Это не один «ассистент», а конвейер из специализированных AI-агентов, который сам берёт задачи, обсуждает их, пишет код, прогоняет проверки, коммитит, запоминает выводы и улучшает сам себя.

### Кто за что отвечает

| Агент | Роль |
|---|---|
| **Claude** (`claude-opus-4-8` для Deep/премиум, `sonnet` для триажа) | Планирование, обсуждение, ревью, архитектурные решения |
| **Codex** | Написание и правка кода |
| **DeepSeek / Gemini** | Критик (на *другой* модели, чем автор), аудит, библиотекарь, эмбеддинги (`gemini-embedding-001`), роутинг, дешёвые служебные решения |

Северная звезда (`goals.md`), строго по приоритету: **стабильность и безопасность → автономность → самообучение → скорость/польза/экономия → внешние проекты** (последнее — только когда фундамент моста надёжен).

### Каналы

Единица работы — **канал**: своя вкладка, свой `project_root`, свои state/conversation/backlog/память/код-индекс. **Один `driver.ps1` на активный канал.** Живые каналы: `main` (сам мост), `claude` (операторский), `telegram-bridge-bot`, `computer-control` (ЛАПА — GUI-руки), `oko` (vision-сервис). Архивные — в `channels/_archive/`. Фоновый audit/brainstorm для всех каналов кроме `main` выключен по умолчанию (`channelMaintenance.nonMainAuditEnabled=false`, `nonMainBrainstormEnabled=false`).

### Ключевые пути

| Что | Путь | Примечание |
|---|---|---|
| Код, доки, git-репо моста | `C:\Users\rafie\OneDrive\Documents\bridge` | канал `main`; на OneDrive |
| Runtime (state, locks, jobs, логи ensure) | `C:\Users\rafie\.bridge-runtime` | **вне** OneDrive — чтобы sync не бил блокировками и не портил JSON |
| Секреты + аварийный стоп-кран | `C:\Users\rafie\.bridge-private` | `secrets.json`, `auth.json`, `watchdog.pause` — **вне** корня моста, недоступны coder-у |
| Репозитории проектов | `C:\Users\rafie\bridge-projects\<slug>` | точный путь — в `channels\<канал>\channel.json → project_root` |
| Состояние/история канала | `bridge\channels\<slug>\` | `state.json`, `conversation.jsonl`, `backlog.jsonl` |
| Управляющие флаги и логи | `bridge\control\` | restart-флаги, active channel, `watchdog.log` |

> `.git` вынесен с OneDrive (separate-git-dir): `bridge\.git` — это GITLINK-файл (`gitdir: …`), а не каталог.

### Как это запущено (автостарт)

Всё поднимается само при логине Windows. Внешняя задача Task Scheduler `ClaudeCodexBridge` (elevated) запускает дерево процессов:

```text
Task Scheduler: ClaudeCodexBridge (elevated)
  supervisor.ps1                      — надзор, recycle, circuit-breaker
    ├─ server.ps1                     — HTTP API + веб-пульт на :8787 (config.json .port)
    ├─ driver.ps1 -Channel main       — рабочий цикл канала самого моста
    ├─ driver.ps1 -Channel <project>  — по одному driver на каждый активный проектный канал
    └─ watchdog.ps1                   — независимый сторож здоровья, рестартов и rollback
```

До **20** одновременных драйверов (`config.json supervisor.maxConcurrentDrivers=20`). Параллельные воркеры внутри задачи изолируются в git worktrees (`lib/parallel.ps1`). Дефолтная coder-песочница — `workspace-write` (`config.json coder.sandboxMode`), отдельным каналам можно расширить через `sandboxModeByChannel`. Decision Synthesis включён (`synthesisMode.enabled=true`); canary — выключен.

**Правила процессного слоя:** никогда не делать dot-source для `driver.ps1`/`server.ps1`/`supervisor.ps1`; целевая среда — Windows PowerShell **5.1** (не 7); `.ps1` — UTF-8 **с BOM**; правки собирать пачкой и делать один контролируемый restart на idle-канале, не плодить рестарты (иначе сработает circuit-breaker).

### Слои надёжности (как мост сам себя чинит)

Три независимых уровня восстановления, от мягкого к жёсткому:

1. **`watchdog.ps1`** — следит за свежестью heartbeat канала. Подход **restart-first**: при stale-heartbeat сначала перезапускает драйвер (код цел), а git-**rollback** делает только если рестарт не помог *и* smoke красный. Перед откатом всегда создаётся safety-ветка `prerollback/<ts>` (коммиты не теряются). Rollback **HELD**, если уже сработал circuit-breaker (cooldown) или идёт параллельный merge. Авто-rollback применим только к каналу `main` (bridge git).

2. **`ensure-bridge.ps1`** — внешний якорь, задача Task Scheduler `ClaudeCodexBridge-Ensure` (~каждые 5 мин, elevated). Лечит два наблюдавшихся отказа: (а) OneDrive обнулил `.git/refs/heads/master` → восстанавливает ref из backup/`stable`/`origin/master`; (б) умерли supervisor И watchdog без авто-рестарта → перезапускает задачу supervisor (cooldown 10 мин) и респаунит watchdog. Считает watchdog «зависшим», если его smoke-лог не обновлялся **>75 мин** (порог поднят с учётом реального ~50-мин цикла smoke, чтобы не убивать рабочий watchdog). Process-heal работает только в elevated-контексте (иначе CommandLine нечитаем → fail-safe «жив», без spawn-storm).

3. **Аварийный стоп-кран оператора** — создать файл `C:\Users\rafie\.bridge-private\watchdog.pause` → watchdog не предпринимает никаких действий. Файл намеренно лежит вне корня моста, чтобы coder-ход не мог его тронуть; снять паузу — удалить файл.

### Быстрая проверка «жив ли мост»

```powershell
# 1) пульт отвечает? (200 = жив; 401 = жив, но требует auth — это норма, НЕ поломка)
Invoke-WebRequest 'http://127.0.0.1:8787/api/health' -UseBasicParsing -TimeoutSec 4 | Select StatusCode
# 2) свежесть канала — ИСТИНА в heartbeat, не в списке процессов (CommandLine часто нечитаем)
$s = [IO.File]::ReadAllText('C:\Users\rafie\OneDrive\Documents\bridge\channels\main\state.json',[Text.Encoding]::UTF8) | ConvertFrom-Json
"status=$($s.status) hb=$([int]((Get-Date)-[datetime]$s.heartbeat).TotalSeconds)с"
```

**HTTP 200 + heartbeat < ~30 с = жив.** `status=working` — выполняет задачу; `status=idle` — просто нет работы (это норма). Пульт открывается в браузере на **http://127.0.0.1:8787**; переключение канала — через `?channel=<slug>`.

---

## Архитектура

Мост — автономная команда из двух ИИ-агентов на **Windows + PowerShell 5.1** (не 7.x): **Claude** планирует/ревьюит, **Codex** пишет код. ~200 `.ps1`-файлов, HTTP-сервер и весь UI в одном `web/index.html` (≈282 KB). Целевая платформа жёсткая: PS 5.1, UTF-8 **с BOM** для `.ps1`, runtime в OneDrive-папке (источник class'а инфра-сбоев — см. раздел про стабильность).

### Процессная модель

Дерево процессов поднимается из Task Scheduler (`\ClaudeCodexBridge`, **elevated**) и держится надзирателем:

```text
Task Scheduler: ClaudeCodexBridge  (autostart, elevated)
  supervisor.ps1                       # надзор, recycle, circuit-breaker, OOM-reaper
    ├── server.ps1            (:8787)  # HTTP API + web UI + чат
    ├── driver.ps1 -Channel main       # цикл planner↔coder для самого моста
    ├── driver.ps1 -Channel <slug>     # ПО ОДНОМУ driver на каждый активный канал
    └── watchdog.ps1                   # независимый сторож: restart-first, иначе rollback
```

- **Один `driver.ps1` на канал.** `main` = сам мост (bridge-self); живые проектные/операторские каналы — `claude`, `oko`, `computer-control`, `telegram-bridge-bot` (отработанные уехали в `channels/_archive/`). У каждого свой `channels/<slug>/`: `state.json`, `conversation.jsonl`, `turns.jsonl`, project binding.
- **Общий Codex на ВСЕ каналы → сериализация через mutex `runtime/codex.lock`** (`lib/common.ps1`). Конкурирующий канал ждёт до 120 c («Codex занят другим каналом»), затем продолжает без mutex. Lock имеет stale-detection: мёртвый/чужой PID (проверка по start-time, `common.ps1:1723+`) забирается сразу. Снизить конкуренцию — `autonomyDisabledChannels`.
- **Жёсткие правила:** никогда не dot-source'ить `driver.ps1`/`server.ps1`/`supervisor.ps1`; перед применением любой `.ps1`-правки — `Parser::ParseFile` + `driver.ps1 -SelfTest`; не плодить рестарты (пачка правок → один recycle на idle).

### 8-фазный цикл драйвера

`driver.ps1` — тонкий entrypoint (~150 строк): грузит библиотеки, dot-source'ит `driver/NN-*.ps1`, гоняет self-test и зовёт startup + main loop. Сам loop — `Start-DriverMainLoop` в `driver/90-main-loop.ps1`: бесконечный `while`, который на каждой итерации последовательно dot-source'ит 8 фазовых scriptblock'ов (`$script:DriverLoop*Block`), обёрнутых в общий `try/catch` (ошибка фазы → лог + сброс активного агента в state + sleep, без падения процесса):

| # | Модуль | Фаза |
|---|---|---|
| 80 | `80-loop-preflight.ps1` | preflight: state-recovery, recycle-coalescer (откладывает `restart.flag` пока есть работа), обработка stop/pause/doctor/job |
| 81 | `81-loop-idle-claim.ps1` | idle-claim: пользовательский ввод / автономия / claim из бэклога; здесь же `Start-ProjectAutopilotIfNeeded` и резолв `computer_action` |
| 82 | `82-loop-turn-setup.ps1` | turn-setup: выбор `task_mode`, speaker, модели планировщика, сборка промпта |
| 83 | `83-loop-agent-turn.ps1` | agent-turn: вызов planner/coder, preflight, обработка таймаутов, SAFETY-gate |
| 84 | `84-loop-reply-markers.ps1` | reply-markers: парсинг `[[FILE]]`/`[[SAVE]]`/`[[EVIDENCE]]`/`[[PLAN]]`/`[[RUNJOB]]`/`[[PROJECT_BACKLOG]]`/`[[ЛАПА]]` |
| 85 | `85-loop-mode-transitions.ps1` | mode-transitions: переходы discuss/study/research; loop-детекторы → эскалация в Doctor |
| 86 | `86-loop-completion*.ps1` | completion: статус планировщика, verify-gate, commit, completion-gates (разбит на `-checks`/`-actions`/`-cleanup`) |
| 87 | `87-loop-final-guard.ps1` | final-guard: max-turn guard (`config.maxTurns`) и idle-sleep |

> Правки поведения вносить в профильный модуль, не возвращать монолит в `driver.ps1`; затем обязательно `ParseFile` + `-SelfTest`.

### Разбиение на модули

**Корень/entrypoint'ы (в git):** `driver.ps1`, `server.ps1` (≈98 KB, HTTP API + auth + UI backend), `supervisor.ps1` (≈18 KB), `watchdog.ps1` (≈10 KB), плюс фоновые `reflect.ps1` / `librarian.ps1` / `techradar.ps1` / `canary.ps1`. **`config.json` — основной конфиг в git**; `secrets.json` / `auth.json` / `settings.json` — НЕ в git (приватный стор вне корня моста, legacy-fallback внутри).

**`lib/` (~68 модулей, dot-source из `common.ps1`)** — вся логика. Ключевые:

- `common.ps1` (97 KB) — state/atomic-write, сообщения, LLM-вызовы, локи (включая `codex.lock`).
- `parallel.ps1` (64 KB) / `worktrees.ps1` — параллельные потоки в git-worktree'ах + устойчивый merge.
- **Бэклог-семейство** — фасад-загрузчик `backlog.ps1` (28 KB) dot-source'ит split-модули: `backlog-core.ps1` (~143 KB; claim-gate, risk-tier, self-exec), `backlog-crud.ps1` (Add/Set/Get-Idea), `backlog-workpack.ps1` (deterministic intake gate + ready-frontier), `backlog-governor.ps1`, `backlog-dedup.ps1` (embedding root-cause dedup), `backlog-autopilot.ps1`, `backlog-state-reaper.ps1`.
- `auditor.ps1` (read-only health-сенсор), `memory.ps1` (векторная память, `gemini-embedding-001`), `architect.ps1` (брейншторм/deep-think), `circuit-breaker.ps1`, `doctor.ps1`, `decision-depth.ps1` + `decision-synthesis.ps1` (Multi-Model Decision Synthesis), `router.ps1`, `intent.ps1`, `channels.ps1`, `settings.ps1`, и др.

**`tools/` (~191 скрипт)** — аудит и утилиты: `audit.ps1` (статика + findings-ledger), `deep-audit.ps1` + `deep-audit-agent.ps1` (многоагентный), `web-smoke.ps1`, `scenario.ps1`.

### Надзор и восстановление

Три независимых защитных слоя — **не путать**:

| Механизм | Где | Что делает |
|---|---|---|
| **supervisor** | `supervisor.ps1` | держит server+driver+watchdog живыми, recycle по `restart.flag`. Rate-limit: ≥60 c между recycle'ами (`$minRecycleSec`). Только non-zero exit считается крахом (clean exit = managed restart, breaker не трогает). OOM-reaper: >8 GB private → kill. Второй независимый restart-limiter (`Test-SupervisorRestartAllowed`, `~/.bridge-runtime/restart-limits.json`) — в проде практически выключен (`maxPerHour`≈1000). |
| **circuit-breaker** | `lib/circuit-breaker.ps1` | анти-шторм: ≥`maxRestarts=5` рестартов за `windowMin=30` мин → cooldown `cooldownMin=15`. Классы рестартов (`parse-fail`/`state-corrupt`/`OOM`/`explicit-flag`/`task-survived-3x`/`unknown`) в `~/.bridge-runtime/restarts.jsonl`. После 3 продлений cooldown — принудительный resume (живой мост лучше мёртвого). |
| **watchdog** | `watchdog.ps1` | **restart-first, rollback — крайняя мера** (hardened 2026-05-25 после ложного отката). Здоровье судится по heartbeat. API упал, но heartbeat свежий (server рестартится после self-edit) → мягкий `restart.flag`. Только при **stale heartbeat** (`rollbackThreshold=4`, ~8 мин) или API-down-после-recycle (`apiRollbackThreshold=6`, ~12 мин) → `git reset --hard stable`, и ВСЕГДА сначала safety-ветка `prerollback/<ts>` (коммиты не теряются), smoke-gated; rollback HELD при сработавшем breaker. |

**Per-task потолок** (отдельная ось, не процессный breaker): `config.taskRestartCaps` = `{apply:6, hard:3, total:8}` — превышение помечает ОДНУ задачу `failed`, мост идёт дальше (`driver/60-startup.ps1`).

**Hard-freeze kill-switch:** файл `<USERPROFILE>\.bridge-private\watchdog.pause` (вынесен ИЗ coder-writable дерева — кодер в `workspace-write` не может его создать, чтобы заглушить защиту). Пока он есть — watchdog не делает НИЧЕГО. Legacy-путь `control\watchdog.pause` намеренно больше не проверяется.

### Capability-matrix (кратко)

Что реально работает (полная живая матрица генерится `Get-CapabilityMatrixLive` из `features/registry.json`; ручной reference — `architecture-matrix.md`):

- **Ядро:** planner↔coder пайплайн, модель-роутер по сложности (Sonnet триаж / Opus 4.8 архитектура), Codex `xhigh` reasoning, usage-tracking.
- **Надёжность:** supervisor, watchdog с safety-branch, hybrid stable-promotion (30 мин здоровья + smoke), zombie-reaper, 🩺 Doctor auto-repair.
- **Самообучение:** вектор-память + код-память (semantic recall), librarian, reflect, post-mortem, experiment-loop с вердиктом.
- **Агенты/оркестрация:** независимый критик (DeepSeek-Pro), coder-bypass gate, Decision Synthesis (`task_mode='synthesis'`), параллельные worktree-воркеры, job-manager, computer_action («лапа»).
- **Безопасность/проверки:** SAFETY-gate (HITL-пауза), verify-gate (`[[VERIFIED:]]`), API/UI-verification, ParseFile fast-fail, deterministic backlog intake-gate.
- **Частично / нет:** мобильный layout (⚠), push-уведомления (⚠ без боевого теста на устройстве), полная DAG-декомпозиция (⚠ — workpack эвристически выводит `depends_on`), red-green test-first (❌).

---

## Модели и режимы работы

Мост — это команда из разных LLM, каждой отведена своя роль. Кто думает/планирует, кто пишет код, кто проверяет — задаётся в `config.json`, а конкретную модель планировщика на каждую задачу выбирает `Get-PlannerModel`.

### Ростер ролей

| Роль | Модель / ключ конфига | Назначение |
|---|---|---|
| **Planner** | Claude (`config.planner = "claude"`) | Думает, планирует, ревьюит, ведёт обсуждения |
| **Coder** | Codex (`config.coder.agent = "codex"`, `sandboxMode = "workspace-write"`) | Пишет код в песочнице |
| **Триаж-модель планировщика** | `triageModel = "sonnet"` | Дефолт для рутины (дёшево/быстро) |
| **Premium-модель планировщика** | `deepModel = "claude-opus-4-8"` | Архитектурные/важные решения |
| **Критик** | `config.llm.critic = "deepseek-v4-flash"`, тяжёлый — `criticHeavy = "deepseek-v4-pro"` | Независимая проверка правок (до `criticMaxRetries = 3` попыток) |
| **Intent-классификатор / curator** | `gemini-2.5-flash-lite` (`lib/intent.ps1`, `$IntentDefaultModel`) | Дешёвый разбор намерения по каждой новой задаче (~$0.0001/вызов) |
| **QA / gate / librarian / reflect** | `deepseek-v4-flash` (`config.llm.*`) | Служебные LLM-роли |

Параллельный пул из 20 воркеров (`config.parallel.workers`) — отдельная тема (см. раздел про параллельные потоки); модельная политика та же.

### Tiering планировщика: `Get-PlannerModel` (`driver/00-task-session.ps1:63`)

Функция возвращает либо `triageModel` (sonnet, по умолчанию), либо `deepModel` (`claude-opus-4-8`). В premium уходят:

- **Архитектурные ключевые слова** в тексте (`opusKeywords`: `архитектур`, `рефактор`, `перераб`, `redesign`, `мигр`, `интеграц`, `масштаб`, `спроектируй`, `design`, `refactor`…);
- режим `study` (`opusOnStudy = true`), режим `discuss` (`opusOnDiscuss = true`), любой `synthesis` — безусловно;
- маркеры `[[OPUS]]` / `[[FABLE]]` (regex по слову) и `[[DEEP-THINK]]` / `[[FABLE]]` (regex по строке);
- длинные промпты (>300 слов) — только если включён `opusOnLongPrompts` (сейчас `false`).

> **Важно:** структура спеки (нумерованные шаги, «волна 1/2/3», «фаза A/B») премиум НЕ форсит (фикс 2026-05-27) — хорошо организованная задача проще для Sonnet, не сложнее.

### Маркеры модели → все резолвятся в Opus 4.8

`[[OPUS]]`, `[[FABLE]]` и `[[DEEP-THINK]]` остаются валидными триггерами premium-уровня, но все резолвятся в **`claude-opus-4-8`**. Старая строка `claude-fable-5` **мертва** (404 на подписке текущего `claude.exe`, убрана 2026-06-13) — в коде/конфиге её нет нигде, кроме комментариев, документирующих замену (например fallback в `driver/40-agent-invoke.ps1:432` теперь `claude-opus-4-8`). Воркер с id `claude-fable` в пуле тоже указывает на `model: claude-opus-4-8`.

Хочешь premium Claude точечно — добавь в текст задачи `[[OPUS]]`, `[[FABLE]]` или архитектурное слово.

### Авто-эскалация модели (`lib/router.ps1`)

Поверх tiering работает `Select-PlannerModel`: `triageModel` эскалируется в `deepModel`, если
- передан флаг `Escalate` (например `timeout_retry`), **или**
- оконная success-rate триаж-модели (из `turns.jsonl`) ниже `router.minSuccess` при ≥ `router.minSamples` сэмплов за `router.windowHours`.

Дефолты: **`minSuccess = 0.5`, `minSamples = 5`, `windowHours = 24`** (`config.router`).

### Политика моделей (затраты — соблюдать строго)

- ⛔ **Никогда** `gemini-2.5-pro` (слишком дорого) — удалять из конфига, если вернётся.
- ⚠️ `gemini-3-flash` — **только резерв** (дорогой), когда основной агент недоступен/вернул пусто.
- Рутина (curator, intent-classifier, smoke) → `gemini-2.5-flash-lite` / `gemini-2.5-flash`.
- Держать `claude-opus-4-8` на deep-think / study / architectural, не на мелочь (это обеспечивает premium-guard в роутере воркеров).

### Режимы работы (`task_mode` в `state.json`)

Реальные значения состояния, которые записываются в `state.json`; намерение/режим выбирает `lib/intent.ps1` (`primary_mode`):

| `task_mode` | Что это |
|---|---|
| `normal` (он же `code`) | Обычный цикл planner ↔ coder |
| `discuss` | Диалог двух моделей (Claude ↔ Codex), `[[DEEP-THINK]]` форсит его |
| `study` | Глубокое изучение темы |
| `synthesis` | Multi-Model Decision Synthesis (depth-роутер `lib/decision-depth.ps1` направляет сюда Deep/High-Stakes и явный `discuss` при `synthesisMode.enabled = true`) |
| `research` | Claude ищет/сверяет ВНЕШНИЕ источники; тулсет `Read/Grep/Glob/WebSearch/WebFetch` **без** Bash |

**Не путать с режимами:**

- **`fast` — это НЕ `task_mode`, а оверлей skip-флагов поверх `normal`.** Fast-lane выставляет `task_mode = 'normal'` + `skip_planner`/`skip_critic` (`Set-FastLaneFlags`, `driver/00-task-session.ps1`). `effMode='fast'` в логах/телеметрии — только ярлык, не значение состояния. Гейт — `fastLane.{autoDetect,minChars}`.
- **`computer_action` («руки/лапа») тоже резолвится в `task_mode = 'normal'`** (`driver/81-loop-idle-claim.ps1:450`) — это intent desktop-fast-lane (mouse/window-control без planner/coder/critic), а не отдельное значение состояния.

> `lib/delivery-mode.ps1` — это SHADOW-классификатор, read-only, **НЕ wired** в живой драйвер; его mode-енумы не управляют реальным `task_mode` — не путать.

---

## Бэклог и жизненный цикл задач

Бэклог — это `channels/<канал>/backlog.jsonl` (append-log, сворачивается по `id`). Загрузчик — `lib/backlog.ps1`, который транзитивно подтягивает `backlog-core.ps1`, `backlog-crud.ps1`, `backlog-dedup.ps1`, `backlog-governor.ps1`, `backlog-workpack.ps1`, `backlog-state-reaper.ps1`, `backlog-autopilot.ps1`. Идея проходит путь от попадания в очередь до терминального исхода через цепочку детерминистических гейтов; статус — это всегда исход гейта или работы, а не намерение.

### Статусы идеи

| Статус | Смысл | Кто ставит |
|---|---|---|
| `new` | Сгенерирована (генератор/радар/аудит), ещё не одобрена к авто-исполнению | генераторы |
| `approved` | Допущена в очередь авто-исполнения | curator / intake-gate / оператор |
| `running` / `working` | В работе у кодера | claim |
| `done` | Завершена с реальным evidence | DONE-gate |
| `rejected` | Отклонена | curator / оператор |
| `held` | Снята с авто-исполнения, ждёт ревью | gate / reaper / оператор |
| `auto-dropped` | Детерминистически отброшена на входе (false-positive, malformed) | intake/governor gate |
| `failed` | Провалена; требует `-FailureEvidence`, иначе `outcome-ledger-block` | driver / оператор |
| `superseded` | Заменена другой задачей | планировщик / оператор |
| `cancelled` | Отменена | оператор |
| `deduped` | На входе совпала с уже известной идеей (дубль) | dedup |
| `decomposed` | Родитель, разбитый на дочерние атомы через `[[DECOMPOSED: N]]` (закрыт **без хода кодера и без DONE-gate**) или осиротевший parent от state-reaper | планировщик / reaper |
| `needs-review` | `attempts >= 5` → `Set-BacklogAttemptsExhausted` снимает с автоисполнения (`needs_review_reason='attempts-exhausted'`, `backlog-core.ps1:1532,1660`). Возврат в работу: `Set-Idea -Status approved -Reason 'operator:…'` | автоматика |
| `auto-resolved` | На claim-time `Test-IdeaStillRelevant` обнаружил, что задача уже сделана другим коммитом (`resolved_by_sha`) — закрывается без работы, считается как done в авто-статистике | claim |
| `auto-stale` | Непринятая `new`-идея старше `ideaStaleDays=14` авто-архивируется (внешние/radar исключены — ждут ручного ревью; `backlog-dedup.ps1:511-527`, `settings.ps1:49`) | гигиена |

`green`/`yellow`/`red` — это **risk-tiers** (`Get-IdeaRiskTier`), а НЕ статусы (см. ниже).

### Embedding-дедуп на входе (`Add-Idea` может вернуть null/existing)

Перед созданием идеи `lib/backlog-dedup.ps1` считает cosine-similarity эмбеддинга к уже известным идеям (порядок проверок в `backlog-dedup.ps1:74-86`):

- `>= 0.88` к существующей → `action='dedup'`, возвращается id существующей (новая НЕ создаётся);
- `>= 0.85` к недавно отклонённой → `action='rejected-recently'`, идея молча дропается (silent null);
- `0.70–0.88` → лишь помечается `similar` (advisory `semantic_similarity`), но создаётся.

Поэтому `Add-Idea` может тихо вернуть `null` или id чужой идеи — это штатно. Дедуп срабатывает даже при `from=operator`/`SkipCurator`.

### Гейты допуска (в порядке прохождения)

**1. Backlog intake-gate** (`Invoke-BacklogIntakeGate`, `lib/backlog.ps1:266` и `lib/backlog-workpack.ps1:598`). Audit/deep-audit findings больше не пишутся напрямую в `approved`. Даже `Add-Idea -SkipCurator` проходит детерминистический gate (`SkipCurator` отключает только дешёвый LLM-curator, intake не обходит). Применяется к audit-source находкам со `scope ≠ project`:

- root-cause дубль уже открытой находки → `status='deduped'` (`intake-dedup`);
- очевидный false-positive по **security-evidence правилам** (проверка против реального кода): находка только в комментарии → `auto-dropped`; нет реального dynamic-exec примитива (`Invoke-Expression` и т.п.) → `auto-dropped`; слабое/косвенное evidence секрета → `held`; реальное присваивание/использование → `allow`;
- finding без читаемого code-evidence (нет существующих файлов) → `held`;
- валидный → `approved` + `intake_gate` metadata.

**2. Второй слой — `cross_file_causal_map` hard hold** (`Test-BacklogFindingCausalMap`, `lib/backlog.ps1:224-306`). Даже если базовый gate вернул `allow`, для approved audit-source находки исход переигрывается в `held` (`reason='cross_file_causal_map required'`), ПОКА finding не несёт ВСЕ: ≥2 затронутых файла, все названы поимённо в тексте, file-roles, propagation-path, multi-layer failure-path и причинно-следственный язык. Отсекает однострочные автозаявки без сквозной причинной карты.

**3. Governor shape** (`Test-BacklogGovernorItemShape`, `lib/backlog-governor.ps1:188`). Для статусов `approved`/`running`/`working` требует только ИДЕНТИЧНОСТЬ: `id` + (`title` | `text` | `task`). Поля `touch_set`/`root_cause_key` — это координационные поля workpack, назначаемые **при claim**, а НЕ предусловия существования (hotfix 2026-06-06: требование их на входе дропало каждый обычный `Add-Idea`/operator-атом как `invalid-shape`). Невалидная форма → `auto-dropped`.

**4. Claim / control-plane gate** (`Test-BacklogApprovedItemClaimable`, `lib/backlog-core.ps1:1516-1575`). Если задача трогает control-plane моста (`Test-IdeaTouchesControlPlane`: `driver*.ps1`, `server`/`supervisor`/`watchdog`/`canary.ps1`, `lib/backlog*.ps1`, `lib/parallel|circuit-breaker|policy.ps1`, `control/`), то claimable **только** при одном из:

- валидный блок `bridge_self_admission` (`reason='bridge-self-admission'`); либо
- **тег `operator`** в `tags` (НЕ поле `from`!) → `reason='operator'`.

Иначе `claimable=$false; reason='control-plane-blocked'` — задача застрянет в `approved` навсегда. **Заводя операторскую control-plane задачу, всегда добавляй `tags: ["operator"]`.** Исключение: project-autopilot coordinator/planner проверяется по тексту, а его атомы (`tag atom`) — по файлам (`Test-ItemFilesHitControlPlane`), т.к. инструктивный текст планировщика штатно упоминает control-plane слова.

**5. Frontier touch-overlap** (workpack ready-frontier scheduler, `Get-NextBacklogWorkpackBatch`). Packer группирует независимые approved-задачи в batch при условии ≥2 задач с **разными** `workpack_conflict_group` (`file:<путь>`) и **непересекающимся** touch-set. Explicit `depends_on` обязан указывать на `done`/`auto-resolved` slug; атомы с незакрытыми зависимостями ждут, но НЕ блокируют независимые ready-атомы; heuristic `foundation` без явных deps остаётся serial-барьером. Чтобы задачи шли параллельно — у каждой свой `conflict_group` = свой целевой файл. Драйвер пишет в чат телеметрию фронта (`selected`, `ready/eligible`, `deps`, `barrier`, `conflicts`).

### Risk-tiers и selfExecuteTier

`Get-IdeaRiskTier` (`backlog-core.ps1:2735-2763`) классифицирует идею:

- **`red`** — security/необратимое/деньги, внешний источник (radar/web), правка собственного контура (`Test-IdeaTouchesControlPlane`), либо пустой текст. **`red` никогда не авто-исполняется** — только ручное одобрение.
- **`green`** — узкий обратимый скоуп (доки/комменты/линт/тексты).
- **`yellow`** — реальное изменение кода (дефолт, когда не green и не red).

Оператор выставляет дисковую ручку `selfExecuteTier` (`settings.json`): `off` / `shadow` (логирует, не делает) / `green` (только green-идеи) / `yellow` (green+yellow). Авто-claim берёт идею, только если её tier **внутри** диска (`backlog-core.ps1:2706`): диск `green` → только `green`; диск `yellow` → `green` или `yellow`. Так `green`-диск никогда не запустит `yellow`-идею, а очередь не клинит на out-of-dial задаче впереди.

### Project Autopilot и `[[DECOMPOSED: N]]`

Для каналов с project binding (`channels/<slug>/channel.json`, не `main`) очередь пополняется не вручную, а автопилотом (`lib/backlog-autopilot.ps1`). Запуск, когда: backlog pressure низкий (нет runnable `approved`/`running` и нет открытых autopilot-атомов), project repo clean, истёк cooldown, **и план утверждён** (`Set-ProjectPlanApproved` — Discuss-First gate, без него атомы не генерятся). Дефолты (`lib/settings.ps1`, override в `settings.json`): `projectAutopilotEnabled=true`, `projectAutopilotCooldownMinutes=5`, `projectAutopilotMaxTasksPerBatch=12`, `projectAutopilotEmptyCoordinatorLimit=3`.

Coordinator/planner возвращает атомы внутри маркера, driver их добавляет как `approved` project tasks:

```text
[[PROJECT_BACKLOG]]
[ {"slug":"...","title":"...","task":"...","files":["..."],"depends_on":[],"severity":"normal"} ]
[[/PROJECT_BACKLOG]]
```

**Самопауза:** если 3 координатора подряд (`emptyCoordinatorLimit`) не вернули ни одного атома (план исчерпан), автопилот сам встаёт на паузу (`project-autopilot.last.json` → `paused=true` + сообщение в чат); снять = расширить PROJECT_PLAN и заново вызвать `Set-ProjectPlanApproved` (re-approval обнуляет streak и хеширует доки заново).

**`[[DECOMPOSED: N]]`** (`driver/86-loop-completion-checks.ps1:140-217`) — когда планировщик разбивает крупный atom на N дочерних, он эмитит их через `[[PROJECT_BACKLOG]]` и отдельной строкой `[[DECOMPOSED: N атомов]]`. Драйвер ловит маркер, ставит родителю `status='decomposed'` и закрывает его **без хода кодера и без DONE-gate** — работа делегирована детям. Это штатный путь «разложить на атомы», не ошибка.

### Восстановление зависших задач (state-reaper)

`lib/backlog-state-reaper.ps1` (zombie-recovery): зависшую `running`/`working`-задачу без живого `agent_pid`, без свежего worker-heartbeat (старше `HeartbeatMaxAgeSeconds=900`) и без активного runtime-state reaper авто-возвращает в `approved`, чтобы она переклеймилась. После `MaxZombieRetries=2` смертей подряд (`recoveryCount > MaxZombieRetries`) задача уходит в `held` на ревью (`backlog-state-reaper.ps1:308-372`).

**Переоткрытие статуса** (`Set-Idea`): терминальную задачу (`done`/`rejected`) нельзя понизить в нетерминальный статус без `-Reason` вида `operator:…` или `reaper:…` (защита от случайного сброса исхода); `Set-Idea -Status failed` требует `-FailureEvidence`, иначе `outcome-ledger-block`. `Add-Idea` дедупит по тексту даже при `from=operator`/`SkipCurator`, а `Set-Idea` НЕ меняет `tags` (только status/text/attempts/reason).

---

## Синтез решений и роутер глубины

Decision Synthesis заменяет старый ролевой DISCUSS (одна модель ПРЕДЛАГАЕТ → вторая ОБЯЗАНА КРИТИКОВАТЬ → третья КОМПРОМИСС). Новый принцип: не «какая модель права», а «какие decision-атомы взять» — артефакты вместо чата, атомы решений вместо целых ответов, точечная (не обязательная) критика, рубрикой оцениваемый синтез, многоуровневая глубина, red-team + Decision Record. Включается флагом `config.json → synthesisMode.enabled` (сейчас `true`).

### Роутер глубины (`lib/decision-depth.ps1`, без LLM)

Чисто детерминированный keyword-классификатор (никогда не зовёт LLM/gemini). `Get-SynthesisDepthDecision` возвращает один из четырёх уровней; `Get-SynthesisRouteDecision` решает, уходит ли задача в `task_mode='synthesis'`. Порядок проверок строгий — первое срабатывание выигрывает:

| # | Условие | Глубина |
|---|---------|---------|
| 1 | Явный маркер `[[HIGH-STAKES]]` в тексте | **High-Stakes** |
| 2 | `risk=high\|critical` (явный `-Risk` или `Intent.risk`) **или** high-stakes-домен (см. подавление) | **High-Stakes** |
| 3 (fast-path) | `Intent.primary_mode='normal'` и `confidence ≥ 0.7` | **Simple** (если complexity trivial/simple), иначе **Standard** |
| 4 (code-verb backstop) | есть code-глагол (`реализу/напиш/почини/implement/build/fix/...`) и НЕТ discuss-глагола | **Standard** |
| 5 | discuss/архитектура/дизайн/подход/стратегия (`обсуди/discuss/architect/design/...`) | **Deep** |
| 6 | complexity trivial/simple, или текст < 40 симв., или `screenshot/скрин/one-liner` | **Simple** |
| 7 | дефолт | **Standard** |

Параллельно `Get-SynthesisTaskType` детерминированно проставляет `judge_task_type` (`bugfix/refactor/infra/research/creative/architecture`, дефолт `architecture`) — он выбирает модель судьи на стадии Judge.

**Тонкости (чтобы не удивляться, почему задача не ушла в Deep):**
- **fast-path** (шаг 3): уверенный intent=normal гасит Deep даже если текст «name-dropнул» архитектуру/дизайн — одно упоминание слова Deep не форсит.
- **code-verb backstop** (шаг 4): императивная задача «сделай X» → Standard, даже с архитектурными существительными в тексте; настоящее «обсуди/выбери между» всё ещё падает в Deep на шаге 5.
- **High-Stakes-подавление** (шаг 2, фикс 2026-06-19): ключевые слова `secret/watchdog/supervisor/circuit-breaker/control-plane/security/медицин/финанс/деньг/необратим/...` НЕ форсят High-Stakes, если задача мелкая (`complexity` trivial/simple или текст < 160 симв.) или это plan-refinement-discuss. Иначе мелкая control-plane-задача зря гонялась через весь пайплайн и падала на restart-cap, заклинивая main-канал. Явный `risk=high/critical` подавление игнорирует — всегда High-Stakes.
- **plan-refinement-discuss** (`уточни/доработай/refine` + `atom/backlog/plan/spec/self-improve`): остаётся на Standard и при `ExplicitDiscuss`, не уходит в Deep.

**Маршрутизация в synthesis** (`Get-SynthesisRouteDecision`, вызывается из `driver/81-loop-idle-claim.ps1`): даже при `enabled=true` приоритетные guard-ы НЕ пускают задачу в synthesis — `fast-lane`, `normal override`, `computer-action`, `study mode`, `low complexity`. В synthesis уходят: явный deep-think маркер, явный discuss-запрос, и smart-router `depth ∈ {Deep, High-Stakes}`. `state.json` получает `task_mode='synthesis'` + `synthesis_depth`/`synthesis_decision_id`.

### Пайплайн (`lib/decision-synthesis.ps1`, `Invoke-SynthesisPipeline`)

Stateless artifact-движок: каждая стадия пишет свой JSON-чекпойнт в `channels/<slug>/decisions/<id>/` (диск = естественные чекпойнты, поэтому Deep-прогон никогда не один гигантский незакоммиченный таск). Запускается через `Invoke-SynthesisDriverTurn` из `driver/83-loop-agent-turn.ps1`. **Сбой любой стадии не бросает исключение** — пайплайн ловит его и возвращает запись с `needs_operator=$true` (+`pipeline_error`).

Глубина определяет, какие стадии бегут:

| Стадия | Файл-артефакт | Модель | Simple | Standard | Deep / High-Stakes |
|--------|---------------|--------|:---:|:---:|:---:|
| 1. TaskContract | `task_contract.json` | gemini-2.5-flash | ✓ | ✓ | ✓ |
| Simple-record | `final_decision_record.json` | gemini-2.5-flash | ✓ (и стоп) | | |
| 2. Proposals (3 «слепых», без ролей) | `proposal_{A,B,C}.json` | A=Codex `gpt-5.5:xhigh` (read-only), B=Claude `claude-opus-4-8:xhigh`, C=`deepseek-v4-pro` | | ✓ | ✓ |
| 3. Normalize → DecisionAtoms | `decision_atoms.json` | gemini-2.5-flash | | ✓ | ✓ |
| 4. ConflictMatrix | `conflict_matrix.json` | детерминир. консенсус (атом цитируется ≥2 пропозерами) + 1 дешёвый вызов на семантич. конфликты | | | ✓ |
| 5. CrossReview (только конфликтные/low-conf атомы) | `conflict_matrix.json.reviews[]` | gemini-2.5-flash | | | ✓ |
| 6. Judge (модель по `task_type`) | `judge_synthesis.json` | architecture→Claude; bugfix/refactor/infra→Codex; research/creative→gemini | | ✓ | ✓ |
| 7. MicroDebate (только impact=high + нерешённый verdict; cap **3 темы × 2 раунда**) | `micro_debate.json` | gemini-2.5-flash | | | ✓ |
| 8. FinalV2 (свернуть дебаты) | `final_decision_record.json` | Claude | | ✓ | ✓ |
| 9. RedTeam (попытаться сломать решение) | `final_decision_record.json` (`red_team_findings`) | Claude | | | ✓ |

Замечания по стадиям:
- **Standard** = contract → proposals → normalize → judge → FinalV2 (БЕЗ matrix/review/debate/red-team). **Simple** = contract → один дешёвый best-effort record. **Deep и High-Stakes гоняют ВСЕ стадии** одинаково — разница только в финальном гейте (ниже).
- **MicroDebate** тема допустима только если конфликт имеет `impact=high` И судья оставил involved-атом «нерешённым» (verdict ≠ `accept`); кап `MaxTopics=3`, `MaxRounds=2`.
- **RedTeam**: если есть finding `severity=high` → один re-judge + re-fold; если решение всё равно ломается → `needs_operator=$true` (+`red_team_rejudged`).
- **Rubric (Judge)**: correctness .25, feasibility .20, impact .20, simplicity .15, risk_reduction .10, specificity .10; штрафы за unsupported_complexity / contradiction / hidden_dependency / vagueness. Критика опциональна; возражение требует severity+why+fix+cost.

### High-Stakes → needs_operator (человеческий гейт)

После RedTeam, если `depth='High-Stakes'`, `Invoke-SynthesisPipeline` принудительно ставит `needs_operator=$true` (`Set-SynthRecordNeedsOperator`) — **всегда**, безусловно. Источники `needs_operator`: (1) High-Stakes-глубина; (2) high-severity red-team break; (3) любой pipeline-error.

`Format-SynthesisDecisionRecordForDriver` транслирует это в ответ драйверу:
- `needs_operator=true` → `NEEDS-OPERATOR` + `DISCUSS-ONLY` + `STATUS: DONE` — **код НЕ пишется автоматически**, решение ждёт оператора.
- иначе, если есть непустой `implementation_plan` → `STATUS: CONTINUE`, Codex реализует принятый Decision Record (через штатные verify/critic гейты в `driver/86-loop-completion-checks.ps1`). `Test-SynthesisImplementationRequested`: `needs_operator` — единственный гейт, блокирующий авто-реализацию (фикс false-DONE 2026-06-21: непустой план сам по себе доказывает «нужен код», независимо от формулировки задачи).
- иначе → `DISCUSS-ONLY` / `STATUS: DONE`.

Финальный Decision Record также сохраняется в durable-журнал `decisions/<ts>_decision-synthesis-dec-*.md` (`Save-Decision`) — это recall-поверхность для будущих задач.

### Config-ключи: живые vs инертные

Код реально читает только: `enabled`, `claudeModel` (`claude-opus-4-8`), `cheapModel` (`gemini-2.5-flash`), `proposerModels.A/B/C`, `judgeByTaskType.*`. Ключи `defaultDepth`, `maxDebateTopics`, `maxDebateRounds`, `rubricWeights.*`, `promoteAfterShadowRuns` присутствуют в `config.json`, но **инертны** — соответствующие значения (глубина, капы дебатов 3×2, веса рубрики) захардкожены в `lib/decision-synthesis.ps1`/`lib/decision-depth.ps1`; правка их в config ни на что не влияет.

---

## Аудит и Доктор

Три независимых контура надёжности: **Auditor** (read-only сенсор здоровья), **deep-audit** (ночной поиск дефектов кода) и **Doctor** (авто-починка упавших задач). Auditor только наблюдает и классифицирует — чинит исключительно Doctor; deep-audit только заводит находки в backlog.

### Auditor (`lib/auditor.ps1`)

Read-only health-сенсор. Запускается из idle-тика драйвера через `Start-AuditorIfDue` → `Should-RunAuditor` → `Invoke-Auditor`, не чаще `auditor.intervalMin` (15 мин), под file-lock `control/auditor.lock` (stale ≥5 мин). Не запускается, если `status ≠ idle` или `doctor_active`. Маркер последнего прогона — `control/auditor.last`, лог — `control/auditor.log`. Конфиг (`config.json/auditor`):

| Ключ | Значение | Назначение |
|---|---|---|
| `enabled` | `true` | вкл/выкл |
| `intervalMin` | `15` | период опроса |
| `model` | `gemini-2.5-flash-lite` | дешёвая модель-классификатор |
| `doctorRecidivismHours` | `24` | окно подсчёта активаций Doctor |
| `doctorRecidivismMax` | `5` | порог рецидива Doctor (in-code fallback-дефолт — `2`) |

**Детерминистические триггеры** (`Test-AuditorTriggers`) — собираются из снапшота state/git/turns БЕЗ LLM; LLM зовётся только если триггер есть:

| Триггер | Условие |
|---|---|
| `wait_state_stuck` | `working` + heartbeat свежий, но `lastSeq` не двигался ≥5 мин (сначала пробует дешёвый `Recover-ZombieJobs`, триггер — только если не помогло) |
| `empty_reply_streak` | ≥2 подряд пустых ответа агента |
| `same_task_too_long` | `task_turn > 30` при свежем heartbeat (кроме DISCUSS) |
| `critic_pingpong` | `critic_retry_count ≥ criticMaxRetries` (=3) |
| `commit_famine` | задача активна >30 мин, дерево грязное, последний коммит >30 мин — **с поправкой на прогресс**: живой агент / `paused` / свежий seq-прогресс (<10 мин, repeats<3) НЕ считаются голодом |
| `stale_audit` | отчёт аудита старше 30ч при свежей активности launch-ledger |
| `working_tree_drift` | >500 изменённых строк в дереве |
| `restart_frequency` | >4 рестартов супервизора за 20 мин |
| `doctor_recidivism` | ≥`doctorRecidivismMax` активаций Doctor за окно **И** Doctor активен прямо сейчас |

**5-классовый вердикт** (LLM, `Invoke-AuditorLLM` → `Dispatch-AuditorVerdict`):

| Класс | Действие |
|---|---|
| `normal` | ничего, только лог |
| `transient` | временный шум — Doctor НЕ зовётся |
| `hung` | **единственный класс, активирующий Doctor** (`Activate-Doctor -Reason auditor:<trigger>`) |
| `corrupted_state` | **только уведомление в чат** (`⚠ Auditor: corrupted_state…`), авто-починки нет |
| `unsolvable` | **только уведомление в чат**; повторное гасится файлом `control/auditor.suppressed.json` |

Дедуп повторных срабатываний: на канал в state пишется `auditor.suppressed_hashes` (hash по task_key+trigger+нормализованный detail), глобально для `unsolvable` — отдельный файл. `hung` дополнительно гасится `doctorRecidivismMax`: при превышении класс понижается до `unsolvable` (не звать Doctor по кругу). Вердикты пишутся в векторную память (`auditor-verdict`) для recall.

### Deep-audit (ночной аудит)

Запускается планировщиком `Start-AuditIfDue` (`driver/10-maintenance.ps1`) в ночном окне (config-driven `audit.windowStartHour`/`windowEndHour` = **1:00–6:00**) — раз за ОККУРРЕНЦИЮ окна (привязка к `winStart`, не sliding `floorHours`; `floorHours=20` — вторичный same-window guard), либо вручную. Идёт двумя фазами:
1. **Статика** (`tools/audit.ps1`) — security/functional грепы + DeepSeek.
2. **Многоагентный deep-audit** (`tools/deep-audit.ps1`) — N параллельных срезов, каждый со своей моделью из `config.audit.deepAgents`: `security-model`/`architecture-model` → `deepseek-v4-pro`, `functional-model` → `gemini-2.5-flash`, `reliability-model`/`dependency-model` → `deepseek-v4-flash`. Тяжёлая фаза под watchdog-таймаутом; результаты сливаются.

**Findings-ledger** (`audit/findings-ledger.jsonl`, `Update-FindingsLedger`) — машинный учёт находок с dedup по `rootCauseKey`. Лайфцикл состояний:

| Состояние | Кто ставит | Поведение |
|---|---|---|
| `new` | первая встреча root-cause | попадает в отчёт |
| `open` | вторая встреча (`new` → `open`) | известна; non-critical **вырезается** из отчёта (`findings_ledger_suppressed_count`), critical показывается всегда |
| `fixed` / `suppressed` | вне аудита (код только читает) | — |
| `regressed` | повторное появление `fixed`/`suppressed` находки | снова в отчёт |

Находки не пишутся в backlog напрямую: даже `Add-Idea -SkipCurator` проходит детерминистический intake-gate (root-cause-дубли, security без реального dynamic-exec примитива → `auto-dropped`, слабое evidence → `held`). `usefulness.jsonl` оценивает полезность аудита (action_rate + resolved_signal_delta + incident_capture).

### Doctor (`lib/doctor.ps1`)

Авто-ремонт при жёстком сбое задачи: `Activate-Doctor` приостанавливает текущую задачу в `held_task`, ставит `doctor_active=true`, обнуляет счётчики, и следующая итерация драйвера прогоняет диагностический промпт (`Get-DoctorTaskText`, `mode=doctor`) через обычный planner→coder→critic пайплайн. Лог — `control/doctor.log`, события — `metrics.jsonl` (`doctor_event`). Doctor сам **не трогает** `watchdog.ps1`, `supervisor.ps1`, `.git/*`, `secrets.json`, `auth.json` (ограничение в промпте).

**Триггеры активации** (источник → reason):

| Источник | Reason |
|---|---|
| Таймаут planner/coder (`driver/40`→`83-loop-agent-turn.ps1`) | `planner_timeout` / `planner_zero_output_timeout` / `planner_silent_exit` |
| Watchdog-rollback (`repair.signal` → `driver/80-loop-preflight.ps1`) | `watchdog_rollback` / `storm_*` |
| Loop-детектор (`driver/85`) | `loop_detected` (3× идентичный progress-fingerprint) |
| Stagnation-детектор (`driver/85`) | `no_progress_loop` (`no_progress_count ≥ 4`) |
| Restart-loop (`Test-RestartLoop`, `driver/80`) | `restart_loop` (≥3 рестарта/5мин, 0 ok-turns) |
| Auditor `hung` | `auditor:<trigger>` (в т.ч. `commit_famine`, `critic_pingpong`) |

**Лимиты** (`config.json/doctor`, `Get-DoctorConfigInt`):
- `maxRepairAttempts = 3` (диапазон 1–5) — repair-попытки на одну held-задачу; владелец счётчика — стабильный `doctor_repair_task_id`.
- `maxRestartResumes = 3` (диапазон 2–10) — резюме Doctor после рестартов драйвера (рестарт-резюме НЕ считается repair-попыткой).

При исчерпании лимита `Abort-Doctor` **ре-кьюит** backlog-задачу в статус `held` с reason `doctor-exhausted` (`Set-Idea`) — конвейер свободен, решение за оператором; шлёт `need_you` push. Fallback (нет backlog-id / `Set-Idea` упал): держит `held_task` в state. Успех — `Complete-Doctor`: восстанавливает `held_task` как `current_task`, чистит Doctor-state. `ESCALATE`-маркер в ответе Doctor → уведомление оператору без починки.

**Спец-кейсы:**
- `commit_famine`: если held-задача УЖЕ готова (есть свежий коммит / QA PASS / pass-SHA — `Test-DoctorHeldWorkReady`), Doctor закрывает её как `done` без повторной диагностики (`Complete-Doctor -ResolveHeldDone`, reason `commit_famine_work_ready`).
- `critic_pingpong`: `Invoke-DoctorCriticPingPongAutoCommit` — если есть незакоммиченный diff и все `.ps1` проходят `ParseFile`, Doctor сам коммитит (`repair(uncommitted-diff)…`) и возобновляет задачу **без Codex**.

### Failed-task salvage (`Invoke-FailedTaskSalvage`)

Вызывается из `driver/60-startup.ps1` после пометки задачи FAILED. Часто упавшая задача оставляет ВАЛИДНЫЙ хвост (умерла оркестрация, а не код), который блокирует dirty-tree-guard. Гейт — **PARSE** (boot-safe, smoke — лишь advisory-сигнал), плюс проверка critic-вердикта окна:
- Хвост парсится и critic не «serious» → авто-коммит `[salvage] спасён хвост failed-задачи…`, дерево чистое, автономия разблокирована.
- Parse-broken / critic-serious → `git stash push -u` ТОЛЬКО этих файлов (обратимо `git stash pop`) + page оператору; при critic-debt заводится follow-up в backlog.

Salvage никогда не разрушает работу и не трогает runtime/state-файлы (`channels/`, `control/`, `turns.jsonl`, `decisions/` и т.п. исключены).

> **Связка с watchdog:** жёсткие сбои движка watchdog отдаёт Doctor'у мягко — через `control/repair.signal` (storm-detector: suspect → grace/self-heal → Doctor → если не вылечил, rollback + page). Git-rollback применяется только при провально-сломанном коде и ВСЕГДА создаёт safety-ветку `prerollback/<ts>`. Оператор глушит весь watchdog файлом `<USERPROFILE>\.bridge-private\watchdog.pause`.

---

## Надёжность и аварийное восстановление

Мост защищён тремя независимыми сторожами (supervisor, watchdog, circuit-breaker) и несколькими ограничителями рестартов. Они работают по принципу «живой мост с предупреждением лучше мёртвого», но при детерминистичных поломках уходят в жёсткую заморозку и ждут оператора. Ниже — что именно срабатывает, по каким порогам и как восстанавливать вручную.

### Карта защитных слоёв

| Слой | Файл | Что ловит | Реакция |
|---|---|---|---|
| **Supervisor** | `supervisor.ps1` (elevated, Task Scheduler `\ClaudeCodexBridge`) | падения server/driver; раздутые процессы; зависшие (hung) процессы | recycle (kill+respawn), zombie-reaper, hung-detection |
| **Watchdog** | `watchdog.ps1` (скрытый, `-WindowStyle Hidden`) | API не отвечает / мёртвый heartbeat / шторм одинаковых ошибок | мягкий рестарт (`restart.flag`) → git-rollback на `stable` |
| **Circuit-breaker** | `lib/circuit-breaker.ps1` | штормы рестартов (5/30мин) | cooldown 15 мин или **HARD-FREEZE** |
| **System Sentinel** | внутри `watchdog.ps1` | живой драйвер, который рестарт-лупит/спамит одну ошибку | grace ~8мин → Doctor → rollback+page |

### Watchdog (smoke + rollback)

Watchdog судит о здоровье по heartbeat-у драйвера и доступности API. Логика лестничная (пороги в `watchdog.ps1:49-53`, цикл каждые 120с):

- **API лежит + driver жив:** `apiRestartThreshold=3` проваленных проб (~6 мин) → мягкий рестарт (`control/restart.flag`).
- **API всё ещё лежит после recycle:** `apiRollbackThreshold=6` (~12 мин) → код сервера сломан → **rollback**.
- **Heartbeat драйвера протух:** `rollbackThreshold=4` (~8 мин) → движок мёртв → **rollback**.

**Rollback безопасен by-design** (`Invoke-Rollback`): перед откатом ВСЕГДА создаётся safety-ветка `prerollback/<timestamp>` на текущем HEAD, затем `git reset --hard stable` (если ref `stable` есть) или `git checkout -- .`. Закоммиченная работа не теряется — её можно достать из `prerollback/*`. Цель отката — ref **`stable`** (last-known-good).

**Promotion `stable`** (`Promote-Stable`): ref продвигается к HEAD только после `promoteMin=30` минут **непрерывного** здоровья (трекается в `control/watchdog.healthy-since`, сбрасывается на любой нездоровой пробе) **И** успешного прогона `smoke.ps1` (exit 0). Так откат всегда нацелен на реально проверенный коммит.

> Хардненинг 2026-05-25: раньше ложный rollback стёр закоммиченную работу (медленный Codex был принят за «движок сломан»). Теперь rollback бьёт только при реально мёртвом heartbeat / лежачем API, и всегда через safety-branch.

### Supervisor: zombie-reaper и hung-detection

**Zombie-reaper** (`Reap-Bloated`, `supervisor.ps1:336`) — защита от утечек памяти (исторический кейс: `/api/radar` `ConvertTo-Json -Depth 10` OOM породил powershell-зомби на 50–70 ГБ private). Считает **private**-память (не working set):

- cap **8 ГБ** (`reapBloatedMB`, default 8192) — превышение держится `reapGraceMs=60000` (60с) → kill (`/F` без `/T`, чтобы пощадить codex-детей);
- warn на **6 ГБ** (`reapWarnMB`). Здоровый powershell-моста к этим цифрам не приближается.

**Hung-detection** — убивает «зависший, но формально живой» процесс (медленный-но-живой тоже может попасть под нож; в чате это «⚠ … принудительный перезапуск»):

| Процесс | Порог | Деталь |
|---|---|---|
| **server** | `hcSrvHungLimit=3` подряд проваленных `/api/health` (интервал 30с) | kill+restart |
| **driver** | `hcDrvHungLimit=25` подряд интервалов с нулевым CPU × `hcDrvIntervalSec=60` = **~25 мин** CPU-стагнации | kill+restart |

Планка драйвера поднята до 25 мин намеренно: чанки кодера идут 10–12 мин, а штатное обслуживание (parse ~300 ps1 + smoke + gate-regression) держит loop CPU-тихим ~12–15 мин — раньше это ложно читалось как зависание.

### Circuit-breaker: cooldown и HARD-FREEZE

Окно: `maxRestarts=5` рестартов за `windowMin=30` мин → trip (config `config.json:142-146`, дубль-дефолты в `lib/circuit-breaker.ps1:11-13`). Каждый рестарт классифицируется (`parse-fail` / `state-corrupt` / `OOM` / `explicit-flag` / `task-survived-3x` / `unknown`) в `~/.bridge-runtime/restarts.jsonl`. Чистые выходы (exit 0) крахами НЕ считаются.

Режим выбирает `Get-CircuitMode`:

- **cooldown** (мягкий, обычный случай) — драйверы стоят `cooldownMin=15` мин (зажат в коридор 10–30), затем `Invoke-HealthProbe`: зелёный → resume. **Failsafe**: после 3 продлений cooldown (`~/.bridge-runtime/cb-cooldown-extensions`) — принудительный resume + эскалация оператору.
- **HARD-FREEZE** (жёсткий) — срабатывает, когда доминирующая причина **детерминистична** (`parse-fail` или `state-corrupt`) И её доля `sameSignatureRatio ≥ 0.8`. Breaker пишет **`control/cb-freeze.flag`**, блокирует ВЕСЬ старт server/driver и шлёт в чат `🛑 Circuit-breaker … Мост заморожен, жду оператора`. **Это нельзя пересидеть — выход только ручной** (см. recovery ниже).

> Бывший deadlock (исправлен 2026-05-30): `state-unreadable` больше НЕ фатален для probe (server пересоздаёт state сам), probe сканирует только core-`.ps1` (top + `lib` + `tools`, без рекурсии в canary/sandbox); resume блокирует лишь реальный parse-fail в core-файле или пропавший bridge-root.

### Три ограничителя рестартов (не путать)

| # | Ограничитель | Где | Область | Прод-статус |
|---|---|---|---|---|
| 1 | **Circuit-breaker** | `lib/circuit-breaker.ps1` | весь процесс, окно 5/30мин | активен (cooldown / hard-freeze) |
| 2 | **Supervisor restart-limiter** | `Test-SupervisorRestartAllowed`, `lib/supervisor-restart-limit.ps1` | per-key, состояние в `~/.bridge-runtime/restart-limits.json`; подпись в логах `SUPERVISOR-RESTART-LIMIT … start suppressed` | **~выключен**: config `restartLimitMaxPerHour=1000` (cooldown 5мин) поверх код-дефолтов `10/час`, `30мин` — почти не триггерит |
| 3 | **Per-task restart-cap** | `config.taskRestartCaps`, `driver/60-startup.ps1` | трёх-осевой потолок на ОДНУ задачу | активен |

Per-task потолок — три **разных** оси (формулировка «3x» вводит в заблуждение): `apply=6` (доверенные apply-рестарты), `hard=3` (нетрасты/крэши), `total=8`. По превышению любой оси задача помечается `failed`, мост идёт дальше.

### Restart-coalescer (анти-шторм)

Двухуровневый, в `driver/80-loop-preflight.ps1` (main-канал). Гасит проблему «пачка self-dev правок ставит `restart.flag` на каждую правку → 18 рестартов/30мин»:

- **Пока задача РАБОТАЕТ** (`$rcBusy`: status working/coding + `current_task` + `active_jobs`) → `restart.flag` откладывается в `control/restart.deferred`. Медленный Codex безопасен — рестарта нет.
- **Между задачами — решение по ПЛАНУ, не по таймеру:** отложенный рестарт держится, пока в плане есть работа (`active_jobs` ИЛИ claimable-бэклог при автономии); срабатывает только когда план опустел. Таймеры — только failsafe: 300с штатно, жёсткий потолок отсрочки 600с, абсолютный completion-backstop 1800с. Активный deep-think discuss дополнительно удерживает рестарт.

Итог: пачка правок схлопывается в **один** рестарт после последней задачи.

### Рубильники и ручное восстановление

**РУБИЛЬНИК ВОТЧДОГА** — `~/.bridge-private/watchdog.pause` (`watchdog.ps1:47,378`). Пока файл есть, watchdog НЕ делает ничего. **Только этот защищённый путь читается; легаси `control/watchdog.pause` мёртв** (`watchdog.ps1:36` — намеренно не проверяется). Снять = удалить файл.

```powershell
$priv="$env:USERPROFILE\.bridge-private"; New-Item -ItemType Directory $priv -Force | Out-Null
New-Item -ItemType File (Join-Path $priv 'watchdog.pause') -Force | Out-Null   # снять = удалить файл
```

**Выход из HARD-FREEZE** — удалить флаг (причину глянь внутри файла), при необходимости почистить окно рестартов:

```powershell
Remove-Item 'C:\Users\rafie\OneDrive\Documents\bridge\control\cb-freeze.flag' -Force
```

**Ложный cooldown** (драйверы стоят, в логах «Circuit-breaker cooldown») — очистить окно рестартов:

```powershell
$rf='C:\Users\rafie\.bridge-runtime\restarts.jsonl'; Move-Item $rf "$rf.bak" -Force; New-Item -ItemType File $rf | Out-Null
```

**Полный чистый рестарт** (deadlock / storm / завис): убить supervisor (НЕ watchdog!) и server/driver → сбросить окно breaker + флаги (`restart.flag`, `restart.deferred`, `runtime/codex.lock`, `cb-cooldown-extensions`) → при порче state сбросить `channels/*/state.json` в `idle` → поднять через autostart-задачу:

```powershell
schtasks /end /tn "ClaudeCodexBridge"; Start-Sleep 2; schtasks /run /tn "ClaudeCodexBridge"
```

После recovery подожди 45–60с и убедись: API жив (401/200 = жив), `restarts.jsonl` НЕ растёт (иначе server крашится на старте — ищи parse-fail в core-`.ps1`), `state.json` свежеет. Подробный пошаговый сценарий — в MONITORING_RUNBOOK §5.

> Грабли восстановления: `schtasks /run` и `/end` безопасны (UAC не требуют); `schtasks /change` и прочие elevated-операции **в фоне зависают** на UAC-промпте. Поднимать мост только через autostart-задачу, НЕ через вложенный скрытый `powershell -Command "… Start-Process … -Hidden -Bypass …"` — Defender блокирует это как сигнатуру malware (`EPERM: uv_spawn`).

---

## Операции (управление мостом и командой)

Раздел для оператора: как запускать/останавливать мост, управлять командой из 20 воркеров, заводить задачи и утверждать планы проектов. Все пути относительно корня моста `C:\Users\rafie\OneDrive\Documents\bridge` (далее `$bridge`).

### Запуск / остановка / перезапуск

Мост поднимается автоматически при старте Windows через Task Scheduler (задача **`ClaudeCodexBridge`**, elevated → `supervisor.ps1`). После перезагрузки возобновляет прерванную задачу («♻ Мост перезапущен — возобновляю…»).

| Действие | Команда |
|---|---|
| Перезапустить целиком (правильный способ) | `Stop-ScheduledTask -TaskName 'ClaudeCodexBridge'; Start-Sleep 3; Start-ScheduledTask -TaskName 'ClaudeCodexBridge'` |
| Применить правку `.ps1` без полного рестарта (graceful) | `Set-Content "$bridge\control\restart.flag" '1' -Encoding ASCII` |
| Полная остановка | `Stop-ScheduledTask -TaskName 'ClaudeCodexBridge'` |
| Пауза/стоп текущей задачи извне | `POST http://127.0.0.1:8787/api/stop?channel=<slug>` (ставит `abort=true` + убивает agent-процесс) |

**Про `restart.flag`:** supervisor (`$flagRestart`) подхватывает флаг и перезапускает драйверы, **когда канал освободится**. Ставить только когда нет активных jobs и живого агента. Не делать серию рестартов подряд — для зависшей-на-ревью задачи достаточно одного мягкого флага (driver закроет её как `COVERED`).

### Управление командой (config.json → parallel.workers)

Команда — пул из 20 воркеров, `parallel.maxStreams = 20`. Реально параллелятся ровно столько, сколько НЕЗАВИСИМЫХ задач в batch (непересекающиеся touch-set). Машина тянет ~20 потоков (CPU 6–16 %).

| Воркеры | CLI / модель | strength | cost | назначение |
|---|---|---|---|---|
| `codex-xhigh` | codex `gpt-5.5` (xhigh) | 5 | 5 | самое сложное, backend/scripts |
| `codex-high` ×3 | codex `gpt-5.5` (high) | 4 | 4 | сложное, любой домен |
| `codex-medium` ×3 | codex `gpt-5.5` (medium) | 3 | 3 | средние |
| `codex-alt` ×2 | codex `gpt-5.4` | 3 | 2 | дешевле, запас |
| `codex-specialist` ×2 | codex `gpt-5.3-codex` | 3 | 3 | код-специфика |
| `claude-sonnet` ×3 | claude `sonnet` | 3 | 3 | frontend/docs/config |
| **`claude-fable` ×2** | **`claude-opus-4-8`** | **5** | **5** | только architectural/deep-think |
| `deepseek-pro` ×2 | deepseek `v4-pro` | 2 | 2 | дешёвый ⇒ только simple |
| `gemini-flash` ×2 | gemini `2.5-flash` | 2 | 1 | дешёвый/быстрый ⇒ только simple |

**Масштабирование:** добавить/убрать записи в `parallel.workers` (дублируй `id-2`, `id-3`), подкрутить `maxStreams` → `restart.flag`. Новый воркер: запись `{id, cli, model, reasoning?, strength, cost, speed, domains[]}`; CLI должен быть в реестре `lib/parallel.ps1` (codex/claude/gemini/deepseek).

**Роутинг (`Select-WorkerForStream`, `lib/parallel.ps1`):** сложность определяется из текста (`Get-TaskComplexityHeuristic`), порог силы `complexityFloor` = **simple→2, moderate→3, complex→4, architectural→5**; затем совпадение `domains`; **premium-guard** — `claude-fable`/opus берётся ТОЛЬКО на `architectural` (или маркер `[[FABLE]]`/`[[OPUS]]`); сортировка кандидатов «дешевле, потом быстрее». Форсировать: `worker: codex-xhigh` или `Complexity: complex` в тексте задачи.

### Модель-политика и стоимость (соблюдать!)

- ⛔ **НИКОГДА `gemini-2.5-pro`** (слишком дорогой) — удалять из конфига.
- ⚠️ `gemini-3-flash` — только резерв.
- Рутина (curator, intent-classifier, smoke) → `gemini-2.5-flash-lite` / `gemini-2.5-flash`.
- `claude-opus-4-8` (id `claude-fable`) — держать на architectural/deep-think (это и обеспечивает premium-guard). Основная масса — codex (prepaid).
- **Учёт:** `usage.jsonl` логирует каждый вызов — `kind=prepaid` (codex/claude по подписке, $0) или `paid` (deepseek/gemini API, `cost_usd`); сводка — `Get-UsageSummary`.
- **`config.usage.dailyCapUsd`** — потолок paid-расхода за 24 ч; **сейчас `0` = выключен**. Превышение лишь краснит cost-строку в pulse и сигналит `usage.dailyCapUsd exceeded` — это предупреждение, **не стоп**.

### Завести задачу

| Способ | Когда / как |
|---|---|
| **A. Чат пульта** | мелочи: мост сам решает обсудить или сразу делать |
| **B. Discuss-First** | фичи/проекты — основной флоу (см. соответствующий раздел) |
| **C. Project Autopilot** | штатно для проектов: при пустом backlog + чистом git + утверждённом плане driver просит planner сгенерить пачку атомов в `[[PROJECT_BACKLOG]]` |
| **D. Прямой append** | аварийно: дописать в `channels\<ch>\backlog.jsonl` **под паузой** (`state.paused=true`, иначе driver затрёт) |
| **E. Operator-batch** | приоритетная пачка well-specified задач |

**⚠️ Control-plane claim-gate.** Задача, трогающая control-plane (`driver*.ps1`, `server`/`supervisor`/`watchdog`/`canary.ps1`, `lib\backlog*.ps1`, `lib\parallel|circuit-breaker|policy.ps1`, `control\`), **НЕ возьмётся автономией без тега `operator`** (именно в `tags`, не в поле `from`). Иначе `Test-BacklogApprovedItemClaimable` (`lib/backlog-core.ps1:1516`) вернёт `control-plane-blocked` и задача застрянет в `approved` навсегда. Для операторских control-plane задач всегда `-Tags @('operator', ...)` (либо валидный блок `bridge_self_admission`).

**⚠️ Смена статуса (`Set-Idea`).** Терминальную задачу (`done`/`rejected`) нельзя понизить без `-Reason` вида `operator:…`; `Set-Idea -Status failed` требует `-FailureEvidence` (иначе `outcome-ledger-block`).

### Operator-batch (приоритетная пачка)

`tools\operator-delegate.ps1` (обёртка над `Add-OperatorBatch`, `lib/backlog-core.ps1:2328`) вливает пачку задач **выше** audit/auto-идей. Каждая получает `tags:['operator','batch:<id>']`, статус `approved`, `severity=critical`, `SkipCurator`, и **клеймится первой** (operator-tier sort в `Get-NextRunnableIdea`). Возвращает `batchId` — единственная ручка для слежения за всей пачкой (`Get-OperatorBatchProgress`).

### Утверждение плана проекта (Discuss-First Ф4 → Ф5)

**Gate:** Project Autopilot НЕ генерит атомы, пока план не утверждён (защита от масштабирования неутверждённого «франкенштейна»). Утвердить:
```powershell
$bridge = 'C:\Users\rafie\OneDrive\Documents\bridge'
. "$bridge\lib\common.ps1"; . "$bridge\lib\backlog.ps1"
Set-ProjectPlanApproved -Channel '<slug>'        # снять: -Approved:$false
```
`Set-ProjectPlanApproved` определена в `lib\backlog-autopilot.ps1:1067` (подгружается транзитивно через `backlog.ps1`). Она **хеширует staged-план** — `PROJECT_BRIEF.md`, `DISCUSS_PRODUCT/UX/UI/BACKEND/QA/INTEGRATION.md`, `PROJECT_MAP.md`, `PROJECT_PLAN.md`, `.bridge/project-contract.json`; изменение любого этапа **ре-гейтит** autopilot до повторного утверждения. Самопауза: если N=`projectAutopilotEmptyCoordinatorLimit` (дефолт 3) coordinator-задач подряд вернули 0 атомов — autopilot ставит канал на паузу; снять = расширить PROJECT_PLAN + заново `Set-ProjectPlanApproved`.

Настройки автопилота (`lib/settings.ps1`): `projectAutopilotEnabled=true`, `projectAutopilotCooldownMinutes=5`, `projectAutopilotMaxTasksPerBatch=12`.

### Sandbox (уровень доступа coder)

По умолчанию coder работает в **`workspace-write`**. Карта повышенного доступа — `coder.sandboxModeByChannel` (config.json). Сейчас на **`danger-full-access`** подняты два канала: **`literary-slop-video`** (в config) и **`oko`** (через gitignored overlay `settings.json`, переживает rollback — поэтому config-only доки занижают объём elevated-доступа).

### bridge CLI и восстановление

`bridge.ps1` (+ `bridge.cmd`) — операторский диспетчер:

| Команда | Что делает |
|---|---|
| `bridge status` | живой статус одной командой (→ `tools\live-status.ps1`) |
| `bridge replay <task_id>` | сохранённые agent-вызовы задачи (→ `tools\replay-cli.ps1`; флаги `--list`, `--role`, `--turn`, `--full`) |

**Пути восстановления (важнейшие):**

- **Hard-freeze circuit-breaker** (в чате «🛑 Circuit-breaker … Мост заморожен, жду оператора»). При доминирующей детерминистичной причине рестартов (доля ≥0.8) breaker пишет `control\cb-freeze.flag` и блокирует ВЕСЬ запуск драйверов. Восстановление **только вручную**: `Remove-Item "$bridge\control\cb-freeze.flag" -Force` (предварительно глянуть причину в файле; при необходимости почистить окно рестартов `.bridge-runtime\restarts.jsonl`).
- **Ложный cooldown** (>5 крашевых рестартов / 30 мин → 15-мин cooldown): `Move-Item "$env:USERPROFILE\.bridge-runtime\restarts.jsonl" ...bak; New-Item -ItemType File ...` (очистить окно).
- **Заглушить watchdog** (ложно откатывает/перезапускает): создать kill-switch **`$env:USERPROFILE\.bridge-private\watchdog.pause`** — пока файл есть, watchdog не делает НИЧЕГО. **Легаси `control\watchdog.pause` больше НЕ читается** (`watchdog.ps1` слушает только защищённый путь в `.bridge-private`).
- **Застрявший lease** (канал в `working`, driver мёртв): в `channels\<ch>\state.json` выставить `status='idle'`, `paused=$false`, `workpack_batch_active=$false`, обновить `heartbeat` (записывать UTF-8 БЕЗ BOM).

---

## API (эндпоинты сервера :8787)

HTTP-сервер `server.ps1` (single-threaded `HttpListener`) слушает порт **8787** (`config.json` → `"port": 8787`). Пытается биндить на все интерфейсы (LAN, нужен urlacl от `setup-lan.ps1`), иначе fallback на localhost-only. Все ответы — JSON (`application/json; charset=utf-8`), если не указано иное.

### Аутентификация

Один gate `Test-Auth` (server.ps1) защищает **всё, кроме `/api/health`**. Креды читаются на старте из `auth.json` (поля `user`, `password`, опционально `token`), который резолвится через `Get-AuthPath` → `Get-PrivateFilePath` из приватного стора **вне корня моста**; путь внутри моста — лишь legacy-fallback (`lib/common-files.ps1`).

Принимаются два механизма (любой проходит):

| Механизм | Как передать | Источник |
|---|---|---|
| **Bearer-токен** | заголовок `Authorization: Bearer <token>` ИЛИ query `?token=<token>` | `auth.json.token` |
| **HTTP-Basic** | заголовок `Authorization: Basic <base64(user:password)>` | `auth.json.user` / `auth.json.password` |

При провале сервер шлёт `WWW-Authenticate: Basic realm="AI Bridge"` и **`401 Authentication required`**. Важно: `401` без кредов означает «сервер жив и требует auth», а не «сломан» — на это опираются canary/мониторинг.

### `/api/health` — единственный без auth

`GET /api/health` обрабатывается **до** `Test-Auth` (CORS `*`):
- **с кредами** — полная форма (state, git-head, память и т.д.);
- **без кредов** — урезанная: `ok`, `uptime_sec`, `heartbeat_age_sec`, `recent_error_count_24h`.

Флаг живости: **`ok = (heartbeat_age_sec < 120) AND (not paused) AND (recent_error_count_24h < 10)`**. Это основной хелсчек canary/runbook'а.

### Управление мостом

| Маршрут | Метод | Назначение |
|---|---|---|
| `/api/control` | POST | `action` ∈ `pause`/`resume`/`stop`/`kill`/`restart`. Таргетит драйвер конкретного канала через `?channel=` или `body.channel` (по умолчанию active-маркер). `kill` → `taskkill /F /T` по `agent_pid` + `abort=true`. `restart` пишет флаг `control/restart.flag` (выполняет **супервизор без UAC**, signal всем драйверам). `pause`/`resume`/`stop` ставят флаги в state. |
| `/api/stop` | POST | Выделенный стоп-рычаг (Live Task Card в TG-боте, внешние вызовы). Логика как у `action=kill`: убивает `agent_pid` + `abort=true`. Возвращает `{"ok":true,"killedPid":<pid|null>}`. Honors `?channel=`/`body.channel`. |
| `/api/archive` | POST | Архивация чата канала: старые сообщения → `conversation.archive.jsonl`, в чате остаётся `keep` последних (по умолчанию **30**). **Только когда канал idle** — иначе `{"ok":false,"reason":"busy"}` (контекст задачи не рвём). Honors `?channel=`. |
| `/api/state` | GET | Активный канал + scope-DTO: `active`, `is_bridge`, `project_root`, `scope`. |

### Сообщения и беклог

| Маршрут | Метод | Назначение |
|---|---|---|
| `/api/messages` | GET | Чтение `conversation.jsonl`; `?channel=<slug>` читает конкретный канал, минуя active-маркер. |
| `/api/say` | POST | Добавить сообщение от `user` (`text` + опц. `attachments`). Honors `?channel=`. |
| `/api/backlog/add` | POST | Новая идея (`text`, опц. `status`=`new`, `skip_curator`). Через `Add-Idea -From 'user' -Tags @('user')` (с `-SkipCurator` при `skip_curator`). Пустой `text` → `400`. Honors `?channel=`. |
| `/api/backlog/update` | POST | `Set-Idea` по `id`: меняет `status`/`text`/`reason`/`clear_auto_curator`. |
| `/api/backlog/delete` | POST | `Remove-Idea` по `id`. Honors `?channel=`. |

### Лайв-стрим и сценарии

| Маршрут | Метод | Назначение |
|---|---|---|
| `/api/live-stream` | GET (**SSE**) | `text/event-stream`, паттерн write-once-close (совместим с single-threaded listener). EventSource авто-реконнектится; `retry:3000` = 3с интервал. Полезная нагрузка: `channel`, `status` (`idle`/`working`/`paused`), `heartbeat_age_sec`, текущая задача (`current_backlog_id` → title/desc из беклога), число активных `parallel_streams`. |
| `/api/scenario/result` | POST | Браузерные сценарии (`tools/scenarios/*.js`) постят результат (`name`, `ok`, `errors`, `log`, `timings`); пишется строкой в `control/scenario-results.jsonl`. `name` обязателен (иначе `400`). Это инфраструктура функциональной верификации (реальные user-flow тесты вместо статичных скриншотов). |
| `/api/scenario/result` | GET | Поллинг результата по `?name=X` (опц. `?since=<ts>`); раннер `tools/scenario.ps1` ждёт ответ. Возвращает `{"ok":true,"result":<rec|null>}`. |
| `/api/radar/run` | POST | Запускает `techradar.ps1` (hidden процесс через `Invoke-WithChannelEnv`). Нет файла → `500`. |

### Медиа и файлы

| Маршрут | Метод | Назначение |
|---|---|---|
| `/api/stt` | POST | **Платный**: speech-to-text через Gemini (`sttModel`, дефолт `gemini-2.5-flash`) — `generativelanguage.googleapis.com/.../:generateContent`, нужен secret `geminiApiKey` (иначе `500`). Тело: `data` (base64) + `mimeType` (нормализуется: `x-m4a`→`mp4`, `mpeg`→`mp3`). Лимит аудио — `maxUploadBytes` (25 МБ); `>2×` → `413`. |
| `/api/upload` | POST | Загрузка вложения: `name`, `dataB64` (поддержка `data:`-URL), опц. `text`. Сохраняется через `Save-AttachmentBytes` + добавляется сообщение от `user`. Лимит **25 МБ** (`>` → `413`), битый base64 → `400`. |
| `/api/screenshot` | POST | Запускает `tools/screenshot.ps1` (таймаут 60с), опц. `text` (caption) и `post` (постить ли сообщение, дефолт `true`). Нет тула/ошибка → `500`. |

**Прим.:** сервер также отдаёт прочие read-роуты (`/api/status`, `/api/memory/*`, `/api/plan`, `/api/code`, `/api/settings`, `/api/channels/*`, `/api/runbook`, `/api/metrics`, `/api/audit/*`, `/api/radar`, `/api/architect/run`, `/api/brainstorm`, `/api/reflect` и др.) — все за тем же auth-gate.

---

## Справочник конфигурации

Два слоя настроек:

| Файл | В git? | Назначение |
|---|---|---|
| `config.json` | да (tracked) | общий дефолт: модели, лимиты, autonomy, audit, parallel. Сбрасывается watchdog-откатом. |
| `settings.json` | **нет** (gitignored) | runtime-оверлей оператора. **Переживает git-rollback** — поэтому хранится отдельно. |

Порядок резолва (последний выигрывает): **хардкод-дефолты (`lib/settings.ps1`) ← `config.json` ← `settings.json`**.

### Ключи config.json

| Ключ | Значение | Что делает |
|---|---|---|
| `port` | `8787` | HTTP-порт сервера/UI. |
| `planner` / `coder.agent` | `claude` / `codex` | планировщик и кодер. |
| `coder.sandboxMode` | `workspace-write` | песочница кодера; `coder.sandboxModeByChannel` — override на канал (правится прямым редактом, вне allowlist). |
| `triageModel` | `sonnet` | дешёвая модель triage (`driver.ps1:102`, дефолт `sonnet`). |
| `deepModel` | `claude-opus-4-8` | эскалация на глубокие задачи (`driver.ps1:103`, дефолт `opus`); выбирается для discuss/study/synthesis, `[[DEEP-THINK]]`/`[[FABLE]]`, слов >300, opus-keyword. |
| `sttModel` | `gemini-2.5-flash` | **живой** платный голосовой STT — реальный вызов Gemini на `/api/stt` (`server.ps1:787,790`). |
| `plannerRouting.opusKeywords` | архитектур/рефактор/мигр… | слова-триггеры эскалации planner на `deepModel`. |
| `llm.*` | deepseek-v4-flash/pro, fallback `gemini-2.5-flash` | модели сервис-ролей (gate, librarian, reflect, qa, critic, deep). |
| `router.{minSuccess:0.5,minSamples:5,windowHours:24}` | — | окно статистики эскалации triage→deep. |
| `usage.dailyCapUsd` | `0` | **живой** суточный кап расходов; `0`=выключен. При превышении operator-pulse шлёт предупреждение (`tools/operator-pulse.ps1:204`), задачи НЕ режутся жёстко. |
| `circuitBreaker.{windowMin:30,maxRestarts:5,cooldownMin:15}` | — | защита от рестарт-шторма (cooldown clamp 10–30 мин). |
| `taskRestartCaps.{apply:6,hard:3,total:8}` | — | per-task потолок рестартов. |
| `chunking.maxChunksPerTask` | `10` | макс. чанков на задачу (range 1–50). |
| `doctor.{maxRepairAttempts:3,maxRestartResumes:3}` | — | потолки лечения/резюме доктора. |
| `audit.{windowStartHour:1,windowEndHour:6,floorHours:20,deepAgents}` | — | ночное окно deep-audit + 5 модель-агентов. |
| `auditor.{enabled,intervalMin:15,model:gemini-2.5-flash-lite,doctorRecidivismMax}` | — | 15-мин сенсор аномалий. |
| `autonomy.*` | см. ниже | автономия (оверлеится `settings.json`). |
| `parallel.{enabled,maxStreams:20,workers}` | — | пул из 20+ воркеров (codex/claude/deepseek/gemini), роутинг по domain/strength. |
| `synthesisMode.*` | — | Decision Synthesis (живые ключи — ниже). |

### autonomy.* (оверлеится settings.json)

`enabled`, `requireApproval:false`, `idleQuietMinutes`, `maxAutonomousTasksPerDay`, `autonomyDisabledChannels`, `selfExecuteTier`, `maxOpenIdeas:3`, `reflectEveryHours`, `stablePromoteMinutes:30`.

- **`selfExecuteTier` = `shadow`** (дефолт, `lib/settings.ps1:41`) — ось selection-автономии для неодобренных `new`-идей: `off` → `shadow` (логирует выбор+риск, НЕ исполняет) → `green` (авто-исполняет green-tier) → `yellow`. **red-tier (security/необратимое/внешнее) НЕ авто-исполняется НИКОГДА.**
- **`maxAutonomousTasksPerDay`:** `config.json=150`, но flat-ключ в `settings.json=0` (безлимит) применяется ПОСЛЕДНИМ — **150 не авторитетно**, эффективное значение резолвит `Get-AutonomySettings`.

### settings.json: advanced-настройки

Пишутся через `Set-AdvancedSetting` (`lib/settings.ps1:236`) — **allowlist + range-валидация** (`Test-AdvancedSettingValue`); ключи вне allowlist → `rejected`. Покрытие: `parallel.maxStreams` (1–12), `chunking.maxChunksPerTask` (1–50), `criticMaxRetries`, `auditor.*`, `canary.*`, **`fastLane.{autoDetect,minChars}`** (гейт fast-режима), `memory.{recallTopK,recallMinScore,dedupThreshold,ageDaysPrune,verifyOnRecall,restaleOnSha1Mismatch}`, `librarian.*`, `reflect.minTaskDurationSec`, `backlogPack.*`, `workpackExec.*`, `channelMaintenance.{nonMainBrainstormEnabled,nonMainAuditEnabled}`. `coder.sandboxModeByChannel` — **вне allowlist**, правится прямым редактированием.

### Мёртвые (inert) ключи — код их НЕ читает

| Ключ | Статус |
|---|---|
| `synthesisMode.defaultDepth` | inert — глубина захардкожена в коде. |
| `synthesisMode.maxDebateTopics` / `maxDebateRounds` | inert — потолки дебатов захардкожены. |
| `synthesisMode.rubricWeights.*` | inert — веса рубрики захардкожены. |
| `synthesisMode.promoteAfterShadowRuns` | inert. |
| `auditor.cooldownMin` | inert — `Get-AuditorConfig` его загружает, но планирование гейтит ТОЛЬКО `intervalMin` (`lib/auditor.ps1:1137`); присутствует в allowlist, но на поведение не влияет. |

В `synthesisMode` реально читаются только `enabled`, `proposerModels.C` (он же `cheapModel`/`claudeModel` где резолвятся) и `judgeByTaskType.*` (`lib/decision-synthesis.ps1`).

### Модель-политика (жёстко)

- **НИКОГДА `gemini-2.5-pro`** — слишком дорого; удалять из любого нового конфига.
- `gemini-3-flash` — только резерв (дорогой), не primary.
- Рутина (curator, intent, smoke, STT): `gemini-2.5-flash-lite` / `gemini-2.5-flash`.

### Восстановление (kill-switch)

- **PAUSE watchdog:** создать файл `%USERPROFILE%\.bridge-private\watchdog.pause` — watchdog при его наличии НЕ предпринимает действий (`watchdog.ps1:8,47,250,378`). Удалить файл — авто-откат снова активен. (`control\watchdog.pause` больше НЕ проверяется.)

---

## Мониторинг и устранение неполадок

Источник правды по операциям — `MONITORING_RUNBOOK.md` (copy-paste-ready команды). Этот раздел — выжимка: какие процессы должны жить, диагностик-однострочники и карта «симптом → лечение». Корень моста во всех сниппетах: `$src = 'C:\Users\rafie\OneDrive\Documents\bridge'`.

> Безопасность прежде всего: НИКОГДА не делай `. driver.ps1` / `. server.ps1` / `. supervisor.ps1` (top-level код запустит loop в твоём процессе). Проверяй код через `ParseFile` или `-SelfTest` (см. ниже). `lib/*.ps1` и `common.ps1` dot-source безопасны — это библиотеки (исключение — исполняемые `tools/*.ps1` вроде `deep-audit.ps1`).

### Ожидаемые процессы

Норма — **минимум 4 ядра**: `supervisor.ps1` + `server.ps1` + `watchdog.ps1` + **≥1 `driver.ps1` на активный канал** (по одному драйверу на канал, до 20).

| Процесс | Роль | Если отсутствует |
|---|---|---|
| `supervisor.ps1` | спавнит/рестартит server и драйверы, держит circuit-breaker | мост не самовосстанавливается — recovery |
| `server.ps1` | HTTP API на `127.0.0.1:8787`, UI, пересоздаёт `state.json` | API DOWN — recovery |
| `watchdog.ps1` | независимый страховочный контур (~120с loop): restart/rollback по heartbeat | нет авто-rollback; supervisor его респавнит |
| `driver.ps1 -Channel <slug>` | основной loop канала (claim → turn → completion) | канал стоит; должен подняться supervisor'ом |

Процессы с пустым `CommandLine` (start совпадает) — норма: session 0 (elevated через Task Scheduler скрывает CommandLine).

### Диагностик-однострочники

```powershell
$src = 'C:\Users\rafie\OneDrive\Documents\bridge'

# 1) Ядро-процессы по ролям
@(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  ? { $_.CommandLine -match 'supervisor\.ps1|server\.ps1|driver\.ps1|watchdog\.ps1' }) |
  % { "$($_.ProcessId): $($_.CommandLine -replace '.*(supervisor|server|driver|watchdog).*','$1')" }

# 2) API жив? (/api/health — единственный маршрут БЕЗ авторизации; 200=жив. На /api/status 401=жив)
try { (Invoke-WebRequest 'http://127.0.0.1:8787/api/health' -UseBasicParsing -TimeoutSec 6).StatusCode }
catch { if ($_.Exception.Message -match '401') {'401 ALIVE'} else {'DOWN — сервер не слушает'} }

# 3) Свежесть драйвера (heartbeat) + что делает канал. ALIVE <30с, STALE ⚠ иначе
foreach ($ch in @('main','oko')) {
  $sf = Join-Path $src "channels\$ch\state.json"; if (-not (Test-Path $sf)) { continue }
  $age = [int]((Get-Date) - (Get-Item $sf).LastWriteTime).TotalSeconds
  $s = [IO.File]::ReadAllText($sf) | ConvertFrom-Json
  "$ch=$($s.status) (state $age`s, $(if($age -lt 30){'ALIVE'}else{'STALE ⚠'})) task=$([string]$s.current_task)" }

# 4) Рестарты за окно circuit-breaker (5/30мин → cooldown)
$rj = Join-Path $env:USERPROFILE '.bridge-runtime\restarts.jsonl'
@(Get-Content $rj -EA SilentlyContinue | % { try { $o=$_|ConvertFrom-Json; if (([datetimeoffset]$o.ts).LocalDateTime -ge (Get-Date).AddMinutes(-30)){$o} } catch {} }).Count
```

**Parse-check всего core-кода** (после правки `.ps1` или при `parse-fail` от circuit-breaker — проверяй И `driver/*.ps1`-модули, не только корневой `driver.ps1`):

```powershell
$src='C:\Users\rafie\OneDrive\Documents\bridge'
$bad=@(); foreach($f in (@(gci $src -Filter *.ps1 -File)+@(gci "$src\driver" -Filter *.ps1)+@(gci "$src\lib" -Filter *.ps1)+@(gci "$src\tools" -Filter *.ps1))){
  $e=$null;$t=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$t,[ref]$e); if($e.Count){$bad+=$f.FullName} }
if($bad){"BROKEN: $($bad -join ', ')"}else{"all core .ps1 parse OK"}

# Load-time self-test драйвера (грузит ВСЕ driver/NN-*.ps1, выходит до loop):
powershell -NoProfile -ExecutionPolicy Bypass -File "$src\driver.ps1" -Channel main -SelfTest   # ждём exit 0 + "DRIVER SELFTEST OK"
```

Что мост делает прямо сейчас (хвост чата): `$env:BRIDGE_CHANNEL='main'; . "$src\lib\common.ps1"; Get-Content (Get-ConversationPath) -Tail 15`.

### Норма / тревога

| Наблюдение | Норма? |
|---|---|
| API отдаёт **401** без токена (на `/api/status`) | ✅ сервер жив, требует токен |
| `state.json` свежеет каждые <30с (heartbeat пишется каждый ход) | ✅ драйвер жив |
| `state.json` старше 60с | ⚠ драйвер завис/умер |
| `restarts(30min)` = 0–2 | ✅ спокойно |
| `restarts(30min)` ≥ 5 | ⚠ circuit-breaker уйдёт в cooldown/freeze |
| Сообщение «git add/commit заблокирован ACL» | ✅ песочница кодера by-design (driver докоммитит сам) |
| «🔍 Аудит запущен / ✅ завершён», «♻️ Zombie-reaper», «🩺 Доктор» | ✅ штатная самозащита — дай отработать |

### Частые проблемы → решения

| Симптом | Корень | Решение |
|---|---|---|
| **Dirty-git guard:** канал не берёт задачу, в чате «рабочее дерево грязное» | Перед claim драйвер (`driver/81-loop-idle-claim.ps1:~1294`) гонит `git status --porcelain`; грязь блокирует старт (per-channel guard) | Закоммить/откатить хвост: `git -C $src status` → salvage реальной работы (commit) либо `git checkout -- <file>` для мусора. Освободившись, канал клеймит сам |
| **Stuck-lease:** задача `running`/`working` часами, прогресса нет | Зомби-аренда (владелец умер, lease не освобождён) или restart-cap | На idle сам срабатывает **zombie-reaper** (`driver/10-maintenance.ps1:~750`): `running` без живого владельца → `held`, lease освобождён. Restart-cap reconcile в `driver/60-startup.ps1`. Если не отпускает — reset state (recovery, шаг 4) |
| **control-plane-blocked:** approved-задача не клеймится | `Test-BacklogApprovedItemClaimable` (`lib/backlog-core.ps1:~1561`): задача трогает control-plane (driver/supervisor/watchdog/secret/backlog*.ps1) без разрешения | Добавь тег **`operator`** (`-Tags @('operator',...)`) — тогда `claimable=true reason='operator'`. Альтернатива — bridge_self_admission блок. ВАЖНО: тег `operator`, НЕ поле `from` |
| **Hard-freeze (circuit-breaker):** в чате «🛑 Мост заморожен, жду оператора», процессы не поднимаются | 5 рестартов/30мин → cooldown; стойкая поломка → freeze. Флаг `control/cb-freeze.flag` (`supervisor.ps1:875`, `lib/circuit-breaker.ps1:509`) | Сначала почини корень (parse-fail-файл → §parse-check). Затем **удали `control/cb-freeze.flag`**. Failsafe: после 3 продлений cooldown мост поднимется сам + пейдж в чат |
| **Ложный rollback:** watchdog откатил коммиты (`git reset --hard`) при кратком API-гэпе | watchdog трактовал паузу сервера как «движок мёртв» (исторический баг 2026-05-25). Пороги: API-down+driver-alive → restart на 3-м (~6мин); rollback только если API лежит и после рестарта (порог 6, ~12мин), либо heartbeat stale (порог 4, ~8мин). Перед rollback ВСЕГДА ветка `prerollback/<ts>` | Поставить kill-switch: создать файл **`<USERPROFILE>\.bridge-private\watchdog.pause`** → watchdog не делает НИЧЕГО (`watchdog.ps1:378`). Это путь ВНЕ корня моста (кодер не может его создать). Восстановить работу: `git checkout prerollback/<ts>` / cherry-pick потерянных коммитов. Убрать паузу — удалить файл |

### Recovery (полный чистый рестарт)

Только при deadlock/storm/зависании. Кратко (полный сниппет — `MONITORING_RUNBOOK.md` §5): убить `supervisor.ps1`, затем повисшие `server.ps1`/`driver.ps1` (**watchdog НЕ трогать**) → `Clear-Content restarts.jsonl` + удалить `control\restart.flag`, `runtime\codex.lock`, `cb-cooldown-extensions` → (при порче) reset `state.json` каналов в `idle` → поднять через `schtasks /end /tn "ClaudeCodexBridge"; schtasks /run /tn "ClaudeCodexBridge"` (НЕ через скрытый `powershell` — Defender блокирует) → подождать ~35–60с и убедиться, что API жив и `restarts.jsonl` НЕ растёт. Один рестарт за раз, только при idle-канале (каждый ручной рестарт приближает circuit-breaker storm).

---

## Каналы, проекты, внешние системы

Канал — это изолированная единица работы моста: свой driver, своё состояние (`state.json`), свой бэклог (`backlog.jsonl`), своя история и память. Один проект = один канал. **Codex общий на все каналы** (отсюда сообщение «⏳ Codex занят другим каналом — жду»). Активный канал (тот, что показывается на пульте без пина) задаётся в `control/active_channel`.

### Живые каналы

| Канал | Что это | `project_root` |
|---|---|---|
| `main` | Развитие самого моста (его инфраструктура, мета-улучшение). Вся «оригинальная» работа над кодом моста | `null` → резолвится в `Get-BridgeRoot` (особый случай `is_bridge`) |
| `claude` | Операторский канал. Прямая линия оператор↔Claude. **Driver здесь всегда на паузе** — сообщения читает и отвечает только Claude-оператор (Claude Code), не автономный мост | `""` (нет проекта) |
| `telegram-bridge-bot` | Личный TG-бот = чат-интерфейс оператора к мосту (текст, файлы, скриншоты, голос) | `C:\Users\rafie\bridge-projects\telegram-bridge-bot` |
| `computer-control` | «Руки/лапа» оператора: быстрое/точное/дешёвое исполнение задач на ПК (Win32→UIAutomation→vision→браузер) | `C:\Users\rafie\bridge-projects\computer-control` |
| `oko` | Vision-сервис — «глаза» моста: камеры, YOLO, трекинг, зоны, события, VLM, risk-решения | `C:\Users\rafie\bridge-projects\oko` |

### Архив (`channels/_archive/`)

Старые/тестовые каналы, **к живому мосту не относятся** (рыночные проекты убраны из целей, см. ниже): `aipartners`, `private-community`, `travel-planner`, `literary-slop-video`, плюс smoke/fallback/feature-verifier-тестовые слепки. Архивные каналы driver не поднимает.

### Привязка проекта (`channel.json`)

Каждый канал описан в `channels/<slug>/channel.json` полями `{ slug, name, description, project_root, created, archived }`. Резолвинг рабочего корня — `Get-EffectiveProjectRoot` / `Get-EffectiveScope` (`lib/channels.ps1`):

- `main` (`is_bridge`) → `project_root = bridge_root`; features/memory/backlog внутри корня моста.
- Не-`main` канал → `project_root` берётся из `channel.json` (или config-ключа `channels.<slug>.project_root`); **тихого fallback нет** — если привязки нет, `Get-EffectiveProjectRoot` возвращает `''`, и canon-каталоги (`features/`, `memory/`, `backlog.jsonl`) ведут внутрь `channels/<slug>/`. Несуществующий канал → throw.

Проектные каналы дополнительно несут гейт утверждения плана (Discuss-First Ф5): `plan_approved`, `plan_approved_signature` (`staged-v1`), `plan_approved_git_head`, путь и score `project-contract.json` (`.bridge\project-contract.json`, обязательные секции: goal, scope/non_goals, users/roles, surfaces, data/backend, acceptance_scenarios, checks, risk, parallel_policy). Беклог проекта разрешён только после утверждённого плана. Verify-gate определяет repo проекта (`Get-TaskRepoRoot`) и проверяет project-diff, а не bridge-diff.

### Цели моста (`goals.md`)

**Миссия:** быть всё более быстрым, надёжным и самостоятельным ИИ-разработчиком для Тимура (русскоязычный, Windows). Мост развивает и улучшает **сам себя** — свой код и свои сервисы (лапа, синтез, рефлексия, доктор). **Сторонние/рыночные проекты — не цель** (pivot 2026-06-18).

Приоритеты по убыванию: **1.** надёжность/стабильность → **2.** безопасность (всё под git-откатом) → **3.** автономность (сам берёт/исполняет/проверяет/откатывает) → **4.** скорость → **5.** качество (фикс в корень, без ложно-зелёного) → **6.** саморазвитие → **7.** оптимизация своих сервисов → **8.** полезность → **9.** экономия (тяжёлое — на предоплаченных Claude/Codex; платные API Gemini/DeepSeek беречь).

**Главный принцип:** скорость и качество через **простоту**, не через нагромождение гейтов. Урок: мост уже плодил конфликтующие защитные гейты, которые ложно блокировали автономию. Поэтому — harden существующего вместо добавления нового; каждая идея сначала спрашивает «можно ли решить упрощением/починкой, а не новым гейтом?».

### Сравнение с внешними системами (`external-systems.md`)

Кураторский gap-анализ: цель — **замечать пробелы в своей архитектуре**, а не копировать. Ключевые «закрытые» пробелы:

| Внешняя система | Их паттерн | Чем закрыто у моста |
|---|---|---|
| **AutoGen** (`GroupChat` — совет агентов) | N агентов одновременно обсуждают | **Decision Synthesis** (`task_mode='synthesis'`, `synthesisMode.enabled=true` в `config.json`): N≥3 модели (Codex/Claude-opus/Gemini) дают слепые предложения → ConflictMatrix → CrossReview → Judge → MicroDebate → FinalV2+RedTeam → Decision Record. Это «совет» для Deep/High-Stakes; рутина — 1:1 |
| **MetaGPT** (роли PM→Architect→Engineer→**QA** с SoD) | QA как отдельная роль, документы между ролями | Claude (planner) + Codex (coder) + DeepSeek-Pro (critic). **QA как отдельная роль закрыта:** `tools/feature-verifier.ps1`, `lib/project-acceptance.ps1`, `tools/scenario.ps1` — приёмка гоняет реальные E2E/acceptance, не только ревью diff |
| **Devin/OpenHands** (sandboxed VM, browser+terminal+IDE) | полноценная изоляция dev-среды | **worktrees** (`lib/parallel.ps1` — каждый параллельный воркер в своём git-worktree, мерж обратно последовательно) + Codex `-s workspace-write` (ОС-confine записей в cwd). Уровень sandbox-режима, не полная VM. Браузер — `visit.ps1` (снимок) + канал `computer-control` (реальные руки) |
| **LangGraph** (checkpointing мид-задачи) | restart с середины | Чекпойнты в synthesis-пайплайне (артефакты в `channels/<slug>/decisions/<id>/`); обычный код-ход всё ещё рестартует с нуля (**остаётся** распространить) |
| **BabyAGI** (LLM-приоритизация очереди) | task-queue с приоритетами | Бэклог + reflect-генерация идей + `Invoke-BacklogLLMPrioritize` поверх формулы `score=value*confidence/effort` |
| **Aider** (conventional commits) | читаемая история | Уже делается (`feat(meta): …`) |

**Уникально у моста (нет почти ни у кого):** «доктор» — самодиагностика и автопочинка под тяжёлый сбой; прозрачность для оператора (живой чат + план-доска + дайджест памяти) вместо чёрного ящика.

---

## Роли агентов

Роли согласованы Claude и Codex 2026-05-24 (`discussion.md`, оба `AGREED: yes`) и закреплены в `roles.md`. Базовое разделение труда — **планировщик думает и ревьюит, кодер пишет код**, плюс дешёвые служебные LLM и человек-оператор над control-plane.

### Сводка

| Роль | Агент / модель | Где задаётся | Зона ответственности |
|------|----------------|--------------|----------------------|
| **Planner** (планировщик) | Claude Opus 4.8, Claude Code CLI | `config.json` → `planner: "claude"`, `deepModel: "claude-opus-4-8"` | разбор задачи, план, контракты, ревью diff кодера; **файлы не редактирует** |
| **Coder** (кодер) | Codex `gpt-5.5`, reasoning `xhigh`, Codex CLI | `coder.{agent,model}`, эффорт `xhigh` (`lib/parallel.ps1:100`) | реализация, команды, тесты до зелёного; протокол `RUNJOB`/`FILE`/`VERIFIED` |
| **Critic** (ревьюер diff) | DeepSeek: `deepseek-v4-flash` (лёгкий) / `deepseek-v4-pro` (тяжёлый) | `llm.critic` / `llm.criticHeavy` | независимое ревью diff после хода кодера |
| **Curator / Intent** (служебные) | `gemini-2.5-flash-lite` | `auditor.model`, `lib/intent.ps1:23` (override `llm.intent`) | классификация намерения, курирование беклога, аудит — дёшево |
| **Operator** (человек) | — | — | оркестрация, утверждение глав/плана, control-plane |

### Planner — Claude (Opus 4.8)

Планировщик дробит проект на **непересекающиеся** задачи (disjoint file `scope`), фиксирует общие контракты/интерфейсы ДО кодинга, ревьюит и интегрирует вывод кодера, ведёт доску задач и разрешает конфликты. Файлы он сам **не правит** — это контракт роли (в `roles.md` за планировщиком нет операций записи). Единственное исключение — режим **planner-fallback**: когда Codex занят в другом канале, Claude временно подменяет кодера и реально читает/правит файлы, соблюдая все правила безопасности кодера (`driver/40-agent-invoke.ps1:428`).

Выбор модели планировщика — роутинг `plannerRouting`: Opus включается на DISCUSS/STUDY и по ключевым словам (`архитектур`, `рефактор`, `мигр`, `интеграц`, `overhaul`, `спроектируй`…); иначе дешёвый triage (`triageModel: "sonnet"`).

### Coder — Codex (gpt-5.5, xhigh)

Кодер реализует задачу строго **внутри выданного scope**, прогоняет команды/тесты до зелёного, отдаёт diff и отчёт, **не меняет контракты молча** — флагует. Запуск (per-turn резолв модели/эффорта/sandbox/cwd):

```
codex exec --color never --skip-git-repo-check -m <model> \
  -c model_reasoning_effort="xhigh" -s <sandbox> -C <cwd> -o <file> -
```

Закрытый stdin (`-`) гасит EOF-зависание; чистый результат читается из `-o <file>`. Sandbox по умолчанию `workspace-write` (Gate A — запись только в `-C` cwd), fail-closed при отсутствии конфига; эскалация только оператором через `coder.sandboxMode='danger-full-access'` или `coder.sandboxModeByChannel` — петля автономии сама не повышает права.

**Протокол кодера** (маркеры в ответе, парсятся драйвером):
- `[[RUNJOB: команда | папка]]` — долгая команда (сборка/тесты) в фоне без таймаута хода; вывод и код выхода приходят отдельным `[SYSTEM]`-сообщением (`lib/jobs.ps1`, `driver/84-loop-reply-markers.ps1:232`).
- `[[FILE: путь]]` — передать планировщику артефакт (например baseline-скриншоты UI).
- `[[VERIFIED: что проверено | результат]]` — **обязателен** перед `STATUS: DONE`, если ход менял файлы/выполнял команды; без него DONE отклоняется (`lib/prompt-builder.ps1:337`). Для API-эндпоинтов `[[VERIFIED]]` обязан включать реальный HTTP-вызов, для UI — прогон `tools/ui_audit.ps1`.

### Critic — DeepSeek

После хода кодера независимый критик ревьюит diff. Две градации (`config.json → llm`): лёгкий `deepseek-v4-flash` (`critic`) для рутины и тяжёлый `deepseek-v4-pro` (`criticHeavy`, с thinking) для сложного (`driver/86-loop-completion-actions.ps1:372-408,692`). Ретраи критика ограничены `criticMaxRetries: 3`.

### Curator / Intent — дешёвый gemini-flash-lite

Служебные LLM-вызовы (классификация намерения хода, курирование беклога, периодический аудитор) идут на самой дешёвой `gemini-2.5-flash-lite`: `intent` по умолчанию (`lib/intent.ps1:23`, override `llm.intent`), `auditor.model` и `canary.llmModel` в `config.json`. Прочие служебные роли (`gate`, `librarian`, `reflect`, `qa`) — на `deepseek-v4-flash` с `fallback: gemini-2.5-flash`. Дорогой `gemini-2.5-pro` запрещён политикой; `gemini-3-flash` — только резерв.

### Слияние ролей: Decision Synthesis

Для задач, где архитектуры много, а кода мало, роли planner/coder **сливаются в равноправную панель** через Multi-Model Decision Synthesis (`task_mode='synthesis'`, `synthesisMode.enabled`, движок `lib/decision-synthesis.ps1`). Роутер глубины (`lib/decision-depth.ps1`) на Deep/High-Stakes заменяет одиночного планировщика слепыми предложениями трёх моделей — **A = Codex gpt-5.5:xhigh, B = Claude opus-4-8:xhigh, C = DeepSeek** — после чего судья выбирается по типу задачи (`synthesisMode.judgeByTaskType`: architecture→claude; bugfix/refactor/infra→codex; research/creative→gemini). High-Stakes-исходы помечаются `needs_operator` и **никогда не автоимплементятся**.

### Operator — человек (control-plane)

Оператор оркеструет команду и владеет control-plane: утверждает уровень **глав** в Discuss-First (параграфы/атомы ревьюит планировщик), даёт разрешения на необратимо-внешнее и на изменение критичной инфры моста. Control-plane-задачи не берутся автономией без тега `operator` (`Test-BacklogApprovedItemClaimable`). Две операторские точки восстановления при остановке моста:

- **`watchdog.pause`** — kill-switch вотчдога: файл `<USERPROFILE>\.bridge-private\watchdog.pause` (`watchdog.ps1:47`). Пока он есть, вотчдог **не предпринимает действий** (никаких авто-роллбэков/рестартов). Снять — удалить файл.
- **hard-freeze** — circuit-breaker при доминирующей детерминистической причине и доле ≥ 0.8 пишет флаг `control/cb-freeze.flag` (`lib/circuit-breaker.ps1:505-509`), мост замораживается и ждёт оператора. Снять — удалить `control/cb-freeze.flag`.

Файлы: `roles.md`, `config.json`, `lib/parallel.ps1`, `lib/decision-synthesis.ps1`, `lib/decision-depth.ps1`, `lib/intent.ps1`, `lib/circuit-breaker.ps1`, `lib/prompt-builder.ps1`, `lib/jobs.ps1`, `watchdog.ps1`, `driver/40-agent-invoke.ps1`, `driver/84-loop-reply-markers.ps1`, `driver/86-loop-completion-actions.ps1`.
