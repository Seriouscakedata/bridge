#Requires -Version 5.1
# test-delivery-gate.ps1 -- fixtures for the isolated Delivery Gate validator.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\delivery-gate.ps1')

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
    $suffix = if ($null -ne $Actual) { " actual=" + ($Actual | ConvertTo-Json -Compress -Depth 6) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

function Check-ResultShape {
  param([string]$Name, $Result)
  $schema = Get-DeliveryGateSchema
  foreach ($key in $schema.output.Keys) {
    Check "$Name has $key" ($null -ne $Result.PSObject.Properties[$key]) $Result
  }
  Check "$Name failures is array" ($Result.failures -is [array]) $Result
  Check "$Name warnings is array" ($Result.warnings -is [array]) $Result
  Check "$Name required_checks is array" ($Result.required_checks -is [array]) $Result
  Check "$Name evidence is array" ($Result.evidence -is [array]) $Result
}

function New-GreenFacts {
  return [ordered]@{
    repo_clean             = $true
    forbidden_changes      = $false
    destructive_patterns   = $false
    parse_ok               = $true
    tests_ok               = $true
    smoke_ok               = $true
    acceptance_ok          = $true
    review_board_ok        = $true
    parallel_obligation_ok = $true
    memory_updated         = $true
    self_model_refreshed   = $true
    critical_bridge_self   = $false
    canary_ok              = $true
    quality_bypass_detected = $false
    rollback_required      = $false
    evidence               = "parser=ok`ntests=ok"
  }
}

$allGreen = Get-DeliveryGateResult -InputFacts (New-GreenFacts)
Check-ResultShape 'all green' $allGreen
Check '1 all green ok' ([bool]$allGreen.ok) $allGreen
Check '1 all green merge true' ([bool]$allGreen.merge_allowed) $allGreen
Check '1 all green release true' ([bool]$allGreen.release_allowed) $allGreen
Check '1 all green low-normal risk' (@('low','normal') -contains [string]$allGreen.risk) $allGreen

$parseFailFacts = New-GreenFacts
$parseFailFacts.parse_ok = $false
$parseFail = Get-DeliveryGateResult -InputFacts $parseFailFacts
Check '2 parse fail not ok' (-not [bool]$parseFail.ok) $parseFail
Check '2 parse fail has parse failure' ((@($parseFail.failures) | Where-Object { $_ -match 'parse' }).Count -gt 0) $parseFail

$testsFailFacts = New-GreenFacts
$testsFailFacts.tests_ok = $false
$testsFail = Get-DeliveryGateResult -InputFacts $testsFailFacts
Check '3 tests fail not ok' (-not [bool]$testsFail.ok) $testsFail

$smokeFailFacts = New-GreenFacts
$smokeFailFacts.smoke_ok = $false
$smokeFail = Get-DeliveryGateResult -InputFacts $smokeFailFacts
Check '4 smoke fail not ok' (-not [bool]$smokeFail.ok) $smokeFail

$forbiddenFacts = New-GreenFacts
$forbiddenFacts.forbidden_changes = $true
$forbidden = Get-DeliveryGateResult -InputFacts $forbiddenFacts
Check '5 forbidden changes not ok' (-not [bool]$forbidden.ok) $forbidden
Check '5 forbidden changes merge false' (-not [bool]$forbidden.merge_allowed) $forbidden

$bypassFacts = New-GreenFacts
$bypassFacts.quality_bypass_detected = $true
$bypass = Get-DeliveryGateResult -InputFacts $bypassFacts
Check '6 quality bypass not ok' (-not [bool]$bypass.ok) $bypass

$acceptanceFacts = New-GreenFacts
$acceptanceFacts.acceptance_ok = $false
$acceptance = Get-DeliveryGateResult -InputFacts $acceptanceFacts
Check '7 acceptance pending keeps ok' ([bool]$acceptance.ok) $acceptance
Check '7 acceptance pending release false' (-not [bool]$acceptance.release_allowed) $acceptance
Check '7 acceptance pending merge true' ([bool]$acceptance.merge_allowed) $acceptance

$reviewFacts = New-GreenFacts
$reviewFacts.review_board_ok = $false
$review = Get-DeliveryGateResult -InputFacts $reviewFacts
Check '8 review fail not ok' (-not [bool]$review.ok) $review
Check '8 review fail merge false' (-not [bool]$review.merge_allowed) $review

$parallelWarnFacts = New-GreenFacts
$parallelWarnFacts.memory_updated = $false
$parallelWarnFacts.parallel_obligation_ok = $false
$parallelWarn = Get-DeliveryGateResult -InputFacts $parallelWarnFacts
Check '9 parallel warning still ok' ([bool]$parallelWarn.ok) $parallelWarn
Check '9 parallel warning risk normal' ([string]$parallelWarn.risk -eq 'normal') $parallelWarn
Check '9 parallel warning present' ((@($parallelWarn.warnings) | Where-Object { $_ -match 'parallel' }).Count -gt 0) $parallelWarn

$parallelFailFacts = New-GreenFacts
$parallelFailFacts.acceptance_ok = $false
$parallelFailFacts.parallel_obligation_ok = $false
$parallelFail = Get-DeliveryGateResult -InputFacts $parallelFailFacts
Check '10 parallel high risk not ok' (-not [bool]$parallelFail.ok) $parallelFail
Check '10 parallel high risk failure present' ((@($parallelFail.failures) | Where-Object { $_ -match 'parallel' }).Count -gt 0) $parallelFail

$canaryFacts = New-GreenFacts
$canaryFacts.critical_bridge_self = $true
$canaryFacts.canary_ok = $false
$canary = Get-DeliveryGateResult -InputFacts $canaryFacts
Check '11 canary fail not ok' (-not [bool]$canary.ok) $canary
Check '11 canary required true' ([bool]$canary.canary_required) $canary
Check '11 canary failures not empty' (@($canary.failures).Count -gt 0) $canary

$selfModelFacts = New-GreenFacts
$selfModelFacts.critical_bridge_self = $true
$selfModelFacts.self_model_refreshed = $false
$selfModel = Get-DeliveryGateResult -InputFacts $selfModelFacts
Check '12 self model fail not ok' (-not [bool]$selfModel.ok) $selfModel

$memoryWarnFacts = New-GreenFacts
$memoryWarnFacts.memory_updated = $false
$memoryWarn = Get-DeliveryGateResult -InputFacts $memoryWarnFacts
Check '13 memory warning present' ((@($memoryWarn.warnings) | Where-Object { $_ -match 'memory' }).Count -gt 0) $memoryWarn

$memoryFailFacts = New-GreenFacts
$memoryFailFacts.critical_bridge_self = $true
$memoryFailFacts.memory_updated = $false
$memoryFail = Get-DeliveryGateResult -InputFacts $memoryFailFacts
Check '14 memory fail present' ((@($memoryFail.failures) | Where-Object { $_ -match 'memory' }).Count -gt 0) $memoryFail

$rollbackFacts = New-GreenFacts
$rollbackFacts.rollback_required = $true
$rollback = Get-DeliveryGateResult -InputFacts $rollbackFacts
Check '15 rollback not ok' (-not [bool]$rollback.ok) $rollback
Check '15 rollback true' ([bool]$rollback.rollback_required) $rollback

$nullResult = Get-DeliveryGateResult -InputFacts $null
Check-ResultShape 'null input' $nullResult
Check '16 null input not ok' (-not [bool]$nullResult.ok) $nullResult

$emptyResult = Get-DeliveryGateResult -InputFacts @{}
Check-ResultShape 'empty input' $emptyResult
Check '17 empty input not ok' (-not [bool]$emptyResult.ok) $emptyResult

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
