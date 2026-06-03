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
| **Claude** | Инфра-надёжность: Task RestartOnFailure + supervisor/watchdog self-heal + защита `.git` от OneDrive (после инцидента 2026-06-03: supervisor+watchdog были мертвы 6–11ч, мост без надзора; до этого OneDrive занулил `.git/refs/heads/master`) | `supervisor.ps1`, `watchdog.ps1`, `install-autostart.ps1`, `install-watchdog.ps1`, Task `ClaudeCodexBridge`, `.git/**`, `.gitignore` (git-секция) | **IN PROGRESS** | 2026-06-03 12:30 |
| **Codex** | Рефакторинг/модуляризация `driver.ps1` (6235 строк → тонкий оркестратор + `lib/*.ps1`) | `driver.ps1`, новые `lib/*.ps1` модули | (Codex проставит) | — |

## Что это значит на практике

- **Claude НЕ трогает `driver.ps1`** пока у Codex активен claim на рефакторинг — чтобы не конфликтовать.
- **Codex НЕ трогает** `supervisor.ps1` / `watchdog.ps1` / `install-*.ps1` / Task / `.git`-конфиг пока у Claude `IN PROGRESS` по инфра-надёжности.
- Общие файлы (`lib/backlog.ps1`, `lib/common.ps1`, `config.json`) — предупреждай в этой таблице перед крупной правкой.
- Закончил claim → переведи в `DONE` и освободи файлы.

## История

- 2026-06-03 12:30 — Claude взял инфра-надёжность (см. выше). Причина: двойной каскад OneDrive→`.git` занулён + supervisor/watchdog умерли без авто-рестарта.
