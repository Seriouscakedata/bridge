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
#   doctor_repair_task_id  -- stable owner of doctor_repair_attempts
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

function Test-DoctorCommitFamineReason {
  param([string]$Reason)
  return (([string]$Reason).Trim().ToLowerInvariant() -match '(^|:)commit_famine$')
}

function Test-DoctorHeldReadyCloseReason {
  param([string]$Reason)
  $r = ([string]$Reason).Trim().ToLowerInvariant()
  return ($r -match '(^|:)commit_famine$' -or $r -match '(^|:)same_task_too_long$')
}

function Invoke-DoctorCriticPingPongAutoCommit {
  # Fast-path: when Doctor is triggered by critic_pingpong, check for uncommitted working-tree
  # changes. If found and all .ps1 files pass ParseFile, commit them and resolve Doctor without
  # launching Codex. Returns $true if auto-commit succeeded and Doctor state was cleared.
  param([object]$State)
  $reason = [string]$State.doctor_reason
  if ($reason -notmatch 'critic_pingpong') { return $false }
  $root = Get-BridgeRoot
  $git = 'C:\Program Files\Git\cmd\git.exe'
  if (-not (Test-Path $git)) { return $false }
  $diffFiles = @()
  try {
    $tracked   = @(& $git -C $root diff HEAD --name-only 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $untracked = @(& $git -C $root ls-files --others --exclude-standard 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $diffFiles = @($tracked) + @($untracked) | Select-Object -Unique | Where-Object { $_ }
  } catch { $diffFiles = @() }
  if ($diffFiles.Count -eq 0) { return $false }
  $ps1Files = @($diffFiles | Where-Object { [string]$_ -match '\.ps1$' })
  foreach ($rel in $ps1Files) {
    $full = Join-Path $root $rel
    if (-not (Test-Path $full)) { continue }
    try {
      $t = $null; $e = $null
      [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$t, [ref]$e) | Out-Null
      if ($e -and $e.Count -gt 0) {
        try { Add-Message -From system -Text ("🩺 critic_pingpong auto-commit: ParseFile fail in $rel — falling back to normal repair.") -Kind event | Out-Null } catch {}
        try { Write-DoctorLog ("critic_pingpong auto-commit: ParseFile error in $rel; abort") } catch {}
        return $false
      }
    } catch { return $false }
  }
  try {
    & $git -C $root add -A 2>$null | Out-Null
    $msg = "repair(uncommitted-diff): doctor auto-commit on critic_pingpong ($($diffFiles.Count) files)"
    & $git -C $root commit -m $msg 2>$null | Out-Null
    $newHead = ([string](& $git -C $root rev-parse --short HEAD 2>$null)).Trim()
    try { Add-Message -From system -Text ("🩺 Доктор (critic_pingpong): uncommitted diff обнаружен и закоммичен ($newHead, $($diffFiles.Count) файлов). Возобновляю задачу без Codex.") -Kind event | Out-Null } catch {}
    try { Write-DoctorLog ("critic_pingpong auto-commit OK: $newHead, files=$($diffFiles.Count)") } catch {}
  } catch {
    try { Write-DoctorLog ("critic_pingpong auto-commit: git error: " + $_.Exception.Message) } catch {}
    return $false
  }
  try { Complete-Doctor } catch {}
  return $true
}

function Get-DoctorStateText {
  param($State, [string[]]$Names, [string]$Default = '')
  if (-not $State) { return $Default }
  foreach ($name in @($Names)) {
    try {
      if (($State.PSObject.Properties.Name -contains $name) -and $null -ne $State.$name) {
        $value = ([string]$State.$name).Trim()
        if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
      }
    } catch {}
  }
  return $Default
}

function Get-DoctorStableTextHash {
  param([string]$Text)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0,16)
  } finally {
    try { $sha.Dispose() } catch {}
  }
}

function Get-DoctorHeldBacklogId {
  param($State)
  return (Get-DoctorStateText -State $State -Names @('current_backlog_id','current_task_id') -Default '')
}

function Get-DoctorRepairTaskId {
  param($State)
  $id = Get-DoctorHeldBacklogId -State $State
  if (-not [string]::IsNullOrWhiteSpace($id)) { return ('backlog:' + $id) }
  $taskId = Get-DoctorStateText -State $State -Names @('task_id') -Default ''
  if (-not [string]::IsNullOrWhiteSpace($taskId)) { return ('task:' + $taskId) }
  $held = Get-DoctorStateText -State $State -Names @('held_task') -Default ''
  if (-not [string]::IsNullOrWhiteSpace($held)) { return ('held-hash:' + (Get-DoctorStableTextHash -Text $held)) }
  return ''
}

function Sync-DoctorRepairCounterOwner {
  param($State)
  if (-not $State) { return $State }
  $owner = Get-DoctorRepairTaskId -State $State
  if ([string]::IsNullOrWhiteSpace($owner)) { return $State }
  $stored = Get-DoctorStateText -State $State -Names @('doctor_repair_task_id') -Default ''
  if ($stored -eq $owner) { return $State }
  Update-State ({
    param($s)
    $s | Add-Member -NotePropertyName doctor_repair_task_id -NotePropertyValue $owner -Force
    $s | Add-Member -NotePropertyName doctor_repair_attempts -NotePropertyValue 0 -Force
    $s.doctor_attempts = 0
  }.GetNewClosure()) | Out-Null
  return (Read-State)
}

function Get-DoctorGitHead {
  param([string]$Root = '')
  if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Get-BridgeRoot }
  try { return ([string](& git -c ('safe.directory=' + $Root) -C $Root rev-parse HEAD 2>$null | Out-String)).Trim() } catch { return '' }
}

function Get-DoctorGitStatusText {
  param([string]$Root = '')
  if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Get-BridgeRoot }
  try { return ([string](& git -c ('safe.directory=' + $Root) -C $Root status --porcelain -uall 2>$null | Out-String)).Trim() } catch { return '__git_status_error__' }
}

function Get-DoctorLastCommitMessage {
  param([string]$Root = '')
  if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Get-BridgeRoot }
  try { return ([string](& git -c ('safe.directory=' + $Root) -C $Root log -1 --pretty=%B 2>$null | Out-String)).Trim() } catch { return '' }
}

function Test-DoctorCommitLooksLikeDoctorRepair {
  param([string]$Message)
  $msg = ([string]$Message).Trim()
  if ([string]::IsNullOrWhiteSpace($msg)) { return $false }
  return ($msg -match '(?i)(\bdoctor\b|repair\(|доктор|саморемонт)')
}

function Test-DoctorHeldTestsPassed {
  param($State, [string]$Head = '')
  if (-not $State) { return $false }
  try {
    if (($State.PSObject.Properties.Name -contains 'doctor_tests_passed') -and [bool]$State.doctor_tests_passed) { return $true }
  } catch {}
  try {
    if (($State.PSObject.Properties.Name -contains 'qa_verdict_cache') -and $State.qa_verdict_cache) {
      $qc = $State.qa_verdict_cache
      $verdict = ([string]$qc.verdict).Trim().ToUpperInvariant()
      $qcHead = ([string]$qc.head).Trim()
      if ($verdict -eq 'PASS' -and ([string]::IsNullOrWhiteSpace($qcHead) -or [string]::IsNullOrWhiteSpace($Head) -or $qcHead -eq $Head)) { return $true }
    }
  } catch {}
  try {
    $doneSha = Get-DoctorStateText -State $State -Names @('done_gate_pass_sha') -Default ''
    if (-not [string]::IsNullOrWhiteSpace($doneSha) -and -not [string]::IsNullOrWhiteSpace($Head) -and $doneSha -eq $Head) { return $true }
  } catch {}
  return $false
}

function Test-DoctorHeldFreshCommit {
  param($State, [string]$Head = '', [string]$Root = '')
  if (-not $State -or [string]::IsNullOrWhiteSpace($Head)) { return $false }
  $base = Get-DoctorStateText -State $State -Names @('doctor_held_base_commit','task_bridge_base_commit','task_base_commit') -Default ''
  if ([string]::IsNullOrWhiteSpace($base) -or $base -eq $Head) { return $false }
  $lastMsg = Get-DoctorLastCommitMessage -Root $Root
  if (Test-DoctorCommitLooksLikeDoctorRepair -Message $lastMsg) { return $false }
  return $true
}

function Test-DoctorHeldWorkReady {
  param($State = $null)
  if (-not $State) { $State = Read-State }
  if (-not $State) { return $false }
  $reason = [string]$State.doctor_reason
  if (-not (Test-DoctorHeldReadyCloseReason -Reason $reason)) { return $false }

  $root = Get-BridgeRoot
  $head = Get-DoctorGitHead -Root $root
  $status = Get-DoctorGitStatusText -Root $root
  $hasFreshCommit = Test-DoctorHeldFreshCommit -State $State -Head $head -Root $root
  $testsPassed = Test-DoctorHeldTestsPassed -State $State -Head $head
  if (Test-DoctorCommitFamineReason -Reason $reason) {
    if ($status -eq '') { return $true }
    if ($hasFreshCommit) { return $true }
    if ($testsPassed) { return $true }
    return $false
  }
  if ($status -ne '') { return $false }
  if ($hasFreshCommit) { return $true }
  if ($testsPassed) { return $true }
  return $false
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
  $repairOwner = Get-DoctorRepairTaskId -State $st
  $storedOwner = Get-DoctorStateText -State $st -Names @('doctor_repair_task_id') -Default ''
  $preserveRepairAttempts = (-not [string]::IsNullOrWhiteSpace($repairOwner) -and $storedOwner -eq $repairOwner)
  $repairAttempts = if ($preserveRepairAttempts) { Get-DoctorRepairAttemptCount -State $st } else { 0 }
  $holdHead = Get-DoctorGitHead
  $heldBaseCommit = Get-DoctorStateText -State $st -Names @('task_bridge_base_commit','task_base_commit') -Default ''
  try { Save-StateSnapshot -Reason 'doctor_activate' } catch {}
  Update-State ({ param($s)
    $s.held_task         = $cur
    $s.doctor_active     = $true
    $s | Add-Member -NotePropertyName doctor_repair_attempts -NotePropertyValue $repairAttempts -Force
    $s | Add-Member -NotePropertyName doctor_restart_count -NotePropertyValue 0 -Force
    $s | Add-Member -NotePropertyName doctor_repair_task_id -NotePropertyValue $repairOwner -Force
    $s | Add-Member -NotePropertyName doctor_hold_head -NotePropertyValue $holdHead -Force
    $s | Add-Member -NotePropertyName doctor_held_base_commit -NotePropertyValue $heldBaseCommit -Force
    $s.doctor_attempts   = $repairAttempts
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
  param([switch]$ResolveHeldDone)
  $st = Read-State
  $held = [string]$st.held_task
  if ($ResolveHeldDone) {
    $bid = Get-DoctorHeldBacklogId -State $st
    if ([string]::IsNullOrWhiteSpace($bid)) {
      try { Add-Message -From system -Text "🩺 Доктор: готовность held-задачи подтверждена, но backlog id пуст — не закрываю и не очищаю held_task." -Kind event | Out-Null } catch {}
      try { Write-DoctorLog "Doctor resolve-held-done blocked: missing backlog id" } catch {}
      return $false
    }
    $head = Get-DoctorGitHead
    $closed = $false
    if (Get-Command Set-Idea -ErrorAction SilentlyContinue) {
      try { $closed = [bool](Set-Idea -Id $bid -Status 'done' -Reason 'doctor-resolved-commit-famine-ready') } catch { $closed = $false }
    }
    if (-not $closed) {
      try { Add-Message -From system -Text ("🩺 Доктор: готовность held-задачи подтверждена, но Set-Idea не закрыл backlog id " + $bid + " — state оставлен без изменений.") -Kind event | Out-Null } catch {}
      try { Write-DoctorLog ("Doctor resolve-held-done blocked: Set-Idea failed for " + $bid) } catch {}
      return $false
    }
    try {
      if (Get-Command Write-BacklogJsonLine -ErrorAction SilentlyContinue) {
        Write-BacklogJsonLine ([ordered]@{
          ts = (Get-Date).ToUniversalTime().ToString('o')
          action = 'doctor-resolve-held-done'
          item_id = $bid
          reason = 'commit_famine_work_ready'
          commit = $head
        })
      }
    } catch {}
    Update-State ({ param($s)
      $s.current_task         = $null
      $s.held_task            = $null
      $s.current_backlog_id   = $null
      $s.doctor_active        = $false
      $s.doctor_reason        = ''
      $s.doctor_started_at    = $null
      $s.doctor_attempts      = 0
      $s | Add-Member -NotePropertyName doctor_repair_attempts -NotePropertyValue 0 -Force
      $s | Add-Member -NotePropertyName doctor_restart_count -NotePropertyValue 0 -Force
      $s | Add-Member -NotePropertyName doctor_repair_task_id -NotePropertyValue '' -Force
      $s | Add-Member -NotePropertyName doctor_hold_head -NotePropertyValue '' -Force
      $s | Add-Member -NotePropertyName doctor_held_base_commit -NotePropertyValue '' -Force
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
      $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null
      $s.status='idle'
    }.GetNewClosure()) | Out-Null
    try { Add-Message -From system -Text ("🩺 Доктор: held-задача " + $bid + " уже готова при commit_famine — закрыта как done, повторная диагностика пропущена.") -Kind event | Out-Null } catch {}
    try { Append-DoctorEvent -Event 'resolve-held-done' -Reason 'commit_famine_work_ready' } catch {}
    try { Write-DoctorLog ("Doctor resolve-held-done: " + $bid + " " + $head) } catch {}
    return $true
  }
  if ([string]::IsNullOrWhiteSpace($held)) {
    try { Add-Message -From system -Text "🩺 Доктор завершил, но held_task пуст — нечего возобновлять. Возвращаюсь в idle." -Kind event | Out-Null } catch {}
    # FIX 2026-05-26: clear current_task and counters too, else the loop keeps running the
    # doctor diagnostic prompt as a normal task (caught on first wiring test).
    Update-State ({ param($s)
      $s.doctor_active=$false; $s.held_task=$null; $s.doctor_reason=''; $s.doctor_started_at=$null; $s.doctor_attempts=0
      $s | Add-Member -NotePropertyName doctor_repair_attempts -NotePropertyValue 0 -Force
      $s | Add-Member -NotePropertyName doctor_restart_count -NotePropertyValue 0 -Force
      $s | Add-Member -NotePropertyName doctor_repair_task_id -NotePropertyValue '' -Force
      $s | Add-Member -NotePropertyName doctor_hold_head -NotePropertyValue '' -Force
      $s | Add-Member -NotePropertyName doctor_held_base_commit -NotePropertyValue '' -Force
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
    $s | Add-Member -NotePropertyName doctor_repair_task_id -NotePropertyValue '' -Force
    $s | Add-Member -NotePropertyName doctor_hold_head -NotePropertyValue '' -Force
    $s | Add-Member -NotePropertyName doctor_held_base_commit -NotePropertyValue '' -Force
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
  # Called when Doctor attempts are exhausted or Doctor itself fails.
  # 2026-06-11 freeze-audit wave1 atom2: this used to park held_task in a state dead-end
  # ("жду оператора") — the task fell out of the queue FOREVER (reconcile later marked the
  # backlog item failed, terminal, no auto-return). Now: requeue the backlog item as 'held'
  # with an explicit reason (visible, queue keeps moving, operator decides with context).
  # No auto-resume to approved/new — Doctor exhausted means a human look IS warranted; the
  # win is the conveyor stays free and the task is never lost. Fallback: if there is no
  # backlog id or Set-Idea fails, keep held_task in state (old behavior, reaper backstops).
  param([string]$Reason = 'attempts exhausted')
  $abortHeld = ''
  $abortBid = ''
  try {
    $abortState = Read-State
    if ($abortState) {
      try { $abortHeld = [string]$abortState.held_task } catch {}
      try { $abortBid = [string]$abortState.current_backlog_id } catch {}
    }
  } catch {}
  $requeued = $false
  if (-not [string]::IsNullOrWhiteSpace($abortBid) -and (Get-Command Set-Idea -ErrorAction SilentlyContinue)) {
    try { $requeued = [bool](Set-Idea -Id $abortBid -Status 'held' -Reason ('doctor-exhausted: ' + $Reason)) } catch { $requeued = $false }
  }
  Update-State ({
    param($s)
    $s.doctor_active=$false; $s.doctor_attempts=0; $s.doctor_reason=''; $s.doctor_started_at=$null
    $s | Add-Member -NotePropertyName doctor_repair_attempts -NotePropertyValue 0 -Force
    $s | Add-Member -NotePropertyName doctor_restart_count -NotePropertyValue 0 -Force
    $s | Add-Member -NotePropertyName doctor_repair_task_id -NotePropertyValue '' -Force
    $s | Add-Member -NotePropertyName doctor_hold_head -NotePropertyValue '' -Force
    $s | Add-Member -NotePropertyName doctor_held_base_commit -NotePropertyValue '' -Force
    $s.current_task=$null; $s.task_turn=0; Clear-AuditorSuppressedHashes -State $s
    if ($requeued) { $s.held_task=$null; $s.current_backlog_id=$null }
  }.GetNewClosure()) | Out-Null
  if ($requeued) {
    $bidShort = $abortBid; if ($bidShort.Length -gt 8) { $bidShort = $bidShort.Substring(0,8) }
    try { Add-Message -From system -Text ("🩺 Доктор не справился (" + $Reason + "). Задача " + $bidShort + " возвращена в backlog со статусом held (reason=doctor-exhausted) — конвейер свободен, реши её судьбу.") -Kind event | Out-Null } catch {}
  } else {
    try { Add-Message -From system -Text ("🩺 Доктор не справился (" + $Reason + "). Held-task сохранён в state. Жду оператора.") -Kind event | Out-Null } catch {}
  }
  try { Send-PushEvent -Kind need_you -Text "Doctor failed: $Reason" } catch {}
  try { Append-DoctorEvent -Event 'abort' -Reason $Reason } catch {}
  try { Write-DoctorLog ("Doctor abort: " + $Reason + $(if ($requeued) { ' (requeued ' + $abortBid + ' as held)' } else { '' })) } catch {}
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

function Normalize-DoctorTaskWindowText {
  param([AllowNull()][string]$Text)
  return ((([string]$Text) -replace '\s+', ' ').Trim().ToLowerInvariant())
}

function Test-DoctorTextContains {
  param([AllowNull()][string]$Text, [AllowNull()][string]$Needle)
  $n = Normalize-DoctorTaskWindowText $Needle
  if ([string]::IsNullOrWhiteSpace($n)) { return $false }
  return ((Normalize-DoctorTaskWindowText $Text).Contains($n))
}

function Get-DoctorConversationPath {
  param([string]$Root)
  $channel = ''
  try {
    if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) {
      $channel = [string](Get-EffectiveChannel)
    }
  } catch {}
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = [string]$env:BRIDGE_CHANNEL }
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = 'main' }

  $candidates = New-Object 'System.Collections.Generic.List[string]'
  if (-not [string]::IsNullOrWhiteSpace($channel)) {
    [void]$candidates.Add((Join-Path $Root ("channels\" + $channel + "\conversation.jsonl")))
  }
  [void]$candidates.Add((Join-Path $Root 'channels\main\conversation.jsonl'))
  [void]$candidates.Add((Join-Path $Root 'conversation.jsonl'))
  foreach ($p in @($candidates.ToArray())) {
    if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
  }
  return $null
}

function Read-DoctorConversationRecords {
  param([string]$Path)
  $records = New-Object 'System.Collections.Generic.List[object]'
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return @()
  }
  $idx = 0
  foreach ($line in [System.IO.File]::ReadLines($Path, [System.Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $obj = $line | ConvertFrom-Json
      $text = ''
      $from = ''
      $kind = ''
      try { $text = [string]$obj.text } catch {}
      try { $from = [string]$obj.from } catch {}
      try { $kind = [string]$obj.kind } catch {}
      [void]$records.Add([pscustomobject][ordered]@{
        index = $idx
        from = $from
        kind = $kind
        text = $text
        raw = $obj
      })
      $idx++
    } catch {
      $idx++
    }
  }
  return @($records.ToArray())
}

function Test-DoctorFailedTaskMarker {
  param([AllowNull()][string]$Text)
  $t = Normalize-DoctorTaskWindowText $Text
  if ([string]::IsNullOrWhiteSpace($t)) { return $false }
  return ($t -match '(помечаю как failed|помечен[оа]? failed|failed-задач|restart cap|превысила restart|не завершилась успешно|marked failed|task failed)')
}

function Test-DoctorTaskStartMarker {
  param([AllowNull()][string]$Text)
  $t = Normalize-DoctorTaskWindowText $Text
  if ([string]::IsNullOrWhiteSpace($t)) { return $false }
  return ($t -match '(беру .*ids=|task management:|task_start|task start|текущая задача|begin task|current_task|selected=)')
}

function Get-DoctorFailedTaskWindowRecords {
  param(
    [object[]]$Records,
    [string]$TaskText = '',
    [string]$BacklogId = ''
  )
  $records = @($Records)
  if ($records.Count -eq 0) { return @() }

  $taskNeedle = Normalize-DoctorTaskWindowText $TaskText
  if ($taskNeedle.Length -gt 80) { $taskNeedle = $taskNeedle.Substring(0, 80) }
  $fail = -1
  if (-not [string]::IsNullOrWhiteSpace($BacklogId)) {
    for ($i = $records.Count - 1; $i -ge 0; $i--) {
      $txt = [string]$records[$i].text
      if ((Test-DoctorFailedTaskMarker $txt) -and (Test-DoctorTextContains $txt $BacklogId)) {
        $fail = $i
        break
      }
    }
  }
  if ($fail -lt 0 -and -not [string]::IsNullOrWhiteSpace($taskNeedle)) {
    for ($i = $records.Count - 1; $i -ge 0; $i--) {
      $txt = [string]$records[$i].text
      if ((Test-DoctorFailedTaskMarker $txt) -and (Test-DoctorTextContains $txt $taskNeedle)) {
        $fail = $i
        break
      }
    }
  }
  if ($fail -lt 0) {
    for ($i = $records.Count - 1; $i -ge 0; $i--) {
      if (Test-DoctorFailedTaskMarker ([string]$records[$i].text)) {
        $fail = $i
        break
      }
    }
  }

  $start = -1
  if ($fail -ge 0) {
    if (-not [string]::IsNullOrWhiteSpace($BacklogId)) {
      for ($i = $fail; $i -ge 0; $i--) {
        $txt = [string]$records[$i].text
        if ((Test-DoctorTaskStartMarker $txt) -and (Test-DoctorTextContains $txt $BacklogId)) {
          $start = $i
          break
        }
      }
    }
    if ($start -lt 0 -and -not [string]::IsNullOrWhiteSpace($taskNeedle)) {
      for ($i = $fail; $i -ge 0; $i--) {
        $txt = [string]$records[$i].text
        if ((Test-DoctorTaskStartMarker $txt) -and (Test-DoctorTextContains $txt $taskNeedle)) {
          $start = $i
          break
        }
      }
    }
    if ($start -lt 0) {
      for ($i = $fail; $i -ge 0; $i--) {
        if (Test-DoctorTaskStartMarker ([string]$records[$i].text)) {
          $start = $i
          break
        }
      }
    }
    if ($start -lt 0) { return @() }
    return @($records[$start..$fail])
  }

  if (-not [string]::IsNullOrWhiteSpace($BacklogId)) {
    for ($i = $records.Count - 1; $i -ge 0; $i--) {
      $txt = [string]$records[$i].text
      if ((Test-DoctorTaskStartMarker $txt) -and (Test-DoctorTextContains $txt $BacklogId)) {
        $start = $i
        break
      }
    }
  }
  if ($start -lt 0 -and -not [string]::IsNullOrWhiteSpace($taskNeedle)) {
    for ($i = $records.Count - 1; $i -ge 0; $i--) {
      $txt = [string]$records[$i].text
      if ((Test-DoctorTaskStartMarker $txt) -and (Test-DoctorTextContains $txt $taskNeedle)) {
        $start = $i
        break
      }
    }
  }
  if ($start -lt 0) {
    for ($i = $records.Count - 1; $i -ge 0; $i--) {
      if (Test-DoctorTaskStartMarker ([string]$records[$i].text)) {
        $start = $i
        break
      }
    }
  }
  if ($start -lt 0) { return @() }

  $end = $records.Count - 1
  for ($i = $start + 1; $i -lt $records.Count; $i++) {
    $txt = [string]$records[$i].text
    if (Test-DoctorFailedTaskMarker $txt) {
      $end = $i
      break
    }
    if ((Test-DoctorTaskStartMarker $txt) -and (-not [string]::IsNullOrWhiteSpace($BacklogId)) -and -not (Test-DoctorTextContains $txt $BacklogId)) {
      $end = $i - 1
      break
    }
  }
  if ($end -lt $start) { return @() }
  return @($records[$start..$end])
}

function Test-DoctorCriticRecord {
  param([AllowNull()]$Record)
  if ($null -eq $Record) { return $false }
  $from = Normalize-DoctorTaskWindowText ([string]$Record.from)
  $kind = Normalize-DoctorTaskWindowText ([string]$Record.kind)
  $text = Normalize-DoctorTaskWindowText ([string]$Record.text)
  return ($from -match 'critic|критик' -or $kind -match 'critic|критик' -or $text -match 'critic|критик')
}

function Get-DoctorCriticVerdictFromWindow {
  param([object[]]$WindowRecords)
  $critics = @(@($WindowRecords) | Where-Object { Test-DoctorCriticRecord $_ })
  if ($critics.Count -eq 0) { return $null }
  $last = $critics[$critics.Count - 1]
  $text = [string]$last.text
  $norm = Normalize-DoctorTaskWindowText $text
  $serious = ($norm -match '(серь[её]зн|serious|severity\s*[:=]\s*(critical|high|serious)|critical|критическ|blocker)')
  if ($norm -match '(ok\s*/\s*none|no serious|не обнаружено|без serious)') { $serious = $false }
  return [pscustomobject][ordered]@{
    serious = [bool]$serious
    findings = $text
    index = [int]$last.index
  }
}

function Get-FailedTaskCriticVerdict {
  param(
    [string]$Root,
    [string]$TaskText = '',
    [string]$BacklogId = ''
  )
  $path = Get-DoctorConversationPath -Root $Root
  $records = @(Read-DoctorConversationRecords -Path $path)
  $window = @(Get-DoctorFailedTaskWindowRecords -Records $records -TaskText $TaskText -BacklogId $BacklogId)
  $verdict = Get-DoctorCriticVerdictFromWindow -WindowRecords $window
  if ($null -eq $verdict) { return $null }
  $verdict | Add-Member -NotePropertyName conversation_path -NotePropertyValue $path -Force
  $verdict | Add-Member -NotePropertyName window_count -NotePropertyValue $window.Count -Force
  return $verdict
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
  $criticVerdict = $null
  try { $criticVerdict = Get-FailedTaskCriticVerdict -Root $root -TaskText $TaskText -BacklogId $BacklogId } catch { $criticVerdict = $null }
  $criticSerious = ($criticVerdict -and [bool]$criticVerdict.serious)

  if ($parseBad.Count -eq 0 -and -not $criticSerious) {
    try {
      $smokeScript = Join-Path $root 'smoke.ps1'
      if (Test-Path $smokeScript) {
        $out = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $smokeScript 2>&1
        $smokeOk = ($LASTEXITCODE -eq 0)
        $smokeTail = (@($out) | Select-Object -Last 1) -join ' '
      }
    } catch { $smokeOk = $false; $smokeTail = $_.Exception.Message }
  }

  if ($parseBad.Count -eq 0 -and -not $criticSerious) {
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
    # 3b) BROKEN or critic-rejected tail -> reversibly stash ONLY those files; page operator.
    $whyParts = New-Object 'System.Collections.Generic.List[string]'
    if ($parseBad.Count -gt 0) { [void]$whyParts.Add(('parse: ' + (($parseBad | Select-Object -First 3) -join ', '))) }
    if ($criticSerious) { [void]$whyParts.Add(('critic-debt: serious verdict at conversation index ' + [string]$criticVerdict.index)) }
    $why = (@($whyParts.ToArray()) -join '; ')
    if ([string]::IsNullOrWhiteSpace($why)) { $why = 'unknown salvage quarantine reason' }
    try {
      $stashMsg = 'salvage-invalid: ' + $taskShort + ' | ' + $why
      if ($stashMsg.Length -gt 160) { $stashMsg = $stashMsg.Substring(0,160) }
      & git -C $root stash push -u -m $stashMsg -- @($files) 2>$null | Out-Null
      $stashSha = ''
      try { $stashSha = ([string](& git -C $root rev-parse --verify refs/stash 2>$null)).Trim() } catch { $stashSha = '' }
      $stashRef = 'stash@{0}'
      $followUpId = ''
      if ($criticSerious -and (Get-Command Add-BacklogCriticDebtFollowUp -ErrorAction SilentlyContinue)) {
        try {
          $followUpId = [string](Add-BacklogCriticDebtFollowUp -TaskId $BacklogId -TaskText $TaskText -Findings ([string]$criticVerdict.findings) -StashRef $stashRef -StashSha $stashSha -Files $files)
        } catch { try { Write-DoctorLog ('critic-debt follow-up error: ' + $_.Exception.Message) } catch {} }
      }
      try { Write-DoctorLog ('salvage STASH invalid tail (' + $why + '): ' + $taskShort) } catch {}
      try { Add-Message -From system -Text ('📦 Хвост failed-задачи не парсится (' + $why + ') — спрятал эти файлы в git stash (обратимо: `git stash pop`), дерево очищено. Нужен ты для разбора.') -Kind event | Out-Null } catch {}
      try { Send-PushEvent -Kind need_you -Text ('salvage: invalid tail stashed — ' + $why) } catch {}
      $result = @{ action='stashed'; why=$why; stash_ref=$stashRef; stash_sha=$stashSha; critic_debt_followup_id=$followUpId }
    } catch { try { Write-DoctorLog ('salvage stash error: ' + $_.Exception.Message) } catch {} }
  }
  return $result
}
