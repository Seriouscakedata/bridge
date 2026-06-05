function Initialize-DriverStartup {
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
      Update-State {
        param($s)
        $s.doctor_active = $false
        $s.doctor_attempts = 0
        $s | Add-Member -NotePropertyName doctor_repair_attempts -NotePropertyValue 0 -Force
        $s | Add-Member -NotePropertyName doctor_restart_count -NotePropertyValue 0 -Force
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
      Add-Message -From system -Text ("⚠ Доктор отменён: restart-loop ($newRestartCount рестартов мостa при reason='" + $reason + "'). Приостановленная задача: «" + $snip + "» — оператор, проверь рабочее дерево (git status / git stash list) и при необходимости перепиши задачу.") -Kind event | Out-Null
    }
  }
} catch {}
}
