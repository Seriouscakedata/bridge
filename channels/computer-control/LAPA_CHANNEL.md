# ЛАПА / computer-control channel

Обновлено: 2026-06-24.

Этот документ фиксирует текущую рабочую правду по каналу ЛАПЫ: что реально подключено к мосту, что покрыто тестами, где есть ограничения, и как правильно вызывать.

## 1. Где находится проект

- Актуальный проект ЛАПЫ: `C:\Users\rafie\bridge-projects\lapa`
- Python package: `C:\Users\rafie\bridge-projects\lapa\lapa`
- Bridge wrapper: `C:\Users\rafie\OneDrive\Documents\bridge\tools\lapa-control.ps1`
- Bridge marker parser: `driver/84-loop-reply-markers.ps1`
- Channel slug: `computer-control`
- Legacy project: `C:\Users\rafie\bridge-projects\computer-control` — это старый `cc.py`, не актуальная точка входа ЛАПЫ.

## 2. Как мост вызывает ЛАПУ

Формат маркера в ответе агента:

```text
[[ЛАПА: skill | key=value | key=value]]
```

Дальше мост делает:

```text
[[ЛАПА]] marker
  -> tools/lapa-control.ps1 / Invoke-LapaSkill
  -> python -m lapa.cli <skill> ...
  -> JSON ExecutionReport
  -> [SYSTEM] ответ агенту со status/evidence/proof
```

Wrapper не должен содержать бизнес-логику. Он только мапит friendly params в CLI flags, запускает Python, парсит JSON и возвращает структурированный результат.

## 3. Навыки, доступные через мост

### open-app

```text
[[ЛАПА: open-app | name=Notepad]]
```

Открывает приложение и ждет top-level window. Доказательство успеха: `uia_read` с hwnd.

Статус: работает, покрыто headless-тестами; live-приемка нужна для новых/локализованных приложений.

### type

```text
[[ЛАПА: type | app=Notepad | field= | text=hello]]
```

Открывает/находит приложение и вводит текст в `Edit` поле через five-gate loop. Доказательство успеха: read-back из UIA.

Статус: работает для UIA-доступных полей. Не подходит для полностью custom-drawn полей без UIA.

### telegram-send

```text
[[ЛАПА: telegram-send | contact=Имя | message=текст]]
```

Открывает Telegram, ищет контакт, проверяет identity gate по заголовку чата, вводит сообщение и отправляет Enter. Доказательство: screenshot.

Статус: работает по тестам и старому live-flow, но есть важный safety debt: обычный `telegram-send` в текущей реализации сам не требует `SafetyPolicy.confirm`; если вызван явным marker, это фактически считается авторизацией. Для автономного `operator-task` отправка Telegram имеет risk floor `medium` и без подтверждения будет остановлена.

### telegram-send-sticker

```text
[[ЛАПА: telegram-send-sticker | contact=Имя | description=описание стикера]]
```

Canvas/vision режим для custom-drawn sticker panel. Проверяет чат, ищет стикер через vision, кликает только при confidence threshold и post-click verify.

Статус: best-effort. Через unattended CLI/wrapper medium-risk send без confirm должен fail-closed.

### operator-task

```text
[[ЛАПА: operator-task | goal=Открой Блокнот и напечатай hello | allowed_apps=Notepad | allowed_skills=open-app,type | forbidden_actions=delete,pay | max_steps=5]]
```

Новый planner/LLM слой над руками ЛАПЫ. Он:

- наблюдает GUI через `DesktopObserver` (`screenshot` + compact UIA nodes);
- отправляет наблюдение и историю в `GeminiOperatorPlanner`;
- принимает только strict JSON decision: `act`, `finish`, `ask_operator`, `fail`;
- проверяет perimeter (`allowed_apps`, `allowed_skills`, `forbidden_actions`);
- применяет risk floor для отправки, submit, booking, purchase, delete, payment;
- выполняет skill-действия через `LapaSkillExecutor`;
- после `incomplete/aborted` наблюдает заново и может попробовать следующий шаг;
- не принимает `finish` без real evidence.

Статус: каркас и skill-executor подключены, CLI/wrapper доступны, headless-тесты зеленые. Реальные UIA/vision generic actions (`kind=uia`, `kind=vision`, `kind=keyboard`) пока не имеют полноценного concrete executor; сейчас надежный реальный executor — только `kind=skill` через существующие навыки.

## 4. Безопасность

ЛАПА должна оставаться fail-closed.

Текущие правила:

- `low` может выполняться автоматически.
- `medium/high` требуют confirmation hook.
- `critical` отказывается всегда.
- `operator-task` через bridge wrapper не получает `--confirm-risky`, значит автономный мост не может сам подтвердить покупку, бронь, отправку, удаление или submit.
- Пароли, 2FA, платежные credentials — hard forbidden / critical. Их вводит оператор-человек.
- Успех без real evidence запрещен: `ExecutionReport(COMPLETED)` должен иметь screenshot, UIA read или file proof.

Практический вывод: ЛАПА может готовить бронь/покупку до финального подтверждения, но финальный submit/payment должен остановиться и запросить человека.

## 5. Что реально работает сейчас

- Five-gate ядро: PERCEIVE -> RESOLVE -> PROVE -> ACT -> VERIFY.
- UIA selector/resolver/action/verifier.
- App launcher с защитой от ложных window matches.
- STOP flag / stop controller.
- CLI JSON reports.
- Bridge marker invocation.
- `open-app`, `type`, `telegram-send`, `telegram-send-sticker`.
- Self-learning infrastructure: capture/analyze/recipe/validate/recall/wire, opt-in in-process.
- Operator layer: planner loop, real DesktopObserver, Gemini planner seam, LapaSkillExecutor, CLI `operator-task`, bridge wrapper `operator-task`.

## 6. Что частично работает или не готово

- `operator-task` пока выполняет реальные действия только через existing skills. Он еще не полноценный arbitrary UIA/canvas executor.
- Self-learning есть как opt-in Python API, но не включено автоматически в bridge skills.
- Обычный `telegram-send` safety semantics нужно привести к документам: либо явно считать marker авторизацией, либо добавить confirm gate.
- Live desktop acceptance для `operator-task` еще не проведена.
- Gemini planner требует `LAPA_GEMINI_API_KEY` или `GEMINI_API_KEY` либо ключ в `~/.bridge-private/secrets.json`. Без ключа planner честно вернет no decision/incomplete.

## 7. Проверка

Из `C:\Users\rafie\bridge-projects\lapa`:

```powershell
python -m pytest tests/ -q
python -m compileall -q lapa tests conftest.py
```

Текущий результат после подключения `operator-task`:

```text
474 passed, 1 skipped
```

Из bridge root проверить wrapper:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command ". 'C:\Users\rafie\OneDrive\Documents\bridge\tools\lapa-control.ps1'; Get-LapaSkillNames"
```

Ожидаемый список включает:

```text
open-app
operator-task
telegram-send
telegram-send-sticker
type
```

## 8. Рекомендуемые следующие шаги

1. Провести live smoke для безопасной задачи:

```text
[[ЛАПА: operator-task | goal=Открой Блокнот и напечатай test | allowed_apps=Notepad | allowed_skills=open-app,type | forbidden_actions=delete,pay | max_steps=5]]
```

2. Добавить concrete executor для `kind=uia` поверх `Lapa.run(Intent)`.
3. Добавить concrete executor для `kind=vision` поверх canvas mode.
4. Подключить self-learning к operator failure path как opt-in.
5. Исправить/уточнить safety contract обычного `telegram-send`.
