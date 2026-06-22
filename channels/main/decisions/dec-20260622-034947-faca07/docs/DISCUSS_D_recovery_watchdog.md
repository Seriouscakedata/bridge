# DISCUSS D — Recovery Ladder и Autonomy Watchdog

_DA07: bounded recovery ladder | DA10: autonomy watchdog_

---

## Recovery Ladder (DA07)

Когда шаг провалился, ЛАПА не останавливается немедленно (если бюджет не исчерпан).
Лестница восстановления с явными бюджетами:

```
УРОВЕНЬ 0: Retry current action
  - Условие: transient UIA error (StaleSnapshot, WindowGone temporary)
  - Бюджет: max_retries_per_node (предложение: 2)
  - Механизм: re-snapshot → re-resolve → re-prove → re-act
  - Нет LLM-вызова

УРОВЕНЬ 1: Re-perceive / Vision diagnosis
  - Условие: retry исчерпан, UIA-verifier → uncertain/failed
  - Бюджет: 1 vision-call per node
  - Механизм: take screenshot → vision.diagnose_stuck → получить hint
  - Нет LLM-вызова (vision только диагностирует)

УРОВЕНЬ 2: Reactive subgraph replanning
  - Условие: vision дала diagnosis, retry и re-perceive исчерпаны
  - Бюджет: max_replan_per_task (предложение: 3 общих на задачу)
  - Механизм: LLM получает diagnosis + текущее состояние → генерирует новые узлы
  - ОБЯЗАТЕЛЬНО: новые узлы проходят VALIDATION GATE (schema + skill + risk)
  - Если risk требует → confirm с payload

УРОВЕНЬ 3: Escalate to operator / STOP
  - Условие: replan-бюджет исчерпан, или validation gate отклонил предложенные узлы
  - Механизм: STOP с partial-state report + объяснение почему не справились
  - Никакого авто-resume
```

**Структурный инвариант (DA01+DA09):** каждый реактивно созданный узел — тот же путь,
что initial: VALIDATION GATE → risk-classify → (если нужно) confirm → 5-gate loop.

---

## Бюджеты (предложения, требуют калибровки)

| Параметр | Предложение | Конфигурируемо? |
|----------|-------------|----------------|
| `max_retries_per_node` | 2 | Да |
| `max_vision_calls_per_node` | 1 | Да |
| `max_replan_per_task` | 3 | Да |
| `max_steps_total` | 20 | Да (watchdog) |
| `max_wall_clock_seconds` | 300 | Да (watchdog) |
| `max_risk_budget` | sum(risk_weights) ≤ threshold | Да (watchdog) |

Все бюджеты имеют **fail-closed default**: исчерпание → escalate, не auto-retry.

**Открытый вопрос D1:** Как определить `max_steps` для задач разной сложности?
Предложение: оператор указывает при создании задачи; default = 10 шагов для
simple-tasks, 30 для complex. Watchdog предупреждает при 80% исчерпания.

---

## Autonomy Watchdog (DA10)

Дополняет per-node бюджеты глобальным наблюдателем:

```python
class AutonWatchdog:
    max_steps: int          # global step counter
    max_seconds: int        # wall-clock timeout
    max_risk_budget: float  # cumulative risk weight

    # No-progress detector:
    # "no progress" = последние N шагов завершились на ОДНОМ И ТОМ ЖЕ узле
    # (узел не продвинулся к следующему, recovery ladder крутится впустую)
    no_progress_window: int  # предложение: 3 consecutive failures on same node

    def tick(self, step_result):
        # при каждом шаге обновляет счётчики
        # если любой лимит исчерпан → trigger fail-closed STOP
        ...
```

**Почему нужен Watchdog помимо per-node бюджетов:**
- Per-node бюджеты ловят провал одного шага
- Watchdog ловит глобальное зависание (задача «движется», но прогресса нет,
  и суммарно уже потрачено 25 шагов + 5 минут)
- Risk-budget агрегирует суммарный риск всех исполненных шагов — дополнительный
  protect от высокорисковых задач, которые «выглядят как много маленьких low-risk шагов»

**Открытый вопрос D2:** Как детектировать «no progress» на GUI-поверхностях?
Предложение: снимать hash UIA-snapshot после каждого шага; если hash не изменился
за последние N шагов → «no progress». Vision-state-summary как дополнительный signal.

---

## Partial-state report (при STOP / watchdog)

При любом прерывании (STOP или watchdog) генерируется `PartialStateReport`:

```json
{
  "task_goal": "отправить сообщение Ивану",
  "status": "stopped_by_operator",
  "steps_completed": [
    {"node_id": "N1", "action": "open Telegram", "status": "success", "evidence": "..."},
    {"node_id": "N2", "action": "search contact", "status": "success", "evidence": "..."}
  ],
  "steps_not_started": [
    {"node_id": "N3", "action": "send message", "status": "not_executed"}
  ],
  "irreversible_effects": [
    "Telegram opened (reversible — can close)"
  ],
  "safe_to_restart_from": "N3",
  "operator_action_required": "review and manually restart or abort"
}
```

Ключевые поля: `irreversible_effects` (что нельзя откатить) и `safe_to_restart_from`
(с какого узла безопасно рестартовать, если оператор решит продолжить вручную).
