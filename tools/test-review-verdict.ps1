#Requires -Version 5.1
# test-review-verdict.ps1 -- fixtures for isolated structured review verdict helpers.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\review-verdict.ps1')

$script:pass = 0
$script:fail = 0

function Check {
  param(
    [string]$Name,
    [bool]$Condition,
    [object]$Actual = $null
  )
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:fail++
    $suffix = if ($null -ne $Actual) { " actual=" + ($Actual | ConvertTo-Json -Compress -Depth 8) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

function New-TestFinding {
  param(
    [string]$Severity = 'minor',
    [string]$File = 'lib/sample.ps1',
    [int]$Line = 10,
    [string]$Message = 'Sample finding',
    [bool]$RequiredFix = $true
  )

  return New-ReviewFinding `
    -Severity $Severity `
    -File $File `
    -Line $Line `
    -Message $Message `
    -RequiredFix $RequiredFix
}

function New-TestVerdict {
  param(
    [Parameter(Mandatory)][string]$Role,
    [string]$Verdict = 'pass',
    [double]$Confidence = 0.9,
    [object[]]$Findings = @(),
    [string]$AcceptanceImpact = 'none'
  )

  return New-ReviewVerdict `
    -Role $Role `
    -Verdict $Verdict `
    -Confidence $Confidence `
    -Findings $Findings `
    -AcceptanceImpact $AcceptanceImpact
}

function New-AllRoleVerdicts {
  param(
    [string]$Verdict = 'pass',
    [double]$Confidence = 0.9
  )

  $schema = Get-ReviewVerdictSchema
  $items = New-Object System.Collections.Generic.List[object]
  foreach ($role in $schema.roles) {
    [void]$items.Add((New-TestVerdict -Role $role -Verdict $Verdict -Confidence $Confidence))
  }
  return @($items.ToArray())
}

$allPassDecision = Get-ReviewBoardDecision -Verdicts (New-AllRoleVerdicts)
Check 'all roles pass ok' ([bool]$allPassDecision.ok) $allPassDecision
Check 'all roles pass merge allowed' ([bool]$allPassDecision.merge_allowed) $allPassDecision
Check 'all roles pass release allowed' ([bool]$allPassDecision.release_allowed) $allPassDecision

$warnOnlyDecision = Get-ReviewBoardDecision -Verdicts (New-AllRoleVerdicts -Verdict 'warn' -Confidence 0.8)
Check 'warn only ok' ([bool]$warnOnlyDecision.ok) $warnOnlyDecision
Check 'warn only warnings present' (@($warnOnlyDecision.warnings).Count -gt 0) $warnOnlyDecision
Check 'warn only merge allowed' ([bool]$warnOnlyDecision.merge_allowed) $warnOnlyDecision
Check 'warn only release allowed' ([bool]$warnOnlyDecision.release_allowed) $warnOnlyDecision

$blockerDecision = Get-ReviewBoardDecision -Verdicts @(
  (New-TestVerdict -Role 'code' -Findings @(
      (New-TestFinding -Severity 'blocker' -File 'lib/review-verdict.ps1' -Line 42 -Message 'Blocking regression' -RequiredFix $true)
    ))
)
Check 'blocker finding merge denied' (-not [bool]$blockerDecision.merge_allowed) $blockerDecision
Check 'blocker finding release denied' (-not [bool]$blockerDecision.release_allowed) $blockerDecision

$securityFailDecision = Get-ReviewBoardDecision -Verdicts @(
  (New-TestVerdict -Role 'security' -Verdict 'fail')
)
Check 'security fail merge denied' (-not [bool]$securityFailDecision.merge_allowed) $securityFailDecision
Check 'security fail release denied' (-not [bool]$securityFailDecision.release_allowed) $securityFailDecision

$acceptanceFailDecision = Get-ReviewBoardDecision -Verdicts @(
  (New-TestVerdict -Role 'acceptance' -Verdict 'fail')
)
Check 'acceptance fail release denied' (-not [bool]$acceptanceFailDecision.release_allowed) $acceptanceFailDecision
Check 'acceptance fail merge still allowed' ([bool]$acceptanceFailDecision.merge_allowed) $acceptanceFailDecision

$securityLowConfidenceDecision = Get-ReviewBoardDecision -Verdicts @(
  (New-TestVerdict -Role 'security' -Confidence 0.3)
)
Check 'security low confidence role listed' (@($securityLowConfidenceDecision.low_confidence_roles) -contains 'security') $securityLowConfidenceDecision
Check 'security low confidence action listed' ((@($securityLowConfidenceDecision.required_actions) | Where-Object { $_ -match 'security' }).Count -gt 0) $securityLowConfidenceDecision

$acceptanceLowConfidenceDecision = Get-ReviewBoardDecision -Verdicts @(
  (New-TestVerdict -Role 'acceptance' -Confidence 0.4)
)
Check 'acceptance low confidence role listed' (@($acceptanceLowConfidenceDecision.low_confidence_roles) -contains 'acceptance') $acceptanceLowConfidenceDecision
Check 'acceptance low confidence action listed' ((@($acceptanceLowConfidenceDecision.required_actions) | Where-Object { $_ -match 'acceptance' }).Count -gt 0) $acceptanceLowConfidenceDecision

$malformedVerdict = Test-ReviewVerdict -Verdict ([ordered]@{
    role = 'code'
  })
Check 'malformed verdict rejected' (-not [bool]$malformedVerdict.ok) $malformedVerdict
Check 'malformed verdict blockers present' (@($malformedVerdict.blockers).Count -gt 0) $malformedVerdict

$unknownRoleVerdict = Test-ReviewVerdict -Verdict ([ordered]@{
    role              = 'ops'
    verdict           = 'pass'
    confidence        = 0.8
    findings          = @()
    acceptance_impact = 'none'
  })
Check 'unknown role rejected' (-not [bool]$unknownRoleVerdict.ok) $unknownRoleVerdict

$unknownVerdictValue = Test-ReviewVerdict -Verdict ([ordered]@{
    role              = 'code'
    verdict           = 'ship-it'
    confidence        = 0.8
    findings          = @()
    acceptance_impact = 'none'
  })
Check 'unknown verdict rejected' (-not [bool]$unknownVerdictValue.ok) $unknownVerdictValue

$unknownSeverityRejected = $false
try {
  [void](New-TestFinding -Severity 'critical')
} catch {
  $unknownSeverityRejected = $true
}
Check 'unknown severity rejected' $unknownSeverityRejected

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
