# BRIDGE STATUS — единая точка входа

> **Зачем этот файл.** Это «обложка» проекта: с него начинают, чтобы за минуту понять
> **актуальную версию, что сейчас умеет мост, как им управлять и как с ним работать.**
> Остальные документы — глубже по темам (см. карту ниже). Если сомневаешься, что доки
> не устарели — раздел **«Как проверить РЕАЛЬНОЕ состояние»** говорит, как посмотреть живое
> состояние напрямую, не доверяя тексту.

_Обновлено: 2026-06-02. Поддерживает: оператор (Claude) + Codex. Держать актуальным при крупных изменениях._

---

## 1. Что такое мост (в двух абзацах)

Мост — автономная команда из двух ИИ-ролей поверх локальных процессов на Windows:
**Claude планирует/ревьюит, Codex (и пул LLM-воркеров) кодит.** Цель — команда, которая
делает ~80% работы по проекту сама, а оператор оркеструет и чинит инфраструктуру.

Топология процессов: **Task Scheduler → supervisor.ps1 → server.ps1 (пульт :8787) +
driver.ps1 (по одному на канал) + watchdog.ps1**. Каждый **канал = проект = «вкладка»**
(`channels/<slug>/`: state.json, backlog.jsonl, conversation.jsonl). `main` — канал развития
самого моста. Рантайм/состояние держатся вне OneDrive (`C:\Users\rafie\.bridge-runtime`).

---

## 2. Текущая версия / веха

- **Веха:** `2026-06-02 — Project Autopilot ПОД Discuss-First + Project Acceptance.`
- **Предыдущие вехи:** Foundation #1 (рантайм вне OneDrive) → #3 (честная метрика автономии) →
  #4 (доказана сквозная автономия на реальном проекте) → пакет надёжности параллели (ERR-001..015).
- **Точная версия = git HEAD** репозитория моста (см. ниже). Отдельного номера версии нет —
  истина в git-истории и в живом состоянии.

### Что нового в этой вехе (сессия 2026-06-01/02)
1. **12 корневых фиксов параллели/надёжности** (журнал: `OPERATOR_ERROR_LOG.md`): CRLF-ложные
   failed, карантин провалившихся потоков, dispatch-once (без петли), dependency-aware packing,
   честный zero-output, Doctor self-repair в bridge-root, project-build verify, mixed→planner,
   обобщённый RUNJOB-дедуп, env-var safety, guard без ложных halt.
2. **Project Autopilot** — мост сам разворачивает утверждённый план в атомы (coordinator +
   ready-frontier scheduler с `depends_on`).
3. **Project Acceptance** — финальная приёмка: поднимает реальный сервер, бьёт по роутам, пишет
   evidence, при FAIL заводит fix-задачу.
4. **Гейт Discuss-First над Autopilot** — autopilot включается ТОЛЬКО после утверждения плана
   оператором (`Set-ProjectPlanApproved`). Без утверждения мост остаётся в обсуждении.

---

## 3. Как проверить РЕАЛЬНОЕ состояние (не доверяя докам)

```powershell
# (a) Актуальный код моста — последние изменения и текущий HEAD:
git -C C:\Users\rafie\OneDrive\Documents\bridge log --oneline -10
git -C C:\Users\rafie\OneDrive\Documents\bridge log -1 --format='HEAD %h %ci %s'

# (b) Живут ли процессы (supervisor/server/drivers):
Get-Process powershell,node -ErrorAction SilentlyContinue | Sort-Object StartTime |
  Format-Table Id,ProcessName,@{N='Start';E={$_.StartTime.ToString('HH:mm:ss')}}

# (c) Пульт жив? (401 = жив, требует авторизации — это норма):
try { (Invoke-WebRequest http://127.0.0.1:8787/ -TimeoutSec 5 -UseBasicParsing).StatusCode } catch { $_.Exception.Message }

# (d) Состояние канала (статус / задача / autopilot / doctor):
Get-Content C:\Users\rafie\OneDrive\Documents\bridge\channels\<slug>\state.json -Raw | ConvertFrom-Json |
  Select-Object status, current_task, doctor_active, workpack_batch_active

# (e) Здоровье watchdog (последний smoke + stable-коммит):
Get-Content C:\Users\rafie\OneDrive\Documents\bridge\control\watchdog.log -Tail 4

# (f) Что мост умеет (реестр фич + их живой статус):
#     features/registry.json  (полный список), features/state.json (активность)
```

**Правило:** доки описывают намерение; `git log` + `state.json` + `watchdog.log` — это факт.
При расхождении верь факту и обнови доку.

---

## 4. Карта документов — куда смотреть

| Тебе нужно… | Документ | Свежесть |
|---|---|---|
| **Эта обложка / версия / точка входа** | `BRIDGE_STATUS.md` (этот файл) | актуально |
| **Как управлять мостом** (пульт, задачи, процессы, команда, нюансы) | `OPERATOR_GUIDE.md` | актуально |
| **Как работать над проектом** (Discuss-First, атомы, ревью, autopilot gate) | `PROJECT_WORKFLOW.md` | актуально |
| **Как устроен код моста** (для разработчика/самоулучшения) | `DEVELOPER_GUIDE.md` | актуально |
| **Карта подсистем моста** (что из чего состоит) | `PROJECT_MAP.md` | актуально |
| **Журнал инцидентов/ошибок** (что ломалось и как чинили) | `OPERATOR_ERROR_LOG.md` | живой |
| **Мониторинг/диагностика** (что смотреть когда «что-то не так») | `MONITORING_RUNBOOK.md` | проверить |
| Старые материалы (ранние идеи/обсуждения) | `ARCHITECTURE_V2.md`, `architecture-matrix.md`, `discussion.md`, `roles.md`, `sources.md`, `goals.md`, `AGENTS.md`, `external-systems.md`, `study-travel-*.md` | **архив (≤05-27), не источник правды** |

---

## 5. Как УПРАВЛЯТЬ (шпаргалка; подробно — OPERATOR_GUIDE.md §5)

```powershell
$bridge = 'C:\Users\rafie\OneDrive\Documents\bridge'

# Перезапустить мост целиком (правильно — через планировщик):
Stop-ScheduledTask -TaskName 'ClaudeCodexBridge'; Start-Sleep 3; Start-ScheduledTask -TaskName 'ClaudeCodexBridge'

# Применить правку .ps1 без полной остановки (graceful recycle драйверов):
Set-Content "$bridge\control\restart.flag" '1' -Encoding ASCII

# Полная остановка:
Stop-ScheduledTask -TaskName 'ClaudeCodexBridge'

# Утвердить план проекта → разрешить Project Autopilot (Discuss-First Ф4):
. "$bridge\lib\common.ps1"; . "$bridge\lib\backlog.ps1"
Set-ProjectPlanApproved -Channel '<slug>'        # снять разрешение: -Approved:$false
```

- **Пульт:** `http://127.0.0.1:8787` — чат канала, кнопки ⏸ Пауза / ▶ Продолжить / ⏹ Стоп /
  🛑 Стоп-кран / ♻ Перезапуск.
- **Не дёргай мост частыми рестартами** — circuit-breaker: 5 рестартов/30 мин → 15 мин cooldown.
  Чистый выход (код 0) брейкер НЕ считает.
- **Каналы** живут в `channels/<slug>/`; архив — `channels/_archive/`.

---

## 6. Как РАБОТАТЬ над проектом (поток; подробно — PROJECT_WORKFLOW.md)

**Новый проект = новая вкладка** (`New-Project`), НИКОГДА не в `main`/чужом канале.

Незыблемый порядок (Discuss-First):

```
Ф0 намерение (оператор)
 → Ф1 ГЛУБОКОЕ обсуждение мостом (DISCUSS: мост сам вскрывает нестыковки)
 → Ф2 мост пишет PROJECT_MAP.md + PROJECT_PLAN.md (durable)
 → Ф3 моё ревью плана (архитектор-гейт)
 → Ф4 оператор УТВЕРЖДАЕТ план  →  Set-ProjectPlanApproved -Channel <slug>
 → Ф6 Project Autopilot исполняет атомы (ready-frontier, depends_on; параллель только независимых)
 → Ф7 Project Acceptance сверяет результат (build + реальный запуск + флоу как в карте)
```

- **Только после Ф4 autopilot пилит.** Без утверждения мост остаётся в обсуждении/планировании
  и НЕ генерит атомы (это защита от «франкенштейна» — собирается, но продукт несвязный).
- **В беклог идут только АТОМЫ** (1 файл / 1 маленькое проверяемое изменение, проходит tsc/build сам).
  Крупный этап в беклоге = воркер ломается.
- **Ревью-разграничение:** оператор ревьюит только уровень ГЛАВ; параграфы/абзацы/атомы — ревью Claude.
- **Приёмка (Ф7) — не «зелёный build», а «флоу как в утверждённой карте».**

---

## 7. Здоровье и подводные камни (быстро; подробно — OPERATOR_GUIDE §8)

- **PS 5.1:** .ps1 с кириллицей — UTF-8 **BOM**; нативный exe в stderr на exit 0 → NativeCommandError
  (решается опорой на `$LASTEXITCODE`, не на stderr).
- **OneDrive:** код моста на OneDrive (git), рантайм/состояние — вне (`.bridge-runtime`), иначе lock-гонки.
- **Доки устаревают** — раздел §3 показывает, как смотреть живое состояние.
- **Не делать работу ЗА мост:** оператор чинит инфраструктуру моста, не дописывает код проекта руками.
