# Guard-Driven Parallel — PLAN (ревью Claude пройден, ожидает утверждения оператора)

Происхождение: DISCUSS (Claude инвентаризация + Codex риски) → decision `decisions/2026-06-03_201727_*.md` → архитектурный ревью (Claude). Исполняет МОСТ по атомам; критичные атомы под ревью+гейтом.

## Проблема
Мост не параллелит сам: решение отдано модели как опциональный `[[PARALLEL:N]]`, а модель не берёт опциональные возможности (доказано на `[[DECISION]]`). Детерминированного авто-параллелизатора для обычных задач нет (только backlog batch).

## Архитектура (консенсус)
**ParallelGuard** — deterministic validator/applicator ПОВЕРХ существующего `lib/parallel.ps1` (НЕ новый движок). Все источники параллели приводятся к одному DTO и проходят один guard.
- **v1** `parallel_groups: string[][]` (в DecisionContract) — только shadow-сигнал, для dispatch НЕДОСТАТОЧЕН.
- **v2** `ParallelProposal { id, files, task, complexity, acceptance?, source }` — для реального apply.
- **Источники** → единый DTO: explicit `[[PARALLEL]]`, backlog frontier, DecisionContract v2, future admission hook.
- **Pre-guard:** ≥2 групп; repo-relative files; нет exact/prefix overlap; нет absolute/traversal/glob/директорий; нет control-plane/shared-state; нет deps/barriers/verify/critic.
- **Post-write guard:** changed files каждого worktree ⊆ declared `files`; иначе поток QUARANTINE, не мержится. (Без этого безопасность = prompt воркера.)
- **Apply-success строгий:** `merged==total && failed==0 && quarantined==0 && conflicts==0`. Partial ≠ DONE.
- **Explicit `[[PARALLEL]]` тоже через guard** (закрыть unsafe bypass).
- **Shadow → evidence → guarded apply** (тот же каркас, что DecisionContract). Fallback на sequential всегда сохранён.

## Denylist (консервативный default, Codex)
`supervisor.ps1, watchdog.ps1, driver.ps1, driver/**, lib/circuit-breaker.ps1, lib/supervisor-restart-limit.ps1, lib/script-integrity.ps1, .git/**, control/**, channels/**/state.json, jobs/**, worktrees/**, memory/**, secrets.json`. Спорные (`config.json, lib/common.ps1, lib/channels.ps1`) — сначала shadow-deny.

## Что мост поймал глубже ориентира (сильные стороны)
- post-write quarantine (rogue worker), строгий success rule, prefix/traversal/glob overlap, explicit-через-guard, **channel concurrency ≠ subtask parallel** (multi-channel-parallel-drivers = `Start-Drv` vs `Start-ChannelDriver` metadata mismatch, отдельный stale issue), forced admission source (если optional снова не эмитится).

## Главы → атомы (порядок по зависимостям)
Каждый атом: 1 файл / ParseFile+BOM / targeted smoke / общий smoke.ps1 после driver/lib / acceptance.

1. **`lib/parallel-guard.ps1`** — pure validator/converter + denylist + path normalization. — *изолированный → мост сам*
2. **`tools/parallel_guard_smoke.ps1`** — fixture: safe/exact-overlap/prefix/control-plane/traversal/glob/dir/missing-task. — *изолированный*
3. **`config.json`** — `parallelGuard.mode="shadow"` default, поведение не меняется. — *изолированный*
4. **`driver/86-loop-completion.ps1`** — SHADOW hook: guard оценивает explicit/proposed groups, пишет `parallel-guard-shadow.jsonl` (would_dispatch/groups/reject/actual), dispatch НЕ меняет. — **гейт: ревью (completion path, хоть и shadow)**
5. **`tools/analyze-parallel-guard-shadow.ps1`** — отчёт: opportunities/reject reasons/actual. — *изолированный*
6. **`lib/decision-contract.ps1`** — v2 `parallel_proposals` (DTO), сохранить v1 `parallel_groups`. — *изолированный (shadow)*
7. **`lib/backlog.ps1`** — adapter frontier → `ParallelProposal[]`, dispatch не меняет. — *изолированный*
8. **`lib/parallel.ps1`** — post-write changed-files enforcement + stats merged/failed/quarantined/conflicts. — **гейт: ревью (трогает движок dispatch)**
9. **`driver/86-loop-completion.ps1`** — apply-mode за `parallelGuard.mode="apply"`: guard-approved → `Invoke-ParallelDispatch`; сомнение/ошибка = sequential fallback. — **гейт: ревью + live-verify; ВКЛЮЧАТЬ ТОЛЬКО после shadow-evidence (атомы 4-5) подтвердил корректность guard — как DecisionContract promote**
10. **registry/audit для `multi-channel-parallel-drivers`** — формализовать как stale metadata (Start-ChannelDriver vs Start-Drv), отдельно от subtask parallel. — *изолированный*

## Корректировки оператора-архитектора (Claude)
- **Атом 9 = жёсткий гейт shadow→apply:** не включать apply-mode, пока `analyze-parallel-guard-shadow` на реальном evidence не покажет, что guard валидирует корректно (нет ложных «безопасно»). Promote по данным, не по дате.
- **Критичные атомы (4 driver-hook, 8 движок, 9 apply)** — мой+Codex ревью перед merge. Изолированные (1,2,3,5,6,7,10) — мост сам через critic+verify.
- Страховка: watchdog rollback + git per-atom; control-plane в denylist.

## Acceptance плана
Мост САМ детерминированно параллелит независимую работу когда безопасно (model предлагает → guard валидирует pre+post → dispatch или sequential fallback); explicit и auto через один guard; control-plane/verify/critic никогда не параллелятся; apply включается только после shadow-evidence; текущее последовательное поведение — всегда доступный fallback.
