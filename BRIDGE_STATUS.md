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

> **⚠️ ВАЖНО (2026-06-03): `.git` вынесен с OneDrive.** Реальный git-каталог теперь
> `C:\Users\rafie\.bridge-runtime\bridge-git`; `bridge\.git` — это **gitlink-файл** (`gitdir: …`),
> не папка. Причина: OneDrive занулял `.git/refs/heads/master` и держал locks, вешавшие watchdog
> (3 аварии за сутки). Обычные git-команды работают прозрачно. Прямой доступ к `.git/refs` или
> `.git/HEAD` в коде ДОЛЖЕН резолвить gitlink (см. `ensure-bridge.ps1`/`server.ps1`).
>
> **Самовосстановление:** `ensure-bridge.ps1` (Task `ClaudeCodexBridge-Ensure`, каждые 5 мин,
> регистрируется супервизором) лечит мёртвый/зависший supervisor+watchdog и занулённый git-ref.

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
- **Решения (Ф1, режим `synthesis`).** Глубокое обсуждение и High-Stakes-решения идут через
  **Multi-Model Decision Synthesis** (`synthesisMode.enabled=true`): no-LLM роутер глубины
  (`lib/decision-depth.ps1`: Simple/Standard/Deep/High-Stakes) запускает stateless-пайплайн
  (`lib/decision-synthesis.ps1`): TaskContract → 3 слепых предложения → ConflictMatrix →
  CrossReview → Judge → MicroDebate → FinalV2+RedTeam → Decision Record (чекпойнты в
  `channels/<slug>/decisions/<id>/`). **Это пришло на смену старому двухмодельному DISCUSS-диалогу.**
  High-Stakes и high-severity red-team всегда дают `needs_operator` (НЕ авто-внедряется до утверждения).

---

## 7. Здоровье и подводные камни (быстро; подробно — OPERATOR_GUIDE §8)

- **PS 5.1:** .ps1 с кириллицей — UTF-8 **BOM**; нативный exe в stderr на exit 0 → NativeCommandError
  (решается опорой на `$LASTEXITCODE`, не на stderr).
- **OneDrive:** код моста на OneDrive (git), рантайм/состояние — вне (`.bridge-runtime`), иначе lock-гонки.
- **Доки устаревают** — раздел §3 показывает, как смотреть живое состояние.
- **Не делать работу ЗА мост:** оператор чинит инфраструктуру моста, не дописывает код проекта руками.

---

## 8. Bridge Self-Model

**Что это.** Derived runtime artifact — компактная самомодель моста (~1.5–2.5 KB). Генерируется
*из реальности* и инжектируется в промпт канала `main` при каждом ходе, чтобы агент всегда видел
актуальное состояние самого себя.

### Source-of-truth mapping (источники → self-model)

| Источник | Что берётся |
|---|---|
| `features/registry.json` | список фич, owner_file, статус |
| `features/state.json` | активность / activation_date |
| `docs/`, `BRIDGE_STATUS.md` | человекочитаемый контекст |
| `lib/`, `driver/`, `tools/` | архитектурные факты |
| git (HEAD, recent log) | версия, последние изменения |

> **⚠ Cache — derived, руками НЕ поддерживать.** Настоящий source of truth — файлы выше.
> Cache (`.bridge-runtime/self-model/main.*`) создаётся автоматически и может быть пересоздан
> в любой момент без потери данных.

### Четыре части пайплайна

```
Generator           lib/self-model.ps1
  ↓ (read-only, собирает пакет из источников)
Refresh             tools/refresh-self-model.ps1
  ↓ (кешируется → .bridge-runtime/self-model/main.pack.json + main.prompt.txt)
Inject              driver/30-prompt-agent-state.ps1  (Build-Prompt)
  ↓ (читает ТОЛЬКО cache, main-only, fail-open)
Drift Audit         tools/self-model-drift.ps1
    (read-only, ловит рассинхрон: stale hash, owner_file_missing, size cap)
```

### Как обновляется

- **Авто** — hook в `driver/86-loop-completion.ps1` запускает refresh после каждой успешно
  завершённой задачи (fail-open: сбой refresh не ломает completion).
- **Вручную** — `tools/refresh-self-model.ps1` (идемпотентен: no-op, если источники не менялись).

### Чем НЕ является

- Не новая память (не заменяет `memory/`, не пишет туда).
- Не замена guard/safety-механизмов.
- Не ручной документ — редактировать cache вручную бессмысленно (перезатрётся при следующем refresh).

### Известные drift-находки (текущие, для разбора)

Смотреть живьём: `tools/self-model-drift.ps1 -BridgeRoot <bridge>` (read-only). На 2026-06-23:

- `OPERATOR_GUIDE.md` — `source_hash_drift` (док изменился, self-model pack пересобрать).
- `size_cap_exceeded` — pack ~2.7 KB при cap 2560 B (raise cap или подрезать пакет).
- `lib/batch-timeout.ps1`, `lib/decision-depth.ps1` — `undocumented_module` (info: добавить в `features/registry.json`).
