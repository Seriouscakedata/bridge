# DISCUSS C — Vision как first-class planning signal

_DA03: Vision глубоко интегрирована в планирование, а не только в locate элемента_

---

## Текущая роль Vision в ЛАПЕ

Сейчас Vision (Gemini Flash Lite):
- Вызывается ТОЛЬКО при UIA-промахе (lazy fallback)
- Возвращает selector-refinement, который заново идёт через resolver
- Никогда не кликает по координатам
- Единственная цель: помочь найти UI-элемент

Vision = «запасной переводчик с пикселей на UIA», не более.

---

## Новая роль Vision в планировщике (DA03)

Vision становится **first-class planning oracle** в 4 ролях:

### Роль 1: State Summary (Percept-before-Plan)

Перед декомпозицией задачи или перед каждым шагом:
```
vision.describe_screen(screenshot) →
  {
    "active_app": "Telegram Desktop",
    "visible_windows": [...],
    "form_fields": [...],
    "current_context": "чат с Иваном, поле ввода пустое",
    "affordances": ["send_button", "search_bar", ...]
  }
```
LLM плановщик использует это как context для первоначальной декомпозиции.
Без state summary плановщик «слепой» в начале задачи.

### Роль 2: Affordance Map

Перед планированием шага плановщик запрашивает:
```
vision.list_affordances(screenshot, goal="найти поле поиска") →
  ["search_input[AutomationId=SearchBox]", "Ctrl+K shortcut available"]
```
Это помогает плановщику сгенерировать реалистичные selector-ы, а не
галлюцинировать AutomationId-ы.

### Роль 3: Pre/Post-condition verification

```
# Перед шагом (precondition):
vision.check_precondition(screenshot, condition="поле поиска пустое и в фокусе") →
  {verified: true, confidence: 0.91}

# После шага (postcondition):
vision.check_postcondition(screenshot, condition="сообщение отправлено, виден тик") →
  {verified: true, confidence: 0.85}
  # OR
  {verified: false, confidence: 0.90, reason: "кнопка отправки всё ещё активна"}
```

Это позволяет обнаружить провал шага даже когда UIA-верификация вернула Unverifiable
(кастомные элементы Telegram — именно этот случай).

**Открытый вопрос C1:** Какие пороги confidence → replan vs escalate vs fail-closed?
Предложение (требует калибровки):
```
confidence >= 0.80 → verified (proceed / fail accordingly)
0.60 <= confidence < 0.80 → uncertain → trigger recovery ladder (retry/re-perceive)
confidence < 0.60 → low-confidence → escalate to operator (не auto-fail-closed)
```

### Роль 4: Stuck Diagnosis и Recovery Input

Когда retry бюджет исчерпан на шаге:
```
vision.diagnose_stuck(screenshot, intended_action, last_error) →
  {
    "diagnosis": "кнопка отправки disabled, поле ввода пустое — сообщение не заполнено",
    "suggested_recovery": "re-fill message field before send",
    "replan_hint": "go back to fill-message step"
  }
```
Это **вход для LLM-переплановщика**, не самостоятельное действие.
Vision ставит диагноз; LLM решает что делать.

---

## Инварианты Vision (не меняются!)

Из существующего DESIGN.md — **эти принципы сохраняются**:

1. **VISION-PROPOSES-UIA-DISPOSES**: Vision никогда не кликает по координатам
2. **Perception-only**: Vision не пишет в state, не меняет TaskGraph напрямую
3. **Single-call per decision point**: нет Vision-в-цикле без UIA-miss или явного trigger
4. **Returns selector refinement or structured assessment**, not raw coordinates

Новые роли расширяют когда Vision вызывается, но не меняют что она возвращает и кто принимает решения.

---

## Vision model policy

Сохраняется из DESIGN.md: `gemini-2.5-flash-lite` для всех vision-вызовов.
НИКОГДА `gemini-2.5-pro` (стоимость).

Для state_summary и affordance_map — допустимо кэшировать скриншот между вызовами
одного planning-шага (не делать 4 скриншота для 4 ролей).

---

## Открытый вопрос C2: Частота Vision-вызовов

Чтобы не превратить Vision из lazy в eager:

Предложение:
- State summary: 1 вызов в начале задачи + при каждом реактивном переплане
- Affordance map: только если LLM плановщик явно запрашивает
- Precondition check: только для HIGH-risk узлов (не для каждого шага)
- Postcondition check: для шагов где UIA-verifier вернул Unverifiable
- Stuck diagnosis: при исчерпании retry-бюджета шага

Это сохраняет «lazy» характер Vision и предотвращает 4× Vision-вызовы на каждое действие.
