$script:DriverLoopModeTransitionBlock = {
  . (Join-Path $bridgeRoot 'lib\task-action-evidence.ps1')
  if (-not (Get-Command Get-TaskActionEvidence -ErrorAction SilentlyContinue)) {
    throw 'Missing task-action-evidence helper: Get-TaskActionEvidence'
  }
  if (-not (Get-Command Get-TaskActionEvidenceContext -ErrorAction SilentlyContinue)) {
    throw 'Missing task-action-evidence helper: Get-TaskActionEvidenceContext'
  }
  if (-not (Get-Command Test-BridgeAutoCommitWorthPath -ErrorAction SilentlyContinue)) {
    . (Join-Path $bridgeRoot 'lib\auto-commit-worthiness.ps1')
  }
  if ((($speaker -eq 'claude') -or $fastLaneDone) -and $plannerStatus -eq 'DONE' -and $modeBeforeIncrement -eq 'normal') {
    $noopHasBacklogId = $true
    $noopTask = ''
    $noopHasEvidence = $false
    $noopEvidenceChecked = $false
    $noopGuardError = ''
    try {
      $stNoop = Read-State
      $noopBacklogId = [string]$stNoop.current_backlog_id
      $noopHasBacklogId = -not [string]::IsNullOrWhiteSpace($noopBacklogId)
      $noopTask = [string]$stNoop.current_task
      $repoNoopRoot = Get-TaskRepoRoot
      $noopEvidenceContext = Get-TaskActionEvidenceContext -State $stNoop -DefaultRepoRoot $repoNoopRoot -BridgeRoot $bridgeRoot
      $noopEvidence = Get-TaskActionEvidence -RepoRoot ([string]$noopEvidenceContext.repo_root) -BaseCommit ([string]$noopEvidenceContext.base_commit) -BridgeRoot $bridgeRoot -BaseDirtyPaths @($noopEvidenceContext.base_dirty_paths)
      $noopEvidenceChecked = $true
      if ($noopEvidence -and [bool]$noopEvidence.has_actions) {
        $noopHasEvidence = $true
        Update-State {
          param($s)
          $s.task_did_actions = $true
          $s | Add-Member -NotePropertyName codex_evidence_retry_count -NotePropertyValue 0 -Force
        } | Out-Null
      }
    } catch {
      $noopGuardError = $_.Exception.Message
      $noopHasEvidence = $false
      $noopEvidenceChecked = $false
    }
    try {
      $noopProjectAutopilot = [bool]([regex]::IsMatch($noopTask, '(?im)^\s*\[project-autopilot\b'))
      $noopAllowDone = $false
      $noopRejectReason = 'missing_action_evidence'
      if (-not $noopHasBacklogId) {
        $noopAllowDone = $true
        $noopRejectReason = 'not_backlog_task'
      } elseif ($noopProjectAutopilot) {
        $noopAllowDone = $true
        $noopRejectReason = 'project_autopilot'
      } elseif ([int]$projectBacklogCreated -gt 0) {
        $noopAllowDone = $true
        $noopRejectReason = 'project_backlog_created'
      } elseif (-not $noopEvidenceChecked) {
        $noopRejectReason = 'evidence_check_failed'
      } elseif ($noopHasEvidence) {
        $noopAllowDone = $true
        $noopRejectReason = 'action_evidence'
      }

      if (-not $noopAllowDone) {
        $plannerStatus = 'CONTINUE'
        $noopBaseRejectReason = $noopRejectReason
        if (-not [string]::IsNullOrWhiteSpace($noopGuardError)) { $noopRejectReason = $noopRejectReason + ': ' + $noopGuardError }
        $noopFailureText = 'DONE rejected by action evidence guard: ' + $noopRejectReason
        $noopForceCoderRecovery = ($noopBaseRejectReason -eq 'missing_action_evidence')
        $noopRecoveryMessage = "Codex: создай реальный commit/diff evidence для текущей backlog-задачи, затем проверки и DONE."
        $noopFailureRecord = [pscustomobject]@{
          kind = 'test_failed'
          reason = $noopBaseRejectReason
          text = $noopFailureText
          ts = (Get-Date).ToString('o')
        }
        Update-State ({
          param($s)
          $s.task_did_actions = $false
          $s | Add-Member -NotePropertyName codex_evidence_retry_count -NotePropertyValue 0 -Force
          $s | Add-Member -NotePropertyName task_failure_record -NotePropertyValue $noopFailureRecord -Force
          if ($noopForceCoderRecovery) {
            $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $true -Force
            $s.force_planner = $false
          }
        }.GetNewClosure()) | Out-Null
        try { Set-TaskLastFailure -Kind test_failed -Text $noopFailureText } catch {}
        if ($noopForceCoderRecovery) {
          Add-Message -From system -Text ("🚫 DONE отклонён: backlog-задача не имеет свежего commit/diff evidence перед переключением режима (reason=" + $noopRejectReason + "). " + $noopRecoveryMessage + " Нельзя планировщику снова закрывать задачу без commit/diff evidence.") -Kind event | Out-Null
        } else {
          Add-Message -From system -Text ("🚫 DONE отклонён: backlog-задача не имеет свежего commit/diff evidence перед переключением режима (reason=" + $noopRejectReason + "). Нельзя закрывать реализационную задачу планом. Продолжай: реализуй изменения, запусти проверки и только потом STATUS: DONE.") -Kind event | Out-Null
        }
      }
    } catch {
      $plannerStatus = 'CONTINUE'
      $noopDecisionError = $_.Exception.Message
      Update-State {
        param($s)
        $s.task_did_actions = $false
        $s | Add-Member -NotePropertyName codex_evidence_retry_count -NotePropertyValue 0 -Force
      } | Out-Null
      try { Set-TaskLastFailure -Kind test_failed -Text ('DONE evidence guard crashed: ' + $noopDecisionError) } catch {}
      Add-Message -From system -Text ("🚫 DONE evidence guard failed closed: " + $noopDecisionError + ". Продолжай: реализуй изменения, запусти проверки и только потом STATUS: DONE.") -Kind event | Out-Null
    }
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
    $hasChanges = -not [string]::IsNullOrWhiteSpace($gitDiffOut) -or $attachmentMetas.Count -gt 0
    $hasActionEvidence = ($attachmentMetas.Count -gt 0)
    try {
      $stEvidence = Read-State
      $repoEvidenceRoot = Get-TaskRepoRoot
      $evidenceContext = Get-TaskActionEvidenceContext -State $stEvidence -DefaultRepoRoot $repoEvidenceRoot -BridgeRoot $bridgeRoot
      $actionEvidence = Get-TaskActionEvidence -RepoRoot ([string]$evidenceContext.repo_root) -BaseCommit ([string]$evidenceContext.base_commit) -BridgeRoot $bridgeRoot -BaseDirtyPaths @($evidenceContext.base_dirty_paths)
      if ($actionEvidence -and [bool]$actionEvidence.has_actions) { $hasActionEvidence = $true }
    } catch {}
    if ($mode -eq 'normal' -and $hasActionEvidence) { Update-State { param($s) $s.task_did_actions=$true } | Out-Null }
    $npc = [int](Read-State).no_progress_count
    if ($hasChanges) {
      Update-State { param($s) $s.no_progress_count=0 } | Out-Null
    } else {
      $newNpc = $npc + 1
      $mutNpc = { param($s) $s.no_progress_count = $newNpc }.GetNewClosure()
      Update-State $mutNpc | Out-Null
      if ($newNpc -ge 4) {
        Add-Message -From system -Text "⚠ Нет изменений файлов $newNpc ходов подряд. Codex — объясни, что блокирует выполнение, или предложи иной подход." -Kind event | Out-Null
        try {
          Activate-Doctor -Reason 'no_progress_loop' -Detail ("no_progress_count=" + [string]$newNpc) | Out-Null
        } catch {
          Add-Message -From system -Text ("⚠ Activate-Doctor failed in no-progress detector: " + $_.Exception.Message) -Kind event | Out-Null
        }
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
}
