function Test-DriverBatchForcesClaudeSpeaker {
  # 2026-07-02 audit fix (turn-0 speaker misroute): a claimed PARALLEL workpack-batch task must be
  # routed to the claude planner path at turn 0 -- that path owns the deterministic parallel
  # dispatch block. Without this guard the codex fast paths (skip_planner / Test-DirectCoderTask)
  # can grab the batch and one codex turn executes the whole N-atom batch INLINE in the main tree,
  # after which the parallel dispatch re-executes everything in worktrees (duplicate work,
  # touch-set conflicts). Pure predicate: no state reads/writes, testable in isolation.
  param($State, [int]$TaskTurn = 0)
  if ($TaskTurn -ne 0) { return $false }
  if ($null -eq $State) { return $false }
  $batchActive = $false; $batchMode = ''; $batchDispatched = $false
  try { $batchActive = [bool]$State.workpack_batch_active } catch {}
  try { $batchMode = [string]$State.workpack_batch_mode } catch {}
  try { $batchDispatched = [bool]$State.workpack_batch_dispatched } catch {}
  return ($batchActive -and ($batchMode -ne 'serial') -and (-not $batchDispatched))
}

$script:DriverLoopTurnSetupBlock = {
  $task = [string]$state.current_task
  $tt   = [int]$state.task_turn
  $mode = if ($state.task_mode) { [string]$state.task_mode } else { 'normal' }
  $forcePlanner = [bool]$state.force_planner
  $forceCoder = $false
  try { $forceCoder = [bool]$state.force_coder } catch {}
  $skipPlanner = [bool]$state.skip_planner
  # 2026-07-02 audit fix: active undispatched parallel workpack batch must land on the claude
  # planner path (it contains the deterministic dispatch block). Guard sits ABOVE both codex
  # fast-path branches below.
  $batchForcesClaude = $false
  try {
    $batchGuardState = $null
    try { $batchGuardState = Read-State } catch {}
    if ($null -eq $batchGuardState) { $batchGuardState = $state }
    $batchForcesClaude = [bool](Test-DriverBatchForcesClaudeSpeaker -State $batchGuardState -TaskTurn $tt)
  } catch {}
  $speaker = if ($forceCoder) { 'codex' }
              elseif ($forcePlanner) { 'claude' }
              elseif ($mode -eq 'synthesis') { 'claude' }
              elseif ($mode -eq 'research') { 'claude' }
              elseif ($mode -eq 'study') { Get-StudySpeaker -TaskTurn $tt -StudySubtype ([string]$state.study_subtype) -StudyPhase ([string]$state.study_phase) }
              elseif ($batchForcesClaude) { 'claude' }
              elseif ($skipPlanner -and $mode -eq 'normal' -and $tt -eq 0) { 'codex' }
              elseif ($tt -eq 0 -and $mode -eq 'normal' -and (Test-DirectCoderTask -TaskText $task)) { 'codex' }
              elseif ($tt -eq 0) { 'claude' }
              else { Next-Speaker }
  if ($forcePlanner) { Update-State { param($s) $s.force_planner=$false } | Out-Null }
  if ($forceCoder) { Update-State { param($s) $s.force_coder=$false } | Out-Null }
  $plannerEscalate = $false
  try { $plannerEscalate = ([int](Read-State).timeout_retry_count -ge 1) } catch {}
  $plannerModel = Select-PlannerModel -TaskText $task -Mode $mode -Escalate $plannerEscalate
  $activeModel  = if ($mode -eq 'synthesis') { 'decision-synthesis' } elseif ($speaker -eq 'claude') { $plannerModel } else { 'codex' }
  $statusText   = Get-AgentStatusText -Speaker $speaker -Mode $mode -TaskText $task
  Update-State ({ param($s) $s.active_agent=$speaker; $s.active_model=$activeModel; $s.status_text=$statusText; $s.status='working'; $s.claimed_at=(Get-Date).ToString('o'); $s.heartbeat=(Get-Date).ToString('o') }.GetNewClosure()) | Out-Null

  $fastLaneTurn = ($speaker -eq 'codex' -and $mode -eq 'normal' -and [bool](Read-State).skip_planner)
  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'summary' -TaskText $task)
  if (-not $fastLaneTurn -and $mode -ne 'synthesis') { Update-ContextSummary }   # synthesis builds stateless artifacts; no prompt history needed
  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'prompt' -TaskText $task)
  $prompt = if ($mode -eq 'synthesis') { '' } else { Build-Prompt -Role $speaker -Task $task -Mode $mode -FastLane:$fastLaneTurn }
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
