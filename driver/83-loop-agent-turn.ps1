$script:DriverLoopAgentTurnBlock = {
  if (-not (Get-Command Test-BridgeAutoCommitWorthPath -ErrorAction SilentlyContinue)) {
    . (Join-Path $bridgeRoot 'lib\auto-commit-worthiness.ps1')
  }
  . (Join-Path $bridgeRoot 'lib\task-action-evidence.ps1')
  if (-not (Get-Command Get-TaskActionEvidence -ErrorAction SilentlyContinue)) {
    throw 'Missing task-action-evidence helper: Get-TaskActionEvidence'
  }
  if (-not (Get-Command Get-CodexEvidenceRetryPlan -ErrorAction SilentlyContinue)) {
    throw 'Missing task-action-evidence helper: Get-CodexEvidenceRetryPlan'
  }
  if (-not (Get-Command Get-TaskActionEvidenceContext -ErrorAction SilentlyContinue)) {
    throw 'Missing task-action-evidence helper: Get-TaskActionEvidenceContext'
  }

  function Get-DriverAutoCommitTaskMarker {
    $taskId = ''
    try {
      $stMarker = Read-State
      $taskId = [string]$stMarker.current_task_id
      if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = [string]$stMarker.current_backlog_id }
      if ([string]::IsNullOrWhiteSpace($taskId) -and $stMarker.task_start_seq) { $taskId = 'task-' + [string]$stMarker.task_start_seq }
    } catch { $taskId = '' }
    if ([string]::IsNullOrWhiteSpace($taskId)) { return '' }
    return ('[task:' + $taskId.Trim() + '] ')
  }

  function Normalize-TurnResultContract {
    param([AllowNull()][object]$Result)
    if ($null -eq $Result) { $Result = [pscustomobject]@{} }
    $defaults = [ordered]@{
      status           = 'ok'
      text             = ''
      duration         = 0
      errorType        = ''
      fallback         = ''
      preflightBlocked = $false
      reason           = ''
    }
    $names = @($Result.PSObject.Properties.Name)
    foreach ($name in $defaults.Keys) {
      if ($names -notcontains $name) {
        $Result | Add-Member -NotePropertyName $name -NotePropertyValue $defaults[$name] -Force
        $names += $name
      }
    }
    return $Result
  }

  if (-not (Get-Variable -Name turnResult -Scope 0 -ErrorAction SilentlyContinue)) {
    $turnResult = $null
  }

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
    $wpMode = ''; try { $wpMode = [string](Read-State).workpack_batch_mode } catch {}
    $projRootDet = ''; try { if (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) { $projRootDet = [string](Get-EffectiveProjectRoot) } } catch {}
    if ($wpActive -and ([string]$wpMode -ne 'serial') -and -not $wpDispatched -and $projRootDet -and ($projRootDet -ne $bridgeRoot)) {
      $detStreams = $null; try { $detStreams = Test-CanParallelize -PlanText $task } catch {}
      if ($detStreams -and @($detStreams).Count -ge 2) {
        try {
          $detTimeoutMin = 25
          try {
            $stDetTimeout = Read-State
            $stateParallelTimeoutMin = 0
            $statePerTaskTimeoutSec = 0
            try { $stateParallelTimeoutMin = [int](Get-BacklogPackObjectValue -Obj $stDetTimeout -Name 'workpack_batch_parallel_timeout_min' -Default 0) } catch {}
            try { $statePerTaskTimeoutSec = [int](Get-BacklogPackObjectValue -Obj $stDetTimeout -Name 'workpack_batch_per_task_timeout_sec' -Default 0) } catch {}
            if ($stateParallelTimeoutMin -gt 0) {
              $detTimeoutMin = $stateParallelTimeoutMin
            } elseif ($statePerTaskTimeoutSec -gt 0) {
              $detTimeoutMin = [int][Math]::Ceiling($statePerTaskTimeoutSec / 60.0)
            }
          } catch {}
          if ($detTimeoutMin -lt 1) { $detTimeoutMin = 25 }
          Add-Message -From system -Text ("🔀 Детерминированный parallel dispatch: " + @($detStreams).Count + " потоков из workpack-batch (timeout=" + $detTimeoutMin + " min, без планировщика)") -Kind event | Out-Null
          $detRes = Invoke-ParallelDispatch -Streams $detStreams -TimeoutMin $detTimeoutMin -PollSec 10
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
  if ($speaker -eq 'claude') {
    try {
      $stBatchTimeoutHint = Read-State
      $wpBatchActiveForHint = $false
      try { $wpBatchActiveForHint = [bool](Get-BacklogPackObjectValue -Obj $stBatchTimeoutHint -Name 'workpack_batch_active' -Default $false) } catch {}
      if ($wpBatchActiveForHint) {
        $perTaskTimeoutSec = 0
        $taskCount = 0
        try { $perTaskTimeoutSec = [int](Get-BacklogPackObjectValue -Obj $stBatchTimeoutHint -Name 'workpack_batch_per_task_timeout_sec' -Default 0) } catch {}
        try {
          if ($stBatchTimeoutHint.PSObject.Properties.Name -contains 'workpack_batch_ids') {
            $taskCount = @($stBatchTimeoutHint.workpack_batch_ids).Count
          }
        } catch {}
        if ($taskCount -le 1) {
          try {
            $hintStreams = Test-CanParallelize -PlanText $task
            $taskCount = @($hintStreams).Count
          } catch {}
        }
        $batchTimeoutHint = ""
        if ($perTaskTimeoutSec -gt 0 -and $taskCount -gt 1) {
          $batchTimeoutHint = @"

BATCH-TIMEOUT-HINT: Этот batch содержит $taskCount независимых задач.
- Автоматически разбей на $taskCount отдельных [[PARALLEL:N]] блоков (один блок = одна задача).
- В каждом блоке укажи: timeout_sec=$perTaskTimeoutSec
- Если воркер превысит таймаут — драйвер выполнит retry (до 3 раз).
- НЕ пытайся выполнить все задачи в одном Codex-вызове.
"@
        }
        if (-not [string]::IsNullOrWhiteSpace($batchTimeoutHint)) {
          $prompt = [string]$prompt + $batchTimeoutHint
        }
      }
    } catch {}
  }
  try {
    if ($turnResult) { }  # already produced by the deterministic dispatch above -> skip planner
    elseif ($speaker -eq 'claude' -and $mode -eq 'synthesis') {
      $synthState = Read-State
      $synthDepth = ''
      $synthDecisionId = ''
      try { $synthDepth = [string]$synthState.synthesis_depth } catch {}
      try { $synthDecisionId = [string]$synthState.synthesis_decision_id } catch {}
      if ([string]::IsNullOrWhiteSpace($synthDepth)) {
        try {
          $sd = Get-SynthesisDepthDecision -Text $task
          if ($sd -is [hashtable]) { $synthDepth = [string]$sd['depth'] } else { $synthDepth = [string]$sd.depth }
        } catch {}
      }
      Add-Message -From system -Text ("🧠 Decision Synthesis: запускаю pipeline depth=" + $(if([string]::IsNullOrWhiteSpace($synthDepth)){'smart'}else{$synthDepth}) + $(if([string]::IsNullOrWhiteSpace($synthDecisionId)){''}else{" id=$synthDecisionId"})) -Kind event | Out-Null
      $turnResult = Normalize-TurnResultContract (Invoke-SynthesisDriverTurn -Task $task -Channel $Channel -Depth $synthDepth -DecisionId $synthDecisionId)
    }
    elseif ($speaker -eq 'claude') { $turnResult = Normalize-TurnResultContract (Invoke-Planner -Prompt $prompt -Model $plannerModel -Mode $mode) }
    else {
      $turnResult = Normalize-TurnResultContract (Invoke-Coder -Prompt $prompt -Mode $mode)
      # Track that the coder role actually ran for this task. A Claude fallback counts as
      # the coder for this turn because it has write tools and is not merely advisory.
      if ($turnResult.status -eq 'ok') { Update-State { param($s) $s.coder_fired = $true } | Out-Null }
    }
  } catch {
    Write-TurnLog -Speaker $speaker -Model $activeModel -Mode $mode -StartedAtUtc $turnStart -Reply $_.Exception.Message -Status 'error' -FastLane:$fastLaneTurn
    throw
  }
  $turnResult = Normalize-TurnResultContract $turnResult
  $reply = [string]$turnResult.text
  $replySafetyGatePattern = '(?m)^\s*\[\[SAFETY:\s*(.+?)\s*\]\]\s*$'
  $replySafetyGateMatch = [regex]::Match([string]$reply, $replySafetyGatePattern)
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
      # private-community scaffold turn). The genuine escape signal is UNCOMMITTED bridge working-tree
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
      Update-State {
        param($s)
        $curSec = 0
        try { $curSec = [int]$s.task_agent_duration_sec } catch {}
        $s | Add-Member -NotePropertyName task_agent_duration_sec -NotePropertyValue ($curSec + $turnSec) -Force
      } | Out-Null
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
        $acDirty = @(& git -C $bridgeRoot status --porcelain -uall 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if (@($acDirty).Count -gt 0) {
          $acFiles = @($acDirty | ForEach-Object { Normalize-AutoCommitStatusPath -StatusLine ([string]$_) } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
          $commitWorthyFiles = @($acFiles | Where-Object { Test-BridgeAutoCommitWorthPath -Path ([string]$_) })
          if ($acFiles.Count -gt 0 -and $commitWorthyFiles.Count -gt 0) {
            $acMsg = (Get-DriverAutoCommitTaskMarker) + 'auto-commit (driver; coder sandbox cannot reach .git): ' + (($task -replace '\s+',' ').Trim())
            if ($acMsg.Length -gt 180) { $acMsg = $acMsg.Substring(0,180) }
            $acAdd = Invoke-GitAddPaths -RepoRoot $bridgeRoot -Paths @($commitWorthyFiles)
            if ($acAdd.ExitCode -ne 0) {
              Add-Message -From system -Text ("⚠ Driver auto-commit: git add failed (bridgeRoot): " + (($acAdd.Output -join ' ') -replace '\s+', ' ').Trim()) -Kind event | Out-Null
            } else {
              $acCommit = Invoke-GitCommitMessage -RepoRoot $bridgeRoot -Message $acMsg
              if ($acCommit.ExitCode -ne 0) {
                Add-Message -From system -Text ("⚠ Driver auto-commit: git commit failed (bridgeRoot): " + (($acCommit.Output -join ' ') -replace '\s+', ' ').Trim()) -Kind event | Out-Null
              }
            }
            $acNewHead = (& git -C $bridgeRoot rev-parse HEAD 2>$null).Trim()
            if ($acNewHead -and $acNewHead -ne $headBeforeTurn) {
              try {
                $stPostCommitQa = Read-State
                $postCommitQaTaskId = [string]$stPostCommitQa.current_task_id
                if ([string]::IsNullOrWhiteSpace($postCommitQaTaskId)) { $postCommitQaTaskId = [string]$stPostCommitQa.current_backlog_id }
                if ([string]::IsNullOrWhiteSpace($postCommitQaTaskId)) { $postCommitQaTaskId = 'task-' + [string]$stPostCommitQa.task_start_seq }
                $postCommitQa = Invoke-QAAgentPostCommit -BridgeRoot $bridgeRoot -CommitSha $acNewHead -TaskId $postCommitQaTaskId -TaskTitle $task -Channel $Channel
                if ($postCommitQa.Verdict -eq 'FAIL') {
                  try { Set-TaskLastFailure -Kind qa_failed -Text ([string]$postCommitQa.Summary) } catch {}
                  Add-Message -From system -Text ("🔴 QA Runner post-commit: FAIL после commit " + $acNewHead.Substring(0,7) + "`n" + [string]$postCommitQa.Summary + "`nЗадача НЕ может перейти в done; возвращаю Codex на доработку.") -Kind event | Out-Null
                  Update-State { param($s) $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $true -Force; $s.task_did_actions=$true; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
                  continue mainDriverLoop
                } else {
                  try { Clear-TaskLastFailureKind -Kind qa_failed } catch {}
                  Add-Message -From system -Text ("✅ QA Runner post-commit: PASS — " + [string]$postCommitQa.Summary) -Kind event | Out-Null
                  # post-commit PASS populates qa_verdict_cache so done-gate skips re-run on same HEAD
                  try {
                    Update-State { param($s)
                      $s | Add-Member -NotePropertyName qa_verdict_cache -NotePropertyValue ([pscustomobject]@{
                        head    = [string]$acNewHead
                        verdict = 'PASS'
                        source  = 'post_commit'
                        ts      = (Get-Date).ToUniversalTime().ToString('o')
                      }) -Force
                    } | Out-Null
                  } catch {}
                }
              } catch {
                $qaErr = ($_.Exception.Message -replace '\s+', ' ').Trim()
                try { Set-TaskLastFailure -Kind qa_failed -Text ('QA Runner post-commit error: ' + $qaErr) } catch {}
                Add-Message -From system -Text ("🔴 QA Runner post-commit: ERROR после commit " + $acNewHead.Substring(0,7) + "`n" + $qaErr + "`nЗадача НЕ может перейти в done; возвращаю Codex на доработку.") -Kind event | Out-Null
                Update-State { param($s) $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $true -Force; $s.task_did_actions=$true; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
                continue mainDriverLoop
              }
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
      $pDirty = @(& git -C $projRoot status --porcelain -uall 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
      if (@($pDirty).Count -gt 0) {
        $pMsg = (Get-DriverAutoCommitTaskMarker) + 'auto-commit (driver): ' + (($task -replace '\s+', ' ').Trim())
        if ($pMsg.Length -gt 160) { $pMsg = $pMsg.Substring(0, 160) }
        $pAdd = Invoke-GitNative -RepoRoot $projRoot -GitArgs @('add', '-A')
        if ($pAdd.ExitCode -ne 0) {
          Add-Message -From system -Text ("⚠ Driver auto-commit: git add failed (projectRoot): " + (($pAdd.Output -join ' ') -replace '\s+', ' ').Trim()) -Kind event | Out-Null
        } else {
          $pCommit = Invoke-GitCommitMessage -RepoRoot $projRoot -Message $pMsg
          if ($pCommit.ExitCode -ne 0) {
            Add-Message -From system -Text ("⚠ Driver auto-commit: git commit failed (projectRoot): " + (($pCommit.Output -join ' ') -replace '\s+', ' ').Trim()) -Kind event | Out-Null
          }
        }
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

  # Record deterministic action evidence after the coder turn. This keeps the later
  # planner DONE gate tied to actual commit/diff evidence, not to "Codex replied OK".
  if (($speaker -eq 'codex' -or [string]$turnResult.fallback -eq 'claude_as_coder') -and ([string]$turnResult.status -eq 'ok') -and $mode -eq 'normal') {
    try {
      $stAction = Read-State
      $repoActionRoot = Get-TaskRepoRoot
      $actionEvidenceContext = Get-TaskActionEvidenceContext -State $stAction -DefaultRepoRoot $repoActionRoot -BridgeRoot $bridgeRoot
      $actionEvidence = Get-TaskActionEvidence -RepoRoot ([string]$actionEvidenceContext.repo_root) -BaseCommit ([string]$actionEvidenceContext.base_commit) -BridgeRoot $bridgeRoot -BaseDirtyPaths @($actionEvidenceContext.base_dirty_paths)
      if ($actionEvidence -and [bool]$actionEvidence.has_actions) {
        Update-State { param($s) $s.task_did_actions = $true; $s | Add-Member -NotePropertyName codex_evidence_retry_count -NotePropertyValue 0 -Force } | Out-Null
      } elseif (Test-TaskCoveredVerifiedDoneEvidence -Reply $reply) {
        Update-State { param($s) $s.task_did_actions = $true; $s.no_progress_count = 0; $s | Add-Member -NotePropertyName codex_evidence_retry_count -NotePropertyValue 0 -Force } | Out-Null
      } else {
        $retryBacklogId = ''
        try { $retryBacklogId = [string]$stAction.current_backlog_id } catch {}
        $replyHasSafetyGateMarker = ($speaker -eq 'codex' -and $replySafetyGateMatch.Success)
        # 2026-06-24 wedge-fix #1 (defense-in-depth backstop to the claim-gate path-block): coder-scope
        # HARD-FAIL. When the coder produced NO evidence specifically because it could not write the atom's
        # target repo (target files outside this channel's sandbox), retrying is futile — the scope mismatch
        # is structural, not transient. Route the atom to HELD (attempts++) with an operator-visible reason
        # instead of force_planner -> infinite re-claim (the 3h wedge of 2026-06-24). Narrow refusal
        # signature; planner/discuss turns never reach this block (gated codex + normal at line 370).
        $scopeRefusalSignature = '(?i)(writing outside of the project|outside of the project|active scope allows only|apply_patch (?:was )?rejected|Unable to create [^\r\n]*index\.lock[^\r\n]*Permission denied|index\.lock[^\r\n]*Permission denied)'
        if (-not [string]::IsNullOrWhiteSpace($retryBacklogId) -and -not $replyHasSafetyGateMarker -and ([string]$reply -match $scopeRefusalSignature)) {
          $scopeRepoLabel = if ([string]::IsNullOrWhiteSpace([string]$actionEvidenceContext.repo_root)) { '<unknown>' } else { [string]$actionEvidenceContext.repo_root }
          $scopeReason = "coder-scope-mismatch: atom target lies outside this channel's sandbox (repo=$scopeRepoLabel). Coder could not write/commit (scope/permission refusal). Re-file on the owning project channel or set scope to that project; will not auto-retry."
          try { Set-TaskLastFailure -Kind coder_scope_mismatch -Text $scopeReason } catch {}
          try { Set-Idea -Id $retryBacklogId -Status 'held' -IncrementAttempts $true -Reason ('operator: ' + $scopeReason) | Out-Null } catch {}
          Add-Message -From system -Text ("🛑 Coder-scope-mismatch: атом " + $retryBacklogId + " не может писать target-репозиторий из песочницы этого канала (repo=" + $scopeRepoLabel + "). Перевожу в HELD (attempts++), НЕ повторяю — переадресуй на канал владельца проекта.") -Kind event | Out-Null
          Update-State {
            param($s)
            try { Complete-TaskAgentDuration $s } catch {}
            try { Close-ReplayForStateTask -State $s -Status 'aborted' } catch {}
            $s | Add-Member -NotePropertyName codex_evidence_retry_count -NotePropertyValue 0 -Force
            $s.task_did_actions = $false
            $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $false -Force
            $s.force_planner = $false
            $s.current_task = $null
            $s | Add-Member -NotePropertyName current_task_id -NotePropertyValue $null -Force
            $s | Add-Member -NotePropertyName current_backlog_id -NotePropertyValue '' -Force
            $s | Add-Member -NotePropertyName workpack_batch_ids -NotePropertyValue @() -Force
            $s | Add-Member -NotePropertyName workpack_batch_active -NotePropertyValue $false -Force
            $s | Add-Member -NotePropertyName workpack_batch_dispatched -NotePropertyValue $false -Force
            $s.active_jobs=@(); $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.status='idle'; $s.heartbeat=(Get-Date).ToString('o')
          } | Out-Null
          # Safe: driver/90-main-loop.ps1 dot-sources this block under :mainDriverLoop.
          continue mainDriverLoop
        }
        if (-not [string]::IsNullOrWhiteSpace($retryBacklogId) -and -not $replyHasSafetyGateMarker) {
          $curEvidenceRetries = 0
          try {
            if ($stAction.PSObject.Properties.Name -contains 'codex_evidence_retry_count') {
              $curEvidenceRetries = [int]$stAction.codex_evidence_retry_count
            }
          } catch { $curEvidenceRetries = 0 }
          $retryPlan = Get-CodexEvidenceRetryPlan -CurrentRetryCount $curEvidenceRetries -MaxAttempts 3 -BaseDelaySec 5 -MaxDelaySec 20
          $repoLabel = if ([string]::IsNullOrWhiteSpace([string]$actionEvidenceContext.repo_root)) { '<unknown>' } else { [string]$actionEvidenceContext.repo_root }
          if ([bool]$retryPlan.should_retry) {
            $delaySec = [int]$retryPlan.delay_sec
            $retryAttempt = [int]$retryPlan.attempt
            $retryMaxAttempts = [int]$retryPlan.max_attempts
            try { Set-TaskLastFailure -Kind no_action_evidence -Text ("Codex produced no commit/diff evidence on attempt " + $retryAttempt + "/" + $retryMaxAttempts) } catch {}
            Add-Message -From system -Text ("🔁 Codex не оставил commit/diff evidence для backlog-задачи (attempt " + $retryAttempt + "/" + $retryMaxAttempts + ", repo=" + $repoLabel + "). Повторяю Codex после " + $delaySec + "с.") -Kind event | Out-Null
            Update-State {
              param($s)
              $s | Add-Member -NotePropertyName codex_evidence_retry_count -NotePropertyValue $retryAttempt -Force
              $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $true -Force
              $s.force_planner = $false
              $s.task_did_actions = $false
              $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o')
            } | Out-Null
            if ($delaySec -gt 0) { Start-Sleep -Seconds $delaySec }
            # Safe: driver/90-main-loop.ps1 dot-sources this block under :mainDriverLoop.
            continue mainDriverLoop
          } else {
            try { Set-TaskLastFailure -Kind no_action_evidence -Text ("Codex produced no commit/diff evidence after " + [int]$retryPlan.max_attempts + " attempts") } catch {}
            Add-Message -From system -Text ("🚫 Codex не оставил commit/diff evidence за " + [int]$retryPlan.max_attempts + " попытки. Не засчитываю действие; передаю планировщику для диагностики/переформулировки.") -Kind event | Out-Null
            Update-State {
              param($s)
              $s | Add-Member -NotePropertyName codex_evidence_retry_count -NotePropertyValue 0 -Force
              $s.task_did_actions = $false
              $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $false -Force
              $s.force_planner=$true
              $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o')
            } | Out-Null
            # Safe: driver/90-main-loop.ps1 dot-sources this block under :mainDriverLoop.
            continue mainDriverLoop
          }
        }
      }
    } catch {
      $actionEvidenceError = $_.Exception.Message
      try { Set-TaskLastFailure -Kind action_evidence_error -Text ("Codex action evidence guard failed: " + $actionEvidenceError) } catch {}
      Add-Message -From system -Text ("🚫 Codex action evidence guard failed: " + $actionEvidenceError + ". Не засчитываю действие; передаю планировщику.") -Kind event | Out-Null
      Update-State {
        param($s)
        $s.task_did_actions = $false
        $s.force_planner = $true
        $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $false -Force
        $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o')
      } | Out-Null
      # Safe: driver/90-main-loop.ps1 dot-sources this block under :mainDriverLoop.
      continue mainDriverLoop
    }
  }

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

  if ($turnResult.status -eq 'auth_error') {
    $authKind = [string]$turnResult.errorType
    if ([string]::IsNullOrWhiteSpace($authKind)) { $authKind = 'agent_auth_error' }
    $authReason = [string]$turnResult.reason
    if ([string]::IsNullOrWhiteSpace($authReason)) { $authReason = [string]$reply }
    if ([string]::IsNullOrWhiteSpace($authReason)) { $authReason = $authKind }
    try { Set-TaskLastFailure -Kind $authKind -Text $authReason } catch {}
    Add-Message -From system -Text ("🛑 Auth failure у агента (" + $authKind + "): " + $authReason + ". Это требует ручной переавторизации; ставлю канал на паузу вместо retry/Doctor loop.") -Kind event | Out-Null
    if ([bool](Read-State).doctor_active) {
      try { Abort-Doctor -Reason ("operator auth required: " + $authKind) } catch {}
    }
    Update-State {
      param($s)
      $s.paused = $true
      $s.force_planner = $false
      $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $false -Force
      $s.active_agent=$null; $s.active_model=$null; $s.status_text='Paused: agent authentication failed; operator reauth required.'; $s.agent_pid=$null; $s.status='paused'; $s.heartbeat=(Get-Date).ToString('o')
    } | Out-Null
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
      # 🩺 If Doctor itself timed out, retry the Doctor task only while its repair budget remains.
      if ([bool](Read-State).doctor_active) {
        $docState = Read-State
        $docAttempt = Get-DoctorRepairAttemptCount -State $docState
        $docMax = Get-DoctorMaxRepairAttempts
        if ($docAttempt -lt $docMax) {
          Add-Message -From system -Text ("⏱ Доктор сам упёрся в таймаут (${dur}с, repair-попытка " + $docAttempt + "/" + $docMax + "). Готовлю следующую repair-попытку.") -Kind event | Out-Null
          try { Set-TaskLastFailure -Kind doctor_timeout -Text ("doctor timeout ${dur}s on repair attempt " + $docAttempt + "/" + $docMax) } catch {}
          Update-State {
            param($s)
            $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0
            $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.critic_retry_count=0
            $s.force_planner=$false; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null
            $s.status='idle'; $s.heartbeat=(Get-Date).ToString('o')
          } | Out-Null
        } else {
          Add-Message -From system -Text ("⏱ Доктор сам упёрся в таймаут (${dur}с, repair-попытка " + $docAttempt + "/" + $docMax + "). Лимит исчерпан, эскалирую оператору.") -Kind event | Out-Null
          try { Abort-Doctor -Reason ("doctor timeout (${dur}с, repair attempt " + $docAttempt + "/" + $docMax + ")") } catch {}
          Update-State { param($s) $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.status='idle'; $s.heartbeat=(Get-Date).ToString('o') } | Out-Null
        }
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
    if ($replySafetyGateMatch.Success) {
      $safetyDesc = $replySafetyGateMatch.Groups[1].Value.Trim()
      $preReply = [regex]::Replace([string]$reply, $replySafetyGatePattern, '').Trim()
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
  if (($speaker -eq 'codex' -or [string]$turnResult.fallback -eq 'claude_as_coder') -and
      ([string]$turnResult.status -eq 'ok') -and
      [string]::IsNullOrWhiteSpace($reply) -and
      $mode -eq 'normal') {
    try {
      $stEmptyCoder = Read-State
      $emptyCoderBacklogId = [string]$stEmptyCoder.current_backlog_id
      if (-not [string]::IsNullOrWhiteSpace($emptyCoderBacklogId) -and [bool]$stEmptyCoder.task_did_actions) {
        $emptyCoderMaxAttempts = 2
        $emptyCoderAttempt = 0
        try { $emptyCoderAttempt = [int]$stEmptyCoder.completion_coder_empty_attempts } catch { $emptyCoderAttempt = 0 }
        $emptyCoderAttempt++
        if ($emptyCoderAttempt -lt $emptyCoderMaxAttempts) {
          Add-Message -From system -Text ("🔁 Codex вернул пустой ответ после action evidence (empty " + $emptyCoderAttempt + "/" + $emptyCoderMaxAttempts + ") — повторяю только coder close-turn.") -Kind event | Out-Null
          Update-State ({
            param($s)
            $s | Add-Member -NotePropertyName completion_coder_empty_attempts -NotePropertyValue $emptyCoderAttempt -Force
            $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $true -Force
            $s.force_planner = $false
            $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.agent_pid=$null; $s.heartbeat=(Get-Date).ToString('o')
          }.GetNewClosure()) | Out-Null
          continue mainDriverLoop
        }
        Update-State ({
          param($s)
          $s | Add-Member -NotePropertyName completion_coder_empty_attempts -NotePropertyValue $emptyCoderAttempt -Force
          $s | Add-Member -NotePropertyName completion_coder_result -NotePropertyValue 'skipped-empty' -Force
          $s | Add-Member -NotePropertyName force_coder -NotePropertyValue $false -Force
        }.GetNewClosure()) | Out-Null
        Add-Message -From system -Text ("⚠ Codex close-turn пустой " + $emptyCoderMaxAttempts + " раза подряд после action evidence — фиксирую coder_result=skipped-empty; close продолжит deterministic gates.") -Kind event | Out-Null
      }
    } catch {}
  }
  if (($speaker -eq 'codex' -or [string]$turnResult.fallback -eq 'claude_as_coder') -and
      ([string]$turnResult.status -eq 'ok') -and
      -not [string]::IsNullOrWhiteSpace($reply) -and
      $mode -eq 'normal') {
    try {
      Update-State { param($s)
        $s | Add-Member -NotePropertyName completion_coder_empty_attempts -NotePropertyValue 0 -Force
        $s | Add-Member -NotePropertyName completion_coder_result -NotePropertyValue '' -Force
      } | Out-Null
    } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($reply)) { $reply = "(нет ответа от $speaker)" }
}
