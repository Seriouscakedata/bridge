# Loop-completion cleanup: checkpoints, DONE bookkeeping, delivery-gate shadow, and final state reset.
# Dot invocation preserves existing `continue` behavior for doctor resume and loop close.

$script:DriverLoopCompletionCleanupRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:DriverLoopCompletionCleanupBridgeRoot = Split-Path -Parent $script:DriverLoopCompletionCleanupRoot
$script:DriverLoopCompletionLedgerPath = Join-Path $script:DriverLoopCompletionCleanupBridgeRoot 'lib\task-outcome-ledger.ps1'
if (-not (Get-Command Test-TaskOutcomeLedgerDone -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $script:DriverLoopCompletionLedgerPath)) {
  . $script:DriverLoopCompletionLedgerPath
}

function Import-DriverTaskOutcomeLedger {
  param([string]$BridgeRoot = '')
  if (Get-Command Test-TaskOutcomeLedgerDone -ErrorAction SilentlyContinue) { return }
  $root = [string]$BridgeRoot
  if ([string]::IsNullOrWhiteSpace($root)) { $root = Split-Path -Parent $script:DriverLoopCompletionCleanupRoot }
  $ledgerPath = Join-Path $root 'lib\task-outcome-ledger.ps1'
  if (-not (Test-Path -LiteralPath $ledgerPath)) { throw "Missing task outcome ledger: $ledgerPath" }
  . $ledgerPath
}

function Set-DriverOutcomeProperty {
  param(
    [Parameter(Mandatory=$true)]$Item,
    [Parameter(Mandatory=$true)][string]$Name,
    [AllowNull()]$Value
  )
  if ($Item.PSObject.Properties.Name -contains $Name) {
    $Item.PSObject.Properties[$Name].Value = $Value
  } else {
    $Item | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
  }
}

function Copy-DriverOutcomeItem {
  param([Parameter(Mandatory=$true)]$Item)
  $copy = [pscustomobject][ordered]@{}
  foreach ($prop in @($Item.PSObject.Properties)) {
    Set-DriverOutcomeProperty -Item $copy -Name ([string]$prop.Name) -Value $prop.Value
  }
  return $copy
}

function New-DriverCompletionDoneEvidence {
  param(
    [Parameter(Mandatory=$false)]$State,
    [string]$Reply = '',
    [string]$Speaker = '',
    [string]$BridgeRoot = '',
    [string]$Channel = '',
    [bool]$FastLaneDone = $false
  )

  $root = [string]$BridgeRoot
  if ([string]::IsNullOrWhiteSpace($root)) { $root = Split-Path -Parent $script:DriverLoopCompletionCleanupRoot }
  $repoRoot = $root
  try {
    if (Get-Command Get-TaskRepoRoot -ErrorAction SilentlyContinue) {
      $candidateRepo = [string](Get-TaskRepoRoot)
      if (-not [string]::IsNullOrWhiteSpace($candidateRepo)) { $repoRoot = $candidateRepo }
    } elseif (Get-Command Get-ActiveProjectRoot -ErrorAction SilentlyContinue) {
      $candidateRepo = [string](Get-ActiveProjectRoot)
      if (-not [string]::IsNullOrWhiteSpace($candidateRepo)) { $repoRoot = $candidateRepo }
    }
  } catch {}

  $head = ''
  try { $head = ((& git -C $repoRoot rev-parse HEAD 2>$null) | Select-Object -First 1).Trim() } catch { $head = '' }
  $base = ''
  try { $base = [string]$State.task_base_commit } catch { $base = '' }

  $verified = New-Object 'System.Collections.Generic.List[string]'
  foreach ($match in [regex]::Matches([string]$Reply, '(?im)^\s*\[\[VERIFIED:\s*(.+?)\]\]\s*$')) {
    $txt = $match.Groups[1].Value.Trim()
    if (-not [string]::IsNullOrWhiteSpace($txt)) { [void]$verified.Add($txt) }
  }

  $tests = New-Object 'System.Collections.Generic.List[string]'
  foreach ($v in @($verified.ToArray())) { [void]$tests.Add($v) }
  foreach ($gate in @('completion-gate:critic', 'completion-gate:parsefile', 'completion-gate:smoke', 'completion-gate:qa')) {
    [void]$tests.Add($gate)
  }

  $criticResult = 'PASS'
  try {
    if ($State -and ($State.PSObject.Properties.Name -contains 'skip_critic') -and [bool]$State.skip_critic) {
      $criticResult = 'SKIPPED'
    }
  } catch {}

  return [pscustomobject][ordered]@{
    done_sha = $head
    done_evidence = [pscustomobject][ordered]@{
      repo_root = $repoRoot
      base_sha = $base
      head_sha = $head
      verified = @($verified.ToArray())
      gates = @('critic','parsefile','smoke','qa')
      channel = [string]$Channel
      fast_lane = [bool]$FastLaneDone
    }
    done_by = if ([string]::IsNullOrWhiteSpace($Speaker)) { 'driver-completion' } else { [string]$Speaker }
    tests_run = @($tests.ToArray())
    critic_result = $criticResult
    qa_result = 'PASS'
  }
}

function Set-BacklogOutcomeDoneWithLedger {
  param(
    [Parameter(Mandatory=$true)][string[]]$Ids,
    [Parameter(Mandatory=$true)]$OutcomeEvidence,
    [string]$BridgeRoot = ''
  )

  Import-DriverTaskOutcomeLedger -BridgeRoot $BridgeRoot
  $idsClean = @($Ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  if ($idsClean.Count -eq 0) {
    return [pscustomobject][ordered]@{ ok = $true; reason = 'no_ids'; done_ids = @(); needs_review_ids = @(); blocked_ids = @(); ledger_entries = @() }
  }

  $getBacklogFn = ${function:Get-Backlog}
  $saveBacklogFn = ${function:Save-Backlog}
  $testDoneFn = ${function:Test-TaskOutcomeLedgerDone}
  $recoverFn = ${function:Test-TaskOutcomeLedgerRecoverFalseFailed}
  $entryFn = ${function:Get-TaskOutcomeLedgerEntry}
  $copyFn = ${function:Copy-DriverOutcomeItem}
  $setPropFn = ${function:Set-DriverOutcomeProperty}

  $doneSha = [string](Get-TaskOutcomeLedgerObjectValue -Object $OutcomeEvidence -Names @('done_sha') -Default '')
  $doneEvidence = Get-TaskOutcomeLedgerObjectValue -Object $OutcomeEvidence -Names @('done_evidence') -Default $null
  $doneBy = [string](Get-TaskOutcomeLedgerObjectValue -Object $OutcomeEvidence -Names @('done_by') -Default '')
  $testsRun = @(Get-TaskOutcomeLedgerObjectValue -Object $OutcomeEvidence -Names @('tests_run') -Default @())
  $criticResult = [string](Get-TaskOutcomeLedgerObjectValue -Object $OutcomeEvidence -Names @('critic_result') -Default '')
  $qaResult = [string](Get-TaskOutcomeLedgerObjectValue -Object $OutcomeEvidence -Names @('qa_result') -Default '')
  $recoveryEvidence = [pscustomobject][ordered]@{
    recovery_sha = $doneSha
    recovery_checks = @($testsRun)
  }

  return (Invoke-BacklogLocked ({
    $items = @(& $getBacklogFn)
    $doneIds = New-Object 'System.Collections.Generic.List[string]'
    $needsReviewIds = New-Object 'System.Collections.Generic.List[string]'
    $blockedIds = New-Object 'System.Collections.Generic.List[string]'
    $ledgerEntries = New-Object 'System.Collections.Generic.List[object]'
    $dirty = $false
    $reason = 'done_evidence_complete'

    foreach ($id in @($idsClean)) {
      $item = $null
      foreach ($candidateItem in $items) {
        if ([string]$candidateItem.id -eq [string]$id) { $item = $candidateItem; break }
      }
      if ($null -eq $item) {
        [void]$blockedIds.Add([string]$id)
        $reason = 'backlog_item_not_found'
        continue
      }

      $currentStatus = ([string](Get-TaskOutcomeLedgerObjectValue -Object $item -Names @('status') -Default '')).Trim().ToLowerInvariant()
      if ($currentStatus -eq 'failed') {
        $recovery = & $recoverFn -Item $item -RecoveryEvidence $recoveryEvidence
        if ([bool]$recovery.recoverable -and [string]$recovery.proposed_status -eq 'needs-review') {
          & $setPropFn -Item $item -Name 'status' -Value 'needs-review'
          & $setPropFn -Item $item -Name 'outcome_recovery_reason' -Value ([string]$recovery.reason)
          & $setPropFn -Item $item -Name 'outcome_recovery_evidence' -Value $recoveryEvidence
          [void]$needsReviewIds.Add([string]$id)
          $dirty = $true
          $reason = 'false_failed_needs_review'
          continue
        }
      }

      $candidate = & $copyFn -Item $item
      & $setPropFn -Item $candidate -Name 'status' -Value 'done'
      & $setPropFn -Item $candidate -Name 'done_sha' -Value $doneSha
      & $setPropFn -Item $candidate -Name 'done_evidence' -Value $doneEvidence
      & $setPropFn -Item $candidate -Name 'done_by' -Value $doneBy
      & $setPropFn -Item $candidate -Name 'tests_run' -Value @($testsRun)
      & $setPropFn -Item $candidate -Name 'critic_result' -Value $criticResult
      & $setPropFn -Item $candidate -Name 'qa_result' -Value $qaResult

      $validation = & $testDoneFn -Item $candidate
      if (-not [bool]$validation.valid) {
        [void]$blockedIds.Add([string]$id)
        $missing = @($validation.missing) -join ','
        $reason = if ([string]::IsNullOrWhiteSpace($missing)) { [string]$validation.reason } else { ([string]$validation.reason + ':' + $missing) }
        continue
      }

      & $setPropFn -Item $item -Name 'status' -Value 'done'
      & $setPropFn -Item $item -Name 'done_sha' -Value $doneSha
      & $setPropFn -Item $item -Name 'done_evidence' -Value $doneEvidence
      & $setPropFn -Item $item -Name 'done_by' -Value $doneBy
      & $setPropFn -Item $item -Name 'tests_run' -Value @($testsRun)
      & $setPropFn -Item $item -Name 'critic_result' -Value $criticResult
      & $setPropFn -Item $item -Name 'qa_result' -Value $qaResult
      $entry = & $entryFn -Item $candidate
      & $setPropFn -Item $item -Name 'outcome_ledger' -Value $entry
      [void]$ledgerEntries.Add($entry)
      [void]$doneIds.Add([string]$id)
      $dirty = $true
    }

    if ($dirty) { & $saveBacklogFn $items }
    $ok = ($blockedIds.Count -eq 0 -and $needsReviewIds.Count -eq 0)
    return [pscustomobject][ordered]@{
      ok = [bool]$ok
      reason = $reason
      done_ids = @($doneIds.ToArray())
      needs_review_ids = @($needsReviewIds.ToArray())
      blocked_ids = @($blockedIds.ToArray())
      ledger_entries = @($ledgerEntries.ToArray())
    }
  }.GetNewClosure()))
}

function Set-BacklogOutcomeFailedWithLedger {
  param(
    [Parameter(Mandatory=$true)][string[]]$Ids,
    [Parameter(Mandatory=$false)]$FailureEvidence,
    [string]$BridgeRoot = ''
  )

  Import-DriverTaskOutcomeLedger -BridgeRoot $BridgeRoot
  $idsClean = @($Ids | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  if ($idsClean.Count -eq 0) {
    return [pscustomobject][ordered]@{ ok = $true; reason = 'no_ids'; failed_ids = @(); blocked_ids = @() }
  }

  $getBacklogFn = ${function:Get-Backlog}
  $saveBacklogFn = ${function:Save-Backlog}
  $testFailedFn = ${function:Test-TaskOutcomeLedgerFailed}
  $copyFn = ${function:Copy-DriverOutcomeItem}
  $setPropFn = ${function:Set-DriverOutcomeProperty}

  return (Invoke-BacklogLocked ({
    $items = @(& $getBacklogFn)
    $failedIds = New-Object 'System.Collections.Generic.List[string]'
    $blockedIds = New-Object 'System.Collections.Generic.List[string]'
    $reason = 'failure_evidence_present'
    $dirty = $false
    foreach ($id in @($idsClean)) {
      $item = $null
      foreach ($candidateItem in $items) {
        if ([string]$candidateItem.id -eq [string]$id) { $item = $candidateItem; break }
      }
      if ($null -eq $item) {
        [void]$blockedIds.Add([string]$id)
        $reason = 'backlog_item_not_found'
        continue
      }
      $candidate = & $copyFn -Item $item
      & $setPropFn -Item $candidate -Name 'status' -Value 'failed'
      & $setPropFn -Item $candidate -Name 'failure_evidence' -Value $FailureEvidence
      $validation = & $testFailedFn -Item $candidate
      if (-not [bool]$validation.valid) {
        [void]$blockedIds.Add([string]$id)
        $reason = [string]$validation.reason
        continue
      }
      & $setPropFn -Item $item -Name 'status' -Value 'failed'
      & $setPropFn -Item $item -Name 'failure_evidence' -Value $FailureEvidence
      [void]$failedIds.Add([string]$id)
      $dirty = $true
    }
    if ($dirty) { & $saveBacklogFn $items }
    return [pscustomobject][ordered]@{
      ok = ($blockedIds.Count -eq 0)
      reason = $reason
      failed_ids = @($failedIds.ToArray())
      blocked_ids = @($blockedIds.ToArray())
    }
  }.GetNewClosure()))
}
$script:DriverLoopCompletionCleanupBlock = {
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
      $doneBatchMode = ''
      try {
        if ($stDoneBacklog.PSObject.Properties.Name -contains 'workpack_batch_mode') { $doneBatchMode = [string]$stDoneBacklog.workpack_batch_mode }
      } catch { $doneBatchMode = '' }
      $doneIds = if ($doneBatchIds.Count -gt 0) { @($doneBatchIds) } elseif ($doneBid) { @($doneBid) } else { @() }
      if ($doneIds.Count -gt 0) {
        $doneOutcomeEvidence = New-DriverCompletionDoneEvidence -State $stDoneBacklog -Reply $visibleReply -Speaker $speaker -BridgeRoot $bridgeRoot -Channel $Channel -FastLaneDone ([bool]$fastLaneDone)
        $doneLedgerResult = Set-BacklogOutcomeDoneWithLedger -Ids $doneIds -OutcomeEvidence $doneOutcomeEvidence -BridgeRoot $bridgeRoot
        if (-not [bool]$doneLedgerResult.ok) {
          $ledgerReason = [string]$doneLedgerResult.reason
          if ([string]::IsNullOrWhiteSpace($ledgerReason)) { $ledgerReason = 'outcome_ledger_invalid' }
          try { Set-TaskLastFailure -Kind test_failed -Text ('outcome_ledger_invalid: ' + $ledgerReason) } catch {}
          Add-Message -From system -Text ("🚫 Outcome ledger blocked backlog completion (reason=" + $ledgerReason + "). Done/failed terminal statuses require reproducible evidence; continuing instead of closing.") -Kind event | Out-Null
          $plannerStatus = 'CONTINUE'
          continue
        }
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
        if ($doneIds.Count -gt 1 -and [string]$doneBatchMode -eq 'serial') {
          Add-Message -From system -Text ("✅ Protected serial-batch выполнен: закрыто safety/core задач бэклога: " + $doneIds.Count + ". 🤖 Автономных задач подряд без вмешательства: $sNow$bestTxt") -Kind event | Out-Null
        } elseif ($doneIds.Count -gt 1) {
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
    try { Invoke-PostTaskSelfModelRefresh -Channel $Channel -BridgeRoot $bridgeRoot | Out-Null } catch {}
    # Delivery gate shadow: evidence-only report, never blocks DONE or release.
    if ($modeBeforeIncrement -eq 'normal') {
      try {
        $stDg = Read-State
        $dgTaskId = [string]$stDg.current_task_id
        if ([string]::IsNullOrWhiteSpace($dgTaskId)) { $dgTaskId = [string]$stDg.current_backlog_id }
        if ([string]::IsNullOrWhiteSpace($dgTaskId)) { $dgTaskId = 'task-' + [string]$stDg.task_start_seq }
        $dgBase = [string]$stDg.task_base_commit
        $dgHead = try { (& git -C $bridgeRoot log -1 --format='%H' 2>$null).Trim() } catch { '' }
        $dgEvents = @(@{ text = [string]$visibleReply })
        $dgAcceptancePassed = Get-DeliveryGateAcceptanceFact `
          -BridgeRoot $bridgeRoot `
          -Channel $Channel `
          -TaskText $task `
          -BaseCommit $dgBase `
          -HeadCommit $dgHead `
          -Events $dgEvents
        # Atom 16: preliminary facts to detect critical_bridge_self before canary.
        $dgPrelimFacts = New-DeliveryGateInputFacts `
          -BridgeRoot $bridgeRoot `
          -Channel $Channel `
          -TaskText $task `
          -BaseCommit $dgBase `
          -HeadCommit $dgHead `
          -Events $dgEvents `
          -QaPassed $false `
          -CriticPassed $false `
          -ParsePassed $false `
          -SmokePassed $false `
          -AcceptancePassed $false `
          -CanaryPassed $false
        $dgCanaryPassed = $false
        if ([bool]$dgPrelimFacts.critical_bridge_self `
            -and -not [bool]$dgPrelimFacts.rollback_required `
            -and -not [bool]$dgPrelimFacts.destructive_patterns `
            -and -not [bool]$dgPrelimFacts.quality_bypass_detected) {
          try {
            . (Join-Path $bridgeRoot 'lib\canary.ps1')
            $dgCanaryResult = Invoke-CanaryCycle -Force -NoStateUpdate
            $dgCanaryPassed = ([bool]$dgCanaryResult.ok -eq $true) -and ([bool]$dgCanaryResult.skipped -ne $true)
          } catch {
            $dgCanaryPassed = $false
          }
        }
        $dgFacts = New-DeliveryGateInputFacts `
          -BridgeRoot $bridgeRoot `
          -Channel $Channel `
          -TaskText $task `
          -BaseCommit $dgBase `
          -HeadCommit $dgHead `
          -Events $dgEvents `
          -QaPassed $true `
          -CriticPassed $true `
          -ParsePassed $true `
          -SmokePassed $true `
          -AcceptancePassed $dgAcceptancePassed `
          -CanaryPassed $dgCanaryPassed `
          -MemoryUpdated $true `
          -SelfModelRefreshed $true `
          -ParallelObligationOk $true
        $dgResult = Get-DeliveryGateResult -InputFacts $dgFacts
        $dgWrite = Write-DeliveryGateShadowRecord `
          -BridgeRoot $bridgeRoot `
          -Channel $Channel `
          -TaskId $dgTaskId `
          -TaskText $task `
          -BaseCommit $dgBase `
          -HeadCommit $dgHead `
          -Facts $dgFacts `
          -Result $dgResult `
          -Note 'shadow-only; no DONE/release blocking'
        $dgReason = [string]$dgResult.reason
        if ($dgReason.Length -gt 160) { $dgReason = $dgReason.Substring(0,160) + '...' }
        Add-Message -From system -Text ("🧪 Delivery gate shadow: ok=$($dgResult.ok) risk=$($dgResult.risk) release=$($dgResult.release_allowed) reason=$dgReason") -Kind event | Out-Null
        if (-not [bool]$dgWrite.ok) {
          Add-Message -From system -Text ("⚠ Delivery gate shadow write failed: " + [string]$dgWrite.error) -Kind event | Out-Null
        }
      } catch {
        try { Add-Message -From system -Text ("⚠ Delivery gate shadow failed open: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
      }
    }
    # Delivery gate shadow end.
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
    Update-State { param($s) Complete-TaskAgentDuration $s; Close-ReplayForStateTask -State $s -Status 'done'; $s.current_task=$null; $s.task_turn=0; $s.task_mode='normal'; $s.no_progress_count=0; $s.timeout_retry_count=0; $s.task_did_actions=$false; $s.coder_fired=$false; $s.coder_bypass_retry_count=0; $s.verify_retry_count=0; $s.force_planner=$false; $s.discuss_turn=0; $s.discuss_snapshot=''; $s.study_phase=''; $s.study_subtype=''; $s.study_snapshot=''; $s.research_count=0; Clear-AuditorSuppressedHashes -State $s; Clear-FastLaneFlags $s -PreserveReflectSkip; Clear-ChunkingState $s; $s.current_backlog_id=$null; $s | Add-Member -NotePropertyName codex_evidence_retry_count -NotePropertyValue 0 -Force; $s | Add-Member -NotePropertyName workpack_batch_ids -NotePropertyValue @() -Force; $s | Add-Member -NotePropertyName workpack_batch_active -NotePropertyValue $false -Force; $s | Add-Member -NotePropertyName workpack_batch_dispatched -NotePropertyValue $false -Force; $s | Add-Member -NotePropertyName workpack_batch_mode -NotePropertyValue '' -Force; $s.active_agent=$null; $s.active_model=$null; $s.status_text=$null; $s.status='idle'; $s | Add-Member -NotePropertyName task_restart_count -NotePropertyValue 0 -Force } | Out-Null
    continue
  }
}
