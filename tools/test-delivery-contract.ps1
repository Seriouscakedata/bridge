#Requires -Version 5.1
# test-delivery-contract.ps1 -- fixtures for the isolated Delivery Contract validator.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\delivery-contract.ps1')

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
  $schema = Get-DeliveryContractSchema
  foreach ($key in $schema.Keys) {
    Check "$Name has $key" ($null -ne $Result.PSObject.Properties[$key]) $Result
  }
  Check "$Name score in range" ($Result.score -is [int] -and $Result.score -ge 0 -and $Result.score -le 100) $Result
  Check "$Name missing is array" ($Result.missing -is [array]) $Result
  Check "$Name warnings is array" ($Result.warnings -is [array]) $Result
  Check "$Name blockers is array" ($Result.blockers -is [array]) $Result
  Check "$Name required_sections is array" ($Result.required_sections -is [array]) $Result
}

function New-DeepContract {
  return [ordered]@{
    goal                 = 'Ship a deterministic delivery contract validator for isolated worker execution.'
    non_goals            = 'Do not modify the live driver, stateful layers, or any unsafe restart controls.'
    roles                = 'Bridge operators and parallel coder workers need contract feedback before implementation.'
    routes               = 'Worker prompt surface, result summary surface, and contract review path are covered.'
    backend              = 'Input is only the contract object and optional context; no live backend mutation is allowed.'
    acceptance_scenarios = 'Given a deep contract, the validator returns ok true, high score, and no missing sections.'
    checks               = 'Parser.ParseFile passes for both scripts and the dedicated PowerShell harness exits cleanly.'
    risk                 = 'Primary risk is a shallow contract passing despite missing actionable implementation detail.'
    parallel_policy      = 'One isolated worker owns the atom; parallel streams must not share mutable delivery paths.'
  }
}

$full = Test-DeliveryContract -Contract (New-DeepContract)
Check-ResultShape 'full contract' $full
Check 'full contract ok' ([bool]$full.ok) $full
Check 'full contract high score' ([int]$full.score -ge 80) $full
Check 'full contract missing empty' (@($full.missing).Count -eq 0) $full

$missingAcceptanceContract = New-DeepContract
$missingAcceptanceContract.Remove('acceptance_scenarios')
$missingAcceptance = Test-DeliveryContract -Contract $missingAcceptanceContract
Check-ResultShape 'missing acceptance' $missingAcceptance
Check 'missing acceptance not ok' (-not [bool]$missingAcceptance.ok) $missingAcceptance
Check 'missing acceptance blocker present' (@($missingAcceptance.blockers) -contains 'acceptance_scenarios') $missingAcceptance
Check 'missing acceptance missing present' (@($missingAcceptance.missing) -contains 'acceptance_scenarios') $missingAcceptance

$missingSurfaceContract = New-DeepContract
$missingSurfaceContract.Remove('routes')
$missingSurface = Test-DeliveryContract -Contract $missingSurfaceContract
Check-ResultShape 'missing surfaces' $missingSurface
Check 'missing surfaces not ok' (-not [bool]$missingSurface.ok) $missingSurface
Check 'missing surfaces missing present' (@($missingSurface.missing) -contains 'surfaces/routes/screens') $missingSurface

$shallowContract = [ordered]@{
  goal                 = 'tiny'
  scope                = 'small'
  users                = 'few'
  surfaces             = 'cli'
  data                 = 'obj'
  acceptance_scenarios = 'pass'
  checks               = 'run'
  risk                 = 'low'
  parallel_policy      = 'solo'
}
$shallow = Test-DeliveryContract -Contract $shallowContract
Check-ResultShape 'shallow strings' $shallow
Check 'shallow strings low score' ([int]$shallow.score -lt 50) $shallow
Check 'shallow strings warnings present' (@($shallow.warnings).Count -gt 0) $shallow
Check 'shallow strings not ok' (-not [bool]$shallow.ok) $shallow
Check 'shallow strings no missing sections' (@($shallow.missing).Count -eq 0) $shallow

$bridgeSelfContract = [ordered]@{
  goal                 = 'Tighten bridge-self delivery policy checks without changing any live execution path.'
  scope                = 'Only isolated validator behavior and its harness are in scope for this worker atom.'
  users                = 'Bridge maintainers need canary-safe contract validation for self-modifying tasks.'
  data                 = 'Only contract facts are inspected; runtime channels and repos stay untouched.'
  acceptance_scenarios = 'Given a bridge-self contract with critical paths and canary checks, validator returns ok.'
  checks               = 'Run parser validation, focused harness execution, and bridge self canary verification.'
  risk                 = 'Bridge self changes can break routing, so the contract must declare critical path coverage.'
  parallel_policy      = 'Bridge-self work stays isolated and must never trigger restart markers across worktrees.'
  critical_paths       = 'driver/81 and related guard paths are called out explicitly for canary-safe validation.'
  canary               = 'A bridge-self canary check must pass before any promotion or integration step is allowed.'
}
$bridgeSelf = Test-DeliveryContract -Contract $bridgeSelfContract -Context @{ IsBridgeSelf = $true }
Check-ResultShape 'bridge self omission' $bridgeSelf
Check 'bridge self omission ok' ([bool]$bridgeSelf.ok) $bridgeSelf
Check 'bridge self omission keeps surfaces optional' (-not (@($bridgeSelf.missing) -contains 'surfaces/routes/screens')) $bridgeSelf
Check 'bridge self required sections include critical paths' (@($bridgeSelf.required_sections) -contains 'critical_paths') $bridgeSelf
Check 'bridge self required sections include canary' (@($bridgeSelf.required_sections) -contains 'canary') $bridgeSelf

$missingParallelContract = New-DeepContract
$missingParallelContract.Remove('parallel_policy')
$missingParallel = Test-DeliveryContract -Contract $missingParallelContract
Check-ResultShape 'missing parallel policy' $missingParallel
Check 'missing parallel policy still ok' ([bool]$missingParallel.ok) $missingParallel
Check 'missing parallel policy listed as missing' (@($missingParallel.missing) -contains 'parallel_policy') $missingParallel
Check 'missing parallel policy warning present' ((@($missingParallel.warnings) | Where-Object { $_ -match 'parallel_policy' }).Count -gt 0) $missingParallel

$extraContract = New-DeepContract
$extraContract['extra_field'] = 'ignored metadata should not break the contract validator result.'
$extra = Test-DeliveryContract -Contract $extraContract
Check-ResultShape 'unknown extras' $extra
Check 'unknown extras still ok' ([bool]$extra.ok) $extra

$nullContract = Test-DeliveryContract -Contract $null
Check-ResultShape 'null contract' $nullContract
Check 'null contract not ok' (-not [bool]$nullContract.ok) $nullContract
Check 'null contract empty blocker' (@($nullContract.blockers) -contains 'empty_contract') $nullContract

$emptyContract = Test-DeliveryContract -Contract @{}
Check-ResultShape 'empty contract' $emptyContract
Check 'empty contract not ok' (-not [bool]$emptyContract.ok) $emptyContract
Check 'empty contract empty blocker' (@($emptyContract.blockers) -contains 'empty_contract') $emptyContract

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
