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
- [~] E. Gate Discipline — IN PROGRESS (2026-06-08): runner + hang-fix + governor re-sync; dogfooding
  A1–A8 → 6 реальных багов автономии моста; 5 ПОЧИНЕНЫ durable (collection .git-alt, gate-cascade
  admission ×2, dirty-guard, orphan-reaper ddd10b8); A1(регресс)+A8(enforcement) done автономно;
  по #3 frontier часть (б) serial-single-fallback ПОЧИНЕНА (2026-06-14), открыта только часть (а)
  узкий touch_set planner'а

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

### DOGFOODING-находки (2026-06-08): мост сам исполнял план A1–A8 → вскрыл 4 пробела автономии
Мост АВТОНОМНО прошёл Discuss-First (DISCUSS→план→атомы с canary), РЕАЛИЗОВАЛ A1 (реальная регрессия
`lane`, packer-тест зелёный) + A8 (control-plane enforcement, прошёл canary) = **3/8 done, включая 2
самых трудных**. Но застрял на 5 оставшихся — исполнение многоатомного плана вскрыло реальные баги:
1. **Collection .git-alt quarantine [ПОЧИНЕНО, commit 4fbac65]:** sandbox bridge-git оставляет
   `.git-alt.index` в ворктри воркера → `Collect-ParallelDispatchWorkerOutput` видел его в git status,
   считал «outside touch-set», пытался `git checkout` (untracked→fail) → кварантинил ХОРОШИЙ поток.
   Любой автономный workpack-ран так заклинивал. Фикс: `.gitignore .git-alt*` + skip git-plumbing в
   change-detection `parallel.ps1`. Verified: collect-guard 30/30. **Без этого фикса A1/A3/A8 не закрылись бы.**
2. **Orphan-reaper gap [ПОЧИНЕНО, ddd10b8]:** КОРЕНЬ (тот же класс, что E «built-but-not-wired») —
   `Invoke-BacklogStateReaper` (lib/backlog-state-reaper.ps1) был построен + юнит-протестирован, но
   НИКОГДА не загружался и не вызывался (встречался ТОЛЬКО в своём тесте). Поэтому running-атом с мёртвым
   воркером (A3 — 13ч) висел вечно, держа lease, что клогил очередь. Фикс: (а) `lib/backlog.ps1` грузит
   reaper в бандл; (б) `driver/10-maintenance.ps1` — `Start-BacklogReaperIfDue` (под локом, reap'ит
   running/working без live-PID/heartbeat/runtime → held, lease освобождается); (в)
   `driver/81-loop-idle-claim.ps1` вызывает его в idle-блоке. Reaper консервативен (сохраняет всё живое).
   Доказано LIVE: восстановил реальную сироту f531c6fb (running→held). test 11/11, smoke OK (226 ps1).
3. **Frontier overbroad-touch_set + нет serial-fallback [частично починено]:** planner объявил
   `workpack_touch_set`, включающий verify-зависимости (`tools/run-tests.ps1`) как «тронутые» → 5 атомов
   ложно пересеклись по run-tests.ps1 → frontier не смог собрать непересекающийся batch → wedge
   (`open-unpacked`, `lease-conflict`). Нужно: (а) planner объявляет УЗКИЙ touch_set = edit-таргет, не
   verify-deps; (б) frontier fallback на serial-single когда batch wedged [ПОЧИНЕНО, 2026-06-14
   serial-single-fallback: `lib/backlog-workpack.ps1:2327-2346` — когда за волну selected=0 и атомы
   заблокированы исключительно взаимным touch-overlap, frontier берёт первый заблокированный атом solo
   и гонит serial-путь (`$serialReason='serial-single-fallback'`)].
4. **Gate-cascade на control-plane-планах [ПОЧИНЕНО, bf6c39d + 419ead2]:** КОРЕНЬ — ДВЕ несогласованные
   control-plane детекции: claim-gate `Test-IdeaTouchesControlPlane` (широкая, блокирует A6
   `lib/verify-selftest.ps1`) vs autopilot `Test-ProjectAutopilotControlPlanePath` (узкая, не ловит →
   admission не ставит). Атом control-plane-blocked, но без admission → frontier wedge (protected-dominant,
   нет single-path). Фикс: autopilot авто-синтезирует canary-admission (с обязательными
   selftest/smoke/canary checks) для ЛЮБОГО атома, который claim-gate считает control-plane — admission
   согласован с гейтом, что реально блокирует; canary остаётся required. Доказано: A2/A6/A7
   control-plane-blocked → claimable=True.
5. **Dirty-guard: ротированные usage-логи [ПОЧИНЕНО]:** `usage.jsonl.1/.2` (ротация cost-логов) не покрыты
   `.gitignore` (только `usage.jsonl`) → грязнят дерево → dirty-guard откладывает ВСЮ очередь. Фикс:
   `usage.jsonl*` + untrack. Тот же класс, что `.git-alt`.

ВЫВОД: оператор чинил КОРНИ в мосте (6 реальных багов: collection, gate-cascade ×2, dirty-guard,
orphan-reaper + E-runner/hang/governor), а НЕ добивал хвост руками. После каждого фикса мост проходил
дальше — это доказывает, что чинились реальные wedge-причины, не симптомы. **Из 6 найденных багов 5
ПОЧИНЕНЫ durable** (collection 4fbac65, gate-cascade bf6c39d/419ead2, dirty-guard 12a86f4, orphan-reaper
ddd10b8); по **#3 frontier** часть (б) serial-fallback ПОЧИНЕНА (2026-06-14, serial-single-fallback в
`lib/backlog-workpack.ps1:2327-2346` — single когда parallel batch wedged по touch-overlap), остаётся
открытой только часть (а) узкий touch_set planner'а. Доказано: мост МОЖЕТ Discuss-First + canary +
реальный регресс-фикс (A1) + control-plane enforcement (A6/A8) автономно; харденинг сессии радикально
снизил wedge-причины многоатомной финализации (5 из 6 устранены).
