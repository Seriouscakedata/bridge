# delivery-gate.ps1 -- pure read-only deterministic delivery gate.
#
# This file is intentionally isolated from the live driver. It does not write
# files, mutate runtime state, call models/APIs, or authorize execution. It only
# validates delivery facts and returns a deterministic strict result.

$script:DeliveryGateBoolInputEnum = @(
  'repo_clean',
  'forbidden_changes',
  'destructive_patterns',
  'parse_ok',
  'tests_ok',
  'smoke_ok',
  'acceptance_ok',
  'review_board_ok',
  'parallel_obligation_ok',
  'memory_updated',
  'self_model_refreshed',
  'critical_bridge_self',
  'canary_ok',
  'quality_bypass_detected',
  'rollback_required'
)

$script:DeliveryGateOptionalInputEnum = @(
  'evidence',
  'forbidden_changes_files',
  'protected_project_spec_changes'
)

$script:DeliveryGateOutputFieldEnum = @(
  'ok',
  'merge_allowed',
  'release_allowed',
  'risk',
  'failures',
  'warnings',
  'required_checks',
  'evidence',
  'canary_required',
  'rollback_required',
  'reason'
)

$script:DeliveryGateRiskEnum = @(
  'low',
  'normal',
  'high',
  'critical'
)

function Get-DeliveryGateSchema {
  return [ordered]@{
    input = [ordered]@{
      required = @($script:DeliveryGateBoolInputEnum)
      optional = @($script:DeliveryGateOptionalInputEnum)
      types    = [ordered]@{
        repo_clean             = 'bool'
        forbidden_changes      = 'bool'
        destructive_patterns   = 'bool'
        parse_ok               = 'bool'
        tests_ok               = 'bool'
        smoke_ok               = 'bool'
        acceptance_ok          = 'bool'
        review_board_ok        = 'bool'
        parallel_obligation_ok = 'bool'
        memory_updated         = 'bool'
        self_model_refreshed   = 'bool'
        critical_bridge_self   = 'bool'
        canary_ok              = 'bool'
        quality_bypass_detected = 'bool'
        rollback_required      = 'bool'
        evidence               = 'string?'
        forbidden_changes_files = 'string[]?'
        protected_project_spec_changes = 'string[]?'
      }
    }
    output = [ordered]@{
      ok               = 'bool'
      merge_allowed    = 'bool'
      release_allowed  = 'bool'
      risk             = 'low|normal|high|critical'
      failures         = 'string[]'
      warnings         = 'string[]'
      required_checks  = 'string[]'
      evidence         = 'string[]'
      canary_required  = 'bool'
      rollback_required = 'bool'
      reason           = 'string'
    }
  }
}

function Add-DeliveryGateListItem {
  param(
    [Parameter(Mandatory)]$List,
    [string]$Value
  )
  if ([string]::IsNullOrWhiteSpace($Value)) { return }
  if (-not $List.Contains($Value)) { [void]$List.Add($Value) }
}

function Test-DeliveryGateBooleanValue {
  param($Value)
  return ($Value -is [bool])
}

function Get-DeliveryGateEvidenceList {
  param($InputFacts)

  if ($null -eq $InputFacts) { return [string[]]@() }
  if ($InputFacts -isnot [System.Collections.IDictionary]) { return [string[]]@() }
  if (-not $InputFacts.Contains('evidence')) { return [string[]]@() }

  $raw = $InputFacts['evidence']
  if ($null -eq $raw) { return [string[]]@() }
  if ($raw -isnot [string]) { return [string[]]@() }

  $items = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in ($raw -split "(`r`n|`n|`r)")) {
    $trimmed = $line.Trim()
    if (-not [string]::IsNullOrWhiteSpace($trimmed)) {
      Add-DeliveryGateListItem -List $items -Value $trimmed
    }
  }
  return [string[]]@($items.ToArray())
}

function Get-DeliveryGateRisk {
  param(
    [Parameter(Mandatory)][hashtable]$Facts,
    [string[]]$Warnings = @()
  )

  if ([bool]$Facts.critical_bridge_self) { return 'critical' }
  if ([bool]$Facts.forbidden_changes -or [bool]$Facts.destructive_patterns -or [bool]$Facts.quality_bypass_detected) { return 'high' }
  if (-not [bool]$Facts.acceptance_ok) { return 'high' }
  if (@($Warnings).Count -gt 0) { return 'normal' }
  return 'low'
}

function New-DeliveryGateResult {
  param(
    [Parameter(Mandatory)][bool]$Ok,
    [Parameter(Mandatory)][bool]$MergeAllowed,
    [Parameter(Mandatory)][bool]$ReleaseAllowed,
    [Parameter(Mandatory)][ValidateSet('low','normal','high','critical')][string]$Risk,
    [string[]]$Failures = @(),
    [string[]]$Warnings = @(),
    [string[]]$RequiredChecks = @(),
    [string[]]$Evidence = @(),
    [Parameter(Mandatory)][bool]$CanaryRequired,
    [Parameter(Mandatory)][bool]$RollbackRequired,
    [Parameter(Mandatory)][string]$Reason
  )

  foreach ($entry in @(
      @{ Name = 'failures'; Value = $Failures },
      @{ Name = 'warnings'; Value = $Warnings },
      @{ Name = 'required_checks'; Value = $RequiredChecks },
      @{ Name = 'evidence'; Value = $Evidence }
    )) {
    if ($null -eq $entry.Value) { continue }
    foreach ($item in @($entry.Value)) {
      if ($item -isnot [string]) { throw "Delivery gate $($entry.Name) must contain only strings" }
    }
  }

  [string[]]$failureValues = @()
  [string[]]$warningValues = @()
  [string[]]$requiredCheckValues = @()
  [string[]]$evidenceValues = @()

  if ($null -ne $Failures) { $failureValues = [string[]]@($Failures) }
  if ($null -ne $Warnings) { $warningValues = [string[]]@($Warnings) }
  if ($null -ne $RequiredChecks) { $requiredCheckValues = [string[]]@($RequiredChecks) }
  if ($null -ne $Evidence) { $evidenceValues = [string[]]@($Evidence) }

  return [pscustomobject][ordered]@{
    ok                = $Ok
    merge_allowed     = $MergeAllowed
    release_allowed   = $ReleaseAllowed
    risk              = $Risk
    failures          = $failureValues
    warnings          = $warningValues
    required_checks   = $requiredCheckValues
    evidence          = $evidenceValues
    canary_required   = $CanaryRequired
    rollback_required = $RollbackRequired
    reason            = $Reason
  }
}

function Test-DeliveryGateInput {
  param($InputFacts)

  $missing = New-Object 'System.Collections.Generic.List[string]'
  $warnings = New-Object 'System.Collections.Generic.List[string]'
  $typeFailures = New-Object 'System.Collections.Generic.List[string]'

  if ($null -eq $InputFacts) {
    foreach ($name in $script:DeliveryGateBoolInputEnum) {
      Add-DeliveryGateListItem -List $missing -Value $name
    }
    Add-DeliveryGateListItem -List $warnings -Value 'input:null'
    return @{
      ok       = $false
      missing  = @($missing.ToArray())
      warnings = @($warnings.ToArray())
    }
  }

  if ($InputFacts -isnot [System.Collections.IDictionary]) {
    foreach ($name in $script:DeliveryGateBoolInputEnum) {
      Add-DeliveryGateListItem -List $missing -Value $name
    }
    Add-DeliveryGateListItem -List $warnings -Value 'input:not_hashtable'
    return @{
      ok       = $false
      missing  = @($missing.ToArray())
      warnings = @($warnings.ToArray())
    }
  }

  foreach ($name in $script:DeliveryGateBoolInputEnum) {
    if (-not $InputFacts.Contains($name)) {
      Add-DeliveryGateListItem -List $missing -Value $name
      continue
    }
    if (-not (Test-DeliveryGateBooleanValue -Value $InputFacts[$name])) {
      Add-DeliveryGateListItem -List $typeFailures -Value ('non_boolean:' + $name)
    }
  }

  if ($InputFacts.Contains('evidence') -and $null -ne $InputFacts['evidence'] -and $InputFacts['evidence'] -isnot [string]) {
    Add-DeliveryGateListItem -List $typeFailures -Value 'evidence:not_string'
  }

  foreach ($key in $InputFacts.Keys) {
    if (($script:DeliveryGateBoolInputEnum -notcontains [string]$key) -and ($script:DeliveryGateOptionalInputEnum -notcontains [string]$key)) {
      Add-DeliveryGateListItem -List $warnings -Value ('unknown_fact:' + [string]$key)
    }
  }

  foreach ($warning in $typeFailures) {
    Add-DeliveryGateListItem -List $warnings -Value $warning
  }

  return @{
    ok       = ([bool]($missing.Count -eq 0 -and $typeFailures.Count -eq 0))
    missing  = @($missing.ToArray())
    warnings = @($warnings.ToArray())
  }
}

function Get-DeliveryGateResult {
  param($InputFacts)

  $validation = Test-DeliveryGateInput -InputFacts $InputFacts
  $evidence = Get-DeliveryGateEvidenceList -InputFacts $InputFacts

  if (-not [bool]$validation.ok) {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    Add-DeliveryGateListItem -List $failures -Value 'invalid_input'
    foreach ($name in @($validation.missing)) {
      Add-DeliveryGateListItem -List $failures -Value ('missing:' + $name)
    }
    return New-DeliveryGateResult `
      -Ok $false `
      -MergeAllowed $false `
      -ReleaseAllowed $false `
      -Risk 'critical' `
      -Failures @($failures.ToArray()) `
      -Warnings @($validation.warnings) `
      -RequiredChecks @($script:DeliveryGateBoolInputEnum) `
      -Evidence $evidence `
      -CanaryRequired $false `
      -RollbackRequired $false `
      -Reason 'invalid input'
  }

  $facts = @{}
  foreach ($name in $script:DeliveryGateBoolInputEnum) {
    $facts[$name] = [bool]$InputFacts[$name]
  }

  $failures = New-Object 'System.Collections.Generic.List[string]'
  $warnings = New-Object 'System.Collections.Generic.List[string]'
  $requiredChecks = New-Object 'System.Collections.Generic.List[string]'

  foreach ($warning in @($validation.warnings)) {
    Add-DeliveryGateListItem -List $warnings -Value $warning
  }

  $ok = $true
  $mergeAllowed = $true
  $releaseAllowed = $true
  $canaryRequired = $false
  $rollbackRequired = $false

  if (-not $facts.memory_updated -and -not $facts.critical_bridge_self) {
    Add-DeliveryGateListItem -List $warnings -Value 'memory_update_missing'
    Add-DeliveryGateListItem -List $requiredChecks -Value 'memory_updated'
  }

  $risk = Get-DeliveryGateRisk -Facts $facts -Warnings @($warnings.ToArray())

  if ($facts.rollback_required) {
    $ok = $false
    $mergeAllowed = $false
    $releaseAllowed = $false
    $rollbackRequired = $true
    Add-DeliveryGateListItem -List $failures -Value 'rollback_required'
    Add-DeliveryGateListItem -List $requiredChecks -Value 'rollback_required'
  }

  if ($facts.forbidden_changes) {
    $ok = $false
    $mergeAllowed = $false
    $releaseAllowed = $false
    Add-DeliveryGateListItem -List $failures -Value 'forbidden_changes_detected'
    Add-DeliveryGateListItem -List $requiredChecks -Value 'forbidden_changes'
  }
  if ($facts.destructive_patterns) {
    $ok = $false
    $mergeAllowed = $false
    $releaseAllowed = $false
    Add-DeliveryGateListItem -List $failures -Value 'destructive_patterns_detected'
    Add-DeliveryGateListItem -List $requiredChecks -Value 'destructive_patterns'
  }
  if ($facts.quality_bypass_detected) {
    $ok = $false
    $mergeAllowed = $false
    $releaseAllowed = $false
    Add-DeliveryGateListItem -List $failures -Value 'quality_bypass_detected'
    Add-DeliveryGateListItem -List $requiredChecks -Value 'quality_bypass_detected'
  }

  if (-not $facts.parse_ok) {
    $ok = $false
    $mergeAllowed = $false
    $releaseAllowed = $false
    Add-DeliveryGateListItem -List $failures -Value 'parse_failed'
    Add-DeliveryGateListItem -List $requiredChecks -Value 'parse_ok'
  }
  if (-not $facts.tests_ok) {
    $ok = $false
    $mergeAllowed = $false
    $releaseAllowed = $false
    Add-DeliveryGateListItem -List $failures -Value 'tests_failed'
    Add-DeliveryGateListItem -List $requiredChecks -Value 'tests_ok'
  }
  if (-not $facts.smoke_ok) {
    $ok = $false
    $mergeAllowed = $false
    $releaseAllowed = $false
    Add-DeliveryGateListItem -List $failures -Value 'smoke_failed'
    Add-DeliveryGateListItem -List $requiredChecks -Value 'smoke_ok'
  }

  if (-not $facts.review_board_ok) {
    $ok = $false
    $mergeAllowed = $false
    $releaseAllowed = $false
    Add-DeliveryGateListItem -List $failures -Value 'review_board_rejected'
    Add-DeliveryGateListItem -List $requiredChecks -Value 'review_board_ok'
  }

  if (-not $facts.acceptance_ok) {
    $releaseAllowed = $false
    Add-DeliveryGateListItem -List $warnings -Value 'acceptance_pending'
    Add-DeliveryGateListItem -List $requiredChecks -Value 'acceptance_ok'
    if ($mergeAllowed) {
      $mergeAllowed = $true
    }
  }

  if (($risk -in @('high','critical')) -and -not $facts.parallel_obligation_ok) {
    $ok = $false
    $mergeAllowed = $false
    $releaseAllowed = $false
    Add-DeliveryGateListItem -List $failures -Value 'parallel_obligation_required'
    Add-DeliveryGateListItem -List $requiredChecks -Value 'parallel_obligation_ok'
  } elseif ($risk -eq 'normal' -and -not $facts.parallel_obligation_ok) {
    Add-DeliveryGateListItem -List $warnings -Value 'parallel_obligation_missing'
    Add-DeliveryGateListItem -List $requiredChecks -Value 'parallel_obligation_ok'
  }

  if ($facts.critical_bridge_self) {
    if (-not $facts.canary_ok) {
      $ok = $false
      $mergeAllowed = $false
      $releaseAllowed = $false
      $canaryRequired = $true
      Add-DeliveryGateListItem -List $failures -Value 'canary_failed'
      Add-DeliveryGateListItem -List $requiredChecks -Value 'canary_ok'
    }
    if (-not $facts.self_model_refreshed) {
      $ok = $false
      $mergeAllowed = $false
      $releaseAllowed = $false
      $canaryRequired = $true
      Add-DeliveryGateListItem -List $failures -Value 'self_model_refresh_required'
      Add-DeliveryGateListItem -List $requiredChecks -Value 'self_model_refreshed'
    }
  }

  if (-not $facts.memory_updated -and $facts.critical_bridge_self) {
    $ok = $false
    $mergeAllowed = $false
    $releaseAllowed = $false
    Add-DeliveryGateListItem -List $failures -Value 'memory_update_required'
    Add-DeliveryGateListItem -List $requiredChecks -Value 'memory_updated'
  }

  $risk = Get-DeliveryGateRisk -Facts $facts -Warnings @($warnings.ToArray())

  $reason = 'approved'
  if (@($failures.ToArray()).Count -gt 0) {
    $reason = ($failures.ToArray() -join ', ')
  } elseif (-not $releaseAllowed -and $mergeAllowed) {
    $reason = 'acceptance pending'
  } elseif (@($warnings.ToArray()).Count -gt 0) {
    $reason = 'approved with warnings'
  }

  return New-DeliveryGateResult `
    -Ok $ok `
    -MergeAllowed $mergeAllowed `
    -ReleaseAllowed $releaseAllowed `
    -Risk $risk `
    -Failures @($failures.ToArray()) `
    -Warnings @($warnings.ToArray()) `
    -RequiredChecks @($requiredChecks.ToArray()) `
    -Evidence $evidence `
    -CanaryRequired $canaryRequired `
    -RollbackRequired $rollbackRequired `
    -Reason $reason
}
