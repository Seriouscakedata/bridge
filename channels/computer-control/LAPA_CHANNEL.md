# ЛАПА / computer-control channel

Обновлено: 2026-06-26.

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
- если `allowed_apps` задан, generic `uia/vision/keyboard/inspect` action обязан декларировать `app/app_name`; одного `window_hwnd` недостаточно;
- применяет risk floor для отправки, submit, booking, purchase, delete, payment;
- выполняет действия через `LapaActionExecutor`:
  - `kind=skill` -> существующие навыки ЛАПЫ (`open-app`, `type`, Telegram flows);
  - `kind=uia` -> `Lapa.run(Intent)` с `Selector`, five-gate loop и UIA VERIFY;
  - `kind=vision` -> guarded Gemini/canvas mode: `vision_click` для действия мышью и read-only `vision_verify/exists` для визуальной проверки без клика. Planner описывает цель визуально, ЛАПА через Gemini находит пиксели и действует только после confidence/safety/STOP проверок;
  - `kind=keyboard` -> навигационные VK-клавиши; это не proof, после него обязателен новый observe;
  - `kind=inspect` -> read-only UIA диагностика окна: расширенный snapshot/filter/find без кликов и ввода;
  - `kind=sequence` -> bounded workflow из `skill/uia/vision/keyboard/inspect` subactions, максимум 20 шагов, без вложенных sequence;
- после `incomplete/aborted` наблюдает заново и может попробовать следующий шаг;
- возвращает ошибки действий обратно в planner history вместе с `operator_action`, `action_signature` и `recovery_hint`, чтобы planner менял селектор, verb или tool family вместо слепого повтора;
- останавливает цикл, если planner дважды повторил одно и то же неуспешное действие (`RepeatedFailedAction`);
- не принимает `finish` без real evidence.

Статус: planner loop, CLI/wrapper и concrete executor для `skill/uia/vision/keyboard/inspect/sequence` подключены, headless-тесты зеленые. `kind=uia` и `kind=vision` используют те же fail-closed gates, что и ядро ЛАПЫ; `kind=keyboard` намеренно возвращает `INCOMPLETE`, пока следующий observe не даст реальное доказательство; `kind=inspect` дает планировщику безопасный способ расширенно перечитать окно перед сменой стратегии. Есть общий recovery-контракт для ошибок `TargetNotFound`, `UiaExecutionFailed`, `FieldIdentityError`, `Unverifiable`, `MissingTargetWindow`, `MissingEvidence`, `KeyboardNavigationNeedsObservation`, `MissingActionApp`, `InvalidUiaSelector`, `InvalidUiaVerb`, `InvalidSequenceAction`. Live smoke 2026-06-25 проведен на задаче смены фона через Windows Settings: частично работает, но задачу до конца не завершил. Live acceptance 2026-06-26 проведен на desktop/browser/messenger/multimodal кейсах; результаты ниже.

Live smoke 2026-06-25, Windows Settings -> Персонализация -> Фон:

- ЛАПА открыла/нашла окно настроек, закрыла внешний TeamViewer popup через canvas click, выбрала `Персонализация`, открыла `Фон`, раскрыла ComboBox `Персонализируйте фон` и выбрала `Сплошной цвет`.
- Финальный swatch был фактически выбран в последнем run15: фон стал сине-бирюзовым/blue-ish, но процесс завис и был остановлен вручную, поэтому корректного `COMPLETED` report не было.
- По итогам smoke добавлены: structured `observation.window_hwnd`, увеличенный UIA node cap до 180, JSON-mode/temperature=0 для Gemini, text-only retry на невалидный planner JSON, mapping `open_app` params `app -> name`, reuse hwnd из `open_app` evidence, wrapper неожиданных UIA/vision exceptions в `ExecutionReport`, нормализация `ListItem/TabItem click -> select` и `ComboBox click -> expand`, enriched failure history с recovery hints, защита от повторения одной и той же неудачной операции и read-only `inspect` для расширенной диагностики UIA.

Live acceptance 2026-06-26:

- `Блокнот`: цель “набрать строку” дошла до `COMPLETED` после фиксов. Найдены и частично закрыты общие проблемы: `type` skill теперь подставляет `field_name=""`, generic action при единственном `allowed_app` автоматически получает `params.app`, а `LapaActionExecutor` выводит целевое окно вперед перед `uia/vision/keyboard`.
- `Google Chrome`: цель “новая вкладка -> https://example.com” дошла до `COMPLETED` после foreground-фикса и prompt-правила, что обычная browser navigation является `low` risk. Остаточный дефект: `New Tab` click остается `Unverifiable`, `Enter` как keyboard action требует последующего observe, финальный proof слабее typed browser verifier.
- `Telegram Desktop`: цель “поиск Избранное без отправки” дошла до `COMPLETED`. Planner восстановился после `AmbiguousTarget` на двух `Edit name='Поиск'` и выбрал `nth=1`. Остаточный дефект: были `FieldIdentityError`/ambiguous steps до рабочего действия.
- `Telegram Saved Messages`, отправка текста + self-verify: no-vision run ожидаемо не справился с custom/sparse Telegram UI (`FieldIdentityError`, `TargetNotFound` на message input). Vision run дошел до `COMPLETED`: UIA `set_text nth=1` ввел сообщение, `keyboard Enter` отправил, затем read-only `vision_verify` подтвердил исходящий текст по screenshot/box/confidence без дополнительного клика. По live-run закрыты две общие дыры: failed diagnostic evidence больше не используется как final proof, а `vision exists/verify` больше не идет через canvas-click.
- `telegram-send-sticker` в `Избранное`: vision нашел sticker tab и candidate sticker, но без confirmation hook корректно остановился fail-closed. После добавления `--confirm-risky` и `--search-timeout` повторный run вернул машинный JSON `INCOMPLETE` вместо зависания/traceback; при полном поиске целевой “smiling happy face sticker” не был подтвержден, стикер не отправлен. Закрыты общие дыры: OS scroll exception больше не роняет CLI, sticker search имеет deadline, CLI оборачивает неожиданные исключения в JSON.
- `Windows Settings -> Personalization -> Background`: no-vision run с UIA/keyboard дошел до `COMPLETED`, несмотря на несколько `NULL COM pointer` при UIA click; planner переключился на keyboard navigation и UIA select. Vision-allowed run смог выбирать swatch через `vision_click` и подтвердить checkmark через `vision_verify`, но ушел в лишние повторные выборы и завершился `INCOMPLETE` по `--wall-timeout`; после этого `vision_click` стал сохранять screenshot proof и prompt дополнен правилом “не выбирать другой вариант после подтвержденного visual change”.
- `Калькулятор`: первоначально цель “2 + 2 = 4” не завершалась (`MaxStepsExceeded`): ЛАПА видела UIA tree и кнопки через `inspect`, но последовательность button clicks возвращала `Unverifiable`, planner путался в состоянии, один шаг `equalButton` дал `TargetNotFound`. После добавления `kind=sequence`, compact sequence parser, action-only JSON fallback и typed `CalculatorResults` postcondition live run стал `COMPLETED`: финальный `equalButton` verified через `postcondition {"uia_text": "Отображать как 4"}`.
- Multimodal `Chrome -> Блокнот`: цель “открыть https://example.com, проверить `Example Domain`, открыть Блокнот и записать `Example Domain page verified`” дошла до `COMPLETED` (`.tmp\multimodal-20260626\chrome-notepad-20260626-042241.out.json`). В процессе закрыты общие дыры: missing `verb` у skill-action, read-only `uia.verify_element -> inspect`, `skill` внутри `sequence`, multi-app observer теперь предпочитает последнее реально открытое приложение, `open_app` очищает лишний inherited context, recoverable executor/perimeter refusals возвращаются planner в историю.
- Multimodal `Calculator -> Блокнот`: расширенный кейс “7 * 8 = 56, затем записать результат” пока не стабилен. Один run вернул `INCOMPLETE` из-за `FieldIdentityError`: UIA нашла кнопки калькулятора, но hit-test попадал в перекрытое окно Блокнота; следующий run ушел за внешний таймаут и был остановлен. После этого добавлены более сильная foreground-активация, повторная foreground-проверка и keyboard fallback hints/keys (`MULTIPLY`, `ADD`, `SUBTRACT`, `DIVIDE`), но нужен отдельный повторный live-run до `COMPLETED`.
- Multimodal `Telegram -> Блокнот`: расширенный кейс “проверить Избранное/Saved Messages, не отправлять, затем записать результат в Блокнот” пока частично успешен: Telegram state был подтвержден через `inspect` по window title `Избранное`, vision смог открыть чат, но workflow тратил шаги на shorthand JSON формы (`verb=inspect`, `verb=open_app`, `verb=skill`) и на `Edit` vs `Document` selector в Блокноте. После этого добавлена нормализация таких shorthand subactions; нужен повторный live-run.

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
- Operator layer: planner loop, real DesktopObserver, Gemini planner seam, `LapaActionExecutor` (`skill/uia/vision/keyboard/inspect/sequence`), CLI `operator-task`, bridge wrapper `operator-task`.
- Operator recovery: failures in history include the failed action, stable action signature and general recovery hint; repeated identical failures are stopped instead of looping forever.
- Read-only diagnostic action: `kind=inspect` can capture/filter a bounded UIA snapshot (`snapshot`, `find`, `exists`) and return structured evidence to the planner without mutating the GUI.
- Single-app perimeter repair: if `allowed_apps` contains exactly one app, generic `uia/vision/keyboard/inspect` actions missing `params.app` are safely filled with that allowed app instead of wasting a planner turn.
- Multi-app context tracking: when several `allowed_apps` are declared, `DesktopObserver` prefers the most recent successful `open_app` target instead of always observing the first allowed app.
- Generic foreground activation: before `uia/vision/keyboard`, `LapaActionExecutor` best-effort restores/brings the target hwnd to foreground via the existing `skills._foreground` seam and retries activation when foreground did not change.
- Typed UIA postconditions for `kind=uia`: planner can declare `params.expected_postcondition` with `kind=uia_text|uia_exists|uia_node|window_title` plus `selector` and `contains/equals/normalized/exists`. ЛАПА builds the reader itself, so JSON planner actions can verify button-click effects such as `CalculatorResults contains "4"` without passing Python callables.
- Bounded workflow action: `kind=sequence` executes up to 20 low-risk `skill/uia/vision/keyboard/inspect` subactions as one workflow. Intermediate low-risk `Unverifiable`/keyboard-observe steps can be tolerated, but the sequence only completes with real final evidence. This is the generic path for calculator/keypad/menu/wizard and multi-app flows.
- Gemini vision/pixel fallback: для custom-drawn UI, перекрытий, sparse UIA tree и визуально проверяемых состояний planner должен использовать `kind=vision` с относительным описанием цели. Сырые координаты от planner не принимаются как контракт; пиксельный locate/click делает сама ЛАПА через Gemini/canvas. `vision_click` теперь сохраняет screenshot proof, а `vision_verify/exists/find/locate` выполняет read-only Gemini locate без клика.
- Effectful action idempotency guard: если planner повторяет уже успешно выполненное state-changing действие с тем же action signature, ЛАПА возвращает recoverable `RepeatedCompletedAction` и не выполняет его повторно. Read-only `inspect` и `vision_verify/exists` можно повторять.
- Safety scan for effectful sequences: `sequence` больше не может спрятать отправку/submit/delete/buy за `set_text + keyboard Enter`; если summary/params effectful action содержит `send/submit/buy/delete/payment/...`, risk floor поднимается до medium/high/critical.
- CLI/runtime hardening: unexpected skill exception теперь возвращается как JSON `ExecutionReport(status=aborted, code=CliCommandCrashed)`, `operator-task` имеет `--wall-timeout`, а `telegram-send-sticker` имеет `--confirm-risky` и `--search-timeout`.
- Planner JSON hardening: action-only responses are treated as `act`; missing skill verbs are inferred for known skills; read-only UIA verification is coerced to `inspect`; compact sequence subactions such as `{selector: ...}`, `verb=skill`, `verb=open_app`, `verb=inspect`, and `kind`-less action shorthand are normalized into full actions.
- Keyboard fallback for keypad workflows: `kind=keyboard` accepts printable digit tokens and keypad operator aliases such as `MULTIPLY`, `ADD`, `SUBTRACT`, `DIVIDE`; planner prompt tells it to switch to keyboard after `FieldIdentityError` on keypad/calculator UIs.
- Final evidence priority: when a task finishes, evidence produced by executed actions is preferred over generic observation screenshots; screenshots are kept as supplemental proof.

## 6. Что частично работает или не готово

- `operator-task` теперь имеет arbitrary UIA/canvas/keyboard executor, read-only `inspect`, read-only `vision_verify/exists`, bounded `sequence`, wall-clock timeout и общий recovery-контур, но его качество на реальном рабочем столе все еще зависит от того, насколько planner увидит корректный UIA selector, сможет выбрать альтернативный selector/verb/tool или даст точное vision-описание.
- “Любые задачи” означает широкий универсальный GUI-оператор в разрешенном периметре, а не снятие safety-ограничений: пароли, 2FA, капчи, платежные credentials, финальный payment/submit покупки или брони и действия без доступа должны останавливаться на человеке.
- Low-risk UIA button clicks без declared observable все еще могут становиться `Unverifiable`; для multi-step workflows planner должен использовать `sequence` и финальный `expected_postcondition`.
- Связь final evidence с конкретными `success_criteria` стала сильнее за счет приоритета action evidence, но еще нет отдельного semantic scorer, который доказывает покрытие каждого success criterion.
- При заданном `allowed_apps` observer не смотрит случайный foreground window: если разрешённое окно не найдено, он возвращает `no target window found`.
- `kind=keyboard` годится только для навигации между наблюдениями; сам по себе он никогда не доказывает завершение задачи.
- Planner/runtime latency remains a real limitation: multi-app tasks can take several minutes because every failed strategy requires another model call and observation. `operator-task --wall-timeout` now stops cleanly between observe/planner/action steps, but it still cannot interrupt an already in-flight Gemini/model call; external wrappers should still keep a process-level timeout/STOP flag.
- Self-learning есть как opt-in Python API, но не включено автоматически в bridge skills.
- Обычный `telegram-send` safety semantics нужно привести к документам: либо явно считать marker авторизацией, либо добавить confirm gate.
- Live desktop acceptance для `operator-task` проведена частично: Settings no-vision flow дошел до `COMPLETED`; Settings vision flow умеет выбирать swatch через canvas/vision, но planner может продолжать выбирать новые варианты вместо finish, поэтому нужен дальнейший live-tuning/semantic success scorer.
- Кириллические app names в отдельных путях PowerShell/Gemini могут превращаться в `?????????`; для live smoke временно использовался foreground-периметр.
- `open_app('Настройки')` может запускать Settings, но live title окна бывает `Параметры`; observer умеет переиспользовать hwnd из `open_app` evidence, однако сам skill `open_app` для уже открытого Settings еще может не дождаться окна по title lookup.
- Medium-risk canvas click без специфического verify остается `Unverifiable`; для визуальных low-risk swatch clicks planner должен явно объявлять `risk=low` или нужен typed verifier для таких настроек.
- Vision/canvas не снимает safety: отправка, покупка, удаление, submit и ввод секретов остаются medium/high/critical даже если цель можно найти пикселями. Для low-risk визуального клика нужен confidence и последующее доказательство через screenshot-diff, screenshot observation, UIA read или typed verifier.
- Gemini planner требует `LAPA_GEMINI_API_KEY` или `GEMINI_API_KEY` либо ключ в `~/.bridge-private/secrets.json`. Без ключа planner честно вернет no decision/incomplete.

## 7. Проверка

Из `C:\Users\rafie\bridge-projects\lapa`:

```powershell
python -m pytest tests/ -q
python -m compileall -q lapa tests conftest.py
```

Текущий результат после complex live/operator/canvas фиксов 2026-06-26:

```text
522 passed, 1 skipped
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

2. Доделать live swatch selection reporting: устойчивый low-risk color-swatch executor/verify, чтобы после выбора цвета run завершался `COMPLETED`, а не зависал до таймаута.
3. Починить title/app-name mismatch для `open_app('Настройки')` -> live window `Параметры` без app-specific хрупкости.
4. Подключить self-learning к operator failure path как opt-in.
5. Исправить/уточнить safety contract обычного `telegram-send`.
6. Добавить semantic success scorer и per-model-call timeout: `--wall-timeout` уже останавливает цикл между шагами, но не доказывает покрытие каждого success criterion и не прерывает уже начатый Gemini call.
