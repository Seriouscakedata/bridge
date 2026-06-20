# Само-размышление: направления улучшения моста

DecisionId: `dec-20260620-032229-2bd892`
Дата: 2026-06-20
Статус: reflection only, без реализации

## Граница вывода

Это не список фиксов и не команда на изменение кода. Я называю направления, где сам себе мешаю в скорости и качестве автономии, и опираюсь на собственные журналы: `audit.log`, `auditor.log`, `audit.launches.jsonl`, `restart-root-cause-log.jsonl`, backlog, shadow-логи и `metrics.jsonl`.

Важная поправка к исходной гипотезе: production `restarts.jsonl` в рабочем дереве не найден; реальные restart-события сейчас живут в `decisions/restart-root-cause-log.jsonl`. Также `auditor.log` не доказывает false-positive findings: его недавние строки в основном `no anomaly` и skip reasons. Шум findings виден в `audit/audit.log`, не в `control/auditor.log`.

## 1. Сделать сбои громкими, а сигналы надежными

Приоритет: highest. Это самый большой риск качества автономии: когда часть системы болит молча, я узнаю поздно; когда сигнал шумный, я трачу время на разгребание или неверно ранжирую риск.

Данные:

- `decisions/restart-root-cause-log.jsonl:2-4` показывает три hard restart подряд по одной задаче с `stamp_reason=missing-stamp`; `:16-18`, `:24-31`, `:32-35`, `:38-43` повторяют тот же класс для других задач. Это не единичная авария, а повторяющийся паттерн позднего/неясного сигнала.
- `metrics.jsonl:258` фиксирует root-задачу: `Start-AuditIfDue` молча не доходил до запуска, потому что вызов был под `try{}catch{}` и исключение глушилось. То есть self-maintenance могла быть сломана без явного runtime-сигнала.
- `audit/audit.log:110-139` показывает один и тот же `runtime-incident-model` warning id `58f4...` много раз подряд; это уже не fail-loud, а signal-noise. `audit/audit.log:196` затем суммирует partial audit с большим deep/backlog выходом.
- `audit/audit.launches.jsonl:1444-1447` показывает, что после hardening появились started и terminal-события (`skipped_not_idle`, `completed_partial`). Это хороший пример окупившегося закаливания существующего ledger вместо нового монитора.

Foundation #2: закалять существующие error contracts, audit ledger и restart attribution; не добавлять новый watcher. Главный принцип: каждый silent catch и каждый повторяющийся finding должны превращаться в один понятный, дедуплицированный сигнал с причиной и владельцем.

## 2. Защитить self-maintenance как обязательную часть автономии

Приоритет: high. Я выполняю пользовательские задачи дисциплинированнее, чем ухаживаю за собственным audit/health контуром. При этом данные не доказывают, что причина именно в queue-preemption: последние skip reasons в `auditor.log` чаще `channel_audit_disabled`, `already_ran_this_window`, `audit_busy`. Поэтому честная формулировка направления: не "очередь всегда съедает аудит", а "self-maintenance не имеет надежного completion contract и может долго выглядеть нормально".

Данные:

- `audit/audit.launches.jsonl:1-20` и `:1418-1443` показывают старую denial-storm форму: repeated `denied max_attempts_per_window` без полезного terminal результата.
- `audit/audit.launches.jsonl:1444-1447` показывает недавний положительный сдвиг: `started` получил terminal `skipped_not_idle`, а следующий run завершился `completed_partial` с `runtime_seconds=129.4`. Это доказывает, что maintenance становится надежнее, когда completion записывается в существующий ledger.
- `control/auditor.log:2297-2300`, `:2304`, `:2308`, `:2321`, `:2329-2331` показывают реальные причины skip в последние часы: disabled external channels, `audit_busy`, `already_ran_this_window`. Это полезные сигналы, но они не равны доказанному "аудит проиграл очереди задач".
- `metrics.jsonl:255-258` показывает, что audit-improve атомы были вынуждены чинить telemetry truncation и root launch failure уже после того, как проблема накопилась до отдельной operator-задачи.

Foundation #2: усилить существующий maintenance ledger и расписание, а не строить второй аудит-аудита. Нужна защищенная гарантия "за период есть terminal health-result или явная причина отсутствия", без превращения в новый параллельный контрольный слой.

## 3. Консолидировать shadow/gate слои и снизить ложные блокировки

Приоритет: high-medium. Я часто добавляю защиты быстрее, чем убираю дубли. Это повышает безопасность локально, но создает много "shadow-only", `acceptance_pending`, held и retry состояний, где система вроде защищена, но путь к DONE становится тяжелым и местами неоднозначным.

Данные:

- `channels/main/delivery-gate-shadow.jsonl:185-189` и `:201-204` показывают повторяющийся shadow-only результат: `merge_allowed=true`, `release_allowed=false`, `risk=high/critical`, `warnings=["acceptance_pending"]`, `note="shadow-only; no DONE/release blocking"`. Это полезно как наблюдение, но пока не всегда load-bearing.
- `channels/main/backlog.jsonl` по текущему подсчету содержит много held/rejected относительно done: команда проверки дала `held=151`, `rejected=316`, `done=260`. Это не значит, что все блокировки ложные, но это доказывает существенную цену контрольных слоев.
- `channels/main/backlog.jsonl:597` держит задачу `8f9b210...` в `held`; строки `:609-611` показывают уже реализованные crusher/gate атомы вокруг decomposed marker/gate; `:615` закрывает E2E. То есть я не только добавляю gates, но уже вынужден добавлять gates для gates.
- `channels/main/depth-shadow.jsonl:17-20` показывает, что routing/depth слой уже различает High-Stakes/Standard/Deep, но это отдельный shadow-сигнал рядом с delivery-gate shadow и backlog gates.

Foundation #2: объединять и продвигать только load-bearing проверки, убирать или понижать шумные shadow-дубли. Цель не "меньше safety", а меньше неоднозначных защит, которые создают friction без ясного terminal эффекта.

## 4. Соразмерять вес pipeline реальному риску

Приоритет: medium. Я медленный не только из-за кода. Большая доля времени уходит на planner/verify/decision synthesis, иногда оправданно, иногда слишком тяжело для ставки задачи. При этом DISCUSS/reflection не должны автоматически считаться low-stakes: текущая задача как раз требует строгой доказательной базы.

Данные:

- `metrics.jsonl:203` для control-plane canary task показывает крупнейшие фазы: `planner_ms=8374834`, `worker_ms=2676520`, `verify_ms=1947987`. Это оправданный тяжелый случай, но он показывает порядок цены.
- `metrics.jsonl:256` для audit telemetry atom показывает более сбалансированную картину: `verify_ms=468740`, `worker_ms=467342`, `planner_ms=458891`.
- `metrics.jsonl:261` для workpack-batch показывает `planner_ms=1937026`, `verify_ms=937434`, `worker_ms=726913`; в этом случае overhead планирования и проверок превышает работу кодера.
- `channels/main/depth-shadow.jsonl:20` классифицирует эту reflection-задачу как `depth=Deep` из-за design/architecture discussion. Это правильный пример: "обсуждение" может быть high-rigor, если оно задает направления улучшения.

Foundation #2: калибровать существующий depth/decision pipeline по измеримым risk signals, а не добавлять новый классификатор. Сигналы должны учитывать blast radius, control-plane, историю failure, требование durable evidence и цену ошибки.

## 5. Сократить context-rebuild и повторный ввод, но только через доказанную экономию

Приоритет: lowest. Это потенциально большой speedup, но самый опасный кандидат на новый механизм. Я не должен плодить "persistent short-term memory", пока не доказал, что существующие state/cache/typed memory не могут дать тот же эффект.

Данные:

- `metrics.jsonl:187`, `:190`, `:203`, `:261` показывают, что `planner_ms` часто является крупнейшей фазой. Это не доказывает напрямую повторное чтение файлов, но доказывает, где искать скорость.
- `metrics.jsonl:191` у deep-think задачи показывает очень тяжелую planner-фазу (`planner_ms=1575624`) и последующий `doctor_event` в `metrics.jsonl:192`; такие длинные рассуждения чувствительны к повторной реконструкции контекста.
- `metrics.jsonl:250-253` показывает stale hypothesis verdict/actuation по старым lapa-гипотезам; это признак, что краткоживущие рабочие выводы стареют и переоцениваются через общий контур, а не через дешевую task-local память.
- `audit/audit.log` не содержит per-file read traces, поэтому я не утверждаю "логи доказали повторное чтение файлов". Для этого нужен отдельный baseline из turn/usage telemetry; без него направление остается последним.

Foundation #2: сначала измерить и использовать существующую typed memory/state/cache. Новый short-term слой допустим только если данные покажут экономию, которую нельзя получить закаливанием уже имеющегося механизма.

## Что реально занимает время

По данным `metrics.jsonl`, крупнейшие фазы в тяжелых задачах - planner и verify, затем worker. `metrics.jsonl:203` и `:261` особенно ясно показывают, что автономная скорость упирается не только в кодинг, а в decision/verification overhead. Часть этого overhead двигает к цели: canary, smoke, qa и audit hardening удерживают мост от самоповреждения. Накладные расходы начинаются там, где shadow/gate слои не дают terminal решения или где decision depth не привязан к реальному риску.

## Что недавно окупилось

Окупилось закаливание существующего audit launch ledger: до этого видна storm/denied история (`audit.launches.jsonl:1-20`, `:1418-1443`), после этого появились terminal-события и completed partial (`:1444-1447`). Окупилась и deep-audit hardening линия: `audit/audit.log:196` уже фиксирует partial result с runtime и backlog output, а recent QA в `channels/main/qa-results.jsonl` показывает PASS для audit atoms 2.1-2.3.

## Что меня тормозит и где я сам себе мешаю

Я слишком легко превращаю каждую обнаруженную слабость в новый слой проверки. Это видно по delivery-gate shadow с постоянным `acceptance_pending`, по held/rejected backlog массе и по crusher/gate задачам вокруг decomposed flow. Правильное направление - не добавить еще один gate, а решить, какие текущие gates реально блокируют опасное, какие остаются shadow-наблюдением, а какие надо слить или удалить.

## Приоритетный итог

1. Fail loud + signal hygiene.
2. Protected self-maintenance completion contract.
3. Consolidate shadow/gate layers.
4. Risk-proportional pipeline weight.
5. Measured context-rebuild reduction through existing memory/state first.

Все пять направлений являются reflection-направлениями. Ни одно не является реализационным планом или командой на patch.
