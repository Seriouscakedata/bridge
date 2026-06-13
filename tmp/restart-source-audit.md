# Restart Source Audit: `control/restart.flag`

Дата аудита: 2026-06-13. Scope: только диагностика; поведение моста не менялось.

## Короткий вывод

Событие в `main`:

```text
2026-06-12T21:07:39 system/event: Перезапуск по запросу (без UAC).
2026-06-12T21:08:03 system/event: hard/untrusted restart: missing-stamp; apply=3/6, hard=3/3, total=6/8.
```

Эта строка не доказывает действие оператора. Ее пишет `supervisor.ps1` при любом найденном `control/restart.flag`:

```text
supervisor.ps1:953: Remove-Item $flagRestart -Force -ErrorAction SilentlyContinue
supervisor.ps1:954: Log "restart flag -> recycle"
supervisor.ps1:955: Add-Message -From system -Text "Перезапуск по запросу (без UAC)." -Kind event | Out-Null
supervisor.ps1:961: Record-CircuitRestart -Detail 'restart.flag recycle' -ReapFired:$false -FlagPresent:$true
```

По `C:\Users\rafie\.bridge-runtime\restarts.jsonl` инцидент выглядит так:

```text
2026-06-12T20:49:51.2411781Z cause=task-survived-3x detail=restart.flag recycle
2026-06-12T21:07:45.2225025Z cause=task-survived-3x detail=restart.flag recycle
```

Вердикт по 21:07: наиболее вероятный источник - отложенный `restart.flag`, возвращенный coalescer'ом (`restart.deferred -> restart.flag`) после self-dev/covered-loop. Это баг для текущей stamp-модели: re-arm может привести к `restart.flag recycle`, но startup затем видит `missing-stamp`. Operator/API и watchdog не выглядят прямым источником именно этого события.

## Идентифицированные армеры и классификаторы

### 1. Operator/API control endpoint

Цитата:

```text
server.ps1:811: $ctl = Join-Path (Get-BridgeRoot) 'control'
server.ps1:812: if (-not (Test-Path $ctl)) { New-Item -ItemType Directory -Path $ctl -Force | Out-Null }
server.ps1:813: Set-Content -LiteralPath (Join-Path $ctl 'restart.flag') -Value '1' -Encoding ASCII
server.ps1:814: [void](Add-Message -From system -Text "♻ Запрошен перезапуск -- супервизор выполнит его без UAC." -Kind event)
```

Триггер: HTTP `POST /api/control` с `action=restart`.

Вердикт: легитимно для операторской команды. Для 2026-06-12 21:07 рядом нет события `♻ Запрошен перезапуск -- ...`, поэтому это не основной кандидат.

### 2. Watchdog recovery

Цитата:

```text
watchdog.ps1:136: function Request-Restart {
watchdog.ps1:137:   Set-Content -LiteralPath (Join-Path $ctl 'restart.flag') -Value '1' -Encoding ascii
watchdog.ps1:138:   Start-ScheduledTask -TaskName 'ClaudeCodexBridge' -ErrorAction SilentlyContinue
```

Условия вызова:

```text
watchdog.ps1:309: Request-Restart
watchdog.ps1:445: Request-Restart
watchdog.ps1:451: Request-Restart
watchdog.ps1:478: Request-Restart
watchdog.ps1:496: Request-Restart
watchdog.ps1:501: Request-Restart
```

Триггеры: storm unhealed после Doctor, API down при живом driver, API stuck после рестарта, stale heartbeat, rollback+restart, повторный restart при smoke OK.

Вердикт: легитимно как recovery rail, но автоматически создает `restart.flag` без `New-ApplyRestartStamp`. Для 21:07 это не главный кандидат: в `restarts.jsonl` стоит `detail=restart.flag recycle`, а в канале нет соседнего watchdog/health-check сообщения прямо перед 21:07.

### 3. Driver restart coalescer: defer/apply

Defer-цитаты:

```text
lib/agent-wait.ps1:44: # Recycle coalescer (mid-turn): if a self-dev restart.flag appears while an
lib/agent-wait.ps1:50: if (Test-Path -LiteralPath $rcF) {
lib/agent-wait.ps1:51:   Move-Item -LiteralPath $rcF -Destination (Join-Path $rcCtl 'restart.deferred') -Force
```

```text
driver/80-loop-preflight.ps1:88: if ((Test-Path -LiteralPath $rcFlag) -and ($rcBusy -or $rcDeepThinkActive -or $rcCompletionFinalizing)) {
driver/80-loop-preflight.ps1:96:   Set-Content -LiteralPath $rcDefer -Value ((Get-Date).ToUniversalTime().ToString('o')) -Encoding ASCII
driver/80-loop-preflight.ps1:97:   Remove-Item -LiteralPath $rcFlag -Force
```

Re-arm-цитата:

```text
driver/80-loop-preflight.ps1:397: param([string]$Reason, [string]$Message)
driver/80-loop-preflight.ps1:399:   Move-Item -LiteralPath $DeferredPath -Destination $FlagPath -Force
driver/80-loop-preflight.ps1:401:   $result.action = 'apply'
```

Триггер: `restart.flag` появился во время busy/deep-think/completion-finalizing; driver переносит его в `restart.deferred`, а позже возвращает в `restart.flag` по idle/backstop/failsafe условиям.

Вердикт: баг для stamp-модели. `restart.deferred` хранит время defer, но не provenance/apply-stamp. Поздний re-arm может дать supervisor валидный флаг без актуального stamp, что совпадает с `hard/untrusted restart: missing-stamp` в 21:08.

### 4. Background `jobs/*.cmd`

Примеры найденных runtime job-файлов:

```text
jobs/8d6c9219.cmd:1: ... New-ApplyRestartStamp ...; New-Item -ItemType File -Path .\control\restart.flag -Force ...
jobs/fff82eb5.cmd:1: ... New-ApplyRestartStamp ...; Set-Content -LiteralPath .\control\restart.flag ...
jobs/822afe97.cmd:1: ... if($changed -match '\.ps1$'){ New-Item -ItemType File -Path (Join-Path $root 'control\restart.flag') -Force ...
jobs/519c1901.cmd:1: ... if($changed -match '\.ps1$'){ New-Item -ItemType File -Path (Join-Path $root 'control\restart.flag') -Force ...
jobs/992ae746.cmd:1: ... commit -m 'fix(workpack): harden dispatcher smoke closures'; New-Item -ItemType File -Path control/restart.flag -Force ...
jobs/b045d1d6.cmd:1: ... commit -m 'fix(gate-regression): scope snapshot suite by changed paths'; ... New-Item -ItemType File -Path ... 'control\restart.flag' ...
```

Триггер: фоновые helper/job-команды после commit/verify `.ps1` diff.

Вердикт: смешанный. Jobs с `New-ApplyRestartStamp` перед флагом легитимны. Legacy jobs без stamp - баг/legacy-risk: они могут создавать `restart.flag` после `.ps1` commit без evidence. По текущим логам они не выглядят прямым 21:07 источником, но это отдельный автоматический армер.

### 5. Circuit-breaker

Цитата:

```text
lib/circuit-breaker.ps1:193: } elseif ($StateAttempts -ge 3) {
lib/circuit-breaker.ps1:194:   $class = 'task-survived-3x'
lib/circuit-breaker.ps1:196: } elseif ($FlagPresent) {
lib/circuit-breaker.ps1:197:   $class = 'explicit-flag'
lib/circuit-breaker.ps1:198:   $key = 'restart.flag'
lib/circuit-breaker.ps1:545: $cause = Get-RestartCause ... -FlagPresent:$FlagPresent ...
lib/circuit-breaker.ps1:546: $out.event = Write-RestartEvent -Cause $cause.class -Signature $cause.signature -Detail $Detail
```

Триггер: `supervisor.ps1` вызывает `Record-CircuitRestart`; circuit-breaker классифицирует и пишет restart-event.

Вердикт: не армер. Он не создает `restart.flag`; он только атрибутирует событие. Важная деталь: `StateAttempts >= 3` имеет приоритет над `FlagPresent`, поэтому `detail=restart.flag recycle` может получить `cause=task-survived-3x`. Это ровно видно в 21:07.

## Сверка последних суток

Журнал: `C:\Users\rafie\.bridge-runtime\restarts.jsonl`.

Окно `2026-06-12T17:00:00Z` - `2026-06-13T05:00:00Z`:

```text
explicit-flag 8
task-survived-3x 9
```

События вокруг инцидента:

```text
2026-06-12T18:48:03.8452567Z cause=task-survived-3x detail=driver[main] unresponsive (CPU-stagnation health-check)
2026-06-12T18:58:20.7567418Z cause=task-survived-3x detail=driver[main] unresponsive (CPU-stagnation health-check)
2026-06-12T19:11:43.1674270Z cause=task-survived-3x detail=driver[main] unresponsive (CPU-stagnation health-check)
2026-06-12T19:33:18.7957006Z cause=task-survived-3x detail=restart.flag recycle
2026-06-12T19:48:17.1867972Z cause=explicit-flag detail=restart.flag recycle
2026-06-12T20:27:33.4928413Z cause=explicit-flag detail=restart.flag recycle
2026-06-12T20:34:33.3214325Z cause=task-survived-3x detail=restart.flag recycle
2026-06-12T20:49:51.2411781Z cause=task-survived-3x detail=restart.flag recycle
2026-06-12T21:07:45.2225025Z cause=task-survived-3x detail=restart.flag recycle
```

Канал `main` вокруг 21:07:

```text
2026-06-12T20:49:44 system/event: Перезапуск по запросу (без UAC).
2026-06-12T20:50:07 system/event: hard/untrusted restart: missing-stamp; apply=3/6, hard=2/3, total=5/8.
2026-06-12T20:53:51 system/event: Gate-check Codex: commit 573adb6
2026-06-12T21:07:39 system/event: Перезапуск по запросу (без UAC).
2026-06-12T21:08:03 system/event: hard/untrusted restart: missing-stamp; apply=3/6, hard=3/3, total=6/8.
```

## Follow-up atom candidate

Отдельным fix-атомом: сохранить provenance/apply-stamp рядом с `restart.deferred` или запретить apply deferred restart без валидного, непросроченного stamp. Дополнительно удалить/перегенерировать legacy `jobs/*.cmd`, которые создают `restart.flag` без `New-ApplyRestartStamp`.
