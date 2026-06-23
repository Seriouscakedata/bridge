# Capability matrix моста — что реально работает

_Обновлено: 2026-06-23. Ручной reference-файл. Архитектор (`lib/architect.ps1`)
больше НЕ читает/правит его — он генерирует живую матрицу на лету из
`features/registry.json` (`Get-CapabilityMatrixLive`); этот файл — для оператора.
Сравнивается с `ARCHITECTURE_V2.md` (план)._

**Статусы:** ✅ работает · 🔄 в разработке · ⚠ частично · ❌ отсутствует · 🚫 отложено

## Ядро движка
| Capability | Status | Module | Notes |
|---|---|---|---|
| планировщик-кодер пайплайн | ✅ | driver/00-task-session.ps1 | Claude (Sonnet/Opus 4.8) ↔ Codex |
| модель-роутер по сложности | ✅ | lib/router.ps1 | Sonnet для триажа, Opus 4.8 для архитектурного (`Get-PlannerModel` в driver/00-task-session.ps1; router добавляет эскалацию) |
| usage tracking (расход) | ✅ | lib/usage.ps1, usage.jsonl | per-model, burn-rate UI |
| Codex `xhigh` reasoning | ✅ | driver/40-agent-invoke.ps1 | `model_reasoning_effort="xhigh"` |
| Premium Claude ultrathink | ✅ | driver/00-task-session.ps1 | Opus 4.8 (deepModel=claude-opus-4-8; маркеры [[FABLE]]/[[OPUS]]/[[DEEP-THINK]] резолвятся в opus-4-8, claude-fable-5 мёртв/404) через 'ultrathink' + xhigh |

## Надёжность + откат
| Capability | Status | Module | Notes |
|---|---|---|---|
| supervisor (elevated host) | ✅ | supervisor.ps1 | держит server+driver живыми |
| watchdog с safety branch | ✅ | watchdog.ps1 | hardened 2026-05-25 |
| гибридный stable promotion | ✅ | watchdog.ps1 | 30мин здоровья + smoke |
| reset --hard rollback | ✅ | watchdog.ps1 | только на серьёзный сбой |
| BOM + parse-check инвариант | ✅ | smoke.ps1 | lint в smoke |
| zombie reaper (OOM) | ✅ | supervisor.ps1 | >8GB private = kill |
| 🩺 Doctor auto-repair | ✅ | lib/doctor.ps1 | триггеры: planner-timeout, watchdog-rollback, commit_famine (+ held-resolve, restart-loop guard); держит задачу, чинит, резюмирует |

## Самообучение
| Capability | Status | Module | Notes |
|---|---|---|---|
| вектор-память (Gemini embed) | ✅ | lib/memory.ps1 | 60+ записей, recall работает |
| код-память (semantic) | ✅ | lib/codemem.ps1 | /api/code, recall top-1 |
| librarian (карта памяти) | ✅ | librarian.ps1 | hybrid: 6ч + delta-trigger ≥5 новых |
| reflect (предлагает идеи) | ✅ | reflect.ps1 | DeepSeek, leaf-уровень |
| post-mortem (lesson+idea) | ✅ | lib/metrics.ps1 | DeepSeek на timeout/safety/rollback |
| experiment-loop (вердикт) | ✅ | lib/metrics.ps1 | Write-Hypothesis + 24ч сравнение |
| usage.jsonl + burn-rate | ✅ | lib/usage.ps1 | расход прозрачен |

## Агенты / оркестрация
| Capability | Status | Module | Notes |
|---|---|---|---|
| планировщик (план→Codex) | ✅ | driver/*.ps1 (40-agent-invoke) | STATUS: CONTINUE/DONE/RESEARCH/DISCUSS |
| Codex (кодер) | ✅ | driver/40-agent-invoke.ps1 | через xhigh, RUNJOB, FILE, VERIFIED |
| независимый критик | ✅ | driver/40-agent-invoke.ps1 | DeepSeek-Pro ревью diff |
| coder-bypass гейт | ✅ | driver/*.ps1 (83/86/87) | file-edits только через Codex |
| discuss-mode | ✅ | driver/40-agent-invoke.ps1 | DISCUSS-ONLY маркер при закрытии без кода; для Deep/High-Stakes вытеснен task_mode='synthesis' |
| Decision Synthesis | ✅ | lib/decision-synthesis.ps1 + lib/decision-depth.ps1 | task_mode='synthesis' (synthesisMode.enabled): no-LLM depth-роутер (Simple/Standard/Deep/High-Stakes) → stateless pipeline (3 слепых proposal → ConflictMatrix → CrossReview → Judge → MicroDebate → FinalV2+RedTeam → Decision Record под channels/<slug>/decisions/<id>/); High-Stakes + high-sev red-team → needs_operator (без auto-implement) |
| computer_action mode (лапа) | ✅ | driver/81-loop-idle-claim.ps1 | локальный mouse/window fast-lane без planner/coder/critic; intent-роутер distinguishes от обычных задач |
| study-mode (с bug-markers) | ✅ | lib/study.ps1 | не триггерится на жалобы |
| план-доска (EPIC/TASK/STEP) | ✅ | lib/plan.ps1 | `/api/plan`, парсинг `[[PLAN]]` |
| параллельные воркеры (worktree) | ✅ | lib/parallel.ps1 | `[[PARALLEL]]` маркер |
| job manager (фоновые) | ✅ | lib/jobs.ps1 | `[[RUNJOB]]` маркер |

## Безопасность + проверки
| Capability | Status | Module | Notes |
|---|---|---|---|
| SAFETY-gate (`[[SAFETY:]]`) | ✅ | driver/83-loop-agent-turn.ps1 | блокирует опасные действия Codex |
| verify-gate (`[[VERIFIED:]]`) | ✅ | driver/86-loop-completion-checks.ps1 | требует реальный запуск перед DONE |
| API/UI verification rule | ✅ | driver/86-loop-completion-checks.ps1 | реальный HTTP + ui_audit |
| ETS-JSON footgun lint | ✅ | smoke.ps1 | `-Depth>=12` и `raw\|ConvertTo-Json` |
| ui_audit структурный | ✅ | tools/ui_audit.ps1 | id выход/вход контейнера + screenshot |
| visit.ps1 (browse+screenshot) | ✅ | tools/visit.ps1 | desktop+mobile baseline + Gemini vision |
| ParseFile fast-fail | ✅ | smoke.ps1 / driver/40-agent-invoke.ps1 | парс-чек перед DONE |

## UI (веб)
| Capability | Status | Module | Notes |
|---|---|---|---|
| chat-UI с историей | ✅ | web/index.html | основной интерфейс |
| /memory (вкладки) | ✅ | web/memory.html | Записи/Карта/Бэклог/Радар/Настройки |
| план-доска панель | ✅ | web/index.html | `planToggle`, основной ряд |
| мобильный layout | ⚠ | web/index.html | drag-handle вместо свайпа (50ca472) |
| push-уведомления (Telegram) | ⚠ | server.ps1 / settings | реализовано, но без активного теста на устройстве |

## Радар (внешнее обучение)
| Capability | Status | Module | Notes |
|---|---|---|---|
| Habr RSS digest (passive) | ✅ | techradar.ps1, lib/radar.ps1 | релевант-гейт `value≥3`, weekly |
| ручной триггер /api/radar/run | ✅ | server.ps1 | работает |
| **radar→action** (auto-idea) | ✅ | lib/radar.ps1, techradar.ps1 | value≥4 + не-дубль → Add-Idea (radar-derived), cap 5 pending |
| внешние системы compare | ⚠ | external-systems.md | файл существует, потребляется Архитектором как контекст |

## Мета-уровень (Архитектор — этот файл)
| Capability | Status | Module | Notes |
|---|---|---|---|
| capability matrix (live) | ✅ | lib/architect.ps1 (Get-CapabilityMatrixLive) | генерится из features/registry.json на каждом ходу; этот .md — ручной reference |
| failures.jsonl + meta-pattern | ✅ | lib/metrics.ps1 | memory/failures.jsonl, источник meta-pattern для Архитектора |
| operator-interventions парсер | ✅ | lib/architect.ps1 (Get-OperatorInterventions) | сканирует user-сообщения по маркерам коррекции/жалоб |
| 🧭 Architect agent | ✅ | lib/architect.ps1 | structural-агент: 1-3 идеи в беклог, НЕ авто-исполняет; gate 24ч / ≥10 закрытых задач |
| external-systems list | ✅ | external-systems.md | потребляется Get-ArchitectContext |
| deep-think (premium Claude open) | ✅ | lib/architect.ps1 | ежедневный [[DEEP-THINK]] ~01:00, режим 'deep-think', respects WIP cap |

## Из ARCHITECTURE_V2.md ещё не реализовано
| Capability | Status | Notes |
|---|---|---|
| DAG-декомпозиция | ⚠ | `[[PLAN]]` без явного графа, НО workpack-packer (lib/backlog-workpack.ps1) выводит depends_on эвристикой → dependency-wait + последовательные волны для зависимых цепочек |
| песочница до промоута в main | ⚠ | worktrees есть, но не используются по умолчанию |
| красный-зелёный test-first | ❌ | нет автоматического тест-первого workflow |
