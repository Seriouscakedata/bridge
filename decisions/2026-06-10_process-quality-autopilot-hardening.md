# 2026-06-10 — Process-quality: autopilot hardening (связность, spec-faithfulness, production-real)

**Статус:** DESIGN / operator review. Код НЕ менялся — этот док = MAP/PLAN + атомы.
**Триггер:** bridge audit «Болезнь 2» (автономно построенные проекты build-green, но бессвязные) + slopvid post-mortem:
- `pipeline.py` вырос до 1687 строк, cats-rule переписан независимо в 4 файлах (нет consolidation);
- UI redesign удалил операторские фичи и прошёл green, потому что атом переписал тесты вместе с кодом (нет spec-pinning);
- в проде биндились stub-валидаторы, классы `Real*` были мертвы, гейт «артефакт >100KB» существовал только в тексте плана (нет real-path acceptance).

**Констрейнт (Foundation #2):** ТОЛЬКО харднинг существующего autopilot/acceptance/delivery-gate flow. Никаких новых подсистем, демонов, отдельных конфиг-деревьев. Все атомы трогают уже существующие файлы: `lib/backlog-autopilot.ps1`, `lib/project-acceptance.ps1`, `lib/delivery-gate-facts.ps1`, `lib/delivery-mode.ps1`.

---

## MAP — как процесс устроен сейчас (file:line evidence)

Поток: **plan gate → coordinator → atom ingest → workers → QA/delivery gate → project acceptance**.

1. **Plan gate.** Autopilot стартует только при `plan_approved=true` и совпадении signature: `Test-ProjectPlanApproved` — `lib/backlog-autopilot.ps1:818-850`; вызов в `Start-ProjectAutopilotIfNeeded` — `lib/backlog-autopilot.ps1:918-920`. Signature = SHA256 над фиксированным набором plan-файлов (`DISCUSS_*.md`, `PROJECT_MAP.md`, `PROJECT_PLAN.md`, `.bridge/project-contract.json`): `Get-ProjectAutopilotPlanSignatureFiles` — `lib/backlog-autopilot.ps1:340-349`. Штамп ставит `Set-ProjectPlanApproved` (`plan_approved_signature`, `plan_approved_git_head`) — `lib/backlog-autopilot.ps1:876-891`.
2. **Coordinator.** Один coordinator-таск на пустой backlog: `Start-ProjectAutopilotIfNeeded` — `lib/backlog-autopilot.ps1:1015-1017`. Промпт `New-ProjectAutopilotCoordinatorTaskText` — `lib/backlog-autopilot.ps1:739-816`: декомпозирует ОДНУ главу в атомы, требует DAG (`depends_on`, `wave`, `parallel_group` — :771-773), схема атома :787-810. **Нет** понятия shared-infra-атомов и **нет** integrator-прохода между волнами — волны соединяются только через depends_on, никто не читает combined diff.
3. **Ingest gate.** `Add-ProjectBacklogFromMarker` — `lib/backlog-autopilot.ps1:1291-1376`; детерминированная проверка полноты атома `Test-ProjectAutopilotTaskMetadata` (slug/title/task/files/acceptance/checks/risk) — `lib/backlog-autopilot.ps1:1194-1217`. **Files-touchset атома никак не проверяется на запрещённые пути** — атом может легально объявить `files: [".bridge/project-contract.json", "tests/..."]`.
4. **QA.** Для project-каналов — только toolchain: `Invoke-ProjectBuildGate` (install→typecheck→build) — `lib/qa-agent.ps1:109-160`. Сценарии (`Invoke-QAAgentScenarioSuite` — `lib/qa-agent.ps1:162-264`) гоняются против самого bridge, не против проекта.
5. **Delivery gate.** Запрещённые пути `Test-DeliveryGateForbiddenPath` — `lib/delivery-gate-facts.ps1:174-189` (только `.git`, `.bridge-runtime`, `node_modules`, uploads, secrets, `.env`, db). Критичные bridge-пути `Test-DeliveryCriticalBridgePath` — `lib/delivery-mode.ps1:115-137` (`supervisor.ps1`, `watchdog.ps1`, `config.json`...) — для non-main каналов требуют bridge-self+acceptance evidence (`Test-DeliveryGateForbiddenChanges` — `lib/delivery-gate-facts.ps1:298-319`). **Контракт проекта и тестовые/acceptance-файлы проекта не защищены ничем.**
6. **Project acceptance.** `Invoke-ProjectAcceptance` — `lib/project-acceptance.ps1:1055-1308`: plan-contract depth/counts (:1077-1079, реализация `Get-ProjectAcceptancePlanContractSteps` :730-782), tracked-artifacts (:1080-1086), journey coverage (:1087-1088), npm scripts typecheck/lint/build (:1090-1101), web-сервер + HTTP-статусы + `must_contain` токены (:1103-1176), smoke (:1178-1205). Отчёт пишет `plan_signature` (:1224), но **не сравнивает его с approved signature канала**. Отсутствующий объявленный скрипт = `'missing script, skipped'` + **ok=true** (:1093-1096) — green по умолчанию. **Нет** проверок размера модулей, дубликатов символов, stub-биндингов, realness артефактов, non-fixture прогона.

Примечание по evidence: сами инстансы `.bridge/project-contract.json` живут в project root'ах вне этого worktree (read недоступен из песочницы); формат восстановлен по читателям: поля `project_goal/requirements/screens/routes/user_journeys/acceptance_scenarios/ux_contract/planning_flow` — `lib/backlog-autopilot.ps1:677-711` и `lib/project-acceptance.ps1:749-781`; `surfaces[].kind`, `checks[].command` — `lib/project-acceptance.ps1:916-933`.

**Корневая причина всех трёх болезней:** все гейты проверяют свойства *одного атома* или *одного билда*. Ни один механизм не смотрит на (a) сумму diff'ов волны, (b) неизменность спеки относительно момента approve, (c) путь от production entrypoint до реального артефакта.

---

## (A) CONSOLIDATION PASS — связность кодовой базы

### Как сейчас (evidence)

- Coordinator эмитит атомы одной главы и умирает; следующий coordinator стартует только когда backlog пуст (`Start-ProjectAutopilotIfNeeded` — `lib/backlog-autopilot.ps1:939-941`, `1015-1017`). Между волнами никто не читает суммарный diff.
- В схеме атома (`lib/backlog-autopilot.ps1:787-810`) нет типа атома: infra/feature/consolidation неразличимы; промпт не требует «общие модули первыми».
- Acceptance не имеет ни одного шага про структуру кода (полный список шагов: `lib/project-acceptance.ps1:1077-1205`).
- Боль: slopvid `pipeline.py` 1687 строк; cats-rule продублирован в 4 файлах — каждый параллельный worker изобрёл свою копию, и никто не имел задачи «склей».

### Дизайн

1. **Shared-infra атомы первыми.** Промпт coordinator'а (`New-ProjectAutopilotCoordinatorTaskText`) дополняется правилами: (a) каждая глава начинается с wave-1 атомов с `kind:"infra"` — общие модули/типы/утилиты, на которые feature-атомы ссылаются через `depends_on`; (b) feature-атом, использующий общую логику (валидация, форматирование, доступ к данным), обязан зависеть от infra-атома, а не реализовывать её локально; (c) новое опциональное поле атома `kind: "infra"|"feature"|"consolidation"|"planning"` (default `feature`). Ingest сохраняет `kind` в metadata (расширение `Set-ProjectAutopilotIdeaMetadata` — `lib/backlog-autopilot.ps1:1219-1289`). DAG-механика не меняется — это тот же `depends_on`, который scheduler уже понимает.
2. **Integrator после волны.** В `Start-ProjectAutopilotIfNeeded`, в точке где backlog пуст и autopilot собирается ставить следующий coordinator (`lib/backlog-autopilot.ps1:1015`), добавляется шаг: если с момента `last_integrator_head` (новое поле в `project-autopilot.last.json`, пишется через существующий `Write-ProjectAutopilotState` — :65-71) в проекте появились коммиты от ≥2 атомов — сначала ставится **integrator-таск** (новый промпт-хелпер `New-ProjectAutopilotIntegratorTaskText` рядом с coordinator'ом). Integrator: читает `git diff <last_integrator_head>..HEAD` ЦЕЛИКОМ, ищет дубли/расползание/oversized-файлы и эмитит consolidation-атомы (`kind:"consolidation"`: extract shared module / collapse duplicates / split oversized) через тот же `[[PROJECT_BACKLOG]]`-маркер и тот же ingest. Если консолидировать нечего — завершает без маркера, autopilot записывает head и идёт к следующему coordinator. Это не новая подсистема: тот же idle-hook, тот же Add-Idea, тот же ingest-гейт.
3. **Coherence-чеки в acceptance.** Новая детерминированная функция `Get-ProjectAcceptanceCoherenceSteps` в `lib/project-acceptance.ps1`, шаги добавляются рядом с plan-contract steps (`lib/project-acceptance.ps1:1077-1079`):
   - `coherence:max-module-lines` — ни один source-файл (code extensions, исключая vendored/generated/lock) не превышает порог; default 700 строк, override в `.bridge/acceptance.json` → `coherence.maxModuleLines` (конфиг уже читается `Get-ProjectAcceptanceConfig` — `lib/project-acceptance.ps1:246-284`). slopvid-кейс: 1687 строк = FAIL.
   - `coherence:duplicate-symbols` — regex-скан top-level объявлений (`def|class|function|export const|...`) по source-файлам; один и тот же символ, объявленный в >`coherence.maxDuplicateDefs` (default 1, т.е. 2+ определения = FAIL) файлах, с whitelist (`__init__`, `main`, overload-паттерны). cats-rule-в-4-файлах = FAIL.
   - Пороги детерминированные и дешёвые (чистый file-scan, без LLM), в духе остальных шагов acceptance.

### Атомы

| # | slug | files (touch-set) | acceptance | checks | risk | rollback |
|---|------|-------------------|------------|--------|------|----------|
| A1 | `coordinator-prompt-shared-infra-kind` | `lib/backlog-autopilot.ps1` (только `New-ProjectAutopilotCoordinatorTaskText`, `Set-ProjectAutopilotIdeaMetadata`, `Add-ProjectBacklogFromMarker` — поле kind) | Промпт содержит правила infra-first + поле `kind` в JSON-схеме; ingest принимает атом с `kind` и без него (backward-compat); метадата атома содержит `kind` | `powershell -Command ". lib/backlog-autopilot.ps1"` (parse), юнит-прогон `Add-ProjectBacklogFromMarker` на фикстурном маркере с/без kind | normal | revert одного коммита; старые атомы без kind продолжают работать |
| A2 | `autopilot-integrator-wave-pass` | `lib/backlog-autopilot.ps1` (`Start-ProjectAutopilotIfNeeded`, новый `New-ProjectAutopilotIntegratorTaskText`, state-поле `last_integrator_head`) | При пустом backlog и ≥2 atom-коммитах с `last_integrator_head` ставится integrator-таск ДО следующего coordinator; после integrator-таска head записан; при 0-1 коммитах integrator не ставится | parse + dry-run `Start-ProjectAutopilotIfNeeded` на тестовом канале (проверить queued task text содержит 'integrator') | high (меняет каденс autopilot; риск зацикливания integrator→consolidation→integrator — гасится записью head ДО постановки таска) | убрать вызов integrator-ветки (один if); state-поле безвредно остаётся |
| A3 | `acceptance-coherence-steps` | `lib/project-acceptance.ps1` (новый `Get-ProjectAcceptanceCoherenceSteps` + вызов в `Invoke-ProjectAcceptance`), `lib/project-artifact-policy.ps1` НЕ трогается | Отчёт acceptance содержит шаги `coherence:max-module-lines` и `coherence:duplicate-symbols`; фикстурный проект с файлом 800 строк → FAIL; с дублем символа в 2 файлах → FAIL; пороги переопределяются из `.bridge/acceptance.json` | parse + запуск `Invoke-ProjectAcceptance` на фикстурном мини-проекте | normal | шаги изолированы в одной функции; revert = удалить вызов |

---

## (B) SPEC-PINNED ACCEPTANCE — спека и тесты не переписываются исполнителем

### Как сейчас (evidence)

- Drift спеки **после** approve уже ловится: `Test-ProjectPlanApproved` сверяет текущую signature с `plan_approved_signature`, при несовпадении — git diff plan-файлов против `plan_approved_git_head`; изменены → autopilot стоит (`lib/backlog-autopilot.ps1:835-845` → `:918-920` reason `plan-not-approved`). Re-stamp делает только `Set-ProjectPlanApproved` (`lib/backlog-autopilot.ps1:852-897`).
- НО ничто не мешает atom-worker'у **закоммитить** правку `.bridge/project-contract.json` или `.bridge/acceptance.json`: ingest-гейт не смотрит на `files` (`Test-ProjectAutopilotTaskMetadata` — `lib/backlog-autopilot.ps1:1194-1217` проверяет только наличие полей), а `Test-DeliveryGateForbiddenPath` (`lib/delivery-gate-facts.ps1:174-189`) защищает только инфраструктурные пути bridge. Результат: либо autopilot молча встаёт (плохой, но видимый исход), либо — slopvid-кейс — атом переписывает **тесты** (которые вообще не входят в signature) вместе с кодом, и green ничего не значит.
- Acceptance пишет `plan_signature` в отчёт (`lib/project-acceptance.ps1:1224`), но не сравнивает с approved у канала — drift не виден как FAIL-шаг.
- Образец защиты существует: критичные пути типа `supervisor.ps1` блокируются для non-main каналов без явного evidence (`Test-DeliveryCriticalBridgePath` — `lib/delivery-mode.ps1:115-137`; применение — `lib/delivery-gate-facts.ps1:309-316`).

### Дизайн

1. **Protected paths для project-атомов** — по образцу `Test-DeliveryGateForbiddenPath`. Новая функция `Test-ProjectDeliveryProtectedPath` в `lib/delivery-gate-facts.ps1`: относительно project root защищены `.bridge/project-contract.json`, `.bridge/acceptance.json`, `PROJECT_PLAN.md`, `PROJECT_MAP.md`, `DISCUSS_*.md` (= ровно `Get-ProjectAutopilotPlanSignatureFiles` + acceptance.json). Применение в `Test-DeliveryGateForbiddenChanges` (`lib/delivery-gate-facts.ps1:298-319`) для каналов ≠ main: touch защищённого пути ⇒ `forbidden_changes=true` ⇒ существующий rollback-механизм (`rollback_required` — `lib/delivery-gate-facts.ps1:357`). Исключение: атом с `kind:"planning"` (из секции A) — планирующие атомы легитимно углубляют DISCUSS_*/contract, но после них signature drift всё равно требует re-stamp.
2. **Тот же запрет на входе** — дешевле поймать до запуска: `Add-ProjectBacklogFromMarker`/`Test-ProjectAutopilotTaskMetadata` отклоняют implementation-атом (kind ≠ planning), у которого `files` пересекается с protected set, с ошибкой в `errors[]` (тот же канал, что 'incomplete PROJECT_BACKLOG atom' — `lib/backlog-autopilot.ps1:1322-1328`). Coordinator получает правило в промпт: «контракт и acceptance-фикстуры read-only для implementation-атомов; изменение спеки = planning-атом + re-approve».
3. **Re-stamp только через planning phase.** Механика уже есть (`Set-ProjectPlanApproved` пересчитывает signature и git head). Харднинг: новый acceptance-шаг `plan-contract:signature-matches-approved` — сравнивает текущую `Get-ProjectAcceptancePlanSignature` (`lib/project-acceptance.ps1:664-673`) с `plan_approved_signature` из `channels/<ch>/channel.json`; mismatch = FAIL с details «contract drifted since approval; re-run planning + Set-ProjectPlanApproved». Drift становится видимым красным шагом, а не тихой паузой autopilot.
4. **Diff-shape check: тесты переписаны тем же атомом, что менял код.** В `lib/delivery-gate-facts.ps1` новый факт `tests_rewritten_with_code` (вход в `New-DeliveryGateInputFacts` — `lib/delivery-gate-facts.ps1:321-379`): по `git diff --name-status BaseCommit..HeadCommit` (уже есть plumbing `Get-DeliveryGateTouchedFiles` — :264-288, расширить до name-status); флаг ставится когда в ОДНОМ диапазоне атома есть (a) Modified/Deleted строки по существующим test-файлам (классификация по пути/расширению: `tests/**`, `__tests__/**`, `*.test.*`, `*.spec.*`, `test_*.py`, `conftest.py`) И (b) Modified по non-test source-файлам. Чисто добавленные тесты (status A) флаг не поднимают — TDD и «дописал тесты к фиче» легальны. Это **shape диффа** (статусы по классам путей), не keyword-матчинг текста. Реакция гейта: для project-каналов факт валит `acceptance_ok`-ветку (`Get-DeliveryGateAcceptanceFact` — `lib/delivery-gate-facts.ps1:217-262`) и порождает follow-up: правка ожиданий должна прийти отдельным атомом с явным acceptance «тест изменён потому что спека X изменилась (re-approved)».

### Атомы

| # | slug | files (touch-set) | acceptance | checks | risk | rollback |
|---|------|-------------------|------------|--------|------|----------|
| B1 | `delivery-gate-project-protected-paths` | `lib/delivery-gate-facts.ps1` (`Test-ProjectDeliveryProtectedPath`, wiring в `Test-DeliveryGateForbiddenChanges`) | Для канала ≠ main touch `.bridge/project-contract.json` / `.bridge/acceptance.json` / plan-файлов ⇒ `forbidden_changes=true`; для main поведение не меняется; юнит-фикстуры на оба исхода | parse + table-driven юнит на `Test-ProjectDeliveryProtectedPath` (≥6 путей) | normal | функция новая, wiring = 3-5 строк; revert тривиален |
| B2 | `ingest-reject-protected-touchset` | `lib/backlog-autopilot.ps1` (`Add-ProjectBacklogFromMarker`, `Test-ProjectAutopilotTaskMetadata`, промпт-правило в `New-ProjectAutopilotCoordinatorTaskText`) | Фикстурный маркер с атомом `files:[".bridge/project-contract.json"]`, kind=feature → отклонён с понятной ошибкой; kind=planning → принят; обычный атом → принят | parse + юнит-прогон ingest на 3 фикстурных маркерах | normal | проверка изолирована; revert = удалить ветку |
| B3 | `acceptance-signature-drift-step` | `lib/project-acceptance.ps1` (новый шаг в `Get-ProjectAcceptancePlanContractSteps` или рядом; чтение `channel.json`) | Отчёт содержит `plan-contract:signature-matches-approved`; при подменённом contract → FAIL; при совпадении → PASS; при отсутствии approved signature (legacy канал) → PASS c details `no-approved-signature` | parse + прогон на фикстурном канале с подменой контракта | normal | один шаг; legacy-каналы не ломаются (см. acceptance) |
| B4 | `delivery-gate-diff-shape-test-rewrite` | `lib/delivery-gate-facts.ps1` (name-status расширение `Get-DeliveryGateTouchedFiles` или параллельный хелпер, факт `tests_rewritten_with_code`, учёт в `Get-DeliveryGateAcceptanceFact`), `lib/delivery-mode.ps1` (если правило гейта читает новый факт) | Фикстурный диапазон: M code + M существующий test → факт true; M code + A новый test → false; only M tests → false; факт виден в evidence-строке гейта | parse + 3 git-фикстуры (можно во временном repo) | high (false positives могут блокировать легитимные рефакторинги тестов — смягчение: only-tests-диапазон не флагается, добавленные тесты не флагаются) | факт можно выключить, вернув константу false в одной функции, не трогая остальной гейт |

---

## (C) REAL-PATH ACCEPTANCE — прод-путь реален, артефакты реальны

### Как сейчас (evidence)

- Acceptance гоняет typecheck/lint/build (`lib/project-acceptance.ps1:1090-1101`), HTTP-статусы и `must_contain`-токены страниц (`:1114-1169`), smoke-скрипты (`:1178-1205`). Всё это проверяет «компилируется и отвечает», но не «по продовому пути»: stub-валидатор, отдающий 200 и нужный токен, проходит всё.
- Объявленный, но отсутствующий скрипт молча зелёный: `'missing script, skipped'` Ok=$true — `lib/project-acceptance.ps1:1093-1096` (и то же для smoke — `:1189-1192`). Удалил `smoke:e2e` из package.json — acceptance стал строже выглядеть и слабее проверять.
- Journey coverage удовлетворяется самим **наличием** скрипта или trace-полей в контракте (`Get-ProjectAcceptanceJourneyCoverageFact` — `lib/project-acceptance.ps1:982-998`), не их исполнением на реальном входе.
- Артефакты проверяются только с обратной стороны — что generated-артефакты НЕ закоммичены (`repo:generated-artifacts-not-tracked` — `lib/project-acceptance.ps1:1080-1086`). Порогов realness (размер/тип) нет нигде: slopvid-гейт «видео >100KB» жил только в тексте плана.
- QA-гейт проекта — только build (`Invoke-ProjectBuildGate` — `lib/qa-agent.ps1:109-160`).
- Боль: slopvid — в проде биндились stub-валидаторы, классы `Real*` не использовались вообще, медиа-выход никто не мерил.

### Дизайн

Контракт уже машиночитаемый и расширяемый (читатели терпимы к доп. полям — `Get-ProjectAcceptanceObjectValue`/`...ContractArray`). Добавляются три **опциональные** секции контракта + три детерминированных acceptance-шага (новая `Get-ProjectAcceptanceRealPathSteps` в `lib/project-acceptance.ps1`, вызов рядом с `:1077-1088`). Опциональность = legacy-проекты не краснеют; coordinator-промпт требует секции для новых контрактов.

1. **`real_path.production_entrypoints` + запрет stub-биндингов.** Контракт декларирует entrypoint-файлы (например `app/main.py`, `src/index.ts`) и опционально паттерны `forbidden_binding_symbols` (default: `^(Stub|Fake|Mock|InMemory|Dummy)[A-Z]` и symbol-suffix `(Stub|Fake|Mock)$`). Шаг `real-path:no-stub-bindings`: детерминированный скан import/require/from-строк транзитивного замыкания entrypoint'ов (по static import-графу, depth-limited; vendored/tests исключены) — найден import символа, матчащего паттерн, ⇒ FAIL с указанием файла/строки. Дополнительный шаг `real-path:real-symbols-reachable` (warning-уровень в v1): символы, матчащие `^Real[A-Z]`, объявленные в проекте, но не достижимые из entrypoint'ов, перечисляются в details — «Real* мертвы» становится видимым.
2. **Минимум один non-fixture вход end-to-end.** Контракт: `real_path.e2e = [{id, command, input, expect_artifact}]`, где `input` обязан лежать ВНЕ test/fixtures-директорий (детерминированная проверка пути) либо быть сгенерированным на лету командой. Шаг `real-path:e2e:<id>`: запускает `command` через существующий `Invoke-ProjectAcceptanceProcess` (`lib/project-acceptance.ps1:338-379`), затем проверяет существование `expect_artifact`. Если в контракте объявлены surfaces kind=cli/artifact (`lib/project-acceptance.ps1:916-923`), но секции `real_path.e2e` нет — шаг FAIL `real-path:e2e-declared-missing` (зеркало логики journey coverage, но с обязательным исполнением).
3. **Artifact realness thresholds.** Контракт/acceptance.json: `real_path.artifacts = [{path_glob, min_bytes, max_bytes?, kind}]`, где `kind ∈ media|archive|document|data` задаёт magic-bytes/extension-проверку (для media — заголовок MP4/PNG/..., не пустышка с нужным расширением). Шаг `real-path:artifact:<glob>`: после e2e-прогона артефакт существует, размер ≥ min_bytes, тип соответствует. slopvid «>100KB» переезжает из текста плана в машинный гейт.
4. **Закрыть green-by-omission.** Required script, объявленный в `.bridge/acceptance.json` (или в контракте `checks[].command`), но отсутствующий в `package.json`, ⇒ FAIL вместо `'missing script, skipped'` (правка `lib/project-acceptance.ps1:1093-1096` и `:1189-1192`). Скрипты, попавшие в список через auto-default из package.json (`:252-257`), пропускаются как раньше — ломаться должны только ЯВНО объявленные ожидания.

### Атомы

| # | slug | files (touch-set) | acceptance | checks | risk | rollback |
|---|------|-------------------|------------|--------|------|----------|
| C1 | `contract-real-path-schema-and-prompt` | `lib/backlog-autopilot.ps1` (промпт coordinator: требование секции real_path для новых контрактов), `lib/project-acceptance.ps1` (читатели секции `real_path`, без шагов) | Читатели возвращают пустые structures на legacy-контрактах; на фикстурном контракте с real_path — корректный разбор entrypoints/e2e/artifacts; промпт упоминает real_path | parse + юнит на reader с 2 фикстурными контрактами | low | чистое добавление; revert безвреден |
| C2 | `acceptance-stub-binding-step` | `lib/project-acceptance.ps1` (`Get-ProjectAcceptanceRealPathSteps`: no-stub-bindings + real-symbols-reachable) | Фикстурный проект: entrypoint импортирует `StubValidator` → FAIL с file:line; импортирует `RealValidator` → PASS; legacy-контракт без real_path → шаг не эмитится | parse + прогон на 2 фикстурных мини-проектах | normal (static import-скан может не покрыть DI-фреймворки — это заявленное ограничение v1, скан по import-строкам, не по runtime) | шаги в одной функции; отключение = не эмитить при отсутствии секции (уже так) |
| C3 | `acceptance-real-input-e2e-step` | `lib/project-acceptance.ps1` (e2e-исполнение через `Invoke-ProjectAcceptanceProcess`, anti-fixture проверка input-пути, `real-path:e2e-declared-missing`) | Фикстура с command, создающим артефакт → PASS; command падает или артефакта нет → FAIL; input внутри tests/fixtures → FAIL по anti-fixture правилу | parse + прогон на фикстуре | normal | один шаг-блок; timeout наследует существующий механизм процессов |
| C4 | `acceptance-artifact-realness-step` | `lib/project-acceptance.ps1` (`real-path:artifact:*`: size + magic-bytes) | Артефакт 50KB при min_bytes=100KB → FAIL; 150KB с валидным заголовком → PASS; файл с расширением .mp4 но без MP4-заголовка → FAIL | parse + прогон на фикстурных бинарях | low | изолированный шаг |
| C5 | `acceptance-fail-on-missing-declared-script` | `lib/project-acceptance.ps1` (`:1093-1096`, `:1189-1192` + признак «скрипт явный vs auto-default» в `Get-ProjectAcceptanceConfig`) | Явно объявленный в acceptance.json скрипт отсутствует в package.json → FAIL; auto-default отсутствует → skip как раньше | parse + прогон на 2 конфиг-фикстурах | normal (может покраснеть пара legacy-каналов — это желаемое: их acceptance.json врёт) | вернуть Ok=$true в двух местах |

---

## Порядок внедрения и зависимости

1. **Волна 1 (независимые, low-risk):** A1, B1, C1, C5.
2. **Волна 2:** A3, B2 (зависит от kind из A1), B3, C2, C3, C4.
3. **Волна 3 (меняют каденс/гейт, после обкатки волн 1-2):** A2 (integrator), B4 (diff-shape).

Все атомы детерминированные (file-scan/git-plumbing/прокладка промпта), без LLM-вызовов в гейтах; каждый ревёртится одним коммитом и не ломает legacy-каналы (opt-in через наличие секций контракта или мягкие default-пороги).

## Ключевые решения (для operator review)

- [[PROJECT_DECISION: consolidation встроен в существующий autopilot idle-hook как integrator-таск между волнами (читает combined diff, эмитит consolidation-атомы через тот же PROJECT_BACKLOG ingest) — не как новая подсистема]]
- [[PROJECT_DECISION: coherence (max-module-lines, duplicate-symbols) — детерминированные шаги project acceptance с порогами в .bridge/acceptance.json, default 700 строк / 2+ определений символа]]
- [[PROJECT_DECISION: .bridge/project-contract.json, .bridge/acceptance.json и plan-файлы становятся protected paths для implementation-атомов project-каналов — на двух рубежах: ingest-гейт (отказ атома) и delivery-gate forbidden_changes (rollback), по образцу Test-DeliveryGateForbiddenPath/Test-DeliveryCriticalBridgePath]]
- [[PROJECT_DECISION: изменение спеки легально только через planning-атом + повторный Set-ProjectPlanApproved (re-stamp plan_approved_signature); drift виден как FAIL-шаг acceptance plan-contract:signature-matches-approved, а не как тихая пауза autopilot]]
- [[PROJECT_DECISION: переписывание тестов ловится diff-shape фактом tests_rewritten_with_code (M/D существующих test-файлов в одном диапазоне с M source-файлов), а не keyword-матчингом; чисто добавленные тесты не флагаются]]
- [[PROJECT_DECISION: real-path acceptance = три опциональные секции контракта (production_entrypoints+forbidden_binding_symbols, e2e с non-fixture input, artifact realness thresholds с magic-bytes) + FAIL вместо skip для явно объявленных отсутствующих скриптов; legacy-проекты без секций не краснеют]]
