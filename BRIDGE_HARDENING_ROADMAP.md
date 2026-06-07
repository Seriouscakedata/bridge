# Bridge Hardening Roadmap (operator-approved 2026-06-06)

Цель: мост быстро доводит ЛЮБОЙ проект до честного проверенного результата — не разрастаясь
бесконечно, не путая scaffold с production, сам показывая где ограничен. Источник: анализ ведения
проекта literary-slop-video (потеря CHAPTER 8 + gate-каскад из 5 ложных блокеров + stub/false-green
drift). Codex дал 30-пунктовый roadmap; здесь консолидировано в 5 КОРНЕЙ (не плодить механизмы —
Foundation #2). Завести ПОСЛЕ literary CHAPTER 8. Метод: Discuss-First (мост анализирует свой код,
формирует durable MAP/PLAN, оператор ревьюит как архитектор-гейт, юзер утверждает главы, атомы
исполняются). Control-plane → tag operator + bridge_self_admission canary. НЕ массивные задачи
(commit_famine) — декомпозировать до атомов.

ОБЩИЙ ПРИНЦИП (важнее любого пункта): #27 из Codex — Prompt vs Deterministic Split. Всё критичное
(scope, budget, acceptance, artifact, provider, safety, план-полнота) ДЕТЕРМИНИСТИЧЕСКИ, не суждением
LLM. Сессия доказала: где LLM-суждение (next-chapter «достаточно ли») — там сбой (потеря главы 8);
где детерминистика (intake-gate) — надёжно.

РИСК-ФИЛЬТР для ВСЕХ пунктов: каждый новый gate/механизм ОБЯЗАН иметь (а) regression-тест «не
блокирует легитимную операторскую/проектную задачу», (б) семантическую проверку вместо regex по
тексту. Корень gate-каскада сессии — защиты добавлялись без этого. Различать «новый механизм» (риск)
vs «harden существующего» (безопасно, предпочтительно).

## Status tracker (детерминистический — не терять пункты как главу 8)

- [ ] A. Deterministic Plan/Scope/Release
- [ ] B. Honest Acceptance
- [ ] C. Capability/Provider Readiness
- [ ] D. Doctor/Watchdog/State-repair (harden существующего)
- [~] E. Gate Discipline — IN PROGRESS (2026-06-07): runner построен + фикс hang + 1/4 drift re-synced

## A. Deterministic Plan/Scope/Release (Codex #1,2,11,27)
КОРЕНЬ: потеря CHAPTER 8 — coordinator выбирал next-chapter суждением LLM, остановился после 6/10.
- Chapter/plan-completion tracker: парсить `## Chapter N` из PROJECT_PLAN.md, вести completed/pending
  по списку детерминистически; coordinator берёт строго следующую pending-главу.
- `current_release` boundary в contract: мост не делает «будущие полезные главы» пока текущий release
  не принят / scope не расширен оператором.
- Scope-gate: новая задача ссылается на approved requirement/surface/journey/acceptance из contract,
  иначе не в backlog.
- Acceptance проверяет «все главы PLAN closed», а не только «acceptance-сценарии зелёные».

## B. Honest Acceptance (Codex #3,4,6,28,29)
КОРЕНЬ: stub/false-green drift (production отдавал 1KB заглушки, выдавалось за done).
- Acceptance levels: SCAFFOLD_PASS / DRY_RUN_PASS / STUB_PASS / INTEGRATION_PASS / PRODUCTION_PASS / FAIL.
- Stub/dry-run detector: искать stub|mock|fake|dry_run|placeholder|TODO в production-path → max STUB_PASS.
- Artifact verifier: проверять САМ артефакт (mp4/pdf/site/report) — размер, формат, ffprobe, не нулевой.
- Final handoff contract: финальный ответ = что готово, уровень acceptance, что stub, где артефакт, что осталось.
- Quality rubric по типу проекта (результат соответствует ТЗ, не только «tests pass»).

## C. Capability/Provider Readiness (Codex #5,19)
КОРЕНЬ: provider не wired в production (real Gemini/Veo есть, но cli использовал stub).
- Capability contract на старте: какие API/ключи/модели/браузер/БД/ffmpeg/платёжки доступны; что мокается.
- Provider readiness gate: нужен real provider → проверить конфиги/env ДО реализации; нет → scaffold, не production.

## D. Doctor/Watchdog/State-repair (Codex #9,10,23,24) — HARDEN существующего
КОРЕНЬ: evidence-loop/lease-leak (атомы зависали running, мост разруливал, но требовал няньки).
- Working-without-agent watchdog: state=working без процесса/heartbeat → recovery, не висеть.
- Doctor triage matrix: различать process-dead / no-heartbeat / tests-failed / acceptance-failed /
  no-evidence / dependency-wait / external-blocker — для каждого своя retry policy.
- State-repair: авто-восстановление неконсистентного state (running но process dead; done но agent stuck).
- Retry limits по типу (timeout/no-progress/failed-tests/acceptance/doctor) → потом blocked/review, не вечный рестарт.

## E. Gate Discipline (Codex #30 + наблюдение сессии) — фикс gate-каскада
КОРЕНЬ: 5 ложных gate-блокеров от self-dev (governor shape, delivery-flow, claim-gate, coordinator-
prompt, gate-check) — матчили текст regex широко, добавлялись без regression.
- Каждый новый gate: обязательный regression-тест «не блокирует легитимную operator/project задачу».
- Gate матчит СЕМАНТИКУ (поля/флаги/structured), не regex по свободному тексту.
- Regression suite моста: на каждый найденный дефект — тест (scope-creep, stub-acceptance,
  dead-working-state, malformed-backlog, dependency-wait, false-gate-block).

### E — прогресс оператора (2026-06-07, hybrid «фундамент сам»)
СДЕЛАНО (committed):
- `tools/run-tests.ps1` — консолидированный gate-regression раннер (59 тестов, изолированный child-процесс
  на тест, per-test timeout, exit 1 при любом красном). Операционализирует «Regression suite моста»:
  даёт одну команду «все гейты зелёные?». Коммиты: 184f1d1 (salvage-смёл), ac5ea26, 6f452f6.
- Фикс реального hang: хелпер `Check` дампил упавший `$Actual` через `ConvertTo-Json -Compress -Depth 10`,
  что ВИСНЕТ (экспоненциально) в WinPS 5.1 на многострочных строках. Любой реальный провал = зависание
  всего suite на полный timeout вместо быстрого FAIL. Сошёлся к уже существующей конвенции репо
  (`test-action-held-gates.ps1`: string→как есть, объект→low-depth JSON, cap длины). Починены shadow +
  workpack-obligation (оба Depth-10).

НАЙДЕНО (корневая E-проблема — НЕ закрыта):
- **4 gate-теста дрейфанули рассинхрон с self-modified кодом моста** (suite поймал ровно тот класс
  отказа, ради которого E и существует): governor (strict-shape vs b4eec87 lenient — RE-SYNCED 6f452f6),
  packer (`lane` workpack-метадата теперь обязательна), failure-classifier (operator-pulse grouping),
  project-memory (`Resolve-MemoryContainedPath` сменил сигнатуру). Каждый требует stale-vs-regression
  триажа (НЕ массово ослаблять тесты — можно замаскировать реальный баг).
- **Suite НЕ ENFORCED:** `Invoke-VerifySelftestGate` не вшит в driver; coverage-сканер verify-selftest
  смотрит только `tools/diag/`, не 59 `tools/test-*.ps1`. Поэтому дрейф копился незаметно — мост менял
  код, тесты ржавели. КОРЕНЬ дрейфа = отсутствие enforcement (а не сами 4 теста).
- **Suite недетерминирован относительно дерева:** baseline был зелёным, потом красным БЕЗ смены кода —
  раннер гонит по живому рабочему дереву, которое мост мутирует + OneDrive-sync latency отдаёт устаревшие
  версии файлов. Раннер должен гонять по стабильному коммиту/копии, не по live-дереву.

ДАЛЕЕ (предложение): (1) дотриажить + re-sync packer/classifier/memory (фундамент, безопасно);
(2) КОРЕНЬ — вшить run-tests в self-mod verify-путь моста, чтобы дрейф ловился сразу (control-plane,
согласовать); (3) раннер по чистому checkout. Альтернатива по hybrid-плану: (2)+(3) отдать мосту через
Discuss-First после стабилизации.
