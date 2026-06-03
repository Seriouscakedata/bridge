# WORK COORDINATION — кто над чем работает

> **Зачем.** Над мостом работают ДВА агента: **Claude** (оператор/архитектор) и **Codex**
> (отдельная сессия). Чтобы не переделывать работу друг друга и не ловить конфликты в общих
> файлах — каждый объявляет здесь активный claim ПЕРЕД работой и снимает его ПОСЛЕ.
> Проверяй этот файл перед тем как трогать `supervisor.ps1`, `watchdog.ps1`, `driver.ps1`,
> Task Scheduler, `.git`-конфигурацию.

_Протокол: claim = строка в таблице со статусом `IN PROGRESS`. Закончил → `DONE` + дата. Не трогай чужие `IN PROGRESS`-файлы._

---

## Активные claim'ы

| Агент | Задача | Файлы (НЕ трогать чужому) | Статус | Обновлено |
|---|---|---|---|---|
| **Claude** | Инфра-надёжность ЗАКРЫТА: **(1) `.git` вынесен с OneDrive** → `.bridge-runtime\bridge-git` (gitlink) — устраняет корень всех 3 аварий (зануление ref + git-lock-hang). bundle-бэкап в runtime. **(2)** `ensure-bridge.ps1` лечит мёртвый/**зависший** supervisor+watchdog + занулённый ref (детект по smoke-mtime). **(3)** supervisor сам регистрирует Task `ClaudeCodexBridge-Ensure` (admin не нужен). Коммиты `68aaacc`,`f08e978`,`edd02f2`. Прямые читатели `.git` (ensure-bridge, server) резолвят gitlink. | `ensure-bridge.ps1`, `install-ensure-bridge.ps1`, `supervisor.ps1`, `server.ps1`, `.git` (gitlink) | **DONE** | 2026-06-03 13:32 |
| **Codex** | Рефакторинг/модуляризация `driver.ps1`: startup и runtime loop вынесены в фазовые `driver/*.ps1` scriptblock-модули; entrypoint около 150 строк | `driver.ps1`, `driver/*.ps1`, `DEVELOPER_GUIDE.md` | **DONE** | 2026-06-03 15:22 |
| **Claude** | **Slimming моста** (`SLIMMING_PLAN.md`, rank 1→7): удаление «лесов» — LLM-микро-оракулы, сборка промптов, marker-постпроцессинг, routing/decomposition-эвристики, объединение планировщиков; затем `Platform.*` отвязка от Windows. Атомарно (parse+smoke каждый шаг). НЕ трогаю safety-гейты + verify. **Codex: не трогай** перечисленные файлы пока claim активен. | `lib/scholar.ps1`,`lib/architect.ps1`,`lib/postmortem.ps1`,`lib/auditor.ps1`,`lib/memory.ps1`,`lib/intent.ps1`,`lib/backlog.ps1`,`lib/parallel.ps1`,`driver/30-*`,`driver/81-*`,`driver/84-*` | **IN PROGRESS** | 2026-06-03 15:30 |

## Что это значит на практике

- **Claude НЕ трогает `driver.ps1`** пока у Codex активен claim на рефакторинг — чтобы не конфликтовать.
- **Codex НЕ трогает** `supervisor.ps1` / `watchdog.ps1` / `install-*.ps1` / Task / `.git`-конфиг пока у Claude `IN PROGRESS` по инфра-надёжности.
- Общие файлы (`lib/backlog.ps1`, `lib/common.ps1`, `config.json`) — предупреждай в этой таблице перед крупной правкой.
- Закончил claim → переведи в `DONE` и освободи файлы.

## История

- 2026-06-03 12:30 — Claude взял инфра-надёжность (см. выше). Причина: двойной каскад OneDrive→`.git` занулён + supervisor/watchdog умерли без авто-рестарта.
