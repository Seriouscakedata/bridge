[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:Pass = 0
$script:Fail = 0
$script:Messages = New-Object 'System.Collections.Generic.List[string]'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:TestRoot = Join-Path (Join-Path $repoRoot 'control') ('queue-governor-completion-hooks-test-' + [guid]::NewGuid().ToString('N'))
$script:BacklogPath = Join-Path $script:TestRoot 'backlog.jsonl'

function Assert-QueueCompletionHook {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    [Parameter(Mandatory=$false)][string]$Detail = ''
  )
  if ($Condition) {
    $script:Pass++
    Write-Host ("PASS: {0}" -f $Name)
    return
  }
  $script:Fail++
  if ([string]::IsNullOrWhiteSpace($Detail)) {
    Write-Host ("FAIL: {0}" -f $Name)
  } else {
    Write-Host ("FAIL: {0} :: {1}" -f $Name, $Detail)
  }
}

function Get-BridgeRoot { return $script:TestRoot }
function Get-ChannelBacklogPath { return $script:BacklogPath }
function Use-BridgeLock {
  param([scriptblock]$ScriptBlock)
  & $ScriptBlock
}
function Add-Message {
  param([string]$From, [string]$Text, [string]$Kind = 'message')
  [void]$script:Messages.Add($Text)
  return [pscustomobject]@{ ok = $true }
}

function New-QueueCompletionDoneEvidence {
  param(
    [switch]$OmitSha,
    [switch]$OmitChecks,
    [switch]$OmitCritic,
    [switch]$SkippedEmptyCritic,
    [switch]$OmitTopLevelLlmGateResults
  )
  $sha = if ($OmitSha) { '' } else { 'abc1234def5678' }
  $checks = if ($OmitChecks) { @() } else { @('driver.ps1 -SelfTest','smoke.ps1','tools/test-queue-governor-completion-hooks.ps1') }
  $evidence = [pscustomobject][ordered]@{
    done_sha = $sha
    done_evidence = [pscustomobject][ordered]@{
      commit = $sha
      checks = @($checks)
      smoke = 'SMOKE OK'
      llm_gate_results = [pscustomobject][ordered]@{
        critic_result = if ($SkippedEmptyCritic) { 'skipped-empty' } else { 'OK' }
        qa_result = 'PASS'
      }
    }
    done_by = 'codex'
    tests_run = @($checks)
    qa_result = 'PASS'
  }
  if (-not $OmitTopLevelLlmGateResults) {
    $evidence | Add-Member -NotePropertyName llm_gate_results -NotePropertyValue ([pscustomobject][ordered]@{
      critic_result = if ($SkippedEmptyCritic) { 'skipped-empty' } else { 'OK' }
      qa_result = 'PASS'
    }) -Force
  }
  if (-not $OmitCritic) {
    $evidence | Add-Member -NotePropertyName critic_result -NotePropertyValue $(if ($SkippedEmptyCritic) { 'skipped-empty' } else { 'OK' }) -Force
  }
  return $evidence
}

function Get-TestIdea {
  param([string]$Id)
  return (Get-IdeaById -Id $Id)
}

try {
  New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
  [System.IO.File]::WriteAllText($script:BacklogPath, '', (New-Object System.Text.UTF8Encoding($false)))

  . (Join-Path $repoRoot 'lib\backlog.ps1')
  . (Join-Path $repoRoot 'driver\86-loop-completion-cleanup.ps1')

  $missingDoneId = Add-Idea -Text 'completion ledger missing done evidence case' -Status 'new' -SkipCurator
  $missingDone = Set-BacklogOutcomeDoneWithLedger -Ids @($missingDoneId) -OutcomeEvidence (New-QueueCompletionDoneEvidence -OmitSha) -BridgeRoot $repoRoot
  $missingDoneItem = Get-TestIdea -Id $missingDoneId
  Assert-QueueCompletionHook 'done without required evidence is blocked' (
    -not [bool]$missingDone.ok -and
    @($missingDone.blocked_ids) -contains $missingDoneId -and
    [string]$missingDoneItem.status -ne 'done' -and
    [string]$missingDone.reason -match 'done_sha'
  ) ($missingDone | ConvertTo-Json -Compress -Depth 8)

  $validDoneId = Add-Idea -Text 'completion ledger complete done evidence case' -Status 'new' -SkipCurator
  $validDone = Set-BacklogOutcomeDoneWithLedger -Ids @($validDoneId) -OutcomeEvidence (New-QueueCompletionDoneEvidence) -BridgeRoot $repoRoot
  $validDoneItem = Get-TestIdea -Id $validDoneId
  Assert-QueueCompletionHook 'done with commit checks critic QA and smoke evidence passes' (
    [bool]$validDone.ok -and
    @($validDone.done_ids) -contains $validDoneId -and
    [string]$validDoneItem.status -eq 'done' -and
    [string]$validDoneItem.done_sha -eq 'abc1234def5678' -and
    [string]$validDoneItem.critic_result -eq 'OK' -and
    [string]$validDoneItem.qa_result -eq 'PASS' -and
    @($validDoneItem.tests_run | Where-Object { [string]$_ -match 'smoke\.ps1' }).Count -gt 0 -and
    [bool]$validDoneItem.outcome_ledger.valid
  ) ($validDoneItem | ConvertTo-Json -Compress -Depth 8)

  $emptyCriticDoneId = Add-Idea -Text 'completion ledger empty critic skipped evidence case' -Status 'new' -SkipCurator
  $emptyCriticDone = Set-BacklogOutcomeDoneWithLedger -Ids @($emptyCriticDoneId) -OutcomeEvidence (New-QueueCompletionDoneEvidence -OmitCritic -SkippedEmptyCritic) -BridgeRoot $repoRoot
  $emptyCriticDoneItem = Get-TestIdea -Id $emptyCriticDoneId
  Assert-QueueCompletionHook 'empty critic after cap closes with skipped-empty critic_result' (
    [bool]$emptyCriticDone.ok -and
    @($emptyCriticDone.done_ids) -contains $emptyCriticDoneId -and
    [string]$emptyCriticDoneItem.status -eq 'done' -and
    [string]$emptyCriticDoneItem.critic_result -eq 'skipped-empty' -and
    [bool]$emptyCriticDoneItem.outcome_ledger.valid
  ) ($emptyCriticDoneItem | ConvertTo-Json -Compress -Depth 8)

  $nestedEmptyCriticDoneId = Add-Idea -Text 'completion ledger nested empty critic skipped evidence case' -Status 'new' -SkipCurator
  $nestedEmptyCriticDone = Set-BacklogOutcomeDoneWithLedger -Ids @($nestedEmptyCriticDoneId) -OutcomeEvidence (New-QueueCompletionDoneEvidence -OmitCritic -SkippedEmptyCritic -OmitTopLevelLlmGateResults) -BridgeRoot $repoRoot
  $nestedEmptyCriticDoneItem = Get-TestIdea -Id $nestedEmptyCriticDoneId
  Assert-QueueCompletionHook 'nested skipped-empty LLM evidence is copied into critic_result' (
    [bool]$nestedEmptyCriticDone.ok -and
    @($nestedEmptyCriticDone.done_ids) -contains $nestedEmptyCriticDoneId -and
    [string]$nestedEmptyCriticDoneItem.status -eq 'done' -and
    [string]$nestedEmptyCriticDoneItem.critic_result -eq 'skipped-empty' -and
    [bool]$nestedEmptyCriticDoneItem.outcome_ledger.valid
  ) ($nestedEmptyCriticDoneItem | ConvertTo-Json -Compress -Depth 8)

  $missingCriticDoneId = Add-Idea -Text 'completion ledger missing critic without skipped evidence case' -Status 'new' -SkipCurator
  $missingCriticDone = Set-BacklogOutcomeDoneWithLedger -Ids @($missingCriticDoneId) -OutcomeEvidence (New-QueueCompletionDoneEvidence -OmitCritic) -BridgeRoot $repoRoot
  $missingCriticDoneItem = Get-TestIdea -Id $missingCriticDoneId
  Assert-QueueCompletionHook 'missing critic without skipped-empty evidence still blocks' (
    -not [bool]$missingCriticDone.ok -and
    @($missingCriticDone.blocked_ids) -contains $missingCriticDoneId -and
    [string]$missingCriticDoneItem.status -ne 'done' -and
    [string]$missingCriticDone.reason -match 'critic_result'
  ) ($missingCriticDone | ConvertTo-Json -Compress -Depth 8)

  $failedNoEvidenceId = Add-Idea -Text 'failed transition without evidence case' -Status 'new' -SkipCurator
  $failedNoEvidence = Set-Idea -Id $failedNoEvidenceId -Status 'failed'
  $failedNoEvidenceItem = Get-TestIdea -Id $failedNoEvidenceId
  Assert-QueueCompletionHook 'failed transition without failure_evidence is blocked' (
    -not [bool]$failedNoEvidence -and [string]$failedNoEvidenceItem.status -ne 'failed'
  ) ($failedNoEvidenceItem | ConvertTo-Json -Compress -Depth 8)

  $failedWithEvidenceId = Add-Idea -Text 'failed transition with evidence case' -Status 'new' -SkipCurator
  $failureEvidence = [pscustomobject][ordered]@{ reason = 'test failed'; log = 'failure.log' }
  $failedWithEvidence = Set-Idea -Id $failedWithEvidenceId -Status 'failed' -FailureEvidence $failureEvidence
  $failedWithEvidenceItem = Get-TestIdea -Id $failedWithEvidenceId
  Assert-QueueCompletionHook 'failed transition with failure_evidence passes' (
    [bool]$failedWithEvidence -and
    [string]$failedWithEvidenceItem.status -eq 'failed' -and
    [string]$failedWithEvidenceItem.failure_evidence.reason -eq 'test failed'
  ) ($failedWithEvidenceItem | ConvertTo-Json -Compress -Depth 8)

  $recoverDoneId = Add-Idea -Text 'false failed complete recovery case' -Status 'new' -SkipCurator
  [void](Set-Idea -Id $recoverDoneId -Status 'failed' -FailureEvidence $failureEvidence)
  $recoverDone = Set-BacklogOutcomeDoneWithLedger -Ids @($recoverDoneId) -OutcomeEvidence (New-QueueCompletionDoneEvidence) -BridgeRoot $repoRoot
  $recoverDoneItem = Get-TestIdea -Id $recoverDoneId
  Assert-QueueCompletionHook 'false failed with sha and checks recovers to done' (
    [bool]$recoverDone.ok -and
    [string]$recoverDoneItem.status -eq 'done' -and
    [string]$recoverDoneItem.done_sha -eq 'abc1234def5678'
  ) ($recoverDoneItem | ConvertTo-Json -Compress -Depth 8)

  $recoverReviewId = Add-Idea -Text 'false failed partial recovery case' -Status 'new' -SkipCurator
  [void](Set-Idea -Id $recoverReviewId -Status 'failed' -FailureEvidence $failureEvidence)
  $recoverReview = Set-BacklogOutcomeDoneWithLedger -Ids @($recoverReviewId) -OutcomeEvidence (New-QueueCompletionDoneEvidence -OmitSha) -BridgeRoot $repoRoot
  $recoverReviewItem = Get-TestIdea -Id $recoverReviewId
  Assert-QueueCompletionHook 'false failed with checks but no sha moves to needs-review with reason' (
    [bool]$recoverReview.ok -and
    @($recoverReview.needs_review_ids) -contains $recoverReviewId -and
    [string]$recoverReviewItem.status -eq 'needs-review' -and
    [string]$recoverReviewItem.outcome_recovery_reason -eq 'false_failed_recovery'
  ) (($recoverReview | ConvertTo-Json -Compress -Depth 8) + ' :: ' + ($recoverReviewItem | ConvertTo-Json -Compress -Depth 8))

  $cleanupText = Get-Content -LiteralPath (Join-Path $repoRoot 'driver\86-loop-completion-cleanup.ps1') -Raw -Encoding UTF8
  $checksText = Get-Content -LiteralPath (Join-Path $repoRoot 'driver\86-loop-completion-checks.ps1') -Raw -Encoding UTF8
  $actionsText = Get-Content -LiteralPath (Join-Path $repoRoot 'driver\86-loop-completion-actions.ps1') -Raw -Encoding UTF8
  $agentTurnText = Get-Content -LiteralPath (Join-Path $repoRoot 'driver\83-loop-agent-turn.ps1') -Raw -Encoding UTF8
  $modeText = Get-Content -LiteralPath (Join-Path $repoRoot 'driver\85-loop-mode-transitions.ps1') -Raw -Encoding UTF8
  $agentTurnText = Get-Content -LiteralPath (Join-Path $repoRoot 'driver\83-loop-agent-turn.ps1') -Raw -Encoding UTF8
  $crudText = Get-Content -LiteralPath (Join-Path $repoRoot 'lib\backlog-crud.ps1') -Raw -Encoding UTF8

  Assert-QueueCompletionHook 'completion path uses outcome ledger before Set-Idea done' (
    $cleanupText -match 'Set-BacklogOutcomeDoneWithLedger' -and
    $cleanupText -notmatch 'foreach \(\$doneId in \$doneIds\) \{ Set-Idea -Id \$doneId -Status ''done'''
  )
  Assert-QueueCompletionHook 'critic QA smoke and action evidence guards remain enabled' (
    $actionsText -match 'Invoke-LLM' -and
    $actionsText -match 'SKIPPED_EMPTY' -and
    $actionsText -match 'completion_critic_result' -and
    $actionsText -match '\$severity -eq ''serious''' -and
    $actionsText -match 'Set-TaskLastFailure -Kind critic_rejected' -and
    $actionsText -match '\$plannerStatus = ''CONTINUE''' -and
    $agentTurnText -match 'completion_coder_empty_attempts' -and
    $agentTurnText -match 'completion_coder_result' -and
    $agentTurnText -match 'continue mainDriverLoop' -and
    $checksText -match 'Invoke-QAAgent' -and
    $checksText -match 'smoke\.ps1' -and
    $modeText -match 'missing_action_evidence' -and
    $agentTurnText -match 'Get-TaskActionEvidence'
  )
  Assert-QueueCompletionHook 'backlog CRUD blocks failed without task outcome ledger evidence' (
    $crudText -match 'Test-TaskOutcomeLedgerFailed' -and
    $crudText -match 'outcome-ledger-block' -and
    $crudText -match 'FailureEvidence'
  )

} catch {
  Assert-QueueCompletionHook 'unhandled exception' $false $_.Exception.Message
} finally {
  Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("Queue Governor completion hooks tests: {0} PASS, {1} FAIL" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
