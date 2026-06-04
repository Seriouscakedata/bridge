# Operatorless Delivery Loop — план развития моста до команды без внешнего ревьюера

> Цель: превратить мост из "автопилота с оператором" в команду полного цикла.
> Человек дает входную цель и границы. Дальше мост сам планирует, декомпозирует,
> исполняет, ревьюит, тестирует, параллелит, принимает, откатывает, обновляет память
> и докладывает результат.

Дата плана: 2026-06-03.

---

## 1. Зачем это нужно

Сейчас у моста уже есть большая часть фундамента:

- Discuss-First planning;
- Project Autopilot;
- project-contract gate;
- per-channel memory;
- typed project memory;
- Project Context Pack;
- critic/verify;
- acceptance;
- workpack ready-frontier;
- parallel workers в git-worktree;
- supervisor/watchdog/circuit-breaker;
- restart coalescer;
- DecisionContract/Intent Shadow.

Но текущий режим все еще не полностью operatorless:

- оператор/Codex часто ревьюит план и критичные атомы;
- acceptance уже есть, но должен стать обязательной приемкой против project-contract;
- parallel workers подключаются скорее опционально, а не как штатный путь для независимых задач;
- мост не всегда сам доказывает, почему задача идет serial, если ее можно было распараллелить;
- self-model еще не стал обязательной свежей моделью самого моста в каждом turn.

Целевая архитектура:

```text
Human input
  -> Project Contract
  -> Deep staged planning
  -> Workpack decomposition
  -> Parallel execution where safe
  -> Internal multi-role review
  -> Deterministic merge/release gate
  -> Acceptance agent
  -> Canary/rollback if bridge-self change
  -> Memory + SelfModel refresh
  -> Operator report
```

Ключевой принцип:

> Внешнее ревью убирается не доверием к одной модели, а заменой на независимые внутренние роли,
> deterministic gates, acceptance scenarios, canary и rollback.

---

## 2. Что НЕ создавать заново

Этот проект не должен плодить параллельную систему рядом с мостом.

Переиспользовать:

- `PROJECT_WORKFLOW.md` как базовый workflow;
- `Project Autopilot` как штатный генератор backlog atoms;
- `.bridge/project-contract.json` как machine-readable source of truth;
- `lib/backlog.ps1` для project backlog markers;
- `lib/parallel.ps1` и workpack ready-frontier для параллельной работы;
- `lib/project-acceptance.ps1` для финальной приемки;
- `lib/memory.ps1` + `lib/project-context.ps1` для typed memory/context;
- DecisionContract/Intent Shadow как путь к model-proposes / guard-validates;
- supervisor/watchdog/circuit-breaker/restart coalescer для защиты.

Не делать:

- отдельный "операторский мозг" рядом с мостом;
- ручной self-model document как новый source of truth;
- новый store памяти вместо existing typed memory;
- модельный merge без deterministic gate;
- параллельность без touch-set/dependency validation.

---

## 3. Режимы зрелости

Развитие должно идти ступенями. Нельзя сразу включить полный operatorless для всего.

### Mode 0 — Shadow

Мост строит contract, план, parallel waves, review verdicts и acceptance report, но не меняет текущие решения.

Цель: накопить evidence и поймать ложные классификации.

### Mode 1 — Assisted

Мост сам исполняет low/normal-risk project tasks, но critical bridge-self changes проходят усиленные deterministic gates.

Внешний оператор не ревьюит код, только видит итоговые отчеты.

### Mode 2 — Operatorless

Мост сам ведет проект от входной цели до acceptance.

Человек участвует только на входе:

- цель;
- границы;
- запреты;
- доступы;
- желаемый результат.

### Mode 3 — Bridge-Self Operatorless

Мост сам развивает собственную архитектуру.

Дополнительные защиты:

- SelfModel обязателен;
- prompt/memory/guard/supervisor/watchdog changes идут через canary;
- restart только после deterministic preflight;
- live-verify после restart;
- auto-rollback при health/acceptance failure.

---

## 4. Главы разработки

### Глава A. SelfModel как основа самопонимания

Статус: обсуждение уже проведено, план принят с поправками.

Назначение:

- мост видит актуальную компактную модель самого себя;
- prompt path только читает generated cache;
- refresh/drift работают отдельно;
- SelfModel не заменяет guard и не является новой памятью.

Атомы:

1. `lib/self-model.ps1`: read-only generator v1.
2. `tools/refresh-self-model.ps1`: cache refresh.
3. generated cache в runtime/channel cache с marker `generated`.
4. `driver/30-prompt-agent-state.ps1`: inject cache в `Build-Prompt`, normal + fast-lane.
5. `tools/self-model-drift.ps1`: drift audit.
6. post-task refresh hook.
7. docs + tests.

Acceptance:

- prompt path не сканирует registry/git/memory;
- self-model block присутствует в main normal и fast-lane prompts;
- memory recall не пропал;
- pack size: base 1.5-2.5 KB, expanded 3-4 KB только для bridge-self задач;
- stale pack не ломает turn.

### Глава B. Project Contract как единственный входной контракт

Назначение:

- любая цель превращается в machine-readable contract;
- Project Autopilot не имеет права генерировать backlog без глубокого контракта;
- acceptance строится из contract, а не из "кажется готово".

Атомы:

1. Расширить `.bridge/project-contract.json` до delivery contract:
   - goal;
   - users/roles;
   - scope/non-goals;
   - allowed operations;
   - forbidden operations;
   - screens/routes;
   - user journeys;
   - data model;
   - acceptance scenarios;
   - required checks;
   - risk level;
   - parallel policy.
2. Добавить validator для contract shape/depth.
3. Добавить "contract completeness score".
4. Запретить plan approval, если contract shallow.
5. Добавить report в чат: что принято, что неполно, что блокирует.

Acceptance:

- shallow plan не проходит;
- missing UX/backend/QA sections блокируют autopilot;
- изменения contract сбрасывают approval signature;
- final acceptance читает contract.

### Глава C. Deep staged planning без внешнего ревью

Назначение:

- заменить операторское ревью плана внутренним staged review;
- каждая стадия учитывает предыдущую;
- интеграционная стадия ловит противоречия до backlog.

Базовый порядок уже зафиксирован:

```text
brief -> product -> UX -> UI -> backend -> QA -> integration
```

Атомы:

1. Сделать stage contracts обязательными:
   - `PROJECT_BRIEF.md`;
   - `DISCUSS_PRODUCT.md`;
   - `DISCUSS_UX.md`;
   - `DISCUSS_UI.md`;
   - `DISCUSS_BACKEND.md`;
   - `DISCUSS_QA.md`;
   - `DISCUSS_INTEGRATION.md`;
   - `PROJECT_MAP.md`;
   - `PROJECT_PLAN.md`.
2. Добавить internal stage reviewers:
   - product reviewer;
   - UX reviewer;
   - UI reviewer;
   - backend reviewer;
   - QA reviewer;
   - integration reviewer.
3. Каждый reviewer возвращает structured verdict:
   - pass/fail;
   - missing decisions;
   - contradictions;
   - required fixes;
   - acceptance impact.
4. Integration stage обязан закрыть все contradictions.

Acceptance:

- backlog atoms не создаются, пока integration verdict не pass;
- каждая stage doc ссылается на предыдущие решения;
- QA scenarios покрывают product/UX/UI/backend decisions;
- operator approval больше не нужен для глав в operatorless mode, но отчет глав пишется в чат.

### Глава D. Parallel-by-default decomposition

Назначение:

- параллели должны быть штатным путем, а не опциональной удачей;
- если независимые задачи можно выполнить параллельно, мост обязан это сделать;
- если не делает, обязан объяснить serial reason.

Правило:

> Любая генерация project backlog должна сначала строить dependency graph и ready-frontier.
> Если есть 2+ ready atoms с непересекающимися touch sets и разными conflict groups,
> bridge обязан запустить workpack batch / parallel wave, если parallel enabled и readiness green/yellow.

Обязательная metadata для каждого атома:

```json
{
  "slug": "stable-id",
  "title": "short atom title",
  "task": "one small verifiable change",
  "chapter": "chapter-id",
  "wave": "wave-1",
  "parallel_group": "ui-auth",
  "files": ["relative/path.tsx"],
  "depends_on": [],
  "workpack_conflict_group": "file:relative/path.tsx",
  "workpack_touch_set": ["relative/path.tsx"],
  "acceptance": ["specific assertion"],
  "checks": ["npm run typecheck", "npm run build"],
  "risk": "low|normal|high",
  "serial_reason": ""
}
```

Если atom нельзя параллелить:

```json
{
  "serial_reason": "touches shared auth state used by wave-1"
}
```

Атомы:

1. Добавить validation: project atoms без `files`, `depends_on`, `workpack_conflict_group`,
   `workpack_touch_set`, `acceptance`, `checks` считаются incomplete.
2. Добавить parallel eligibility report:
   - ready atoms;
   - selected atoms;
   - blocked by deps;
   - blocked by file conflicts;
   - blocked by risk/readiness;
   - serial reasons.
3. Добавить "parallel obligation":
   - если eligible >= 2, а batch size = 1, это warning/finding;
   - если eligible >= 2 три раза подряд и parallel не используется, создать backlog task на диагностику.
4. Для stage decomposition требовать waves:
   - foundation serial;
   - independent feature atoms parallel;
   - integration serial;
   - acceptance serial.
5. Сохранять wave outcome в project memory.

Acceptance:

- на синтетическом backlog из 5 независимых atoms scheduler выбирает batch >1;
- атомы с пересекающимся touch-set не попадают в один batch;
- атомы с depends_on ждут, но не блокируют независимые ready atoms;
- в чате виден отчет, почему параллель была или не была применена.

### Глава E. Internal Review Board вместо внешнего ревьюера

Назначение:

- ревью делают независимые роли внутри моста;
- итог merge/release решает deterministic gate, а не одна модель.

Роли:

- architect reviewer: архитектура, модульные границы, переиспользование;
- code reviewer: diff, bugs, maintainability;
- security reviewer: secrets, auth, destructive ops, injection, unsafe commands;
- regression reviewer: что могло сломаться из существующего;
- acceptance reviewer: соответствие contract/user journeys;
- memory/self-model reviewer: обновлены ли memory/worklog/SelfModel;
- parallel reviewer: использованы ли параллели там, где можно.

Structured verdict:

```json
{
  "role": "security-reviewer",
  "verdict": "pass|fail|warn",
  "confidence": 0.0,
  "findings": [
    {
      "severity": "blocker|major|minor",
      "file": "relative/path",
      "line": 0,
      "message": "specific issue",
      "required_fix": "specific fix"
    }
  ],
  "acceptance_impact": "none|partial|blocking"
}
```

Атомы:

1. Define review verdict schema.
2. Add review collection per atom/wave.
3. Add deterministic review gate:
   - any blocker => no merge;
   - any security fail => no merge;
   - acceptance fail => no release;
   - low-confidence critical review => re-run reviewer or escalate to another model.
4. Persist review summaries to project memory.
5. Surface review board report in chat/UI.

Acceptance:

- reviewer blockers prevent merge;
- warning-only verdict allows merge but records risk;
- review result is durable and visible;
- no external operator/Codex review required in operatorless mode.

### Глава F. Deterministic Merge/Release Gate

Назначение:

- модель предлагает, deterministic bridge применяет;
- merge/release не может пройти только по тексту "готово".

Gate checks:

- repo clean before claim;
- worktree isolated;
- no forbidden file changes;
- no destructive command patterns;
- no guard/watchdog/safety disable;
- no quality bypass in diff;
- parse/build/typecheck/smoke pass;
- required acceptance scenarios pass;
- review board pass;
- parallel obligation satisfied or justified;
- memory/worklog updated;
- SelfModel refreshed if bridge-self changed;
- canary passed if bridge-self critical path changed.

Атомы:

1. Add `delivery-gate` schema/result.
2. Reuse existing safety/verify functions; do not duplicate.
3. Add missing checks only where existing gate lacks coverage.
4. Make gate result a durable JSON artifact per wave/release.
5. Add chat summary.

Acceptance:

- forced quality bypass fails gate;
- missing acceptance scenario fails release;
- missing memory update warns or fails depending on risk;
- bridge-self prompt-path change requires canary/live-verify.

### Глава G. Acceptance Agent как настоящий приемщик

Назначение:

- приемка проверяет продукт как пользователь, а не только build;
- для UI проектов агент открывает сайт, регистрируется, логинится, кликает маршруты, проверяет 404,
  empty/error states и админские действия.

Атомы:

1. Расширить `.bridge/project-contract.json` `acceptance_scenarios`.
2. Для web projects генерировать deterministic browser scenario plan:
   - routes;
   - expected statuses;
   - expected text;
   - forms/actions;
   - role flows;
   - screenshots if needed.
3. Acceptance agent executes scenarios via existing web-smoke/browser tooling.
4. Fail on:
   - 404 after login/profile;
   - broken navigation;
   - missing role flow;
   - build-only success with scenario failure.
5. Store acceptance report.

Acceptance:

- Instagram-like example would fail if login redirects to missing profile;
- admin panel route is tested if contract mentions admin;
- report includes exact failed step, URL, expected/actual.

### Глава H. Bridge-self canary and rollback

Назначение:

- мост может сам себя развивать без внешнего ревьюера;
- critical self changes проходят canary/restart/live-verify/rollback.

Critical areas:

- `driver/30-*` prompt path;
- `driver/81-*` claim path;
- `driver/84-*` markers;
- `driver/86-*` completion;
- `lib/memory.ps1`;
- `lib/project-context.ps1`;
- `lib/backlog.ps1`;
- `lib/parallel.ps1`;
- `lib/decision-contract.ps1`;
- `server.ps1`;
- `supervisor.ps1`;
- `watchdog.ps1`;
- `lib/circuit-breaker.ps1`;
- config/settings/security.

Атомы:

1. Define critical path classifier.
2. Add bridge-self gate:
   - ParseFile all touched `.ps1`;
   - self-tests;
   - smoke;
   - canary task;
   - controlled restart if needed;
   - health check;
   - live-verify.
3. Add auto-rollback condition:
   - health red;
   - restart storm;
   - prompt path cannot build;
   - memory recall missing after prompt change;
   - claim path broken.
4. Persist result to memory/SelfModel.

Acceptance:

- prompt inject change cannot be accepted without prompt smoke;
- bad `.ps1` parse blocks before restart;
- failed restart rolls back or freezes with clear report.

### Глава I. Memory and SelfModel after every delivery

Назначение:

- мост должен помнить не просто "что сделал", а почему, как проверил, какие риски остались.

Required records:

- `project_worklog`: что сделано;
- `project_decision`: важные решения;
- `project_test`: как проверять;
- `project_risk`: остаточные риски;
- `project_invariant`: новые правила;
- `project_open_question`: что осталось неясным.

Атомы:

1. Add post-delivery memory checklist.
2. Gate missing memory for bridge-self changes.
3. Refresh SelfModel after critical self changes.
4. Drift audit after SelfModel refresh.

Acceptance:

- after a wave, memory has worklog;
- after bridge-self architecture change, SelfModel reflects it;
- stale evidence is detected or marked.

### Глава J. UI/Telemetry для operatorless режима

Назначение:

- человек не ревьюит код, но должен видеть, что делает команда;
- чат и пульт показывают прогресс, параллели, review board и acceptance.

Показывать:

- current contract status;
- planning stage status;
- backlog pressure;
- parallel eligibility;
- active wave;
- worker count;
- review verdicts;
- gate result;
- acceptance result;
- memory/SelfModel refresh status;
- blockers.

Acceptance:

- оператор видит, почему мост serial/parallel;
- оператор видит, какой gate заблокировал release;
- оператор не должен читать raw logs, чтобы понять состояние.

---

## 5. Обязательная политика параллельности

Параллельность должна стать default behavior для независимых задач.

### 5.1 Когда параллель обязательна

Если выполнены все условия:

- project readiness `green` или допустимый `yellow`;
- parallel enabled;
- есть минимум 2 ready atoms;
- `depends_on` закрыты или отсутствуют;
- touch sets не пересекаются;
- conflict groups разные;
- нет serial barrier (`foundation`, migration, shared schema, critical bridge-self prompt path);
- repo clean;
- disk/worktree capacity ok.

Тогда scheduler должен запускать batch/wave, а не single atom.

### 5.2 Когда serial допустим

Serial допустим только если есть причина:

- foundation/integration barrier;
- shared file/schema/state;
- unresolved dependency;
- critical bridge-self path;
- failing readiness;
- insufficient worker capacity;
- previous parallel wave produced conflict/quarantine;
- acceptance/release step.

Причина должна быть записана:

- в чат;
- в wave telemetry;
- при необходимости в project memory.

### 5.3 Parallel reviewer

После каждой project backlog generation и после каждой wave:

- проверить, были ли eligible atoms;
- проверить, был ли batch >1;
- если нет, записать serial reason;
- если reason пустой, создать finding.

---

## 6. План разработки атомами

### Phase 1 — SelfModel foundation

Исполнитель: мост.

Параллельность:

- generator/drift/docs можно делать параллельно;
- prompt injection serial и только после cache/generator tests.

Атомы:

1. SelfModel generator v1.
2. SelfModel refresh tool.
3. SelfModel drift tool.
4. SelfModel tests.
5. Prompt inject.
6. Post-task refresh hook.
7. Docs.

### Phase 2 — Contract and planning hardening

Параллельность:

- contract schema, stage docs validator, acceptance schema can run parallel;
- approval signature/gate serial after validators.

Атомы:

1. Delivery contract schema.
2. Contract depth validator.
3. Stage chain validator.
4. Integration contradiction report.
5. Contract approval signature update.
6. Chat report.

### Phase 3 — Parallel-by-default

Параллельность:

- this phase itself should use synthetic tests first;
- scheduler changes serial if touching shared backlog/parallel internals.

Атомы:

1. Atom metadata validator.
2. Parallel eligibility reporter.
3. Parallel obligation warning/finding.
4. Synthetic independent backlog test.
5. Synthetic conflict/dependency test.
6. Chat/UI wave reason output.

### Phase 4 — Internal Review Board

Параллельность:

- reviewer schemas and individual reviewer prompts/tools can run parallel;
- deterministic gate integration serial.

Атомы:

1. Review verdict schema.
2. Architect reviewer.
3. Security reviewer.
4. Regression reviewer.
5. Acceptance reviewer.
6. Memory/SelfModel reviewer.
7. Parallel reviewer.
8. Review collection/gate.

### Phase 5 — Deterministic delivery gate

Параллельность:

- tests for separate gate rules can run parallel;
- merge/release gate integration serial.

Атомы:

1. Delivery gate result artifact.
   - Status note: Delivery Gate facts collector added as shadow foundation; live shadow-report wiring is a later atom.
   - Status note: Atom 9 shadow-report wiring added for successful normal DONE; promotion to blocking/release gate remains future and evidence-based.
   - Status note: Atom 10 binds deterministic acceptance facts for shadow-only reports; blocking promotion remains future and evidence-based.
2. Reuse existing safety/verify checks.
3. Add missing acceptance check binding.
4. Add quality bypass hard fail.
5. Add bridge-self critical path classifier.
6. Gate summary in chat.

### Phase 6 — Acceptance Agent upgrade

Status note: Atom 11 adds deterministic user journey scenario extraction into project acceptance; browser/web-smoke execution remains a future atom.

Параллельность:

- route/status checks, auth scenario checks, admin scenario checks can develop parallel;
- final report integration serial.

Атомы:

1. Contract route checks.
2. User journey scenario format.
3. Browser/web-smoke executor integration.
4. Screenshot/report artifacts.
5. Failure classification.
6. Final project acceptance gate.

### Phase 7 — Bridge-self operatorless canary

Параллельность:

- read-only classifiers/tests can run parallel;
- restart/live-verify/rollback logic serial.

Атомы:

1. Critical path classifier.
2. Prompt smoke for prompt-path changes.
3. Claim smoke for claim-path changes.
4. Memory recall smoke.
5. Controlled restart live-verify gate.
6. Rollback/freeze report.

### Phase 8 — UI/Telemetry

Параллельность:

- API read endpoints and UI panels can run parallel if files do not overlap;
- final UI integration serial.

Атомы:

1. Contract status endpoint.
2. Parallel eligibility endpoint.
3. Review board endpoint.
4. Gate result endpoint.
5. Acceptance report endpoint.
6. Dashboard panels.

---

## 7. Acceptance for the whole project

Operatorless Delivery Loop считается готовым, когда:

1. Новый тестовый проект можно запустить из одной идеи.
2. Мост сам создает contract/stage docs/map/plan.
3. Мост сам генерирует approved atoms через Project Autopilot.
4. Независимые atoms выполняются параллельно.
5. Если parallel не применяется, есть serial reason.
6. Внутренние reviewers дают structured verdicts.
7. Deterministic gate блокирует опасные/неполные изменения.
8. Acceptance agent ловит broken routes/login/profile/admin scenarios.
9. Bridge-self prompt/memory/guard changes проходят canary/live-verify.
10. Memory и SelfModel обновляются после результата.
11. В чат/пульт выводится понятный отчет без чтения raw logs.

---

## 8. Первый запрос мосту на исполнение

Когда этот план будет передан мосту, первая задача должна быть не "реализуй все", а:

```text
[[DEEP-THINK]]
DISCUSS-ONLY.

Тема: Operatorless Delivery Loop implementation plan.

Прочитай OPERATORLESS_DELIVERY_LOOP_PLAN.md, PROJECT_WORKFLOW.md, DEVELOPER_GUIDE.md,
PROJECT_MAP.md и текущий WORK_COORDINATION.md.

Цель: подготовить исполнимый план Phase 1 -> Phase 3 без внешнего ревьюера:
SelfModel foundation, Contract hardening, Parallel-by-default.

Нужно:
1. Проверить, какие части уже реализованы.
2. Найти пересечения с активными claim'ами.
3. Разложить Phase 1 на атомы с files/touch_set/depends_on/checks/acceptance.
4. Отдельно указать, какие атомы можно делать параллельно, а какие serial и почему.
5. Вернуть PROJECT_BACKLOG только после deep plan и без нарушения WORK_COORDINATION.

Нельзя:
- трогать safety/verify/guard без отдельного bridge-self gate;
- писать код в discuss-turn;
- создавать новую память вместо existing typed memory;
- делать prompt-path генерацию вместо cache-read.
```

После обсуждения мост должен сам создать/обновить атомы через `[[PROJECT_BACKLOG]]`.

---

## 9. Риски

### Риск 1. "Operatorless" превратится в самоуверенность модели

Смягчение:

- independent review roles;
- deterministic gate;
- acceptance scenarios;
- canary/rollback;
- shadow/assisted/operatorless modes.

### Риск 2. Параллельность начнет ломать shared files

Смягчение:

- required touch sets;
- conflict groups;
- ready-frontier;
- quarantine on conflict;
- serial barriers for foundation/integration/shared schema.

### Риск 3. Prompt/context раздуется

Смягчение:

- SelfModel base 1.5-2.5 KB;
- expanded only for bridge-self;
- prompt path reads cache only;
- cap tests.

### Риск 4. Acceptance станет формальной

Смягчение:

- contract-based journeys;
- browser/web-smoke real checks;
- fail on 404/broken navigation/login/profile;
- report exact URL/step.

### Риск 5. Мост сломает сам себя

Смягчение:

- bridge-self critical path classifier;
- ParseFile/self-test/smoke;
- canary;
- controlled restart;
- live-verify;
- rollback/freeze.

---

## 10. Главный инвариант

> Мост может быть без внешнего ревьюера только тогда, когда у него есть внутренние независимые роли,
> deterministic gates и настоящая acceptance-приемка. Одна модель не должна быть последней инстанцией
> для собственного кода, merge или release.

