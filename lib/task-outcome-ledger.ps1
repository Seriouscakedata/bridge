# task-outcome-ledger.ps1 -- read-only Queue Governor outcome evidence validation

if (-not (Get-Command Get-BacklogGovernorObjectValue -ErrorAction SilentlyContinue)) {
  $script:TaskOutcomeLedgerGovernorPath = Join-Path $PSScriptRoot 'backlog-governor.ps1'
  if (Test-Path -LiteralPath $script:TaskOutcomeLedgerGovernorPath) {
    . $script:TaskOutcomeLedgerGovernorPath
  }
}
if (-not (Get-Command Get-BridgeObjectValue -ErrorAction SilentlyContinue)) {
  try { . (Join-Path $PSScriptRoot 'primitives.ps1') } catch {}
}

function Get-TaskOutcomeLedgerObjectValue {
  # Delegate preserves original ledger semantics: present-but-null is returned.
  param(
    [Parameter(Mandatory=$false)]$Object,
    [Parameter(Mandatory=$true)][string[]]$Names,
    [Parameter(Mandatory=$false)]$Default = $null
  )
  return Get-BridgeObjectValue -Object $Object -Names $Names -Default $Default
}

function Test-TaskOutcomeLedgerValuePresent {
  param([Parameter(Mandatory=$false)]$Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [string]) { return (-not [string]::IsNullOrWhiteSpace($Value)) }
  if ($Value -is [System.Collections.IDictionary]) { return ($Value.Count -gt 0) }
  if ($Value -is [System.Collections.IEnumerable]) { return (@($Value).Count -gt 0) }
  $properties = @($Value.PSObject.Properties)
  if ($properties.Count -eq 0) { return $true }
  return $true
}

function Test-TaskOutcomeLedgerSkippedEmptyResult {
  param([Parameter(Mandatory=$false)]$Value)
  return ([string]$Value).Trim().ToLowerInvariant() -eq 'skipped-empty'
}

function Get-TaskOutcomeLedgerLlmGateEvidenceResult {
  param(
    [Parameter(Mandatory=$false)]$Item,
    [Parameter(Mandatory=$true)][string]$Field
  )
  $doneEvidence = Get-TaskOutcomeLedgerObjectValue -Object $Item -Names @('done_evidence') -Default $null
  foreach ($containerName in @('llm_gate_results','llm_gate_evidence','empty_llm_results')) {
    $container = Get-TaskOutcomeLedgerObjectValue -Object $doneEvidence -Names @($containerName) -Default $null
    if ($null -eq $container) { continue }
    $value = Get-TaskOutcomeLedgerObjectValue -Object $container -Names @($Field) -Default $null
    if (Test-TaskOutcomeLedgerValuePresent -Value $value) { return $value }
  }
  return $null
}

function Get-TaskOutcomeLedgerStatus {
  param([Parameter(Mandatory=$false)]$Item)
  return ([string](Get-TaskOutcomeLedgerObjectValue -Object $Item -Names @('status') -Default '')).Trim().ToLowerInvariant()
}

function Get-TaskOutcomeLedgerId {
  param([Parameter(Mandatory=$false)]$Item)
  foreach ($name in @('id','task_id','backlog_id')) {
    $raw = [string](Get-TaskOutcomeLedgerObjectValue -Object $Item -Names @($name) -Default '')
    if (-not [string]::IsNullOrWhiteSpace($raw)) { return $raw.Trim() }
  }
  return ''
}

function Test-TaskOutcomeLedgerDone {
  param([Parameter(Mandatory=$false)]$Item)
  $status = Get-TaskOutcomeLedgerStatus -Item $Item
  if ($status -ne 'done') {
    return [pscustomobject][ordered]@{
      valid = $true
      reason = 'status_not_done'
      missing = @()
    }
  }
  $requiredFields = @('done_sha','done_evidence','done_by','tests_run','critic_result','qa_result')
  $missing = @()
  foreach ($field in $requiredFields) {
    $value = Get-TaskOutcomeLedgerObjectValue -Object $Item -Names @($field)
    if (-not (Test-TaskOutcomeLedgerValuePresent -Value $value)) {
      if (($field -eq 'critic_result' -or $field -eq 'qa_result') -and
          (Test-TaskOutcomeLedgerSkippedEmptyResult -Value (Get-TaskOutcomeLedgerLlmGateEvidenceResult -Item $Item -Field $field))) {
        continue
      }
      $missing += $field
    }
  }
  if (@($missing).Count -gt 0) {
    return [pscustomobject][ordered]@{
      valid = $false
      reason = 'missing_done_fields'
      missing = @($missing)
    }
  }
  return [pscustomobject][ordered]@{
    valid = $true
    reason = 'done_evidence_complete'
    missing = @()
  }
}

function Test-TaskOutcomeLedgerFailed {
  param([Parameter(Mandatory=$false)]$Item)
  $status = Get-TaskOutcomeLedgerStatus -Item $Item
  if ($status -ne 'failed') {
    return [pscustomobject][ordered]@{
      valid = $true
      reason = 'status_not_failed'
      missing = @()
    }
  }
  $failureEvidence = Get-TaskOutcomeLedgerObjectValue -Object $Item -Names @('failure_evidence')
  if (-not (Test-TaskOutcomeLedgerValuePresent -Value $failureEvidence)) {
    return [pscustomobject][ordered]@{
      valid = $false
      reason = 'missing_failure_evidence'
      missing = @('failure_evidence')
    }
  }
  return [pscustomobject][ordered]@{
    valid = $true
    reason = 'failure_evidence_present'
    missing = @()
  }
}

function Test-TaskOutcomeLedgerRecoverFalseFailed {
  param(
    [Parameter(Mandatory=$false)]$Item,
    [Parameter(Mandatory=$false)]$RecoveryEvidence
  )
  $status = Get-TaskOutcomeLedgerStatus -Item $Item
  if ($status -ne 'failed') {
    return [pscustomobject][ordered]@{
      recoverable = $false
      proposed_status = ''
      reason = 'status_not_failed'
    }
  }
  $recoverySha = Get-TaskOutcomeLedgerObjectValue -Object $RecoveryEvidence -Names @('recovery_sha','done_sha','sha','commit')
  $recoveryChecks = Get-TaskOutcomeLedgerObjectValue -Object $RecoveryEvidence -Names @('recovery_checks','checks_run','tests_run','checks')
  $hasSha = Test-TaskOutcomeLedgerValuePresent -Value $recoverySha
  $hasChecks = Test-TaskOutcomeLedgerValuePresent -Value $recoveryChecks
  if ($hasSha -and $hasChecks) {
    return [pscustomobject][ordered]@{
      recoverable = $true
      proposed_status = 'done'
      reason = 'false_failed_recovery'
    }
  }
  if ($hasChecks) {
    return [pscustomobject][ordered]@{
      recoverable = $true
      proposed_status = 'needs-review'
      reason = 'false_failed_recovery'
    }
  }
  return [pscustomobject][ordered]@{
    recoverable = $false
    proposed_status = ''
    reason = 'missing_recovery_evidence'
  }
}

function Get-TaskOutcomeLedgerEntry {
  param(
    [Parameter(Mandatory=$false)]$Item,
    [Parameter(Mandatory=$false)]$RecoveryEvidence,
    [Parameter(Mandatory=$false)][datetime]$NowUtc = [datetime]::UtcNow
  )
  $status = Get-TaskOutcomeLedgerStatus -Item $Item
  if ($status -eq 'done') {
    $validation = Test-TaskOutcomeLedgerDone -Item $Item
  } elseif ($status -eq 'failed') {
    $validation = Test-TaskOutcomeLedgerFailed -Item $Item
  } else {
    $validation = [pscustomobject][ordered]@{
      valid = $true
      reason = 'status_not_terminal'
      missing = @()
    }
  }
  $recovery = Test-TaskOutcomeLedgerRecoverFalseFailed -Item $Item -RecoveryEvidence $RecoveryEvidence
  return [pscustomobject][ordered]@{
    id = Get-TaskOutcomeLedgerId -Item $Item
    status = $status
    valid = [bool]$validation.valid
    validation_result = $validation
    recovery_eligible = [bool]$recovery.recoverable
    ledger_ts = $NowUtc.ToUniversalTime().ToString('o')
  }
}
