# test-task-outcome-ledger.ps1 -- Queue Governor outcome ledger tests

$ErrorActionPreference = 'Stop'
$bridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $bridgeRoot 'lib\backlog-governor.ps1')
. (Join-Path $bridgeRoot 'lib\task-outcome-ledger.ps1')

$script:pass = 0
$script:fail = 0

function Assert-TaskOutcomeLedger {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    [Parameter(Mandatory=$false)]$Detail = ''
  )
  if ($Condition) {
    Write-Host "PASS: $Name"
    $script:pass++
  } else {
    Write-Host "FAIL: $Name $Detail"
    $script:fail++
  }
}

function New-LedgerDoneItem {
  param([string[]]$Omit = @())
  $item = [pscustomobject][ordered]@{
    id = 'done-item'
    status = 'done'
    title = 'Outcome ledger done case'
    done_sha = 'abc1234'
    done_evidence = [pscustomobject][ordered]@{ commit = 'abc1234'; checks = @('unit') }
    done_by = 'codex'
    tests_run = @('tools/test-task-outcome-ledger.ps1')
    critic_result = 'OK'
    qa_result = 'PASS'
  }
  foreach ($field in @($Omit)) {
    $item.PSObject.Properties.Remove($field)
  }
  return $item
}

function New-LedgerFailedItem {
  param([bool]$WithEvidence = $false)
  $item = [pscustomobject][ordered]@{
    id = 'failed-item'
    status = 'failed'
    title = 'Outcome ledger failed case'
  }
  if ($WithEvidence) {
    $item | Add-Member -NotePropertyName failure_evidence -NotePropertyValue ([pscustomobject][ordered]@{ reason = 'test failed'; log = 'failure.log' }) -Force
  }
  return $item
}

try {
  foreach ($field in @('done_sha','done_evidence','done_by','tests_run','critic_result','qa_result')) {
    $result = Test-TaskOutcomeLedgerDone -Item (New-LedgerDoneItem -Omit @($field))
    Assert-TaskOutcomeLedger "done without $field is rejected" (
      -not [bool]$result.valid -and [string]$result.reason -eq 'missing_done_fields' -and @($result.missing) -contains $field
    ) ($result | ConvertTo-Json -Compress -Depth 8)
  }

  $validDone = Test-TaskOutcomeLedgerDone -Item (New-LedgerDoneItem)
  Assert-TaskOutcomeLedger 'done with all required fields is valid' (
    [bool]$validDone.valid -and [string]$validDone.reason -eq 'done_evidence_complete' -and @($validDone.missing).Count -eq 0
  ) ($validDone | ConvertTo-Json -Compress -Depth 8)

  $criticSkippedViaEvidence = New-LedgerDoneItem -Omit @('critic_result')
  $criticSkippedViaEvidence.done_evidence | Add-Member -NotePropertyName llm_gate_results -NotePropertyValue ([pscustomobject][ordered]@{ critic_result = 'skipped-empty'; qa_result = 'PASS' }) -Force
  $criticSkippedResult = Test-TaskOutcomeLedgerDone -Item $criticSkippedViaEvidence
  Assert-TaskOutcomeLedger 'done without critic_result is valid only with skipped-empty LLM evidence' (
    [bool]$criticSkippedResult.valid -and [string]$criticSkippedResult.reason -eq 'done_evidence_complete'
  ) ($criticSkippedResult | ConvertTo-Json -Compress -Depth 8)

  $qaSkippedViaEvidence = New-LedgerDoneItem -Omit @('qa_result')
  $qaSkippedViaEvidence.done_evidence | Add-Member -NotePropertyName llm_gate_results -NotePropertyValue ([pscustomobject][ordered]@{ critic_result = 'PASS'; qa_result = 'skipped-empty' }) -Force
  $qaSkippedResult = Test-TaskOutcomeLedgerDone -Item $qaSkippedViaEvidence
  Assert-TaskOutcomeLedger 'done without qa_result is valid only with skipped-empty LLM evidence' (
    [bool]$qaSkippedResult.valid -and [string]$qaSkippedResult.reason -eq 'done_evidence_complete'
  ) ($qaSkippedResult | ConvertTo-Json -Compress -Depth 8)

  $missingNonLlmWithSkipped = New-LedgerDoneItem -Omit @('tests_run')
  $missingNonLlmWithSkipped.done_evidence | Add-Member -NotePropertyName llm_gate_results -NotePropertyValue ([pscustomobject][ordered]@{ critic_result = 'skipped-empty'; qa_result = 'PASS' }) -Force
  $missingNonLlmResult = Test-TaskOutcomeLedgerDone -Item $missingNonLlmWithSkipped
  Assert-TaskOutcomeLedger 'skipped-empty LLM evidence does not satisfy missing deterministic fields' (
    -not [bool]$missingNonLlmResult.valid -and @($missingNonLlmResult.missing) -contains 'tests_run'
  ) ($missingNonLlmResult | ConvertTo-Json -Compress -Depth 8)

  $failedWithoutEvidence = Test-TaskOutcomeLedgerFailed -Item (New-LedgerFailedItem)
  Assert-TaskOutcomeLedger 'failed without failure_evidence is rejected' (
    -not [bool]$failedWithoutEvidence.valid -and [string]$failedWithoutEvidence.reason -eq 'missing_failure_evidence'
  ) ($failedWithoutEvidence | ConvertTo-Json -Compress -Depth 8)

  $failedWithEvidence = Test-TaskOutcomeLedgerFailed -Item (New-LedgerFailedItem -WithEvidence $true)
  Assert-TaskOutcomeLedger 'failed with failure_evidence is valid' (
    [bool]$failedWithEvidence.valid -and [string]$failedWithEvidence.reason -eq 'failure_evidence_present'
  ) ($failedWithEvidence | ConvertTo-Json -Compress -Depth 8)

  $recoverDone = Test-TaskOutcomeLedgerRecoverFalseFailed -Item (New-LedgerFailedItem -WithEvidence $true) -RecoveryEvidence ([pscustomobject][ordered]@{
    recovery_sha = 'def5678'
    recovery_checks = @('driver.ps1 -SelfTest','smoke.ps1')
  })
  Assert-TaskOutcomeLedger 'failed with recovery_sha and recovery_checks proposes done' (
    [bool]$recoverDone.recoverable -and [string]$recoverDone.proposed_status -eq 'done' -and [string]$recoverDone.reason -eq 'false_failed_recovery'
  ) ($recoverDone | ConvertTo-Json -Compress -Depth 8)

  $recoverReview = Test-TaskOutcomeLedgerRecoverFalseFailed -Item (New-LedgerFailedItem -WithEvidence $true) -RecoveryEvidence ([pscustomobject][ordered]@{
    recovery_checks = @('tools/test-task-outcome-ledger.ps1')
  })
  Assert-TaskOutcomeLedger 'failed with only recovery_checks proposes needs-review' (
    [bool]$recoverReview.recoverable -and [string]$recoverReview.proposed_status -eq 'needs-review'
  ) ($recoverReview | ConvertTo-Json -Compress -Depth 8)

  $recoverMissing = Test-TaskOutcomeLedgerRecoverFalseFailed -Item (New-LedgerFailedItem -WithEvidence $true) -RecoveryEvidence ([pscustomobject][ordered]@{})
  Assert-TaskOutcomeLedger 'failed without recovery evidence is not recoverable' (
    -not [bool]$recoverMissing.recoverable
  ) ($recoverMissing | ConvertTo-Json -Compress -Depth 8)

  $now = [datetime]::Parse('2026-06-05T12:00:00Z').ToUniversalTime()
  $entry = Get-TaskOutcomeLedgerEntry -Item (New-LedgerDoneItem) -NowUtc $now
  $propertyOrder = @($entry.PSObject.Properties.Name) -join ','
  Assert-TaskOutcomeLedger 'ledger entry has stable inspectable property order' (
    $propertyOrder -eq 'id,status,valid,validation_result,recovery_eligible,ledger_ts'
  ) $propertyOrder
  Assert-TaskOutcomeLedger 'ledger entry for done item includes id status valid and deterministic timestamp' (
    [string]$entry.id -eq 'done-item' -and [string]$entry.status -eq 'done' -and [bool]$entry.valid -and [string]$entry.ledger_ts -eq '2026-06-05T12:00:00.0000000Z'
  ) ($entry | ConvertTo-Json -Compress -Depth 8)

  $entryAgain = Get-TaskOutcomeLedgerEntry -Item (New-LedgerDoneItem) -NowUtc $now
  Assert-TaskOutcomeLedger 'ledger entry is reproducible for same input and timestamp' (
    [string]$entryAgain.id -eq [string]$entry.id -and
    [string]$entryAgain.status -eq [string]$entry.status -and
    [bool]$entryAgain.valid -eq [bool]$entry.valid -and
    [string]$entryAgain.ledger_ts -eq [string]$entry.ledger_ts -and
    [string]$entryAgain.validation_result.reason -eq [string]$entry.validation_result.reason
  ) (($entryAgain | ConvertTo-Json -Compress -Depth 8) + ' :: ' + ($entry | ConvertTo-Json -Compress -Depth 8))

  $moduleText = Get-Content -LiteralPath (Join-Path $bridgeRoot 'lib\task-outcome-ledger.ps1') -Raw -Encoding UTF8
  $forbiddenTokens = @(
    'Save-Backlog',
    'Write-BacklogJsonLine',
    'Set-Content',
    'Out-File',
    'New-Item',
    'Remove-Item',
    'Start-Process',
    'driver/81-loop-idle-claim.ps1',
    'driver/83-loop-agent-turn.ps1',
    'driver/86-loop-completion-cleanup.ps1',
    'lib/backlog-workpack.ps1'
  )
  $foundForbidden = @($forbiddenTokens | Where-Object { $moduleText -like ('*' + $_ + '*') })
  Assert-TaskOutcomeLedger 'module has no write or hot-path tokens' ($foundForbidden.Count -eq 0) ($foundForbidden -join ', ')
} catch {
  Write-Host "FAIL: unhandled exception :: $($_.Exception.Message)"
  $script:fail++
}

Write-Host ("Task Outcome Ledger tests: {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
