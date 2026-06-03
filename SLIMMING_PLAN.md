# BRIDGE SLIMMING PLAN — платформа vs леса

> Источник: аудит 2026-06-03 (8 агентов, ~190 функций размечено). Цель: тонкая, переносимая,
> надёжная ПЛАТФОРМА + доверить модели task-логику. Ожидаемое сокращение ~45-55% (80k → 35-42k строк).
> Выполняем ПО ОЧЕРЕДИ rank 1→7 (от простого/дешёвого к сложному/стратегическому), АТОМАРНО:
> каждый атом = мигрировать правило в промпт (если нужно) → удалить → ParseFile OK → smoke OK → commit.

## Незыблемые правила марафона (риски аудита)
1. **НЕ трогать deterministic safety-гейты** (блок необратимых операций, RUNJOB-vetting, risk-tiers, quality-bypass scan) — единственная граница на самомодифицирующейся системе. KEEP.
2. **НЕ ослаблять verify** (real build/typecheck/smoke + HTTP acceptance) — это verify-hole fix оператора. KEEP.
3. **Мигрировать выстраданные правила в системный промпт ПЕРЕД удалением prose** (BOM, "restart.flag только если .ps1 изменён", dispatch-once ERR-006, HEAD-advance verification). Иначе регресс багфиксов.
4. **Атомарно**, не big-bang. Parse+smoke зелёные на каждом шаге. Resilience-триаду (supervisor/watchdog/circuit-breaker) трогать только verbatim-за-интерфейс, без смены поведения.
5. **Оставить operator overrides** ([[DEEP-THINK]]/[[FAST]]) и strength-floor для слабых API-воркеров (DeepSeek/Gemini) — model-variance страховка.

## KEEP (несущая платформа, ~15-20k, НЕ трогать кроме portability)
resilience-триада · crash-safe персистентность · кросс-сессионная память (embeddings+код-индекс) · мульти-агент dispatch (worktree/merge) · safety-гейты · real build/smoke verify · cadence-планировщик · sandbox/секреты · replay/telemetry.

## REVISED APPROACH (Claude+Codex consensus 2026-06-03) — НЕ «резать код», а Model-proposes / Guard-validates

«GIVE TO MODEL = удалить» — ОШИБОЧНАЯ рамка. Правильно: **модель ПРЕДЛАГАЕТ (строгий JSON) → детерминированный мост ПРОВЕРЯЕТ и ПРИМЕНЯЕТ.**
- **Никогда не отдаём модели:** safety, verify/build/smoke, git/merge, rollback, лимиты, необратимые операции, state/locks, approval/risk-границы. Это детерминированные validators (KEEP+усилить).
- **Два слоя:** Model Decision Layer (JSON-решение) → Deterministic Guard Layer (валидация+применение). JSON модели НЕ разрешает сам себя.
- **Shadow-first:** новое решение пишется в лог/память, старый путь решает как раньше; сравниваем совпадения/ошибки на реальных прогонах; промоутим из shadow только после подтверждения.
- **Старые эвристики НЕ удалять** — fallback на 1-2 версии, режем после сравнений.
- **`confidence` + `needs_operator`** в JSON = решение пункта №2 (ко-пилот/uncertainty): модель помечает неуверенность → мост зовёт оператора.

### DecisionContract (минимальная схема): `intent, risk, files, dependencies, parallel_groups, acceptance, needs_operator, confidence, rationale_short`

### Пересмотренный порядок (Codex):
1. **Atom 1: DecisionContract shadow** — схема + validator + shadow-логгер + интеграция в точках intent/routing/workpack (логировать, НЕ менять поведение) + тесты (parse, self-test, validator).
2. Перевести intent/routing/complexity/workpack-proposal на модельный JSON (всё ещё shadow).
3. Deterministic validators отдельным слоем (path-in-repo, no-safety-change-without-operator, git clean/dirty, risk-tier, file-overlap, parallel-limit, acceptance).
4. Старые эвристики → fallback.
5. Удалить fallback после реальных сравнений (тесты + прогоны подтвердили).
- НЕ трогать verify/safety/rollback/locks/state на этом этапе. Platform/Linux (rank 5-6) — позже.

## Очередь исполнения (исходная, переосмыслена выше)

### Rank 1 — удалить LLM-микро-оракулы (high impact, medium effort) ⏳
Модель делает это в одном проходе. Удалить обёртки, перенести в end-of-task structured block + persistence-tool.
- [ ] `lib/scholar.ps1` — research-агенты (изолирован, IfDue) — **первый атом (самый безопасный)**
- [ ] `lib/architect.ps1` — Invoke-ArchitectCritique + Start-DeepThinkDialog (lib + driver/81)
- [ ] `lib/postmortem.ps1` — Invoke-Repair / LegacyPostMortem
- [ ] `lib/auditor.ps1` — Invoke-AuditorLLM классификатор (оставить SNAPSHOT-сбор + дешёвые триггеры commit_famine/restart-loop)
- [ ] `lib/memory.ps1` — Get-MemoryDistilled/Add-SkillMemory/Add-StudyLessons (оставить storage/retrieval embeddings — это KEEP)

### Rank 2 — свернуть сборку промптов + marker-постпроцессинг
- [ ] Перенести инвариантные rule-блоки (driver/30 Build-Prompt prose) в системный промпт.
- [ ] storage-маркеры ([[REMEMBER]]/[[SAVE]]/[[PROJECT_*]]/[[IDEA]]) → прямые Tool Foundry вызовы; удалить regex-парсер (driver/84).
- [ ] ОСТАВИТЬ control-маркеры (restart.flag, [[PARALLEL:N]], STATUS:DONE/CONTINUE-CHUNK).

### Rank 3 — заменить routing/decomposition эвристики выводом модели
- [ ] Удалить Get-PlannerModel keyword-таблицы, Get-TaskComplexityHeuristic, Get-StreamDomain, complexity-floor.
- [ ] Удалить Get-BacklogInferredFiles/conflict-grouping → модель возвращает {effort, files, parallel_groups} → в KEEP dispatch.
- [ ] ОСТАВИТЬ risk-tier (safety) + idea dedup/outcome-learning (анти-churn).
- [ ] `lib/intent.ps1` целиком (модель сама понимает режим) → удалить + mode в промпт; оставить overrides.

### Rank 4 — объединить ~7 'Start-XIfDue' в один cadence-runner (low effort)
- [ ] architect/audit/librarian/reflect/canary/techradar/scholar → один generic scheduler (config: window/floor/delta). Оставить гейты, удалить дубль timing/marker кода.

### Rank 5 — Platform.* интерфейсы (high effort, стратегия; код verbatim за интерфейс)
- [ ] Platform.Process (spawn/kill-tree/list/owner/alive) — Windows-бэкенд = текущий WMI/JobObject/taskkill.
- [ ] Platform.Scheduler (Task Scheduler → интерфейс), Platform.HttpServer, Platform.Vcs.
- [ ] Config-резолвер путей (BRIDGE_ROOT/RUNTIME/PORT/GIT_BIN/NODE_BIN…) — убрать хардкод C:\…, MSIX/WinGet.

### Rank 6 — Linux/pwsh7 backend + Docker target (gated on rank 5)
- [ ] POSIX-бэкенд (process groups, systemd/cron, обычный .git, без BOM). Контейнер в CI.

### Rank 7 — обрезать orchestration-бухгалтерию (extended-thinking обесценил)
- [ ] adaptive-probe-timeout эвристика, mid-turn checkpoint/snapshot, chunk/noop счётчики.
- [ ] ОСТАВИТЬ один git-diff stagnation backstop + HEAD-advance verification + turn-boundary state.

## Прогресс
- 2026-06-03: план зафиксирован после аудита. Старт rank 1.
- 2026-06-03: `lib/scholar.ps1` удалён (rank 1, первый атом, -448 LOC; architect.ps1 orphan-блок убран).
- 2026-06-03: **разворот после коррекции Codex** — не «GIVE TO MODEL = удалить», а «Модель ПРЕДЛАГАЕТ → детерминированный Guard ПРОВЕРЯЕТ и ПРИМЕНЯЕТ». Условия Codex: shadow-first; маленькая схема; валидаторы отдельно; НЕ удалять старые эвристики до evidence; НЕ трогать verify/safety; ревью после каждого атома. Перед удалением rank 3 (intent/routing) идём через shadow-слой DecisionContract.

### DecisionContract shadow-слой (подготовка к rank 3) — атомы
- **Atom 1** `d819ad4` ✅ **принят Codex** — `lib/decision-contract.ps1` (схема 9 полей + строгий валидатор + shadow-логгер + Read/Remove helpers); capture в driver/84 (модель предлагает → лог vs legacy); hint в driver/30; `[[DECISION]]` вырезается из видимого ответа. Тесты 18/18.
- **Atom 2** `fbf7c4e` (на ревью) — observability логгера: убран hardcoded OneDrive-фоллбэк; `Write-DecisionShadowSignal` → `.bridge-runtime/decision-shadow-errors.jsonl` для root-unavailable|channel-missing|write-failed; пустой `catch{}` заменён сигналом. Тесты 21/21.
- **Atom 3** `5bdaa63` → фикс `dc084d3` (на ревью) — `tools/analyze-decision-shadow.ps1`, READ-ONLY: records (НЕ rate — знаменатель planner-turns тут не трекается), valid%, intent-agreement, топ-расхождения, топ-ошибки валидатора, logger-failures. Фикс по ревью Codex: legacy = task_intent сериализован в JSON-строку → `Get-LegacyMode` достаёт `primary_mode`/`mode`/`intent`; **словари разные** (model `code|plan|audit|fix|...` vs legacy `normal|discuss|study|fast|chat`) → `ConvertTo-CanonMode` сводит оба к канону (`normal`+`code/plan/audit/fix`→`work`), иначе code-vs-normal был бы ложным mismatch. Тест на live-формате 7/7.

**КРИТИЧНО для Atom 4 (vocab gap):** model-intent-словарь ≠ legacy-mode-словарь. Любой advisory-слой ОБЯЗАН маппить их (как `ConvertTo-CanonMode`), иначе «согласие/расхождение» бессмысленно. legacy `primary_mode` НЕ различает code/plan/audit/fix — только `normal`. Это сужает что shadow может доказать про эти под-режимы.

**Факт получен (live-проба, не гадание):** опциональный `[[DECISION]]` hint модели ИГНОРЯТ даже когда он доставлен. Доказано чистым planner discuss-turn'ом в main (hint в промпте через ветку L393, обе модели ответили, 0 маркеров, shadow пуст). Плюс находки: (1) fast-lane codex ветка `Build-Prompt` (L37-51) hint НЕ несёт — ок, fast-lane пропускает planner; (2) shadow концептуально нужен на planner-уровне, а не на reply исполнителя. Вывод → НЕ усиливать hint (вариант A) и НЕ плодить вызовы (C), а **ветка B**.

### Atom 4 = Intent Decision Shadow (вариант B, ТЗ Codex) — capture в точке решения, БЕЗ новых LLM-вызовов, БЕЗ усиления hint
- **4a** `499e777` (на ревью) — `lib/decision-contract.ps1`: `ConvertTo-IntentCanon` (общий канон, единый источник) + `Write-IntentShadow` (запись `stage='intent-claim'`: model intent vs effective + guard_overrides + canon + agreement; без full-contract валидации). Тесты 28/28.
- **4b** `5259b5c` (на ревью) — `driver/81-loop-idle-claim.ps1`: после precedence-closure собирает model proposal (`Test-TaskIntent`) vs `effective_mode`/`effective_reason` (зеркало L162-170) + `guard_overrides` → `Write-IntentShadow`. Pure shadow, try/catch — не ломает claim. SelfTest OK.
- **4c** `a85a7d1` (на ревью) — analyzer: ветка `stage='intent-claim'` отдельно от planner-turn (Codex п.4); метрики agreement/override/reasons/divergences; канон консолидирован на lib. Тесты 20/20 (Codex п.5: normal→work, code/work, discuss, low-conf fallback, unsafe-fastlane blocked, marker override).
- **ОГРАНИЧЕНИЕ (Codex):** покрывает только intent/mode, НЕ полный files/deps/parallel_groups/acceptance. Это «Intent Decision Shadow», НЕ «полный DecisionContract advisory».
- **LIVE-VERIFY ПРОЙДЕН** (2026-06-03, после restart): первый боевой claim записал intent-claim за ~3с — model=fast/0.95/trivial, effective=fast (llm-intent-fast), canon fast==fast → agreement=TRUE, model_consulted=true, low_complexity fired, logger_failures=0. Цепочка `Test-TaskIntent → precedence → Write-IntentShadow → analyzer` работает end-to-end в проде, поведение не изменено.
- **Дальше:** evidence копится естественно при работе моста. Promote (доверить модели intent) / удаление legacy intent-эвристик (rank 3) — ТОЛЬКО после накопления статистики (сейчас 1 запись). Неблокирующий хвост Codex: разделить `guard_overrides.marker_normal` на `normal_marker`/`normal_text_override`, если понадобится точная аналитика по маркерам.
