# driver.ps1 -- INTERACTIVE bridge: idles, and treats each [USER] chat message as a
# task. Planner (Claude) plans/reviews, Coder (Codex) executes with FULL PC access.
#
# Phase 3 (full): supports per-channel parallel drivers. Pass `-Channel <slug>` and the
# driver hard-pins itself to that channel for its entire process lifetime -- all
# Read-State/Update-State/Add-Message calls route into channels/<slug>/. Supervisor
# spawns one process per non-archived channel.
param([string]$Channel = $null, [switch]$SelfTest)

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\agent-wait.ps1')
. (Join-Path $PSScriptRoot 'lib\metrics.ps1')
. (Join-Path $PSScriptRoot 'lib\plan.ps1')
# Project Foundry (Фаза 2): New-Project pipeline + the dispatched-DAG executor
# (Invoke-FoundryPlanDispatch / Invoke-PlanDag / New-FoundryStepRunner). Depends on
# plan.ps1 (above) plus worktrees/parallel/channels (loaded via common.ps1).
. (Join-Path $PSScriptRoot 'lib\foundry.ps1')
. (Join-Path $PSScriptRoot 'lib\auditor.ps1')
. (Join-Path $PSScriptRoot 'lib\canary.ps1')
. (Join-Path $PSScriptRoot 'lib\replay.ps1')
. (Join-Path $PSScriptRoot 'lib\postmortem.ps1')
. (Join-Path $PSScriptRoot 'lib\features.ps1')
. (Join-Path $PSScriptRoot 'lib\qa-agent.ps1')
. (Join-Path $PSScriptRoot 'lib\project-acceptance.ps1')
. (Join-Path $PSScriptRoot 'lib\checkpoint.ps1')
$ErrorActionPreference = 'Continue'

# Tool Foundry (Фаза 1): load every GREEN (status=active) self-built tool from
# tools/auto/. MUST stay at TOP LEVEL -- dot-sourcing inside a function would trap the
# tool functions in that function's local scope instead of the engine's script scope.
# Get-ActiveAutoToolPaths is pure + best-effort: broken/missing tools are silently
# dropped (re-validated names, parse-checked) so a bad tool can never block the engine.
try { foreach ($p in (Get-ActiveAutoToolPaths)) { . $p } } catch {}

# Resolve and lock the channel for this driver process. If -Channel wasn't passed
# (legacy single-driver mode or supervisor before update), fall back to active marker.
if ([string]::IsNullOrWhiteSpace($Channel)) {
  $Channel = (Get-ActiveChannel)
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }
}
$Channel = Normalize-ChannelSlug $Channel
Set-PinnedChannel $Channel
Write-Host ("driver pinned to channel: " + $Channel)

# UTF-8 end-to-end (Russian survives the stdin/stdout file round-trip).
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding = $Utf8NoBom
try { [Console]::OutputEncoding = $Utf8NoBom; [Console]::InputEncoding = $Utf8NoBom } catch {}

try {
  $cfg = Get-BridgeConfig
  $requiredConfigKeys = @('port','maxTurns','loopDelaySeconds','workRoot')
  foreach ($requiredConfigKey in $requiredConfigKeys) {
    if ($cfg.PSObject.Properties.Name -notcontains $requiredConfigKey -or $null -eq $cfg.$requiredConfigKey) {
      Write-Error ("FATAL driver config error: missing required config key '" + $requiredConfigKey + "'")
      exit 3
    }
  }
} catch {
  Write-Error ("FATAL driver config error: " + $_.Exception.Message)
  exit 3
}
$claudeExe  = Resolve-ClaudeExe $cfg
$codexExe   = Resolve-CodexExe  $cfg
$workRoot   = [string]$cfg.workRoot
$bridgeRoot = Get-BridgeRoot

# 2026-05-31 (Foundation #4): ensure node/npm on PATH for PROJECT channels (build/test/verify).
# The driver starts -NoProfile inheriting the supervisor's stale PATH (captured before node was
# installed), so child coder processes can't find node. Locate it once and prepend to this
# process's PATH; spawned codex/claude inherit it. No-op if node is already visible.
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  $nodeDirs = @()
  try { $nodeDirs += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\OpenJS.NodeJS*\node-*-win-x64\node.exe') -ErrorAction SilentlyContinue | ForEach-Object { $_.DirectoryName }) } catch {}
  $nodeDirs += @((Join-Path $env:ProgramFiles 'nodejs'), (Join-Path $env:LOCALAPPDATA 'Programs\nodejs'))
  foreach ($d in $nodeDirs) { if ($d -and (Test-Path (Join-Path $d 'node.exe'))) { $env:Path = [string]$d + ';' + $env:Path; break } }
}
$maxTurns   = [int]$cfg.maxTurns
$loopDelay  = [int]$cfg.loopDelaySeconds
$idlePoll   = if ($cfg.idlePollSeconds) { [int]$cfg.idlePollSeconds } else { 3 }
# Adaptive idle backoff (perf 2026-05-29): keep the snappy $idlePoll cadence for the first
# $idleFastTicks consecutive idle ticks after any activity, then ramp the sleep +1s/tick up to
# $idleMaxPoll. A long-idle bridge otherwise wakes ~1Hz to run maintenance that is almost always
# "not due" -- pure redundant looping. The streak resets to 0 the instant a user message arrives
# or an autonomous task is claimed, so post-activity responsiveness is unchanged.
$idleMaxPoll   = if ($cfg.idleMaxPollSeconds) { [int]$cfg.idleMaxPollSeconds } else { 5 }
$idleFastTicks = if ($cfg.idleFastTicks)      { [int]$cfg.idleFastTicks }      else { 8 }
if ($idleMaxPoll -lt $idlePoll) { $idleMaxPoll = $idlePoll }   # never sleep below base cadence
$script:idleStreak = 0
$fullContext    = if ($cfg.fullContextCount) { [int]$cfg.fullContextCount } else { 20 }
$summarizeBatch = if ($cfg.summarizeBatch)   { [int]$cfg.summarizeBatch }   else { 15 }
$triageModel       = if ($cfg.triageModel)       { [string]$cfg.triageModel }       else { 'sonnet' }
$deepModel         = if ($cfg.deepModel)         { [string]$cfg.deepModel }         else { 'opus' }
$discussMinTurns   = if ($cfg.discussMinTurns)   { [int]$cfg.discussMinTurns }      else { 3 }
$discussMaxTurns   = if ($cfg.discussMaxTurns)   { [int]$cfg.discussMaxTurns }      else { 8 }
$researchMaxTurns  = if ($cfg.researchMaxTurns)  { [int]$cfg.researchMaxTurns }     else { 2 }
$studyMaxTurns     = if ($cfg.studyMaxTurns)     { [int]$cfg.studyMaxTurns }        else { 5 }


# Driver implementation modules. Keep this entrypoint thin; edit behavior in driver/*.ps1.
. (Join-Path $PSScriptRoot 'driver\00-task-session.ps1')
. (Join-Path $PSScriptRoot 'driver\10-maintenance.ps1')
. (Join-Path $PSScriptRoot 'driver\20-context.ps1')
. (Join-Path $PSScriptRoot 'driver\30-prompt-agent-state.ps1')
. (Join-Path $PSScriptRoot 'driver\40-agent-invoke.ps1')
. (Join-Path $PSScriptRoot 'driver\50-loop-utils.ps1')

# ---------- driver self-test (pre-promote runtime gate) ----------
# smoke.ps1 PARSES every .ps1 and runs common.ps1 at runtime (Get-PreflightBlockers), but it never
# EXECUTES driver.ps1 -- so a parse-OK-but-runtime-broken edit here (the PS5.1 `(if...)` expression
# bomb behind the 2026-05-26 restart-loop) shipped green and only blew up on the NEXT restart.
# Running this file as `-SelfTest` in a CHILD process makes reaching this line proof that every
# dot-sourced lib + all driver top-level code + EVERY function definition (L1-2684) loaded without
# a runtime error; we then smoke the pure helpers most exposed to Doctor/coder timeout edits.
# This guard sits BEFORE the startup block (Sweep-AgentOrphans, tmp-sweep, zombie-recovery, Doctor
# restart-loop guard) so the child performs NO process kills, NO Add-Message, NO state writes -- it
# is safe to run alongside the live driver. (Initialize-Bridge above is idempotent without -Reset:
# it only creates missing dirs, never overwrites an existing convo/state.)
if ($SelfTest) {
  $stFail = New-Object System.Collections.ArrayList
  try {
    $probeCfg = Get-BridgeConfig
    $ct = 900000
    if ($probeCfg.coderTimeoutMs -and [int]$probeCfg.coderTimeoutMs -gt 0) { $ct = [int]$probeCfg.coderTimeoutMs }
    if ($ct -le 0) { [void]$stFail.Add('coderTimeoutMs resolved <= 0') }
    $cr = 2
    if ($probeCfg.PSObject.Properties.Name -contains 'criticMaxRetries') { $cr = [int]$probeCfg.criticMaxRetries }
    if ($cr -lt 0) { [void]$stFail.Add('criticMaxRetries < 0') }
  } catch { [void]$stFail.Add('config probe threw: ' + $_.Exception.Message) }
  foreach ($fn in @('Wait-AgentProcess','Get-PlannerModel','Start-ReplayForStateTask','Sweep-AgentOrphans','Activate-Doctor','Complete-Doctor','Abort-Doctor','Get-TaskRepoRoot','Test-QualityBypassesInDiff','Start-ProjectAcceptanceIfDue','Invoke-ProjectAcceptance')) {
    if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { [void]$stFail.Add('missing function: ' + $fn) }
  }
  try {
    $qbProbe = @(Test-QualityBypassesInDiff -Diff "+  typescript: { ignoreBuildErrors: true },")
    if ($qbProbe.Count -lt 1) { [void]$stFail.Add('quality-bypass detector missed ignoreBuildErrors') }
  } catch {
    [void]$stFail.Add('quality-bypass detector threw: ' + $_.Exception.Message)
  }
  if ($stFail.Count -gt 0) { foreach ($f in $stFail) { Write-Output ('DRIVER SELFTEST FAIL: ' + $f) }; exit 1 }
  Write-Output 'DRIVER SELFTEST OK'
  exit 0
}

# ---------- startup ----------
Sweep-AgentOrphans

# Resume an interrupted task across restarts instead of dropping it. Conversation,
# summary and decisions are file-based and already survive. We keep current_task /
# task_turn / task_mode / last_user_seq / summarized_seq, and only clear the transient
# execution state (a killed agent process). The loop re-runs the interrupted turn.
$boot = Read-State
$resumeTask = if ($boot -and $boot.current_task) { [string]$boot.current_task } else { '' }
if (-not [string]::IsNullOrWhiteSpace($resumeTask)) {
  # 2026-05-28: detect "stuck task" — if we've already resumed this task N times
  # without it closing, give up and mark failed. Real incident: Phase 1 task
  # survived 7+ restarts in 20 min while verify-loop and unrelated commits kept
  # triggering supervisor recycles. Auditor flagged "Supervisor restarts exceed
  # limit (7/5)" but bridge kept re-resuming with no escape valve.
  $prevRestartCount = 0
  try { if ($boot.PSObject.Properties.Name -contains 'task_restart_count') { $prevRestartCount = [int]$boot.task_restart_count } } catch {}
  $maxRestarts = 3
  try {
    $cfgRC = Get-BridgeConfig
    if ($cfgRC -and $cfgRC.PSObject.Properties.Name -contains 'taskRestartCap' -and $cfgRC.taskRestartCap) { $maxRestarts = [int]$cfgRC.taskRestartCap }
  } catch {}
  if ($maxRestarts -lt 2) { $maxRestarts = 2 }
  if ($maxRestarts -gt 10) { $maxRestarts = 10 }

  if ($prevRestartCount -ge $maxRestarts) {
    # Stuck task: bail out. Mark backlog failed if linked, clear state, post msg.
    $stuckTaskShort = $resumeTask
    if ($stuckTaskShort.Length -gt 100) { $stuckTaskShort = $stuckTaskShort.Substring(0, 100) + '…' }
    $stuckBacklogId = if ($boot.current_backlog_id) { [string]$boot.current_backlog_id } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($stuckBacklogId)) {
      try { Set-Idea -Id $stuckBacklogId -Status 'failed' -Reason ("task_restart_loop_" + $prevRestartCount) | Out-Null } catch {}
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
    } | Out-Null
    Add-Message -From system -Text ("⚠ Задача пережила " + $prevRestartCount + " рестартов без закрытия — помечаю как failed и перехожу к следующей. Текст: «" + $stuckTaskShort + "»") -Kind event | Out-Null
    # Pick up the tail: a failed task often leaves a VALID uncommitted fix behind (the bridge
    # crashed on orchestration, not on the code). Auto-commit it if it parses (tree clean again,
    # autonomy unblocked) or reversibly stash it if broken — so no operator has to do it by hand.
    try { Invoke-FailedTaskSalvage -TaskText $stuckTaskShort -BacklogId $stuckBacklogId | Out-Null } catch { try { Write-DoctorLog ("salvage call error: " + $_.Exception.Message) } catch {} }
  } else {
    Update-State {
      param($s)
      Start-ReplayForStateTask -State $s -TaskText $resumeTask -ChannelName $Channel
      $s.status='working'; $s.stop=$false; $s.abort=$false
      $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.current_agent=$null; $s.current_agent_pid=0; $s.current_agent_ticks=0; $s.current_agent_since=$null; $s.agent_telemetry=$null
      $s.driver_started=(Get-Date).ToString('o'); $s.heartbeat=(Get-Date).ToString('o')
      $newCount = $prevRestartCount + 1
      $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue $newCount -Force
    } | Out-Null
    $remaining = $maxRestarts - $prevRestartCount - 1
    $tail = if ($remaining -le 0) { '' } else { " (осталось $remaining попыток до auto-fail)" }
    Add-Message -From system -Text ("♻ Мост перезапущен — возобновляю прерванную задачу (прогресс и история сохранены)." + $tail) -Kind event | Out-Null
  }
} else {
  Update-State {
    param($s)
    $s.status='idle'; $s.stop=$false; $s.abort=$false
    $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.current_agent=$null; $s.current_agent_pid=0; $s.current_agent_ticks=0; $s.current_agent_since=$null; $s.agent_telemetry=$null
    $s.current_task=$null; $s.current_task_id=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Reset-TaskAgentDuration $s; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s; Clear-ChunkingState $s
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
# doctor_attempts never incremented because the increment branch only triggers when
# current_task is EMPTY. Result: infinite restart loop, Codex never committed, working tree
# accumulated changes. This guard treats each driver startup-while-Doctor-active as one
# "attempt", so the existing max-attempts gate actually fires.
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
    $newAtt = [int]$startupState.doctor_attempts + 1
    $maxA = 3   # initial + 2 restarts; beyond that the loop is real and we escalate
    Update-State { param($s) $s.doctor_attempts = [int]$s.doctor_attempts + 1 } | Out-Null
    Add-Message -From system -Text ("🩺 Доктор резюмирован после рестарта (попытка " + $newAtt + "/" + $maxA + ").") -Kind event | Out-Null
    if ($newAtt -ge $maxA) {
      # Restart loop -- abort Doctor cleanly + restore held_task so the operator sees what
      # was running. Doctor's prompt may have generated useful diagnostic memories; those
      # stay in long-term memory regardless.
      $held = [string]$startupState.held_task
      $reason = [string]$startupState.doctor_reason
      Update-State {
        param($s)
        $s.doctor_active = $false
        $s.doctor_attempts = 0
        $s.doctor_reason = ''
        $s.doctor_started_at = $null
        Close-ReplayForStateTask -State $s -Status 'aborted'
        $s.current_task = $null    # operator will re-submit / inspect; don't auto-resume held_task to avoid loop chain
        $s.held_task = $held       # keep for the operator-visible event below
        $s.task_turn = 0
        $s.task_mode = 'normal'
        Clear-AuditorSuppressedHashes -State $s
        Clear-FastLaneFlags $s
        $s.status = 'idle'
        $s.active_agent = $null
        $s.active_model = $null
        $s.status_text = $null
      } | Out-Null
      $snip = $held; if ($snip.Length -gt 80) { $snip = $snip.Substring(0,80) + '...' }
      Add-Message -From system -Text ("⚠ Доктор отменён: restart-loop ($newAtt рестартов мостa при reason='" + $reason + "'). Приостановленная задача: «" + $snip + "» — оператор, проверь рабочее дерево (git status / git stash list) и при необходимости перепиши задачу.") -Kind event | Out-Null
    }
  }
} catch {}

# ---------- main loop ----------
while ($true) {
 try {
  # Phase 3 (full): channel is hard-pinned at process startup. No per-iteration re-evaluation
  # -- each driver lives in its own channel for its entire lifetime.
  $state = Read-State
  # FIX 2026-05-27: Read-State now returns $null on structurally-broken state.json
  # (Test-StateShape failure). Self-heal: re-run Initialize-Bridge to restore defaults,
  # then re-read. Without this, a state-wipe accident (like yesterday's) would just hang
  # the driver silently on subsequent iterations.
  if ($null -eq $state) {
    try { Add-Message -From system -Text "⚠ Driver: state.json повреждён — auto-recover через Initialize-Bridge defaults." -Kind event } catch {}
    try { $null = Initialize-Bridge } catch {}
    $state = Read-State
    if ($null -eq $state) {
      # Recovery itself failed — sleep + retry. Never hard-crash the loop.
      Start-Sleep -Seconds 5; continue
    }
  }

  # ───────── self-dev recycle COALESCER — root-cause fix for restart-storms (2026-05-29) ─────────
  # PROBLEM: a self-dev task that edited several .ps1 set restart.flag per edit; the supervisor then
  # recycled MID-TURN, the coder resumed, edited again, set the flag again -> 18 recycles/30min ->
  # circuit-breaker cooldown -> the bridge looked "unstable" (operator-visible). The supervisor's
  # 60s rate-limit only thinned the storm, it didn't stop the mid-turn kill->resume->re-edit loop.
  # CURE: while ANY channel is BUSY, DEFER restart.flag (move it aside) so the supervisor cannot kill
  # a coder mid-turn (recycle = Kill-Bridge ALL channels). Restore the instant ALL channels are idle
  # -> a burst of edits collapses into ONE clean recycle, taken only when nothing is running. A hard
  # cap stops an ever-busy/stuck channel from blocking a genuinely-needed restart forever.
  # ONLY the 'main' driver manages the shared flag (one manager -> no cross-channel Move races, since
  # all channels share one control/ dir). Driver-side on purpose: ships on a normal recycle
  # (supervisor.ps1 would need an elevated reload). The supervisor's 60s rate-limit still backstops.
  if ($Channel -eq 'main') {
    try {
      $ctlDir    = Join-Path $bridgeRoot 'control'
      $rcFlag    = Join-Path $ctlDir 'restart.flag'
      $rcDefer   = Join-Path $ctlDir 'restart.deferred'
      $rcMaxDefer = 600
      $rcBusy = $false
      # 2026-05-30 defense: Get-ActiveSlugs now lives in lib/channels.ps1 (driver dot-sources it).
      # Guard anyway -- if it's ever unavailable again, fall back to 'main' instead of throwing the
      # WHOLE apply-block into the outer catch. That exact silent failure (supervisor-only function
      # called from the driver) held deferred restarts UNAPPLIED for weeks: the bridge could not
      # self-deploy its own .ps1 edits without a manual recycle.
      $rcSlugs = @('main'); try { $rcSlugs = @(Get-ActiveSlugs) } catch { $rcSlugs = @('main') }
      foreach ($rcSlug in $rcSlugs) {
        $rcSp = Join-Path $bridgeRoot ("channels\" + $rcSlug + "\state.json")
        if (Test-Path -LiteralPath $rcSp) {
          try {
            $rcCs = [IO.File]::ReadAllText($rcSp, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if (([string]$rcCs.status -in @('working','planning','coding','discuss','study','research')) -or (-not [string]::IsNullOrWhiteSpace([string]$rcCs.current_task)) -or [bool]$rcCs.doctor_active) { $rcBusy = $true; break }
          } catch {}
        }
      }
      if ((Test-Path -LiteralPath $rcFlag) -and $rcBusy) {
        # 2026-05-30 v3: stamp the FIRST-defer time into restart.deferred content and do
        # NOT reset it on re-defer. Otherwise continuous self-dev work re-defers every
        # tick, bumping the file mtime, so the maxDefer cap (age) never fires and the
        # restart is held FOREVER -- a never-deploying gate exposed this. Keep original stamp.
        try {
          if (Test-Path -LiteralPath $rcDefer) { Remove-Item -LiteralPath $rcFlag -Force }
          else { Set-Content -LiteralPath $rcDefer -Value ((Get-Date).ToUniversalTime().ToString('o')) -Encoding ASCII; Remove-Item -LiteralPath $rcFlag -Force }
          Write-Host 'recycle: deferred restart.flag (a channel is busy, coalescing)'
        } catch {}
      }
      elseif (Test-Path -LiteralPath $rcDefer) {
        # Age from the FIRST-defer timestamp in the file content (mtime would keep getting
        # bumped by re-defer). Fall back to mtime if content isn't a parseable timestamp.
        $rcAge = 999999
        try {
          $rcStamp = ([string](Get-Content -LiteralPath $rcDefer -Raw -ErrorAction SilentlyContinue)).Trim()
          $rcFirst = [datetime]::MinValue
          if ($rcStamp -and [datetime]::TryParse($rcStamp, [ref]$rcFirst)) { $rcAge = ((Get-Date).ToUniversalTime() - $rcFirst.ToUniversalTime()).TotalSeconds }
          else { $rcAge = ((Get-Date) - (Get-Item -LiteralPath $rcDefer).LastWriteTime).TotalSeconds }
        } catch {}
        # 2026-05-30 v2 PLAN-AWARE batch-done detection (operator: a blind timeout
        # could fire while a slow Codex is mid-batch -> "выстрел в ногу"). Two facts:
        #   1. $rcBusy above ALREADY keeps the restart deferred while a task RUNS
        #      (status working/coding/etc + current_task + doctor) -- so a slow Codex
        #      NEVER triggers a restart; the channel stays busy until it's actually done.
        #   2. Between tasks we now look at the PLAN, not a clock: hold the restart
        #      while there is still work the bridge will pick up next --
        #        * background jobs still running (state.active_jobs), OR
        #        * claimable backlog (approved/green/yellow/new) and autonomy enabled.
        # The restart fires only when the plan is DRAINED (the batch is truly over).
        # A long quiet period is a FAILSAFE for when backlog is unreadable or the
        # bridge is gated and will never pick the work up; the 600s cap is the hard stop.
        $rcPlanHasWork = $false
        try { $rcSt2 = Read-State; if (@($rcSt2.active_jobs).Count -gt 0) { $rcPlanHasWork = $true } } catch {}
        if (-not $rcPlanHasWork) {
          try {
            if ([bool](Get-AutonomySettings).enabled) {
              $rcClaim = @((Get-Backlog) | Where-Object { [string]$_.status -in @('approved','green','yellow','new') }).Count
              if ($rcClaim -gt 0) { $rcPlanHasWork = $true }
            }
          } catch {}
        }
        $rcQuietSec = 0
        try { $rcCp = Get-ConversationPath; $rcQuietSec = ((Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $rcCp).LastWriteTimeUtc).TotalSeconds } catch {}
        $rcFailsafeQuiet = 300
        if (-not $rcPlanHasWork) {
          try { Move-Item -LiteralPath $rcDefer -Destination $rcFlag -Force; Add-Message -From system -Text '♻ Применяю отложенный перезапуск — план пуст, пачка self-dev правок завершена (один recycle).' -Kind event | Out-Null } catch {}
        } elseif ($rcQuietSec -ge $rcFailsafeQuiet) {
          try { Move-Item -LiteralPath $rcDefer -Destination $rcFlag -Force; Add-Message -From system -Text ('♻ Применяю отложенный перезапуск — мост тих ' + [int]$rcQuietSec + 'с (failsafe).') -Kind event | Out-Null } catch {}
        } elseif ($rcAge -ge $rcMaxDefer) {
          try { Move-Item -LiteralPath $rcDefer -Destination $rcFlag -Force; Add-Message -From system -Text '♻ Отложенный перезапуск применён по таймауту (макс. отсрочка).' -Kind event | Out-Null } catch {}
        }
        # else: plan still has queued work, not failsafe-quiet, under cap -> keep holding
      }
    } catch { try { [System.IO.File]::AppendAllText((Join-Path $bridgeRoot 'control\coalescer.err.log'), ((Get-Date).ToString('o') + ' coalescer-apply EXC: ' + $_.Exception.Message + "`n")) } catch {} }
  }

  if ($state.stop) { Add-Message -From system -Text "Мост остановлен." -Kind event | Out-Null; Update-State { param($s) $s.status='stopped'; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null } | Out-Null; break }

  if ($state.abort) {
    Add-Message -From system -Text "🛑 Стоп-кран: текущая задача прервана. Жду новую." -Kind event | Out-Null
    try { foreach ($j in @($state.active_jobs)) { Stop-BridgeJob $j } } catch {}
    # Abort is always intentional (user kill button) -- no post-mortem needed.
    # If Doctor was active, clean up its state gracefully before resetting.
    if ([bool](Read-State).doctor_active) {
      try { Abort-Doctor -Reason 'manual abort by operator' } catch {}
    }
      Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'aborted'; $s.abort=$false; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s; Clear-ChunkingState $s; $s.active_jobs=@(); $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.status='idle' } | Out-Null
    Start-Sleep -Seconds 1; continue
  }
  if ($state.paused) { Update-State { param($s) $s.status='paused'; $s.active_agent=$null; $s.active_model=$null; $s.status_text='Пауза: мост ждёт команды продолжить.'; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null; Start-Sleep -Seconds $loopDelay; continue }

  # 🩺 Doctor pre-checks: pick up watchdog's repair.signal, or seed the doctor task if active.
  # When Doctor is active and current_task is empty, we synthesize the doctor task (diagnose +
  # minimal fix + verify + commit) and let the normal pipeline run it. On its DONE we restore
  # the held task. Max attempts gate prevents infinite repair loops.
  try {
    $sigReason = Test-DoctorSignal
    if ($sigReason -and -not [bool]$state.doctor_active -and [string]::IsNullOrWhiteSpace([string]$state.held_task)) {
      Activate-Doctor -Reason $sigReason -Detail 'signal from watchdog' | Out-Null
      $state = Read-State
    }
  } catch {}
  # Restart-loop trigger (wave 3): >=3 restarts in 5 min with no ok turns -> Doctor.
  # User reported 2026-05-26: bridge restarted 4x without Doctor activating; this closes that gap.
  # GUARD (2026-05-26 second fix): Test-RestartLoop counts the LAST 5 min of conversation
  # restart events. On a fresh boot after a prior restart loop, those old events are still
  # in the window and would false-positive Doctor. Skip the check during the driver's first
  # 90s of uptime so the "noise from the past" ages out before we look.
  if (-not [bool]$state.doctor_active) {
    $driverUptime = 0
    try { $driverUptime = ((Get-Date) - [datetime]$state.driver_started).TotalSeconds } catch {}
    if ($driverUptime -ge 90) {
      try {
        $loopReason = Test-RestartLoop
        if ($loopReason) {
          Activate-Doctor -Reason 'restart_loop' -Detail $loopReason | Out-Null
          $state = Read-State
        }
      } catch {}
    }
  }
  if ([bool]$state.doctor_active -and [string]::IsNullOrWhiteSpace([string]$state.current_task)) {
    $maxA = Get-DoctorMaxAttempts
    $att  = [int]$state.doctor_attempts
    if ($att -ge $maxA) {
      Abort-Doctor -Reason "max attempts ($maxA) reached"
      Start-Sleep -Seconds $loopDelay; continue
    }
    try {
      $doctorTask = Get-DoctorTaskText
      $baseCommitD = ''
      try { $baseCommitD = (& git -C $bridgeRoot rev-parse HEAD 2>$null).Trim() } catch {}
      Update-State ({ param($s)
        $s.current_task     = $doctorTask
        $s.task_turn        = 0
        $s.task_mode        = 'normal'
        $s.task_start_seq   = [int]$s.lastSeq
        Clear-AuditorSuppressedHashes -State $s
        Clear-FastLaneFlags $s
        Clear-ChunkingState $s
        $s.doctor_attempts  = [int]$s.doctor_attempts + 1
        $s.status           = 'working'
        $s.heartbeat        = (Get-Date).ToString('o')
        $s | Add-Member -NotePropertyName task_base_commit -NotePropertyValue $baseCommitD -Force
        Reset-TaskAgentDuration $s
      }.GetNewClosure()) | Out-Null
      try { Add-SessionDecisionEvent -EventType 'doctor_fix' -Meta @{ what='doctor_activated' } -Channel $Channel } catch {}
      try { Add-Message -From system -Text "🩺 Доктор приступает к диагностике и фиксу." -Kind event | Out-Null } catch {}
      $state = Read-State
    } catch {
      try { Add-Message -From system -Text ("🩺 Доктор: ошибка при подготовке задачи: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
      Abort-Doctor -Reason "setup error"
      Start-Sleep -Seconds $loopDelay; continue
    }
  }

  try {
    $curatorDecisions = @(Get-NewCuratorDecisions)
    if ($curatorDecisions.Count -gt 0) { Publish-CuratorDecisionEvents -Decisions $curatorDecisions }
  } catch {
    try { Add-Message -From system -Text ("⚠ Curator decision poll failed: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
  }

  # --- BACKGROUND JOBS: if any are running, WAIT (poll) instead of running an agent turn,
  #     so long commands (e.g. hour-long project runs) don't time out and the bridge is
  #     neither "idle" (no autonomy grab) nor killed. Results are fed back when done.
  $activeJobs = @(); try { if ($state.active_jobs) { $activeJobs = @($state.active_jobs) } } catch {}
  if ($activeJobs.Count -gt 0) {
    $jobMaxH = 6; try { $cfgJ = Get-BridgeConfig; if ($cfgJ.PSObject.Properties.Name -contains 'jobMaxHours') { $jobMaxH = [double]$cfgJ.jobMaxHours } } catch {}
    $stillRunning = New-Object System.Collections.Generic.List[object]
    foreach ($job in $activeJobs) {
      $finished = $false; $reason = 'done'
      if (Test-JobDone $job) { $finished = $true }
      else {
        $ageMin = 99999; try { $ageMin = ((Get-Date).ToUniversalTime() - ([datetime]$job.started).ToUniversalTime()).TotalMinutes } catch {}
        # ORPHAN DETECTION (FIX 2026-05-26): if the launched process is dead AND no .done
        # marker was written, the job was killed mid-run (typical cause: bridge restart
        # while visit.ps1 was running). Without this, the driver waits up to jobMaxH (6h)
        # before timing out, blocking ALL new user input meanwhile. We give 3 minutes for
        # the runner to start + write its .done; after that, dead pid = orphan.
        $isOrphan = $false
        if ($ageMin -ge 3) {
          try {
            $jp = 0; try { $jp = [int]$job.pid } catch {}
            if ($jp -le 0) {
              $isOrphan = $true   # no PID ever recorded -- bad startup, dead since birth
            } else {
              $proc = Get-Process -Id $jp -ErrorAction SilentlyContinue
              if (-not $proc) { $isOrphan = $true }
              else {
                # Verify it's the SAME process (PID could be recycled). startTicks must match.
                $stickyTicks = 0; try { $stickyTicks = [long]$job.startTicks } catch {}
                if ($stickyTicks -gt 0) {
                  try { if ($proc.StartTime.Ticks -ne $stickyTicks) { $isOrphan = $true } } catch {}
                }
              }
            }
          } catch {}
        }
        if ($isOrphan) { $finished = $true; $reason = 'orphan' }
        elseif (($ageMin / 60.0) -ge $jobMaxH) { try { Stop-BridgeJob $job } catch {}; $finished = $true; $reason = 'timeout' }
      }
      if ($finished) {
        $res = Get-JobResult $job
        $cap = 1500   # cap "Вывод (хвост)" to avoid context flood
        $tail = [string]$res.tail
        if ($tail.Length -gt $cap) { $tail = '...(хвост обрезан)...' + "`n" + $tail.Substring($tail.Length - $cap) }
        if ($reason -eq 'timeout') {
          Add-Message -From system -Text ("⏱ Фоновая задача [$($job.id)] превысила лимит ($jobMaxH ч) и остановлена.`nКоманда: $($job.cmd)`n`nВывод (хвост):`n$tail") -Kind event | Out-Null
        } elseif ($reason -eq 'orphan') {
          Add-Message -From system -Text ("⚠ Фоновая задача [$($job.id)] потеряна: процесс умер, не записав .done маркер (вероятно, перезапуск моста во время её работы). Снимаю с polling, продолжаю.`nКоманда: $($job.cmd)") -Kind event | Out-Null
        } else {
          Add-Message -From system -Text ("✅ Фоновая задача [$($job.id)] завершена (код выхода: $($res.exitCode)).`nКоманда: $($job.cmd)`n`nВывод (хвост):`n$tail") -Kind event | Out-Null
        }
      } else { [void]$stillRunning.Add($job) }
    }
    $remaining = @($stillRunning.ToArray())
    # LIVE background-job progress: surface the job's LAST LOG LINE so the UI shows WHAT it's doing,
    # not a silent "waiting" (operator 2026-05-29: "дал задачу, она висит, его работа не видна").
    $jobProgress = ''
    if ($remaining.Count -gt 0) {
      try {
        $lpath = [string]$remaining[0].log
        if ($lpath -and (Test-Path -LiteralPath $lpath)) {
          $ll = @([System.IO.File]::ReadAllLines($lpath, [System.Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
          if ($ll.Count -gt 0) { $last = ([string]$ll[-1]).Trim(); if ($last.Length -gt 64) { $last = $last.Substring(0,64) + '…' }; $jobProgress = ' — ' + $last }
        }
      } catch {}
    }
    Update-State ({ param($s) $s.active_jobs=$remaining; $s.status='working'; $s.heartbeat=(Get-Date).ToString('o'); $s.status_text=$(if ($remaining.Count -gt 0) { "⏳ Фоновая задача (" + $remaining.Count + ")" + $jobProgress } else { $null }) }.GetNewClosure()) | Out-Null
    if ($remaining.Count -gt 0) { Start-Sleep -Seconds $loopDelay; continue }
    $state = Read-State
  }

  $maxUser = Get-MaxUserSeq

  if (-not $state.current_task) {
    if ($maxUser -gt [int]$state.last_user_seq) {
      $script:idleStreak = 0   # user activity -> restore snappy idle cadence
      # 🤖 Autonomy metric (Foundation #3): operator stepped in -> the "no-intervention" streak ends.
      # Best is already captured at done-time; just reset the running counter.
      try { Update-State { param($s) $s | Add-Member -NotePropertyName autonomy_streak -NotePropertyValue 0 -Force } | Out-Null } catch {}
      $taskMsg = (Get-Messages -Since 0 | Where-Object { $_.from -eq 'user' })[-1].text
      $projectBindingForTask = Get-ActiveProjectBinding
      if ($projectBindingForTask -and ([string]$projectBindingForTask.slug -ne 'main') -and -not [bool]$projectBindingForTask.ok) {
        $slugForTask = [string]$projectBindingForTask.slug
        $reasonForTask = [string]$projectBindingForTask.error
        if ([string]::IsNullOrWhiteSpace($reasonForTask)) { $reasonForTask = "Канал '$slugForTask' не привязан к проекту" }
        $msg = @"
⚠ Канал '$slugForTask' не привязан к проекту. Задачу не запускаю, чтобы не уйти в bridge.

Добавь привязку в settings.json:
{
  "channels": {
    "$slugForTask": {
      "projectPath": "C:\\путь\\к\\проекту",
      "projectType": "тип проекта",
      "projectDescription": "краткое описание"
    }
  }
}

Причина: $reasonForTask
Затем повтори задачу.
"@
        Add-Message -From system -Text $msg -Kind event | Out-Null
        Update-State ({ param($s)
          $s.last_user_seq=$maxUser
          $s.current_task=$null
          $s.current_task_id=$null
          $s.status='idle'
          $s.active_agent=$null
          $s.active_model=$null
          $s.status_text=$null
          $s.heartbeat=(Get-Date).ToString('o')
        }.GetNewClosure()) | Out-Null
        Start-Sleep -Seconds $loopDelay
        continue
      }
      $studyDetect = Detect-StudyMode -TaskText $taskMsg
      # 🧭 [[DEEP-THINK]] marker forces discuss-mode dialog (Claude↔Codex back-and-forth)
      # instead of normal planner->coder. Used by Start-DeepThinkDialog on Sat/Sun nights.
      #
      # FIX 2026-05-27: anchor the marker to its own line at start (multi-line ^). Previously
      # the regex matched the literal anywhere in the task text -- so if a spec MENTIONED the
      # marker in an example or referenced it in instructions to Codex, the task itself
      # got routed to discuss-mode. Now requires marker to be alone on a line (with optional
      # leading whitespace) -- can't be inside code blocks, quotes, or prose.
      $deepThinkMark = [bool]([regex]::IsMatch($taskMsg, '(?m)^\s*\[\[DEEP-THINK\]\]\s*$'))
      # 2026-05-28: ALSO trigger discuss-mode if task contains explicit discussion
      # verbs anywhere in text. This is a deterministic override BEFORE the LLM
      # intent classifier — was needed because classifier weighs by overall
      # task topic and silently drops "обсудите коротко" sections in mostly-
      # implementation tasks. Forces discuss when user explicitly asks for it,
      # regardless of how much implementation spec is attached.
      $discussVerbRegex = '(?im)\b(обсуди(?:м|те|ть)?|обсудим(?:те)?|посоветуйс(?:я|е)|согласуй(?:те|тесь)?|давайте\s+обсудим|подумайте\s+вместе|перед(?:\s+тем)?\s+(?:чем|как)[^.]{0,80}обсуд|coordinate\s+with\s+codex|discuss\s+with\s+codex)'
      $discussVerbMark = [bool]([regex]::IsMatch($taskMsg, $discussVerbRegex))
      # [[NORMAL]] override forces task_mode=normal even if other auto-detect would route
      # elsewhere (study/discuss). For operators who know "obsuzhdat' nechego, delay".
      # [[NORMAL]] OR an explicit operator "finish / don't loop / this is recon" instruction wins
      # over the LLM intent classifier. FIX 2026-05-29: the classifier forced discuss on an audit
      # task that literally said "STATUS: DONE, без дебатов, не зацикливайся" -> it then looped on
      # the already-finished work. Operator phrasing must override the heuristic.
      $normalOverride = ([bool]([regex]::IsMatch($taskMsg, '(?m)^\s*\[\[NORMAL\]\]\s*$'))) -or ([bool]([regex]::IsMatch($taskMsg, '(?i)(не\s+зациклив|без\s+дебат|не\s+обсужда|не\s+уходи\s+в\s+обсужд|status:\s*done\b|это\s+разведка,?\s+не\s+стройка|один\s+сфокусированн\w*\s+проход)')))
      $fastLaneCfg = Get-FastLaneSettings
      # Control markers are commands only in the task header. Long prompts often
      # contain marker names in feature descriptions/examples.
      $fastMark = Test-TaskControlMarker -TaskText $taskMsg -Marker 'FAST'
      $reasoningHighMark = [bool]([regex]::IsMatch($taskMsg, '\[\[REASONING:high\]\]'))
      $autoFastLane = $false
      if (-not $fastMark -and -not $reasoningHighMark -and [bool]$fastLaneCfg.autoDetect) {
        $autoFastLane = Test-IsTrivialTask -TaskText $taskMsg -MinChars ([int]$fastLaneCfg.minChars)
      }
      $fastLaneReason = ''
      if ($fastMark -and -not $reasoningHighMark) { $fastLaneReason = 'marker' }
      elseif ($autoFastLane) { $fastLaneReason = 'auto' }

      # 2026-05-28: LLM intent classifier. Replaces hardcoded [[DEEP-THINK]] regex
      # with semantic understanding of the user's task. Explicit markers
      # ([[FAST]], [[NORMAL]], [[DEEP-THINK]]) always win; the LLM call only
      # fires when no marker forces a mode. Confidence threshold 0.7 prevents
      # acting on uncertain classifications (falls through to legacy detection).
      # Decomposed subtasks are surfaced to the planner via Format-IntentForPrompt
      # in Build-PromptHistory so the planner sees the structured breakdown,
      # not just a single mode tag.
      $taskIntent = $null
      if (-not $fastLaneReason -and -not $normalOverride -and -not $deepThinkMark -and (Get-Command Test-TaskIntent -ErrorAction SilentlyContinue)) {
        try { $taskIntent = Test-TaskIntent -TaskText $taskMsg -TimeoutSec 25 } catch { $taskIntent = $null }
      }
      $intentMode = ''
      if ($taskIntent -and [double]$taskIntent.confidence -ge 0.7) {
        $intentMode = [string]$taskIntent.primary_mode
      }
      # Convert intent into legacy mode flags so the existing switch below stays simple.
      $intentForcedFastLane = ($intentMode -eq 'fast')
      $intentForcedDiscuss  = ($intentMode -eq 'discuss')
      $intentForcedStudy    = ($intentMode -eq 'study')
      # 2026-05-29 complexity throttle: even when the classifier routed to a
      # heavy mode (e.g. discuss) by topic, a CONFIDENT trivial/simple verdict
      # means the task does not warrant the full ceremony. Test-IntentLowComplexity
      # gates on confidence>=0.7 + complexity in {trivial,simple} + turns<=4.
      # This is the fix for "show a desktop screenshot" being routed to a ~7-min
      # discuss debate. Honour the operator's autoDetect switch so the throttle
      # can be disabled wholesale; explicit markers already suppress $taskIntent.
      $intentLowComplexity = $false
      if ($taskIntent -and [bool]$fastLaneCfg.autoDetect -and (Get-Command Test-IntentLowComplexity -ErrorAction SilentlyContinue)) {
        try { $intentLowComplexity = [bool](Test-IntentLowComplexity -Intent $taskIntent) } catch { $intentLowComplexity = $false }
      }
      # Fast-lane skips planner/critic/reflect, so auto-routed intent fast paths
      # are limited to safe reversible OS/UI/read commands. Explicit [[FAST]]
      # remains an operator opt-in via $fastLaneReason='marker'.
      $fastLaneSafe = $false
      try { $fastLaneSafe = [bool](Test-IsSafeOsFastLaneTask -TaskText $taskMsg) } catch { $fastLaneSafe = $false }
      if (-not $fastLaneSafe) { $intentForcedFastLane = $false; $intentLowComplexity = $false }

      $taskProjectRoot = Get-ActiveProjectRoot
      if ([string]::IsNullOrWhiteSpace($taskProjectRoot)) { $taskProjectRoot = $bridgeRoot }
      $baseCommit = try { (& git -C $taskProjectRoot rev-parse HEAD 2>$null).Trim() } catch { '' }

      # Snapshot intent for the state mutator closure.
      $intentRecord = $null
      if ($taskIntent) {
        $intentRecord = [pscustomobject]@{
          primary_mode = [string]$taskIntent.primary_mode
          mode = [string]$taskIntent.primary_mode
          confidence = [double]$taskIntent.confidence
          reasoning = [string]$taskIntent.reasoning
          user_wants_dialogue = [bool]$taskIntent.user_wants_dialogue
          complexity = [string]$taskIntent.complexity
          estimated_turns = [int]$taskIntent.estimated_turns
          subtasks = @($taskIntent.subtasks)
          model = [string]$taskIntent.model
          ts = (Get-Date).ToUniversalTime().ToString('o')
        }
      }
      $intentForcedFastLaneClosure = $intentForcedFastLane
      $intentForcedDiscussClosure  = $intentForcedDiscuss
      $intentForcedStudyClosure    = $intentForcedStudy
      $discussVerbClosure          = $discussVerbMark
      $intentLowComplexityClosure  = $intentLowComplexity

      Update-State ({ param($s)
        $s.current_task=$taskMsg; $s.last_user_seq=$maxUser; $s.task_turn=0; $s.task_mode='normal'
        Start-ReplayForStateTask -State $s -TaskText $taskMsg -ChannelName $Channel
        $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0
        Clear-FastLaneFlags $s
        # Precedence: explicit markers > discuss-verb regex > LLM intent (high conf) > legacy detection.
        # discuss-verb is BEFORE the LLM intent fork: deterministic catch for
        # "обсуди" в любом месте текста, не зависит от того что классификатор
        # решил по доминирующей теме задачи (он часто прозевает discuss-секции
        # в задачах с большим implementation-спеком).
        # 2026-05-29: a CONFIDENT trivial/simple verdict ($intentLowComplexityClosure)
        # neuters the two "discuss" branches so a 1-line change can't be dragged into
        # a multi-turn Claude<->Codex debate; it then lands on the new fast-lane catch
        # below (after study, which keeps its own output contract). Markers/normal/
        # deep-think still win because they suppress $taskIntent upstream.
        if ($fastLaneReason) { Set-FastLaneFlags -State $s -Reason $fastLaneReason; $s.task_mode='normal' }
        elseif ($normalOverride) { $s.task_mode='normal' }  # explicit operator force
        elseif ($deepThinkMark) { $s.task_mode='discuss'; $s.discuss_turn=0 }
        elseif ($discussVerbClosure -and -not $intentLowComplexityClosure) { $s.task_mode='discuss'; $s.discuss_turn=0 }
        elseif ($intentForcedFastLaneClosure) { Set-FastLaneFlags -State $s -Reason 'llm-intent'; $s.task_mode='normal' }
        elseif ($intentForcedDiscussClosure -and -not $intentLowComplexityClosure) { $s.task_mode='discuss'; $s.discuss_turn=0 }
        elseif ($intentForcedStudyClosure) { $s.task_mode='study'; $s.study_subtype='external'; $s.study_phase='plan' }
        elseif ($studyDetect) { $s.task_mode='study'; $s.study_subtype=[string]$studyDetect.subtype; $s.study_phase='plan' }
        elseif ($intentLowComplexityClosure) { Set-FastLaneFlags -State $s -Reason 'llm-simple'; $s.task_mode='normal' }
        $s.task_start_seq=$maxUser; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.current_backlog_id=$null; $s.status='working'; $s.status_text=$null; $s.heartbeat=(Get-Date).ToString('o')
        $s | Add-Member -NotePropertyName progress_fingerprints -NotePropertyValue @() -Force
        $s | Add-Member -NotePropertyName task_loop_count -NotePropertyValue 0 -Force
        # 2026-05-28: reset restart-counter when a new task arrives. Counter
        # tracks "this task survived N driver restarts without closing" and
        # auto-fails the task at $maxRestarts (boot.ps1 resume block).
        $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue 0 -Force
        Clear-AuditorSuppressedHashes -State $s
        Clear-ChunkingState $s
        $s | Add-Member -NotePropertyName task_base_commit -NotePropertyValue $baseCommit -Force
        $s | Add-Member -NotePropertyName critic_retry_count -NotePropertyValue 0 -Force
        # Persist intent so planner can render it via Format-IntentForPrompt on later turns too.
        $s | Add-Member -NotePropertyName task_intent -NotePropertyValue $intentRecord -Force
        Reset-TaskAgentDuration $s
      }.GetNewClosure()) | Out-Null
      try { [void](Archive-Plan) } catch { Add-Message -From system -Text ("⚠ Не удалось архивировать plan.jsonl: " + $_.Exception.Message) -Kind event | Out-Null }
      try { Clear-TaskCheckpoint } catch { Add-Message -From system -Text ("⚠ Не удалось очистить task checkpoint: " + $_.Exception.Message) -Kind event | Out-Null }
      Add-Message -From system -Text "📥 Новая задача принята в работу." -Kind event | Out-Null
      if ($fastLaneReason -eq 'marker') { Add-Message -From system -Text "🚀 Fast-lane активирован ([[FAST]])" -Kind event | Out-Null }
      elseif ($fastLaneReason -eq 'auto') { Add-Message -From system -Text "🚀 Auto fast-lane detected (короткая императивная задача)" -Kind event | Out-Null }
      if ($normalOverride -and -not $fastLaneReason) { Add-Message -From system -Text "📐 [[NORMAL]] override -- task_mode=normal forced (auto-detect bypassed)." -Kind event | Out-Null }
      if ($deepThinkMark -and -not $fastLaneReason -and -not $normalOverride) { Add-Message -From system -Text "🧭💭 Deep-think dialog detected — режим: discuss (Claude↔Codex до сходимости, max 6 ходов)." -Kind event | Out-Null }
      if ($discussVerbMark -and -not $deepThinkMark -and -not $fastLaneReason -and -not $normalOverride -and -not $intentLowComplexity) { Add-Message -From system -Text "🗣 Discuss-verb detected (обсуди/согласуйте/...) — режим: discuss (Claude↔Codex до сходимости, max 6 ходов). Хочешь обычный режим без обсуждения — добавь [[NORMAL]] в начало задачи." -Kind event | Out-Null }
      if ($studyDetect -and -not $deepThinkMark -and -not $fastLaneReason -and -not $normalOverride -and -not $intentForcedDiscuss -and -not $intentForcedStudy -and -not $intentForcedFastLane) { Add-Message -From system -Text "📚 Study-режим: триггер «$([string]$studyDetect.trigger)» · источник: user" -Kind event | Out-Null }
      # 2026-05-28: announce LLM-classifier verdict so user sees what mode was inferred and why.
      if ($taskIntent -and -not $deepThinkMark -and -not $fastLaneReason -and -not $normalOverride) {
        $confPct = [int]([double]$taskIntent.confidence * 100)
        $verdictText = "🧠 LLM-классификатор намерения ($([string]$taskIntent.model)): mode=" + [string]$taskIntent.primary_mode + ", confidence=$confPct%"
        if (-not [string]::IsNullOrWhiteSpace([string]$taskIntent.reasoning)) { $verdictText += "`n   причина: " + [string]$taskIntent.reasoning }
        if ([bool]$taskIntent.user_wants_dialogue) { $verdictText += "`n   ⚠ пользователь явно хочет диалог" }
        if ($intentLowComplexity) { $verdictText += "`n   → режим: fast-lane (простая задача — пропускаю планировщик/критика/обсуждение). Нужен полный разбор — добавь [[DEEP-THINK]]." }
        elseif ($intentForcedDiscuss) { $verdictText += "`n   → режим: discuss (Claude↔Codex)" }
        elseif ($intentForcedStudy) { $verdictText += "`n   → режим: study" }
        elseif ($intentForcedFastLane) { $verdictText += "`n   → режим: fast-lane (skip planner)" }
        elseif ([double]$taskIntent.confidence -lt 0.7) { $verdictText += "`n   (confidence < 70% → не применён, режим normal)" }
        Add-Message -From system -Text $verdictText -Kind event | Out-Null
      }
      $state = Read-State
    } else {
      # Reconcile: a backlog task that ended without success leaves current_backlog_id set.
      $leftBid = [string]$state.current_backlog_id
      $leftBatchIds = @()
      try {
        if ($state.PSObject.Properties.Name -contains 'workpack_batch_ids' -and $null -ne $state.workpack_batch_ids) {
          $leftBatchIds = @($state.workpack_batch_ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
      } catch { $leftBatchIds = @() }
      $leftIds = @(@($leftBid) + @($leftBatchIds) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
      if ($leftIds.Count -gt 0) {
        $failedN = 0
        foreach ($leftId in $leftIds) {
          try {
            if ((Get-IdeaById -Id $leftId).status -eq 'running') {
              Set-Idea -Id $leftId -Status 'failed' | Out-Null
              $failedN++
            }
          } catch {}
        }
        if ($failedN -gt 0) {
          Add-Message -From system -Text "⚠ Автозадача из бэклога не завершилась успешно — помечено failed: $failedN." -Kind event | Out-Null
        }
        Update-State { param($s) $s.current_backlog_id=$null; $s | Add-Member -NotePropertyName workpack_batch_ids -NotePropertyValue @() -Force; $s | Add-Member -NotePropertyName workpack_batch_active -NotePropertyValue $false -Force; $s | Add-Member -NotePropertyName workpack_batch_dispatched -NotePropertyValue $false -Force } | Out-Null
        $state = Read-State
      }
      # Learning loop: metric snapshot during idle every 3 hours, plus hypothesis reflection.
      $_lastSnap = try { Get-LastMetricsSnapshot } catch { $null }
      $_snapAgeH = if ($_lastSnap) { ([DateTime]::UtcNow - [DateTime]$_lastSnap.ts).TotalHours } else { 999 }
      # Snapshot every 3h (cheap, just stats from turns.jsonl).
      if ($_snapAgeH -ge 3) { try { Write-MetricsSnapshot } catch {} }
      # Hypothesis verdict closure runs ONLY in the nightly quiet window 02:00-06:00 local
      # (user feedback 2026-05-26: "по будильнику, когда я точно сплю"). Heavier I/O + Add-Memory
      # call doesn't bother the user, and we still close verdicts within ~24h.
      try { if (Test-WithinQuietHours -StartHour 2 -EndHour 6) { Invoke-MetricsReflection } } catch {}

      # 🧭 Architect (meta-improvement): cron-style, fires when idle if 24h passed OR 10
      # closed tasks accumulated since last run. Architect proposes STRUCTURAL gaps as
      # backlog ideas (tag=architect status=new -> needs user approval). Different from
      # reflect.ps1 (leaf-level tweaks) and Doctor (acute repair).
      try { Start-ArchitectIfDue -Mode 'normal' } catch {}
      try { Start-DeepThinkIfDue } catch {}
      try { Start-ThinkingReflectionIfDue } catch {}   # internal-thinking step 3: deep reflection -> one insight -> journal
      try { Start-AuditorIfDue } catch {}
      try {
        if ([string]$Channel -eq 'main') {
          if ($null -eq $script:LastTestCleanupTick) { $script:LastTestCleanupTick = 0 }
          $script:LastTestCleanupTick = [int]$script:LastTestCleanupTick + 1
          if ($script:LastTestCleanupTick -ge 30) {
            $script:LastTestCleanupTick = 0
            $cleaned = @(Invoke-TestChannelCleanup -GraceMinutes 10)
            if ($cleaned.Count -gt 0) {
              Write-Host ("[cleanup] processed test channels: " + (($cleaned | ForEach-Object { $_.Name }) -join ', '))
            }
          }
        }
      } catch {}

      # Backlog packer: when many ideas arrived in a short window, annotate them into workpacks
      # before the autonomy picker starts draining the queue one task at a time. This only groups
      # metadata; approval/preflight/execution stay in the existing backlog pipeline.
      try {
        Request-BacklogPackIfNeeded | Out-Null
        $packRun = Invoke-BacklogPackerIfDue
        if ($packRun -and [bool]$packRun.ran -and [int]$packRun.packed_items -gt 0) {
          Add-Message -From system -Text ("📦 Бэклог упакован: {0} задач → {1} workpack(s). Исполнение не меняю: approval и pre-flight остаются обязательными." -f [int]$packRun.packed_items, [int]$packRun.workpack_count) -Kind event | Out-Null
        }
        $reclassifyDue = $false
        $reclassifyNow = [DateTime]::UtcNow
        if ($packRun -and [bool]$packRun.ran -and [int]$packRun.packed_items -gt 0) { $reclassifyDue = $true }
        if ($null -eq $script:LastBacklogWorkpackReclassifyAt) {
          $reclassifyDue = $true
        } elseif (($reclassifyNow - [DateTime]$script:LastBacklogWorkpackReclassifyAt).TotalMinutes -ge 10) {
          $reclassifyDue = $true
        }
        if ($reclassifyDue) {
          $script:LastBacklogWorkpackReclassifyAt = $reclassifyNow
          $reclassified = Update-BacklogWorkpackClassifications
          if ([int]$reclassified -gt 0) {
            Add-Message -From system -Text ("🧭 Workpack classification refreshed: {0} open packed task(s)." -f [int]$reclassified) -Kind event | Out-Null
          }
        }
      } catch {}

      # Autonomy: after enough idle quiet, take the next approved backlog idea and run it
      # as a self-task. Freshness skips are logged by backlog/curator and surfaced via poll.
      $claimedIdea = $null
      $claimedIdeaSelection = $null
      $claimedWorkpackBatch = $false
      $auditBusyForAutonomy = $false
      try { $auditBusyForAutonomy = Test-AuditMaintenanceBusy } catch {}
      if ((-not $auditBusyForAutonomy) -and (Test-AutonomyReady)) {
        # Project Autopilot: project-bound channels should not need the operator to keep
        # feeding atoms. When their runnable backlog is empty, enqueue a coordinator task
        # that reads the durable project plan and emits the next [[PROJECT_BACKLOG]] batch.
        try {
          $paStart = Start-ProjectAutopilotIfNeeded -Reason 'idle-empty-backlog'
          if ($paStart -and [string]$paStart.reason -eq 'paused-empty-scope') {
            Start-ProjectAcceptanceIfDue -Channel $Channel -Trigger 'autopilot-empty-scope' | Out-Null
          }
          elseif ($paStart -and [string]$paStart.reason -eq 'plan-not-approved') {
            # 2026-06-02 Discuss-First gate: notify ONCE (marker file) that autopilot is held until the
            # operator approves the PROJECT_PLAN (Ф4). No spam: the marker is cleared by Set-ProjectPlanApproved.
            try {
              $gateMark = Join-Path (Join-Path (Join-Path $bridgeRoot 'channels') $Channel) '.plan-gate-notified'
              if (-not (Test-Path -LiteralPath $gateMark)) {
                Add-Message -From system -Text ("⏸ Project Autopilot ждёт утверждения PROJECT_PLAN (Discuss-First Ф4). Backlog пуст, но автогенерация атомов НЕ запускается без одобрения видения оператором. Когда план обсуждён и утверждён — выполни: Set-ProjectPlanApproved -Channel '" + $Channel + "'.") -Kind event | Out-Null
                Set-Content -LiteralPath $gateMark -Value ((Get-Date).ToUniversalTime().ToString('o')) -Encoding ASCII
              }
            } catch {}
          }
          elseif ($paStart -and [string]$paStart.reason -eq 'plan-contract-not-ready') {
            # Plan approval is not enough if the durable map/plan/UX contract is missing, shallow, or stale.
            # Notify once; Set-ProjectPlanApproved clears this marker after a valid contract is approved.
            try {
              $contractMark = Join-Path (Join-Path (Join-Path $bridgeRoot 'channels') $Channel) '.plan-contract-gate-notified'
              if (-not (Test-Path -LiteralPath $contractMark)) {
                $issueText = ''
                try { $issueText = ((@($paStart.issues) | Select-Object -First 4) -join '; ') } catch { $issueText = '' }
                if ([string]::IsNullOrWhiteSpace($issueText)) { $issueText = 'project contract is not ready' }
                Add-Message -From system -Text ("Project Autopilot paused: approved plan is not implementation-ready. Need deep PROJECT_MAP.md, PROJECT_PLAN.md, and .bridge/project-contract.json before atom generation. Issues: " + $issueText) -Kind event | Out-Null
                Set-Content -LiteralPath $contractMark -Value ((Get-Date).ToUniversalTime().ToString('o')) -Encoding ASCII
              }
            } catch {}
          }
        } catch {}
      }
      if ((-not $auditBusyForAutonomy) -and (Test-AutonomyReady)) {
        # Workpack execution layer: before claiming a single backlog item, try to claim a small
        # batch of already-approved, non-conflicting workpack items. The batch still enters the
        # normal task pipeline, so planner parallel-dispatch, critic, smoke, and pre-flight gates
        # remain the authority.
        try {
          $wpBatch = Get-NextBacklogWorkpackBatch
          if ($wpBatch -and [int]$wpBatch.count -ge 2) {
            $wpCfg = Get-BacklogWorkpackExecConfig
            $safeItems = New-Object 'System.Collections.Generic.List[object]'
            foreach ($wpItem in @($wpBatch.items)) {
              $wpId = [string]$wpItem.id
              $wpGate = $null
              try { $wpGate = Test-AutonomousTaskSafe -TaskText ('[Автозадача из workpack] ' + [string]$wpItem.text) -BridgeRoot $bridgeRoot } catch { $wpGate = [pscustomobject]@{ safe=$true; risk='unknown'; reason='gate exception fail-open' } }
              if ($wpGate -and -not [bool]$wpGate.safe) {
                try { Set-Idea -Id $wpId -Status 'held' | Out-Null } catch {}
                Add-Message -From system -Text ("🛑 Workpack pre-flight: item " + $wpId + " заблокирован (риск=" + [string]$wpGate.risk + "): " + [string]$wpGate.reason) -Kind event | Out-Null
                try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='workpack-preflight-blocked'; item_id=$wpId; risk=[string]$wpGate.risk; reason=[string]$wpGate.reason }) } catch {}
                continue
              }
              [void]$safeItems.Add($wpItem)
            }
            if ($safeItems.Count -ge [int]$wpCfg.minItems) {
              $safeArr = @($safeItems.ToArray())
              $batchText = New-BacklogWorkpackBatchTaskText -Items $safeArr
              $batchIds = @($safeArr | ForEach-Object { [string]$_.id })
              $claimedIdea = [pscustomobject]@{
                id = [string]$batchIds[0]
                text = $batchText
                workpack_batch = $true
                workpack_batch_ids = @($batchIds)
                workpack_batch_count = $safeArr.Count
                preflight_checked = $true
                workpack_frontier = [pscustomobject]@{
                  eligible = [int]$wpBatch.eligible_count
                  ready = [int]$wpBatch.ready_count
                  dependency_wait = [int]$wpBatch.dependency_wait_count
                  structural_wait = [int]$wpBatch.structural_wait_count
                  conflict_skips = [int]$wpBatch.conflict_skip_count
                  touch_skips = [int]$wpBatch.touch_skip_count
                }
              }
              $claimedWorkpackBatch = $true
              try {
                Write-BacklogJsonLine ([ordered]@{
                  ts=(Get-Date).ToUniversalTime().ToString('o')
                  action='workpack-batch-claim'
                  item_ids=@($batchIds)
                  count=$safeArr.Count
                  workpacks=@($safeArr | ForEach-Object { [string]$_.workpack_id } | Sort-Object -Unique)
                  conflict_groups=@($safeArr | ForEach-Object { [string]$_.workpack_conflict_group } | Sort-Object -Unique)
                  eligible=[int]$wpBatch.eligible_count
                  ready=[int]$wpBatch.ready_count
                  dependency_wait=[int]$wpBatch.dependency_wait_count
                  structural_wait=[int]$wpBatch.structural_wait_count
                  conflict_skips=[int]$wpBatch.conflict_skip_count
                  touch_skips=[int]$wpBatch.touch_skip_count
                })
              } catch {}
            }
          }
        } catch {}
      }
      if ((-not $claimedIdea) -and (-not $auditBusyForAutonomy) -and (Test-AutonomyReady)) {
        try {
          $claimedIdeaSelection = Get-NextApprovedIdea
          if ($claimedIdeaSelection -and ($claimedIdeaSelection.PSObject.Properties.Name -contains 'skipped')) {
            $skipDecisions = @($claimedIdeaSelection.skipped)
            if ($skipDecisions.Count -gt 0) { Publish-CuratorDecisionEvents -Decisions $skipDecisions }
          }
          if ($claimedIdeaSelection -and (($claimedIdeaSelection.PSObject.Properties.Name -contains 'idea') -or ($claimedIdeaSelection.PSObject.Properties.Name -contains 'item'))) {
            $claimedIdea = Get-ObjectValue $claimedIdeaSelection @('idea','item')
          } elseif ($claimedIdeaSelection -and (($claimedIdeaSelection.PSObject.Properties.Name -contains 'id') -or ($claimedIdeaSelection.PSObject.Properties.Name -contains 'text'))) {
            $claimedIdea = $claimedIdeaSelection
          }
        } catch {}
      }
      # 🌱 Increment B -- graduated self-development: AUTO-CLAIM of an UNapproved 'new' idea within
      # the operator's selfExecuteTier dial. When no human/curator-approved idea is queued and the
      # dial is 'green'/'yellow', take the next runnable 'new' idea whose risk tier is within the
      # dial (Get-NextSelfExecIdea excludes external/radar and red-tier, and skips past out-of-dial
      # items so the queue can't wedge). It is promoted into $claimedIdea HERE -- BEFORE the dirty
      # guard -- so it runs the IDENTICAL pipeline as approved ideas (dirty guard, smoke+critic
      # gates, verdict auto-revert). $selfDev* are read by the shadow-observability block below.
      $selfDevTier = 'off'
      $selfDevClaimed = $false
      $selfDevPick = $null
      $selfDevTierOfPick = ''
      $selfDevReason = ''
      if ((-not $claimedIdea) -and (-not $auditBusyForAutonomy) -and ([string]$Channel -eq 'main') -and (Test-AutonomyReady)) {
        try { $selfDevTier = ([string](Get-AutonomySettings).selfExecuteTier).ToLowerInvariant() } catch { $selfDevTier = 'shadow' }
        # 🛡 Safety reflex: if recent self-exec commits regressed (verdict 'worse'), dial DOWN one
        # notch BEFORE picking again, so the system throttles its own autonomy after regressions.
        try {
          $reflex = Test-SelfDevSafetyReflex -CurrentDial $selfDevTier
          if ($reflex -and $reflex.shouldDampen) {
            try { Set-AutonomySetting @{ selfExecuteTier = [string]$reflex.newDial } | Out-Null } catch {}
            Add-Message -From system -Text ("🛡 Само-защита: понижаю диск само-развития $($reflex.fromDial)→$($reflex.newDial) — недавние авто-коммиты дали регресс (worse=$($reflex.worseCount)). Система притормаживает сама.") -Kind event | Out-Null
            try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='self-dev-dampen'; from=[string]$reflex.fromDial; to=[string]$reflex.newDial; worse=[int]$reflex.worseCount }) } catch {}
            $selfDevTier = [string]$reflex.newDial
          }
        } catch {}
        if ($selfDevTier -eq 'green' -or $selfDevTier -eq 'yellow') {
          try { $selfDevPick = Get-NextSelfExecIdea -Dial $selfDevTier } catch { $selfDevPick = $null }
          if ($selfDevPick) {
            $rt = Get-IdeaRiskTier -Idea $selfDevPick
            $selfDevTierOfPick = [string]$rt.tier
            $selfDevReason = [string]$rt.reason
            try { Set-IdeaRiskTier -Id ([string]$selfDevPick.id) -Tier $selfDevTierOfPick -Reason $selfDevReason | Out-Null } catch {}
            $claimedIdea = $selfDevPick
            $selfDevClaimed = $true
            try { Set-IdeaSelfExec -Id ([string]$selfDevPick.id) -Dial $selfDevTier | Out-Null } catch {}
            $script:lastShadowIdeaId = [string]$selfDevPick.id
            $ideaPrev = [string]$selfDevPick.text
            if ($ideaPrev.Length -gt 80) { $ideaPrev = $ideaPrev.Substring(0,80) + '…' }
            Add-Message -From system -Text ("🌱 Само-развитие [диск=$selfDevTier]: беру НОВУЮ идею автономно (риск=$selfDevTierOfPick · $selfDevReason): «$ideaPrev»") -Kind event | Out-Null
            try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='self-exec-claim'; item_id=[string]$selfDevPick.id; tier=$selfDevTierOfPick; reason=$selfDevReason; dial=$selfDevTier }) } catch {}
          }
        }
      }
      # 2026-05-28: dirty-state guard. Before starting an autonomous task,
      # verify the bridge's working tree is clean. Starting work on top of
      # uncommitted edits leads to two bad outcomes: (a) Codex/Claude's diff
      # mixes its changes with whatever was sitting in the tree, making
      # rollback impossible; (b) a watchdog restart loses everything that
      # wasn't committed. Hold the task and ping the operator instead.
      if ($claimedIdea) {
        try {
          # 2026-05-31 (Foundation #4 lesson): per-channel dirty-guard. For a PROJECT
          # channel, check ITS OWN repo (project_root), NOT the bridge -- otherwise an
          # operator edit to the bridge control plane falsely freezes unrelated project
          # channels (this happened twice during the YoungChef run). Bridge channel keeps
          # the original bridge-root check + autosave filter.
          $guardRoot = $bridgeRoot
          $isProjectChannel = $false
          try {
            $pr = Get-EffectiveProjectRoot
            if (-not [string]::IsNullOrWhiteSpace([string]$pr) -and ([string]$pr -ne [string]$bridgeRoot)) { $guardRoot = [string]$pr; $isProjectChannel = $true }
          } catch {}
          $dirty = (& git -C $guardRoot status --porcelain 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
          if (-not $isProjectChannel) {
            # Bridge-only: filter out the perennial autosaved files that aren't real edits
            $dirty = @($dirty | Where-Object {
              $line = ([string]$_).Substring(3).Trim()
              $line -notmatch '^(decisions/session-ledger\.jsonl|turns\.jsonl|channels/[^/]+/state\.json|channels/[^/]+/conversation\.jsonl|features/state\.json|control/.*\.log|audit/.*\.md|audit/.*\.json|logs/.*)$'
            })
          }
          if ($dirty.Count -gt 0) {
            # Dirty tree is a TRANSIENT condition (uncommitted edits), so do NOT change the idea's
            # status -- marking it 'held' would STRAND it, since the selectors only pick 'new'/
            # 'approved' (this silently wedged self-/backlog tasks whenever a stray file sat in the
            # tree). Leave the idea in the queue and just skip this tick; it gets re-picked once the
            # tree is clean. Dedupe the notice by idea id so idle ticks don't spam while it stays dirty.
            if ([string]$claimedIdea.id -ne [string]$script:lastDirtyDeferId) {
              $script:lastDirtyDeferId = [string]$claimedIdea.id
              $preview = ($dirty | Select-Object -First 5 | ForEach-Object { ([string]$_).Trim() }) -join '; '
              Add-Message -From system -Text ("🚧 Автозадача отложена: рабочее дерево не чистое ($($dirty.Count) файлов). Закоммить или сделай stash; мост возьмёт задачу как только дерево станет чистым (идея остаётся в очереди). Превью: $preview") -Kind event | Out-Null
            }
            $claimedIdea = $null
          }
        } catch {
          # If git itself errors, fail open — better to start the task than wedge
          # the loop. The watchdog/critic will catch a bad commit downstream.
        }
      }
      # 🌒 Shadow observability (graduated autonomy; autonomy.selfExecuteTier). When an UNapproved
      # 'new' idea WOULD be the next self-pick but is NOT being executed this tick -- either the dial
      # is 'shadow' (observe-only) or the top idea's risk tier exceeds the dial -- surface it in chat
      # WITHOUT running it. (When the dial DID auto-claim an in-dial idea, $selfDevClaimed is set and
      # the claim path above already announced it.) Posts only when the would-pick CHANGES, so idle
      # ticks don't spam. main channel only.
      if ((-not $claimedIdea) -and (-not $selfDevClaimed) -and (-not $auditBusyForAutonomy) -and ([string]$Channel -eq 'main')) {
        try {
          $selfTier = if ($selfDevTier) { $selfDevTier } else { 'shadow' }
          if ($selfTier -and $selfTier -ne 'off' -and (Test-AutonomyReady)) {
            $shadowPick = $null
            try { $shadowPick = Get-NextRunnableIdea -IncludeNew $true } catch {}
            $shadowId = if ($shadowPick) { [string]$shadowPick.id } else { '' }
            # Only act when the would-pick CHANGES, so we don't repost every idle tick.
            if ($shadowId -ne [string]$script:lastShadowIdeaId) {
              $script:lastShadowIdeaId = $shadowId
              if ($shadowPick -and ([string]$shadowPick.status -eq 'new')) {
                $rt = Get-IdeaRiskTier -Idea $shadowPick
                $tier = [string]$rt.tier; $why = [string]$rt.reason
                try { Set-IdeaRiskTier -Id $shadowId -Tier $tier -Reason $why | Out-Null } catch {}
                $verb = if ($selfTier -eq 'shadow') { 'взяла бы (shadow, без запуска)' }
                        else { "НЕ запускает (риск=$tier выше диска=$selfTier)" }
                $ideaText = [string]$shadowPick.text
                if ($ideaText.Length -gt 80) { $ideaText = $ideaText.Substring(0,80) + '…' }
                Add-Message -From system -Text ("🌒 Само-развитие [диск=$selfTier]: $verb новую идею «$ideaText» · риск=$tier · $why") -Kind event | Out-Null
                try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='shadow-pick'; item_id=$shadowId; tier=$tier; reason=$why; dial=$selfTier; would_execute=$false }) } catch {}
              }
            }
          }
        } catch {}
      }
      if ($claimedIdea) {
        # 2026-05-30 PRE-EXECUTION SAFETY GATE: vet the TASK itself before running it.
        # Critic/QA validate the resulting code, not whether the task is harmful (a task
        # to delete a still-used file passes smoke). Blocked tasks -> 'held' (selectors
        # only pick new/approved, so they won't be re-claimed) + operator escalation.
        try {
          $preflightChecked = $false
          try {
            if ($claimedIdea.PSObject.Properties.Name -contains 'preflight_checked') { $preflightChecked = [bool]$claimedIdea.preflight_checked }
          } catch {}
          if (-not $preflightChecked) {
            $gate = Test-AutonomousTaskSafe -TaskText ('[Автозадача из бэклога] ' + [string]$claimedIdea.text) -BridgeRoot $bridgeRoot
            if (-not $gate.safe) {
              $gid = [string]$claimedIdea.id
              try { Set-Idea -Id $gid -Status 'held' | Out-Null } catch {}
              Add-Message -From system -Text ("🛑 Pre-flight gate: автозадача ЗАБЛОКИРОВАНА (риск=" + [string]$gate.risk + "): " + [string]$gate.reason + ". Помечена 'held' — нужна проверка оператора, мост её НЕ исполняет.") -Kind event | Out-Null
              try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='preflight-blocked'; item_id=$gid; risk=[string]$gate.risk; reason=[string]$gate.reason }) } catch {}
              $claimedIdea = $null
            }
          }
        } catch {}
      }
      if ($claimedIdea) {
        $script:idleStreak = 0   # autonomous task claimed -> snappy idle again once it finishes
        $bid = [string]$claimedIdea.id
        $batchIdsForState = @()
        try {
          if ($claimedIdea.PSObject.Properties.Name -contains 'workpack_batch_ids') {
            $batchIdsForState = @($claimedIdea.workpack_batch_ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
          }
        } catch { $batchIdsForState = @() }
        $isWorkpackBatch = ($batchIdsForState.Count -ge 2)
        $btext = if ($isWorkpackBatch) { [string]$claimedIdea.text } else { '[Автозадача из бэклога] ' + [string]$claimedIdea.text }
        $today = (Get-Date).ToString('yyyy-MM-dd')
        $studyDetect = Detect-StudyMode -TaskText $btext -IsAutonomous
        $taskRepoRootForBacklog = Get-TaskRepoRoot
        $baseCommit = try { (& git -C $taskRepoRootForBacklog rev-parse HEAD 2>$null).Trim() } catch { '' }
        Update-State ({ param($s)
          $s.current_task=$btext; $s.task_turn=0; $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0
          Start-ReplayForStateTask -State $s -TaskText $btext -ChannelName $Channel
          Clear-FastLaneFlags $s
          if ($studyDetect) { $s.task_mode='study'; $s.study_subtype=[string]$studyDetect.subtype; $s.study_phase='plan' }
          $s.task_start_seq=[int]$s.lastSeq; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.current_backlog_id=$bid; $s.status='working'; $s.heartbeat=(Get-Date).ToString('o')
          $s | Add-Member -NotePropertyName progress_fingerprints -NotePropertyValue @() -Force
          $s | Add-Member -NotePropertyName task_loop_count -NotePropertyValue 0 -Force
          $s | Add-Member -NotePropertyName workpack_batch_ids -NotePropertyValue @($batchIdsForState) -Force
          $s | Add-Member -NotePropertyName workpack_batch_active -NotePropertyValue $isWorkpackBatch -Force
          $s | Add-Member -NotePropertyName workpack_batch_dispatched -NotePropertyValue $false -Force  # ERR-006: fresh batch, not yet dispatched
          Clear-AuditorSuppressedHashes -State $s
          Clear-ChunkingState $s
          $s | Add-Member -NotePropertyName task_base_commit -NotePropertyValue $baseCommit -Force
          $s | Add-Member -NotePropertyName critic_retry_count -NotePropertyValue 0 -Force
          Reset-TaskAgentDuration $s
          if ([string]$s.autonomous_day -eq $today) { $s.autonomous_count=[int]$s.autonomous_count+1 } else { $s.autonomous_day=$today; $s.autonomous_count=1 }
        }.GetNewClosure()) | Out-Null
        try {
          $taskText = [string]$btext
          $taskForLedger = if ($taskText.Length -gt 120) { $taskText.Substring(0,120) } else { $taskText }
          Add-SessionDecisionEvent -EventType 'task_start' -Meta @{ task=$taskForLedger } -Channel $Channel
          $mGoal = if ($taskText.Length -gt 600) { $taskText.Substring(0,600) } else { $taskText }
          Update-State ({ param($s)
            $s.session_mission = [pscustomobject]@{ goal=$mGoal; next_step=''; accepted_decisions=@(); constraints=@(); recent_done=@(); blockers=@() }
          }.GetNewClosure()) | Out-Null
        } catch {}
        try { [void](Archive-Plan) } catch { Add-Message -From system -Text ("⚠ Не удалось архивировать plan.jsonl: " + $_.Exception.Message) -Kind event | Out-Null }
        try { Clear-TaskCheckpoint } catch { Add-Message -From system -Text ("⚠ Не удалось очистить task checkpoint: " + $_.Exception.Message) -Kind event | Out-Null }
        try {
          if ($isWorkpackBatch) {
            foreach ($batchId in $batchIdsForState) { Set-Idea -Id $batchId -Status 'running' -IncrementAttempts $true | Out-Null }
          } else {
            Set-Idea -Id $bid -Status 'running' -IncrementAttempts $true | Out-Null
          }
        } catch {}
        if ($isWorkpackBatch) {
          $frontierText = ''
          try {
            if ($claimedIdea.PSObject.Properties.Name -contains 'workpack_frontier' -and $claimedIdea.workpack_frontier) {
              $wf = $claimedIdea.workpack_frontier
              $frontierText = " Фронт: selected=" + $batchIdsForState.Count + ", ready=" + [int]$wf.ready + "/" + [int]$wf.eligible + ", ждут deps=" + [int]$wf.dependency_wait + ", barrier=" + [int]$wf.structural_wait + ", conflicts=" + ([int]$wf.conflict_skips + [int]$wf.touch_skips) + "."
            }
          } catch {}
          Add-Message -From system -Text ("🤖 Беру workpack-batch автономно: " + $batchIdsForState.Count + " approved задач из независимых workpacks." + $frontierText + " Дальше обычный planner/parallel/critic/smoke контур.") -Kind event | Out-Null
        } else {
          Add-Message -From system -Text "🤖 Беру задачу из бэклога в работу (автономно): $([string]$claimedIdea.text)" -Kind event | Out-Null
        }
        if ($studyDetect) { Add-Message -From system -Text "📚 Study-режим: триггер «$([string]$studyDetect.trigger)» · источник: backlog" -Kind event | Out-Null }
        $state = Read-State
      } else {
        Update-State { param($s) $s.status='idle'; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
        try { Start-LibrarianIfDue } catch {}
        try { Start-AuditIfDue } catch {}
        try { Start-FeatureVerifierIfDue } catch {}
        try { Update-FeatureActivations | Out-Null } catch {}
        try { Start-ReflectIfDue } catch {}
        try { Start-TechRadarIfDue } catch {}
        try { Start-ScholarIfDue } catch {}
        try { Start-CanaryIfDue } catch {}
        # 🧹 Anti-junk hygiene: archive unclaimed 'new' ideas older than ideaStaleDays. Throttled to
        # once per 24h via control/stale-sweep.last so it's near-free on the idle path.
        try {
          $ssMarker = Join-Path (Get-BridgeRoot) 'control\stale-sweep.last'
          $ssDue = $true
          if (Test-Path $ssMarker) { try { $ssDue = (((Get-Date) - [datetime]((Get-Content $ssMarker -Raw -Encoding UTF8).Trim())).TotalHours -ge 24) } catch {} }
          if ($ssDue) {
            [System.IO.File]::WriteAllText($ssMarker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
            $staleN = Invoke-BacklogStaleSweep
            if ($staleN -gt 0) { Add-Message -From system -Text "🧹 Гигиена бэклога: $staleN неразобранных идей старше срока → авто-архив (auto-stale)." -Kind event | Out-Null }
          }
        } catch {}
        # 🗄 Archive hygiene: weekly prune of conversation.archive.jsonl (lines older than 7 days).
        # Only the archive sidecar is touched — never the live chat or summary — so this can NOT
        # affect the bridge's context. Throttled via control/archive-prune.last (~7d).
        try {
          $apMarker = Join-Path (Get-BridgeRoot) 'control\archive-prune.last'
          $apDue = $true
          if (Test-Path $apMarker) { try { $apDue = (((Get-Date) - [datetime]((Get-Content $apMarker -Raw -Encoding UTF8).Trim())).TotalDays -ge 7) } catch {} }
          if ($apDue) {
            [System.IO.File]::WriteAllText($apMarker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
            $prunedN = Invoke-ConversationArchivePrune -MaxAgeDays 7
            if ($prunedN -gt 0) { Add-Message -From system -Text "🗄 Архив чата почищен: удалено $prunedN сообщений старше 7 дней (из архива, не из чата)." -Kind event | Out-Null }
          }
        } catch {}
        # 2026-05-27v6: log rotation every idle tick (cheap — Rotate-LogIfBig
        # is O(1) when file is under limit). 2MB cap = ~1 month of metrics.
        try {
          $brRoot = Get-BridgeRoot
          Rotate-LogIfBig -Path (Join-Path $brRoot 'metrics.jsonl')      -MaxKB 2048 -Keep 3 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'usage.jsonl')        -MaxKB 2048 -Keep 3 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'bridge-lock.log')    -MaxKB 512  -Keep 2 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'critic.log')         -MaxKB 1024 -Keep 3 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'control\tmp-leak.log')  -MaxKB 256  -Keep 1 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'control\tmp-sweep.log') -MaxKB 256  -Keep 1 | Out-Null
          Rotate-LogIfBig -Path (Join-Path $brRoot 'control\children.jsonl') -MaxKB 256 -Keep 1 | Out-Null
        } catch {}
        # 2026-05-27v6: sweep registered child processes (audit P2 -- detect crashed children)
        try { Sweep-ChildProcesses -MaxAgeMin 30 | Out-Null } catch {}
        # 2026-05-28: sweep orphan codex.exe processes (real incident: 11 zombies
        # accumulated, one 22h old, 360MB resident). NEVER touches claude.exe
        # (user IDE is also claude.exe). Configurable cutoff via config.json
        # orphanSweep.codexMaxIdleMin, default 30 minutes.
        try {
          $orphMax = 30
          try {
            $cfgO = Get-BridgeConfig
            if ($cfgO -and $cfgO.PSObject.Properties.Name -contains 'orphanSweep' -and $cfgO.orphanSweep -and $cfgO.orphanSweep.codexMaxIdleMin) {
              $orphMax = [int]$cfgO.orphanSweep.codexMaxIdleMin
            }
          } catch {}
          if ($orphMax -lt 5) { $orphMax = 5 }
          $ores = Sweep-OrphanAgentProcesses -MaxIdleMin $orphMax
          if ($ores -and [int]$ores.killed -gt 0) {
            Add-Message -From system -Text ("🧹 Auto-sweep: убит " + $ores.killed + " orphan codex.exe (старше " + $orphMax + " мин, не привязан к активному агенту)") -Kind event | Out-Null
          }
        } catch {}
        # Adaptive backoff: snappy for the first $idleFastTicks ticks after activity, then
        # +1s per extra consecutive idle tick, capped at $idleMaxPoll. Cuts redundant ~1Hz wakeups.
        $script:idleStreak = [int]$script:idleStreak + 1
        $sleepSec = $idlePoll
        if ($script:idleStreak -gt $idleFastTicks) { $sleepSec = [Math]::Min($idleMaxPoll, $idlePoll + ($script:idleStreak - $idleFastTicks)) }
        Start-Sleep -Seconds $sleepSec; continue
      }
    }
  } else {
    if ($maxUser -gt [int]$state.last_user_seq) { Update-State ({ param($s) $s.last_user_seq=$maxUser }.GetNewClosure()) | Out-Null }
  }

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
  if ($speaker -eq 'claude' -and ($mode -eq 'normal')) {
    $wpActive = $false; try { $wpActive = [bool](Read-State).workpack_batch_active } catch {}
    # 2026-06-01 ERR-006 fix: a workpack-batch must be dispatched to the worker pool EXACTLY ONCE.
    # Previously, if the post-dispatch verify/critic/smoke gate returned the task for rework, the next
    # turn re-entered this block (workpack_batch_active was still true) and blindly re-ran the WHOLE
    # batch — producing repeated collect-commits (observed: 23→22→16 files) until the loop-detector
    # fired Doctor. Now the first dispatch sets workpack_batch_dispatched; subsequent turns skip the
    # deterministic dispatch and fall through to the normal planner, which inspects the already-merged
    # result and drives it to DONE (or fixes it) instead of churning the repo.
    $wpDispatched = $false; try { $wpDispatched = [bool](Read-State).workpack_batch_dispatched } catch {}
    $projRootDet = ''; try { if (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) { $projRootDet = [string](Get-EffectiveProjectRoot) } } catch {}
    if ($wpActive -and -not $wpDispatched -and $projRootDet -and ($projRootDet -ne $bridgeRoot)) {
      $detStreams = $null; try { $detStreams = Test-CanParallelize -PlanText $task } catch {}
      if ($detStreams -and @($detStreams).Count -ge 2) {
        try {
          Add-Message -From system -Text ("🔀 Детерминированный parallel dispatch: " + @($detStreams).Count + " потоков из workpack-batch (без планировщика)") -Kind event | Out-Null
          $detRes = Invoke-ParallelDispatch -Streams $detStreams -TimeoutMin 25 -PollSec 10
          # Mark dispatched REGARDLESS of ok, so a fully-failed batch goes to the planner for diagnosis
          # rather than re-dispatching the same broken streams over and over (the ERR-006 loop).
          Update-State { param($s) $s | Add-Member -NotePropertyName workpack_batch_dispatched -NotePropertyValue $true -Force } | Out-Null
          $detQ = 0; try { $detQ = [int]$detRes.quarantined } catch {}
          $detTotal = 0; try { $detTotal = [int]$detRes.total } catch { $detTotal = @($detStreams).Count }
          if ($detTotal -le 0) { $detTotal = @($detStreams).Count }
          $detIdsForMemory = @()
          try {
            $stForWaveMemory = Read-State
            if ($stForWaveMemory.PSObject.Properties.Name -contains 'workpack_batch_ids') {
              $detIdsForMemory = @($stForWaveMemory.workpack_batch_ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
          } catch { $detIdsForMemory = @() }
          if ($detRes -and $detRes.ok -and $detQ -eq 0) {
            # CLEAN: every stream merged, none quarantined -> safe to synthesize DONE for the gates.
            Add-Message -From system -Text ("✅ Parallel завершён: " + $detRes.merged + " потоков слито в проект (все потоки успешны)") -Kind event | Out-Null
            try { Add-ProjectWaveMemory -Outcome 'complete' -Streams $detTotal -Merged ([int]$detRes.merged) -Quarantined 0 -BacklogIds $detIdsForMemory | Out-Null } catch {}
            Update-State { param($s) $s.task_did_actions = $true; $s.coder_fired = $true } | Out-Null
            $turnResult = [pscustomobject]@{ status = 'ok'; text = ("STATUS: DONE`nПараллельно выполнено потоков: " + $detRes.merged); fallback = '' }
          } elseif ($detRes -and $detRes.ok -and $detQ -gt 0) {
            # 2026-06-01 ERR-009: MIXED result (some merged, some FAILED/quarantined). Do NOT report a
            # generic "DONE: N потоков" — that masked failed streams. Partial work did land, so mark
            # actions, but force a planner turn to finish/repair the quarantined streams (sequentially,
            # since ERR-002 will gate them) instead of closing the task as done.
            Add-Message -From system -Text ("⚠ Parallel: СМЕШАННЫЙ результат — слито " + $detRes.merged + " из " + $detRes.total + " потоков, " + $detQ + " в карантине (провалились). НЕ закрываю как DONE; передаю планировщику доделать/починить провалившиеся потоки.") -Kind event | Out-Null
            try { Add-ProjectWaveMemory -Outcome 'partial' -Streams $detTotal -Merged ([int]$detRes.merged) -Quarantined $detQ -BacklogIds $detIdsForMemory -Reason 'some streams quarantined' | Out-Null } catch {}
            Update-State { param($s) $s.task_did_actions = $true; $s.coder_fired = $true; $s.force_planner = $true } | Out-Null
            # leave $turnResult null -> the planner runs this turn and drives the remaining work to DONE
          } else {
            Add-Message -From system -Text "⚠ Parallel dispatch не слил ни одного потока (все в карантине/провал) — передаю планировщику для разбора, без повторного слепого dispatch." -Kind event | Out-Null
            try { Add-ProjectWaveMemory -Outcome 'failed' -Streams $detTotal -Merged 0 -Quarantined $detQ -BacklogIds $detIdsForMemory -Reason 'no streams merged' | Out-Null } catch {}
          }
        } catch { try { Add-Message -From system -Text ("⚠ Детерминированный dispatch: " + $_.Exception.Message + " — обычный planner-ход") -Kind event | Out-Null } catch {} }
      }
    }
  }
  try {
    if ($turnResult) { }  # already produced by the deterministic dispatch above -> skip planner
    elseif ($speaker -eq 'claude') { $turnResult = Invoke-Planner -Prompt $prompt -Model $plannerModel -Mode $mode }
    else {
      $turnResult = Invoke-Coder -Prompt $prompt -Mode $mode
      # Track that the coder role actually ran for this task. A Claude fallback counts as
      # the coder for this turn because it has write tools and is not merely advisory.
      if ($turnResult.status -eq 'ok') { Update-State { param($s) $s.coder_fired = $true } | Out-Null }
    }
  } catch {
    Write-TurnLog -Speaker $speaker -Model $activeModel -Mode $mode -StartedAtUtc $turnStart -Reply $_.Exception.Message -Status 'error' -FastLane:$fastLaneTurn
    throw
  }
  $reply = [string]$turnResult.text
  Write-TurnLog -Speaker $speaker -Model $activeModel -Mode $mode -StartedAtUtc $turnStart -Reply $reply -Status ([string]$turnResult.status) -FastLane:$fastLaneTurn
  $guardChannelSlug = [string]$Channel
  try { $guardChannelSlug = Normalize-ChannelSlug $guardChannelSlug } catch {}
  if (($speaker -eq 'codex' -or [string]$turnResult.fallback -eq 'claude_as_coder') -and $guardChannelSlug -ne 'main') {
    try {
      $bridgeHeadAfterGuard = (& git -C $bridgeRoot rev-parse HEAD 2>$null).Trim()
      $bridgeDirtyAfterGuard = @(& git -C $bridgeRoot diff --name-only HEAD 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
      # Only files this turn NEWLY dirtied (After \ Before) or a HEAD move by THIS turn implicate
      # this channel. Pre-existing dirt (another channel working in parallel on the shared tree)
      # is excluded -> no more false halts from a sibling channel's legitimate edits.
      # 2026-05-31 (Foundation #4): exclude operator control-config edits (config/settings.json)
      # from the guard trigger. A PROJECT channel's coder is sandboxed to project_root and CANNOT
      # write the bridge -- so a config/settings change during its turn is the operator tuning the
      # bridge in parallel, not the coder escaping. Counting it falsely halted the project run.
      # 2026-06-01 fix (false-halt): exclude docs/operator files too. A project coder is sandboxed to
      # project_root and never writes these; if they changed, it's the operator/docs, not an escape.
      $newlyDirty = @($bridgeDirtyAfterGuard | Where-Object { $_ -notin $dirtyBeforeTurn -and $_ -notmatch '(^|/)(config|settings)\.json$' -and $_ -notmatch '\.md$' -and $_ -notmatch '(^|/)OPERATOR_ERROR_LOG' })
      # 2026-06-01 ROOT FIX: a bridge HEAD MOVE is NOT a coder-escape signal. A project coder is
      # sandboxed to project_root and CANNOT git-commit in the bridge (no .git access) — so a HEAD move
      # during its turn is ALWAYS an external commit (operator editing docs/config, the main channel's
      # driver, or Doctor), never the coder escaping. Counting it falsely halted live project tasks
      # (observed 2026-06-01: operator committing OPERATOR_ERROR_LOG.md mid-turn halted the
      # sample-project scaffold turn). The genuine escape signal is UNCOMMITTED bridge working-tree
      # changes newly appearing during the turn ($newlyDirty) — a coder writing outside its sandbox,
      # before any commit. Keep ONLY that; drop the $headMoved trigger.
      if (@($newlyDirty).Count -gt 0) {
        $changed = @($newlyDirty) -join ', '
        $guardMsg = "⚠ Project-focus guard: канал '$guardChannelSlug' не является main, но coder оставил НЕзакоммиченные правки в bridge: $changed. Останавливаю дальнейшие шаги и возвращаю планировщику для разбора."
        try { Set-TaskLastFailure -Kind bridge_guard -Text $guardMsg } catch {}
        Add-Message -From system -Text $guardMsg -Kind event | Out-Null
        Update-State { param($s) $s.force_planner=$true; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
        continue
      }
    } catch {
      Add-Message -From system -Text ("⚠ Project-focus guard не смог проверить bridge diff: " + $_.Exception.Message) -Kind event | Out-Null
    }
  }
  try {
    $turnSec = 0
    try { $turnSec = [int]$turnResult.duration } catch {}
    if ($turnSec -gt 0) {
      Update-State ({ param($s)
        $curSec = 0
        try { $curSec = [int]$s.task_agent_duration_sec } catch {}
        $s | Add-Member -NotePropertyName task_agent_duration_sec -NotePropertyValue ($curSec + $turnSec) -Force
      }.GetNewClosure()) | Out-Null
    }
  } catch {}
  if ($speaker -eq 'codex' -or [string]$turnResult.fallback -eq 'claude_as_coder') {
    try {
      $headAfterTurn = (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim()
      if (-not [string]::IsNullOrWhiteSpace($headBeforeTurn) -and -not [string]::IsNullOrWhiteSpace($headAfterTurn) -and $headBeforeTurn -ne $headAfterTurn) {
        $commitLines = @(& git -C $bridgeRoot log --reverse --format='%H%x09%s' "$headBeforeTurn..$headAfterTurn" 2>$null)
        foreach ($cl in $commitLines) {
          $parts = @(([string]$cl) -split "`t", 2)
          if ($parts.Count -lt 1 -or [string]::IsNullOrWhiteSpace($parts[0])) { continue }
          $sha = [string]$parts[0]
          $subj = if ($parts.Count -ge 2) { [string]$parts[1] } else { '' }
          $shortSha = if ($sha.Length -gt 7) { $sha.Substring(0, 7) } else { $sha }
          Add-TaskCheckpoint -Kind commit -Text (($shortSha + ' ' + $subj).Trim())
          try {
            $pmState = Read-State
            if ($pmState -and ($pmState.PSObject.Properties.Name -contains 'task_last_failure') -and $null -ne $pmState.task_last_failure) {
              $pmPath = Invoke-PostMortem -CommitSha $sha -State $pmState -RepoRoot $bridgeRoot -TimeoutSec 30
              if ($pmPath) { Add-Message -From system -Text ("📋 Post-mortem создан: " + $pmPath) -Kind event | Out-Null }
            }
          } catch {
            try { Add-Message -From system -Text ("⚠ Post-mortem не создан: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
          }
        }
      }
    } catch {}
  }

  # 2026-05-29: close the Gate-A commit gap. Codex runs in a workspace-write sandbox that BLOCKS
  # writes to .git (index.lock ACL "Permission denied"), so it often can't commit its own work and
  # reports "can't close the task honestly -- need a git commit via the driver". The driver runs
  # OUTSIDE the sandbox, so it commits the coder's verified edits right here. Without this, edits
  # sat uncommitted until a later turn happened to win the ACL race (real friction + extra loops).
  if (($speaker -eq 'codex' -or [string]$turnResult.fallback -eq 'claude_as_coder') -and ([string]$turnResult.status -eq 'ok')) {
    try {
      $headNowAC = (& git -C $bridgeRoot rev-parse HEAD 2>$null).Trim()
      if ($headNowAC -and $headBeforeTurn -and $headNowAC -eq $headBeforeTurn) {
        $acDirty = @(& git -C $bridgeRoot status --porcelain 2>$null | Where-Object {
          $line = ([string]$_).Substring(3).Trim()
          $line -notmatch '^(decisions/session-ledger\.jsonl|turns\.jsonl|channels/[^/]+/state\.json|channels/[^/]+/conversation\.jsonl|features/state\.json|control/.*|audit/.*|logs/.*)$'
        })
        if (@($acDirty).Count -gt 0) {
          $acFiles = @()
          foreach ($d in $acDirty) {
            $l = [string]$d; if ($l.Length -le 3) { continue }
            $nm = $l.Substring(3).Trim()
            if ($nm -match ' -> ') { $nm = ($nm -split ' -> ', 2)[1].Trim() }
            $nm = $nm.Trim('"'); if ($nm) { $acFiles += $nm }
          }
          if ($acFiles.Count -gt 0) {
            $acMsg = 'auto-commit (driver; coder sandbox cannot reach .git): ' + (($task -replace '\s+',' ').Trim())
            if ($acMsg.Length -gt 180) { $acMsg = $acMsg.Substring(0,180) }
            & git -C $bridgeRoot add -- @($acFiles) 2>$null | Out-Null
            & git -C $bridgeRoot commit -m $acMsg 2>$null | Out-Null
            $acNewHead = (& git -C $bridgeRoot rev-parse HEAD 2>$null).Trim()
            if ($acNewHead -and $acNewHead -ne $headBeforeTurn) {
              try { Add-TaskCheckpoint -Kind commit -Text (($acNewHead.Substring(0,7) + ' ' + $acMsg).Trim()) } catch {}
              Add-Message -From system -Text ("💾 Драйвер зафиксировал правки Codex (coder в sandbox не имеет доступа к .git): " + $acNewHead.Substring(0,7)) -Kind event | Out-Null
            }
          }
        }
      }
    } catch {}
  }

  # 2026-05-31 (Foundation #4): auto-commit PROJECT changes for project channels. The bridge
  # auto-commit above targets bridgeRoot; a PROJECT channel's coder writes project_root, which the
  # driver previously left uncommitted whenever the coder didn't self-commit -> the task wedged the
  # tree dirty and the per-channel dirty-guard then blocked all following tasks (ValueSection/
  # HowItWorks observed during the redesign run). Commit any project_root changes after the turn so
  # 'done' always leaves a clean tree. No-op for main/bridge (projRoot == bridgeRoot).
  try {
    $projRoot = ''
    try { if (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) { $projRoot = [string](Get-EffectiveProjectRoot) } } catch {}
    if ($projRoot -and ($projRoot -ne $bridgeRoot) -and (Test-Path (Join-Path $projRoot '.git'))) {
      $pDirty = @(& git -C $projRoot status --porcelain 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if (@($pDirty).Count -gt 0) {
        $pMsg = 'auto-commit (driver): ' + (($task -replace '\s+', ' ').Trim())
        if ($pMsg.Length -gt 160) { $pMsg = $pMsg.Substring(0, 160) }
        & git -C $projRoot add -A 2>$null | Out-Null
        & git -C $projRoot commit -m $pMsg 2>$null | Out-Null
        $pHead = ((& git -C $projRoot rev-parse HEAD 2>$null) | Select-Object -First 1).Trim()
        if ($pHead) { Add-Message -From system -Text ("💾 Драйвер зафиксировал правки проекта: " + $(if ($pHead.Length -ge 7) { $pHead.Substring(0,7) } else { $pHead })) -Kind event | Out-Null }
        try { Invoke-AutoPush -Root $projRoot } catch {}
      }
    }
  } catch {}

  # 2026-05-30: auto-push committed work to GitHub when HEAD moved this turn
  # (covers both driver auto-commit above and commits the coder made itself).
  try {
    $headAfterTurn = (& git -C $bridgeRoot rev-parse HEAD 2>$null).Trim()
    if ($headAfterTurn -and $headBeforeTurn -and $headAfterTurn -ne $headBeforeTurn) { Invoke-AutoPush -Root $bridgeRoot }
  } catch {}

  if ((Read-State).abort) { continue }   # killed mid-turn -> handled at top

  if ($turnResult.status -eq 'preflight_blocked' -or [bool]$turnResult.preflightBlocked) {
    $reason = [string]$turnResult.reason
    if ([string]::IsNullOrWhiteSpace($reason)) {
      $reason = ([string]$reply) -replace '^PREFLIGHT_BLOCKED:\s*',''
    }
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'неизвестная причина' }
    try { Set-TaskLastFailure -Kind preflight_blocked -Text $reason } catch {}
    Add-Message -From system -Text ("Pre-flight gate заблокировал запуск Codex: " + $reason + ". Claude, дай инструкцию повторно, когда условие снято, или ответь пользователю через CHAT.") -Kind event | Out-Null
    Update-State { param($s) $s.force_planner=$true; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
    continue
  }

  # Handle agent timeouts as retryable structured errors.
  if ($turnResult.status -eq 'timeout') {
    $who = if ($turnResult.errorType -eq 'coder_timeout') { 'Codex' } else { 'Claude' }
    $dur = [int]$turnResult.duration
    $trc = [int](Read-State).timeout_retry_count
    # 🩺 Long timeouts (>= ~60% of cap) almost never come back via retry — same prompt would
    # just timeout again, wasting another 500+s. Heuristic threshold 350s catches both planner
    # (cap 600s) and coder (cap 900s after Doctor raised it 4cb5f53). User feedback 2026-05-26:
    # "Doctor didn't appear on timeout" -> now Doctor activates ON the long timeout, not after retry.
    $isLongTimeout = ($dur -ge 350)
    if ($trc -lt 1 -and -not $isLongTimeout -and -not [bool](Read-State).doctor_active) {
      Add-Message -From system -Text "⏱ Таймаут $who (${dur}с, $($turnResult.errorType)) — короткий, повторяю попытку..." -Kind event | Out-Null
      $newTrc = $trc + 1
      $mutTrc = { param($s) $s.timeout_retry_count = $newTrc; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o') }.GetNewClosure()
      Update-State $mutTrc | Out-Null
      continue
    } else {
      try { Invoke-PostMortem -FailureType 'timeout' -Task $task -Context "$($turnResult.errorType) (${dur}с)" } catch {}
      # 🩺 If we're already inside a Doctor task and Doctor itself timed out, escalate -- don't recurse.
      if ([bool](Read-State).doctor_active) {
        Add-Message -From system -Text "⏱ Доктор сам упёрся в таймаут (${dur}с). Эскалирую оператору." -Kind event | Out-Null
        try { Abort-Doctor -Reason "doctor timeout (${dur}с)" } catch {}
        Update-State { param($s) $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.status='idle'; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
      } else {
        $reasonMsg = if ($trc -ge 1) { "повторился (${dur}с)" } elseif ($isLongTimeout) { "длинный (${dur}с) — retry почти наверняка снова упрётся" } else { "(${dur}с)" }
        Add-Message -From system -Text "⏱ Таймаут $who $reasonMsg. Передаю Доктору на саморемонт." -Kind event | Out-Null
        $activationDetail = if ($trc -ge 1) { "${dur}с после retry" } elseif ($isLongTimeout) { "${dur}с — длинный, без retry" } else { "${dur}с" }
        try { Activate-Doctor -Reason ([string]$turnResult.errorType) -Detail $activationDetail | Out-Null } catch {}
        Update-State { param($s) $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.status='idle'; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
      }
      continue
    }
  }
  Update-State { param($s) $s.timeout_retry_count=0 } | Out-Null

  # Safety gate: intercept dangerous-action flag from Codex before processing reply
  if ($speaker -eq 'codex') {
    $safetyPat = '(?m)^\s*\[\[SAFETY:\s*(.+?)\s*\]\]\s*$'
    $safetyM = [regex]::Match([string]$reply, $safetyPat)
    if ($safetyM.Success) {
      $safetyDesc = $safetyM.Groups[1].Value.Trim()
      $preReply = [regex]::Replace([string]$reply, $safetyPat, '').Trim()
      if (-not [string]::IsNullOrWhiteSpace($preReply)) {
        Add-Message -From codex -Text $preReply | Out-Null
      }
      Add-Message -From system -Text "🛡 SAFETY GATE: Codex запрашивает разрешение:`n`n**$safetyDesc**`n`nНапиши «да, выполни» для подтверждения, или дай иную инструкцию." -Kind event | Out-Null
      try { Send-PushEvent -Kind gate -Text $safetyDesc } catch {}
      try { Invoke-PostMortem -FailureType 'safety' -Task $task -Context "SAFETY: $safetyDesc" } catch {}
        Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'aborted'; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s; Clear-ChunkingState $s; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle'; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
      continue
    }
  }

  Set-BridgeStatusText (Get-AgentPhaseStatusText -Speaker $speaker -Mode $mode -Phase 'post' -TaskText $task)
  if ([string]::IsNullOrWhiteSpace($reply)) { $reply = "(нет ответа от $speaker)" }
  $fastLaneActiveForTurn = ($speaker -eq 'codex' -and $mode -eq 'normal' -and [bool](Read-State).skip_planner)
  $attachmentMetas = @()
  $failedAttachmentPaths = @()
  $fileMarkerPaths = @()
  $fileMarkerPattern = '(?m)^\s*\[\[FILE:\s*(.+?)\s*\]\]\s*$'
  foreach ($match in [regex]::Matches($reply, $fileMarkerPattern)) {
    $sourcePath = $match.Groups[1].Value.Trim().Trim('"').Trim("'")
    if ($sourcePath.StartsWith('<') -and $sourcePath.EndsWith('>') -and $sourcePath.Length -gt 2) {
      $sourcePath = $sourcePath.Substring(1, $sourcePath.Length - 2).Trim()
    }
    $fileMarkerPaths += $sourcePath
    $meta = Register-AttachmentPath -SourcePath $sourcePath
    if ($meta) {
      $attachmentMetas += $meta
      try { Add-TaskCheckpoint -Kind file -Text $sourcePath } catch {}
    }
    else { $failedAttachmentPaths += $sourcePath }
  }
  # Auto-detect image file paths from markdown links: [name](</C:/path.png>)
  $imgMdPattern = '\[[^\]]*\]\(<\/?([^>]+\.(?:png|jpg|jpeg|gif|bmp|webp))>\)'
  foreach ($mdMatch in [regex]::Matches($reply, $imgMdPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $imgPath = $mdMatch.Groups[1].Value.Trim()
    if ($imgPath -match '^/([A-Za-z]:.*)') { $imgPath = $Matches[1] }
    $imgPath = $imgPath.Replace('/', '\')
    $normalized = $imgPath
    if ($normalized -notin ($fileMarkerPaths | ForEach-Object { ([string]$_).Replace('/', '\') }) -and (Test-Path -LiteralPath $imgPath)) {
      $fileMarkerPaths += $imgPath
      $meta = Register-AttachmentPath -SourcePath $imgPath
      if ($meta) { $attachmentMetas += $meta } else { $failedAttachmentPaths += $imgPath }
    }
  }
  # Best-effort: bare Windows paths (no spaces supported)
  $imgBarePattern = '([A-Za-z]:\\[^\s\[\]<>"'']+\.(?:png|jpg|jpeg|gif|bmp|webp))'
  foreach ($bareMatch in [regex]::Matches($reply, $imgBarePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    $imgPath = $bareMatch.Groups[1].Value.Trim()
    if ($imgPath -notin ($fileMarkerPaths | ForEach-Object { ([string]$_).Replace('/', '\') }) -and (Test-Path -LiteralPath $imgPath)) {
      $fileMarkerPaths += $imgPath
      $meta = Register-AttachmentPath -SourcePath $imgPath
      if ($meta) { $attachmentMetas += $meta } else { $failedAttachmentPaths += $imgPath }
    }
  }
  # [[SAVE: title]] ... [[/SAVE]] -> durable decision note
  $savePattern = '(?s)\[\[SAVE:\s*(.+?)\s*\]\](.*?)\[\[/SAVE\]\]'
  $savedPaths = @()
  foreach ($m in [regex]::Matches($reply, $savePattern)) {
    $st = $m.Groups[1].Value.Trim(); $sc = $m.Groups[2].Value.Trim()
    if ($sc) { $savedPaths += (Save-Decision -Title $st -Content $sc) }
  }
  $evidencePattern = '(?m)^\s*\[\[EVIDENCE:\s*(.+?)\s*\]\]\s*$'
  $verifiedPattern = '(?m)^\s*\[\[VERIFIED:\s*(.+?)\s*\]\]\s*$'
  $evidenceSources = @()
  foreach ($m in [regex]::Matches($reply, $evidencePattern)) {
    $parts = @($m.Groups[1].Value -split '\|', 3)
    $source = if ($parts.Count -ge 1) { $parts[0].Trim() } else { '' }
    $summary = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
    $confidence = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($source)) { continue }
    if (Write-EvidenceLog -Agent $speaker -Task $task -Source $source -Summary $summary -Confidence $confidence) {
      $evidenceSources += $source
    }
  }
  foreach ($m in [regex]::Matches($reply, $verifiedPattern)) {
    $vtext = $m.Groups[1].Value.Trim()
    if (-not [string]::IsNullOrWhiteSpace($vtext)) {
      try { Add-TaskCheckpoint -Kind verified -Text $vtext } catch {}
      try { Add-SessionDecisionEvent -EventType 'verified_commit' -Meta @{ what=$vtext.Substring(0,[Math]::Min(100,$vtext.Length)) } -Channel $Channel } catch {}
    }
  }
  $findingPattern = '(?m)^\s*\[\[FINDING:\s*(.+?)\s*\]\]\s*$'
  $studyFindings = @()
  foreach ($m in [regex]::Matches($reply, $findingPattern)) {
    $parts = @($m.Groups[1].Value -split '\|', 2)
    $fsrc = if ($parts.Count -ge 1) { $parts[0].Trim() } else { '' }
    $ffact = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($fsrc)) { $studyFindings += "$fsrc | $ffact" }
  }
  $studyFallbackPattern = '(?m)^\s*\[\[STUDY_FALLBACK:\s*external\s*\]\]\s*$'
  if ($reply -imatch '\[\[STUDY_FALLBACK:\s*external\s*\]\]') {
    Update-State { param($s) $s.study_subtype='external'; $s.study_phase='gather-web' } | Out-Null
    Add-Message -From system -Text "📚 Study: путь не является репозиторием — переключаюсь на external." -Kind event | Out-Null
  }
  $pbForMarkers = Get-ActiveProjectBinding
  $channelIsMainMarkers = ($pbForMarkers -and ([string]$pbForMarkers.slug -eq 'main'))

  # [[REMEMBER: fact]] -> agent deliberately pushes a durable memory (no gate -- the agent chose).
  $rememberPattern = '(?m)^\s*\[\[REMEMBER:\s*(.+?)\s*\]\]\s*$'
  $rememberedFacts = @()
  foreach ($m in [regex]::Matches($reply, $rememberPattern)) {
    $fact = $m.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($fact)) { continue }
    try {
      $rid = Add-Memory -Text $fact -Tags @('explicit', $speaker) -Source ('explicit:' + $speaker) -Importance 0.75 -Channel ([string]$pbForMarkers.slug)
      if ($rid) { $rememberedFacts += $fact }
    } catch {}
  }
  # [[PROJECT_FACT: ...]] / [[PROJECT_TEST: ...]] / ... -> typed, evidence-backed
  # per-channel project memory. This stays in the same memory.jsonl store and is
  # retrieved by Get-ProjectContextPack before future tasks.
  $projectMemoryPattern = '(?m)^\s*\[\[PROJECT_(FACT|DECISION|RISK|TEST|INVARIANT|WORKLOG|OPEN_QUESTION):\s*(.+?)\s*\]\]\s*$'
  $projectMemoryCount = 0
  foreach ($pm in [regex]::Matches($reply, $projectMemoryPattern)) {
    $kindToken = $pm.Groups[1].Value.Trim().ToUpperInvariant()
    $rawProjectMemory = $pm.Groups[2].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($rawProjectMemory)) { continue }
    $kindMap = @{
      FACT = 'project_fact'
      DECISION = 'project_decision'
      RISK = 'project_risk'
      TEST = 'project_test'
      INVARIANT = 'project_invariant'
      WORKLOG = 'project_worklog'
      OPEN_QUESTION = 'project_open_question'
    }
    if (-not $kindMap.ContainsKey($kindToken)) { continue }
    try {
      if (Get-Command Add-ProjectMemoryFromMarker -ErrorAction SilentlyContinue) {
        $pid = Add-ProjectMemoryFromMarker -Kind ([string]$kindMap[$kindToken]) -RawText $rawProjectMemory -Channel ([string]$pbForMarkers.slug) -Source ('project-marker:' + $speaker)
        if ($pid) { $projectMemoryCount++ }
      }
    } catch {}
  }
  if ($projectMemoryCount -gt 0) {
    try { Add-Message -From system -Text ("🧠 Проектная память: сохранено typed-записей " + $projectMemoryCount) -Kind event | Out-Null } catch {}
  }
  # [[PROJECT_BACKLOG]] JSON [[/PROJECT_BACKLOG]] -> Project Autopilot atom batch.
  # The coordinator task thinks/decomposes; the driver owns durable backlog mutation.
  $projectBacklogPattern = '(?is)\[\[PROJECT_BACKLOG\]\](.*?)\[\[/PROJECT_BACKLOG\]\]'
  $projectBacklogCreated = 0
  foreach ($pbm in [regex]::Matches($reply, $projectBacklogPattern)) {
    $pbBlock = [string]$pbm.Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($pbBlock)) { continue }
    try {
      if (Get-Command Add-ProjectBacklogFromMarker -ErrorAction SilentlyContinue) {
        $pbMax = 12
        try { $pbMax = [int](Get-ProjectAutopilotConfig).maxTasksPerBatch } catch { $pbMax = 12 }
        $sourceTaskId = ''
        try {
          $stPb = Read-State
          $sourceTaskId = [string]$stPb.current_task_id
          if ([string]::IsNullOrWhiteSpace($sourceTaskId)) { $sourceTaskId = [string]$stPb.current_backlog_id }
        } catch {}
        $pbResult = Add-ProjectBacklogFromMarker -Block $pbBlock -Channel ([string]$pbForMarkers.slug) -Source $speaker -SourceTaskId $sourceTaskId -MaxTasks $pbMax
        $projectBacklogCreated += [int]$pbResult.created
        if ([int]$pbResult.created -gt 0) {
          $pbDetails = ''
          try {
            $ch = @($pbResult.chapters | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 3)
            $sl = @($pbResult.slugs | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 5)
            $bits = New-Object 'System.Collections.Generic.List[string]'
            if ($ch.Count -gt 0) { [void]$bits.Add('главы: ' + ($ch -join ', ')) }
            if ($sl.Count -gt 0) { [void]$bits.Add('atoms: ' + ($sl -join ', ')) }
            if ($bits.Count -gt 0) { $pbDetails = ' — ' + (($bits.ToArray()) -join '; ') }
          } catch {}
          Add-Message -From system -Text ("🧭 Project Autopilot: добавлено approved atom-задач: " + [int]$pbResult.created + $(if([int]$pbResult.skipped -gt 0){" (пропущено дублей: " + [int]$pbResult.skipped + ")"}else{""}) + $pbDetails) -Kind event | Out-Null
        } else {
          $errText = ''
          try { $errText = (@($pbResult.errors) -join '; ') } catch {}
          if ([string]::IsNullOrWhiteSpace($errText)) { $errText = 'валидных новых атомов нет' }
          Add-Message -From system -Text ("🧭 Project Autopilot: atom batch не добавлен — " + $errText) -Kind event | Out-Null
        }
      }
    } catch {
      try { Add-Message -From system -Text ("⚠ Project Autopilot marker parse failed: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    }
  }
  # [[IDEA: ...]] -> agent raises a self-improvement idea into the backlog (status 'new').
  $ideaPattern = '(?m)^\s*\[\[IDEA:\s*(.+?)\s*\]\]\s*$'
  $proposedIdeas = New-Object System.Collections.Generic.List[string]
  # 2026-05-28: suppress mid-task echoing of the user spec back as "ideas".
  # Real incident: my Phase 1 task spec mentioned "Этап 2: Test-FeatureSimilarity",
  # the planner emitted [[IDEA: добавить Test-FeatureSimilarity...]] in turn 1 as
  # a sincere idea — but it's just the user's roadmap restated. We compare each
  # idea-text against the current task text by word-overlap; >50% → suppress.
  # Also gather words from current task for cheap overlap check.
  $taskTextForSuppress = ''
  try { $taskTextForSuppress = [string](Read-State).current_task } catch {}
  $taskNorm = ''
  $taskWords = @()
  if (-not [string]::IsNullOrWhiteSpace($taskTextForSuppress)) {
    $taskNorm = ($taskTextForSuppress -replace '\s+',' ').Trim().ToLowerInvariant()
    $taskWords = @($taskNorm -split '\W+' | Where-Object { $_.Length -gt 3 })
  }
  foreach ($m in [regex]::Matches($reply, $ideaPattern)) {
    $idea = $m.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($idea)) { continue }
    # Mid-task echo guard
    if ($taskWords.Count -gt 5) {
      try {
        $ideaNorm = ($idea -replace '\s+',' ').Trim().ToLowerInvariant()
        $ideaWords = @($ideaNorm -split '\W+' | Where-Object { $_.Length -gt 3 })
        if ($ideaWords.Count -gt 2) {
          $shared = ($ideaWords | Where-Object { $taskWords -contains $_ }).Count
          $ratio = $shared / [Math]::Max(1, $ideaWords.Count)
          if ($ratio -gt 0.5) {
            Add-Message -From system -Text ("💡 Идея пропущена (повтор текста задачи, overlap " + ('{0:N2}' -f $ratio) + "): " + ($idea.Substring(0,[Math]::Min(80,$idea.Length)))) -Kind event | Out-Null
            continue
          }
        }
      } catch {}
    }
    try {
      $ideaScope = if ($channelIsMainMarkers) { 'bridge' } else { 'project' }
      $addIdeaResult = Add-Idea -Text $idea -From $speaker -Tags @($speaker) -Status 'new' -Project ([string]$pbForMarkers.slug) -Scope $ideaScope
      $ideaOutcome = Resolve-AddIdeaOutcome -AddResult $addIdeaResult -IdeaText $idea -From $speaker
      if ($ideaOutcome.deduped) {
        $cosineText = 'n/a'
        if ($null -ne $ideaOutcome.cosine) {
          try { $cosineText = ('{0:N2}' -f ([double]$ideaOutcome.cosine)) } catch {}
        }
        $dedupId = if ([string]::IsNullOrWhiteSpace([string]$ideaOutcome.itemId)) { 'unknown' } else { [string]$ideaOutcome.itemId }
        Add-Message -From system -Text "💡 Идея уже в беклоге (cosine $cosineText): id=$dedupId" -Kind event | Out-Null
      } elseif ($ideaOutcome.created -and -not [string]::IsNullOrWhiteSpace([string]$ideaOutcome.itemId)) {
        [void]$proposedIdeas.Add($idea)
      } elseif ($addIdeaResult) {
        [void]$proposedIdeas.Add($idea)
      }
    } catch {
      try { Add-Message -From system -Text ("⚠ Add-Idea failed: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    }
  }
  # [[RUNJOB: команда | папка]] -> запустить долгую команду в фоне (без таймаута хода).
  $runjobPattern = '(?m)^\s*\[\[RUNJOB:\s*(.+?)\s*\]\]\s*$'
  $startedJobs = @()
  foreach ($m in [regex]::Matches($reply, $runjobPattern)) {
    $spec = $m.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($spec)) { continue }
    # Split on the LAST '|' only if the right-hand side looks like a workdir path.
    # This keeps PowerShell pipelines intact, e.g. "Get-Content x | Where-Object {...}".
    $lastPipe = $spec.LastIndexOf('|')
    $jcmd = $spec.Trim()
    $jdir = ''
    if ($lastPipe -ge 0) {
      $candidate = $spec.Substring($lastPipe + 1).Trim()
      # Plausible workdir: Windows abs (C:\...), UNC (\\...), relative (./, ..\), or tilde (~).
      $isPath = $candidate -match '^([A-Za-z]:\\|\\\\|~[\\\/]|\.\.?[\\\/]|\.\.?$)'
      $hasMeta = $candidate -match '[{}$;()|]'
      if ($isPath -and -not $hasMeta) {
        $jcmd = $spec.Substring(0, $lastPipe).Trim()
        $jdir = $candidate
      }
    }
    if ([string]::IsNullOrWhiteSpace($jcmd)) { continue }
    # IDEMPOTENCY (2026-05-29): do NOT relaunch a job whose command is ALREADY running, or that ran in
    # the last 15 min. ROOT CAUSE of "аудит запустился 3-й раз без команды": a discuss-loop + resume +
    # history-compaction made the agent re-emit [[RUNJOB: ...audit.ps1]] on almost every turn, and each
    # emit spawned a fresh audit. Dedupe by normalized command so a burst collapses to ONE run.
    $jnorm = ($jcmd -replace '\s+',' ').Trim().ToLowerInvariant()
    $dupRunning = $false
    try { foreach ($aj in @((Read-State).active_jobs)) { if ((([string]$aj.cmd) -replace '\s+',' ').Trim().ToLowerInvariant() -eq $jnorm) { $dupRunning = $true; break } } } catch {}
    $dupRecent = $false
    if (-not $dupRunning) {
      try {
        $jobsD = Join-Path $bridgeRoot 'jobs'
        $cutoff = (Get-Date).AddMinutes(-15)
        # 2026-06-01 ERR-014 fix (generalizes ERR-012): a deduped RUNJOB result is only valid if the
        # repo state it depended on hasn't changed since the prior run. The first attempt may have run
        # BEFORE its target existed (e.g. `npx tsx scripts/seed-admin.ts` before the script was created,
        # or `npm run build` before `npm install`) and failed; deduping the retry against that stale
        # failure reused a precondition-invalid result. So INVALIDATE the dedupe when the project's git
        # HEAD (last commit) OR node_modules/lockfile is NEWER than the prior run -> precondition changed
        # -> allow the rerun. General (every command), not just build/verify (that was ERR-012's gap).
        $pdir = $jdir
        if ([string]::IsNullOrWhiteSpace($pdir)) { try { if (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) { $pdir = [string](Get-EffectiveProjectRoot) } } catch {} }
        $precondMtime = [datetime]::MinValue
        if (-not [string]::IsNullOrWhiteSpace($pdir)) {
          # (a) last commit time — covers committed target creation (seed script, generated routes, etc.)
          try {
            $gitX = Get-GitExe
            $ct = & $gitX -C $pdir log -1 --format=%cI 2>$null
            if ($ct) { $dt = [datetime]::Parse(([string]$ct).Trim(), $null, [System.Globalization.DateTimeStyles]::RoundtripKind); if ($dt -gt $precondMtime) { $precondMtime = $dt } }
          } catch {}
          # (b) node_modules / lockfile — covers `npm install` (not committed)
          foreach ($dep in @('node_modules','package-lock.json','pnpm-lock.yaml','yarn.lock')) {
            try { $dp = Join-Path $pdir $dep; if (Test-Path -LiteralPath $dp) { $dt = (Get-Item -LiteralPath $dp).LastWriteTime; if ($dt -gt $precondMtime) { $precondMtime = $dt } } } catch {}
          }
        }
        foreach ($cf in @(Get-ChildItem $jobsD -Filter '*.cmd' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $cutoff })) {
          $cc = (([string]([System.IO.File]::ReadAllText($cf.FullName))) -replace '\s+',' ').Trim().ToLowerInvariant()
          if ($cc -eq $jnorm) {
            # ERR-014: repo/deps changed AFTER this prior run => prior result precondition-invalid => rerun.
            if ($precondMtime -gt $cf.LastWriteTime) { continue }
            $dupRecent = $true; break
          }
        }
      } catch {}
    }
    if ($dupRunning -or $dupRecent) {
      $why = if ($dupRunning) { 'уже выполняется' } else { 'уже запускалась в последние 15 минут' }
      Add-Message -From system -Text ("⏭ Не дублирую фоновую задачу ($why): $jcmd`nИспользуй предыдущий результат вместо повторного запуска.") -Kind event | Out-Null
      continue
    }
    # 2026-05-30 RUNJOB SAFETY GATE: this is the SECOND autonomous execution path (agent-emitted
    # background command), so it gets the same danger-class vetting as the backlog pre-flight gate.
    try {
      $jGate = Test-RunjobCommandSafe -Command $jcmd -BridgeRoot $bridgeRoot
      if (-not $jGate.safe) {
        Add-Message -From system -Text ("🛑 Фоновая команда ЗАБЛОКИРОВАНА (риск=" + [string]$jGate.risk + "): " + [string]$jGate.reason + ".`nКоманда: " + $jcmd + "`nНужна проверка оператора — мост её НЕ запускает.") -Kind event | Out-Null
        try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='runjob-blocked'; cmd=$jcmd; risk=[string]$jGate.risk; reason=[string]$jGate.reason }) } catch {}
        continue
      }
    } catch {}
    try { $job = Start-BridgeJob -Command $jcmd -WorkDir $jdir; if ($job) { $startedJobs += $job } } catch {}
  }
  if ($startedJobs.Count -gt 0) {
    $sj = $startedJobs
    Update-State ({ param($s) $cur=@(); if ($s.active_jobs) { $cur=@($s.active_jobs) }; $s.active_jobs=@($cur + $sj) }.GetNewClosure()) | Out-Null
    foreach ($job in $sj) { Add-Message -From system -Text "🛠 Запущена фоновая задача [$($job.id)]: $($job.cmd)`nЖду завершения (без таймаута), результат придёт сюда." -Kind event | Out-Null }
  }
  # [[NEED-TOOL: имя | контракт]] -> синтез инструмента на лету (Tool Foundry, Ф1). Сборка
  # идёт в песочнице (Build-AutoTool: parse -> smoke в ДОЧЕРНЕМ процессе -> критик на ДРУГОЙ
  # модели); зелёный инструмент пишется в tools/auto/<имя>.ps1 и СРАЗУ dot-source'ится здесь
  # (мы в script-scope верхнеуровневого while-цикла), поэтому Invoke-<имя> доступен и этому
  # ходу, и всем следующим. Reuse-before-rebuild: активный одноимённый инструмент не пересобираем.
  $needToolPattern = '(?m)^\s*\[\[NEED-TOOL:\s*(.+?)\s*\]\]\s*$'
  foreach ($m in [regex]::Matches($reply, $needToolPattern)) {
    $spec = $m.Groups[1].Value.Trim()
    if ([string]::IsNullOrWhiteSpace($spec)) { continue }
    $ntParts = $spec -split '\|', 2
    $ntName = $ntParts[0].Trim()
    $ntContract = if ($ntParts.Count -ge 2) { $ntParts[1].Trim() } else { '' }
    $ntSafe = $null
    try { $ntSafe = Test-AutoToolName -Name $ntName } catch {}
    if (-not $ntSafe) {
      Add-Message -From system -Text ("⚠ [[NEED-TOOL]] отклонён: недопустимое имя '" + $ntName + "'. Нужно латиницей: буква, далее буквы/цифры/_ и дефис.") -Kind event | Out-Null
      continue
    }
    if ([string]::IsNullOrWhiteSpace($ntContract)) {
      Add-Message -From system -Text ("⚠ [[NEED-TOOL: " + $ntSafe + "]] без контракта. Формат: [[NEED-TOOL: имя | что инструмент делает]].") -Kind event | Out-Null
      continue
    }
    $ntExisting = $null
    try { $ntExisting = Get-AutoTool -Name $ntSafe } catch {}
    if ($ntExisting -and ([string]$ntExisting.status -eq 'active')) {
      Add-Message -From system -Text ("🔧 Инструмент '" + $ntSafe + "' уже есть (вызов: Invoke-" + $ntSafe + "). Переиспользуй — не пересобираю.") -Kind event | Out-Null
      continue
    }
    Add-Message -From system -Text ("🏗 Tool Foundry: синтез '" + $ntSafe + "' в песочнице (parse → smoke → критик)…") -Kind event | Out-Null
    $ntBuilt = $null
    try { $ntBuilt = Build-AutoTool -Name $ntSafe -Contract $ntContract } catch { $ntBuilt = $null }
    if ($ntBuilt -and $ntBuilt.ok) {
      try {
        $ntFile = Join-Path (Get-ToolForgeRoot) ($ntBuilt.name + '.ps1')
        if (Test-Path -LiteralPath $ntFile) { . $ntFile }   # load into engine script-scope NOW
      } catch {}
      Add-Message -From system -Text ("✅ Инструмент готов: '" + $ntBuilt.name + "' (вызов: " + $ntBuilt.entry + "). Контракт: " + $ntContract + ". Доступен сразу и на следующих ходах.") -Kind event | Out-Null
    } else {
      $ntWhy = if ($ntBuilt) { [string]$ntBuilt.reason } else { 'сборка упала (исключение)' }
      Add-Message -From system -Text ("⚠ Не построил '" + $ntSafe + "' → карантин. Причина: " + $ntWhy + ". Сделай задачу без него или уточни контракт и повтори [[NEED-TOOL]].") -Kind event | Out-Null
    }
  }
  # [[PLAN]] ... [[/PLAN]] -> создать persisted план-доску для текущей задачи.
  $planBlockPattern = '(?is)\[\[PLAN\]\].*?\[\[/PLAN\]\]'
  $planCreatedStepCount = $null
  try {
    $planNodes = ConvertFrom-PlanBlock -Text $reply
    if ($planNodes) {
      $planCreatedStepCount = New-Plan -Task $task -Nodes $planNodes
    }
  } catch {
    Add-Message -From system -Text ("⚠ Не удалось создать план-доску: " + $_.Exception.Message) -Kind event | Out-Null
  }

  # [[DISPATCH-DAG]] / [[DISPATCH-DAG: N]] -> исполнить ТЕКУЩУЮ план-доску как реально
  # диспетчеризуемый DAG (Project Foundry, Ф2): готовые шаги веером уходят в параллельных
  # воркеров в worktree'ах ПРИВЯЗАННОГО ПРОЕКТА, каждый шаг гейтится (done + >=1 commit) и
  # мёрджится-или-откатывается, волна за волной. Статусы шагов план-доски пишет сам
  # Invoke-PlanDag (через Set-PlanStepStatus), поэтому после диспатча доска отражает факт.
  # Жёстко отказываемся работать над самим bridge-репозиторием (foundry-слой тоже откажет).
  $dispatchDagPattern = '(?m)^\s*\[\[DISPATCH-DAG(?::\s*(\d+))?\]\]\s*$'
  $dispatchHit = [regex]::Match($reply, $dispatchDagPattern)
  if ($dispatchHit.Success) {
    $reqPar = 0
    if ($dispatchHit.Groups[1].Success) { try { $reqPar = [int]$dispatchHit.Groups[1].Value } catch { $reqPar = 0 } }
    $binding = $null
    try { $binding = Get-ChannelProjectBinding -Slug $Channel } catch { $binding = $null }
    if (-not $binding -or -not [bool]$binding.ok) {
      $bwhy = if ($binding) { [string]$binding.error } else { 'нет привязки' }
      Add-Message -From system -Text ("⚠ [[DISPATCH-DAG]] пропущен: канал не привязан к проекту ($bwhy). Сначала создай проект (New-Project) и привяжи канал.") -Kind event | Out-Null
    } else {
      $projRoot = [string]$binding.project_root
      $bridgeFull = ''; try { $bridgeFull = [System.IO.Path]::GetFullPath((Get-BridgeRoot)).TrimEnd('\','/') } catch {}
      $projFull = $projRoot; try { $projFull = [System.IO.Path]::GetFullPath($projRoot).TrimEnd('\','/') } catch {}
      if ($projFull -and $bridgeFull -and $projFull.Equals($bridgeFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Add-Message -From system -Text "⚠ [[DISPATCH-DAG]] отклонён: канал указывает на сам bridge-репозиторий. DAG-исполнение работает только над отдельным проектом." -Kind event | Out-Null
      } else {
        $parNote = if ($reqPar -gt 0) { " (parallel=$reqPar)" } else { "" }
        Add-Message -From system -Text ("🧭 DISPATCH-DAG: исполняю план-доску как DAG над проектом " + $projFull + $parNote + "…") -Kind event | Out-Null
        $dag = $null
        try {
          if ($reqPar -gt 0) { $dag = Invoke-FoundryPlanDispatch -RepoRoot $projRoot -MaxParallel $reqPar }
          else               { $dag = Invoke-FoundryPlanDispatch -RepoRoot $projRoot }
        } catch {
          Add-Message -From system -Text ("⚠ DISPATCH-DAG исключение: " + $_.Exception.Message) -Kind event | Out-Null
        }
        if ($dag) {
          $icon = if ([bool]$dag.ok) { "✅" } else { "⚠" }
          $dmsg = $icon + " DISPATCH-DAG: " + [string]$dag.summary
          if (-not [bool]$dag.ok -and $dag.blockers -and $dag.blockers.Count -gt 0) {
            $blines = @($dag.blockers.GetEnumerator() | ForEach-Object { [string]$_.Key + ' <- ' + ((@($_.Value) -join ', ')) }) -join '; '
            if (-not [string]::IsNullOrWhiteSpace($blines)) { $dmsg += ("`nБлокеры: " + $blines) }
          }
          Add-Message -From system -Text $dmsg -Kind event | Out-Null
        }
      }
    }
  }

  # [[STEP-DONE: id | результат]] и [[STEP: id | status | результат]] -> обновить шаги плана.
  $stepDonePattern = '(?m)^\s*\[\[STEP-DONE:\s*([^|\]]+?)(?:\s*\|\s*(.*?))?\s*\]\]\s*$'
  $stepPattern = '(?m)^\s*\[\[STEP:\s*(.+?)\s*\]\]\s*$'
  $planStepUpdates = @()
  foreach ($m in [regex]::Matches($reply, $stepDonePattern)) {
    $stepId = $m.Groups[1].Value.Trim()
    $stepResult = if ($m.Groups.Count -gt 2) { $m.Groups[2].Value.Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($stepId)) { continue }
    $stepCheckpoint = if ([string]::IsNullOrWhiteSpace($stepResult)) { $stepId } else { "$stepId | $stepResult" }
    try { Add-TaskCheckpoint -Kind step_done -Text $stepCheckpoint } catch {}
    try {
      $okStep = Set-PlanStepStatus -Id $stepId -Status done -Result $stepResult
      if ($okStep) { $planStepUpdates += "$stepId → done" }
      else { Add-Message -From system -Text "⚠ Шаг плана не найден: $stepId" -Kind event | Out-Null }
    } catch {
      Add-Message -From system -Text ("⚠ Не удалось обновить шаг плана ${stepId}: " + $_.Exception.Message) -Kind event | Out-Null
    }
  }
  foreach ($m in [regex]::Matches($reply, $stepPattern)) {
    $parts = @($m.Groups[1].Value -split '\|', 3)
    $stepId = if ($parts.Count -ge 1) { $parts[0].Trim() } else { '' }
    $rawStepStatus = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
    $stepStatus = if ($parts.Count -ge 2) { Normalize-PlanStatus -Status $rawStepStatus } else { '' }
    $stepResult = if ($parts.Count -ge 3) { $parts[2].Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($stepId) -or [string]::IsNullOrWhiteSpace($stepStatus)) { continue }
    try {
      $okStep = Set-PlanStepStatus -Id $stepId -Status $stepStatus -Result $stepResult
      if ($okStep) { $planStepUpdates += "$stepId → $stepStatus" }
      else { Add-Message -From system -Text "⚠ Шаг плана не найден: $stepId" -Kind event | Out-Null }
    } catch {
      Add-Message -From system -Text ("⚠ Не удалось обновить шаг плана ${stepId}: " + $_.Exception.Message) -Kind event | Out-Null
    }
  }
  $visibleReply = [regex]::Replace($reply, $fileMarkerPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $savePattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $evidencePattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $verifiedPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $findingPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $projectBacklogPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $studyFallbackPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $rememberPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $ideaPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $runjobPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $needToolPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, '(?s)\[\[PARALLEL:.+?\]\]', '')
  $visibleReply = [regex]::Replace($visibleReply, $planBlockPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $dispatchDagPattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $stepDonePattern, '')
  $visibleReply = [regex]::Replace($visibleReply, $stepPattern, '')
  if ($speaker -eq 'claude' -or [string]$turnResult.fallback -eq 'claude_as_coder' -or $fastLaneActiveForTurn) {
    $visibleReply = [regex]::Replace($visibleReply, '(?im)^\s*STATUS:\s*\w+\s*$', '')
  }
  $visibleReply = $visibleReply.Trim()
  if ($failedAttachmentPaths.Count -gt 0) {
    $failLines = ($failedAttachmentPaths | ForEach-Object { "- $_" }) -join "`n"
    $fileWarning = "⚠ Не удалось прикрепить файл:`n$failLines"
    if ([string]::IsNullOrWhiteSpace($visibleReply)) { $visibleReply = $fileWarning }
    else { $visibleReply = $visibleReply.TrimEnd() + "`n`n" + $fileWarning }
  }
  if ([string]::IsNullOrWhiteSpace($visibleReply) -and $attachmentMetas.Count -eq 0) { $visibleReply = "(нет ответа от $speaker)" }
  Add-Message -From $speaker -Text $visibleReply -Attachments $attachmentMetas -Model $activeModel | Out-Null
  foreach ($sp in $savedPaths) { Add-Message -From system -Text "📝 Заметка сохранена: $sp" -Kind event | Out-Null }
  foreach ($source in $evidenceSources) { Add-Message -From system -Text "📊 Evidence записан: $source" -Kind event | Out-Null }
  if ($null -ne $planCreatedStepCount) { Add-Message -From system -Text "🗂 План-доска создана: шагов $planCreatedStepCount" -Kind event | Out-Null }
  foreach ($pu in $planStepUpdates) { Add-Message -From system -Text "🗂 Шаг плана обновлён: $pu" -Kind event | Out-Null }
  if ($studyFindings.Count -gt 0) {
    $snap = [string](Read-State).study_snapshot
    $snapParts = @()
    if (-not [string]::IsNullOrWhiteSpace($snap)) { $snapParts += $snap.Trim() }
    $snapParts += ($studyFindings -join "`n")
    $newSnap = ($snapParts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`n"
    Update-State ({ param($s) $s.study_snapshot = $newSnap }.GetNewClosure()) | Out-Null
  }
  foreach ($rf in $rememberedFacts) { Add-Message -From system -Text "🧠 Запомнено агентом: $rf" -Kind event | Out-Null }
  foreach ($pi in $proposedIdeas) { Add-Message -From system -Text "💡 Идея в бэклог (от $speaker): $pi" -Kind event | Out-Null }

  # Quality gate: autonomous implementation backlog items must not close as DONE after a
  # plan-only/no-op reply. This caught project tasks being marked done with no commit/build.
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      $stNoop = Read-State
      $noopBacklogId = [string]$stNoop.current_backlog_id
      $noopTask = [string]$stNoop.current_task
      $noopDidActions = [bool]$stNoop.task_did_actions
      $noopCovered = [bool]([regex]::IsMatch([string]$reply, '(?im)^\s*COVERED:\s*'))
      $noopProjectAutopilot = [bool]([regex]::IsMatch($noopTask, '(?im)^\s*\[project-autopilot\b'))
      if (-not [string]::IsNullOrWhiteSpace($noopBacklogId) -and -not $noopDidActions -and -not $noopCovered -and -not $noopProjectAutopilot -and [int]$projectBacklogCreated -le 0) {
        $plannerStatus = 'CONTINUE'
        try { Set-TaskLastFailure -Kind test_failed -Text 'DONE rejected: no file changes, no commands, no commit, no COVERED marker' } catch {}
        Add-Message -From system -Text "🚫 DONE отклонён: это backlog-задача, но в ходе не было действий/коммита/проверок. Нельзя закрывать реализационную задачу планом. Продолжай: реализуй изменения, запусти проверки и только потом STATUS: DONE." -Kind event | Out-Null
      }
    } catch {}
  }

  # [[PARALLEL: <repo> || подзадача1 ;; подзадача2 ;; ...]] -> планировщик запускает
  # независимые под-задачи ПАРАЛЛЕЛЬНО (каждая в своём worktree), затем мерж. Блокирует
  # ход на время выполнения (heartbeat обновляется), потом постит сводку.
  # FIX 2026-05-27: regex requires '||' so it only matches OLD external-repo syntax, NOT
  # new [[PARALLEL:N]]...[[/PARALLEL:N]] (which has no '||' and is handled later via
  # Test-CanParallelize/Invoke-ParallelDispatch).
  if ($speaker -eq 'claude') {
    $pmatch = [regex]::Match($reply, '(?s)\[\[PARALLEL:\s*((?:(?!\[\[).)+?\|\|(?:(?!\[\[).)+?)\s*\]\]')
    if ($pmatch.Success) {
      $pspec = $pmatch.Groups[1].Value.Trim()
      $prepo = Get-ActiveProjectRoot
      if ([string]::IsNullOrWhiteSpace($prepo)) { $prepo = $workRoot }
      $psubsRaw = $pspec
      if ($pspec -match '(?s)^(.*?)\|\|(.*)$') { $prepo = $matches[1].Trim(); $psubsRaw = $matches[2].Trim() }
      $psubs = @($psubsRaw -split '\s*;;\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
      if ($psubs.Count -lt 2) {
        Add-Message -From system -Text "🧩 PARALLEL проигнорирован: нужно >=2 под-задачи через ' ;; '." -Kind event | Out-Null
      } else {
        Add-Message -From system -Text "🧩 Параллельная команда: $($psubs.Count) воркеров в worktrees репозитория $prepo. Жду завершения (без таймаута)..." -Kind event | Out-Null
        $pcount = $psubs.Count
        $tick = ({ param() Update-State ({ param($s) $s.heartbeat=(Get-Date).ToString('o'); $s.status_text="🧩 Параллельные воркеры ($pcount)..." }.GetNewClosure()) | Out-Null }).GetNewClosure()
        $pres = $null
        try { $pres = Invoke-CodexParallel -RepoRoot $prepo -Subtasks $psubs -OnTick $tick -TimeoutSec 3600 } catch { Add-Message -From system -Text "🧩 Параллель: ошибка — $($_.Exception.Message)" -Kind event | Out-Null }
        if ($pres) {
          if ($pres.error) {
            Add-Message -From system -Text "🧩 Параллель не запущена: $($pres.error)" -Kind event | Out-Null
          } else {
            $plines = foreach ($pr in $pres.results) {
              $stat = if ($pr.mergeOk) { 'влито ✅' } elseif ($pr.conflict) { 'КОНФЛИКТ ⚠ (разрешить вручную)' } else { 'не влито ❌' }
              "• $($pr.name): $stat — " + (($pr.subtask -replace '\s+',' '))
            }
            Add-Message -From system -Text ("🧩 Параллель завершена: влито $($pres.merged), конфликтов $($pres.conflicts).`n" + ($plines -join "`n") + "`n`nПланировщик: проверь результат ЗАПУСКОМ, разреши конфликты если есть, доведи до DONE.") -Kind event | Out-Null
          }
        }
      }
    }
  }

  # Stagnation detector: if the coder role made no bridge file changes and no attachments for N turns, trigger self-diagnosis.
  if ($speaker -eq 'codex' -and $mode -ne 'discuss') {
    $gitDiffOut = & git -C $bridgeRoot diff --stat HEAD 2>&1
    # Also check the channel's effective project root (may differ from bridgeRoot).
    if ([string]::IsNullOrWhiteSpace($gitDiffOut)) {
      try {
        $effPR = [string](Get-EffectiveProjectRoot)
        if (-not [string]::IsNullOrWhiteSpace($effPR) -and $effPR -ne $bridgeRoot -and (Test-Path $effPR)) {
          $gitDiffOutPR = & git -C $effPR diff --stat HEAD 2>&1
          if (-not [string]::IsNullOrWhiteSpace($gitDiffOutPR)) { $gitDiffOut = $gitDiffOutPR }
        }
      } catch {
        Add-Message -From system -Text ("⚠ Stagnation detector project_root check failed: " + $_.Exception.Message) -Kind event | Out-Null
      }
    }
    if ($mode -eq 'normal') { Update-State { param($s) $s.task_did_actions=$true } | Out-Null }
    $hasChanges = -not [string]::IsNullOrWhiteSpace($gitDiffOut) -or $attachmentMetas.Count -gt 0
    $npc = [int](Read-State).no_progress_count
    if ($hasChanges) {
      Update-State { param($s) $s.no_progress_count=0 } | Out-Null
    } else {
      $newNpc = $npc + 1
      $mutNpc = { param($s) $s.no_progress_count = $newNpc }.GetNewClosure()
      Update-State $mutNpc | Out-Null
      if ($newNpc -ge 4) {
        Add-Message -From system -Text "⚠ Нет изменений файлов $newNpc ходов подряд. Codex — объясни, что блокирует выполнение, или предложи иной подход." -Kind event | Out-Null
        Update-State { param($s) $s.no_progress_count=0 } | Out-Null
      }
    }
  }

  $modeBeforeIncrement = $mode
  Update-State { param($s) $s.task_turn=[int]$s.task_turn+1; $s.turn=[int]$s.turn+1; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
  if ($modeBeforeIncrement -eq 'discuss') {
    Update-State { param($s) $s.discuss_turn=[int]$s.discuss_turn+1 } | Out-Null
  }
  if ($modeBeforeIncrement -eq 'discuss' -and $speaker -eq 'claude') {
    try {
      $snapMatch = [regex]::Match($reply, '(?ims)^\s*Тип\s*:.*?(?=^\s*STATUS:|\z)')
      if (-not $snapMatch.Success) {
        $snapMatch = [regex]::Match($reply, '(?ims)^\s*Согласовано\s*:.*?(?=^\s*STATUS:|\z)')
      }
      if ($snapMatch.Success) {
        $snap = $snapMatch.Value.Trim()
        $markerCount = [regex]::Matches($snap, '(?im)^[*_> \t#-]*(Тип|Согласовано|Открыто|Решение|Риски|План\s+реализации)[^:\n]*:').Count
        if ($markerCount -ge 2) {
          Update-State ({ param($s) $s.discuss_snapshot = $snap }.GetNewClosure()) | Out-Null
        }
      }
    } catch {}
  }
  if ($modeBeforeIncrement -eq 'study') {
    $stStudy = Read-State
    $curPhase = [string]$stStudy.study_phase
    $turnNow = [int]$stStudy.task_turn
    if ($curPhase -eq 'plan') {
      $nextPhase = if ($stStudy.study_subtype -eq 'local') { 'gather-local' } else { 'gather-web' }
      Update-State ({ param($s) $s.study_phase=$nextPhase }.GetNewClosure()) | Out-Null
    } elseif ($turnNow -ge ($studyMaxTurns - 1)) {
      Update-State { param($s) $s.study_phase='synthesis' } | Out-Null
    } elseif ($curPhase -match '^gather' -and $turnNow -ge 2) {
      Update-State { param($s) $s.study_phase='synthesis' } | Out-Null
    }
  }
  if ($speaker -eq 'claude' -and $modeBeforeIncrement -eq 'research' -and $evidenceSources.Count -eq 0) {
    Add-Message -From system -Text "🔍 Research-ход не дал маркер [[EVIDENCE: ...]]. Дальнейший web-доступ по этой задаче заблокирован до новой задачи." -Kind event | Out-Null
    $researchBlockValue = $researchMaxTurns
    Update-State ({ param($s) $s.research_count=$researchBlockValue }.GetNewClosure()) | Out-Null
  }

  # Loop detector: three identical non-empty progress fingerprints in one task -> Doctor.
  try {
    $fpDiff  = ((& git -C $bridgeRoot diff --stat HEAD 2>$null) -join '|').Trim()
    $fpReply = if ($null -eq $reply) { '' } else { ([string]$reply).Trim() }
    $fpInput = ($fpDiff + '|||' + $fpReply).Trim()
    if (-not [string]::IsNullOrWhiteSpace($fpInput)) {
      $fpBytes = [System.Text.Encoding]::UTF8.GetBytes($fpInput)
      $fpHash  = ([System.Security.Cryptography.SHA256]::Create().ComputeHash($fpBytes) | ForEach-Object { $_.ToString('x2') }) -join ''
      $fp8     = $fpHash.Substring(0, 8)

      $stFp   = Read-State
      $fpList = @()
      try { if ($null -ne $stFp.progress_fingerprints) { $fpList = @($stFp.progress_fingerprints) } } catch {}
      $fpList = @($fpList) + @($fp8)
      if ($fpList.Count -gt 3) { $fpList = @($fpList[($fpList.Count - 3)..($fpList.Count - 1)]) }

      $isLoop = ($fpList.Count -eq 3) -and (($fpList | Select-Object -Unique).Count -eq 1)
      $curLoopCount = 0
      try { $curLoopCount = [int]$stFp.task_loop_count } catch {}
      if ($isLoop) { $curLoopCount++ }

      $newFpList = @($fpList)
      $newLoopCount = $curLoopCount
      Update-State ({ param($s)
        $s | Add-Member -NotePropertyName progress_fingerprints -NotePropertyValue $newFpList -Force
        $s | Add-Member -NotePropertyName task_loop_count -NotePropertyValue $newLoopCount -Force
      }.GetNewClosure()) | Out-Null

      if ($isLoop) {
        Add-Message -From system -Text '🔁 Loop detected: 3× same fingerprint — переключаю в Doctor' -Kind event | Out-Null
        $stLoop = Read-State
        $isAlreadyDoctor = ([bool]$stLoop.doctor_active) -or ([string]$stLoop.task_mode -eq 'doctor')
        if ($isAlreadyDoctor) {
          Add-Message -From system -Text '🛑 Loop в режиме Doctor — прерываю задачу.' -Kind event | Out-Null
          Update-State { param($s)
            Complete-TaskAgentDuration $s
            Close-ReplayForStateTask -State $s -Status 'aborted'
            $s.current_task = $null; $s.task_turn = 0; $s.status = 'idle'; $s.active_agent = $null; $s.active_model = $null; $s.status_text = $null
            $s | Add-Member -NotePropertyName progress_fingerprints -NotePropertyValue @() -Force
            $s | Add-Member -NotePropertyName task_loop_count -NotePropertyValue 0 -Force
          } | Out-Null
        } else {
          try {
            Activate-Doctor -Reason 'loop_detected' -Detail '3x same progress fingerprint' | Out-Null
          } catch {
            Add-Message -From system -Text ("⚠ Activate-Doctor failed in loop-detector: " + $_.Exception.Message) -Kind event | Out-Null
          }
          Update-State { param($s)
            $s | Add-Member -NotePropertyName progress_fingerprints -NotePropertyValue @() -Force
            $s | Add-Member -NotePropertyName task_loop_count -NotePropertyValue 0 -Force
          } | Out-Null
        }
        continue
      }
    }
  } catch {
    Add-Message -From system -Text ("⚠ Loop-detector error: " + $_.Exception.Message) -Kind event | Out-Null
  }

  $plannerStatus = 'CONTINUE'
  $fastLaneDone = $false
  if ($speaker -eq 'codex') {
    $chunkSettings = Get-ChunkingSettings
    $cm = [regex]::Match($reply, '(?im)^\s*STATUS:\s*CONTINUE-CHUNK\s*:\s*(\d+)\s*/\s*(\d+)\s*$')
    if ([bool]$chunkSettings.enabled -and $cm.Success) {
      $chunkN = [int]$cm.Groups[1].Value
      $chunkM = [int]$cm.Groups[2].Value
      $maxChunks = [int]$chunkSettings.maxChunksPerTask
      $headNow = ''
      try { $headNow = (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch {}
      $stChunk = Read-State
      $chunkBase = [string]$stChunk.chunk_base_commit
      if ([string]::IsNullOrWhiteSpace($chunkBase)) { $chunkBase = [string]$stChunk.task_base_commit }
      $baseLabel = if ([string]::IsNullOrWhiteSpace($chunkBase)) { '<empty>' } elseif ($chunkBase.Length -gt 7) { $chunkBase.Substring(0,7) } else { $chunkBase }
      $headAdvanced = (-not [string]::IsNullOrWhiteSpace($headNow)) -and ($headNow -ne $chunkBase)
      if (-not $headAdvanced) {
        Add-Message -From system -Text "Чанк $chunkN/$chunkM помечен, но коммит не зафиксирован (HEAD не сдвинулся с $baseLabel). Закоммить и повтори с тем же STATUS: CONTINUE-CHUNK:$chunkN/$chunkM." -Kind event | Out-Null
        Update-State { param($s) $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $true -Force; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
        continue
      }
      $shortSha = if ($headNow.Length -gt 7) { $headNow.Substring(0,7) } else { $headNow }
      $newProgress = "$chunkN/$chunkM"
      if ($chunkN -ge $maxChunks) {
        Add-Message -From system -Text "Достигнут лимит чанков на задачу ($chunkN/$maxChunks, последний коммит $shortSha). Принудительно закрываю задачу. Если работа не завершена — раздели на отдельные задачи." -Kind event | Out-Null
        Update-State ({ param($s)
          $s | Add-Member -NotePropertyName chunk_progress -NotePropertyValue $newProgress -Force
          $s | Add-Member -NotePropertyName chunk_base_commit -NotePropertyValue $headNow -Force
          $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $false -Force
          $s | Add-Member -NotePropertyName skip_critic -NotePropertyValue $true -Force
          $s.task_did_actions=$true; $s.no_progress_count=0; $s.verify_retry_count=2
        }.GetNewClosure()) | Out-Null
        $plannerStatus = 'DONE'
        $fastLaneDone = $true
      } else {
        Add-Message -From system -Text "Чанк $chunkN/$chunkM завершён: commit $shortSha. Продолжаю на следующий чанк." -Kind event | Out-Null
        Update-State ({ param($s)
          $s | Add-Member -NotePropertyName chunk_progress -NotePropertyValue $newProgress -Force
          $s | Add-Member -NotePropertyName chunk_base_commit -NotePropertyValue $headNow -Force
          $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $true -Force
          $s.task_did_actions=$true; $s.no_progress_count=0
          $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o')
        }.GetNewClosure()) | Out-Null
        continue
      }
    } elseif ([bool]$chunkSettings.enabled) {
      $stChunkDone = Read-State
      $hasChunkProgress = -not [string]::IsNullOrWhiteSpace([string]$stChunkDone.chunk_progress)
      $doneHits = [regex]::Matches($reply, '(?im)^\s*STATUS:\s*DONE\s*$')
      if ($hasChunkProgress -and $doneHits.Count -gt 0) {
        $plannerStatus = 'DONE'
        try { Add-SessionDecisionEvent -EventType 'convergence' -Meta @{ source='planner'; ts=(Get-Date).ToString('o') } -Channel $Channel } catch {}
        $fastLaneDone = $true
        Update-State { param($s) $s.task_did_actions=$true; $s.no_progress_count=0 } | Out-Null
      }
    }

    # 2026-05-27: Deterministic claim verification for Codex reply. Parses
    # the reply for verifiable assertions (HTTP status, ParseFile OK, git SHA)
    # and checks each against ground truth. NEVER blocks the flow — only
    # synthesizes a system event so the next planner turn sees the discrepancy
    # alongside Codex's claim. Catches the over-claim pattern (curator-задача
    # 2026-05-27) before the LLM verify gate spends a 30s round.
    try {
      $gateReport = Test-CoderClaims -Reply $reply -BridgeRoot $bridgeRoot
      if ($gateReport.violations.Count -gt 0) {
        $vparts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($v in $gateReport.violations) {
          [void]$vparts.Add("• [$($v.kind)] Codex заявил: $($v.claim) → реальность: $($v.actual)")
        }
        $okText = if ($gateReport.checks.Count -gt 0) { " (попутно $($gateReport.checks.Count) утверждений сверены OK)" } else { '' }
        Add-Message -From system -Text ("🔢 Gate-check: " + $gateReport.violations.Count + " несоответствий в reply Codex" + $okText + ":`n" + [string]::Join("`n", $vparts.ToArray()) + "`n`nПланировщик: учти эти разрывы при ревью STATUS — Codex заявил неточно, нужна доработка.") -Kind event | Out-Null
      } elseif ($gateReport.checks.Count -gt 0) {
        $kparts = New-Object 'System.Collections.Generic.List[string]'
        foreach ($c in ($gateReport.checks | Select-Object -First 5)) {
          [void]$kparts.Add("[$($c.kind)] $($c.claim)")
        }
        $more = if ($gateReport.checks.Count -gt 5) { " (+ $($gateReport.checks.Count - 5) more)" } else { '' }
        Add-Message -From system -Text ("✓ Gate-check Codex'а: " + $gateReport.checks.Count + " утверждений сверены с фактами OK — " + [string]::Join('; ', $kparts.ToArray()) + $more) -Kind event | Out-Null
      }
    } catch {
      Add-Message -From system -Text ("⚠ Gate-check exception: " + $_.Exception.Message) -Kind event | Out-Null
    }
  }
  if ($fastLaneActiveForTurn) {
    $coderStatusHits = [regex]::Matches($reply, '(?im)^\s*STATUS:\s*(DONE|CONTINUE)\s*$')
    if ($coderStatusHits.Count -gt 0) {
      $coderStatus = $coderStatusHits[$coderStatusHits.Count - 1].Groups[1].Value.ToUpper()
      if ($coderStatus -eq 'DONE') {
        $plannerStatus = 'DONE'
        try { Add-SessionDecisionEvent -EventType 'convergence' -Meta @{ source='coder'; ts=(Get-Date).ToString('o') } -Channel $Channel } catch {}
        $fastLaneDone = $true
      }
    }
  }
  if ($speaker -eq 'claude') {
    $statusHits = [regex]::Matches($reply, '(?im)^\s*STATUS:\s*(CHAT|CONTINUE|DISCUSS|DONE|RESEARCH)\s*$')
    if ($statusHits.Count -gt 0) { $plannerStatus = $statusHits[$statusHits.Count - 1].Groups[1].Value.ToUpper() }

    # FIX 2026-05-27: parallel coder dispatch. If planner reply contains >= 2 [[PARALLEL:N]]
    # blocks with file-disjoint workloads, fan out to worker pool (Claude+Codex round-robin
    # in separate worktrees) instead of normal Codex-only flow. After merge, treat as if
    # planner had said STATUS: DONE so verify gate + critic proceed normally on combined diff.
    if ($plannerStatus -eq 'CONTINUE' -and ($modeBeforeIncrement -eq 'normal' -or $modeBeforeIncrement -eq 'discuss')) {
      $parStreams = $null
      try { $parStreams = Test-CanParallelize -PlanText $reply } catch { $parStreams = $null }
      if ($parStreams -and $parStreams.Count -ge 2) {
        try {
          Add-Message -From system -Text ("🔀 Parallel dispatch: " + $parStreams.Count + " streams detected in planner reply") -Kind event | Out-Null
          $parResult = Invoke-ParallelDispatch -Streams $parStreams -TimeoutMin 25 -PollSec 10
          if ($parResult.ok) {
            Add-Message -From system -Text ("✅ Parallel completed: " + $parResult.merged + " streams merged into main") -Kind event | Out-Null
            $plannerStatus = 'DONE'   # work landed via workers; let verify+critic gates run
            $modeBeforeIncrement = 'normal'  # parallel delivered real implementation; force normal-mode so verify+critic+smoke gates run
            Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.task_did_actions = $true; $s.coder_fired = $true } | Out-Null
          } else {
            Add-Message -From system -Text ("⚠ Parallel failed: " + $parResult.reason + " -- fallback to sequential Codex") -Kind event | Out-Null
            # leave $plannerStatus as CONTINUE -- normal Codex turn next iteration
          }
        } catch {
          Add-Message -From system -Text ("⚠ Parallel exception: " + $_.Exception.Message + " -- fallback to sequential") -Kind event | Out-Null
        }
      }
    }

    if ($plannerStatus -eq 'DISCUSS') {
      if ($modeBeforeIncrement -ne 'discuss') {
        Update-State { param($s) $s.task_mode='discuss'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
      } else {
        Update-State { param($s) $s.task_mode='discuss' } | Out-Null
      }
    }
    elseif ($plannerStatus -eq 'CONTINUE') {
      if ($modeBeforeIncrement -eq 'discuss') {
        $dtNow = [int](Read-State).discuss_turn
        # FIX 2026-05-27: accept synonyms for the convergence-check keywords. Claude often
        # writes "Согласовано:" / "Decision:" / "Решено:" instead of literal "Решение:" —
        # technically a converged plan, but the pedantic gate kept rejecting it (12-min
        # ping-pong observed today on a 12-point task). Same for Риски/Risks/Risk.
        $hasDecision = $reply -imatch '(?im)^[*_> \t#-]*(Решение|Решено|Decision|Согласовано):[ \t]*\S'
        $hasRisks    = $reply -imatch '(?im)^[*_> \t#-]*(Риски|Риск|Risks|Risk):[ \t]*\S'
        $openMatch   = [regex]::Match($reply, '(?im)^[*_> \t#-]*Открыто:[ \t]*(.*)$')
        # FIX 2026-05-26 (Codex's Doctor fix, applied manually after restart-loop incident):
        # TrimEnd punctuation so "Открыто: нет." matches the "no open blockers" regex.
        # Without this, a trailing dot in "нет." was treated as an unresolved open question
        # and the convergence gate kept looping until 905s Codex timeout fired.
        $openVal     = if ($openMatch.Success) { $openMatch.Groups[1].Value.Trim().Trim('*').Trim().TrimEnd('.',',',';','!','?',':',' ') } else { 'нет' }
        $openClosed  = [string]::IsNullOrWhiteSpace($openVal) -or ($openVal -imatch '^(нет|нет блокеров|блокеров нет|отсутствуют|none|n/?a|-|—)$')
        $converged   = ($dtNow -ge $discussMinTurns) -and $hasDecision -and $hasRisks -and $openClosed
        $ceiling     = ($dtNow -ge $discussMaxTurns)
        $planMatch = [regex]::Match($reply, '(?ims)^[*_> \t#-]*План\s+реализации[^:\n]*:[*_ \t]*(.*?)(?=^\s*[*_> \t#-]*(STATUS:|Тип:|Согласовано:|Открыто:|Решение:|Риски:)|\z)')
        $hasPlan = $planMatch.Success -and -not [string]::IsNullOrWhiteSpace($planMatch.Groups[1].Value)
        if (-not $ceiling -and (-not $converged -or -not $hasPlan)) {
          $why = if ($dtNow -lt $discussMinTurns) { "рано ($dtNow/$discussMinTurns ходов)" }
                 elseif (-not $hasDecision -or -not $hasRisks) { "нет блока «Решение:»/«Риски:»" }
                 elseif (-not $openClosed) { "остались открытые вопросы: $openVal" }
                 else { "нет непустого «План реализации:»" }
          Add-Message -From system -Text "💬 CONTINUE из обсуждения требует конвергенции и непустой «План реализации:» — $why. Claude, закройте блок состояния и повторите." -Kind event | Out-Null
          $plannerStatus = 'DISCUSS'
          Update-State { param($s) $s.task_mode='discuss' } | Out-Null
        } else {
          if ($ceiling -and (-not $converged -or -not $hasPlan)) {
            Add-Message -From system -Text "💬 Потолок обсуждения ($discussMaxTurns ходов) достигнут — закрываю обсуждение с текущим планом, передаю Codex'у." -Kind event | Out-Null
          }
          Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
        }
      } elseif ($modeBeforeIncrement -eq 'study') {
        Update-State { param($s) $s.task_mode='study'; $s.discuss_turn=0; $s.discuss_snapshot='' } | Out-Null
      } else {
        Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
      }
    }
    elseif ($plannerStatus -eq 'RESEARCH') {
      if ($modeBeforeIncrement -eq 'study') {
        Add-Message -From system -Text "📚 Study уже имеет web-инструменты; продолжаю в режиме study вместо отдельного research." -Kind event | Out-Null
        $plannerStatus = 'CONTINUE'
        Update-State { param($s) $s.task_mode='study'; $s.discuss_turn=0; $s.discuss_snapshot='' } | Out-Null
      } elseif ($modeBeforeIncrement -eq 'research') {
        Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
      } else {
        $rc = [int](Read-State).research_count
        if ($rc -lt $researchMaxTurns) {
          $newRc = $rc + 1
          Update-State ({ param($s) $s.task_mode='research'; $s.research_count=$newRc; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' }.GetNewClosure()) | Out-Null
        } else {
          Add-Message -From system -Text "🔍 Бюджет research исчерпан ($researchMaxTurns/$researchMaxTurns ходов). Codex получит уже собранные данные." -Kind event | Out-Null
          Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
        }
      }
    }
    if ($modeBeforeIncrement -eq 'research' -and $plannerStatus -ne 'DONE' -and $plannerStatus -ne 'CHAT') {
      Update-State { param($s) $s.task_mode='normal'; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot='' } | Out-Null
    }
  }
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'CHAT') {
    Add-Message -From system -Text "💬 Ответ без Codex. Жду следующее сообщение." -Kind event | Out-Null
    Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'done'; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s; Clear-ChunkingState $s; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle' } | Out-Null
    continue
  }
  # Guard: в discuss DONE разрешён только при конвергенции (по состоянию), с полом и потолком по ходам
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'discuss') {
    $dtNow = [int](Read-State).discuss_turn
    # FIX 2026-05-27: same synonyms accepted here (DONE-in-discuss path), see CONTINUE branch above.
    $hasDecision = $reply -imatch '(?im)^[*_> \t#-]*(Решение|Решено|Decision|Согласовано):[ \t]*\S'
    $hasRisks    = $reply -imatch '(?im)^[*_> \t#-]*(Риски|Риск|Risks|Risk):[ \t]*\S'
    $openMatch   = [regex]::Match($reply, '(?im)^[*_> \t#-]*Открыто:[ \t]*(.*)$')
    # Same TrimEnd punctuation fix as above (2026-05-26): keeps "нет." from being treated
    # as unresolved open question.
    $openVal     = if ($openMatch.Success) { $openMatch.Groups[1].Value.Trim().Trim('*').Trim().TrimEnd('.',',',';','!','?',':',' ') } else { 'нет' }
    $openClosed  = [string]::IsNullOrWhiteSpace($openVal) -or ($openVal -imatch '^(нет|нет блокеров|блокеров нет|отсутствуют|none|n/?a|-|—)$')
    $converged   = ($dtNow -ge $discussMinTurns) -and $hasDecision -and $hasRisks -and $openClosed
    $ceiling     = ($dtNow -ge $discussMaxTurns)
    if (-not $converged -and -not $ceiling) {
      $why = if ($dtNow -lt $discussMinTurns) { "рано ($dtNow/$discussMinTurns ходов)" }
             elseif (-not $hasDecision -or -not $hasRisks) { "нет блока «Решение:»/«Риски:»" }
             else { "остались открытые вопросы: $openVal" }
      Add-Message -From system -Text "💬 Обсуждение продолжается — $why. Claude, доведите до синтеза: блок Согласовано/Открыто/Решение/Риски, «Открыто» пусто." -Kind event | Out-Null
      $plannerStatus = 'DISCUSS'
      Update-State { param($s) $s.task_mode='discuss' } | Out-Null
    } elseif ($ceiling -and -not $converged) {
      Add-Message -From system -Text "💬 Потолок обсуждения ($discussMaxTurns ходов) — закрываю с текущим решением." -Kind event | Out-Null
    }
    # 🧭 Deep-think harvest: at converged DONE of a [[DEEP-THINK]] discuss task, parse the
    # planner's `IDEA: <text>` lines from the ## ИТОГ and file them as backlog ideas with
    # tag=architect+deep-think. These are the ideas that survived the Claude<->Codex critique.
    if (($converged -or $ceiling) -and ($task -match '\[\[DEEP-THINK\]\]')) {
      try {
        $pbForDeepThink = Get-ActiveProjectBinding
        $ideaLines = [regex]::Matches($reply, '(?im)^\s*[*_> \t#-]*IDEA:\s*(.+)$')
        $filed = 0
        foreach ($im in $ideaLines) {
          $itext = $im.Groups[1].Value.Trim() -replace '\*+$',''
          if ([string]::IsNullOrWhiteSpace($itext)) { continue }
          $id = Add-Idea -Text $itext -From 'architect' -Tags @('architect','deep-think','dialog-survived') -Status 'new' -Project ([string]$pbForDeepThink.slug) -Scope 'bridge'
          if ($id) { $filed++ }
        }
        if ($filed -gt 0) {
          Add-Message -From system -Text ("🧭💭 Deep-think dialog завершён: " + $filed + " идей прошли критику Codex'а и легли в беклог (тег: architect+deep-think+dialog-survived, status=new).") -Kind event | Out-Null
        }
      } catch {}
    }
  }
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'study') {
    $hasStudyReport = $false
    foreach ($fp in $fileMarkerPaths) {
      try {
        if ([System.IO.Path]::GetExtension([string]$fp) -ieq '.md') { $hasStudyReport = $true }
      } catch {}
    }
    if (-not $hasStudyReport -or $attachmentMetas.Count -eq 0) {
      Add-Message -From system -Text "📚 Study требует итоговый Markdown-отчёт через [[FILE: ...md]]. Claude, создай/прикрепи отчёт и повтори синтез." -Kind event | Out-Null
      $plannerStatus = 'CONTINUE'
      Update-State { param($s) $s.task_mode='study'; $s.study_phase='synthesis' } | Out-Null
    }
  }
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    $didActions = [bool](Read-State).task_did_actions
    $hasVerify  = $reply -imatch '(?im)^\s*\[\[VERIFIED:\s*.+?\]\]\s*$'
    $vrc        = [int](Read-State).verify_retry_count
    if ($didActions -and -not $hasVerify -and $vrc -lt 2) {
      Add-Message -From system -Text "🔍 Фаза верификации: задача меняла файлы, но проверки нет. Агент, ВЫПОЛНИ проверочную команду/тест/чтение файла/скриншот, покажи результат и добавь строку [[VERIFIED: что проверено | результат]], затем STATUS: DONE." -Kind event | Out-Null
      $plannerStatus = 'VERIFY'
      Update-State { param($s) $s.verify_retry_count=[int]$s.verify_retry_count+1; $s.force_planner=$true } | Out-Null
    } elseif ($didActions -and -not $hasVerify -and $vrc -ge 2) {
      $vfDiff = ''
      try {
        $vfBase = [string](Read-State).task_base_commit
        $vfRepoRoot = Get-TaskRepoRoot
        if (-not [string]::IsNullOrWhiteSpace($vfBase)) {
          $vfBaseOk = $false
          try {
            $vfBaseType = (& git -C $vfRepoRoot cat-file -t $vfBase 2>$null | Select-Object -First 1)
            if ([string]$vfBaseType -eq 'commit') { $vfBaseOk = $true }
          } catch {}
          if (-not $vfBaseOk) { $vfBase = '' }
        }
        if (-not [string]::IsNullOrWhiteSpace($vfBase)) {
          $vfDiff = (& git -C $vfRepoRoot diff $vfBase -- 2>$null | Out-String).Trim()
          if ($vfDiff.Length -gt 2000) { $vfDiff = $vfDiff.Substring(0,2000) + "`n...[truncated]" }
        }
      } catch {}
      $vfLast = $reply.Trim(); if ($vfLast.Length -gt 800) { $vfLast = $vfLast.Substring(0,800) + "`n...[truncated]" }
      $vfMsg = "🔍 Верификация не пройдена за 2 попытки — закрываю как есть."
      if ($vfDiff) { $vfMsg += "`n`n**Git diff (от начала задачи):**`n``````diff`n$vfDiff`n``````" }
      if ($vfLast) { $vfMsg += "`n`n**Последний вывод агента:**`n``````$vfLast`n``````" }
      Add-Message -From system -Text $vfMsg -Kind event | Out-Null
      try { Send-PushEvent -Kind need_you -Text "Верификация не пройдена: $(Get-PushSnippet -Text $task)" } catch {}
      # 2026-05-28: explicitly clear task_did_actions so the verify-check doesn't
      # re-fire on the next planner DONE. Previously this branch only printed
      # a message — but the same DONE could land again after a restart (vrc=2
      # preserved), and the elseif would print THE SAME warning forever. Bridge
      # logged "Верификация не пройдена за 2 попытки" repeatedly on every restart.
      # Setting task_did_actions=false makes the verify-check a no-op next pass,
      # letting plannerStatus=DONE close the task naturally.
      Update-State { param($s) $s.task_did_actions = $false } | Out-Null
    }
  }
  # Coder-bypass gate: planner did file edits without invoking Codex -> reject DONE, force CONTINUE->Codex+critic.
  # The critic only reviews Codex diffs; if Opus modifies files directly, its diff ships without independent review.
  # Probe 2 (2026-05-26) exposed this: Opus single-handedly committed mobile button rearrangement; critic skipped.
  if ($speaker -eq 'claude' -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    $stCB = Read-State
    if ([bool]$stCB.task_did_actions -and -not [bool]$stCB.coder_fired) {
      $cbr = [int]$stCB.coder_bypass_retry_count
      if ($cbr -lt 2) {
        Add-Message -From system -Text "🔁 Кодер пропущен: задача меняла файлы, но Codex не вызывался. Claude, ОБЯЗАТЕЛЬНО передай реализацию через STATUS: CONTINUE с конкретной инструкцией Codex'у (что/где/критерий) — он напишет правки, критик их проверит. Multi-agent дисциплина: правки кода идут через кодера, а не через планировщика." -Kind event | Out-Null
        $plannerStatus = 'CONTINUE'
        Update-State { param($s) $s.coder_bypass_retry_count=[int]$s.coder_bypass_retry_count+1; $s.force_planner=$true } | Out-Null
      } else {
        Add-Message -From system -Text "🔁 Coder-bypass: планировщик 2× не передал работу Codex — закрываю как есть, нужно внимание оператора." -Kind event | Out-Null
        try { Send-PushEvent -Kind need_you -Text "Coder-bypass: $(Get-PushSnippet -Text $task)" } catch {}
      }
    }
  }
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    # Независимый критик: перед закрытием ревьюим git-дифф задачи на другой модели.
    # Серьёзное -> возврат Codex на доработку; сбои критика не блокируют завершение.
    try {
      $stC = Read-State
      if ([bool]$stC.task_did_actions) {
        if ([bool]$stC.skip_critic) {
          Add-Message -From system -Text "⏭ Critic пропущен (fast-lane)" -Kind event | Out-Null
        } else {
        $criticMaxRetries = 2
        try { $cfgCr = Get-BridgeConfig; if ($cfgCr.PSObject.Properties.Name -contains 'criticMaxRetries') { $criticMaxRetries = [int]$cfgCr.criticMaxRetries } } catch {}
        $crc  = [int]$stC.critic_retry_count
        $base = [string]$stC.task_base_commit
        $criticRepoRoot = Get-TaskRepoRoot
        if (-not [string]::IsNullOrWhiteSpace($base)) {
          $baseOkForCritic = $false
          try {
            $baseTypeForCritic = (& git -C $criticRepoRoot cat-file -t $base 2>$null | Select-Object -First 1)
            if ([string]$baseTypeForCritic -eq 'commit') { $baseOkForCritic = $true }
          } catch {}
          if (-not $baseOkForCritic) { $base = '' }
        }
        $diff = ''
        if (-not [string]::IsNullOrWhiteSpace($base)) {
          try { $diff = (& git -C $criticRepoRoot diff $base -- 2>$null | Out-String) } catch { $diff = '' }
        }
        if ([string]::IsNullOrWhiteSpace($diff)) {
          try { $diff = (& git -C $criticRepoRoot diff HEAD -- 2>$null | Out-String) } catch { $diff = '' }
        }
        if (-not [string]::IsNullOrWhiteSpace($diff)) {
          if ($crc -ge $criticMaxRetries) {
            Add-Message -From system -Text "🔎 Критик: лимит доработок ($criticMaxRetries) исчерпан — закрываю задачу как есть, нужно внимание оператора." -Kind event | Out-Null
            try { Send-PushEvent -Kind need_you -Text "Критик исчерпал лимит доработок: $(Get-PushSnippet -Text $task)" } catch {}
          } else {
            $llmCfg = $null
            try { $llmCfg = Get-LLMConfig } catch {}
            $criticLight = if ($llmCfg -and $llmCfg.ContainsKey('critic')) { [string]$llmCfg['critic'] } else { 'deepseek-v4-flash' }
            $criticHeavy = if ($llmCfg -and $llmCfg.ContainsKey('criticHeavy')) { [string]$llmCfg['criticHeavy'] } else { 'deepseek-v4-pro' }
            $diffNames = @()
            try {
              if (-not [string]::IsNullOrWhiteSpace($base)) { $diffNames = @(& git -C $criticRepoRoot diff --name-only $base -- 2>$null) }
              if (@($diffNames).Count -eq 0) { $diffNames = @(& git -C $criticRepoRoot diff --name-only HEAD -- 2>$null) }
            } catch {}
            $linesChanged = 0
            try {
              $numstat = @()
              if (-not [string]::IsNullOrWhiteSpace($base)) { $numstat = @(& git -C $criticRepoRoot diff --numstat $base -- 2>$null) }
              if (@($numstat).Count -eq 0) { $numstat = @(& git -C $criticRepoRoot diff --numstat HEAD -- 2>$null) }
              foreach ($lnStat in @($numstat)) {
                $parts = @(([string]$lnStat) -split '\s+')
                if ($parts.Count -ge 2) {
                  $adds = 0; $dels = 0
                  [int]::TryParse($parts[0], [ref]$adds) | Out-Null
                  [int]::TryParse($parts[1], [ref]$dels) | Out-Null
                  $linesChanged += ($adds + $dels)
                }
              }
            } catch {}
            $heavyRegex = '(?i)security|auth|secret|crypto|race|mutex|lock|concurr(en|ency)?|sql\s*injection|inject(ion)?|csrf|xss'
            $isHeavyCritic = (@($diffNames).Count -gt 3) -or ($linesChanged -gt 100) -or ($diff -match $heavyRegex)
            $crcNow = 0
            try { $crcNow = [int](Read-State).critic_retry_count } catch {}
            if ($crcNow -ge 1) { $isHeavyCritic = $true }
            $criticModelName = if ($isHeavyCritic) { $criticHeavy } else { $criticLight }

            # 2026-05-27: deterministic CLI-flag check BEFORE the LLM critic.
            # The LLM critic (deepseek) approved a non-existent --cwd flag for
            # claude.exe in the prior Wave-C-tails task because it has no way
            # to run the CLI. This pre-check actually invokes `cli --help` and
            # rejects diffs that introduce unknown flags. Findings here are
            # treated as serious and prepended to LLM issues -- they cannot be
            # talked away by the LLM.
            $cliFlagIssues = @()
            try { $cliFlagIssues = @(Test-CliFlagsInDiff -Diff $diff) } catch {
              Add-Message -From system -Text ("⚠ CLI-flag check failed: " + $_.Exception.Message) -Kind event | Out-Null
            }
            $cliFlagIssuesText = ''
            if ($cliFlagIssues.Count -gt 0) {
              $parts = New-Object 'System.Collections.Generic.List[string]'
              foreach ($iss in $cliFlagIssues) {
                [void]$parts.Add(("$($iss.cli).exe не знает флага '$($iss.flag)' (в --help отсутствует). Пример строки: " + ($iss.sample -replace '\s+',' ')))
              }
              $cliFlagIssuesText = [string]::Join(' ; ', $parts.ToArray())
              Add-Message -From system -Text ("🔎 CLI-flag-check: " + $cliFlagIssuesText) -Kind event | Out-Null
            }

            $qualityBypassIssues = @()
            try { $qualityBypassIssues = @(Test-QualityBypassesInDiff -Diff $diff) } catch {
              Add-Message -From system -Text ("⚠ Quality-bypass check failed: " + $_.Exception.Message) -Kind event | Out-Null
            }
            $qualityBypassIssuesText = ''
            if ($qualityBypassIssues.Count -gt 0) {
              $qbParts = New-Object 'System.Collections.Generic.List[string]'
              foreach ($iss in $qualityBypassIssues) {
                [void]$qbParts.Add(("$($iss.reason). Пример строки: " + ($iss.sample -replace '\s+',' ')))
              }
              $qualityBypassIssuesText = [string]::Join(' ; ', $qbParts.ToArray())
              Add-Message -From system -Text ("🔎 Quality-bypass-check: " + $qualityBypassIssuesText) -Kind event | Out-Null
            }

            $diffWasTruncated = $false
            $diffBytes = 0
            try { $diffBytes = [Text.Encoding]::UTF8.GetByteCount($diff) } catch { $diffBytes = $diff.Length }
            if ($diff.Length -gt 16000) {
              $diffWasTruncated = $true
              $diff = $diff.Substring(0,16000) + "`n...[дифф обрезан]..."
            }
            $truncationNote = if ($diffWasTruncated) {
              "ВАЖНО: diff ниже обрезан по лимиту контекста. Не считай сам факт обрезки синтаксической ошибкой, потерей кода или доказательством обрезанной функции; проверяй только реально видимые изменения. Синтаксис .ps1 и BOM проверяются отдельными командами."
            } else { "" }
            $diffTruncatedText = ([string]$diffWasTruncated).ToLowerInvariant()
            $changedFilesText = ''
            try {
              $changedLines = @()
              if (-not [string]::IsNullOrWhiteSpace($base)) { $changedLines = @(& git -C $criticRepoRoot diff --name-status $base -- 2>$null) }
              if (@($changedLines).Count -eq 0) { $changedLines = @(& git -C $criticRepoRoot diff --name-status HEAD -- 2>$null) }
              $changedFilesText = [string]::Join("`n", @($changedLines))
              if ($changedFilesText.Length -gt 3000) { $changedFilesText = $changedFilesText.Substring(0, 3000) + "`n...[changed-files truncated]..." }
            } catch {
              $changedFilesText = "(changed-files unavailable: $($_.Exception.Message))"
            }
            $taskHistory = ''
            if (-not [string]::IsNullOrWhiteSpace($base)) {
              try {
                $histLines = @(& git -C $criticRepoRoot log --oneline --name-status "$base..HEAD" 2>$null)
                $taskHistory = [string]::Join("`n", @($histLines))
                if ($taskHistory.Length -gt 6000) {
                  $taskHistory = $taskHistory.Substring(0, 6000) + "`n...[история обрезана]..."
                }
              } catch {
                $taskHistory = "(task-history unavailable: $($_.Exception.Message))"
              }
            }
            # HEAD context lets the critic distinguish "not in this diff" from "not in repo".
            $headContext = ''
            $symbolEvidence = ''
            try {
              $repoPs1Files = @()
              try { $repoPs1Files = @(& git -C $criticRepoRoot ls-files --cached '*.ps1' 2>$null) } catch { $repoPs1Files = @() }
              $repoPs1List = if ($repoPs1Files.Count -gt 0) { [string]::Join(', ', $repoPs1Files) } else { '(none)' }

              $funcLines = New-Object 'System.Collections.Generic.List[string]'
              $diffPs1Names = @($diffNames | Where-Object { $_ -match '\.ps1$' })
              $diffPs1Set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
              foreach ($relDiffPs1 in $diffPs1Names) { [void]$diffPs1Set.Add([string]$relDiffPs1) }
              foreach ($relf in $diffPs1Names) {
                $fullF = Join-Path $criticRepoRoot $relf
                if (Test-Path $fullF) {
                  $fns = @()
                  try {
                    $fns = @(& git -C $criticRepoRoot show ('HEAD:' + ($relf -replace '\\','/')) 2>$null |
                      Select-String -Pattern '^\s*function\s+([A-Za-z][\w-]*)' -AllMatches |
                      ForEach-Object { $_.Matches | ForEach-Object { $_.Groups[1].Value } })
                  } catch { $fns = @() }
                  if ($fns.Count -gt 0) {
                    [void]$funcLines.Add(($relf + ': ' + [string]::Join(', ', $fns)))
                  }
                }
              }

              $allFuncsInDiffedFiles = New-Object 'System.Collections.Generic.HashSet[string]'
              foreach ($ln in @($funcLines)) {
                $parts2 = $ln -split ': ', 2
                if ($parts2.Count -eq 2) {
                  foreach ($fn in ($parts2[1] -split ', ')) {
                    [void]$allFuncsInDiffedFiles.Add($fn.Trim())
                  }
                }
              }

              $calledInDiff = @()
              try {
                $cmdNamePattern = '(?:Invoke-|Get-|Set-|Add-|Remove-|Test-|New-|Write-|Read-|Send-|Update-|Save-|Load-|Build-|Find-|Format-|Start-|Stop-)[A-Za-z][\w-]*'
                $calledSet = New-Object 'System.Collections.Generic.HashSet[string]'
                foreach ($dln in ($diff -split "`r?`n")) {
                  if ($dln -notmatch '^[\+\- ]') { continue }
                  if ($dln -match '^(?:\+\+\+|---)') { continue }
                  $codeLine = if ($dln.Length -gt 0) { $dln.Substring(1) } else { '' }
                  if ($codeLine -match '^\s*#') { continue }
                  foreach ($m in [regex]::Matches($codeLine, "(?<![\w-])$cmdNamePattern(?![\w-])")) {
                    [void]$calledSet.Add($m.Value)
                  }
                }
                $calledInDiff = @($calledSet | Sort-Object)
              } catch { $calledInDiff = @() }

              $crossRefs = New-Object 'System.Collections.Generic.List[string]'
              $symbolEvidenceParts = New-Object 'System.Collections.Generic.List[string]'
              foreach ($fn in $calledInDiff) {
                if ($allFuncsInDiffedFiles.Contains($fn)) { continue }
                $fnFiles = New-Object 'System.Collections.Generic.List[string]'
                foreach ($rf in $repoPs1Files) {
                  $fullRf = Join-Path $criticRepoRoot $rf
                  if (-not (Test-Path $fullRf)) { continue }
                  if ($diffPs1Set.Contains([string]$rf)) { continue }
                  try {
                    $headLines = @(& git -C $criticRepoRoot show ('HEAD:' + ($rf -replace '\\','/')) 2>$null)
                    $fnPattern = '^\s*function\s+' + [regex]::Escape($fn) + '\b'
                    $hitIndex = -1
                    for ($idx = 0; $idx -lt $headLines.Count; $idx++) {
                      if ([string]$headLines[$idx] -match $fnPattern) { $hitIndex = $idx; break }
                    }
                    $hit = ($hitIndex -ge 0)
                    if ($hit) {
                      [void]$fnFiles.Add($rf)
                      if ($symbolEvidence.Length -lt 8000) {
                        $endIdx = [Math]::Min($headLines.Count - 1, $hitIndex + 10)
                        $bodyLines = New-Object 'System.Collections.Generic.List[string]'
                        for ($bodyIdx = $hitIndex; $bodyIdx -le $endIdx; $bodyIdx++) {
                          [void]$bodyLines.Add([string]$headLines[$bodyIdx])
                        }
                        $snippet = ("### {0} -> {1}`n{2}" -f $fn, $rf, [string]::Join("`n", $bodyLines.ToArray()))
                        [void]$symbolEvidenceParts.Add($snippet)
                        $symbolEvidence = [string]::Join("`n`n", $symbolEvidenceParts.ToArray())
                        if ($symbolEvidence.Length -gt 8000) {
                          $symbolEvidence = $symbolEvidence.Substring(0, 8000) + "`n...[symbol-evidence truncated]..."
                          break
                        }
                      }
                    }
                  } catch { $hit = $false }
                }
                if ($fnFiles.Count -gt 0) {
                  [void]$crossRefs.Add($fn + ' -> ' + [string]::Join(', ', $fnFiles.ToArray()))
                }
                if ($symbolEvidence.Length -gt 8000) { break }
              }

              $hcParts = New-Object 'System.Collections.Generic.List[string]'
              if ($funcLines.Count -gt 0) {
                [void]$hcParts.Add("ФУНКЦИИ В ИЗМЕНЁННЫХ ФАЙЛАХ:`n" + [string]::Join("`n", $funcLines.ToArray()))
              }
              if ($crossRefs.Count -gt 0) {
                [void]$hcParts.Add("ФУНКЦИИ ИЗ DIFF, ОПРЕДЕЛЁННЫЕ В ДРУГИХ ФАЙЛАХ:`n" + [string]::Join("`n", $crossRefs.ToArray()))
              }
              [void]$hcParts.Add("ВСЕ .ps1 ФАЙЛЫ РЕПО: $repoPs1List")
              $headContext = [string]::Join("`n`n", $hcParts.ToArray())
              if ($headContext.Length -gt 8000) { $headContext = $headContext.Substring(0, 8000) + "`n...[контекст обрезан]..." }
              if ([string]::IsNullOrWhiteSpace($symbolEvidence)) { $symbolEvidence = "(no cross-file symbol evidence)" }
            } catch {
              $headContext = "(head-context unavailable: $($_.Exception.Message))"
              $symbolEvidence = "(symbol-evidence unavailable: $($_.Exception.Message))"
            }
            $criticPrompt = @"
Ты — независимый код-критик. Другой ИИ (Codex) внёс изменения в проект на PowerShell (автономный мост Claude<->Codex на Windows). Проверь git-дифф на СЕРЬЁЗНЫЕ проблемы: баги, уязвимости безопасности, регрессии, потеря данных, падения, синтаксические ошибки, нарушение инвариантов (каждый .ps1 в UTF-8 с BOM; не трогать watchdog/supervisor/.git; не выводить секреты).
НЕ придирайся к стилю, именованию и форматированию — отмечай только то, что реально сломает работу или создаёт риск.

ОСОБО ПРОВЕРЬ ИЗВЕСТНЫЕ ГРАБЛИ POWERSHELL (частые причины аварий в этом проекте — при наличии ставь severity=serious):
- ConvertTo-Json по строке из `Get-Content -Raw` (или по сырым объектам из ConvertFrom-Json), особенно с -Depth>=12 → рекурсия по ETS-графу провайдера (PSProvider/PSDrive) → OOM ~70ГБ и краш хоста. Должно быть [IO.File]::ReadAllText или `("" + $s)` + ПЛОСКИЕ DTO + -Depth<=10. (это уже роняло мост — /api/radar)
- .ps1 без BOM (PS 5.1 ломает кириллицу); вызов нативного exe (git и т.п.) под $ErrorActionPreference='Stop' (stderr бросит исключение).
- Новый/изменённый API-эндпоинт или UI БЕЗ реальной проверки по HTTP/загрузке страницы.
- Бесконечные циклы / отсутствие таймаута; убийство процессов по возрасту/эвристике; чтение или вывод secrets.json.
- `param([string[]]$Args)` или другие зарезервированные имена параметров (Args/Input/PSCmdlet/MyInvocation/PSScriptRoot) — silent override автоматическими переменными, функция получит пусто или мусор (2026-05-27: Get-BacklogGitOutput с `$Args` вернула git help-страницу 2335 символов вместо коммитов, freshness-check 18 items работал на мусоре).
- `Add-Content -Encoding UTF8` в PS 5.1 пишет BOM при создании файла — JSONL с BOM ломает строгие парсеры. Для JSONL нужно `[IO.File]::AppendAllText($path,$line+"`n",(New-Object Text.UTF8Encoding($false)))`.
- Native command stderr через `2>&1` под PS 5.1 — каждая stderr-строка оборачивается в NativeCommandError ErrorRecord, что часто валит скрипт. Используй `2>$null` отдельно или `cmd /c "... 2>NUL"`.

🔢 ОТДЕЛЬНО — OVER-CLAIM ПАТТЕРН (это уже было причиной 1-часового цикла verify-reject):
Если в коммит-сообщениях или в обвязке кода Codex ЗАЯВЛЯЕТ численный результат («backfill для 51 items», «обновлено N файлов», «все 4 теста OK», «merged 3 streams») БЕЗ инкорпорированной команды-доказательства в самом коде/коммите — это RED FLAG. Помечай severity=serious с конкретикой:
- «commit message заявляет 51 items, но в коде только цикл foreach без проверки итогового count»
- «комментарий говорит "all parsed OK", но parse-проверка не возвращается / не логируется»
Это родилось из curator-задачи 2026-05-27 где Codex 3 раза подряд заявлял «backfill 51» при реальных 3/19/35.

🩺 ПРОВЕРКА: ЗАКРЫВАЕТ ЛИ ФИКС СИМПТОМ ИЛИ ТОЛЬКО МАСКИРУЕТ?
Задача обычно описывает симптом от пользователя («X мигает», «Y тормозит», «не могу Z»). Прежде чем дать OK:
1. Восстанови по тексту задачи: что именно увидел пользователь? Какой конкретный сценарий ломался?
2. Спроси сам себя: ЕСЛИ пользователь повторит этот сценарий после применения этого диффа — симптом ИСЧЕЗНЕТ или просто станет менее частым/будет глотаться guard'ом?
3. Если диф добавляет защиту (guard / try-catch / timeout / retry / epoch check / abort signal / debounce) — это часто МАСКА, а не фикс. Корень обычно лежит на этаж глубже: данные испорчены в источнике, а guard ловит их уже на выходе. Помечай severity=serious с пометкой «patches symptom, not root cause» и предложи где искать корень.
4. Особо для UI/HTTP пар: если диф меняет КЛИЕНТ (web/), но НЕ ТРОГАЕТ серверный эндпоинт, который этот клиент дёргает — это сильный сигнал маскировки. Перечисли эндпоинты, упомянутые в diff клиента, и спроси «их серверная сторона была пересмотрена в этом дифе?». Если нет — severity=serious с конкретным эндпоинтом для проверки.
5. Слова в комментариях кода и в коммит-сообщении: «race», «flicker», «stale», «timing», «debounce», «throttle», «retry» — это часто сигнал, что чинят временной симптом, а не источник несоответствия. Спроси «есть ли источник правды или два потока данных, которые расходятся?»

🔁 ПРОВЕРКА: ЭТО НЕ ПЕРВАЯ ПОПЫТКА?
Если в тексте задачи (или в HEAD-контексте ниже) есть признаки «уже исправляли», «повторяется», «снова», «опять», «ещё раз», «несмотря на <SHA>», ссылки на предыдущие коммиты-фиксы в этой же области — это RECURRENCE. Тогда:
- Назови явно, чем этот диф ОТЛИЧАЕТСЯ от прошлых попыток на уровне рут-каузы (а не имени файла).
- Если диф структурно ПОХОЖ на прошлые (тот же файл, та же функция, добавлен ещё один guard/epoch/abort/timeout) — severity=serious с подписью «N-th attempt, structurally similar to previous fix, root cause likely elsewhere».
- Если этот диф впервые трогает СОВСЕМ ДРУГОЙ слой (UI→server, client→config, lib→tests) — это хороший знак, не флаг.

ЗАДАЧА: $task

=== КОНТЕКСТ ЗАДАЧИ ===
DIFF_META: repo=$criticRepoRoot | base=$base | diff_truncated=$diffTruncatedText | diff_bytes=$diffBytes
DIFF ниже — полный диф от начала задачи до HEAD. Если diff_truncated=true — файлы за пределом могут быть изменены; их отсутствие в DIFF не доказывает, что они не менялись.
TASK_HISTORY показывает все коммиты задачи — используй его для проверки полноты фаз и файлов.
SYMBOL_EVIDENCE — сигнатуры и первые строки функций, вызванных в DIFF, но определённых в других файлах. Если функция есть в SYMBOL_EVIDENCE или в блоке "ФУНКЦИИ В ИЗМЕНЁННЫХ ФАЙЛАХ" из HEAD-контекста — не флагируй её как отсутствующую. Duplicate/drift флагируй только если изменённые строки DIFF реально вводят конфликтующую реализацию.
Аудируй только строки DIFF со знаком + или -. Не аудируй unchanged код из SYMBOL_EVIDENCE, TASK_HISTORY или HEAD-контекста.

=== CHANGED_FILES ===
$changedFilesText

=== TASK_HISTORY ===
$taskHistory

=== SYMBOL_EVIDENCE ===
$symbolEvidence

КОНТЕКСТ HEAD (для проверки over-claim: функции, упомянутые в diff, существуют в этих файлах — не помечай их как несуществующие):
$headContext

$truncationNote

GIT-ДИФФ:
$diff

Верни СТРОГО JSON без markdown и без пояснений:
{"verdict":"OK","severity":"none","issues":[],"summary":"одна фраза по-русски"}
Где severity = "serious" ТОЛЬКО если есть баг/уязвимость/регрессия, которую обязательно исправить до закрытия; иначе "minor" или "none".
"@
            $rawC = Invoke-LLM -Purpose 'critic' -Model $criticModelName -Prompt $criticPrompt -TimeoutSec 90 -Temperature 0.1
            $verdict='OK'; $severity='none'; $summary=''; $issuesText=''
            if (-not [string]::IsNullOrWhiteSpace($rawC)) {
              $cleanC = ($rawC -replace '```json','' -replace '```','').Trim()
              $mC = [regex]::Match($cleanC, '(?s)\{.*\}')
              if ($mC.Success) {
                try {
                  $cv = $mC.Value | ConvertFrom-Json
                  if ($cv.verdict)  { $verdict  = [string]$cv.verdict }
                  if ($cv.severity) { $severity = ([string]$cv.severity).Trim().ToLower() }
                  if ($cv.summary)  { $summary  = [string]$cv.summary }
                  if ($cv.issues) {
                    $issueParts = New-Object 'System.Collections.Generic.List[string]'
                    foreach ($issue in @($cv.issues)) {
                      if ($null -eq $issue) { continue }
                      if ($issue -is [string]) {
                        $txtIssue = ([string]$issue).Trim()
                      } else {
                        $fields = New-Object 'System.Collections.Generic.List[string]'
                        foreach ($pn in @('file','line','severity','issue','problem','message','summary','fix')) {
                          try {
                            if ($issue.PSObject.Properties.Name -contains $pn) {
                              $pv = [string]$issue.$pn
                              if (-not [string]::IsNullOrWhiteSpace($pv)) { [void]$fields.Add(("{0}={1}" -f $pn,$pv)) }
                            }
                          } catch {}
                        }
                        if ($fields.Count -gt 0) { $txtIssue = [string]::Join(' | ', [string[]]@($fields.ToArray())) }
                        else { $txtIssue = ($issue | ConvertTo-Json -Compress -Depth 4) }
                      }
                      if (-not [string]::IsNullOrWhiteSpace($txtIssue)) { [void]$issueParts.Add($txtIssue) }
                    }
                    $issuesText = [string]::Join('; ', [string[]]@($issueParts.ToArray()))
                  }
                } catch {}
              }
            }
            if ([string]::IsNullOrWhiteSpace($issuesText) -and -not [string]::IsNullOrWhiteSpace($summary)) { $issuesText = $summary }

            # 2026-06-02: quality-bypass findings ALWAYS escalate to 'serious'.
            # Passing build by disabling build/type/lint checks is not an implementation;
            # project autonomy must fix the actual code and keep gates meaningful.
            if ($qualityBypassIssues.Count -gt 0) {
              $severity = 'serious'
              $verdict = 'NEEDS_FIX'
              $qbPrefix = "Отключение проверок качества (ground-truth diff check): " + $qualityBypassIssuesText
              if ([string]::IsNullOrWhiteSpace($issuesText)) { $issuesText = $qbPrefix }
              else { $issuesText = $qbPrefix + ' ; ' + $issuesText }
            }

            # 2026-05-27: CLI-flag findings ALWAYS escalate to 'serious' regardless
            # of what the LLM critic decided. Deterministic checks override LLM
            # opinion (the LLM cannot run the CLI, so trust ground truth).
            if ($cliFlagIssues.Count -gt 0) {
              $severity = 'serious'
              $verdict = 'NEEDS_FIX'
              $prefix = "Неверные CLI-флаги (ground-truth check, --help проверен реально): " + $cliFlagIssuesText
              if ([string]::IsNullOrWhiteSpace($issuesText)) { $issuesText = $prefix }
              else { $issuesText = $prefix + ' ; ' + $issuesText }
            }

            $taskShort = ($task -replace '\s+',' ').Trim()
            if ($taskShort.Length -gt 80) { $taskShort = $taskShort.Substring(0,80) }
            try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'critic.log') -Value ((Get-Date).ToString('s') + "  model=$criticModelName verdict=$verdict severity=$severity crc=$crc | $taskShort | $summary | $issuesText") -Encoding UTF8 } catch {}
            if ($severity -eq 'serious') {
              $newCrc = $crc + 1
              Update-State ({ param($s) $s | Add-Member -NotePropertyName critic_retry_count -NotePropertyValue $newCrc -Force }.GetNewClosure()) | Out-Null
              try { Set-TaskLastFailure -Kind critic_rejected -Text $issuesText } catch {}
              Add-Message -From system -Text "🔎 Независимый критик ($criticModelName) нашёл серьёзное (попытка $newCrc/$criticMaxRetries): $issuesText`n`nCodex, исправь это и снова доведи до STATUS: DONE — задачу НЕ закрываю." -Kind event | Out-Null
              $plannerStatus = 'CONTINUE'
              Update-State { param($s) $s.task_mode='normal' } | Out-Null
            } else {
              Add-Message -From system -Text "🔎 Критик ($criticModelName): $verdict / $severity — $summary" -Kind event | Out-Null
            }
          }
        }
        }
      }
    } catch {
      try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'critic.log') -Value ((Get-Date).ToString('s') + '  critic-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
    }
  }
  # Fast ParseFile gate: syntax-check each changed .ps1 individually before slow smoke.
  # Gives specific file+line errors instantly; also catches newly-created .ps1 not yet in smoke list.
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      if ([bool](Read-State).task_did_actions) {
        $pfFiles = @()
        try { $pfFiles = @(& git -C $bridgeRoot diff --name-only HEAD 2>$null | Where-Object { $_ -match '\.ps1$' }) } catch {}
        $pfFailed = $false
        foreach ($psf in $pfFiles) {
          $fullPath = Join-Path $bridgeRoot $psf
          if (Test-Path $fullPath) {
            $pfErrors = $null; $pfTokens = $null
            [System.Management.Automation.Language.Parser]::ParseFile($fullPath,[ref]$pfTokens,[ref]$pfErrors) | Out-Null
            if ($pfErrors -and $pfErrors.Count -gt 0) {
              $errLine = $pfErrors[0].Extent.StartLineNumber; $errMsg = $pfErrors[0].Message
              Add-Message -From system -Text "🚨 ParseFile FAILED: $psf line $errLine — $errMsg. Codex, исправь синтаксис." -Kind event | Out-Null
              Update-State { param($s) $s.verify_retry_count=[int]$s.verify_retry_count+1 } | Out-Null
              $plannerStatus = 'CONTINUE'; $pfFailed = $true; break
            }
          }
        }
        if (-not $pfFailed -and $pfFiles.Count -gt 0) {
          Add-Message -From system -Text "✅ ParseFile OK: $($pfFiles -join ', ')" -Kind event | Out-Null
        }
      }
    } catch {
      try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'smoke.log') -Value ((Get-Date).ToString('s') + '  parsefile-gate-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
    }
  }
  # Auto-smoke gate: after critic passes, if .ps1 files changed vs HEAD, run smoke.ps1 to catch
  # broken masts before accepting DONE. Reuses verify_retry_count so no new state field needed.
  # Catches cases where [[VERIFIED: smoke OK]] is claimed but smoke actually fails.
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      if ([bool](Read-State).task_did_actions) {
        $psChanged = $false
        try {
          $gitSmFiles = & git -C $bridgeRoot diff --name-only HEAD 2>$null
          $psChanged = (@($gitSmFiles | Where-Object { $_ -match '\.ps1$' })).Count -gt 0
        } catch {}
        if ($psChanged) {
          $smokeFile = Join-Path $bridgeRoot 'smoke.ps1'
          if (Test-Path $smokeFile) {
            $launch = [pscustomobject]@{ File = $smokeFile; Channel = (Get-EffectiveChannel) }
            $smokeOut = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
              param($Launch)
              & powershell -NoProfile -ExecutionPolicy Bypass -File ([string]$Launch.File) 2>&1 | Out-String
            }
            $smokeOk  = $smokeOut -imatch 'SMOKE OK'
            $smokeVrc = [int](Read-State).verify_retry_count
            if (-not $smokeOk) {
              $smokeShort = ($smokeOut -replace '\s+',' ').Trim()
              if ($smokeShort.Length -gt 300) { $smokeShort = $smokeShort.Substring(0,300) + '...' }
              try { Set-TaskLastFailure -Kind smoke_failed -Text $smokeShort } catch {}
              if ($smokeVrc -lt 2) {
                Update-State { param($s) $s.verify_retry_count=[int]$s.verify_retry_count+1; $s.force_planner=$false } | Out-Null
                Add-Message -From system -Text "🚨 Авто-smoke FAILED (попытка $($smokeVrc+1)/2) — .ps1 повреждены, задача НЕ закрывается. Codex, исправь: $smokeShort" -Kind event | Out-Null
                $plannerStatus = 'CONTINUE'
              } else {
                $sfDiff = ''
                try {
                  $sfBase = [string](Read-State).task_base_commit
                  if (-not [string]::IsNullOrWhiteSpace($sfBase)) {
                    $sfDiff = (& git -C $bridgeRoot diff $sfBase -- 2>$null | Out-String).Trim()
                    if ($sfDiff.Length -gt 2000) { $sfDiff = $sfDiff.Substring(0,2000) + "`n...[truncated]" }
                  }
                } catch {}
                $sfMsg = "🚨 Авто-smoke провалился 2× — закрываю как есть, нужно внимание оператора."
                if ($sfDiff) { $sfMsg += "`n`n**Git diff (от начала задачи):**`n``````diff`n$sfDiff`n``````" }
                $sfMsg += "`n`n**Smoke output:** $smokeShort"
                Add-Message -From system -Text $sfMsg -Kind event | Out-Null
                try { Send-PushEvent -Kind need_you -Text "Smoke FAIL: $(Get-PushSnippet -Text $task)" } catch {}
              }
            } else {
              Add-Message -From system -Text "✅ Авто-smoke: OK — .ps1 не сломаны." -Kind event | Out-Null
            }
          }
        }
      }
    } catch {
      try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'smoke.log') -Value ((Get-Date).ToString('s') + '  auto-smoke-gate-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
    }
  }
  # QA agent gate: after verify/coder-bypass/critic/parse/smoke gates, run runtime QA before accepting DONE.
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      $stQa = Read-State
      if ([bool]$stQa.task_did_actions) {
        $qaTaskId = [string]$stQa.current_task_id
        if ([string]::IsNullOrWhiteSpace($qaTaskId)) { $qaTaskId = [string]$stQa.current_backlog_id }
        if ([string]::IsNullOrWhiteSpace($qaTaskId)) { $qaTaskId = 'task-' + [string]$stQa.task_start_seq }
        $qaResult = Invoke-QAAgent -TaskId $qaTaskId -TaskTitle $task -Channel $Channel
        if ($qaResult.Verdict -eq 'FAIL') {
          Add-Message -From system -Text "🔴 QA-агент: FAIL`n$($qaResult.Summary)`nВозвращаю задачу на доработку." -Kind event | Out-Null
          $plannerStatus = 'CONTINUE'
        } else {
          Add-Message -From system -Text "✅ QA-агент: PASS — $($qaResult.Summary)" -Kind event | Out-Null
        }
      }
    } catch {
      Add-Message -From system -Text "⚠ QA-агент: ошибка запуска ($($_.Exception.Message)), пропускаю." -Kind event | Out-Null
    }
  }

  # Project Autopilot stop-condition: record the coordinator outcome only after
  # STATUS/COVERED/verification gates have settled the final planner status.
  if ($plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    try {
      $stPaOutcome = Read-State
      $paTask = [string]$stPaOutcome.current_task
      $paBacklogId = [string]$stPaOutcome.current_backlog_id
      if (Get-Command Test-ProjectAutopilotCoordinatorText -ErrorAction SilentlyContinue) {
        $paIsCoordinator = [bool](Test-ProjectAutopilotCoordinatorText -Text $paTask)
      } else {
        $paIsCoordinator = [bool]([regex]::IsMatch($paTask, '(?is)\[project-autopilot\s+[^\]]+\].*Project Autopilot coordinator for channel'))
      }
      if ($paIsCoordinator -and (Get-Command Record-ProjectAutopilotCoordinatorOutcome -ErrorAction SilentlyContinue)) {
        $paChannel = ''
        $paRoot = ''
        try { $paChannel = [string](Get-BacklogPackObjectValue -Obj $pbForMarkers -Name 'slug' -Default '') } catch {}
        try { $paRoot = [string](Get-BacklogPackObjectValue -Obj $pbForMarkers -Name 'project_root' -Default '') } catch {}
        Record-ProjectAutopilotCoordinatorOutcome -Channel $paChannel -ProjectRoot $paRoot -CoordinatorId $paBacklogId -Created ([int]$projectBacklogCreated) -Reason 'final-planner-status-done' | Out-Null
      }
    } catch {
      try { Add-Message -From system -Text ("⚠ Project Autopilot outcome tracking failed: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    }
  }

  if ($plannerStatus -eq 'CONTINUE') {
    try {
      $stCp = Read-State
      $cpTaskId = [string]$stCp.current_task_id
      if ([string]::IsNullOrWhiteSpace($cpTaskId)) { $cpTaskId = [string]$stCp.current_backlog_id }
      if ([string]::IsNullOrWhiteSpace($cpTaskId)) { $cpTaskId = 'task-' + [string]$stCp.task_start_seq }
      $cpStep = 0
      try { $cpStep = [int]$stCp.task_turn } catch { $cpStep = 0 }
      $conversationSummary = ''
      try {
        $conversationSummary = [string](Read-Summary)
      } catch {
        try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'checkpoint.log') -Value ((Get-Date).ToString('s') + '  summary-read-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
      }
      $cpSummary = if ($conversationSummary) { $conversationSummary.Substring(0, [Math]::Min(500, $conversationSummary.Length)) } else { '' }
      Write-TaskCheckpoint -TaskId $cpTaskId -TaskTitle $task -Step $cpStep -LastSummary $cpSummary -Channel $Channel
    } catch {
      try { Add-Content -LiteralPath (Join-Path $bridgeRoot 'checkpoint.log') -Value ((Get-Date).ToString('s') + '  checkpoint-write-error: ' + $_.Exception.Message) -Encoding UTF8 } catch {}
    }
  }
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE') {
    if ($mode -eq 'discuss') {
      try {
        $startSeqD = [int](Read-State).task_start_seq
        $thread = (Get-Messages -Since ($startSeqD - 1) | ForEach-Object { "**$($_.from):** $($_.text)" }) -join "`n`n"
        $dpath = Save-Decision -Title $task -Content $thread
        Add-Message -From system -Text "📝 Итог обсуждения сохранён: $dpath" -Kind event | Out-Null
      } catch {}
    }
    try {
      $memId = Add-TaskMemory -TaskText $task -Outcome $visibleReply -Source ('task:' + $mode)
      if ($memId) { Add-Message -From system -Text "🧠 Запомнено в долговременную память." -Kind event | Out-Null }
    } catch {}
    try {
      $stWorklog = Read-State
      $didWorklogActions = [bool]$stWorklog.task_did_actions
      if (($didWorklogActions -or $mode -eq 'study') -and (Get-Command Update-ProjectMemoryAfterTask -ErrorAction SilentlyContinue)) {
        $commitForWorklog = ''
        try {
          $rootForWorklog = Get-ActiveProjectRoot
          if (-not [string]::IsNullOrWhiteSpace($rootForWorklog)) {
            $commitForWorklog = (& git -C $rootForWorklog rev-parse --short HEAD 2>$null).Trim()
          }
        } catch {}
        $worklogId = Update-ProjectMemoryAfterTask -TaskText $task -Outcome $visibleReply -Channel $Channel -Commit $commitForWorklog
        if ($worklogId) { Add-Message -From system -Text "🧠 Проектная память: worklog обновлён." -Kind event | Out-Null }
      }
    } catch {}
    try {
      $stMem = Read-State
      $turnForSkill = [int]$stMem.task_turn
      $didActionsForSkill = [bool]$stMem.task_did_actions
      if ($turnForSkill -ge 2 -and $didActionsForSkill -and $modeBeforeIncrement -ne 'study') {
        $startSeqSkill = [int]$stMem.task_start_seq
        $thread = (Get-Messages -Since ($startSeqSkill - 1) | ForEach-Object {
          "**$($_.from):** $($_.text)"
        }) -join "`n`n"
        $skillId = Add-SkillMemory -TaskText $task -Transcript $thread
        if ($skillId) { Add-Message -From system -Text "📘 плейбук сохранён." -Kind event | Out-Null }
      }
    } catch {}
    try {
      if ($modeBeforeIncrement -eq 'study') {
        $studyReportPath = $null
        foreach ($fp in $fileMarkerPaths) {
          try {
            $candidate = [string]$fp
            if ([System.IO.Path]::GetExtension($candidate) -ieq '.md' -and (Test-Path -LiteralPath $candidate)) {
              $studyReportPath = $candidate
              break
            }
          } catch {}
        }
        if ($studyReportPath) {
          $lessonCount = Add-StudyLessons -ReportPath $studyReportPath -TaskText $task
          Add-Message -From system -Text "🎓 уроков: $lessonCount" -Kind event | Out-Null
        }
      }
    } catch {}
    # If this was an autonomous backlog task, close it out.
    try {
      $stDoneBacklog = Read-State
      $doneBid = [string]$stDoneBacklog.current_backlog_id
      $doneBatchIds = @()
      try {
        if ($stDoneBacklog.PSObject.Properties.Name -contains 'workpack_batch_ids' -and $null -ne $stDoneBacklog.workpack_batch_ids) {
          $doneBatchIds = @($stDoneBacklog.workpack_batch_ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        }
      } catch { $doneBatchIds = @() }
      $doneIds = if ($doneBatchIds.Count -gt 0) { @($doneBatchIds) } elseif ($doneBid) { @($doneBid) } else { @() }
      if ($doneIds.Count -gt 0) {
        foreach ($doneId in $doneIds) { Set-Idea -Id $doneId -Status 'done' | Out-Null }
        # 🤖 Autonomy metric (Foundation #3): the honest self-sufficiency number — autonomous backlog
        # tasks closed IN A ROW with zero operator messages between them. Increment on each autonomous
        # done; the user-message handler resets the running streak to 0 (best is preserved here).
        $doneIncrement = [Math]::Max(1, [int]$doneIds.Count)
        Update-State ({ param($s)
          $cur = 0; try { $cur = [int]$s.autonomy_streak } catch {}
          $cur += $doneIncrement
          $best = 0; try { $best = [int]$s.autonomy_streak_best } catch {}
          if ($cur -gt $best) { $best = $cur }
          $s | Add-Member -NotePropertyName autonomy_streak      -NotePropertyValue $cur  -Force
          $s | Add-Member -NotePropertyName autonomy_streak_best -NotePropertyValue $best -Force
        }.GetNewClosure()) | Out-Null
        $stk = Read-State
        $sNow = 0; try { $sNow = [int]$stk.autonomy_streak } catch {}
        $sBest = 0; try { $sBest = [int]$stk.autonomy_streak_best } catch {}
        $bestTxt = if ($sBest -gt $sNow) { " (рекорд: $sBest)" } else { '' }
        if ($doneIds.Count -gt 1) {
          Add-Message -From system -Text ("✅ Workpack-batch выполнен: закрыто задач бэклога: " + $doneIds.Count + ". 🤖 Автономных задач подряд без вмешательства: $sNow$bestTxt") -Kind event | Out-Null
        } else {
          Add-Message -From system -Text ("✅ Автозадача из бэклога выполнена и закрыта. 🤖 Автономных задач подряд без вмешательства: $sNow$bestTxt") -Kind event | Out-Null
        }
      }
    } catch {}
    # Mark ANY self-improvement commit as a hypothesis for the 24h verdict cycle (was previously
    # only autonomous backlog tasks -> we missed user-injected tasks and Doctor fixes entirely).
    # Wave 3 widening: any task that changed HEAD vs task_base_commit gets a baseline+commit row.
    try {
      $stEnd = Read-State
      $baseC = [string]$stEnd.task_base_commit
      $headC = try { (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch { '' }
      if ($baseC -and $headC -and $baseC -ne $headC) {
        Write-Hypothesis -CommitHash $headC -TaskText ([string]$task)
      }
    } catch {}
    # 🌱 Self-dev attribution: stamp the resulting commit on a self-executed idea so the safety
    # reflex can later correlate it to the 24h verdict (worse -> auto-dampen the dial). Read-mostly.
    try {
      $stSd = Read-State
      $sdBid = [string]$stSd.current_backlog_id
      if ($sdBid) {
        $sdIdea = Get-IdeaById $sdBid
        if ($sdIdea -and ([bool]$sdIdea.self_exec)) {
          $sdHead = try { (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch { '' }
          if ($sdHead) { Set-IdeaSelfExec -Id $sdBid -Dial ([string]$sdIdea.self_exec_dial) -Commit $sdHead | Out-Null }
        }
      }
    } catch {}
    # 🩺 If Doctor just finished a repair, restore the held task instead of going idle.
    if ([bool](Read-State).doctor_active) {
      try { Complete-Doctor } catch { try { Add-Message -From system -Text ("🩺 Complete-Doctor: " + $_.Exception.Message) -Kind event | Out-Null } catch {} }
      try { Send-PushEvent -Kind done -Text "🩺 Doctor fix shipped; resuming held task." } catch {}
      continue
    }
    try { Send-PushEvent -Kind done -Text "Задача: $(Get-PushSnippet -Text $task)" } catch {}
    Add-Message -From system -Text "✅ Задача выполнена. Жду следующую." -Kind event | Out-Null
    try {
      $stDoneCp = Read-State
      $doneCpTaskId = [string]$stDoneCp.current_task_id
      if ([string]::IsNullOrWhiteSpace($doneCpTaskId)) { $doneCpTaskId = [string]$stDoneCp.current_backlog_id }
      if ([string]::IsNullOrWhiteSpace($doneCpTaskId)) { $doneCpTaskId = 'task-' + [string]$stDoneCp.task_start_seq }
      Clear-TaskCheckpoint -TaskId $doneCpTaskId -Channel $Channel
    } catch {}
    Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'done'; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s -PreserveReflectSkip; Clear-ChunkingState $s; $s.current_backlog_id=$null; $s | Add-Member -NotePropertyName workpack_batch_ids -NotePropertyValue @() -Force; $s | Add-Member -NotePropertyName workpack_batch_active -NotePropertyValue $false -Force; $s | Add-Member -NotePropertyName workpack_batch_dispatched -NotePropertyValue $false -Force; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle'; $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue 0 -Force } | Out-Null
    continue
  }
  if (([int](Read-State).task_turn) -ge $maxTurns) {
    Add-Message -From system -Text "⏸ Достигнут лимит ходов по задаче ($maxTurns). Останавливаю задачу — уточни или дай новую." -Kind event | Out-Null
    try { Send-PushEvent -Kind need_you -Text "Достигнут лимит ходов ($maxTurns): $(Get-PushSnippet -Text $task)" } catch {}
    Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'aborted'; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s; Clear-ChunkingState $s; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle'; $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue 0 -Force } | Out-Null
    continue
  }
  Start-Sleep -Seconds $loopDelay
 } catch {
  try { Add-Message -From system -Text ("Ошибка драйвера: " + $_.Exception.Message + " -- продолжаю.") -Kind event | Out-Null } catch {}
  try { Update-State { param($s) $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null } | Out-Null } catch {}
  Start-Sleep -Seconds $loopDelay
 }
}
