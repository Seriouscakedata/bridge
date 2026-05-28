# lib/foundry.ps1 -- Project Foundry: the DAG executor that drives a plan to done,
# plus (later) the New-Project pipeline. Depends on lib/plan.ps1 (Get-PlanScheduleState,
# Get-ReadyPlanSteps, Set-PlanStepStatus, Normalize-PlanStatus).

$ErrorActionPreference = 'Stop'

function Get-RunnerField {
  # Read a field from a BatchRunner result that may be EITHER a hashtable
  # (@{ id=..; ok=.. }) or a pscustomobject. Get-PlanProperty only handles
  # pscustomobjects (hashtable keys aren't surfaced via .PSObject.Properties),
  # so the executor needs this to accept the natural @{...} the contract shows.
  param($Obj, [string]$Name, $Default = $null)
  if ($null -eq $Obj) { return $Default }
  if ($Obj -is [System.Collections.IDictionary]) {
    if ($Obj.Contains($Name)) { return $Obj[$Name] }
    return $Default
  }
  if ($Obj.PSObject -and $Obj.PSObject.Properties[$Name]) { return $Obj.$Name }
  return $Default
}

function Invoke-PlanDag {
  # Wave-based DAG executor. Each wave: read the schedule state; if the plan is
  # complete or can no longer advance, stop; otherwise take the ready frontier
  # (capped at MaxParallel), mark those steps in_progress, hand the whole batch
  # to $BatchRunner (which runs them concurrently and returns per-step results),
  # then write each step's terminal status. Repeat until drained.
  #
  # The executor is deliberately agnostic to HOW a step runs: $BatchRunner owns
  # the real work (spawn a worker in a git worktree, merge, verify/critic gate,
  # git-revert on failure). That keeps this scheduling brain unit-testable with a
  # simulated runner, and lets production swap in the parallel-worker engine.
  #
  # $BatchRunner contract:
  #   param([object[]]$Steps)   # each: plan node {id,title,criteria,parent,deps,...}
  #   returns an array of result objects, one per step it ran:
  #     @{ id=<step id>; ok=<bool>; status=<'done'|'blocked'|'skipped'>(optional); result=<string> }
  #   - if 'status' is present it wins (coerced to a terminal status);
  #     otherwise the status is 'done' when ok=$true else 'blocked'.
  #   - a step the runner does not report back is marked 'blocked' (fail-closed),
  #     so a misbehaving runner can never wedge the executor in an infinite loop.
  #
  # Returns a summary: @{ outcome; waves; done; blocked; skipped; deadlocked;
  #                       blockers; log }.
  param(
    [Parameter(Mandatory = $true)][scriptblock]$BatchRunner,
    [int]$MaxParallel = 2,
    [int]$MaxWaves = 200,
    [scriptblock]$OnWave = $null
  )
  if ($MaxParallel -lt 1) { $MaxParallel = 1 }
  $waves = 0
  $log = New-Object 'System.Collections.Generic.List[object]'

  while ($true) {
    $st = Get-PlanScheduleState

    if ($st.reason -eq 'no-plan') {
      return [pscustomobject][ordered]@{ outcome='empty'; waves=$waves; done=0; blocked=0; skipped=0; deadlocked=$false; blockers=@{}; log=@($log.ToArray()) }
    }
    if ($st.complete) {
      # No pending/in_progress left. 'complete' only if nothing failed; if some
      # steps are terminally blocked (a failed leaf with no dependents to stall),
      # report 'partial' so callers can decide whether to re-plan or roll back.
      $outcome = if ($st.blocked -gt 0) { 'partial' } else { 'complete' }
      return [pscustomobject][ordered]@{ outcome=$outcome; waves=$waves; done=$st.done; blocked=$st.blocked; skipped=$st.skipped; deadlocked=$false; blockers=$st.blockers; log=@($log.ToArray()) }
    }
    if ($st.deadlocked) {
      return [pscustomobject][ordered]@{ outcome='deadlocked'; waves=$waves; done=$st.done; blocked=$st.blocked; skipped=$st.skipped; deadlocked=$true; blockers=$st.blockers; log=@($log.ToArray()) }
    }

    $batch = @(Get-ReadyPlanSteps -Max $MaxParallel)
    if ($batch.Count -eq 0) {
      # Not complete, not deadlocked, yet nothing runnable: only possible if steps
      # are stuck in_progress (e.g. an earlier crash). Fail-closed rather than spin.
      return [pscustomobject][ordered]@{ outcome='stalled'; waves=$waves; done=$st.done; blocked=$st.blocked; skipped=$st.skipped; deadlocked=$false; blockers=$st.blockers; log=@($log.ToArray()) }
    }
    if ($waves -ge $MaxWaves) {
      return [pscustomobject][ordered]@{ outcome='wave-cap'; waves=$waves; done=$st.done; blocked=$st.blocked; skipped=$st.skipped; deadlocked=$false; blockers=$st.blockers; log=@($log.ToArray()) }
    }

    $waves++
    $batchIds = @($batch | ForEach-Object { [string]$_.id })
    foreach ($id in $batchIds) { [void](Set-PlanStepStatus -Id $id -Status 'in_progress') }

    $results = @()
    $runnerError = $null
    try { $results = @(& $BatchRunner $batch) }
    catch { $runnerError = $_.Exception.Message }

    if ($null -ne $runnerError) {
      # Runner threw: mark the whole wave blocked so dependents cascade cleanly
      # and we don't re-dispatch the same batch forever.
      foreach ($id in $batchIds) { [void](Set-PlanStepStatus -Id $id -Status 'blocked' -Result ("runner error: " + $runnerError)) }
      [void]$log.Add([pscustomobject][ordered]@{ wave=$waves; ids=$batchIds; error=$runnerError })
      if ($null -ne $OnWave) { try { & $OnWave ([pscustomobject]@{ wave=$waves; ids=$batchIds; error=$runnerError }) } catch {} }
      continue
    }

    $byId = @{}
    foreach ($r in @($results)) {
      if ($null -eq $r) { continue }
      $rid = [string](Get-RunnerField $r 'id' '')
      if (-not [string]::IsNullOrWhiteSpace($rid)) { $byId[$rid] = $r }
    }

    $waveOutcomes = @{}
    foreach ($id in $batchIds) {
      $r = $byId[$id]
      if ($null -eq $r) {
        [void](Set-PlanStepStatus -Id $id -Status 'blocked' -Result 'no result from runner')
        $waveOutcomes[$id] = 'blocked'
        continue
      }
      $rawStatus = [string](Get-RunnerField $r 'status' '')
      if ([string]::IsNullOrWhiteSpace($rawStatus)) {
        $ok = [bool](Get-RunnerField $r 'ok' $false)
        $rawStatus = if ($ok) { 'done' } else { 'blocked' }
      }
      $status = Normalize-PlanStatus $rawStatus
      # Coerce any non-terminal verdict to 'blocked' so the executor always
      # makes progress (a runner must not leave a step pending/in_progress).
      if ($status -ne 'done' -and $status -ne 'blocked' -and $status -ne 'skipped') { $status = 'blocked' }
      $resultText = [string](Get-RunnerField $r 'result' '')
      [void](Set-PlanStepStatus -Id $id -Status $status -Result $resultText)
      $waveOutcomes[$id] = $status
    }

    [void]$log.Add([pscustomobject][ordered]@{ wave=$waves; ids=$batchIds; outcomes=$waveOutcomes })
    if ($null -ne $OnWave) { try { & $OnWave ([pscustomobject]@{ wave=$waves; ids=$batchIds; outcomes=$waveOutcomes }) } catch {} }
  }
}
