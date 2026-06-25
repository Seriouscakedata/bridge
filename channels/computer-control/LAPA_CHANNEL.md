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
- если `allowed_apps` задан, generic `uia/vision/keyboard` action обязан декларировать `app/app_name`; одного `window_hwnd` недостаточно;
- применяет risk floor для отправки, submit, booking, purchase, delete, payment;
- выполняет действия через `LapaActionExecutor`:
  - `kind=skill` -> существующие навыки ЛАПЫ (`open-app`, `type`, Telegram flows);
  - `kind=uia` -> `Lapa.run(Intent)` с `Selector`, five-gate loop и UIA VERIFY;
  - `kind=vision` -> guarded canvas mode `vision_click` с confidence/safety/STOP;
  - `kind=keyboard` -> навигационные VK-клавиши; это не proof, после него обязателен новый observe;
- после `incomplete/aborted` наблюдает заново и может попробовать следующий шаг;
- не принимает `finish` без real evidence.

Статус: planner loop, CLI/wrapper и concrete executor для `skill/uia/vision/keyboard` подключены, headless-тесты зеленые. `kind=uia` и `kind=vision` используют те же fail-closed gates, что и ядро ЛАПЫ; `kind=keyboard` намеренно возвращает `INCOMPLETE`, пока следующий observe не даст реальное доказательство. Live smoke 2026-06-25 проведен на задаче смены фона через Windows Settings: частично работает, но задачу до конца не завершил.

Live smoke 2026-06-25, Windows Settings -> Персонализация -> Фон:

- ЛАПА открыла/нашла окно настроек, закрыла внешний TeamViewer popup через canvas click, выбрала `Персонализация`, открыла `Фон`, раскрыла ComboBox `Персонализируйте фон` и выбрала `Сплошной цвет`.
- Финальный выбор синего swatch не завершен: planner периодически возвращал невалидный/no JSON, а swatch-выбор требовал более надежного vision/UIA шага.
- По итогам smoke добавлены: structured `observation.window_hwnd`, увеличенный UIA node cap до 180, один retry на невалидный planner JSON, mapping `open_app` params `app -> name`, reuse hwnd из `open_app` evidence, wrapper неожиданных UIA/vision exceptions в `ExecutionReport`, нормализация `ListItem/TabItem click -> select` и `ComboBox click -> expand`.

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
- Operator layer: planner loop, real DesktopObserver, Gemini planner seam, `LapaActionExecutor` (`skill/uia/vision/keyboard`), CLI `operator-task`, bridge wrapper `operator-task`.

## 6. Что частично работает или не готово

- `operator-task` теперь имеет arbitrary UIA/canvas/keyboard executor, но его качество на реальном рабочем столе зависит от того, насколько planner увидит корректный UIA selector или даст точное vision-описание.
- При заданном `allowed_apps` observer не смотрит случайный foreground window: если разрешённое окно не найдено, он возвращает `no target window found`.
- `kind=keyboard` годится только для навигации между наблюдениями; сам по себе он никогда не доказывает завершение задачи.
- Self-learning есть как opt-in Python API, но не включено автоматически в bridge skills.
- Обычный `telegram-send` safety semantics нужно привести к документам: либо явно считать marker авторизацией, либо добавить confirm gate.
- Live desktop acceptance для `operator-task` проведена частично: Settings flow дошел до `Сплошной цвет`, но не завершил выбор синего swatch.
- Кириллические app names в отдельных путях PowerShell/Gemini могут превращаться в `?????????`; для live smoke временно использовался foreground-периметр.
- `open_app('Настройки')` может запускать Settings, но live title окна бывает `Параметры`; observer умеет переиспользовать hwnd из `open_app` evidence, однако сам skill `open_app` для уже открытого Settings еще может не дождаться окна по title lookup.
- Medium-risk canvas click без специфического verify остается `Unverifiable`; для визуальных low-risk swatch clicks planner должен явно объявлять `risk=low` или нужен typed verifier для таких настроек.
- Gemini planner требует `LAPA_GEMINI_API_KEY` или `GEMINI_API_KEY` либо ключ в `~/.bridge-private/secrets.json`. Без ключа planner честно вернет no decision/incomplete.

## 7. Проверка

Из `C:\Users\rafie\bridge-projects\lapa`:

```powershell
python -m pytest tests/ -q
python -m compileall -q lapa tests conftest.py
```

Текущий результат после подключения `operator-task`:

```text
486 passed, 1 skipped
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

2. Доделать live swatch selection: устойчивый low-risk color-swatch executor/verify или planner recipe для Windows Settings color grid.
3. Починить title/app-name mismatch для `open_app('Настройки')` -> live window `Параметры` без app-specific хрупкости.
4. Подключить self-learning к operator failure path как opt-in.
5. Исправить/уточнить safety contract обычного `telegram-send`.
