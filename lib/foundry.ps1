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

# ===========================================================================
# Production step runner: the REAL $BatchRunner that Invoke-PlanDag drives.
#
# Each plan step becomes an isolated worker in its OWN git worktree of the
# target PROJECT repo. The result is gated (worker reported 'done' + produced
# commits, plus an optional caller-supplied verify/critic gate) and then MERGED
# back on pass or DISCARDED on fail. Discard == rollback: rejected work lives
# only on the throwaway worktree branch, so the repo's real branch never sees
# it -- no git reset/revert needed, the bad work is simply never merged.
#
# Steps inside one batch are exactly one DAG wave => mutually independent, so we
# launch them ALL, await the whole batch once, then gate+merge SEQUENTIALLY
# (merges must serialize to stay conflict-safe -- same discipline as
# Invoke-ParallelDispatch).
#
# All subprocess/git plumbing is injected via $Ops so the orchestration (batch
# lifecycle, gating, rollback-vs-merge, result shaping) is unit-testable with a
# simulated runner. Production callers pass -RepoRoot and Get-FoundryDefaultOps
# wires the real worktree-worker engine (lib/parallel.ps1 + lib/worktrees.ps1).
#
# $Ops contract (every value is a scriptblock):
#   Prepare : { param($Step)     -> @{ ok=<bool>; ctx=<opaque>; error=<string> } }
#               create the worktree + spawn the worker; ctx is threaded to the
#               other ops untouched (it carries whatever Prepare needs later).
#   Await   : { param($Contexts) -> $null }   block until every ctx's worker is
#               terminal (or a timeout fires and kills the stragglers).
#   Result  : { param($Ctx)      -> @{ status=<string>; reply=<string>; commits=@() } }
#   Merge   : { param($Ctx)      -> @{ ok=<bool>; conflict=<bool> } }
#   Cleanup : { param($Ctx)      -> $null }   tear down worktree+branch; called
#               on EVERY prepared step, pass or fail (idempotent).
#
# $Verify (the gate): { param($Step,$Ctx,$Result) -> @{ ok=<bool>; reason=<string> } }
#   Default = Test-FoundryStepResult (structural only, no LLM cost): pass iff the
#   worker reported terminal 'done' AND produced >=1 commit.
# ===========================================================================

function Format-FoundryTail {
  # Collapse whitespace and keep only the trailing $Max chars of a worker reply,
  # prefixed with ': ', for embedding in a one-line step result string.
  param([string]$Text, [int]$Max = 160)
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $t = (([string]$Text).Trim() -replace '\s+', ' ')
  if ($t.Length -gt $Max) { $t = '...' + $t.Substring($t.Length - $Max) }
  return ': ' + $t
}

function Get-FoundryStepBody {
  # Compose the worker instruction body for a plan step: title + acceptance
  # criteria. Kept separate so both the runner and its tests can reason about it.
  param($Step)
  $title = [string](Get-RunnerField $Step 'title' '')
  $criteria = [string](Get-RunnerField $Step 'criteria' '')
  $sb = New-Object System.Text.StringBuilder
  if (-not [string]::IsNullOrWhiteSpace($title)) { [void]$sb.AppendLine($title) }
  if (-not [string]::IsNullOrWhiteSpace($criteria)) {
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Acceptance criteria:')
    [void]$sb.AppendLine($criteria)
  }
  $text = $sb.ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { $text = [string](Get-RunnerField $Step 'id' 'step') }
  return $text
}

function Test-FoundryStepResult {
  # Default verify gate: STRUCTURAL only (no LLM cost). A step passes iff the
  # worker reported terminal 'done' AND actually produced >=1 commit on its
  # branch. Everything else fails closed. Richer gates (run a verify command in
  # the worktree, call a critic model) are layered by passing a custom -Verify
  # scriptblock to New-FoundryStepRunner.
  param($Step, $Ctx, $Result)
  $status = [string](Get-RunnerField $Result 'status' '')
  if ($status -ne 'done') { return @{ ok = $false; reason = ('worker status=' + $status) } }
  $commits = @(Get-RunnerField $Result 'commits' @())
  if ($commits.Count -lt 1) { return @{ ok = $false; reason = 'worker reported done but produced no commits' } }
  return @{ ok = $true; reason = '' }
}

function Get-FoundryDefaultOps {
  # Wire the REAL plumbing for New-FoundryStepRunner against a project repo.
  # Returns the $Ops hashtable (Prepare/Await/Result/Merge/Cleanup). Refuses the
  # bridge's own repo: self-modification must stay serial/safe and never flow
  # through throwaway parallel worktree workers.
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [int]$TimeoutMin = 25,
    [int]$PollSec = 10
  )
  $repo = [string]$RepoRoot
  if ([string]::IsNullOrWhiteSpace($repo) -or -not (Test-Path (Join-Path $repo '.git'))) {
    throw ('Get-FoundryDefaultOps: not a git repo: ' + $repo)
  }
  try {
    $bridge = [System.IO.Path]::GetFullPath((Get-BridgeRoot)).TrimEnd('\')
    if ([System.IO.Path]::GetFullPath($repo).TrimEnd('\') -eq $bridge) {
      throw 'Get-FoundryDefaultOps: refusing to run the Foundry DAG against the bridge repo itself'
    }
  } catch {
    if ($_.Exception.Message -like '*refusing*') { throw }
  }

  $tmin = $TimeoutMin
  $psec = $PollSec
  $ops = @{}

  $ops['Prepare'] = {
    param($Step)
    $sid = [string](Get-RunnerField $Step 'id' '')
    if ([string]::IsNullOrWhiteSpace($sid)) { return @{ ok = $false; error = 'step has no id' } }
    $wt = New-Worktree -RepoRoot $repo -Name ('foundry-' + $sid)
    if (-not $wt) { return @{ ok = $false; error = 'worktree create failed' } }
    # Pin the PROJECT-repo HEAD the worktree branched from, so the Result Op can
    # count commits as base..branch INSIDE this repo. Do NOT rely on
    # Get-WorkerCommits -- it is hardcoded to the bridge repo and returns nothing
    # for a project worktree branch (would gate every committed step as "no commits").
    $baseSha = ''
    try { $baseSha = ((& (Get-GitExe) -C $repo rev-parse HEAD 2>$null) | Select-Object -First 1).Trim() } catch {}
    $body = Get-FoundryStepBody $Step
    $complexity = [string](Get-RunnerField $Step 'complexity' 'moderate')
    $stream = [pscustomobject]@{ id = $sid; files = @(); complexity = $complexity; body = $body; opus = $false }
    $spec = $null
    try { $spec = Select-WorkerForStream -Stream $stream } catch {}
    if (-not $spec) { $pool = @(Get-ParallelWorkerPool); if ($pool.Count -gt 0) { $spec = $pool[0] } }
    if (-not $spec) { Remove-Worktree $wt; return @{ ok = $false; error = 'no worker available' } }
    $worker = $null
    try { $worker = Spawn-Worker -StreamId $sid -Body $body -Worktree $wt.path -BranchName $wt.branch -WorkerSpec $spec -HostManagedCommit }
    catch { Remove-Worktree $wt; return @{ ok = $false; error = ('spawn: ' + $_.Exception.Message) } }
    return @{ ok = $true; ctx = @{ sid = $sid; wt = $wt; worker = $worker; baseSha = $baseSha } }
  }.GetNewClosure()

  $ops['Await'] = {
    param($Contexts)
    $cs = @($Contexts)
    if ($cs.Count -eq 0) { return }
    $deadline = (Get-Date).AddMinutes($tmin)
    while ($true) {
      $alive = 0
      foreach ($c in $cs) {
        $r = Get-WorkerResult $c.worker
        if ([string](Get-RunnerField $r 'status' '') -eq 'running') { $alive++ }
      }
      if ($alive -eq 0) { break }
      if ((Get-Date) -ge $deadline) {
        foreach ($c in $cs) {
          $w = $c.worker
          try { if ($w.process -and -not $w.process.HasExited) { Start-Process taskkill -ArgumentList '/PID', ([string]$w.pid), '/F', '/T' -NoNewWindow -Wait -ErrorAction SilentlyContinue } } catch {}
        }
        break
      }
      Start-Sleep -Seconds $psec
    }
  }.GetNewClosure()

  $ops['Result'] = {
    param($Ctx)
    # status/reply from the worker are fine (parsed from its STATUS line, not
    # bridge-coupled). commits MUST be recomputed against the PROJECT repo:
    # Get-WorkerResult delegates to Get-WorkerCommits, which queries the bridge
    # repo and so always returns empty for a project worktree branch.
    $r = Get-WorkerResult $Ctx.worker
    $branch = ''
    try { $branch = [string]$Ctx.wt.branch } catch {}
    $base = [string](Get-RunnerField $Ctx 'baseSha' '')

    # HOST-MANAGED COMMIT (Gate C root-cause fix, 2026-05-29). The codex
    # workspace-write sandbox on Windows executes shell as a SEPARATE restricted OS
    # user ('CodexSandboxOffline', distinct SID from the repo owner). Even with
    # --add-dir granting the shared <project>/.git, the NTFS ACL denies that user
    # write to .git/worktrees/<id>/, so the worker cannot create index.lock and thus
    # cannot 'git add'/'git commit'. Workers therefore run in host-managed-commit
    # mode (Spawn-Worker -HostManagedCommit): they only PRODUCE files in the worktree
    # cwd (which the sandbox CAN write). Here the trusted HOST (this process, the repo
    # owner) commits that work so the structural gate can count it. The gate keeps its
    # meaning: a worker that lies about 'done' but produces nothing leaves a clean
    # worktree -> no commit -> fail-closed. Idempotent: if the worker DID manage to
    # commit (Temp-rooted repo / other OS where the sandbox can write git metadata),
    # the worktree is already clean and we add nothing.
    $wstatus = [string](Get-RunnerField $r 'status' '')
    $wtPath = ''
    try { $wtPath = [string]$Ctx.wt.path } catch {}
    if ($wstatus -eq 'done' -and -not [string]::IsNullOrWhiteSpace($wtPath) -and (Test-Path -LiteralPath $wtPath)) {
      # EAP=Continue locally + gate on $LASTEXITCODE: native git writes benign
      # warnings to stderr (notably the "LF will be replaced by CRLF" autoconv notice
      # on 'git add'), and under EAP=Stop those raise NativeCommandError that would
      # abort the commit (confirmed Gate C run #5: add emitted the CRLF warning, the
      # old 2>$null+catch swallowed it as a failure, the commit never happened, the
      # gate saw 0 commits and deadlocked). Success is decided by exit code, not by
      # the absence of stderr output.
      $eapSave = $ErrorActionPreference
      $ErrorActionPreference = 'Continue'
      try {
        $dirty = @(& (Get-GitExe) -C $wtPath status --porcelain 2>&1 | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($dirty.Count -gt 0) {
          & (Get-GitExe) -C $wtPath add -A 2>&1 | Out-Null
          if ($LASTEXITCODE -eq 0) {
            & (Get-GitExe) -C $wtPath -c user.name='bridge' -c user.email='bridge@localhost' commit -m ('foundry-worker: ' + [string]$Ctx.sid) 2>&1 | Out-Null
          }
        }
      } catch {} finally { $ErrorActionPreference = $eapSave }
    }

    $commits = @()
    if (-not [string]::IsNullOrWhiteSpace($branch)) {
      $range = if ([string]::IsNullOrWhiteSpace($base)) { $branch } else { ($base + '..' + $branch) }
      try { $commits = @(& (Get-GitExe) -C $repo rev-list --reverse $range 2>$null | ForEach-Object { [string]$_ }) } catch { $commits = @() }
    }
    return @{
      status  = [string](Get-RunnerField $r 'status' 'failed')
      reply   = [string](Get-RunnerField $r 'reply' '')
      commits = $commits
    }
  }.GetNewClosure()

  $ops['Merge'] = {
    param($Ctx)
    $m = Merge-Worktree -Wt $Ctx.wt -Message ('foundry: ' + $Ctx.sid)
    return @{ ok = [bool](Get-RunnerField $m 'ok' $false); conflict = [bool](Get-RunnerField $m 'conflict' $false) }
  }.GetNewClosure()

  $ops['Cleanup'] = {
    param($Ctx)
    try { Remove-Worktree $Ctx.wt } catch {}
  }.GetNewClosure()

  return $ops
}

function New-FoundryStepRunner {
  # Build the $BatchRunner scriptblock for Invoke-PlanDag. Pass -Ops to inject
  # plumbing (tests), or -RepoRoot to wire the real engine via Get-FoundryDefaultOps.
  [CmdletBinding()]
  param(
    [hashtable]$Ops = $null,
    [string]$RepoRoot = '',
    [int]$TimeoutMin = 25,
    [int]$PollSec = 10,
    [scriptblock]$Verify = $null
  )
  if ($null -eq $Ops) {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { throw 'New-FoundryStepRunner: provide -Ops or -RepoRoot' }
    $Ops = Get-FoundryDefaultOps -RepoRoot $RepoRoot -TimeoutMin $TimeoutMin -PollSec $PollSec
  }
  foreach ($k in @('Prepare', 'Await', 'Result', 'Merge', 'Cleanup')) {
    if (-not $Ops.ContainsKey($k) -or $null -eq $Ops[$k]) { throw ("New-FoundryStepRunner: Ops is missing '" + $k + "'") }
  }
  $verifyGate = $Verify
  if ($null -eq $verifyGate) { $verifyGate = { param($Step, $Ctx, $Result) Test-FoundryStepResult -Step $Step -Ctx $Ctx -Result $Result } }

  $prepareOp = $Ops['Prepare']
  $awaitOp   = $Ops['Await']
  $resultOp  = $Ops['Result']
  $mergeOp   = $Ops['Merge']
  $cleanupOp = $Ops['Cleanup']

  return {
    param($Steps)
    $out  = New-Object 'System.Collections.Generic.List[object]'
    $live = New-Object 'System.Collections.Generic.List[object]'   # prepared steps awaiting their worker

    # 1) Launch every step in the wave (parallel): create worktree + spawn worker.
    foreach ($s in @($Steps)) {
      $sid = [string](Get-RunnerField $s 'id' '')
      $prep = $null
      try { $prep = & $prepareOp $s } catch { $prep = @{ ok = $false; error = $_.Exception.Message } }
      if (-not [bool](Get-RunnerField $prep 'ok' $false)) {
        $perr = [string](Get-RunnerField $prep 'error' 'prepare failed')
        [void]$out.Add(@{ id = $sid; ok = $false; status = 'blocked'; result = ('spawn failed: ' + $perr) })
        continue
      }
      [void]$live.Add(@{ step = $s; ctx = (Get-RunnerField $prep 'ctx' $null); sid = $sid })
    }

    # 2) Await the WHOLE batch once (workers run concurrently).
    if ($live.Count -gt 0) {
      $ctxs = @($live | ForEach-Object { $_.ctx })
      try { & $awaitOp $ctxs } catch {}

      # 3) Gate + merge-or-rollback, SEQUENTIALLY (merges must serialize).
      foreach ($item in $live) {
        $s = $item.step; $ctx = $item.ctx; $sid = $item.sid
        $res = $null
        try { $res = & $resultOp $ctx } catch { $res = @{ status = 'failed'; reply = $_.Exception.Message; commits = @() } }
        $status = [string](Get-RunnerField $res 'status' 'failed')

        if ($status -ne 'done') {
          try { & $cleanupOp $ctx } catch {}
          $reply = [string](Get-RunnerField $res 'reply' '')
          [void]$out.Add(@{ id = $sid; ok = $false; status = 'blocked'; result = ('worker ' + $status + (Format-FoundryTail $reply)) })
          continue
        }

        $gate = $null
        try { $gate = & $verifyGate $s $ctx $res } catch { $gate = @{ ok = $false; reason = ('verify threw: ' + $_.Exception.Message) } }
        if (-not [bool](Get-RunnerField $gate 'ok' $false)) {
          try { & $cleanupOp $ctx } catch {}
          $reason = [string](Get-RunnerField $gate 'reason' 'gate rejected')
          [void]$out.Add(@{ id = $sid; ok = $false; status = 'blocked'; result = ('verify failed: ' + $reason) })
          continue
        }

        $merge = $null
        try { $merge = & $mergeOp $ctx } catch { $merge = @{ ok = $false; conflict = $false } }
        if (-not [bool](Get-RunnerField $merge 'ok' $false)) {
          try { & $cleanupOp $ctx } catch {}
          $why = if ([bool](Get-RunnerField $merge 'conflict' $false)) { 'merge conflict (rolled back)' } else { 'merge failed (rolled back)' }
          [void]$out.Add(@{ id = $sid; ok = $false; status = 'blocked'; result = $why })
          continue
        }

        try { & $cleanupOp $ctx } catch {}
        $commits = @(Get-RunnerField $res 'commits' @())
        [void]$out.Add(@{ id = $sid; ok = $true; status = 'done'; result = ('merged ' + $commits.Count + ' commit(s)') })
      }
    }

    return @($out.ToArray())
  }.GetNewClosure()
}

# ===========================================================================
# New-Project pipeline (Ф2 §3.1): turn a goal into a real, channel-bound git
# repo the bridge can then build out via the DAG executor above.
#
#   resolve+confine project root -> mkdir -> write minimal scaffold -> git init
#   + initial commit (so worktrees/rollback have a HEAD) -> New-Channel bind ->
#   verify Get-ChannelProjectBinding.ok. Any failure after mkdir rolls the whole
#   thing back (remove the dir + the channel) so we never leave a half-project.
#
# Autonomous project creation expands the bridge's write surface (the Gate C
# concern), so creation is CONFINED to a configurable projects root
# (config.foundry.projectsRoot, default <bridge>/projects): a project path that
# resolves outside that root is refused fail-closed, '..' traversal included.
# ===========================================================================

function Get-FoundryProjectsRoot {
  # The single directory under which New-Project may create project repos.
  # Bounds the blast radius of autonomous project creation.
  $root = ''
  try {
    if (Get-Command Get-BridgeConfig -ErrorAction SilentlyContinue) {
      $cfg = Get-BridgeConfig
      if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'foundry') -and $cfg.foundry -and ($cfg.foundry.PSObject.Properties.Name -contains 'projectsRoot')) {
        $root = [string]$cfg.foundry.projectsRoot
      }
    }
  } catch {}
  if ([string]::IsNullOrWhiteSpace($root)) {
    # Default to a path that is BOTH outside OneDrive AND outside MSIX per-app
    # virtualization -- the two Windows mechanisms that corrupt git linked-worktree
    # metadata for autonomous workers (empirically pinned in Gate C, 2026-05-29):
    #   * OneDrive Files-On-Demand turns .git/worktrees/<id>/ into READONLY reparse
    #     points -> worker `git commit` dies "Unable to create ...index.lock:
    #     Permission denied". (bridge lives under OneDrive\Documents, so the old
    #     default <bridge>/projects inherited this.)
    #   * %LOCALAPPDATA% / %APPDATA% / %TEMP% get redirected under an MSIX-packaged
    #     host into ...\Packages\<app>\LocalCache\... ; a worktree created via the
    #     logical path but resolved back via the physical path desyncs across
    #     processes -> "cannot lock ref 'HEAD': unable to create directory for
    #     ...\worktrees\<id>\HEAD". (Probed 2026-05-29: USERPROFILE is NOT
    #     virtualized; parallel worktree commits under it succeed.)
    # %USERPROFILE% root is per-user, never OneDrive-synced (KFM only moves
    # Documents/Desktop/Pictures), and not MSIX-redirected. Falls back to
    # <bridge>/projects only if USERPROFILE is somehow unset.
    $up = [string]$env:USERPROFILE
    if (-not [string]::IsNullOrWhiteSpace($up)) { $root = Join-Path $up 'mos-projects' }
    else { $root = Join-Path (Get-BridgeRoot) 'projects' }
  }
  return $root
}

function Test-FoundryPathContained {
  # Fail-closed containment: $true only if $Path resolves to $Root or inside it.
  # Resolves to absolute form first so '..' / relative paths cannot escape.
  param([string]$Path, [string]$Root)
  if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
  $full = $null; $rootFull = $null
  try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
  try { $rootFull = [System.IO.Path]::GetFullPath($Root) } catch { return $false }
  $p = $full.TrimEnd('\', '/')
  $r = $rootFull.TrimEnd('\', '/')
  $sep = [System.IO.Path]::DirectorySeparatorChar
  if ($p.Equals($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  if ($p.StartsWith($r + $sep, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  if ($p.StartsWith($r + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  return $false
}

function New-FoundryProjectResult {
  param([bool]$Ok, [string]$Slug = '', [string]$ProjectRoot = '', [string]$Head = '', [string]$Reason = '')
  return [pscustomobject]@{ ok = $Ok; slug = $Slug; projectRoot = $ProjectRoot; channel = $Slug; head = $Head; reason = $Reason }
}

function New-Project {
  # Create a new project repo and bind a channel to it. Returns
  # @{ ok; slug; projectRoot; channel; head; reason }.
  param(
    [Parameter(Mandatory = $true)][string]$Slug,
    [string]$Name = '',
    [string]$Description = '',
    [string]$Goal = '',
    [string]$ParentDir = '',
    [hashtable]$Scaffold = $null
  )
  $ErrorActionPreference = 'Stop'

  # 1) Normalize slug the same way New-Channel does (so the channel dir matches).
  $slug = ($Slug.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($slug)) { return (New-FoundryProjectResult -Ok $false -Reason 'invalid slug') }
  if ($slug -eq 'main') { return (New-FoundryProjectResult -Ok $false -Slug $slug -Reason "refuse: 'main' is the bridge's own channel") }

  $displayName = if ([string]::IsNullOrWhiteSpace($Name)) { $slug } else { $Name }

  # 2) Resolve + confine the project root.
  $projectsRoot = Get-FoundryProjectsRoot
  $parent = if ([string]::IsNullOrWhiteSpace($ParentDir)) { $projectsRoot } else { $ParentDir }
  $projectRoot = Join-Path $parent $slug
  if (-not (Test-FoundryPathContained -Path $projectRoot -Root $projectsRoot)) {
    return (New-FoundryProjectResult -Ok $false -Slug $slug -Reason ("refuse: project path escapes projects root (" + $projectsRoot + ")"))
  }
  try { $projectRoot = [System.IO.Path]::GetFullPath($projectRoot) } catch {}

  # 3) Refuse to clobber an existing project dir or channel.
  if (Test-Path -LiteralPath $projectRoot) { return (New-FoundryProjectResult -Ok $false -Slug $slug -ProjectRoot $projectRoot -Reason 'project dir already exists') }
  $channelDir = $null
  try { $channelDir = Get-ChannelDir -Slug $slug } catch {}
  if ($channelDir -and (Test-Path -LiteralPath $channelDir)) { return (New-FoundryProjectResult -Ok $false -Slug $slug -ProjectRoot $projectRoot -Reason 'channel already exists') }

  $channelCreated = $false
  try {
    # 4) Create the dir + scaffold.
    if (-not (Test-Path -LiteralPath $projectsRoot)) { New-Item -ItemType Directory -Path $projectsRoot -Force | Out-Null }
    New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

    $files = $Scaffold
    if ($null -eq $files -or $files.Count -eq 0) {
      $readmeBody = if (-not [string]::IsNullOrWhiteSpace($Goal)) { $Goal } elseif (-not [string]::IsNullOrWhiteSpace($Description)) { $Description } else { 'Project created by the bridge Project Foundry.' }
      $files = @{
        'README.md'  = ("# " + $displayName + "`n`n" + $readmeBody + "`n")
        '.gitignore' = "# bridge Project Foundry default ignores`n*.log`n*.tmp`nnode_modules/`n.bridge-wt/`n"
      }
    }
    $u8 = New-Object System.Text.UTF8Encoding($false)
    foreach ($rel in $files.Keys) {
      $dest = Join-Path $projectRoot ([string]$rel)
      $destDir = Split-Path -Parent $dest
      if (-not [string]::IsNullOrWhiteSpace($destDir) -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
      [System.IO.File]::WriteAllText($dest, [string]$files[$rel], $u8)
    }

    # 5) git init + initial commit (HEAD is required for worktree branches).
    $git = Get-GitExe
    $eapPrev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $git -C $projectRoot init 2>&1 | Out-Null
    $initOk = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath (Join-Path $projectRoot '.git'))
    $head = ''
    if ($initOk) {
      & $git -C $projectRoot add -A 2>&1 | Out-Null
      & $git -C $projectRoot -c user.name='bridge' -c user.email='bridge@localhost' commit -m 'Initial project scaffold (bridge Project Foundry)' 2>&1 | Out-Null
      $commitOk = ($LASTEXITCODE -eq 0)
      if ($commitOk) { try { $head = ((& $git -C $projectRoot rev-parse HEAD 2>$null) | Select-Object -First 1).Trim() } catch {} }
    }
    $ErrorActionPreference = $eapPrev
    if (-not $initOk) { throw 'git init failed' }
    if ([string]::IsNullOrWhiteSpace($head)) { throw 'initial commit failed (no HEAD) -- check git identity/signing config' }

    # 6) Bind a channel to the new project.
    $ch = New-Channel -Slug $slug -Name $displayName -Description $Description -ProjectRoot $projectRoot
    if (-not $ch) { throw 'channel creation failed' }
    $channelCreated = $true

    # 7) Verify the binding resolves.
    $binding = Get-ChannelProjectBinding -Slug $slug
    if (-not $binding -or -not [bool]$binding.ok) {
      $berr = if ($binding) { [string]$binding.error } else { 'binding null' }
      throw ('binding not ok: ' + $berr)
    }

    return (New-FoundryProjectResult -Ok $true -Slug $slug -ProjectRoot $projectRoot -Head $head)
  } catch {
    # Roll back a partial project so we never leave half-created state behind.
    $reason = $_.Exception.Message
    if ($channelCreated -and $channelDir) { try { Remove-Item -LiteralPath $channelDir -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
    try { if (Test-Path -LiteralPath $projectRoot) { Remove-Item -LiteralPath $projectRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
    return (New-FoundryProjectResult -Ok $false -Slug $slug -ProjectRoot $projectRoot -Reason $reason)
  }
}

# ===========================================================================
# Plan dispatch (Ф2 §3.2): the driver-facing seam. Turns the current channel's
# persisted plan-board into a REAL dispatched DAG -- ready steps fan out to
# parallel workers in the bound PROJECT repo's worktrees, each step gated
# (done + >=1 commit) and merged-or-rolled-back, wave after wave until drained.
# All the heavy orchestration lives in the unit-tested layer below
# (Invoke-PlanDag + New-FoundryStepRunner) so the live driver only calls this
# one entry point. Inject -BatchRunner to test the decision/reporting logic
# without spawning real workers or touching git.
# ===========================================================================

function Get-FoundryMaxParallel {
  # Default fan-out width for DAG dispatch. config.foundry.maxParallel overrides;
  # clamped to [1, 8] so a bad config value can never spawn an unbounded swarm.
  $n = 0
  try {
    if (Get-Command Get-BridgeConfig -ErrorAction SilentlyContinue) {
      $cfg = Get-BridgeConfig
      if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'foundry') -and $cfg.foundry -and ($cfg.foundry.PSObject.Properties.Name -contains 'maxParallel')) {
        $n = [int]$cfg.foundry.maxParallel
      }
    }
  } catch {}
  if ($n -lt 1) { $n = 2 }
  if ($n -gt 8) { $n = 8 }
  return $n
}

function New-FoundryDispatchResult {
  param([bool]$Ok, [string]$Outcome = 'error', [int]$Done = 0, [int]$Blocked = 0, [int]$Skipped = 0, [int]$Waves = 0, [bool]$Deadlocked = $false, [string]$Reason = '', [string]$Summary = '', $Blockers = $null)
  if ($null -eq $Blockers) { $Blockers = @{} }
  return [pscustomobject][ordered]@{
    ok = $Ok; outcome = $Outcome; done = $Done; blocked = $Blocked; skipped = $Skipped
    waves = $Waves; deadlocked = $Deadlocked; reason = $Reason; summary = $Summary; blockers = $Blockers
  }
}

function Invoke-FoundryPlanDispatch {
  # Drive the current channel's plan-board to done as a dispatched DAG against the
  # PROJECT repo at -RepoRoot. Returns a normalized outcome:
  #   { ok; outcome; done; blocked; skipped; waves; deadlocked; reason; summary; blockers }
  # ok == ($outcome -eq 'complete'). Inject -BatchRunner to unit-test without workers/git.
  [CmdletBinding()]
  param(
    [string]$RepoRoot = '',
    [int]$MaxParallel = 0,
    [int]$TimeoutMin = 25,
    [int]$PollSec = 10,
    [int]$MaxWaves = 0,
    [scriptblock]$BatchRunner = $null,
    [scriptblock]$Verify = $null
  )
  if ($MaxParallel -le 0) { $MaxParallel = Get-FoundryMaxParallel }

  # 1) There must be a plan with steps to dispatch.
  $ss = $null
  try { $ss = Get-PlanScheduleState } catch { $ss = $null }
  if (-not $ss -or [string]$ss.reason -eq 'no-plan' -or [int]$ss.total -le 0) {
    return (New-FoundryDispatchResult -Ok $false -Outcome 'empty' -Reason 'no plan to dispatch' -Summary 'no plan')
  }
  if ([bool]$ss.complete) {
    return (New-FoundryDispatchResult -Ok $true -Outcome 'complete' -Done ([int]$ss.done) -Skipped ([int]$ss.skipped) -Reason 'already complete' -Summary 'already complete')
  }

  # 2) Build the real step runner unless one is injected (tests inject). The runner
  #    (via Get-FoundryDefaultOps) refuses non-git dirs and the bridge repo itself.
  $runner = $BatchRunner
  if ($null -eq $runner) {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
      return (New-FoundryDispatchResult -Ok $false -Outcome 'error' -Reason 'no project repo bound' -Summary 'no repo (-RepoRoot empty)')
    }
    try {
      if ($null -ne $Verify) { $runner = New-FoundryStepRunner -RepoRoot $RepoRoot -TimeoutMin $TimeoutMin -PollSec $PollSec -Verify $Verify }
      else                   { $runner = New-FoundryStepRunner -RepoRoot $RepoRoot -TimeoutMin $TimeoutMin -PollSec $PollSec }
    } catch {
      return (New-FoundryDispatchResult -Ok $false -Outcome 'error' -Reason $_.Exception.Message -Summary ('runner build failed: ' + $_.Exception.Message))
    }
  }

  # 3) Drain the DAG (each wave: launch ready -> await -> gate+merge/rollback).
  $r = $null
  try {
    if ($MaxWaves -gt 0) { $r = Invoke-PlanDag -BatchRunner $runner -MaxParallel $MaxParallel -MaxWaves $MaxWaves }
    else                 { $r = Invoke-PlanDag -BatchRunner $runner -MaxParallel $MaxParallel }
  } catch {
    return (New-FoundryDispatchResult -Ok $false -Outcome 'error' -Reason $_.Exception.Message -Summary ('dispatch threw: ' + $_.Exception.Message))
  }

  $outcome = [string]$r.outcome
  $summary = ('outcome=' + $outcome + '; done=' + [int]$r.done + '; blocked=' + [int]$r.blocked + '; waves=' + [int]$r.waves)
  return (New-FoundryDispatchResult -Ok ($outcome -eq 'complete') -Outcome $outcome -Done ([int]$r.done) -Blocked ([int]$r.blocked) -Skipped ([int]$r.skipped) -Waves ([int]$r.waves) -Deadlocked ([bool]$r.deadlocked) -Reason $outcome -Summary $summary -Blockers $r.blockers)
}
