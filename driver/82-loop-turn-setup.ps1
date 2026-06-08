$script:DriverLoopTurnSetupBlock = {
  $task = [string]$state.current_task
  $tt   = [int]$state.task_turn
  $mode = if ($state.task_mode) { [string]$state.task_mode } else { 'normal' }
  $forcePlanner = [bool]$state.force_planner
  $forceCoder = $false
  try { $forceCoder = [bool]$state.force_coder } catch {}
  $skipPlanner = [bool]$state.skip_planner
  $speaker = if ($forceCoder) { 'codex' }
              elseif ($forcePlanner) { 'claude' }
              elseif ($mode -eq 'research') { 'claude' }
              elseif ($mode -eq 'study') { Get-StudySpeaker -TaskTurn $tt -StudySubtype ([string]$state.study_subtype) -StudyPhase ([string]$state.study_phase) }
              elseif ($skipPlanner -and $mode -eq 'normal' -and $tt -eq 0) { 'codex' }
              elseif ($tt -eq 0 -and $mode -eq 'normal' -and (Test-DirectCoderTask -TaskText $task)) { 'codex' }
              elseif ($tt -eq 0) { 'claude' }
              else { Next-Speaker }
  if ($forcePlanner) { Update-State { param($s) $s.force_planner=$false } | Out-Null }
  if ($forceCoder) { Update-State { param($s) $s.force_coder=$false } | Out-Null }
  $plannerEscalate = $false
  try { $plannerEscalate = ([int](Read-State).timeout_retry_count -ge 1) } catch {}
  $plannerModel = Select-PlannerModel -TaskText $task -Mode $mode -Escalate $plannerEscalate
  $activeModel  = if ($speaker -eq 'claude') { $plannerModel } else { 'codex' }
  $statusText   = Get-AgentStatusText -Speaker $speaker -Mode $mode -TaskText $task
  Update-State ({ param($s) $s.active_agent=$speaker; $s.active_model=$activeModel; $s.status_text=$statusText; $s.status='working'; $s.claimed_at=(Get-Date).ToString('o'); $s.heartbeat=(Get-Date).ToString('o') }.GetNewClosure()) | Out-Null

  $fastLaneTurn = ($speaker -eq 'codex' -and $mode -eq 'normal' -and [bool](Read-State).skip_planner)
  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'summary' -TaskText $task)
  if (-not $fastLaneTurn) { Update-ContextSummary }   # compress old history if it grew beyond the hot window
  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'prompt' -TaskText $task)
  $prompt = Build-Prompt -Role $speaker -Task $task -Mode $mode -FastLane:$fastLaneTurn
  try {
    $stForCheckpoint = Read-State
    $checkpointTaskId = Get-TaskCheckpointIdFromState -State $stForCheckpoint
    if (-not [string]::IsNullOrWhiteSpace($checkpointTaskId)) {
      $restoreCheckpoint = Read-TaskCheckpoint -TaskId $checkpointTaskId -Channel $Channel
      $restoreText = Format-TaskCheckpointRestoreText -Checkpoint $restoreCheckpoint
      if (-not [string]::IsNullOrWhiteSpace($restoreText) -and $prompt -notmatch '=== TASK CHECKPOINT/RESTORE ===') {
        $prompt = $prompt + "`n`n" + $restoreText
      }
    }
    $checkpointDue = Test-TaskCheckpointDue -State $stForCheckpoint -IntervalMinutes 5 -Force:($tt -eq 0)
    if ($checkpointDue) {
      $contextForCheckpoint = ''
      try { $contextForCheckpoint = [string](Read-Summary) } catch {}
      Save-TaskCheckpointFromState -State $stForCheckpoint -TaskTitle $task -Channel $Channel -Reason 'before-agent' -Prompt $prompt -Context $contextForCheckpoint | Out-Null
      Update-State { param($s) $s | Add-Member -NotePropertyName last_task_checkpoint_at -NotePropertyValue (Get-Date).ToString('o') -Force } | Out-Null
    }
  } catch {
    try { Write-TaskCheckpointLog -BridgeRoot $bridgeRoot -Message ('before-agent-checkpoint-error: ' + $_.Exception.Message) } catch {}
  }
  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'invoke' -TaskText $task)
  $turnStart = [DateTime]::UtcNow
  $headBeforeTurn = ''
  try { $headBeforeTurn = (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch {}
  # FIX 2026-05-29: snapshot the dirty set BEFORE the turn so the project-focus guard below can
  # compare the DELTA of this turn, not the absolute dirty tree. main + non-main channels share
  # ONE bridge git tree -> without this, a non-main guard fired on files MAIN changed in parallel
  # (false halt of a clean travel audit while main legitimately edited the bridge).
  $dirtyBeforeTurn = @()
  try { $dirtyBeforeTurn = @(& git -C $bridgeRoot diff --name-only HEAD 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) } catch {}
  # 2026-06-01 (Foundation #4 scale): DETERMINISTIC parallel dispatch for a workpack-batch on a
  # PROJECT channel. The batch task text already carries ready [[PARALLEL]] blocks (built by
  # New-BacklogWorkpackBatchTaskText); dispatch them straight to the worker pool BEFORE the planner
  # runs -- otherwise the planner inlines small independent tasks in a single turn (no parallelism,
  # observed: 20 tasks done serially, worktrees=1). This guarantees up to N concurrent worktree
  # workers. On success we synthesize a DONE turn so verify/critic gates run on the merged result.
  $turnResult = $null
}
