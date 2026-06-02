# Карта проекта: bridge

_Обновлено: 2026-06-02. Опорный коммит актуализации: `4633fa8 fix(driver): audit project diffs and block quality bypasses`._

Это каноническая карта проекта для канала `main`. Её читают человек, агенты и `Project Context Pack`. Сгенерированные карты в `memory/` полезны, но библиотекарь может их перезаписать, поэтому устойчивый источник правды для структуры проекта - этот файл.

## 1. Назначение

`bridge` - локальная Windows-система, которая превращает чат в автономную команду разработки:

- Claude в основном планирует, обсуждает, ревьюит и принимает архитектурные решения.
- Codex в основном пишет и правит код.
- DeepSeek/Gemini используются для критика, аудита, библиотекаря, эмбеддингов, роутинга и дешёвых служебных решений.
- Мост принимает задачи из чата, обсуждает их, пишет код, запускает проверки, коммитит, запоминает выводы и улучшает сам себя.

Северная звезда из `goals.md`:

1. Сначала стабильность и безопасность.
2. Потом автономность.
3. Потом самообучение и саморазвитие.
4. После этого скорость, полезность и экономия.
5. Внешние коммерческие проекты - только когда фундамент самого моста достаточно надёжен.

## 2. Рантайм-топология

Основное дерево процессов:

```text
Task Scheduler: ClaudeCodexBridge
  supervisor.ps1
    server.ps1        - HTTP API и web UI на :8787
    driver.ps1 main              - канал разработки самого моста
    driver.ps1 <project-channel> - по одному driver на активный проектный канал
  watchdog.ps1        - независимый сторож здоровья, рестартов и rollback
```

Критические правила:

- Никогда не делать dot-source для `driver.ps1`, `server.ps1`, `supervisor.ps1`.
- Целевая среда - Windows PowerShell 5.1, не PowerShell 7.
- После правок `.ps1`: ParseFile, затем обычно `driver.ps1 -SelfTest`.
- Не плодить рестарты. Правки собираются пачкой, затем один контролируемый restart только когда канал idle.
- Не трогать secrets, `.git`, Task Scheduler, watchdog или supervisor без явной причины из runbook или подтверждения оператора.

## 3. Каналы и проекты

Канал - это вкладка и проектный контекст. У каждого канала свои state, conversation, backlog, files, memory scope и project root.

- `main`: сам мост. `project_root` = `C:\Users\rafie\OneDrive\Documents\bridge`.
- `aipartners`: внешний проект AI Partners. `project_root` = `C:\Users\rafie\aipartners`.
- `private-community`: внешний проект закрытого комьюнити. `project_root` = `C:\Users\rafie\bridge-projects\private-community`.
- `travel`: бывший учебный внешний проект, сейчас архивный/не основной.
- Новые вкладки должны повторять эту модель: один канал, один корень проекта, отдельная память, отдельный индекс кода, отдельный контекст.

Ключевые функции скоупа в `lib/channels.ps1`:

- `Get-ChannelProjectBinding`
- `Get-EffectiveProjectRoot`
- `Get-EffectiveScope`
- `Get-ChannelConfig`
- `Save-ChannelConfig`

Конфиги каналов лежат в `channels/<slug>/channel.json`.

## 4. Файловые зоны

Исходники в git:

- `driver.ps1`: главный цикл, сбор промпта, planner/coder loop, автономия, коммиты, memory hooks.
- `server.ps1`: HTTP API, авторизация, UI backend, endpoints каналов, настроек, памяти, backlog.
- `supervisor.ps1`: запуск и надзор за server/drivers, recycle, circuit-breaker.
- `watchdog.ps1`: независимая защитная петля, health, rollback, stable promotion.
- `lib/`: основная библиотека PowerShell-модулей.
- `tools/`: тесты, аудит, диагностика, индексация, сценарии.
- `web/`: браузерный UI (`index.html`, `memory.html`).
- `goals.md`, `DEVELOPER_GUIDE.md`, `MONITORING_RUNBOOK.md`, `ARCHITECTURE_V2.md`: стратегические и операционные документы.

Runtime и сгенерированные данные, обычно не коммитятся:

- `channels/<slug>/state.json`: состояние драйвера и текущей задачи.
- `channels/<slug>/conversation.jsonl`: чат и системные события.
- `channels/<slug>/turns.jsonl`: телеметрия ходов.
- `control/`: restart flags, active channel, watchdog logs.
- `runtime/`: locks, включая `codex.lock`.
- `jobs/`: фоновые задачи.
- `memory/`: vector store, сгенерированные карты, thinking journal, failures.
- `audit/`, `reports/`, `radar/`, `decisions/`, `replay/`: отчёты, решения, исследования, replay.
- `worktrees/`, `.tmp-*`: изолированные рабочие деревья и временные smoke-папки.

## 5. Основные модули

### Фундамент

- `lib/common.ps1`: корень проекта, config, атомарная запись state, сообщения, locks, child processes, attachments, fast-lane helpers, initialization.
- `lib/channels.ps1`: модель вкладок/проектов, active channel, project root binding, пути state/conversation/backlog.
- `lib/settings.ps1`: runtime-настройки из `settings.json`, autonomy, advanced settings, external projects.
- `lib/circuit-breaker.ps1`: классификация рестартов, cooldown, health probe, диагностика restart storm.
- `lib/checkpoint.ps1`: checkpoint текущей задачи.
- `lib/jobs.ps1`: запуск и чтение фоновых PowerShell jobs.
- `lib/agent-wait.ps1`: ожидание внешних agent-процессов.

### Планирование и исполнение

- `lib/plan.ps1`: план/DAG, ready steps, progress, форматирование для API и промптов.
- `lib/parallel.ps1`: параллельные worker-потоки в git worktrees, выбор воркера, merge/fallback.
- `lib/worktrees.ps1`: create/merge/remove/list/cleanup git worktrees.
- `lib/qa-agent.ps1`: QA-agent invocation и формат результата.
- `lib/router.ps1`: выбор модели planner на основе статистики и политики.
- `lib/intent.ps1`: intent detection и классификация простых задач.

### Автономия и backlog

- `lib/backlog.ps1`: очередь идей, risk tier, stale sweep, LLM-prioritizer, self-exec, safety reflex, Project Autopilot.
- `docs/self-development.md`: политика `selfExecuteTier`.
- `config.json -> autonomy`: idle timing, дневной лимит автономных задач, reflect cadence, stable promotion.
- `settings.json -> selfExecuteTier`: runtime-диск. На момент карты наблюдалось значение `yellow`.

Risk tier:

- `green`: маленькие обратимые изменения.
- `yellow`: реальные изменения кода, разрешены только если диск позволяет.
- `red`: безопасность, secrets, необратимые действия, watchdog/supervisor, billing, destructive actions. Автономно не исполняется никогда.

Project Autopilot:

- Для project-каналов `driver.ps1` запускает `Start-ProjectAutopilotIfNeeded`, когда очередь approved
  project tasks исчерпана или почти исчерпана, project repo clean и cooldown истёк.
- Planner возвращает атомы в `[[PROJECT_BACKLOG]] ... [[/PROJECT_BACKLOG]]`.
- `Add-ProjectBacklogFromMarker` добавляет атомы как `approved` project tasks; оператор не должен
  постоянно дописывать backlog руками.
- Defaults: `projectAutopilotEnabled=true`, `projectAutopilotCooldownMinutes=5`,
  `projectAutopilotMaxTasksPerBatch=12`.

### Память и понимание проекта

- `lib/memory.ps1`: vector memory, embeddings, recall, typed records, pruning, API views.
- `lib/project-context.ps1`: Project Context Pack, readiness score, project map snippet, stale evidence, ingestion markers.
- `lib/codemem.ps1`: индекс кода и semantic code recall для PowerShell и типовых проектных файлов.
- `librarian.ps1`: ingest decisions, dedup/prune, генерация memory maps.

Типы памяти v2:

- `project_fact`
- `project_test`
- `project_risk`
- `project_invariant`
- `project_decision`
- `project_worklog`
- `project_open_question`

Маркеры, которые агенты могут писать в ответах:

```text
[[PROJECT_FACT: факт | file=path | line=12 | trust=observed]]
[[PROJECT_TEST: как проверять | file=path]]
[[PROJECT_RISK: риск]]
[[PROJECT_INVARIANT: правило]]
[[PROJECT_DECISION: решение]]
[[PROJECT_OPEN_QUESTION: вопрос]]
```

Readiness проекта считается по мягкому гейту:

- есть project map;
- достаточно проверяемых `project_fact`;
- есть хотя бы один `project_test`;
- code index не пуст;
- есть risks/invariants;
- evidence не устарел.

### Аудит, обучение, рефлексия

- `lib/auditor.ps1`: периодический аудитор задач и здоровья, triggers, verdict memory, suppression/escalation.
- `tools/audit.ps1`: статический audit pipeline.
- `tools/deep-audit.ps1`, `tools/deep-audit-agent.ps1`: multi-agent audit по доменам.
- `lib/findings-ledger.ps1`: lifecycle находок, dedup, visible findings.
- `lib/metrics.ps1`: turns/latency/doctor metrics, hypotheses, verdict actuation, failures.
- `lib/postmortem.ps1`: разбор провалов задач/коммитов.
- `reflect.ps1`: entrypoint рефлексии.
- `lib/architect.ps1`: architecture critique, deep-think, capability matrix, thinking journal.

### Исследования, foundry, инструменты

- `lib/radar.ps1`, `techradar.ps1`: tech radar и генерация идей в backlog.
- `lib/scholar.ps1`: изучение статей и запись знаний.
- `lib/foundry.ps1`: синтез новых проектов.
- `lib/toolforge.ps1`: авто-инструменты, registry, smoke checks.
- `lib/features.ps1`: feature registry, feature state, activations, similarity.
- `features/registry.json`: каталог фич и rollout metadata.

### Уведомления, usage, canary

- `lib/notify.ps1`: Telegram/push с throttle.
- `lib/usage.ps1`: учёт usage и стоимости.
- `lib/canary.ps1`: canary worktree heartbeat/smoke, сейчас в config выключен.

## 6. Server и UI

`server.ps1` обслуживает UI и API на порту `8787`.

Важные endpoints:

- `GET /api/health`
- `GET /api/status`
- `GET /api/messages`
- `POST /api/say`
- `POST /api/control`
- `GET/POST /api/memory/*`
- `GET/POST /api/backlog/*`
- `GET /api/plan`
- `GET /api/code`
- `POST /api/architect/run`
- `POST /api/brainstorm`
- `GET /api/runbook`
- `GET /api/metrics`
- `GET /api/audit/latest`
- `GET /api/radar`
- `GET/POST /api/settings`
- `GET/POST /api/channels/*`
- `GET/POST /api/features/*`

UI:

- `web/index.html`: основной dashboard и chat UI.
- `web/memory.html`: просмотр и редактирование памяти.

Без токена `/api/status` может возвращать `401`. Это значит "сервер жив и требует auth", а не "сервер сломан".

## 7. Жизненный цикл задачи

Обычная задача пользователя:

1. Пользователь пишет в UI/API.
2. `server.ps1` добавляет сообщение в conversation активного канала.
3. `driver.ps1 -Channel <slug>` видит задачу в loop.
4. Driver классифицирует intent и режим.
5. Driver собирает transcript:
   - свежий чат;
   - Project Context Pack;
   - semantic memory recall;
   - code recall;
   - runtime/safety context.
6. Planner формирует план и инструкции.
7. Coder правит файлы и отдаёт отчёт.
8. Critic/retry проверяет результат, если применимо.
9. Driver запускает нужные проверки и коммитит принятые изменения.
10. Project memory markers и worklog сохраняются.
11. UI получает события завершения/статуса.

Fast-lane:

- Безопасные короткие команды могут обходить тяжёлый planner/coder loop.
- Явный `[[FAST]]` считается только первой непустой строкой.
- Описание задачи, где `[[FAST]]` встречается в середине текста, не должно включать fast-lane.

Автономная задача:

1. Idle gate ждёт тишину.
2. Safety reflex проверяет недавние регрессы.
3. Backlog выбирает задачу, разрешённую текущим risk tier.
4. Driver исполняет её через обычный защищённый путь.
5. Metrics/post-mortem оценивают, помогла ли правка.

Проектная автономия:

1. Project channel idle или backlog pressure низкий.
2. `Start-ProjectAutopilotIfNeeded` проверяет binding, clean project git, cooldown и лимит batch.
3. Coordinator task просит planner вернуть `[[PROJECT_BACKLOG]]` JSON atoms.
4. Driver парсит marker, создаёт approved project tasks и скрывает marker из видимого ответа.
5. Обычная автономия берёт эти tasks одну за другой или через workpack-batch, если они независимы.

Project quality gates:

- `Get-TaskRepoRoot` выбирает bridge repo или project repo для base commit, diff, critic и SHA checks.
- Plan-only `STATUS: DONE` для backlog tasks запрещён без реальных действий, `COVERED:` или новых project atoms.
- `Test-QualityBypassesInDiff` блокирует добавленные обходы качества (`ignoreBuildErrors`, `@ts-nocheck`,
  `|| true`, forced `exit 0` в verify).

## 8. Онбординг нового проекта

Для каждой новой вкладки/проекта правильный поток:

1. Создать или обновить канал с `project_root`.
2. Создать `PROJECT_MAP.md` в корне этого проекта.
3. Проиндексировать код для этого project scope.
4. Записать typed project memory:
   - факты архитектуры;
   - тесты и команды проверки;
   - риски и invariants;
   - решения;
   - открытые вопросы.
5. Довести readiness хотя бы до `yellow`, лучше до `green`.
6. Только после этого давать крупные задачи на реализацию.

Карта проекта должна отвечать:

- Что проект делает?
- Какие файлы и модули важны?
- Как проект запускается?
- Как проект тестируется?
- Что нельзя ломать?
- Какие риски и неизвестные?
- Какой следующий полезный шаг?

## 9. Проверки

ParseFile для изменённых `.ps1`:

```powershell
$e=$null;$t=$null
[void][System.Management.Automation.Language.Parser]::ParseFile('lib\project-context.ps1',[ref]$t,[ref]$e)
if($e){$e}else{'OK'}
```

Self-test драйвера:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\driver.ps1 -Channel main -SelfTest
```

Тесты памяти и project context:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test-project-memory.ps1
```

Fast-lane regression:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test-fastlane-routing.ps1
```

Live status:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\live-status.ps1
```

Health check из runbook:

```powershell
# См. MONITORING_RUNBOOK.md, раздел 2.
```

## 10. Главные риски

- `driver.ps1` - большой монолит. Безопаснее точечные правки, чем широкие рефакторинги.
- PowerShell 5.1 легко ломается современным синтаксисом.
- `.ps1` должны оставаться UTF-8 with BOM.
- OneDrive может гонять или портить runtime JSON во время sync.
- Частые рестарты могут включить circuit-breaker.
- `memory/map.md` генерируется и может быть перезаписан.
- Vector memory может вернуть устаревший факт, если не проверять evidence freshness.
- Один `codex.lock` сериализует Codex между каналами.
- Project root внешнего проекта должен быть изолирован от bridge root.
- `selfExecuteTier=yellow` разрешает реальные изменения кода; red-tier защита должна оставаться консервативной.
- Платные LLM/API вызовы должны быть бюджетно ограничены.
- Watchdog/supervisor имеют высокий blast radius.

## 11. Текущее состояние реализации

Недавно сделано:

- Evidence-backed project memory v2.
- Project Context Pack добавлен в prompt driver.
- Typed project memory markers.
- Project worklog после задач.
- Индексация не только PowerShell, но и типовых проектных файлов.
- Исправлен false-positive fast-lane для `[[FAST]]`.
- Добавлен canonical `PROJECT_MAP.md`, который имеет приоритет над сгенерированным `memory/map.md`.
- Добавлен Project Autopilot: project backlog atoms генерируются через `[[PROJECT_BACKLOG]]`, без ручного кормления.
- Project tasks разрешены в project-каналах даже при глобальном bridge scope; `main` остаётся защищён.
- Добавлен guard против plan-only DONE для автономных backlog tasks.
- Project diff/critic/SHA checks переведены на repo активного проекта через `Get-TaskRepoRoot`.
- Добавлен deterministic quality bypass detector для dangerous build/typecheck bypasses.

Последние проверки этой карты:

- `tools/test-project-memory.ps1`: PASS.
- `tools/test-fastlane-routing.ps1`: PASS.
- `driver.ps1 -Channel main -SelfTest`: PASS.
- `git diff --check`: только стандартные предупреждения Git о CRLF.
- Рабочее дерево после коммита: clean.

## 12. План развития

### P0 - Удержать стабильность

- Регулярно читать health по runbook.
- Не ослаблять restart-storm защиту.
- Сохранять ParseFile и self-test gates.
- Укреплять защиту от stale state и OneDrive races.
- Не править supervisor/watchdog без сильной причины.

### P1 - Сделать проектную память рабочей для каждой вкладки

- Использовать `PROJECT_MAP.md` в корне каждого проекта.
- Добавить UI-индикатор readiness/context.
- Сделать onboarding-команду: индекс кода, тестовые команды, начальная typed memory.
- Показать stale-evidence report.
- Сохранить совместимость со старой памятью.

### P2 - Улучшить понимание больших проектов

- Генерировать предложения обновления project map.
- Писать архитектурные факты как evidence-backed typed records.
- Делать incremental code index и code stats по каналам.
- Добавить summary "что знаем / что неизвестно" по каждому проекту.
- Для крупных задач сначала строить DAG/plan, потом писать код.

### P3 - Повысить надёжность автономии

- Связать autonomy с readiness: `red` проект только изучать, не менять.
- Требовать известные тесты перед изменением нового проекта.
- Усилить post-task quality scoring.
- Улучшить canary/stable promotion.
- Показать safety-reflex в UI.

### P4 - Масштабировать до настоящей multi-project команды

- Изолировать worktrees и memory stores по проектам.
- Включать parallel workers только при `green` readiness.
- Добавить per-project budgets, risk tiers, allowed operations.
- Добавить per-project audit schedules.
- Разрешать генерацию внешних коммерческих проектов только после стабильных foundation metrics.

## 13. Правила обновления карты

Обновлять этот файл, если:

- добавлен новый core module;
- изменилась модель каналов или project scope;
- изменилась память/context behavior;
- изменились safety boundaries;
- появилась новая обязательная проверка;
- изменилась roadmap.

Не записывать сюда secrets, tokens, приватные API-значения и случайные детали чата.
