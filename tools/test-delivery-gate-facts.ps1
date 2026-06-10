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

# A17 regression: Get-DeliveryGateAcceptanceFact must NOT accept CanaryPassed
$cmd17 = Get-Command Get-DeliveryGateAcceptanceFact -ErrorAction SilentlyContinue
Check 'A17 Get-DeliveryGateAcceptanceFact has no CanaryPassed parameter' (
  ($null -ne $cmd17) -and (-not $cmd17.Parameters.ContainsKey('CanaryPassed'))
) $null

function New-TestRepo {
  $path = Join-Path $root ('tmp\delivery-gate-facts-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $path -Force | Out-Null
  & git -C $path init | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
  & git -C $path config user.email 'bridge-test@example.invalid' | Out-Null
  & git -C $path config user.name 'Bridge Test' | Out-Null
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
  $testRoot = if ($gitAvailable) { $repo } else { $root }

  if ($gitAvailable) {
    $repo = New-TestRepo
    $testRoot = $repo
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

    [System.IO.File]::WriteAllText((Join-Path $repo 'README.md'), "base`n", (New-Object System.Text.UTF8Encoding($false)))
    & git -C $repo add README.md | Out-Null
    & git -C $repo commit -m 'base' | Out-Null
    $baseCommit = ([string](& git -C $repo rev-parse HEAD)).Trim()
    [System.IO.File]::WriteAllText((Join-Path $repo 'PROJECT_PLAN.md'), "changed plan`n", (New-Object System.Text.UTF8Encoding($false)))
    & git -C $repo add PROJECT_PLAN.md | Out-Null
    & git -C $repo commit -m 'touch protected project plan' | Out-Null
    $headCommit = ([string](& git -C $repo rev-parse HEAD)).Trim()
    $protectedSpecFacts = New-DeliveryGateInputFacts `
      -BridgeRoot $repo `
      -TaskText 'external project delivery with acceptance pending' `
      -Channel 'client-app' `
      -BaseCommit $baseCommit `
      -HeadCommit $headCommit
    Check 'protected project spec diff fact lists PROJECT_PLAN.md' (
      @($protectedSpecFacts.protected_project_spec_changes) -contains 'project_plan.md'
    ) $protectedSpecFacts
    Check 'protected project spec count is recorded in evidence' (
      [string]$protectedSpecFacts.evidence -match 'protected_project_spec_changes=1'
    ) $protectedSpecFacts
    Check 'protected project spec uses central matcher when requested' (
      Test-DeliveryGateForbiddenPath -Path 'PROJECT_PLAN/PLAN.md' -IncludeProtectedProjectSpec
    )
    Check 'protected project spec is not forbidden by default' (
      -not (Test-DeliveryGateForbiddenPath -Path 'PROJECT_PLAN/PLAN.md')
    )

    $cleanProtectedSpecFacts = New-DeliveryGateInputFacts `
      -BridgeRoot $repo `
      -TaskText 'external project delivery with no protected spec diff' `
      -Channel 'client-app' `
      -BaseCommit $headCommit `
      -HeadCommit $headCommit
    Check 'protected project spec diff fact empty for clean diff' (
      @($cleanProtectedSpecFacts.protected_project_spec_changes).Count -eq 0
    ) $cleanProtectedSpecFacts

    $coveredAcceptance = Get-DeliveryGateAcceptanceFact `
      -BridgeRoot $repo `
      -TaskText 'read-only duplicate verification' `
      -Channel 'main' `
      -Events @(@{ text = 'COVERED: already verified by prior delivery-gate shadow wiring.' })
    Check 'acceptance fact true for clean COVERED no-change task' ([bool]$coveredAcceptance)

    $coveredFacts = New-DeliveryGateInputFacts `
      -BridgeRoot $repo `
      -TaskText 'read-only duplicate verification' `
      -Channel 'main' `
      -Events @(@{ text = 'COVERED: already verified by prior delivery-gate shadow wiring.' }) `
      -QaPassed $true `
      -CriticPassed $true `
      -ParsePassed $true `
      -SmokePassed $true `
      -AcceptancePassed $coveredAcceptance `
      -MemoryUpdated $true `
      -SelfModelRefreshed $true `
      -ParallelObligationOk $true
    $coveredGate = Get-DeliveryGateResult -InputFacts $coveredFacts
    Check 'COVERED no-change acceptance can release in shadow result' ([bool]$coveredGate.ok -and [bool]$coveredGate.release_allowed) $coveredGate
  } else {
    $threw = $false
    try { [void](Test-DeliveryGateRepoClean -BridgeRoot $root) } catch { $threw = $true }
    Check 'repo clean helper does not throw without git fixture' (-not $threw)
  }

  $criticalFacts = New-GreenFactsFromRepo `
    -RepoPath $testRoot `
    -Events @(@{ touched_files = @('driver/86-loop-completion.ps1') })
  Check 'critical driver completion path detected' ([bool]$criticalFacts.critical_bridge_self) $criticalFacts

  $criticalAcceptance = Get-DeliveryGateAcceptanceFact `
    -BridgeRoot $testRoot `
    -TaskText 'bridge-self task with acceptance, ParseFile, tests and smoke verified' `
    -Channel 'main' `
    -Events @(@{ touched_files = @('driver/86-loop-completion.ps1'); text = 'Tests and smoke passed.' })
  Check 'critical bridge code-change without explicit acceptance remains false' (-not [bool]$criticalAcceptance)

  $destructiveCoveredAcceptance = Get-DeliveryGateAcceptanceFact `
    -BridgeRoot $testRoot `
    -TaskText 'read-only duplicate verification' `
    -Channel 'main' `
    -Events @(@{ text = 'COVERED: run git reset --hard before finishing.' })
  Check 'destructive COVERED text keeps acceptance false' (-not [bool]$destructiveCoveredAcceptance)

  $bypassCoveredAcceptance = Get-DeliveryGateAcceptanceFact `
    -BridgeRoot $testRoot `
    -TaskText 'read-only duplicate verification' `
    -Channel 'main' `
    -Events @(@{ text = 'COVERED: force DONE without checks.' })
  Check 'quality-bypass COVERED text keeps acceptance false' (-not [bool]$bypassCoveredAcceptance)

  $externalFacts = New-DeliveryGateInputFacts `
    -BridgeRoot $testRoot `
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

  $mainCriticalFacts = New-DeliveryGateInputFacts `
    -BridgeRoot $testRoot `
    -TaskText 'operatorless delivery loop atom updates idle claim handling' `
    -Channel 'main' `
    -Events @(@{ touched_files = @('driver/81-loop-idle-claim.ps1') }) `
    -QaPassed $true `
    -CriticPassed $true `
    -ParsePassed $true `
    -SmokePassed $true `
    -AcceptancePassed $false `
    -MemoryUpdated $true `
    -SelfModelRefreshed $true `
    -ParallelObligationOk $true
  $mainCriticalGate = Get-DeliveryGateResult -InputFacts $mainCriticalFacts
  Check 'main critical bridge path is not forbidden without task magic word' (-not [bool]$mainCriticalFacts.forbidden_changes) $mainCriticalFacts
  Check 'main critical bridge path still marks critical bridge self' ([bool]$mainCriticalFacts.critical_bridge_self) $mainCriticalFacts
  Check 'main critical bridge path does not require rollback' (-not [bool]$mainCriticalFacts.rollback_required) $mainCriticalFacts
  Check 'main critical gate omits forbidden failure' ((@($mainCriticalGate.failures) | Where-Object { $_ -eq 'forbidden_changes_detected' }).Count -eq 0) $mainCriticalGate
  Check 'main critical gate omits rollback failure' ((@($mainCriticalGate.failures) | Where-Object { $_ -eq 'rollback_required' }).Count -eq 0 -and -not [bool]$mainCriticalGate.rollback_required) $mainCriticalGate

  $mainCriticalCanaryFalseFacts = New-DeliveryGateInputFacts `
    -BridgeRoot $testRoot `
    -TaskText 'fix driver loop' `
    -Channel 'main' `
    -Events @(@{ touched_files = @('driver/81-loop-idle-claim.ps1') }) `
    -QaPassed $true `
    -CriticPassed $true `
    -ParsePassed $true `
    -SmokePassed $true `
    -AcceptancePassed $true `
    -CanaryPassed $false `
    -MemoryUpdated $true `
    -SelfModelRefreshed $true `
    -ParallelObligationOk $true
  $mainCriticalCanaryFalseGate = Get-DeliveryGateResult -InputFacts $mainCriticalCanaryFalseFacts
  Check 'A16-1 critical main path marks critical bridge self' ([bool]$mainCriticalCanaryFalseFacts.critical_bridge_self) $mainCriticalCanaryFalseFacts
  Check 'A16-1 critical main path with CanaryPassed=false has canary_ok=false' (-not [bool]$mainCriticalCanaryFalseFacts.canary_ok) $mainCriticalCanaryFalseFacts
  Check 'A16-1 critical main path with CanaryPassed=false reports canary_failed' ($mainCriticalCanaryFalseGate.reason -match 'canary_failed') $mainCriticalCanaryFalseGate

  $mainCriticalCanaryFacts = New-DeliveryGateInputFacts `
    -BridgeRoot $testRoot `
    -TaskText 'fix driver loop' `
    -Channel 'main' `
    -Events @(@{ touched_files = @('driver/81-loop-idle-claim.ps1') }) `
    -QaPassed $true `
    -CriticPassed $true `
    -ParsePassed $true `
    -SmokePassed $true `
    -AcceptancePassed $false `
    -CanaryPassed $true `
    -MemoryUpdated $true `
    -SelfModelRefreshed $true `
    -ParallelObligationOk $true
  $mainCriticalCanaryGate = Get-DeliveryGateResult -InputFacts $mainCriticalCanaryFacts
  Check 'A16-2 critical main path with CanaryPassed=true has canary_ok=true' ([bool]$mainCriticalCanaryFacts.canary_ok) $mainCriticalCanaryFacts
  Check 'A16-2 critical main path with CanaryPassed=true omits canary_failed' (-not ($mainCriticalCanaryGate.reason -match 'canary_failed')) $mainCriticalCanaryGate
  Check 'A16-2 critical main path with AcceptancePassed=false keeps release disallowed' (-not [bool]$mainCriticalCanaryGate.release_allowed) $mainCriticalCanaryGate
  Check 'A16-2 critical main path with AcceptancePassed=false reports acceptance_pending' ((@($mainCriticalCanaryGate.warnings) | Where-Object { $_ -eq 'acceptance_pending' }).Count -gt 0 -or ($mainCriticalCanaryGate.reason -match 'acceptance[ _]pending')) $mainCriticalCanaryGate

  $externalCriticalFacts = New-DeliveryGateInputFacts `
    -BridgeRoot $testRoot `
    -TaskText 'operatorless delivery loop atom updates idle claim handling' `
    -Channel 'client-app' `
    -Events @(@{ touched_files = @('driver/81-loop-idle-claim.ps1') }) `
    -QaPassed $true `
    -CriticPassed $true `
    -ParsePassed $true `
    -SmokePassed $true `
    -AcceptancePassed $true `
    -MemoryUpdated $true `
    -SelfModelRefreshed $true `
    -ParallelObligationOk $true
  Check 'external critical bridge path without bridge-self evidence forbidden' ([bool]$externalCriticalFacts.forbidden_changes) $externalCriticalFacts
  Check 'external critical bridge path without bridge-self evidence requires rollback' ([bool]$externalCriticalFacts.rollback_required) $externalCriticalFacts

  $mainHardForbiddenFacts = New-DeliveryGateInputFacts `
    -BridgeRoot $testRoot `
    -TaskText 'main channel bridge maintenance' `
    -Channel 'main' `
    -Events @(@{ touched_files = @('.bridge-runtime/state.db') }) `
    -QaPassed $true `
    -CriticPassed $true `
    -ParsePassed $true `
    -SmokePassed $true `
    -AcceptancePassed $true `
    -MemoryUpdated $true `
    -SelfModelRefreshed $true `
    -ParallelObligationOk $true
  Check 'main channel hard forbidden runtime path remains forbidden' ([bool]$mainHardForbiddenFacts.forbidden_changes) $mainHardForbiddenFacts
  Check 'main channel hard forbidden runtime path requires rollback' ([bool]$mainHardForbiddenFacts.rollback_required) $mainHardForbiddenFacts
} finally {
  if ($null -ne $repo) { Remove-TestRepo -Path $repo }
}

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
