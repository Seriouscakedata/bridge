# Bridge Self-Model — FROZEN PLAN (одобрено оператором 2026-06-03)

Происхождение: DISCUSS (Claude↔Codex) → decision `decisions/2026-06-03_192003_*.md` → архитектурный ревью (Claude) → поправки оператора → ЗАМОРОЗКА. Исполняет МОСТ по атомам; оператор/Codex держат гейт на критичных атомах.

## Проблема
Мост помнит куски прошлого (память есть), но НЕ видит обязательную свежую **самомодель** в каждом рабочем ходе: «я устроен так, мои активные фичи такие, эти модули критичные, эти dormant, эти правила нельзя нарушать». Факт: `Build-Prompt`/`Format-Transcript` инжектят state/память/skills/recurrence/intent/план, но НЕ feature registry и НЕ архитектурное самоописание.

## Архитектура (4 части, derived artifact — НЕ память, НЕ ручной документ)
- **Generator** — read-only, собирает pack ИЗ РЕАЛЬНОСТИ (registry+state+docs+memory map+typed memory+state). Без записи в память, без LLM в prompt-path.
- **Refresh** — отдельная команда/хук, строит/обновляет cache. Fail-open: упал → старый pack + `stale=true`, turn не ломается.
- **Inject** — в `Build-Prompt` (driver/30), сразу после `$activeProjectBlock`. **Только читает cache.** Никакого scan registry/git/memory в prompt-path.
- **Drift Audit** — read-only: source hashes, owner_files, status counts, stale age, size cap. Drift НЕ чинит сам → создаёт finding/risk/task.

## Поправки оператора (обязательны)
1. **Адаптивный размер pack по контексту:**
   - main базовый (каждый turn): **1.5–2.5 KB**;
   - main расширенный: **3–4 KB**, только если задача про сам мост/архитектуру/memory/prompt/planner/guard/parallel/audit;
   - внешние проектные вкладки: **0.5–1 KB** (только bridge-infra safety, чтобы не съедать контекст проекта).
2. **Cache в runtime, не в канале:** `Get-RuntimeRoot()` → `.bridge-runtime/self-model/main.{pack.json,prompt.txt}`. Generated marker + gitignore. Это derived artifact, не знание для ручной поддержки.

## Ограничения («нельзя»)
- не «ещё один документ руками»; не грузить весь registry/PROJECT_MAP в prompt; не заменять guard/safety моделью; не ломать memory recall; не делать prompt-path mutating/slow.

## Always в prompt (компактно)
Архитектура (5–7 строк), critical modules, top active features, dormant/broken risks, safety-инварианты, memory model, planner/coder/critic/parallel/autopilot/DecisionContract status, known current risks, test smoke pointers.
**По релевантности (НЕ в self-model):** полный PROJECT_MAP, весь registry, docs excerpts, git log, decisions, полный test inventory, code recall — остаются в Project Context Pack / memory recall.

## Главы → атомы (порядок учитывает зависимости)
Каждый атом: 1 основной файл / 1 проверяемое изменение / ParseFile+smoke+test перед коммитом / acceptance.

- **Гл.1 — Generator** `lib/self-model.ps1` (read-only). v1 МИНИМУМ источников (registry+state+safety+arch), остальные источники — отдельными атомами потом. Test `tools/self_model_smoke.ps1`: output в рамках размера, required sections, NO full registry dump, читает но НЕ пишет память. — *изолированный → мост сам (critic+verify)*
- **Гл.2 — Refresh** `tools/refresh-self-model.ps1`: строит cache в `.bridge-runtime/self-model/main.*` с source hashes, атомарно, fail-open. Test: 2 запуска подряд = no-op (stable); изменение fixture-источника меняет hash. *(первый cache рождается ЗДЕСЬ, не отдельным атомом)* — *изолированный → мост сам*
- **Гл.3 — Inject** `driver/30-prompt-agent-state.ps1`: читать cache после `$activeProjectBlock`, выбрать tier (base/extended/external) по каналу+релевантности. **КРИТИЧНЫЙ.** Test: prompt smoke для normal И fast-lane, self-model присутствует, memory recall сохранён, «inject reads cache only» (no generation). — **гейт: я+Codex ревью + тесты normal/fast-lane + live-verify**
- **Гл.4 — Drift Audit** `tools/self-model-drift.ps1` (read-only). Test: fixture с missing owner_file → drift finding; mutating `Update-FeatureActivations` НЕ вызывается. — *изолированный → мост сам*
- **Гл.5 — Post-task Hook** `driver/86-loop-completion.ps1`: вызвать refresh после task/commit/audit, fail-open. **Полу-критичный** (completion path). Test: mocked refresh failure НЕ ломает completion. — **гейт: ревью**
- **Гл.6 — Docs+Acceptance** `PROJECT_MAP.md`/`BRIDGE_STATUS.md`: SelfModel = derived artifact, source-of-truth = registry/docs/memory/code. Acceptance: оператор видит source mapping, нет ручного self-model-документа. — *изолированный → мост сам*

## Разграничение исполнения/ревью
- **Критичные (Гл.3 Inject, Гл.5 Hook)** — трогают prompt-path/completion. Мост кодит → я+Codex ревью + тесты + live-verify перед merge. Короткий поводок.
- **Изолированные (Гл.1,2,4,6)** — read-only/отдельные файлы/tools. Мост гонит сам через planner→coder→critic→verify.
- **Страховка везде:** watchdog auto-rollback + git per-atom; атом сам проходит ParseFile+smoke+tests.

## Acceptance плана в целом
Мост в каждом main-turn видит компактную актуальную самомодель; pack генерируется из реальности и сам обновляется; drift ловится; prompt-path не замедлен и не мутирует; memory recall цел; guard/safety не тронут; никакого ручного self-model-документа.
