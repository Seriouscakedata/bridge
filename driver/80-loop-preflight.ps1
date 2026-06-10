$script:DriverLoopPreflightBlock = {
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

  try { Invoke-ConversationAutoArchiveIfDue | Out-Null } catch {}

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
      $rcCompletionBackstop = 1800
      $rcBusy = $false
      $rcLiveAgent = $false
      $rcDeepThinkActive = $false
      $rcCompletionFinalizing = $false
      function Test-RestartCoalescerDeepThinkActive {
        param([object]$ChannelState)
        if ($null -eq $ChannelState) { return $false }
        $rcStatus = [string]$ChannelState.status
        $rcMode   = [string]$ChannelState.task_mode
        $rcTask   = [string]$ChannelState.current_task
        $rcSnap   = [string]$ChannelState.discuss_snapshot
        $rcTexts  = @($rcTask, $rcSnap) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        $rcHasMarker = $false
        foreach ($rcText in $rcTexts) {
          if ([string]$rcText -match '\[\[DEEP-THINK\]\]') { $rcHasMarker = $true; break }
        }
        if (-not $rcHasMarker) { return $false }

        # Deep-think filing happens in completion checks before current_task is cleared.
        # Holding until state cleanup is safer than trusting the final transcript marker:
        # STATUS: DONE / ## ИТОГ may be present while IDEA filing has not run yet.
        if (-not [string]::IsNullOrWhiteSpace($rcTask)) { return $true }
        if ($rcStatus -in @('discuss','planning','working','coding','research','study')) { return $true }
        if ($rcMode -in @('discuss','planning','working','coding','research','study')) { return $true }
        return $false
      }
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
            if (Test-RestartCoalescerDeepThinkActive -ChannelState $rcCs) { $rcDeepThinkActive = $true }
            if (Test-RestartCoalescerCompletionFinalizing -ChannelState $rcCs) { $rcCompletionFinalizing = $true; $rcBusy = $true }
            if (([string]$rcCs.status -in @('working','planning','coding','discuss','study','research')) -or (-not [string]::IsNullOrWhiteSpace([string]$rcCs.current_task)) -or [bool]$rcCs.doctor_active) { $rcBusy = $true }
            # 2026-06-09 speed/stability: a LIVE agent_pid mid-turn = the channel is genuinely working,
            # even when SILENT (Claude reasoning produces NO conversation output). The agent-wait owns
            # that agent's lifecycle (stall-grace + 900s wall kill a truly-hung one), so the failsafe-
            # quiet/maxDefer branches below must NOT restart over a live agent — that was recycling atoms
            # mid-turn every 300s of silence (~10 min/atom + zombie risk). Apply the deferred restart only
            # once no agent is live (the inter-turn gap), which is exactly when a reload is safe anyway.
            try { $rcAp = 0; if ($rcCs.PSObject.Properties.Name -contains 'agent_pid') { $rcAp = [int]$rcCs.agent_pid }; if ($rcAp -gt 0 -and (Get-Process -Id $rcAp -ErrorAction SilentlyContinue)) { $rcLiveAgent = $true } } catch {}
          } catch {}
        }
      }
      if ((Test-Path -LiteralPath $rcFlag) -and ($rcBusy -or $rcDeepThinkActive -or $rcCompletionFinalizing)) {
        # 2026-05-30 v3: stamp the FIRST-defer time into restart.deferred content and do
        # NOT reset it on re-defer. Otherwise continuous self-dev work re-defers every
        # tick, bumping the file mtime, so the maxDefer cap (age) never fires and the
        # restart is held FOREVER -- a never-deploying gate exposed this. Keep original stamp.
        try {
          if (Test-Path -LiteralPath $rcDefer) { Remove-Item -LiteralPath $rcFlag -Force }
          else {
            Set-Content -LiteralPath $rcDefer -Value ((Get-Date).ToUniversalTime().ToString('o')) -Encoding ASCII
            Remove-Item -LiteralPath $rcFlag -Force
            if ($rcDeepThinkActive) {
              Add-Message -From system -Text '♻ Перезапуск отложен: идёт [[DEEP-THINK]] discuss, жду filing идей или failsafe-timeout.' -Kind event | Out-Null
            }
          }
          if ($rcDeepThinkActive) { Write-Host 'recycle: deferred restart.flag (active deep-think discuss)' }
          else { Write-Host 'recycle: deferred restart.flag (a channel is busy, coalescing)' }
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
        $rcMessageSink = { param([string]$Text) Add-Message -From system -Text $Text -Kind event | Out-Null }
        $rcDecision = Invoke-RestartCoalescerDeferredApply -DeferredPath $rcDefer -FlagPath $rcFlag -AgeSec $rcAge -QuietSec $rcQuietSec -DeepThinkActive:$rcDeepThinkActive -Busy:$rcBusy -LiveAgent:$rcLiveAgent -PlanHasWork:$rcPlanHasWork -CompletionFinalizing:$rcCompletionFinalizing -MaxDeferSec $rcMaxDefer -CompletionBackstopSec $rcCompletionBackstop -FailsafeQuietSec $rcFailsafeQuiet -MessageSink $rcMessageSink
        if ($rcDecision.reason -eq 'deepthink_active') {
          Write-Host 'recycle: holding deferred restart (active deep-think discuss)'
        } elseif ($rcDecision.reason -eq 'completion_finalizing') {
          Write-Host 'recycle: holding deferred restart (DONE-finalization boundary)'
        } elseif ($rcDecision.reason -eq 'busy') {
          Write-Host 'recycle: holding deferred restart (a channel is busy)'
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
      Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'aborted'; $s.abort=$false; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s; Clear-ChunkingState $s; $s | Add-Member -NotePropertyName workpack_batch_ids -NotePropertyValue @() -Force; $s | Add-Member -NotePropertyName workpack_batch_active -NotePropertyValue $false -Force; $s | Add-Member -NotePropertyName workpack_batch_dispatched -NotePropertyValue $false -Force; $s | Add-Member -NotePropertyName workpack_batch_mode -NotePropertyValue '' -Force; $s.active_jobs=@(); $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.status='idle' } | Out-Null
    Start-Sleep -Seconds 1; continue
  }
  if ($state.paused) { Update-State { param($s) $s.status='paused'; $s.active_agent=$null; $s.active_model=$null; $s.status_text='Пауза: мост ждёт команды продолжить.'; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null; Start-Sleep -Seconds $loopDelay; continue }

  # ───────── RESUME VALIDATION (2026-06-09) — never resume an operator-vetoed task ─────────
  # PROBLEM: on restart (and each loop) the driver resumes current_task from state.json
  # (current_backlog_id) WITHOUT re-checking the backlog item is still claimable. So if the
  # operator/curator rejects or holds a task while it is in-flight, the NEXT restart resumes it
  # verbatim and re-runs the vetoed work — an endless re-run loop. Real incident: a self-built
  # "energy-saving idle mode" was reverted + rejected by the operator, then resumed and rebuilt
  # after the restart. CURE: if the current task's backlog item is now terminated/vetoed
  # (rejected/held/done/dropped/cancelled/archived) or gone, drop it cleanly and go idle to claim
  # fresh work. Runs every iteration, so an operator veto also takes effect on the very next turn.
  if ((-not [string]::IsNullOrWhiteSpace([string]$state.current_backlog_id)) -and (-not [string]::IsNullOrWhiteSpace([string]$state.current_task))) {
    $rvId = [string]$state.current_backlog_id
    $rvItem = $null
    try { $rvItem = @(Get-Backlog | Where-Object { [string]$_.id -eq $rvId } | Select-Object -First 1)[0] } catch { $rvItem = $null }
    $rvStatus = if ($rvItem) { [string]$rvItem.status } else { 'missing' }
    $rvAbortStatuses = @('rejected','held','done','dropped','cancelled','archived')
    if (($rvStatus -eq 'missing') -or ($rvAbortStatuses -contains $rvStatus)) {
      $rvShort = $rvId; if ($rvShort.Length -gt 8) { $rvShort = $rvShort.Substring(0,8) }
      try { Add-Message -From system -Text ("↩ Не возобновляю задачу бэклога " + $rvShort + " — её статус теперь '" + $rvStatus + "' (снята/отклонена/завершена). Сбрасываю и беру новую.") -Kind event | Out-Null } catch {}
      Update-State ({ param($s)
        try { Complete-TaskAgentDuration $s } catch {}
        try { Close-ReplayForStateTask -State $s -Status 'cancelled' } catch {}
        $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.verify_retry_count=0
        try { Clear-FastLaneFlags $s } catch {}
        $s.active_jobs=@(); $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.status='idle'
        $s | Add-Member -NotePropertyName current_backlog_id -NotePropertyValue '' -Force
      }.GetNewClosure()) | Out-Null
      Start-Sleep -Seconds 1; continue
    }
  }

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
    $maxA = Get-DoctorMaxRepairAttempts
    $att  = Get-DoctorRepairAttemptCount -State $state
    if ($att -ge $maxA) {
      Abort-Doctor -Reason "max repair attempts ($maxA) reached"
      Start-Sleep -Seconds $loopDelay; continue
    }
    try {
      $doctorTask = Get-DoctorTaskText
      $baseCommitD = ''
      try { $baseCommitD = (& git -C $bridgeRoot rev-parse HEAD 2>$null).Trim() } catch {}
      $baseDirtyD = @()
      try {
        $baseDirtyD = @(& git -C $bridgeRoot status --porcelain -uall 2>$null | ForEach-Object {
          $ln = [string]$_
          if ($ln.Length -le 3) { return }
          $bp = $ln.Substring(3).Trim()
          if ($bp -match '\s+->\s+(.+)$') { $bp = $Matches[1].Trim() }
          $bp -replace '\\','/'
        } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
      } catch { $baseDirtyD = @() }
      $newRepairAttempt = $att + 1
      try { Save-StateSnapshot -Reason 'doctor_repair_attempt' } catch {}
      Update-State ({ param($s)
        $s.current_task     = $doctorTask
        $s.task_turn        = 0
        $s.task_mode        = 'normal'
        $s.task_start_seq   = [int]$s.lastSeq
        Clear-AuditorSuppressedHashes -State $s
        Clear-FastLaneFlags $s
        Clear-ChunkingState $s
        $s.status           = 'working'
        $s.heartbeat        = (Get-Date).ToString('o')
        $s | Add-Member -NotePropertyName task_base_commit -NotePropertyValue $baseCommitD -Force
        $s | Add-Member -NotePropertyName task_base_dirty -NotePropertyValue @($baseDirtyD) -Force
        $s | Add-Member -NotePropertyName task_bridge_base_commit -NotePropertyValue $baseCommitD -Force
        $s | Add-Member -NotePropertyName task_bridge_base_dirty -NotePropertyValue @($baseDirtyD) -Force
        $s | Add-Member -NotePropertyName doctor_repair_attempts -NotePropertyValue $newRepairAttempt -Force
        $s.doctor_attempts  = $newRepairAttempt
        Reset-TaskAgentDuration $s
      }.GetNewClosure()) | Out-Null
      try { Add-SessionDecisionEvent -EventType 'doctor_fix' -Meta @{ what='doctor_activated' } -Channel $Channel } catch {}
      try { Add-Message -From system -Text ("🩺 Доктор приступает к диагностике и фиксу (repair-попытка " + $newRepairAttempt + "/" + $maxA + ").") -Kind event | Out-Null } catch {}
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
}

function Test-RestartCoalescerCompletionFinalizing {
  param([object]$ChannelState)
  if ($null -eq $ChannelState) { return $false }
  try {
    if (($ChannelState.PSObject.Properties.Name -contains 'completion_finalizing') -and [bool]$ChannelState.completion_finalizing) { return $true }
    if (($ChannelState.PSObject.Properties.Name -contains 'done_finalizing') -and [bool]$ChannelState.done_finalizing) { return $true }
  } catch {}
  return $false
}

function Invoke-RestartCoalescerDeferredApply {
  param(
    [Parameter(Mandatory=$true)][string]$DeferredPath,
    [Parameter(Mandatory=$true)][string]$FlagPath,
    [double]$AgeSec = 0,
    [double]$QuietSec = 0,
    [bool]$DeepThinkActive = $false,
    [bool]$Busy = $false,
    [bool]$LiveAgent = $false,
    [bool]$PlanHasWork = $false,
    [bool]$CompletionFinalizing = $false,
    [int]$MaxDeferSec = 600,
    [int]$CompletionBackstopSec = 1800,
    [int]$FailsafeQuietSec = 300,
    [scriptblock]$MessageSink = $null
  )

  $result = [ordered]@{ action = 'hold'; reason = 'under_cap'; applied = $false }
  if (-not (Test-Path -LiteralPath $DeferredPath)) {
    $result.action = 'none'
    $result.reason = 'no_deferred_restart'
    return [pscustomobject]$result
  }

  $apply = {
    param([string]$Reason, [string]$Message)
    try {
      Move-Item -LiteralPath $DeferredPath -Destination $FlagPath -Force
      if ($MessageSink -and -not [string]::IsNullOrWhiteSpace($Message)) { & $MessageSink $Message }
      $result.action = 'apply'
      $result.reason = $Reason
      $result.applied = $true
    } catch {
      $result.action = 'error'
      $result.reason = ($Reason + ': ' + $_.Exception.Message)
      $result.applied = $false
    }
  }

  if ($CompletionFinalizing -and $AgeSec -lt $CompletionBackstopSec) {
    $result.reason = 'completion_finalizing'
    return [pscustomobject]$result
  }
  if ($CompletionFinalizing -and $AgeSec -ge $CompletionBackstopSec) {
    & $apply 'completion_backstop' '♻ Отложенный перезапуск применён по runaway-backstop: DONE-finalization hold превысил 1800с.'
    return [pscustomobject]$result
  }
  if ($DeepThinkActive -and $QuietSec -ge $FailsafeQuietSec) {
    & $apply 'deepthink_quiet_failsafe' ('♻ Применяю отложенный перезапуск — [[DEEP-THINK]] ещё активен, но мост тих ' + [int]$QuietSec + 'с (failsafe).')
    return [pscustomobject]$result
  }
  if ($DeepThinkActive -and $AgeSec -ge $MaxDeferSec) {
    & $apply 'deepthink_max_defer' '♻ Отложенный перезапуск применён по таймауту: [[DEEP-THINK]] hold превысил максимум.'
    return [pscustomobject]$result
  }
  if ($DeepThinkActive) {
    $result.reason = 'deepthink_active'
    return [pscustomobject]$result
  }
  if ($Busy -and (-not $LiveAgent) -and $QuietSec -ge $FailsafeQuietSec) {
    & $apply 'busy_quiet_failsafe' ('♻ Применяю отложенный перезапуск — канал ещё busy, но агент не жив и мост тих ' + [int]$QuietSec + 'с (failsafe).')
    return [pscustomobject]$result
  }
  if ($Busy -and (-not $LiveAgent) -and $AgeSec -ge $MaxDeferSec) {
    & $apply 'busy_max_defer' '♻ Отложенный перезапуск применён по таймауту: busy-hold превысил максимум.'
    return [pscustomobject]$result
  }
  if ($Busy) {
    $result.reason = 'busy'
    return [pscustomobject]$result
  }
  if (-not $PlanHasWork) {
    & $apply 'plan_empty' '♻ Применяю отложенный перезапуск — план пуст, пачка self-dev правок завершена (один recycle).'
    return [pscustomobject]$result
  }
  if ($QuietSec -ge $FailsafeQuietSec) {
    & $apply 'quiet_failsafe' ('♻ Применяю отложенный перезапуск — мост тих ' + [int]$QuietSec + 'с (failsafe).')
    return [pscustomobject]$result
  }
  if ($AgeSec -ge $MaxDeferSec) {
    & $apply 'max_defer' '♻ Отложенный перезапуск применён по таймауту (макс. отсрочка).'
    return [pscustomobject]$result
  }

  return [pscustomobject]$result
}
