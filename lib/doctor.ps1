# doctor.ps1 -- the bridge auto-repair agent ("Doctor").
# When a task hits a hard failure (planner-timeout-exhausted, watchdog rollback, etc.),
# Doctor holds the original task, diagnoses the root cause, writes a minimal fix, verifies
# it, commits it, then resumes the original task -- without operator intervention. The
# Doctor uses the normal planner->coder->critic pipeline (mode='doctor' changes the prompt).
#
# State fields owned by Doctor (initialized in Initialize-Bridge):
#   held_task          -- text of the original task being suspended
#   doctor_active          -- bool, Doctor is currently triaging/fixing
#   doctor_repair_attempts -- repair attempts seeded for the held task
#   doctor_restart_count   -- driver restarts while Doctor is active (restart-loop guard)
#   doctor_attempts        -- legacy alias, mirrors doctor_repair_attempts
#   doctor_reason          -- short reason string (planner_timeout, watchdog_rollback, ...)
#   doctor_started_at      -- ISO timestamp the Doctor activated

function Get-DoctorConfigInt {
  param([string]$Name, [int]$Default, [int]$Min = 1, [int]$Max = 10)
  $value = $Default
  try {
    $cfg = Get-BridgeConfig
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'doctor') -and $cfg.doctor) {
      $node = $cfg.doctor
      if (($node.PSObject.Properties.Name -contains $Name) -and $null -ne $node.$Name) {
        $value = [int]$node.$Name
      }
    }
  } catch {}
  if ($value -lt $Min) { return $Min }
  if ($value -gt $Max) { return $Max }
  return [int]$value
}

function Get-DoctorMaxRepairAttempts {
  return (Get-DoctorConfigInt -Name 'maxRepairAttempts' -Default 3 -Min 1 -Max 5)
}

function Get-DoctorMaxRestartResumes {
  return (Get-DoctorConfigInt -Name 'maxRestartResumes' -Default 3 -Min 2 -Max 10)
}

function Get-DoctorMaxAttempts {
  # Backward-compatible wrapper for older call sites/tests.
  return (Get-DoctorMaxRepairAttempts)
}

function Get-DoctorStateInt {
  param($State, [string[]]$Names, [int]$Default = 0)
  if (-not $State) { return $Default }
  foreach ($name in @($Names)) {
    try {
      if (($State.PSObject.Properties.Name -contains $name) -and $null -ne $State.$name) {
        return [int]$State.$name
      }
    } catch {}
  }
  return $Default
}

function Get-DoctorRepairAttemptCount {
  param($State)
  $repair = Get-DoctorStateInt -State $State -Names @('doctor_repair_attempts') -Default 0
  $legacy = Get-DoctorStateInt -State $State -Names @('doctor_attempts') -Default 0
  return [Math]::Max([int]$repair, [int]$legacy)
}

function Get-DoctorRestartCount {
  param($State)
  return (Get-DoctorStateInt -State $State -Names @('doctor_restart_count') -Default 0)
}

function Write-DoctorLog {
  param([string]$Message)
  try {
    $path = Join-Path (Get-BridgeRoot) 'control\doctor.log'
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ([string]$Message)
    Add-Content -LiteralPath $path -Value $line -Encoding UTF8
  } catch {}
}

function Activate-Doctor {
  # Called by the driver when a hard failure is detected. Suspends the current task into
  # held_task, flags Doctor active, leaves current_task null so the next loop iteration
  # picks up the Doctor task.
  param([string]$Reason, [string]$Detail = '')
  $st = Read-State
  $cur = [string]$st.current_task
  $already = [bool]$st.doctor_active
  if ($already) {
    # Doctor failure or recursion -- don't double-activate
    try { Add-Message -From system -Text ("🩺 Доктор уже активен; повторного вызова не делаю. Reason: " + $Reason) -Kind event | Out-Null } catch {}
    return $false
  }
  $now = (Get-Date).ToString('o')
  try { Save-StateSnapshot -Reason 'doctor_activate' } catch {}
  Update-State ({ param($s)
    $s.held_task         = $cur
    $s.doctor_active     = $true
    $s | Add-Member -NotePropertyName doctor_repair_attempts -NotePropertyValue 0 -Force
    $s | Add-Member -NotePropertyName doctor_restart_count -NotePropertyValue 0 -Force
    $s.doctor_attempts   = 0
    $s.doctor_reason     = $Reason
    $s.doctor_started_at = $now
    $s.current_task      = $null
    $s.task_turn         = 0
    $s.task_mode         = 'normal'
    $s.no_progress_count = 0
    $s.timeout_retry_count = 0
    $s.task_did_actions  = $false
    $s.coder_fired       = $false
    $s.coder_bypass_retry_count = 0
    $s.verify_retry_count = 0
    $s.critic_retry_count = 0
    $s.force_planner     = $false
    Clear-AuditorSuppressedHashes -State $s
    $s.active_agent = $null; $s.active_model = $null; $s.status_text = $null
  }.GetNewClosure()) | Out-Null
  $snippet = $cur
  if ($snippet.Length -gt 80) { $snippet = $snippet.Substring(0,80) + '...' }
  $detailMsg = if ([string]::IsNullOrWhiteSpace($Detail)) { '' } else { " — $Detail" }
  try { Add-Message -From system -Text ("🩺 Доктор активирован: " + $Reason + $detailMsg + ". Задача приостановлена: «" + $snippet + "». Диагностика и фикс пойдут отдельной задачей.") -Kind event | Out-Null } catch {}
  try { Append-DoctorEvent -Event 'activate' -Reason $Reason } catch {}
  try { Write-DoctorLog ("Doctor activate: " + $Reason) } catch {}
  return $true
}

function Get-DoctorContext {
  # Compact diagnostic dump for the Doctor prompt: recent system events (last 15), watchdog
  # log tail, supervisor log tail, git log (last 5), git status. Strings only -- no ETS.
  $root = Get-BridgeRoot
  $sb = New-Object System.Text.StringBuilder
  # Recent system events
  try {
    $msgs = @(Get-Messages -Since 0) | Where-Object { $_.from -eq 'system' } | Select-Object -Last 15
    [void]$sb.AppendLine("=== Recent system events (last 15) ===")
    foreach ($m in $msgs) {
      $t = [string]$m.text
      if ($t.Length -gt 220) { $t = $t.Substring(0,220) + '...' }
      [void]$sb.AppendLine("[seq $($m.seq)] $t")
    }
  } catch {}
  # Watchdog log tail
  try {
    $wd = Join-Path $root 'control\watchdog.log'
    if (Test-Path $wd) {
      [void]$sb.AppendLine(""); [void]$sb.AppendLine("=== watchdog.log (tail 10) ===")
      $tail = [System.IO.File]::ReadAllLines($wd) | Select-Object -Last 10
      foreach ($l in $tail) { [void]$sb.AppendLine($l) }
    }
  } catch {}
  # Supervisor log tail
  try {
    $sup = Join-Path $root 'control\supervisor.log'
    if (Test-Path $sup) {
      [void]$sb.AppendLine(""); [void]$sb.AppendLine("=== supervisor.log (tail 10) ===")
      $tail = [System.IO.File]::ReadAllLines($sup) | Select-Object -Last 10
      foreach ($l in $tail) { [void]$sb.AppendLine($l) }
    }
  } catch {}
  # Git log + status
  try {
    $git = 'C:\Program Files\Git\cmd\git.exe'
    if (Test-Path $git) {
      $logOut = & $git -C $root log --oneline -6 2>$null
      [void]$sb.AppendLine(""); [void]$sb.AppendLine("=== git log -6 ===")
      foreach ($l in @($logOut)) { [void]$sb.AppendLine([string]$l) }
      $statOut = & $git -C $root status --short 2>$null
      [void]$sb.AppendLine(""); [void]$sb.AppendLine("=== git status --short ===")
      foreach ($l in @($statOut)) { [void]$sb.AppendLine([string]$l) }
    }
  } catch {}
  return $sb.ToString()
}

function Get-DoctorTaskText {
  # Compose the "task" the Doctor sees as its current_task. This is plugged into the normal
  # planner->coder pipeline; mode='doctor' tells Build-Prompt to use a special intro.
  $st = Read-State
  $held = [string]$st.held_task
  $reason = [string]$st.doctor_reason
  $maxRepair = Get-DoctorMaxRepairAttempts
  $nextAttempt = (Get-DoctorRepairAttemptCount -State $st) + 1
  if ($nextAttempt -gt $maxRepair) { $nextAttempt = $maxRepair }
  $heldShort = $held; if ($heldShort.Length -gt 400) { $heldShort = $heldShort.Substring(0,400) + '...[truncated]' }
  $ctx = Get-DoctorContext
  return @"
🩺 ДОКТОР — задача саморемонта моста.

ПРИЧИНА ВЫЗОВА: $reason

ПОПЫТКА ДОКТОРА: $nextAttempt/$maxRepair

ПРИОСТАНОВЛЕННАЯ ЗАДАЧА (восстановим после фикса; не выполняй её саму!):
---
$heldShort
---

ДИАГНОСТИЧЕСКИЙ КОНТЕКСТ:
$ctx

ЧТО ОТ ТЕБЯ НУЖНО:
1) Диагноз: одним абзацем — какой корневой причиной задача упала. Сошлись на конкретные строки логов / commit / state-поля.
2) Минимальный фикс: только то, что устранит первопричину. НЕ переделывай систему, НЕ оптимизируй смежные модули.
3) Реализация через STATUS: CONTINUE → Codex (multi-agent дисциплина: правки кода идут через кодера).
4) Верификация: smoke OK + конкретная проверка, что то самое больше не падает (например, если был planner_timeout — кэп в конфиге/коде увеличен; если ETS-OOM — sanitize применён).
5) Коммит с префиксом `repair(<область>):` и в теле описание корня + фикса.
6) STATUS: DONE с [[VERIFIED: ...]]. После твоего DONE я (driver) автоматически восстановлю приостановленную задачу.

ОГРАНИЧЕНИЯ (строго):
- НЕ трогать `watchdog.ps1`, `supervisor.ps1`, `.git/*`, `secrets.json`, `auth.json`.
- НЕ трогать структуру state-полей.
- Если корень требует ручного решения оператора (повреждение данных, потеря секретов) — STATUS: DONE с маркером `[[ESCALATE: оператор]]` и кратким описанием; я уведомлю пользователя.
- Maximum $maxRepair repair-попыток; если не справишься за лимит, я эскалирую оператору.

Начинай.
"@
}

function Complete-Doctor {
  # Called when Doctor reports STATUS: DONE successfully. Restore the held task as the new
  # current_task with mode='normal' and fresh counters; clear Doctor state.
  $st = Read-State
  $held = [string]$st.held_task
  if ([string]::IsNullOrWhiteSpace($held)) {
    try { Add-Message -From system -Text "🩺 Доктор завершил, но held_task пуст — нечего возобновлять. Возвращаюсь в idle." -Kind event | Out-Null } catch {}
    # FIX 2026-05-26: clear current_task and counters too, else the loop keeps running the
    # doctor diagnostic prompt as a normal task (caught on first wiring test).
    Update-State ({ param($s)
      $s.doctor_active=$false; $s.held_task=$null; $s.doctor_reason=''; $s.doctor_started_at=$null; $s.doctor_attempts=0
      $s | Add-Member -NotePropertyName doctor_repair_attempts -NotePropertyValue 0 -Force
      $s | Add-Member -NotePropertyName doctor_restart_count -NotePropertyValue 0 -Force
      $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'
      $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false
      $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.critic_retry_count=0
      $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''
      $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0
      Clear-AuditorSuppressedHashes -State $s
      $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null
      $s.status='idle'
    }.GetNewClosure()) | Out-Null
    return
  }
  Update-State ({ param($s)
    $s.current_task         = $held
    $s.held_task            = $null
    $s.doctor_active        = $false
    $s.doctor_reason        = ''
    $s.doctor_started_at    = $null
    $s.doctor_attempts      = 0
    $s | Add-Member -NotePropertyName doctor_repair_attempts -NotePropertyValue 0 -Force
    $s | Add-Member -NotePropertyName doctor_restart_count -NotePropertyValue 0 -Force
    $s.task_turn            = 0
    $s.task_mode            = 'normal'
    $s.no_progress_count    = 0
    $s.timeout_retry_count  = 0
    $s.task_did_actions     = $false
    $s.coder_fired          = $false
    $s.coder_bypass_retry_count = 0
    $s.verify_retry_count   = 0
    $s.critic_retry_count   = 0
    $s.force_planner        = $false
    Clear-AuditorSuppressedHashes -State $s
  }.GetNewClosure()) | Out-Null
  $snippet = $held; if ($snippet.Length -gt 80) { $snippet = $snippet.Substring(0,80) + '...' }
  try { Add-Message -From system -Text ("🩺 Доктор закончил — фикс применён и проверен. Возобновляю приостановленную задачу: «" + $snippet + "».") -Kind event | Out-Null } catch {}
  try { Append-DoctorEvent -Event 'complete' } catch {}
  try { Write-DoctorLog "Doctor complete: repaired" } catch {}
}

function Abort-Doctor {
  # Called when Doctor attempts are exhausted or Doctor itself fails. Keep held_task in
  # state (operator decides what to do); clear active/attempts so loop won't retry.
  param([string]$Reason = 'attempts exhausted')
  Update-State {
    param($s)
    $s.doctor_active=$false; $s.doctor_attempts=0; $s.doctor_reason=''; $s.doctor_started_at=$null
    $s | Add-Member -NotePropertyName doctor_repair_attempts -NotePropertyValue 0 -Force
    $s | Add-Member -NotePropertyName doctor_restart_count -NotePropertyValue 0 -Force
    $s.current_task=$null; $s.task_turn=0; Clear-AuditorSuppressedHashes -State $s
  } | Out-Null
  try { Add-Message -From system -Text ("🩺 Доктор не справился (" + $Reason + "). Held-task сохранён в state. Жду оператора.") -Kind event | Out-Null } catch {}
  try { Send-PushEvent -Kind need_you -Text "Doctor failed: $Reason" } catch {}
  try { Append-DoctorEvent -Event 'abort' -Reason $Reason } catch {}
  try { Write-DoctorLog ("Doctor abort: " + $Reason) } catch {}
}

function Test-RestartLoop {
  # Detect "many restarts in a short window with no successful turn" — symptom of a stall the
  # current trigger set (timeout/rollback) misses. User reported 2026-05-26: bridge restarted
  # 4 times in 4 min while Doctor stayed silent. Returns reason string if triggered, else $null.
  #
  # FIX 2026-05-26: previously [datetime]$m.ts (where $m.ts ends in "Z") returned a LOCAL
  # DateTime in PowerShell (the cast auto-converts UTC->Local and sets Kind=Local). The
  # resulting comparison against a UTC cutoff used raw ticks, so a UTC timestamp from hours
  # ago was treated as "recent" by the timezone-offset amount. Result: every historical
  # restart event passed the cutoff filter forever → Doctor false-positive on every fresh
  # boot. Fix: ((Get-Date $m.ts).ToUniversalTime()) normalizes back to UTC for the compare.
  param([int]$WindowMinutes = 5, [int]$RestartThreshold = 3)
  $root = Get-BridgeRoot
  $cutoff = (Get-Date).AddMinutes(-[Math]::Abs($WindowMinutes)).ToUniversalTime()
  # 1) count "Перезапуск по запросу" system events in conversation.jsonl since cutoff
  $restarts = 0
  try {
    $msgs = @(Get-Messages -Since 0) | Where-Object { $_.from -eq 'system' -and ([string]$_.text) -match 'Перезапуск по запросу' }
    foreach ($m in $msgs) {
      try { if (([datetime]$m.ts).ToUniversalTime() -ge $cutoff) { $restarts++ } } catch {}
    }
  } catch {}
  if ($restarts -lt $RestartThreshold) { return $null }
  # 2) check turns.jsonl: was there ANY ok turn in the same window? If yes, restarts are
  #    just self-test recycles (legitimate) — don't fire Doctor.
  $okTurns = 0
  try {
    $tp = Join-Path $root 'turns.jsonl'
    if (Test-Path $tp) {
      foreach ($line in [System.IO.File]::ReadAllLines($tp, [System.Text.Encoding]::UTF8) | Select-Object -Last 50) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $r = $line | ConvertFrom-Json } catch { continue }
        try { if (([datetime]$r.ts).ToUniversalTime() -ge $cutoff -and [string]$r.status -eq 'ok') { $okTurns++ } } catch {}
      }
    }
  } catch {}
  if ($okTurns -ge 1) { return $null }   # there IS progress, restarts are self-tests
  return "restart_loop_no_progress (${restarts} restarts/${WindowMinutes}min, 0 ok-turns)"
}

function Test-DoctorSignal {
  # Watchdog leaves control/repair.signal after a rollback. We pick it up on the next loop
  # iteration, activate Doctor, and consume the signal. File contains a short reason string.
  $sig = Join-Path (Get-BridgeRoot) 'control\repair.signal'
  if (-not (Test-Path $sig)) { return $null }
  $reason = 'watchdog_rollback'
  try { $txt = [System.IO.File]::ReadAllText($sig); if ($txt) { $reason = $txt.Trim() } } catch {}
  try { Remove-Item -LiteralPath $sig -Force -ErrorAction SilentlyContinue } catch {}
  return $reason
}

function Invoke-FailedTaskSalvage {
  # Called right after a task is marked FAILED (restart-loop bail-out). The bridge often leaves a
  # VALID working tail behind — the task died on process/orchestration, not on the code. Real case:
  # the 2026-05-31 StopReason storm left a sound fix (smoke green) sitting UNCOMMITTED, which blocks
  # the dirty-tree guard and risks loss on a watchdog rollback; the operator had to commit it by hand.
  # This automates that judgment so no human is needed to pick up the tail:
  #   parse-clean tail  -> auto-commit (tree clean again, autonomy unblocked)
  #   parse-broken tail -> `git stash` of ONLY those files (reversible) + page the operator
  # Gate is PARSE, not smoke: this runs at driver boot when endpoints may not be up yet, so a red
  # smoke would be ambiguous. smoke is captured as an advisory signal. Never destroys work, and
  # never touches runtime/state files (so it can't undo the failed-cleanup that just ran).
  param([string]$TaskText = '', [string]$BacklogId = '')
  $root = Get-BridgeRoot
  $result = @{ action = 'none' }

  # 1) Collect dirty CODE files (reuse the driver auto-commit runtime-exclusion set).
  $files = @()
  try {
    foreach ($d in @(& git -C $root status --porcelain 2>$null)) {
      $l = [string]$d; if ($l.Length -le 3) { continue }
      $nm = $l.Substring(3).Trim()
      if ($nm -match ' -> ') { $nm = ($nm -split ' -> ', 2)[1].Trim() }
      $nm = $nm.Trim('"'); if ([string]::IsNullOrWhiteSpace($nm)) { continue }
      # Exclude ALL runtime/state churn (whole dirs, so a wholly-untracked dir like 'channels/'
      # is caught too). features/state.json is excluded but features/registry.json (code data) is not.
      if ($nm -match '^(decisions/.*|turns\.jsonl|channels/.*|features/state\.json|control/.*|audit/.*|logs/.*|radar/.*|jobs/.*|sandbox/.*|replay/.*|reports/.*|memory/.*)$') { continue }
      $files += $nm
    }
  } catch {}
  if ($files.Count -eq 0) { return $result }   # clean, or runtime-only churn — nothing to salvage

  $taskShort = ([string]$TaskText -replace '\s+', ' ').Trim()
  if ($taskShort.Length -gt 100) { $taskShort = $taskShort.Substring(0,100) + '…' }

  # 2) GATE: every changed .ps1 must parse (boot-safe, deterministic).
  $parseBad = @()
  foreach ($f in $files) {
    if ($f -notmatch '\.ps1$') { continue }
    $full = Join-Path $root $f
    if (-not (Test-Path -LiteralPath $full)) { continue }   # deleted file is fine
    $errs = $null; $toks = $null
    try { [void][System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$toks, [ref]$errs) } catch {}
    if ($errs -and $errs.Count -gt 0) { $parseBad += ($f + ' (' + $errs.Count + ' err)') }
  }

  # 2b) Advisory smoke (signal only — not a gate).
  $smokeOk = $true; $smokeTail = '(skipped)'
  if ($parseBad.Count -eq 0) {
    try {
      $smokeScript = Join-Path $root 'smoke.ps1'
      if (Test-Path $smokeScript) {
        $out = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $smokeScript 2>&1
        $smokeOk = ($LASTEXITCODE -eq 0)
        $smokeTail = (@($out) | Select-Object -Last 1) -join ' '
      }
    } catch { $smokeOk = $false; $smokeTail = $_.Exception.Message }
  }

  if ($parseBad.Count -eq 0) {
    # 3a) VALID tail -> commit it.
    try {
      $msg = '[salvage] спасён хвост failed-задачи: ' + $taskShort + $(if ($smokeOk) { ' (parse+smoke OK)' } else { ' (parse OK; smoke red — see note)' })
      if ($msg.Length -gt 180) { $msg = $msg.Substring(0,180) }
      & git -C $root add -- @($files) 2>$null | Out-Null
      & git -C $root commit -m $msg 2>$null | Out-Null
      $head = (& git -C $root rev-parse --short HEAD 2>$null); if ($head) { $head = ([string]$head).Trim() }
      try { Invoke-AutoPush -Root $root } catch {}
      try { Write-DoctorLog ("salvage COMMIT " + $head + " (" + $files.Count + " files, smokeOk=" + $smokeOk + "): " + $taskShort) } catch {}
      $warn = if ($smokeOk) { '' } else { (' ⚠ smoke красный (' + $smokeTail + ') — код синтаксически валиден, но проверь; сентинел подстрахует.') }
      try { Add-Message -From system -Text ('💾 Спасён хвост failed-задачи — авто-коммит ' + $head + ' (' + $files.Count + ' файлов, parse OK). Дерево чистое, автономия разблокирована.' + $warn) -Kind event | Out-Null } catch {}
      if (-not $smokeOk) { try { Send-PushEvent -Kind need_you -Text ('salvage committed but smoke red: ' + $smokeTail) } catch {} }
      $result = @{ action='committed'; head=$head; files=$files.Count; smokeOk=$smokeOk }
    } catch { try { Write-DoctorLog ('salvage commit error: ' + $_.Exception.Message) } catch {} }
  } else {
    # 3b) BROKEN tail -> reversibly stash ONLY those files; page operator.
    $why = 'parse: ' + (($parseBad | Select-Object -First 3) -join ', ')
    try {
      $stashMsg = 'salvage-invalid: ' + $taskShort + ' | ' + $why
      if ($stashMsg.Length -gt 160) { $stashMsg = $stashMsg.Substring(0,160) }
      & git -C $root stash push -u -m $stashMsg -- @($files) 2>$null | Out-Null
      try { Write-DoctorLog ('salvage STASH invalid tail (' + $why + '): ' + $taskShort) } catch {}
      try { Add-Message -From system -Text ('📦 Хвост failed-задачи не парсится (' + $why + ') — спрятал эти файлы в git stash (обратимо: `git stash pop`), дерево очищено. Нужен ты для разбора.') -Kind event | Out-Null } catch {}
      try { Send-PushEvent -Kind need_you -Text ('salvage: invalid tail stashed — ' + $why) } catch {}
      $result = @{ action='stashed'; why=$why }
    } catch { try { Write-DoctorLog ('salvage stash error: ' + $_.Exception.Message) } catch {} }
  }
  return $result
}
