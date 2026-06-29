function Initialize-DriverStartup {
# ---------- startup ----------
function Get-DriverStartupSessionLedgerEvents {
  param([string]$Channel = '')
  $events = New-Object System.Collections.ArrayList
  try {
    $ledger = Join-Path (Get-DecisionsPath) 'session-ledger.jsonl'
    if (-not (Test-Path -LiteralPath $ledger)) { return @() }
    $u8NoBom = New-Object System.Text.UTF8Encoding($false)
    foreach ($rawLine in [System.IO.File]::ReadAllLines($ledger, $u8NoBom)) {
      try {
        $line = ([string]$rawLine).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.Length -gt 0 -and [int][char]$line[0] -eq 0xFEFF) { $line = $line.Substring(1) }
        $entry = $line | ConvertFrom-Json
        $entryChannel = if ($entry.PSObject.Properties.Name -contains 'channel') { [string]$entry.channel } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($Channel) -and -not [string]::IsNullOrWhiteSpace($entryChannel) -and $entryChannel -ne $Channel) { continue }
        $tsText = if ($entry.PSObject.Properties.Name -contains 'ts') { [string]$entry.ts } else { '' }
        $ts = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse($tsText, [ref]$ts)) { continue }
        [void]$events.Add([pscustomobject][ordered]@{
          ts    = $ts
          event = if ($entry.PSObject.Properties.Name -contains 'event') { [string]$entry.event } else { '' }
          what  = if ($entry.PSObject.Properties.Name -contains 'what')  { [string]$entry.what }  else { '' }
          task  = if ($entry.PSObject.Properties.Name -contains 'task')  { [string]$entry.task }  else { '' }
        })
      } catch {}
    }
  } catch {}
  return @($events | Sort-Object ts)
}

function Test-DriverStartupVerifiedRepairAfterTaskStart {
  param(
    [object]$State,
    [string]$TaskText = '',
    [string]$Channel = ''
  )
  $isDoctorTask = $false
  try {
    if ($State -and $State.PSObject.Properties.Name -contains 'doctor_active' -and [bool]$State.doctor_active) { $isDoctorTask = $true }
  } catch {}
  if (-not $isDoctorTask -and [string]$TaskText -match '(?i)doctor|доктор|саморемонт') { $isDoctorTask = $true }
  if (-not $isDoctorTask) { return $false }

  $events = @(Get-DriverStartupSessionLedgerEvents -Channel $Channel)
  if ($events.Count -eq 0) { return $false }
  $lastTaskStart = $null
  foreach ($event in $events) {
    if ([string]$event.event -eq 'task_start') { $lastTaskStart = $event.ts }
  }
  if ($null -eq $lastTaskStart) { return $false }

  foreach ($event in $events) {
    if ($event.ts -le $lastTaskStart) { continue }
    $eventType = [string]$event.event
    if ($eventType -eq 'verified_commit') { return $true }
    if ($eventType -eq 'doctor_fix') {
      $what = [string]$event.what
      if ($what -and $what -notmatch '(?i)^doctor_activated$' -and $what -match '(?i)verified|repair|fixed|pass|ok|commit|исправ|почин|провер') { return $true }
    }
  }
  return $false
}

function Get-DriverStartupResumeTaskId {
  param($State, [string]$TaskText = '')
  foreach ($name in @('current_backlog_id','current_task_id')) {
    try {
      if ($State -and ($State.PSObject.Properties.Name -contains $name) -and -not [string]::IsNullOrWhiteSpace([string]$State.$name)) {
        return [string]$State.$name
      }
    } catch {}
  }
  return [string]$TaskText
}

function Get-DriverStartupRestartCaps {
  $caps = [ordered]@{ apply = 6; hard = 3; total = 8 }
  try {
    $cfgRC = Get-BridgeConfig
    if ($cfgRC -and ($cfgRC.PSObject.Properties.Name -contains 'taskRestartCaps') -and $cfgRC.taskRestartCaps) {
      foreach ($name in @('apply','hard','total')) {
        try {
          if ($cfgRC.taskRestartCaps.PSObject.Properties.Name -contains $name) { $caps[$name] = [int]$cfgRC.taskRestartCaps.$name }
        } catch {}
      }
    } elseif ($cfgRC -and $cfgRC.PSObject.Properties.Name -contains 'taskRestartCap' -and $cfgRC.taskRestartCap) {
      $caps['hard'] = [int]$cfgRC.taskRestartCap
    }
  } catch {}
  if ([int]$caps['apply'] -lt 1) { $caps['apply'] = 1 }
  if ([int]$caps['hard'] -lt 1) { $caps['hard'] = 1 }
  if ([int]$caps['total'] -lt 1) { $caps['total'] = 1 }
  if ([int]$caps['apply'] -gt 20) { $caps['apply'] = 20 }
  if ([int]$caps['hard'] -gt 10) { $caps['hard'] = 10 }
  if ([int]$caps['total'] -gt 30) { $caps['total'] = 30 }
  return [pscustomobject]$caps
}

function Get-RestartRootCauseClass {
  param($BootState, [bool]$IsTrustedApply, [string]$StampReason = '')
  if ($IsTrustedApply) { return 'operator' }

  $reasonCandidates = @()
  if ($BootState) {
    foreach ($name in @('last_restart_reason','restart_flag_reason')) {
      try {
        if ($BootState.PSObject.Properties.Name -contains $name) {
          $reasonCandidates += [string]$BootState.$name
        }
      } catch {
        $reasonCandidates += ''
      }
    }
  }
  $reasonCandidates += [string]$StampReason
  foreach ($reasonText in $reasonCandidates) {
    $reason = ([string]$reasonText).Trim()
    if ([string]::IsNullOrWhiteSpace($reason)) { continue }
    if ($reason -match '(?i)timeout|timed[ -]?out|soft_timeout|hard_timeout') { return 'timeout' }
    if ($reason -match '(?i)zombie|orphan|stale') { return 'zombie' }
    if ($reason -match '(?i)killed|kill|terminated|dead|process[ -]?exit|agent[ -]?exit') { return 'killed' }
    if ($reason -match '(?i)operator|manual|verified-ps1-diff|apply|restart\.flag|flag') { return 'operator' }
    if ($reason -match '(?i)crash|exception|fault|panic|unhandled') { return 'crash' }
    if ($reason -match '(?i)unknown|missing-stamp|untrusted') { return 'unknown' }
  }

  if ($BootState) {
    $prevStatus = [string]$BootState.status
    $prevStatusText = [string]$BootState.status_text
    if ($prevStatus -match '(?i)timeout|timed[ -]?out' -or $prevStatusText -match '(?i)timeout|timed[ -]?out') {
      return 'timeout'
    }
    if ($prevStatus -match '(?i)zombie|orphan|stale' -or $prevStatusText -match '(?i)zombie|orphan|stale') {
      return 'zombie'
    }

    $agentPid = 0
    try { $agentPid = [int]$BootState.agent_pid } catch { $agentPid = 0 }
    if ($agentPid -le 0) {
      try { $agentPid = [int]$BootState.current_agent_pid } catch { $agentPid = 0 }
    }
    if ($agentPid -gt 0) {
      $alive = $false
      try {
        $p = Get-Process -Id $agentPid -ErrorAction SilentlyContinue
        if ($p) { $alive = $true }
      } catch {
        $alive = $false
      }
      if (-not $alive) { return 'killed' }
      if ($prevStatus -match '(?i)working|running') { return 'zombie' }
    }
    if ($prevStatus -match '(?i)working|running') { return 'crash' }
  }

  return 'unknown'
}

function Test-DriverStartupPendingDoctorSignal {
  param($State)
  if (-not $State) { return $false }
  try { if ([bool]$State.doctor_active) { return $false } } catch {}
  $cur = ''
  $held = ''
  try { $cur = [string]$State.current_task } catch {}
  try { $held = [string]$State.held_task } catch {}
  if ([string]::IsNullOrWhiteSpace($cur)) { return $false }
  if (-not [string]::IsNullOrWhiteSpace($held)) { return $false }
  $sig = Join-Path (Get-BridgeRoot) 'control\repair.signal'
  return (Test-Path -LiteralPath $sig -PathType Leaf)
}

function Invoke-DriverStartupDoctorSignalAdmission {
  param($State)
  if (-not (Test-DriverStartupPendingDoctorSignal -State $State)) { return $false }
  if (-not (Get-Command Test-DoctorSignal -ErrorAction SilentlyContinue)) { return $false }
  if (-not (Get-Command Activate-Doctor -ErrorAction SilentlyContinue)) { return $false }
  $reason = 'watchdog_rollback'
  try {
    $r = Test-DoctorSignal
    if (-not [string]::IsNullOrWhiteSpace([string]$r)) { $reason = [string]$r }
  } catch {
    return $false
  }
  try {
    return [bool](Activate-Doctor -Reason $reason -Detail 'signal from watchdog before startup resume')
  } catch {
    return $false
  }
}

Sweep-AgentOrphans

# Resume an interrupted task across restarts instead of dropping it. Conversation,
# summary and decisions are file-based and already survive. We keep current_task /
# task_turn / task_mode / last_user_seq / summarized_seq, and only clear the transient
# execution state (a killed agent process). The loop re-runs the interrupted turn.
$boot = Read-State
try {
  if (Invoke-DriverStartupDoctorSignalAdmission -State $boot) {
    $boot = Read-State
  }
} catch {}
$resumeTask = if ($boot -and $boot.current_task) { [string]$boot.current_task } else { '' }
if (-not [string]::IsNullOrWhiteSpace($resumeTask)) {
  # 2026-05-28: detect "stuck task" — if we've already resumed this task N times
  # without it closing, give up and mark failed. Real incident: Phase 1 task
  # survived 7+ restarts in 20 min while verify-loop and unrelated commits kept
  # triggering supervisor recycles. Auditor flagged "Supervisor restarts exceed
  # limit (7/5)" but bridge kept re-resuming with no escape valve.
  $prevRestartCount = 0
  $prevApplyRestartCount = 0
  $prevHardRestartCount = 0
  $prevTotalRestartCount = 0
  try { if ($boot.PSObject.Properties.Name -contains 'task_restart_count') { $prevRestartCount = [int]$boot.task_restart_count } } catch {}
  try { if ($boot.PSObject.Properties.Name -contains 'task_apply_restart_count') { $prevApplyRestartCount = [int]$boot.task_apply_restart_count } } catch {}
  try { if ($boot.PSObject.Properties.Name -contains 'task_hard_restart_count') { $prevHardRestartCount = [int]$boot.task_hard_restart_count } } catch {}
  try { if ($boot.PSObject.Properties.Name -contains 'task_restart_total_count') { $prevTotalRestartCount = [int]$boot.task_restart_total_count } } catch {}
  if ($prevTotalRestartCount -lt $prevRestartCount) { $prevTotalRestartCount = $prevRestartCount }
  if ($prevHardRestartCount -eq 0 -and $prevApplyRestartCount -eq 0 -and $prevRestartCount -gt 0) { $prevHardRestartCount = $prevRestartCount }
  $restartCaps = Get-DriverStartupRestartCaps
  $maxApplyRestarts = [int]$restartCaps.apply
  $maxHardRestarts = [int]$restartCaps.hard
  $maxTotalRestarts = [int]$restartCaps.total

  $resumeTaskId = Get-DriverStartupResumeTaskId -State $boot -TaskText $resumeTask
  $applyStamp = $null
  try { $applyStamp = Consume-ApplyRestartStamp -TaskId $resumeTaskId } catch { $applyStamp = [pscustomobject]@{ ok = $false; reason = 'consume-error'; error = $_.Exception.Message } }
  $isTrustedApplyRestart = ($applyStamp -and [bool]$applyStamp.ok)

  $restartBudgetResetByVerifiedRepair = $false
  if ($isTrustedApplyRestart -and $prevApplyRestartCount -ge $maxApplyRestarts -and (Test-DriverStartupVerifiedRepairAfterTaskStart -State $boot -TaskText $resumeTask -Channel $Channel)) {
    $prevApplyRestartCount = 0
    $restartBudgetResetByVerifiedRepair = $true
  }

  $newApplyRestartCount = $prevApplyRestartCount + $(if ($isTrustedApplyRestart) { 1 } else { 0 })
  $newHardRestartCount = $prevHardRestartCount + $(if ($isTrustedApplyRestart) { 0 } else { 1 })
  $newTotalRestartCount = $prevTotalRestartCount + 1
  $restartCapHit = ''
  if ($newTotalRestartCount -gt $maxTotalRestarts) { $restartCapHit = 'total' }
  elseif ($newHardRestartCount -gt $maxHardRestarts) { $restartCapHit = 'hard' }
  elseif ($newApplyRestartCount -gt $maxApplyRestarts) { $restartCapHit = 'apply' }

  if (-not [string]::IsNullOrWhiteSpace($restartCapHit)) {
    # Stuck task: bail out. Mark backlog failed if linked, clear state, post msg.
    $stuckTaskShort = $resumeTask
    if ($stuckTaskShort.Length -gt 100) { $stuckTaskShort = $stuckTaskShort.Substring(0, 100) + '…' }
    $stuckBacklogId = if ($boot.current_backlog_id) { [string]$boot.current_backlog_id } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($stuckBacklogId)) {
      $dqpcMarkedDone = $false
      try { . (Join-Path (Get-BridgeRoot) 'lib\task-action-evidence.ps1') } catch {}
      if (Get-Command Test-TaskDoneQaPassCommitEvidence -ErrorAction SilentlyContinue) {
        try {
          if (Test-TaskDoneQaPassCommitEvidence -BacklogId $stuckBacklogId -BridgeRoot (Get-BridgeRoot)) {
            $dqpcEntry = @(Get-Backlog) | Where-Object { [string]$_.id -eq $stuckBacklogId } | Select-Object -First 1
            $dqpcSha = ([string]$dqpcEntry.done_qa_pass_commit).Trim()
            try { Set-Idea -Id $stuckBacklogId -Status 'done' -Reason ("restart_cap_reconciled_done_qa_pass_commit_" + $dqpcSha) | Out-Null } catch {}
            $dqpcMarkedDone = $true
          }
        } catch {}
      }
      if (-not $dqpcMarkedDone) {
        $recoverFlag = $false
        try {
          $cfgRecover = Get-BridgeConfig
          if ($cfgRecover.PSObject.Properties.Name -contains 'recover_covered_after_restart') { $recoverFlag = [bool]$cfgRecover.recover_covered_after_restart }
        } catch { $recoverFlag = $false }
        if ($recoverFlag -and (Get-Command Test-TaskCompletionRecoverable -ErrorAction SilentlyContinue)) {
          try {
            $recoverResult = Test-TaskCompletionRecoverable -State $boot -BacklogId $stuckBacklogId -BridgeRoot (Get-BridgeRoot)
            $recoverDecision = if ([string]$recoverResult.verdict -eq 'RECOVER_DONE') { 'recover' } else { 'fail' }
            try { Write-TaskCompletionRecoveryAudit -BridgeRoot (Get-BridgeRoot) -TaskId $stuckBacklogId -Decision $recoverDecision -Verdict $recoverResult -FlagState $recoverFlag -Site 'driver60_restart_cap' } catch {}
            if ([string]$recoverResult.verdict -eq 'RECOVER_DONE') {
              try { Set-Idea -Id $stuckBacklogId -Status 'done' -Reason ("restart_cap_recovered_covered_after_restart_" + ([string]$recoverResult.head).Substring(0,[Math]::Min(7,([string]$recoverResult.head).Length))) | Out-Null } catch {}
              $dqpcMarkedDone = $true
            }
          } catch {}
        }
      }
      if (-not $dqpcMarkedDone) {
        try { Set-Idea -Id $stuckBacklogId -Status 'failed' -Reason ("task_restart_loop_" + $restartCapHit + "_" + $newTotalRestartCount) | Out-Null } catch {}
      }
    }
    Update-State {
      param($s)
      $s.current_task = $null
      $s.current_task_id = $null
      $s.task_turn = 0
      $s.task_mode = 'normal'
      $s.task_did_actions = $false
      $s.coder_fired = $false
      $s.verify_retry_count = 0
      $s.critic_retry_count = 0
      $s.status = 'idle'
      $s.active_agent = $null
      $s.active_model = $null
      $s.status_text = $null
      $s.agent_pid = $null
      $s.current_agent = $null
      $s.current_agent_pid = 0
      $s.driver_started = (Get-Date).ToString('o')
      $s.heartbeat = (Get-Date).ToString('o')
      $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue 0 -Force
      $s | Add-Member -NotePropertyName task_apply_restart_count -NotePropertyValue 0 -Force
      $s | Add-Member -NotePropertyName task_hard_restart_count -NotePropertyValue 0 -Force
      $s | Add-Member -NotePropertyName task_restart_total_count -NotePropertyValue 0 -Force
      $s | Add-Member -NotePropertyName codex_evidence_retry_count -NotePropertyValue 0 -Force
    } | Out-Null
    Add-Message -From system -Text ("⚠ Задача превысила restart cap (" + $restartCapHit + ": apply=" + $newApplyRestartCount + "/" + $maxApplyRestarts + ", hard=" + $newHardRestartCount + "/" + $maxHardRestarts + ", total=" + $newTotalRestartCount + "/" + $maxTotalRestarts + ") — помечаю как failed и перехожу к следующей. Текст: «" + $stuckTaskShort + "»") -Kind event | Out-Null
    # Pick up the tail: a failed task often leaves a VALID uncommitted fix behind (the bridge
    # crashed on orchestration, not on the code). Auto-commit it if it parses (tree clean again,
    # autonomy unblocked) or reversibly stash it if broken — so no operator has to do it by hand.
    try { Invoke-FailedTaskSalvage -TaskText $stuckTaskShort -BacklogId $stuckBacklogId | Out-Null } catch { try { Write-DoctorLog ("salvage call error: " + $_.Exception.Message) } catch {} }
  } else {
    $restartRootCauseClass = Get-RestartRootCauseClass -BootState $boot -IsTrustedApply $isTrustedApplyRestart -StampReason $(if ($applyStamp -and $applyStamp.reason) { [string]$applyStamp.reason } else { '' })
    Update-State {
      param($s)
      Start-ReplayForStateTask -State $s -TaskText $resumeTask -ChannelName $Channel
      $s.status='working'; $s.stop=$false; $s.abort=$false
      $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.current_agent=$null; $s.current_agent_pid=0; $s.current_agent_ticks=0; $s.current_agent_since=$null; $s.agent_telemetry=$null
      $s.driver_started=(Get-Date).ToString('o'); $s.heartbeat=(Get-Date).ToString('o')
      $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue $newTotalRestartCount -Force
      $s | Add-Member -NotePropertyName task_apply_restart_count -NotePropertyValue $newApplyRestartCount -Force
      $s | Add-Member -NotePropertyName task_hard_restart_count -NotePropertyValue $newHardRestartCount -Force
      $s | Add-Member -NotePropertyName task_restart_total_count -NotePropertyValue $newTotalRestartCount -Force
      $s | Add-Member -NotePropertyName task_last_restart_kind -NotePropertyValue $(if ($isTrustedApplyRestart) { 'apply' } else { 'hard' }) -Force
      $s | Add-Member -NotePropertyName task_last_restart_stamp_reason -NotePropertyValue $(if ($applyStamp -and $applyStamp.reason) { [string]$applyStamp.reason } else { '' }) -Force
      $s | Add-Member -NotePropertyName task_restart_root_cause_class -NotePropertyValue $restartRootCauseClass -Force
    } | Out-Null
    $remainingByKind = if ($isTrustedApplyRestart) { $maxApplyRestarts - $newApplyRestartCount } else { $maxHardRestarts - $newHardRestartCount }
    $remainingByTotal = $maxTotalRestarts - $newTotalRestartCount
    $remaining = [Math]::Min($remainingByKind, $remainingByTotal)
    $tail = if ($remaining -le 0) { '' } else { " (осталось $remaining попыток до auto-fail)" }
    if ($restartBudgetResetByVerifiedRepair) {
      Add-Message -From system -Text "🩺 Apply restart-budget сброшен: найден verified repair marker после task_start; hard/total safety caps не сброшены." -Kind event | Out-Null
    }
    $restartKindText = if ($isTrustedApplyRestart) { 'trusted apply-stamp' } else { 'hard/untrusted restart: ' + $(if ($applyStamp -and $applyStamp.reason) { [string]$applyStamp.reason } else { 'missing-stamp' }) }
    Add-Message -From system -Text ("♻ Мост перезапущен — возобновляю прерванную задачу (" + $restartKindText + "; apply=" + $newApplyRestartCount + "/" + $maxApplyRestarts + ", hard=" + $newHardRestartCount + "/" + $maxHardRestarts + ", total=" + $newTotalRestartCount + "/" + $maxTotalRestarts + ")." + $tail) -Kind event | Out-Null
    try {
      $rrLogPath = Join-Path (Get-DecisionsPath) 'restart-root-cause-log.jsonl'
      $rrEntry = [ordered]@{
        ts = (Get-Date).ToString('o')
        class = $restartRootCauseClass
        kind = if ($isTrustedApplyRestart) { 'apply' } else { 'hard' }
        stamp_reason = if ($applyStamp -and $applyStamp.reason) { [string]$applyStamp.reason } else { '' }
        stamp_root_cause_class = if ($applyStamp -and ($applyStamp.PSObject.Properties.Name -contains 'restart_root_cause_class')) { [string]$applyStamp.restart_root_cause_class } else { '' }
        apply_count = $newApplyRestartCount
        hard_count = $newHardRestartCount
        total_count = $newTotalRestartCount
        task_id = $resumeTaskId
      }
      $rrJson = $rrEntry | ConvertTo-Json -Compress
      [System.IO.File]::AppendAllText($rrLogPath, $rrJson + "`n", [System.Text.Encoding]::UTF8)
    } catch {}
  }
} else {
  Update-State {
    param($s)
    $s.status='idle'; $s.stop=$false; $s.abort=$false
    $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.current_agent=$null; $s.current_agent_pid=0; $s.current_agent_ticks=0; $s.current_agent_since=$null; $s.agent_telemetry=$null
    $s.current_task=$null; $s.current_task_id=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Reset-TaskAgentDuration $s; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s; Clear-ChunkingState $s
    $s | Add-Member -NotePropertyName codex_evidence_retry_count -NotePropertyValue 0 -Force
    $s | Add-Member -NotePropertyName task_apply_restart_count -NotePropertyValue 0 -Force
    $s | Add-Member -NotePropertyName task_hard_restart_count -NotePropertyValue 0 -Force
    $s | Add-Member -NotePropertyName task_restart_total_count -NotePropertyValue 0 -Force
    $s.driver_started=(Get-Date).ToString('o'); $s.heartbeat=(Get-Date).ToString('o')
  } | Out-Null
  Add-Message -From system -Text "Интерактивный режим запущен. Полный доступ к ПК. Жду задачу от тебя в чате…" -Kind event | Out-Null
  # 2026-05-27v6: startup cleanup tasks (P0/P3 audit findings):
  #   - Sweep orphan *.tmp.* files (was 100+ leak from silent Remove failures)
  #   - Merge any *.unflushed sidecars from failed Add-Message writes
  try {
    $sweep = Sweep-OrphanTmpFiles -MinAgeMin 60
    if ($sweep -and (([int]$sweep.cleaned -gt 0) -or ([int]$sweep.failed -gt 0))) {
      $stuckPart = if ([int]$sweep.failed -gt 0) { ", " + $sweep.failed + " stuck (see control/tmp-leak.log)" } else { '' }
      Add-Message -From system -Text ("🧹 Tmp-sweep on startup: cleaned " + $sweep.cleaned + " orphan .tmp files" + $stuckPart) -Kind event | Out-Null
    }
  } catch {}
  # 2026-05-28: orphan git-worktree janitor. Parallel-worker worktrees whose teardown ran
  # under OneDrive readonly-reparse locks leave .git/worktrees/<name> metadata that git's
  # auto-gc can't prune ("failed to delete ...: Permission denied" on every commit).
  # Self-heal: force-remove admin dirs that no longer map to a live worktree.
  try {
    $wtClean = Clear-OrphanWorktrees -RepoRoot (Get-BridgeRoot)
    if ([int]$wtClean -gt 0) {
      Add-Message -From system -Text ("🧹 Worktree-janitor: removed " + $wtClean + " orphaned .git/worktrees entries.") -Kind event | Out-Null
    }
  } catch {}
  try {
    $unflush = Merge-UnflushedSidecars
    if ($unflush -and [int]$unflush.sidecars -gt 0) {
      Add-Message -From system -Text ("📥 Восстановлено " + $unflush.merged + " потерянных строк из " + $unflush.sidecars + " sidecar-файлов (сообщения, не дописанные в прошлый рестарт).") -Kind event | Out-Null
    }
  } catch {}
  # 2026-05-27v7: zombie-job recovery (audit deferred -- but came up live with
  # be073b57/774d71ed visit.ps1 jobs stuck after restart). At startup, re-check
  # active_jobs in state: if PID is dead and no .done marker -- write fake .done
  # with exit=-1 so polling loop closes them next iteration. Without this, driver
  # waits jobMaxH (6h default) blocking ALL new user tasks meanwhile.
  try {
    $bootState = Read-State
    $bootJobs = @()
    try { if ($bootState.PSObject.Properties.Name -contains 'active_jobs') { $bootJobs = @($bootState.active_jobs) } } catch {}
    if ($bootJobs.Count -gt 0) {
      $recovered = 0
      foreach ($bj in $bootJobs) {
        $jp = 0; try { $jp = [int]$bj.pid } catch {}
        $alive = $false
        if ($jp -gt 0) {
          try {
            $bp = Get-Process -Id $jp -ErrorAction SilentlyContinue
            if ($bp) {
              $ticks = 0L; try { $ticks = [long]$bj.startTicks } catch {}
              if ($ticks -le 0) { $alive = $true }
              else { try { if ($bp.StartTime.Ticks -eq $ticks) { $alive = $true } } catch {} }
            }
          } catch {}
        }
        if (-not $alive) {
          # Write a .done marker so the polling loop's Test-JobDone returns true.
          # exit-code -1 indicates "process died, no clean exit" — orphan classification.
          $jobsDir = Join-Path (Get-BridgeRoot) 'jobs'
          $donePath = Join-Path $jobsDir (([string]$bj.id) + '.done')
          try {
            if (-not (Test-Path -LiteralPath $donePath)) {
              [System.IO.File]::WriteAllText($donePath, '-1', (New-Object System.Text.UTF8Encoding($false)))
              $recovered++
            }
          } catch {}
        }
      }
      if ($recovered -gt 0) {
        Add-Message -From system -Text ("⚠ Zombie-jobs recovered: " + $recovered + " фоновых задач после рестарта помечены как orphan (процесс умер до записи .done). Драйвер не залипнет в ожидании.") -Kind event | Out-Null
      }
    }
  } catch {}
}

# Doctor restart-loop guard (FIX: 2026-05-26).
# Bug: when Codex (as Doctor's coder) edited a .ps1 and set restart.flag, the bridge
# restarted, Doctor stayed active (doctor_active=true, current_task=<doctor task>), but
# restart loops were not counted when current_task was non-empty. Result: infinite restart
# loop, Codex never committed, working tree accumulated changes. This guard counts driver
# startups-while-Doctor-active separately from repair attempts, so a legitimate restart no
# longer consumes the Doctor's repair budget.
#
# 2026-05-26 incident: 6 restarts in 10 min while Doctor was "in progress" -- user had to
# kill the bridge manually. Save Codex's pending edits to a stash branch first if you see
# the loop happening again (changes are recoverable via `git stash list`).
try {
  $startupState = Read-State
  try {
    if ($startupState) {
      $_bootCh = if ($startupState.current_channel) { [string]$startupState.current_channel } else { $Channel }
      $_lastSnap = Get-LastSnapshot -Channel $_bootCh
      if ($_lastSnap -and [string]::IsNullOrWhiteSpace([string]$startupState.held_task) -and [string]::IsNullOrWhiteSpace([string]$startupState.current_task)) {
        $_snapAge = ((Get-Date) - (Get-Item $_lastSnap).LastWriteTime).TotalMinutes
        if ($_snapAge -lt 60) {
          try { Add-Message -From system -Text ("♻ Снимок state до рестарта (<60мин): " + $_lastSnap + ". Если задача потеряна — снимок содержит прежний контекст.") -Kind event | Out-Null } catch {}
        }
      }
    }
  } catch {}
  if ([bool]$startupState.doctor_active) {
    $prevRestartCount = Get-DoctorRestartCount -State $startupState
    $newRestartCount = $prevRestartCount + 1
    $maxRestartsWhileDoctor = Get-DoctorMaxRestartResumes
    $repairAttempt = Get-DoctorRepairAttemptCount -State $startupState
    $maxRepairAttempts = Get-DoctorMaxRepairAttempts
    Update-State {
      param($s)
      $s | Add-Member -NotePropertyName doctor_restart_count -NotePropertyValue $newRestartCount -Force
    } | Out-Null
    Add-Message -From system -Text ("🩺 Доктор резюмирован после рестарта (рестарт " + $newRestartCount + "/" + $maxRestartsWhileDoctor + "; repair-попытка " + $repairAttempt + "/" + $maxRepairAttempts + ").") -Kind event | Out-Null
    if ($newRestartCount -ge $maxRestartsWhileDoctor) {
      # Restart loop -- abort Doctor cleanly + restore held_task so the operator sees what
      # was running. Doctor's prompt may have generated useful diagnostic memories; those
      # stay in long-term memory regardless.
      $held = [string]$startupState.held_task
      $reason = [string]$startupState.doctor_reason
      # 2026-06-11 freeze-audit wave1 atom2 (mirror of Abort-Doctor): requeue the suspended
      # backlog item as 'held' with a reason instead of parking it in a state dead-end the
      # operator had to untangle by hand. No auto-resume (avoids the loop chain this guard
      # exists for); the queue stays free and the task is never lost.
      $heldBid = ''
      try { $heldBid = [string]$startupState.current_backlog_id } catch {}
      $heldRequeued = $false
      if (-not [string]::IsNullOrWhiteSpace($heldBid) -and (Get-Command Set-Idea -ErrorAction SilentlyContinue)) {
        try { $heldRequeued = [bool](Set-Idea -Id $heldBid -Status 'held' -Reason ('doctor-restart-loop: ' + $reason)) } catch { $heldRequeued = $false }
      }
      Update-State ({
        param($s)
        $s.doctor_active = $false
        $s.doctor_attempts = 0
        $s | Add-Member -NotePropertyName doctor_repair_attempts -NotePropertyValue 0 -Force
        $s | Add-Member -NotePropertyName doctor_restart_count -NotePropertyValue 0 -Force
        $s | Add-Member -NotePropertyName doctor_repair_task_id -NotePropertyValue '' -Force
        $s | Add-Member -NotePropertyName doctor_hold_head -NotePropertyValue '' -Force
        $s | Add-Member -NotePropertyName doctor_held_base_commit -NotePropertyValue '' -Force
        $s.doctor_reason = ''
        $s.doctor_started_at = $null
        Close-ReplayForStateTask -State $s -Status 'aborted'
        $s.current_task = $null    # operator will re-submit / inspect; don't auto-resume held_task to avoid loop chain
        if ($heldRequeued) { $s.held_task = $null; $s.current_backlog_id = $null }
        else { $s.held_task = $held }   # fallback: keep for the operator-visible event below
        $s.task_turn = 0
        $s.task_mode = 'normal'
        Clear-AuditorSuppressedHashes -State $s
        Clear-FastLaneFlags $s
        $s.status = 'idle'
        $s.active_agent = $null
        $s.active_model = $null
        $s.status_text = $null
      }.GetNewClosure()) | Out-Null
      $snip = $held; if ($snip.Length -gt 80) { $snip = $snip.Substring(0,80) + '...' }
      if ($heldRequeued) {
        $bidSnip = $heldBid; if ($bidSnip.Length -gt 8) { $bidSnip = $bidSnip.Substring(0,8) }
        Add-Message -From system -Text ("⚠ Доктор отменён: restart-loop ($newRestartCount рестартов при reason='" + $reason + "'). Задача " + $bidSnip + " возвращена в backlog (held, reason=doctor-restart-loop) — конвейер свободен. Codex-правки в stash (git stash list).") -Kind event | Out-Null
      } else {
        Add-Message -From system -Text ("⚠ Доктор отменён: restart-loop ($newRestartCount рестартов мостa при reason='" + $reason + "'). Приостановленная задача: «" + $snip + "» — оператор, проверь рабочее дерево (git status / git stash list) и при необходимости перепиши задачу.") -Kind event | Out-Null
      }
    }
  }
} catch {}
}
