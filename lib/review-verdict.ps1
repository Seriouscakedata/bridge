# review-verdict.ps1 -- pure read-only structured review verdict helpers.
#
# This file is intentionally isolated from the live driver. It does not write
# files, mutate runtime state, call models/APIs, or authorize execution. It only
# validates review findings/verdicts and derives a deterministic board decision.

$script:ReviewVerdictRoleEnum = @(
  'architect',
  'code',
  'security',
  'regression',
  'acceptance',
  'memory_selfmodel',
  'parallel'
)

$script:ReviewVerdictVerdictEnum = @(
  'pass',
  'warn',
  'fail'
)

$script:ReviewVerdictSeverityEnum = @(
  'blocker',
  'major',
  'minor',
  'info'
)

$script:ReviewVerdictAcceptanceImpactEnum = @(
  'none',
  'partial',
  'blocking'
)

function Get-ReviewVerdictSchema {
  return [ordered]@{
    roles              = @($script:ReviewVerdictRoleEnum)
    verdicts           = @($script:ReviewVerdictVerdictEnum)
    severities         = @($script:ReviewVerdictSeverityEnum)
    acceptance_impacts = @($script:ReviewVerdictAcceptanceImpactEnum)
    finding            = [ordered]@{
      severity     = 'string enum'
      file         = 'string'
      line         = 'int'
      message      = 'string non-empty'
      required_fix = 'bool'
    }
    verdict            = [ordered]@{
      role              = 'string enum'
      verdict           = 'string enum'
      confidence        = 'double 0.0..1.0'
      findings          = 'finding[]'
      acceptance_impact = 'string enum'
    }
    board_decision     = [ordered]@{
      ok                   = 'bool'
      merge_allowed        = 'bool'
      release_allowed      = 'bool'
      blockers             = 'string[]'
      warnings             = 'string[]'
      role_status          = 'hashtable role->verdict'
      low_confidence_roles = 'string[]'
      required_actions     = 'string[]'
    }
  }
}

function Find-ReviewVerdictValue {
  param($Object, [string[]]$Names)
  if ($null -eq $Object) {
    return [pscustomobject][ordered]@{
      found = $false
      name  = ''
      value = $null
    }
  }

  foreach ($name in $Names) {
    if ($Object -is [hashtable] -and $Object.ContainsKey($name)) {
      return [pscustomobject][ordered]@{
        found = $true
        name  = $name
        value = $Object[$name]
      }
    }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) {
      return [pscustomobject][ordered]@{
        found = $true
        name  = $name
        value = $Object[$name]
      }
    }
    $prop = $Object.PSObject.Properties[$name]
    if ($null -ne $prop) {
      return [pscustomobject][ordered]@{
        found = $true
        name  = $name
        value = $prop.Value
      }
    }
  }

  return [pscustomobject][ordered]@{
    found = $false
    name  = ''
    value = $null
  }
}

function Add-ReviewVerdictIssue {
  param(
    [Parameter(Mandatory)]$List,
    [string]$Value
  )
  if ([string]::IsNullOrWhiteSpace($Value)) { return }
  if (-not $List.Contains($Value)) {
    [void]$List.Add($Value)
  }
}

function Test-ReviewVerdictStringEnumValue {
  param(
    [string]$Value,
    [string[]]$Enum
  )
  if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
  return ($Enum -contains $Value.Trim())
}

function Test-ReviewVerdictIntegerValue {
  param($Value)
  return (
    $Value -is [byte] -or
    $Value -is [sbyte] -or
    $Value -is [int16] -or
    $Value -is [uint16] -or
    $Value -is [int32] -or
    $Value -is [uint32] -or
    $Value -is [int64] -or
    $Value -is [uint64]
  )
}

function Test-ReviewVerdictNumericValue {
  param($Value)
  return (
    (Test-ReviewVerdictIntegerValue -Value $Value) -or
    $Value -is [single] -or
    $Value -is [double] -or
    $Value -is [decimal]
  )
}

function Test-ReviewVerdictStrictBooleanValue {
  param($Value)
  return ($Value -is [bool])
}

function Test-ReviewFindingInternal {
  param($Finding)

  $missing = New-Object System.Collections.Generic.List[string]
  $blockers = New-Object System.Collections.Generic.List[string]

  if ($null -eq $Finding) {
    Add-ReviewVerdictIssue -List $missing -Value 'finding'
    Add-ReviewVerdictIssue -List $blockers -Value 'finding is null'
    return [ordered]@{
      ok       = $false
      missing  = @($missing.ToArray())
      blockers = @($blockers.ToArray())
    }
  }

  $severity = Find-ReviewVerdictValue -Object $Finding -Names @('severity','Severity')
  if (-not $severity.found) {
    Add-ReviewVerdictIssue -List $missing -Value 'severity'
  } elseif ($severity.value -isnot [string]) {
    Add-ReviewVerdictIssue -List $blockers -Value 'severity must be a string'
  } elseif (-not (Test-ReviewVerdictStringEnumValue -Value ([string]$severity.value) -Enum $script:ReviewVerdictSeverityEnum)) {
    Add-ReviewVerdictIssue -List $blockers -Value ('unknown severity: ' + [string]$severity.value)
  }

  $file = Find-ReviewVerdictValue -Object $Finding -Names @('file','File')
  if (-not $file.found) {
    Add-ReviewVerdictIssue -List $missing -Value 'file'
  } elseif ($file.value -isnot [string]) {
    Add-ReviewVerdictIssue -List $blockers -Value 'file must be a string'
  }

  $line = Find-ReviewVerdictValue -Object $Finding -Names @('line','Line')
  if (-not $line.found) {
    Add-ReviewVerdictIssue -List $missing -Value 'line'
  } elseif (-not (Test-ReviewVerdictIntegerValue -Value $line.value)) {
    Add-ReviewVerdictIssue -List $blockers -Value 'line must be an int'
  }

  $message = Find-ReviewVerdictValue -Object $Finding -Names @('message','Message')
  if (-not $message.found) {
    Add-ReviewVerdictIssue -List $missing -Value 'message'
  } elseif ($message.value -isnot [string]) {
    Add-ReviewVerdictIssue -List $blockers -Value 'message must be a string'
  } elseif ([string]::IsNullOrWhiteSpace([string]$message.value)) {
    Add-ReviewVerdictIssue -List $blockers -Value 'message must be non-empty'
  }

  $requiredFix = Find-ReviewVerdictValue -Object $Finding -Names @('required_fix','RequiredFix','requiredFix')
  if (-not $requiredFix.found) {
    Add-ReviewVerdictIssue -List $missing -Value 'required_fix'
  } elseif (-not (Test-ReviewVerdictStrictBooleanValue -Value $requiredFix.value)) {
    Add-ReviewVerdictIssue -List $blockers -Value 'required_fix must be a bool'
  }

  if ($missing.Count -gt 0) {
    Add-ReviewVerdictIssue -List $blockers -Value 'finding missing required fields'
  }

  return [ordered]@{
    ok       = ($missing.Count -eq 0 -and $blockers.Count -eq 0)
    missing  = @($missing.ToArray())
    blockers = @($blockers.ToArray())
  }
}

function New-ReviewFinding {
  param(
    [Parameter(Mandatory)][string]$Severity,
    [Parameter(Mandatory)][string]$File,
    [Parameter(Mandatory)][int]$Line,
    [Parameter(Mandatory)][string]$Message,
    [Parameter(Mandatory)][bool]$RequiredFix
  )

  if (-not (Test-ReviewVerdictStringEnumValue -Value $Severity -Enum $script:ReviewVerdictSeverityEnum)) {
    throw "Unknown review finding severity: $Severity"
  }
  if ([string]::IsNullOrWhiteSpace($Message)) {
    throw 'Review finding message must be non-empty'
  }

  $finding = [pscustomobject][ordered]@{
    severity     = $Severity.Trim()
    file         = $File
    line         = $Line
    message      = $Message
    required_fix = $RequiredFix
  }

  $validation = Test-ReviewFindingInternal -Finding $finding
  if (-not $validation.ok) {
    throw ('Invalid review finding: ' + (($validation.blockers + $validation.missing) -join '; '))
  }

  return $finding
}

function New-ReviewVerdict {
  param(
    [Parameter(Mandatory)][string]$Role,
    [Parameter(Mandatory)][string]$Verdict,
    [Parameter(Mandatory)][double]$Confidence,
    [object[]]$Findings = @(),
    [Parameter(Mandatory)][string]$AcceptanceImpact
  )

  if (-not (Test-ReviewVerdictStringEnumValue -Value $Role -Enum $script:ReviewVerdictRoleEnum)) {
    throw "Unknown review verdict role: $Role"
  }
  if (-not (Test-ReviewVerdictStringEnumValue -Value $Verdict -Enum $script:ReviewVerdictVerdictEnum)) {
    throw "Unknown review verdict value: $Verdict"
  }
  if ($Confidence -lt 0.0 -or $Confidence -gt 1.0) {
    throw "Review verdict confidence out of range: $Confidence"
  }
  if (-not (Test-ReviewVerdictStringEnumValue -Value $AcceptanceImpact -Enum $script:ReviewVerdictAcceptanceImpactEnum)) {
    throw "Unknown acceptance impact: $AcceptanceImpact"
  }

  $normalizedFindings = New-Object System.Collections.Generic.List[object]
  foreach ($finding in @($Findings)) {
    $validation = Test-ReviewFindingInternal -Finding $finding
    if (-not $validation.ok) {
      throw ('Invalid finding supplied to review verdict: ' + (($validation.blockers + $validation.missing) -join '; '))
    }
    [void]$normalizedFindings.Add($finding)
  }

  $reviewVerdict = [pscustomobject][ordered]@{
    role              = $Role.Trim()
    verdict           = $Verdict.Trim()
    confidence        = [double]$Confidence
    findings          = @($normalizedFindings.ToArray())
    acceptance_impact = $AcceptanceImpact.Trim()
  }

  $validation = Test-ReviewVerdict -Verdict $reviewVerdict
  if (-not $validation.ok) {
    throw ('Invalid review verdict: ' + (($validation.blockers + $validation.missing) -join '; '))
  }

  return $reviewVerdict
}

function Test-ReviewVerdict {
  param($Verdict)

  $missing = New-Object System.Collections.Generic.List[string]
  $blockers = New-Object System.Collections.Generic.List[string]

  if ($null -eq $Verdict) {
    Add-ReviewVerdictIssue -List $missing -Value 'verdict'
    Add-ReviewVerdictIssue -List $blockers -Value 'verdict is null'
    return [ordered]@{
      ok       = $false
      missing  = @($missing.ToArray())
      blockers = @($blockers.ToArray())
    }
  }

  $role = Find-ReviewVerdictValue -Object $Verdict -Names @('role','Role')
  if (-not $role.found) {
    Add-ReviewVerdictIssue -List $missing -Value 'role'
  } elseif ($role.value -isnot [string]) {
    Add-ReviewVerdictIssue -List $blockers -Value 'role must be a string'
  } elseif (-not (Test-ReviewVerdictStringEnumValue -Value ([string]$role.value) -Enum $script:ReviewVerdictRoleEnum)) {
    Add-ReviewVerdictIssue -List $blockers -Value ('unknown role: ' + [string]$role.value)
  }

  $verdictValue = Find-ReviewVerdictValue -Object $Verdict -Names @('verdict','Verdict')
  if (-not $verdictValue.found) {
    Add-ReviewVerdictIssue -List $missing -Value 'verdict'
  } elseif ($verdictValue.value -isnot [string]) {
    Add-ReviewVerdictIssue -List $blockers -Value 'verdict must be a string'
  } elseif (-not (Test-ReviewVerdictStringEnumValue -Value ([string]$verdictValue.value) -Enum $script:ReviewVerdictVerdictEnum)) {
    Add-ReviewVerdictIssue -List $blockers -Value ('unknown verdict: ' + [string]$verdictValue.value)
  }

  $confidence = Find-ReviewVerdictValue -Object $Verdict -Names @('confidence','Confidence')
  if (-not $confidence.found) {
    Add-ReviewVerdictIssue -List $missing -Value 'confidence'
  } elseif (-not (Test-ReviewVerdictNumericValue -Value $confidence.value)) {
    Add-ReviewVerdictIssue -List $blockers -Value 'confidence must be numeric'
  } elseif ([double]$confidence.value -lt 0.0 -or [double]$confidence.value -gt 1.0) {
    Add-ReviewVerdictIssue -List $blockers -Value ('confidence out of range: ' + [string]$confidence.value)
  }

  $findings = Find-ReviewVerdictValue -Object $Verdict -Names @('findings','Findings')
  $findingItems = @()
  if (-not $findings.found) {
    Add-ReviewVerdictIssue -List $missing -Value 'findings'
  } elseif ($null -eq $findings.value) {
    Add-ReviewVerdictIssue -List $blockers -Value 'findings must be an array'
  } elseif ($findings.value -is [string] -or $findings.value -isnot [System.Collections.IEnumerable]) {
    Add-ReviewVerdictIssue -List $blockers -Value 'findings must be an array'
  } else {
    $findingItems = @($findings.value)
    for ($i = 0; $i -lt $findingItems.Count; $i++) {
      $findingValidation = Test-ReviewFindingInternal -Finding $findingItems[$i]
      foreach ($field in @($findingValidation.missing)) {
        Add-ReviewVerdictIssue -List $missing -Value ('findings[' + $i + '].' + $field)
      }
      foreach ($issue in @($findingValidation.blockers)) {
        Add-ReviewVerdictIssue -List $blockers -Value ('findings[' + $i + ']: ' + $issue)
      }
    }
  }

  $acceptanceImpact = Find-ReviewVerdictValue -Object $Verdict -Names @('acceptance_impact','AcceptanceImpact','acceptanceImpact')
  if (-not $acceptanceImpact.found) {
    Add-ReviewVerdictIssue -List $missing -Value 'acceptance_impact'
  } elseif ($acceptanceImpact.value -isnot [string]) {
    Add-ReviewVerdictIssue -List $blockers -Value 'acceptance_impact must be a string'
  } elseif (-not (Test-ReviewVerdictStringEnumValue -Value ([string]$acceptanceImpact.value) -Enum $script:ReviewVerdictAcceptanceImpactEnum)) {
    Add-ReviewVerdictIssue -List $blockers -Value ('unknown acceptance_impact: ' + [string]$acceptanceImpact.value)
  }

  if ($missing.Count -gt 0) {
    Add-ReviewVerdictIssue -List $blockers -Value 'verdict missing required fields'
  }

  return [ordered]@{
    ok       = ($missing.Count -eq 0 -and $blockers.Count -eq 0)
    missing  = @($missing.ToArray())
    blockers = @($blockers.ToArray())
  }
}

function New-ReviewBoardDecision {
  param(
    [Parameter(Mandatory)][bool]$Ok,
    [Parameter(Mandatory)][bool]$MergeAllowed,
    [Parameter(Mandatory)][bool]$ReleaseAllowed,
    [string[]]$Blockers = @(),
    [string[]]$Warnings = @(),
    $RoleStatus = $null,
    [string[]]$LowConfidenceRoles = @(),
    [string[]]$RequiredActions = @()
  )

  $status = [ordered]@{}
  if ($null -ne $RoleStatus) {
    foreach ($entry in $RoleStatus.GetEnumerator()) {
      $status[[string]$entry.Key] = [string]$entry.Value
    }
  }

  return [pscustomobject][ordered]@{
    ok                   = $Ok
    merge_allowed        = $MergeAllowed
    release_allowed      = $ReleaseAllowed
    blockers             = @($Blockers)
    warnings             = @($Warnings)
    role_status          = $status
    low_confidence_roles = @($LowConfidenceRoles)
    required_actions     = @($RequiredActions)
  }
}

function Get-ReviewBoardDecision {
  param([object[]]$Verdicts = @())

  $blockers = New-Object System.Collections.Generic.List[string]
  $warnings = New-Object System.Collections.Generic.List[string]
  $lowConfidenceRoles = New-Object System.Collections.Generic.List[string]
  $requiredActions = New-Object System.Collections.Generic.List[string]
  $roleStatus = [ordered]@{}

  if (@($Verdicts).Count -eq 0) {
    Add-ReviewVerdictIssue -List $blockers -Value 'no verdicts provided'
    return New-ReviewBoardDecision `
      -Ok $false `
      -MergeAllowed $false `
      -ReleaseAllowed $false `
      -Blockers @($blockers.ToArray()) `
      -Warnings @() `
      -RoleStatus $roleStatus `
      -LowConfidenceRoles @() `
      -RequiredActions @()
  }

  $mergeAllowed = $true
  $releaseAllowed = $true
  $validVerdictCount = 0
  $warnCount = 0
  $failCount = 0

  foreach ($reviewVerdict in @($Verdicts)) {
    $validation = Test-ReviewVerdict -Verdict $reviewVerdict
    if (-not $validation.ok) {
      foreach ($issue in @($validation.blockers)) {
        Add-ReviewVerdictIssue -List $blockers -Value ('invalid verdict: ' + $issue)
      }
      foreach ($field in @($validation.missing)) {
        Add-ReviewVerdictIssue -List $blockers -Value ('invalid verdict missing: ' + $field)
      }
      $mergeAllowed = $false
      $releaseAllowed = $false
      continue
    }

    $validVerdictCount++

    $role = [string](Find-ReviewVerdictValue -Object $reviewVerdict -Names @('role','Role')).value
    $verdictValue = [string](Find-ReviewVerdictValue -Object $reviewVerdict -Names @('verdict','Verdict')).value
    $confidence = [double](Find-ReviewVerdictValue -Object $reviewVerdict -Names @('confidence','Confidence')).value
    $findingItems = @((Find-ReviewVerdictValue -Object $reviewVerdict -Names @('findings','Findings')).value)

    $roleStatus[$role] = $verdictValue

    if ($verdictValue -eq 'warn') {
      $warnCount++
      Add-ReviewVerdictIssue -List $warnings -Value ($role + ' review returned warn')
    }
    if ($verdictValue -eq 'fail') {
      $failCount++
    }

    foreach ($finding in @($findingItems)) {
      $severity = [string](Find-ReviewVerdictValue -Object $finding -Names @('severity','Severity')).value
      if ($severity -eq 'blocker') {
        $mergeAllowed = $false
        $releaseAllowed = $false
        $file = [string](Find-ReviewVerdictValue -Object $finding -Names @('file','File')).value
        $line = [int](Find-ReviewVerdictValue -Object $finding -Names @('line','Line')).value
        Add-ReviewVerdictIssue -List $blockers -Value ($role + ': blocker finding at ' + $file + ':' + $line)
      }
    }

    if ($role -eq 'security' -and $verdictValue -eq 'fail') {
      $mergeAllowed = $false
      $releaseAllowed = $false
      Add-ReviewVerdictIssue -List $blockers -Value 'security review failed'
    }

    if ($role -eq 'acceptance' -and $verdictValue -eq 'fail') {
      $releaseAllowed = $false
      Add-ReviewVerdictIssue -List $blockers -Value 'acceptance review failed'
    }

    if ((@('security','acceptance','architect') -contains $role) -and $confidence -lt 0.5) {
      Add-ReviewVerdictIssue -List $lowConfidenceRoles -Value $role
      Add-ReviewVerdictIssue -List $requiredActions -Value ('re-review required: ' + $role)
      Add-ReviewVerdictIssue -List $warnings -Value ('low confidence: ' + $role)
    }
  }

  if ($validVerdictCount -eq 0) {
    Add-ReviewVerdictIssue -List $blockers -Value 'no valid verdicts provided'
  }

  if ($validVerdictCount -gt 0 -and $warnCount -eq $validVerdictCount -and $failCount -eq 0) {
    Add-ReviewVerdictIssue -List $warnings -Value 'all verdicts are warn'
  }

  $ok = ($blockers.Count -eq 0 -and $mergeAllowed -and $releaseAllowed -and $validVerdictCount -gt 0)

  return New-ReviewBoardDecision `
    -Ok $ok `
    -MergeAllowed $mergeAllowed `
    -ReleaseAllowed $releaseAllowed `
    -Blockers @($blockers.ToArray()) `
    -Warnings @($warnings.ToArray()) `
    -RoleStatus $roleStatus `
    -LowConfidenceRoles @($lowConfidenceRoles.ToArray()) `
    -RequiredActions @($requiredActions.ToArray())
}
