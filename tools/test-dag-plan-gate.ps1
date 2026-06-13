#Requires -Version 5.1
<#
.SYNOPSIS
  Unit test: Invoke-FoundryPlanDispatch plan-gate (Ф4) check.
  Tests that DAG dispatch blocks when plan_approved is missing and proceeds when approved.
#>
param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$passed = 0; $failed = 0

function Assert-True([bool]$cond, [string]$label) {
  if ($cond) { Write-Host "  PASS: $label"; $script:passed++ }
  else        { Write-Host "  FAIL: $label"; $script:failed++ }
}

# ===== MOCKS (defined BEFORE dot-sourcing foundry.ps1) =====
$script:MockPlanApproved = $false
$script:MockPlanContractIssues = @('plan_approved не установлен — выполните Set-ProjectPlanApproved')
$script:MockMessages = [System.Collections.Generic.List[string]]::new()
$script:MockStatuses = @{}
$script:MockRunnerCalls = 0
$script:MockStep = [pscustomobject]@{ id='step-1'; title='fixture step' }

function Get-BridgeRoot { return $script:BridgeRoot }
function Get-PlanScheduleState {
  $status = [string]$script:MockStatuses['step-1']
  $done = ($status -eq 'done')
  return [pscustomobject]@{
    reason = 'has-plan'
    total = 1
    complete = $done
    done = if ($done) { 1 } else { 0 }
    blocked = 0
    skipped = 0
    deadlocked = $false
    blockers = @{}
  }
}
function Get-ReadyPlanSteps {
  param([int]$Max = 1)
  $status = [string]$script:MockStatuses['step-1']
  if ([string]::IsNullOrWhiteSpace($status) -or $status -eq 'pending') { return @($script:MockStep) }
  return @()
}
function Set-PlanStepStatus {
  param([string]$Id, [string]$Status, [string]$Result = '')
  $script:MockStatuses[$Id] = $Status
}
function Normalize-PlanStatus {
  param([string]$Status)
  return $Status.ToLowerInvariant()
}
function Test-ProjectPlanApproved {
  param([string]$Channel, [string]$ProjectRoot = '')
  return $script:MockPlanApproved
}
function Test-ProjectPlanContractReady {
  param([string]$ProjectRoot)
  return [pscustomobject]@{ ready=$false; issues=$script:MockPlanContractIssues }
}
function Add-Message {
  param([string]$From, [string]$Text, [string]$Kind = '')
  [void]$script:MockMessages.Add($Text)
}
function Reset-Fixture {
  $script:MockMessages.Clear()
  $script:MockStatuses = @{ 'step-1' = 'pending' }
  $script:MockRunnerCalls = 0
  $script:MockPlanContractIssues = @('plan_approved не установлен — выполните Set-ProjectPlanApproved')
}
function Invoke-MockRunner {
  param($Steps)
  $script:MockRunnerCalls++
  return @($Steps | ForEach-Object { @{ id = [string]$_.id; ok = $true; result = 'ran' } })
}

# Load function under test
. (Join-Path $BridgeRoot 'lib\foundry.ps1')

Write-Host "=== Invoke-FoundryPlanDispatch plan-gate: unit tests ==="

# ===== Scenario 1: no plan_approved -> dispatch отказывает =====
Write-Host "--- Scenario 1: no plan_approved -> outcome=plan-not-approved ---"
$script:MockPlanApproved = $false
Reset-Fixture
$r1 = Invoke-FoundryPlanDispatch -Channel 'test-channel' -RepoRoot 'C:\fake-root' -MaxParallel 1 -BatchRunner ${function:Invoke-MockRunner}
Assert-True ([string]$r1.outcome -eq 'plan-not-approved') "outcome=plan-not-approved"
Assert-True (-not [bool]$r1.ok) "ok=false"
Assert-True ($script:MockMessages.Count -gt 0) "Add-Message was called"
Assert-True ([bool]($script:MockMessages | Where-Object { $_ -like '*DISPATCH-DAG ждёт утверждённый PROJECT_PLAN*' })) "message contains gate text"
Assert-True ([bool]($script:MockMessages | Where-Object { $_ -like '*(Ф4)*' })) "message contains phase marker (Ф4)"
Assert-True ($script:MockRunnerCalls -eq 0) "runner not called while unapproved"

# ===== Scenario 2: empty validator issues -> default reason is preserved =====
Write-Host "--- Scenario 2: empty contract issues -> default reason preserved ---"
$script:MockPlanApproved = $false
Reset-Fixture
$script:MockPlanContractIssues = @($null, '', '   ')
$r2 = Invoke-FoundryPlanDispatch -Channel 'test-channel' -RepoRoot 'C:\fake-root' -MaxParallel 1 -BatchRunner ${function:Invoke-MockRunner}
Assert-True ([string]$r2.outcome -eq 'plan-not-approved') "outcome=plan-not-approved with empty issues"
Assert-True ([bool]($script:MockMessages | Where-Object { $_ -like '*plan_approved не установлен*' })) "default reason kept when issues are empty"
Assert-True ($script:MockRunnerCalls -eq 0) "runner not called when empty issues"

# ===== Scenario 3: plan_approved -> dispatch стартует =====
Write-Host "--- Scenario 3: plan_approved=true -> runner starts ---"
$script:MockPlanApproved = $true
Reset-Fixture
$r3 = Invoke-FoundryPlanDispatch -Channel 'test-channel' -RepoRoot 'C:\fake-root' -MaxParallel 1 -BatchRunner ${function:Invoke-MockRunner}
Assert-True ([string]$r3.outcome -eq 'complete') "approved plan completes fixture step"
Assert-True ($script:MockRunnerCalls -eq 1) "runner called once when approved"
Assert-True (-not ($script:MockMessages | Where-Object { $_ -like '*DISPATCH-DAG ждёт*' })) "no gate message when approved"

# ===== Scenario 4: нет $Channel -> гейт пропускается (backward compat) =====
Write-Host "--- Scenario 4: no -Channel -> gate skipped ---"
$script:MockPlanApproved = $false
Reset-Fixture
$r4 = Invoke-FoundryPlanDispatch -RepoRoot 'C:\fake-root' -MaxParallel 1 -BatchRunner ${function:Invoke-MockRunner}
Assert-True ([string]$r4.outcome -eq 'complete') "no channel -> fixture step runs"
Assert-True ($script:MockRunnerCalls -eq 1) "runner called once without channel"

# ===== Scenario 5: approval validator missing -> fail-secure =====
Write-Host "--- Scenario 5: missing Test-ProjectPlanApproved -> fail-secure ---"
$script:MockPlanApproved = $true
Reset-Fixture
Remove-Item Function:\Test-ProjectPlanApproved -Force
$r5 = Invoke-FoundryPlanDispatch -Channel 'test-channel' -RepoRoot 'C:\fake-root' -MaxParallel 1 -BatchRunner ${function:Invoke-MockRunner}
Assert-True ([string]$r5.outcome -eq 'plan-not-approved') "missing approval validator blocks dispatch"
Assert-True ([bool]($script:MockMessages | Where-Object { $_ -like '*Test-ProjectPlanApproved недоступен*' })) "message names missing validator"
Assert-True ($script:MockRunnerCalls -eq 0) "runner not called when validator is missing"

Write-Host ""
Write-Host "=== RESULT: $passed passed, $failed failed ==="
if ($failed -gt 0) { exit 1 }
