# DISCUSS B — Автономность vs Контроль: как разрешить главное противоречие

_DA02, DA05, DA06, DA09: stateless advisory, risk-ladder, STOP, validation invariant_

---

## Главное противоречие

Цель оператора: ЛАПА автономно выполняет высокоуровневые задачи.
Требование безопасности: каждый шаг проверен, высокорисковые — подтверждены оператором.

Наивная конструкция: оператор подтверждает каждый шаг → нет автономии.
Другая крайность: LLM выполняет всё самостоятельно → нет контроля.

---

## Принятое решение: Pre-approved boundaries + automated per-step validation

Разрешение противоречия через **разделение доменов**:

```
Оператор контролирует ГРАНИЦЫ (один раз, до исполнения):
  - Что задача должна делать (goal, success_criteria)
  - Какие приложения разрешены (allowed_apps)
  - Какой риск-класс допустим без confirm (risk_auto_proceed)
  - Максимальное число шагов / время / бюджет риска

Автоматика контролирует КАЖДЫЙ ШАГ (без latency):
  - Schema + skill-compliance валидация каждого узла
  - Risk re-classification per-node
  - Vision postcondition-check

Оператор подтверждает ТОЛЬКО ЭСКАЛАЦИИ:
  - Узел с risk > pre-approved threshold → confirm с конкретным payload
  - Recovery ladder исчерпан → escalate/STOP
  - Out-of-vocabulary навык → fail-closed, объяснение оператору
```

**Ключевой принцип:** оператор одобряет план + контракт один раз.
Реактивное раскрытие свободно внутри этих границ, но каждый новый узел
автоматически проходит тот же validation gate, что и pre-planned узлы.

---

## Плановщик как «stateless advisory» (DA02)

Плановщик **не имеет** прямого доступа к исполнению. Он только:
- Генерирует узлы TaskGraph
- Интерпретирует Vision-состояние для replanning

Все действия идут через 5-гейтовый loop. Loop — единственная точка принуждения.

Важное уточнение из red-team: «stateless» здесь означает «не имеет независимого
authority». При этом системе нужно хранить:
- Текущее состояние TaskGraph (прогресс)
- Retry-бюджеты по узлам
- Watchdog-счётчики

Это состояние должно быть:
- Явно смоделировано (не скрыто в промпте LLM)
- Сериализуемо (для partial-state report при STOP)
- Защищено от записи со стороны LLM (read-only для плановщика, rw для гейтов)

---

## Risk ladder (DA05): task-level + per-node

```
TASK-LEVEL (при получении задачи):
  Оператор видит суммарный risk-класс задачи.
  Если overall_risk > порога → оператор одобряет или отклоняет задачу целиком.

PER-NODE (перед каждым шагом):
  risk_class = classify(node)
  if risk_class == low:   → auto-proceed (в пределах pre-approved threshold)
  if risk_class == medium: → confirm с payload (если medium не в pre-approved)
  if risk_class == high:  → всегда confirm с полным payload
  if risk_class == critical: → always refuse, объяснение оператору

FAIL-CLOSED DEFAULT:
  unknown/ambiguous risk → medium (confirm), никогда не auto-proceed тихо
```

**Открытый вопрос B1:** Какие конкретно risk-классы входят в `pre-approved auto-proceed`?
Предложение: `low` всегда auto; `medium` — оператор выбирает при запуске задачи.

**Критически важно (red-team RT5):** Confirm должен показывать **конкретный payload**,
а не только тип действия. Пример:
```
[CONFIRM REQUIRED]
Действие: telegram-send
Получатель: Иван Петров (чат заголовок: "Иван Петров")
Сообщение: "Привет! Вот данные: [полный текст]"
Risk: medium (send/external)
[YES / NO / STOP]
```
Без конкретного payload confirm превращается в «театр безопасности».

---

## STOP: глобальный, асинхронный, преемптивный (DA06)

```
Источники сигнала STOP:
  1. Ctrl+Alt+Pause (low-level Win32 hook) — основной
  2. stop.flag файл — fallback (для bridge-интеграции)
  3. in-process threading.Event — межпоточная синхронизация

При STOP:
  - НЕМЕДЛЕННО: установить Event, прекратить генерацию новых узлов
  - МЕЖДУ ГЕЙТАМИ: loop проверяет Event → abort с StoppedByOperator
  - Никакой авто-resume
  - Сохранить partial-state report: что выполнено, что в процессе, что не начато
  - Выпустить все удерживаемые клавиши (если были)
```

**Честное ограничение (red-team RT4):** STOP прекращает эмиссию НОВЫХ действий,
но не откатывает уже исполненные OS-эффекты. Это нужно чётко коммуницировать
оператору. `partial_state_report` должен явно перечислить «что уже сделано и
необратимо».

---

## Validation invariant: «no unverified execution» (DA09)

Любой узел — initial, reactively unfolded, replanned — перед исполнением:
1. Проходит schema validation (соответствие TaskGraph node schema)
2. Проходит skill-compliance check (навык в закрытом словаре)
3. Re-classifies risk per-node
4. Если risk требует → confirm с payload

**Это не конфигурация, это структурный инвариант.**
Плановщик не может «попросить пропустить» validation для «доверенного» узла.
