# Claude+Codex Bridge — Developer Guide

> Детальное описание архитектуры, механизмов, сложностей и правил разработки.
> Последнее обновление: 2026-06-02. Документ держи в актуальном состоянии при крупных изменениях.

---

## 0. TL;DR для нового разработчика

**Что это.** Автономный, само-развивающийся «мост» между двумя ИИ-агентами: **Claude** (планировщик/ревьюер) и **Codex** (кодер). Мост принимает задачи из чата (или сам берёт их из бэклога), планирует, пишет код, ревьюит, коммитит и умеет улучшать **сам себя**.

**Платформа.** Windows + **PowerShell 5.1** (не PowerShell 7!). ~200 `.ps1`-файлов, веб-UI на одном `web/index.html` (245 KB), HTTP-сервер на `:8787`. 587+ коммитов.

**Топология процессов:**
```
Task Scheduler (autostart, elevated)
        └── supervisor.ps1            # следит, перезапускает, circuit-breaker
              ├── server.ps1 (:8787)  # HTTP API + веб-UI + чат
              ├── driver.ps1 -Channel main     # главный цикл: planner↔coder
              ├── driver.ps1 -Channel aipartners / private-community / ... # по одному driver на активный канал
              └── watchdog.ps1         # авто-откат при поломке
```

**Золотые правила (читай до первой правки):**
1. **PowerShell 5.1**, не 7. Многие конструкции 7.x не работают (см. §6).
2. **Перед применением любой `.ps1`-правки**: `ParseFile` + `driver.ps1 -SelfTest`. Битый код уронит мост в crash-loop.
3. **Не перезапускай мост часто.** Копи правки в пачку → один рестарт. Частые рестарты = circuit-breaker storm (см. §5, §7).
4. **Никогда не коммить** `secrets.json`, `auth.json`, `settings.json` (они в `.gitignore`).
5. **Не трогай** `supervisor.ps1` / `watchdog.ps1` / `.git` / Task Scheduler без явной необходимости и теста.

---

## 1. Зачем это и философия

Цель — **автономная команда разработки из двух ИИ**: Claude думает и проверяет, Codex пишет. Со временем добавилась **само-разработка** (`self-development`): мост анализирует себя (аудит), генерирует идеи (брейншторм), берёт их из бэклога и реализует **без участия человека** — с градацией доверия (`shadow → green → yellow`).

Ключевая ценность оператора (важно понимать при разработке):
- **Чинить КОРЕНЬ, а не симптом.** Нельзя отключать возможность, чтобы скрыть баг — надо лечить причину, чтобы возможность выжила.
- **Автономность важнее многократных подтверждений.** Когда дизайн понятен — решать и делать, не спрашивать «что приоритетнее».
- **Стабильность > новые фичи.** Foundation-направление: «хватит добавлять механизмы, укрепляй то что есть».

---

## 2. Архитектура процессов

### 2.1 supervisor.ps1 (≈18 KB)
Запускается из Task Scheduler (`\ClaudeCodexBridge`) **с повышенными правами** (elevated). Его задача:
- держать живыми `server.ps1` и по одному `driver.ps1` на канал;
- ловить их падения и перезапускать (recycle);
- применять **circuit-breaker** (защита от рестарт-штормов, см. §5);
- соблюдать rate-limit (не чаще 1 recycle / 60 c).

### 2.2 server.ps1 (≈81 KB)
HTTP-сервер на `http://+:8787/`:
- отдаёт веб-UI (`web/index.html`);
- REST API: `/api/status`, `/api/messages`, `/api/settings`, `/api/channels/*`, `/api/backlog`, `/api/brainstorm`, и т.д.;
- принимает сообщения пользователя в чат, пишет их в `channels/<slug>/conversation.jsonl`;
- **аутентификация по токену** — без токена `/api/status` отдаёт `401` (это «жив», а не «сломан»).

### 2.3 driver.ps1 + driver/*.ps1 (entrypoint + модули)
Сердце моста. Один процесс на канал (`-Channel main` / `-Channel <project-slug>`). `driver.ps1` оставлен как entrypoint: загружает библиотеки, dot-source'ит `driver/*.ps1`, выполняет self-test/startup и держит главный цикл (`loop`):
1. читает состояние канала (`state.json`) и новые сообщения;
2. классифицирует намерение (intent), выбирает режим (`code` / `discuss` / `study` / …);
3. выбирает модель планировщика (Sonnet/Opus — см. §4.2);
4. гоняет цикл **planner (Claude) ↔ coder (Codex)** с критиком и верификацией;
5. коммитит результат (driver делает git-commit за Codex — см. §4.4);
6. в простое — берёт автономную задачу из бэклога (см. §4.3);
7. обслуживает recycle-coalescer (§5), аудит-планировщик, doctor и пр.

> Поддерживаемость улучшена: функции вынесены в `driver/*.ps1`, но startup и главный runtime loop пока остаются в `driver.ps1`. Правки поведения вноси в профильный модуль, затем обязательно проверяй `ParseFile` + `-SelfTest`.

### 2.4 watchdog.ps1 (≈10 KB)
Независимый сторож. Если мост «сломан движком» (API не отвечает, лог-сигнатура поломки) — делает **мягкий рестарт** (`restart.flag`), а в крайнем случае — git-rollback на последний стабильный коммит. Запускается скрыто (`-WindowStyle Hidden`). **Не убивать вручную** — это защита.

### 2.5 Каналы (channels)
Мост многоканальный. `main` = сам мост (bridge-self), остальные активные каналы обычно привязаны к
внешним проектам (`aipartners`, `private-community`, ...). У каждого свой `channels/<slug>/`:
`state.json`, `conversation.jsonl`, `turns.jsonl`, бэклог-привязка. **Один общий Codex** на все каналы
→ сериализация через mutex `runtime/codex.lock` (см. §7).

---

## 3. Файловая структура

```
bridge/
├── driver.ps1            # entrypoint: self-test/startup/runtime loop
├── driver/               # функции driver.ps1, разнесённые по зонам ответственности
│   ├── 00-task-session.ps1        # replay/current task, tiering, CLI/help/quality/fast-lane helpers
│   ├── 10-maintenance.ps1         # curator, attachments, librarian/audit/reflect/techradar/canary
│   ├── 20-context.ps1             # autonomy gate, task safety, recall, recurrence/project focus
│   ├── 30-prompt-agent-state.ps1  # prompt builder, current-agent/PID bookkeeping, direct-coder detection
│   ├── 40-agent-invoke.ps1        # Claude/Codex invocation, sandbox/reasoning, summarizer/context folding
│   └── 50-loop-utils.ps1          # speaker/status helpers, turn/evidence logging
├── server.ps1            # HTTP API + UI
├── supervisor.ps1        # autostart-надзиратель + circuit-breaker
├── watchdog.ps1          # авто-откат
├── reflect.ps1 / librarian.ps1 / techradar.ps1 / canary.ps1   # фоновые задачи
├── *-elevated.ps1 / install-*.ps1 / start.ps1 / stop.ps1      # обвязка/установка
├── config.json           # ОСНОВНОЙ конфиг (в git!) — модели, лимиты, autonomy, audit
├── lib/  (31 модуль)     # вся логика-библиотека (dot-source из common.ps1)
│   ├── common.ps1        # ядро: state, сообщения, LLM-вызовы, локи (97 KB)
│   ├── parallel.ps1      # параллельные worktree-потоки (64 KB)
│   ├── backlog.ps1       # очередь задач/идей (57 KB)
│   ├── auditor.ps1       # планировщик аудита (42 KB)
│   ├── memory.ps1        # семантическая память (embeddings) (42 KB)
│   ├── architect.ps1     # брейншторм/deep-think (40 KB)
│   ├── foundry.ps1       # синтез новых проектов (36 KB)
│   ├── circuit-breaker.ps1  # защита от штормов (26 KB)
│   ├── channels.ps1 / features.ps1 / metrics.ps1 / plan.ps1 / doctor.ps1 /
│   │   intent.ps1 / postmortem.ps1 / codemem.ps1 / toolforge.ps1 /
│   │   settings.ps1 / replay.ps1 / worktrees.ps1 / radar.ps1 / usage.ps1 /
│   │   llm.ps1 / notify.ps1 / canary.ps1 ...
├── tools/  (37 скриптов) # аудит и утилиты
│   ├── audit.ps1         # статический аудит-пайплайн (66 KB)
│   ├── deep-audit.ps1    # многоагентный deep-audit оркестратор (52 KB)
│   ├── deep-audit-agent.ps1  # один агент-срез аудита
│   ├── audit-signals.ps1 / audit-functional.ps1 / audit-security.ps1 ...
├── web/index.html        # весь UI в одном файле (245 KB)
├── docs/                 # проектная документация (ARCHITECTURE_V2.md и пр.)
│
│  --- RUNTIME (всё в .gitignore, НЕ коммитить) ---
├── channels/<slug>/      # state.json, conversation.jsonl, turns.jsonl
├── control/              # restart.flag, restart.deferred, флаги управления
├── runtime/              # codex.lock и мутабельное состояние
├── jobs/                 # маркеры фоновых задач (чистить периодически)
├── audit/                # отчёты аудита, findings-ledger.jsonl, usefulness.jsonl
├── decisions/            # журнал решений, deep-think саммари, post-mortems
├── memory/               # векторная память, thinking-journal
├── replay/ / tmp/ / reports/ / logs/ / radar/
├── secrets.json          # API-ключи (НЕ в git, ACL-защита)
├── auth.json             # HTTP-креды (НЕ в git)
└── settings.json         # пользовательские настройки runtime (НЕ в git)
```

**Бэкап:** репозиторий на GitHub (`origin/master`, приватный). Папка также синкается в OneDrive (файловый бэкап исходников — но см. §6.2 про вред OneDrive для runtime).

---

## 4. Ключевые механизмы

### 4.1 Цикл planner ↔ coder
- **Planner = Claude** (`config.planner = claude`). Думает, планирует, ревьюит, ведёт обсуждения.
- **Coder = Codex** (`config.coder.agent = codex`, `sandboxMode = workspace-write`). Пишет код в песочнице.
- **Критик** (`deepseek-v4-flash`/`-pro`) независимо проверяет правки (до `criticMaxRetries` попыток).
- Режимы: обычный `code`, `discuss` (диалог двух моделей), `study` (глубокое изучение).

### 4.2 Tiering моделей планировщика (экономия)
`Get-PlannerModel` (driver.ps1) выбирает Sonnet или Opus:
- **Sonnet** (`triageModel`) — по умолчанию, для рутины (дёшево/быстро);
- **Opus** (`deepModel`) — только когда: есть архитектурные ключевые слова (`архитектур`, `рефактор`, `redesign`, `мигр`, `спроектируй`…), режим `study`, промпт > 300 слов, или явный маркер `[[OPUS]]` / `[[DEEP-THINK]]`.

> Хочешь Opus на конкретную задачу — добавь `[[OPUS]]` или архитектурное слово.

**Политика моделей (важно для затрат):**
- ❌ **Никогда** `gemini-2.5-pro` (слишком дорого).
- ⚠️ `gemini-3-flash` — только резерв (дорогой).
- Рутина (curator, intent, smoke) → `gemini-2.5-flash-lite` / `gemini-2.5-flash`.
- Основные LLM-роли — DeepSeek (`deepseek-v4-flash` / `-pro`), см. `config.llm`.

### 4.3 Автономность (self-development)
Мост сам берёт задачи из бэклога, когда простаивает. Контролируется:
- `config.autonomy.enabled` — включена ли;
- `settings.json: selfExecuteTier` — `off` / `shadow` (логирует, но не делает) / `green` (делает безопасные) / `yellow` (делает шире). **red-tier (security/необратимое) никогда не авто-исполняется.**
- `idleQuietMinutes` — сколько тишины до взятия задачи;
- `maxAutonomousTasksPerDay` — лимит (0 = безлимит);
- `autonomyDisabledChannels` — каналы без автономии, если надо временно убрать конкуренцию за Codex; UI: 🤖/🚫 в меню каналов.

Гейт — `Test-AutonomyReady` (driver.ps1). Бэклог: `lib/backlog.ps1`, статусы `new/approved/green/yellow/done/rejected/auto-dropped`.

### 4.3-bis Project Autopilot (project backlog generation)
Для каналов, привязанных к внешнему проекту, добавлен отдельный слой автопилота, чтобы проект не
требовал ручного "кормления" задачами.

**Когда запускается:**
- канал имеет project binding (`channels/<slug>/channel.json`);
- канал не `main`;
- project repo clean;
- backlog pressure низкий: нет running-задачи и нет достаточного числа approved project tasks;
- cooldown истёк.

**Настройки по умолчанию** (`lib/settings.ps1`, могут перекрываться `settings.json`):
- `projectAutopilotEnabled = true`;
- `projectAutopilotCooldownMinutes = 5`;
- `projectAutopilotMaxTasksPerBatch = 12`.

**Контракт planner-а:**
Driver добавляет в prompt инструкцию PROJECT AUTOPILOT. Coordinator/planner должен вернуть строго
JSON-массив атомов внутри:

```text
[[PROJECT_BACKLOG]]
[
  {"slug":"...", "title":"...", "task":"...", "files":["..."], "depends_on":[], "severity":"normal"}
]
[[/PROJECT_BACKLOG]]
```

С 2026-06-02 атомы Project Autopilot должны по возможности нести расширенную мету:
`chapter`, `wave`, `parallel_group`, `files`, `depends_on`, `acceptance`, `checks`.
Planner также может/должен перед `[[PROJECT_BACKLOG]]` сохранять долговечные проектные знания через
`[[PROJECT_DECISION: ...]]`, `[[PROJECT_RISK: ...]]`, `[[PROJECT_INVARIANT: ...]]`,
`[[PROJECT_TEST: ...]]`, `[[PROJECT_OPEN_QUESTION: ...]]`. Driver пишет это в per-channel
project memory (`channels/<slug>/memory/memory.jsonl`) через существующий embedding-store.

**Project plan contract gate (2026-06-02):**
Project Autopilot is not allowed to decompose a shallow plan. Before `Set-ProjectPlanApproved`
can approve a project channel, the project must contain:

- `PROJECT_BRIEF.md` with the project core: purpose, users, scope, constraints, non-goals;
- `DISCUSS_PRODUCT.md` with product decisions and user/business constraints;
- `DISCUSS_UX.md` with user journeys, navigation, empty/error states, and role flows;
- `DISCUSS_UI.md` with screen structure, visual system, components, responsive expectations;
- `DISCUSS_BACKEND.md` with data, API, auth, storage, permissions, scaling/ops constraints;
- `DISCUSS_QA.md` with test strategy, acceptance scenarios, failure criteria, launch gates;
- `DISCUSS_INTEGRATION.md` with cross-stage conflict resolution and final consistency review;
- `PROJECT_MAP.md` with durable product/interface/workflow mapping;
- `PROJECT_PLAN.md` with deep chapter/dependency/acceptance planning;
- `.bridge/project-contract.json` as the machine-readable source of truth for product, UX/interface,
  journeys/workflows, and final acceptance.

The required discussion order is:

`brief -> product -> UX -> UI -> backend -> QA -> integration`.

Every later stage must explicitly use the previous-stage decisions. For example, UX cannot invent
new roles outside Product; Backend must implement the Product/UX flows; QA must test Product, UX,
UI, Backend, and the integration review. The final integration discussion is the place where
contradictions are resolved before implementation atoms are generated.

`Set-ProjectPlanApproved` stores `plan_approved_signature`, a SHA-256 signature of
all stage docs + `PROJECT_MAP.md + PROJECT_PLAN.md + .bridge/project-contract.json`. If any of those files change,
`Test-ProjectPlanApproved` returns false and autopilot waits for re-approval instead of expanding
stale scope.

Minimal `.bridge/project-contract.json` shape:

```json
{
  "project_goal": "Concrete outcome, not a slogan.",
  "planning_flow": {
    "stages": [
      {
        "id": "brief",
        "status": "complete",
        "doc": "PROJECT_BRIEF.md",
        "depends_on": [],
        "summary": "Core project purpose, users, constraints, MVP, and non-goals are fixed."
      },
      {
        "id": "product",
        "status": "complete",
        "doc": "DISCUSS_PRODUCT.md",
        "depends_on": ["brief"],
        "summary": "Product decisions use the brief and define roles, value, scope, and boundaries."
      },
      {
        "id": "integration",
        "status": "complete",
        "doc": "DISCUSS_INTEGRATION.md",
        "depends_on": ["brief", "product", "ux", "ui", "backend", "qa"],
        "summary": "Cross-stage contradictions were resolved before implementation."
      }
    ]
  },
  "requirements": ["capability 1", "capability 2", "capability 3"],
  "screens": [
    {
      "id": "dashboard",
      "path": "/dashboard",
      "expected_status": 200,
      "must_contain": ["Dashboard"]
    }
  ],
  "user_journeys": [
    {"id": "main-flow", "steps": ["open", "act", "verify"]},
    {"id": "admin-flow", "steps": ["open admin", "review", "act"]}
  ],
  "ux_contract": {
    "navigation": "Primary actions and state feedback are visible for the intended roles."
  },
  "acceptance_scenarios": ["typecheck passes", "build passes", "critical journey passes"]
}
```

Final project acceptance uses this contract too: it fails when the plan/contract is missing or
too shallow, and it adds deterministic web checks from contract surfaces (`path`, `expected_status`,
`must_contain`) in addition to project scripts/smokes from `.bridge/acceptance.json`.

**Реализация:**
- `lib/backlog.ps1`: `Get-ProjectAutopilotConfig`, `Get-ProjectAutopilotBinding`,
  `Get-ProjectAutopilotBacklogPressure`, `Test-ProjectAutopilotProjectClean`,
  `Start-ProjectAutopilotIfNeeded`, `Get-ProjectAutopilotTaskArrayFromMarker`,
  `Add-ProjectBacklogFromMarker`.
- `driver.ps1`: idle trigger перед claim (`Start-ProjectAutopilotIfNeeded -Reason 'idle-empty-backlog'`);
  парсинг `[[PROJECT_BACKLOG]]`; добавление approved project tasks; очистка маркера из видимого ответа.

**Операторский инвариант:** ручной append в `backlog.jsonl` теперь fallback. Штатно проект сам
пополняет очередь атомами через `[[PROJECT_BACKLOG]]`, а затем обычная автономия исполняет approved tasks.

### 4.3-ter Workpack ready-frontier scheduler
`Get-NextBacklogWorkpackBatch` больше не отключает весь batch из-за одной зависимой задачи. Он строит
готовый фронт approved workpack-атомов:
- explicit `depends_on` обязан указывать на `done`/`auto-resolved` slug;
- атомы с незакрытыми зависимостями остаются ждать и не блокируют независимые ready-атомы;
- heuristic `foundation` без explicit deps остаётся serial barrier;
- выбор batch всё ещё требует разные `workpack_conflict_group` и непересекающийся touch-set.

Driver пишет в чат телеметрию фронта (`selected`, `ready/eligible`, `deps`, `barrier`, `conflicts`).
Итог deterministic parallel wave сохраняется в project memory: success как `project_worklog`, partial/fail
как `project_risk`.

### 4.4 Песочница кодера и auto-commit (это НЕ баг)
Codex работает в **изолированной песочнице** (`workspace-write`): может писать файлы проекта, но **намеренно не имеет доступа к `.git`** (ACL на `.git/index.lock`). Поэтому:
- Codex правит файлы → пытается `git commit` → получает `Permission denied` → честно сообщает «git заблокирован»;
- **Driver (доверенный, вне песочницы) докоммичивает правки за Codex** (`💾 Драйвер зафиксировал правки Codex … <sha>`).

Это защита (Gate-A): кодер не трогает историю напрямую. Правки **не теряются**. Сообщение про «заблокированную песочницу» — штатное.

### 4.4-bis Project repo gates и quality bypass guard
Для project-каналов критично проверять не bridge repo, а repo активного проекта. Исправления:

- `Get-TaskRepoRoot` в `driver.ps1` выбирает repo root текущей задачи: project binding для project tasks,
  иначе bridge root. Это устранило ложный gate, где `git-sha` коммита проекта искался в bridge repo.
- Base commit автономной project task теперь берётся из project repo, а не из bridge.
- Verify diff fallback, critic gate, changed files, task history, symbol evidence и `DIFF_META` используют
  repo root задачи.
- `Test-QualityBypassesInDiff` ловит добавленные строки с обходом качества:
  `ignoreBuildErrors`, `ignoreDuringBuilds`, `@ts-nocheck`, verify-команды с `|| true` или forced `exit 0`.
- Автономная backlog task не может закрыться `STATUS: DONE`, если агент только написал план:
  нужен реальный action/evidence, `COVERED:` для дубля или project backlog atoms.

Инвариант для разработчика: при любой доработке project gates тестировать `driver.ps1 -Channel main -SelfTest`
и `driver.ps1 -Channel <project-channel> -SelfTest`; detector quality bypass должен оставаться в SelfTest.

### 4.5 Аудит (статический + deep-audit)
Ночью (окно `config.audit` 01:00–06:00, `floorHours=20`) или вручную:
1. **Статика**: `tools/audit.ps1` — security/functional грепы + DeepSeek.
2. **findings-ledger** (`audit/findings-ledger.jsonl`) — машинный учёт находок (new→fixed→regressed, dedup).
3. **usefulness-score** (`audit/usefulness.jsonl`) — насколько полезен аудит (action_rate + resolved_signal_delta + incident_capture).
4. **deep-audit** (`tools/deep-audit.ps1`): многоагентный — N срезов параллельно (security/functional/reliability/architecture/dependency-model), каждый со своей моделью из `config.audit.deepAgents`, результаты сливаются.

> Тонкость PowerShell: переменные регистронезависимы. `$functionalAgent` и param `$FunctionalAgent` — одна переменная. Эта коллизия валила deep-audit (см. §7).

### 4.6 Параллельные потоки (parallel)
`lib/parallel.ps1` — раскладывает задачу на потоки, каждый в своём git-worktree (`wip/parallel/<hash>/<id>`), потом merge-стадия. Merge устойчив: при конфликте `git merge --abort` → retry `-X ours` → дерево никогда не остаётся unmerged.

### 4.7 Память, doctor, foundry, radar
- **memory** (`lib/memory.ps1`) — векторная память (embeddings, `gemini-embedding-001`), семантический recall в промпты.
- **doctor** (`lib/doctor.ps1`) — самодиагностика и починка при сбоях задач.
- **foundry/toolforge** — синтез новых инструментов (`[[NEED-TOOL]]`) и проектов на лету.
- **radar/techradar/architect** — брейншторм идей, deep-think диалоги Claude↔Codex, тех-радар.

---

## 5. Recycle, Coalescer, Circuit-breaker (СТАБИЛЬНОСТЬ)

Это самая важная и хрупкая часть — читай внимательно.

### 5.1 Как происходит рестарт
Любой компонент создаёт `control/restart.flag` → supervisor видит → recycle (kill + respawn server и driver). Источники флага: правка `.ps1` автозадачей, watchdog, ручной триггер.

### 5.2 Recycle-coalescer (анти-шторм, в driver.ps1, main-канал)
Проблема: пачка self-dev правок ставила `restart.flag` на каждую правку → 18 рестартов/30 мин → шторм.
Решение (двухуровневое):
- **Пока задача РАБОТАЕТ** (`$rcBusy`: status working/coding + `current_task` + active_jobs) → `restart.flag` откладывается в `restart.deferred`. **Медленный Codex безопасен** — пока «работает», рестарта нет.
- **Между задачами — решение по ПЛАНУ, не по таймеру** (2026-05-30): отложенный рестарт держится, пока в плане есть работа (`active_jobs` ИЛИ claimable-бэклог при включённой автономии). Рестарт срабатывает только когда **план опустел** (пачка завершена). Таймаут 300 c — только failsafe; жёсткий потолок отсрочки — 600 c.

Итог: целая пачка правок схлопывается в **один** рестарт после последней задачи.

### 5.3 Circuit-breaker (`lib/circuit-breaker.ps1`)
Защита от штормов: если ≥ `maxRestarts` (5) рестартов за `windowMin` (30) мин → **cooldown** (`cooldownMin` 15). Каждый рестарт классифицируется (`parse-fail` / `state-corrupt` / `OOM` / `explicit-flag` / `task-survived-3x` / `unknown`) в `~/.bridge-runtime/restarts.jsonl`.

**Бывший deadlock (исправлен 2026-05-30):** выход из cooldown гейтился `Invoke-HealthProbe`, а probe считал `state-unreadable` фатальным. Но state.json чинит сам server при старте → cooldown → нет server → state остаётся битым → probe red → cooldown навечно. **Фикс:**
- `state-unreadable` → теперь **warning**, не блокер (server пересоздаст state);
- probe сканирует только **core** `.ps1` (top + `lib` + `tools`), без рекурсии в canary-worktree/sandbox;
- блокирует resume только реальная фатальщина: parse-fail в core-файле или пропавший bridge-root;
- **failsafe**: после 3 продлений cooldown — принудительный resume + эскалация оператору (живой мост с предупреждением лучше мёртвого).

### 5.4 Ручное восстановление (если мост всё же умер)
```powershell
# 1. убить застрявший supervisor
Stop-Process -Id <supervisor_pid> -Force
# 2. сбросить окно circuit-breaker + отложенный рестарт
Clear-Content "$env:USERPROFILE\.bridge-runtime\restarts.jsonl"
Remove-Item bridge\control\restart.flag, bridge\control\restart.deferred -Force -EA SilentlyContinue
Remove-Item bridge\runtime\codex.lock -Force -EA SilentlyContinue
# 3. поднять заново через autostart-задачу
schtasks /end /tn "ClaudeCodexBridge"; schtasks /run /tn "ClaudeCodexBridge"
# 4. проверить: API 401 (жив), restarts.jsonl не растёт, channels/*/state.json свежеет
```

---

## 6. Сложности разработки (что обязательно знать)

### 6.1 PowerShell 5.1 — подводные камни
- **`$var:` парсится как drive-qualifier.** `"$Mode: text"` ломается — пиши `"${Mode}: text"`.
- **`if` — не выражение.** `$x = (if (...) {...})` ошибка. Используй `$x = $(if (...) {...})` или явный `if/else`.
- **Регистронезависимые переменные.** `$functionalAgent` == `$FunctionalAgent`. Коллизия с `[ValidateSet]`-параметром → `ValidationMetadataException` при присваивании объекта. **Именуй локальные переменные уникально.**
- **Кодировка.** `.ps1` сохранять как **UTF-8 с BOM** (кириллица иначе бьётся). Файлы для других тулзов — UTF-8 **без** BOM (`New-Object System.Text.UTF8Encoding($false)`).
- **`2>&1` на нативном exe** оборачивает stderr в ErrorRecord и ставит `$?`=false даже при exit 0. Не редиректь stderr нативных команд без нужды.
- **Нет** тернарного `?:`, `??`, `?.`, `&&`/`||` в пайплайнах (это 7.x).

### 6.2 OneDrive
Папка в `OneDrive\Documents`. Для **исходников** — это плюс (облачный бэкап). Для **runtime** (`state.json`, локи) — был источник порчи (`state.json corrupted ×7` при штормах: sync держит файл, atomic-rename падает). Foundation-задача — выносить мутабельное в `%LOCALAPPDATA%`. При работе помни: частые atomic-write в OneDrive-папке ненадёжны.

### 6.3 Windows Defender
Эвристика Defender **блокирует запуск скрытого PowerShell, запускающего PowerShell с Bypass** (`powershell -Command "... Start-Process powershell -WindowStyle Hidden -ExecutionPolicy Bypass ..."`) — это сигнатура malware. Симптом: `EPERM: uv_spawn`. Мост стартует server/driver через `-File` (без inline `-Command`), поэтому штатно не триггерит. **Не гоняй диагностику через вложенный скрытый powershell** — упрётся в EPERM и/или повиснет на UAC.

### 6.4 UAC и фоновые задачи
`schtasks /change` и подобные elevated-операции **в фоне зависают** на UAC-промпте (ответить некому). Не запускай их в `run_in_background`.

### 6.5 Codex mutex / cross-channel
Один Codex на все каналы → `runtime/codex.lock`. Если несколько каналов автономны, они конкурируют →
сообщения «Codex занят другим каналом», ожидание до 120 c, потом «продолжаю без mutex» (риск двух
Codex). Для снижения конкуренции временно выключай автономию лишних проектных каналов через
`autonomyDisabledChannels`. Lock имеет stale-detection (мёртвый/чужой PID → забирается сразу).

### 6.6 Размер крупных файлов
`driver.ps1` больше не является одиночным 366 KB монолитом: функции вынесены в `driver/*.ps1`, а сам entrypoint держит загрузку, self-test, startup и runtime loop. Крупными остаются `web/index.html` 245 KB, `common.ps1` 97 KB и несколько driver-модулей. Правки — **точечные** (`Edit` по уникальному фрагменту), в профильном модуле. Полную перезапись делать только осознанно.

---

## 7. Инструкции: как безопасно вносить изменения

### 7.1 Перед применением ЛЮБОЙ .ps1-правки
```powershell
# 1. синтаксис
$e=$null;$t=$null
[void][System.Management.Automation.Language.Parser]::ParseFile('driver.ps1',[ref]$t,[ref]$e)
$e.Count   # должно быть 0
# 2. загрузочный self-test (ловит runtime-бомбы при загрузке, выходит до loop)
powershell -NoProfile -ExecutionPolicy Bypass -File driver.ps1 -Channel main -SelfTest
# exit 0 + "DRIVER SELFTEST OK"
```

### 7.2 Дисциплина рестартов (КРИТИЧНО)
- **Не перезапускай мост после каждой мелкой правки.** Собери пачку → один рестарт.
- Не делай несколько ручных рестартов подряд — превысишь окно circuit-breaker (5/30мин) → cooldown.
- Применяй изменения, когда канал **idle** (не прерывай работающую задачу).
- HTML (`web/index.html`) применяется **без** рестарта — просто обнови вкладку. **Не** создавай `restart.flag` ради HTML.

### 7.3 Применение изменений
- Правки `lib/*` и `driver.ps1` → подхватываются при следующем recycle драйвера (`restart.flag`).
- Правки `server.ps1` → нужен recycle сервера.
- Правки `supervisor.ps1` / `circuit-breaker.ps1` → нужен **перезапуск supervisor** (`schtasks /end` + `/run`), т.к. supervisor грузит их при старте.

### 7.4 Что НЕ трогать без явной необходимости + теста
`supervisor.ps1`, `watchdog.ps1`, `.git/`, Task Scheduler (`ClaudeCodexBridge*`). Перед `kill` процесса — **проверь, не bridge ли это** (CommandLine на `supervisor/server/driver/watchdog.ps1`). Однажды это спасло от убийства watchdog.

### 7.5 Секреты и приватность
- **Никогда** не коммить `secrets.json`, `auth.json`, `settings.json`, `turns.jsonl`, `decisions/session-ledger.jsonl`, `conversation.jsonl`. Все в `.gitignore`; runtime-маркеры (`features/verifier.last` и пр.) тоже — иначе грязное дерево блокирует автономию.
- Ключи грузятся из `secrets.json` (`Get-SecretsPath`), не хардкодить.

### 7.6 Git-гигиена
- Коммить только осмысленные файлы (не `-A` вслепую — захватишь runtime).
- Конец сообщения коммита: `Co-Authored-By: …`.
- Не force-push, не reset --hard на грязном дереве без сохранения diff.

---

## 8. Конфигурация

### 8.1 config.json (в git — общий дефолт)
Ключевое: `port`, `planner`, `coder.{agent,sandboxMode}`, `triageModel`/`deepModel`, `plannerRouting.opusKeywords`, `llm.*` (модели ролей), `circuitBreaker.{windowMin,maxRestarts,cooldownMin}`, `autonomy.*`, `audit.{windowStartHour,floorHours,deepAgents}`, `parallel.{enabled,maxStreams,workers}`, `probeTimeout`.

### 8.2 settings.json (runtime, НЕ в git)
Накладывается поверх `config.autonomy`. Переживает git-rollback (поэтому отдельно). Ключевое: `selfExecuteTier`, `idleQuietMinutes`, `maxAutonomousTasksPerDay`, `autonomyDisabledChannels`, advanced-настройки (`Set-AdvancedSetting`, whitelisted + range-validated).

Эффективные настройки: дефолты в `lib/settings.ps1` ← `config.json` ← `settings.json`.

---

## 9. Troubleshooting

| Симптом | Причина | Что делать |
|---|---|---|
| API не отвечает, только supervisor+watchdog живы | circuit-breaker deadlock (старая версия) или storm | §5.4 ручное восстановление |
| 6+ рестартов/30мин в `restarts.jsonl` | recycle-storm (много правок/ручных рестартов) | подождать; не плодить рестарты; проверить coalescer |
| «Codex занят другим каналом» часто | несколько каналов автономны, конкуренция за Codex | временно выключить автономию лишних каналов (🚫 в UI / `autonomyDisabledChannels`) |
| «git add/commit заблокирован ACL» | штатная песочница кодера | ничего — driver докоммитит сам (§4.4) |
| `state.json` повреждён | OneDrive sync во время шторма | server пересоздаёт; в идеале вынести runtime из OneDrive |
| `deep[deep_failed agents=0]` | контракт/коллизия переменных в deep-audit | проверить `agents` vs `model_agents`, `$functionalAgent` коллизию |
| `EPERM uv_spawn` | Defender блокирует вложенный скрытый powershell | не запускать диагностику так; использовать `-File` |
| `server not ready` в project HTTP-smoke | агент руками поднял dev-сервер через inline `Start-Process` без логов/cleanup | использовать `tools\web-smoke.ps1`: start/dev detection, readiness, stdout/stderr log, cleanup |
| «Recon … Running 911m» в фоне | зависла фоновая команда на UAC | Stop в UI / убить процесс (проверив, что не bridge) |

Диагностика здоровья:
```powershell
# процессы
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | ? {$_.CommandLine -match 'supervisor|server|driver|watchdog'}
# API (401 = жив)
try { Invoke-WebRequest http://127.0.0.1:8787/api/status -UseBasicParsing -TimeoutSec 6 } catch { $_.Exception.Message }
# рестарты
Get-Content "$env:USERPROFILE\.bridge-runtime\restarts.jsonl" | Select-Object -Last 8
# свежесть драйвера
(Get-Item channels\main\state.json).LastWriteTime
```

Project web/API smoke для любого сайта:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\web-smoke.ps1 `
  -ProjectRoot C:\path\to\project `
  -ReadyPath /login `
  -Check "/api/health=200;/api/private=401,403"
```
Агенты должны вызывать это через `[[RUNJOB: ... | C:\Users\rafie\OneDrive\Documents\bridge]]`, а не собирать inline `Start-Process npm run dev`.

---

## 10. Сильные стороны и риски (честно)

**Сильные стороны:**
- Богатая, реально работающая автономия: мост сам генерит идеи, берёт из бэклога, кодит, ревьюит, коммитит, пушит.
- Глубокий многоагентный аудит, семантическая память, doctor, parallel-worktrees, foundry.
- Многоуровневая защита: sandbox-изоляция кодера, watchdog-откат, circuit-breaker, plan-aware coalescer.
- Градуированное доверие автономии (shadow→green→yellow), red-tier никогда не авто.

**Риски / технический долг:**
- **Крупные файлы/модули** (`web/index.html`, `common.ps1`, отдельные `driver/*.ps1`) — всё ещё требуют точечных правок и обязательного self-test, но главный риск старого `driver.ps1`-монолита снижен.
- **Высокая связность механизмов** (31 lib) — баги во взаимодействии (штормы, deadlock — большинство уже вылечено).
- **Хрупкая платформа**: PS 5.1 + Windows + OneDrive + Defender + UAC дают целый класс инфраструктурных сбоев.
- **Стабильность — главный риск.** Большинство инцидентов — не логика, а рестарт-штормы/порча state. Направление развития верное: «укреплять, а не наращивать» (Foundation-задачи), держать runtime вне OneDrive, продолжать дробить крупные зоны без изменения поведения.

**Вердикт:** впечатляющая, амбициозная и работающая система. Для дальнейшего развития приоритет — **надёжность и поддерживаемость** (дальнейшая декомпозиция крупных файлов, runtime вне OneDrive, больше self-test покрытия), а не новые механизмы.

---

*Документ создан Claude (Opus). При крупных архитектурных изменениях — обновляй соответствующий раздел.*
