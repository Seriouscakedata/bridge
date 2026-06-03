#Requires -Version 5.1
# test-delivery-gate-facts.ps1 -- fixtures for the Delivery Gate shadow facts collector.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\delivery-gate-facts.ps1')

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

function New-TestRepo {
  $path = Join-Path $root ('tmp\delivery-gate-facts-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $path -Force | Out-Null
  & git -C $path init | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
  return $path
}

function Remove-TestRepo {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
  if ($null -eq $resolved) { return }
  $tmpRoot = Join-Path $root 'tmp'
  $resolvedTmp = Resolve-Path -LiteralPath $tmpRoot -ErrorAction SilentlyContinue
  if ($null -eq $resolvedTmp) { return }
  if ($resolved.Path.StartsWith($resolvedTmp.Path)) {
    Remove-Item -LiteralPath $resolved.Path -Recurse -Force
  }
}

function New-GreenFactsFromRepo {
  param([string]$RepoPath, $Events = @(), [string]$TaskText = 'bridge-self acceptance evidence: ParseFile, tests, smoke verified')
  return New-DeliveryGateInputFacts `
    -BridgeRoot $RepoPath `
    -TaskText $TaskText `
    -Channel 'main' `
    -Events $Events `
    -QaPassed $true `
    -CriticPassed $true `
    -ParsePassed $true `
    -SmokePassed $true `
    -AcceptancePassed $true `
    -MemoryUpdated $true `
    -SelfModelRefreshed $true `
    -ParallelObligationOk $true
}

$gitAvailable = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
$repo = $null

try {
  if ($gitAvailable) {
    $repo = New-TestRepo
    $facts = New-GreenFactsFromRepo -RepoPath $repo
    $schema = Get-DeliveryGateSchema

    foreach ($field in @($schema.input.required)) {
      Check "green facts has $field" ($facts.Contains($field)) $facts
      Check "green facts $field bool" ($facts[$field] -is [bool]) $facts
    }
    Check 'green facts evidence string' ($facts.Contains('evidence') -and $facts.evidence -is [string] -and -not [string]::IsNullOrWhiteSpace($facts.evidence)) $facts

    $gate = Get-DeliveryGateResult -InputFacts $facts
    Check 'green facts accepted by gate' ([bool]$gate.ok -and [bool]$gate.merge_allowed -and [bool]$gate.release_allowed) $gate

    Check 'repo clean helper true in clean temp repo' (Test-DeliveryGateRepoClean -BridgeRoot $repo) $repo
  } else {
    $threw = $false
    try { [void](Test-DeliveryGateRepoClean -BridgeRoot $root) } catch { $threw = $true }
    Check 'repo clean helper does not throw without git fixture' (-not $threw)
  }

  $criticalFacts = New-GreenFactsFromRepo `
    -RepoPath $(if ($gitAvailable) { $repo } else { $root }) `
    -Events @(@{ touched_files = @('driver/86-loop-completion.ps1') })
  Check 'critical driver completion path detected' ([bool]$criticalFacts.critical_bridge_self) $criticalFacts

  $externalFacts = New-DeliveryGateInputFacts `
    -BridgeRoot $(if ($gitAvailable) { $repo } else { $root }) `
    -TaskText 'external project acceptance verified with tests and smoke' `
    -Channel 'client-app' `
    -Events @(@{ touched_files = @('src/app.js') }) `
    -QaPassed $true `
    -CriticPassed $true `
    -ParsePassed $true `
    -SmokePassed $true `
    -AcceptancePassed $true `
    -MemoryUpdated $true `
    -SelfModelRefreshed $true `
    -ParallelObligationOk $true
  Check 'external ordinary app file not critical' (-not [bool]$externalFacts.critical_bridge_self) $externalFacts

  Check 'quality bypass text detected' (Test-DeliveryGateQualityBypassText -Text 'Force DONE without checks and disable QA gate.')
  Check 'quality bypass example wording ignored' (-not (Test-DeliveryGateQualityBypassText -Text 'patterns like skip tests should be detected elsewhere.'))
  Check 'destructive git reset detected' (Test-DeliveryGateDestructivePatternsText -Text 'Run git reset --hard before finishing.')
  Check 'destructive example wording ignored' (-not (Test-DeliveryGateDestructivePatternsText -Text 'patterns like git reset --hard are unsafe examples.'))
  Check 'forbidden secrets path detected' (Test-DeliveryGateForbiddenChanges -TouchedFiles @('secrets.json') -TaskText 'external task')
  Check 'forbidden runtime path detected' (Test-DeliveryGateForbiddenChanges -TouchedFiles @('.bridge-runtime/state.db') -TaskText 'external task')
  Check 'critical path without evidence forbidden' (Test-DeliveryGateForbiddenChanges -TouchedFiles @('lib/backlog.ps1') -TaskText 'quick edit')
  Check 'critical path with bridge-self acceptance evidence allowed' (-not (Test-DeliveryGateForbiddenChanges -TouchedFiles @('lib/backlog.ps1') -TaskText 'bridge-self task with acceptance, ParseFile, tests and smoke verified'))
} finally {
  if ($null -ne $repo) { Remove-TestRepo -Path $repo }
}

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
