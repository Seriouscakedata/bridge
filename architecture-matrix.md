# Capability matrix моста — что реально работает

_Обновлено: 2026-05-26. Поддерживается Архитектором (`lib/architect.ps1`) +
ручная правка при необходимости. Сравнивается с `ARCHITECTURE_V2.md` (план)._

**Статусы:** ✅ работает · 🔄 в разработке · ⚠ частично · ❌ отсутствует · 🚫 отложено

## Ядро движка
| Capability | Status | Module | Notes |
|---|---|---|---|
| планировщик-кодер пайплайн | ✅ | driver.ps1 | Claude (Sonnet/Fable) ↔ Codex |
| модель-роутер по сложности | ✅ | lib/router.ps1 | Sonnet для триажа, Fable для архитектурного |
| usage tracking (расход) | ✅ | lib/usage.ps1, usage.jsonl | per-model, burn-rate UI |
| Codex `xhigh` reasoning | ✅ | driver.ps1 | `model_reasoning_effort="xhigh"` |
| Premium Claude ultrathink | ✅ | driver.ps1 | Fable/Opus/Mythos через 'ultrathink' + xhigh |

## Надёжность + откат
| Capability | Status | Module | Notes |
|---|---|---|---|
| supervisor (elevated host) | ✅ | supervisor.ps1 | держит server+driver живыми |
| watchdog с safety branch | ✅ | watchdog.ps1 | hardened 2026-05-25 |
| гибридный stable promotion | ✅ | watchdog.ps1 | 30мин здоровья + smoke |
| reset --hard rollback | ✅ | watchdog.ps1 | только на серьёзный сбой |
| BOM + parse-check инвариант | ✅ | smoke.ps1 | lint в smoke |
| zombie reaper (OOM) | ✅ | supervisor.ps1 | >8GB private = kill |
| 🩺 Doctor auto-repair | ✅ | lib/doctor.ps1 | MVP: 2 триггера (timeout-exhaust, rollback) |

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
| планировщик (план→Codex) | ✅ | driver.ps1 | STATUS: CONTINUE/DONE/RESEARCH/DISCUSS |
| Codex (кодер) | ✅ | driver.ps1 | через xhigh, RUNJOB, FILE, VERIFIED |
| независимый критик | ✅ | driver.ps1 | DeepSeek-Pro ревью diff |
| coder-bypass гейт | ✅ | driver.ps1 | file-edits только через Codex |
| discuss-mode | ✅ | driver.ps1 | DISCUSS-ONLY маркер при закрытии без кода |
| study-mode (с bug-markers) | ✅ | lib/study.ps1 | не триггерится на жалобы |
| план-доска (EPIC/TASK/STEP) | ✅ | lib/plan.ps1 | `/api/plan`, парсинг `[[PLAN]]` |
| параллельные воркеры (worktree) | ✅ | lib/parallel.ps1 | `[[PARALLEL]]` маркер |
| job manager (фоновые) | ✅ | lib/jobs.ps1 | `[[RUNJOB]]` маркер |

## Безопасность + проверки
| Capability | Status | Module | Notes |
|---|---|---|---|
| SAFETY-gate (`[[SAFETY:]]`) | ✅ | driver.ps1 | блокирует опасные действия Codex |
| verify-gate (`[[VERIFIED:]]`) | ✅ | driver.ps1 | требует реальный запуск перед DONE |
| API/UI verification rule | ✅ | driver.ps1 | реальный HTTP + ui_audit |
| ETS-JSON footgun lint | ✅ | smoke.ps1 | `-Depth>=12` и `raw\|ConvertTo-Json` |
| ui_audit структурный | ✅ | tools/ui_audit.ps1 | id выход/вход контейнера + screenshot |
| visit.ps1 (browse+screenshot) | ✅ | tools/visit.ps1 | desktop+mobile baseline + Gemini vision |
| ParseFile fast-fail | ✅ | smoke.ps1 / driver.ps1 | новый, 2026-05-26 (036279c) |

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
| **radar→action** (auto-idea) | ❌ | — | планируется в волне 3 |
| внешние системы compare | ❌ | — | планируется (`memory/external-systems.md`) |

## Мета-уровень (Архитектор — этот файл)
| Capability | Status | Module | Notes |
|---|---|---|---|
| capability matrix (этот файл) | 🔄 | architecture-matrix.md | волна 1 |
| failures.jsonl + meta-pattern | 🔄 | lib/metrics.ps1 | волна 1 |
| operator-interventions парсер | ❌ | lib/architect.ps1 | волна 2 |
| 🧭 Architect agent | ❌ | lib/architect.ps1 | волна 2 |
| external-systems list | ❌ | memory/external-systems.md | волна 2 |
| radar→action гейтом | ❌ | techradar.ps1 / lib/radar.ps1 | волна 3 |
| deep-think (premium Claude open) | ❌ | lib/architect.ps1 | волна 3 |

## Из ARCHITECTURE_V2.md ещё не реализовано
| Capability | Status | Notes |
|---|---|---|
| DAG-декомпозиция | ❌ | планировщик пишет `[[PLAN]]`, но без зависимостей-как-граф; шаги последовательные |
| песочница до промоута в main | ⚠ | worktrees есть, но не используются по умолчанию |
| красный-зелёный test-first | ❌ | нет автоматического тест-первого workflow |
