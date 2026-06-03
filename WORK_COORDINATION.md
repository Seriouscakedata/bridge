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
| **Claude** | Инфра-надёжность: внешний якорь `ensure-bridge.ps1` (git-ref-heal + supervisor/watchdog self-heal) + `install-ensure-bridge.ps1` (Task каждые 5 мин). **СДЕЛАНО+коммит `9bfabc8`**, git-heal проверен (backup SHA пишется, здоровый ref не тронут). ⏳ Ждёт: оператор запускает `install-ensure-bridge.ps1` как **admin** (Register-ScheduledTask требует elevation). Фаза 2 (опц.): `.alive`-heartbeat в supervisor/watchdog для проверки без CommandLine. | `ensure-bridge.ps1`, `install-ensure-bridge.ps1`, Task `ClaudeCodexBridge-Ensure` | **DONE (ждёт admin-регистрации)** | 2026-06-03 12:40 |
| **Codex** | Рефакторинг/модуляризация `driver.ps1` (6235 строк → тонкий оркестратор + `lib/*.ps1`) | `driver.ps1`, новые `lib/*.ps1` модули | (Codex проставит) | — |

## Что это значит на практике

- **Claude НЕ трогает `driver.ps1`** пока у Codex активен claim на рефакторинг — чтобы не конфликтовать.
- **Codex НЕ трогает** `supervisor.ps1` / `watchdog.ps1` / `install-*.ps1` / Task / `.git`-конфиг пока у Claude `IN PROGRESS` по инфра-надёжности.
- Общие файлы (`lib/backlog.ps1`, `lib/common.ps1`, `config.json`) — предупреждай в этой таблице перед крупной правкой.
- Закончил claim → переведи в `DONE` и освободи файлы.

## История

- 2026-06-03 12:30 — Claude взял инфра-надёжность (см. выше). Причина: двойной каскад OneDrive→`.git` занулён + supervisor/watchdog умерли без авто-рестарта.
