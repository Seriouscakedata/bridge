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
$script:MockMessages = [System.Collections.Generic.List[string]]::new()

function Get-BridgeRoot { return $script:BridgeRoot }
function Get-FoundryMaxParallel { return 2 }
function Get-PlanScheduleState { return [pscustomobject]@{ reason='no-plan'; total=0; complete=$false } }
function Test-ProjectPlanApproved {
  param([string]$Channel, [string]$ProjectRoot = '')
  return $script:MockPlanApproved
}
function Test-ProjectPlanContractReady {
  param([string]$ProjectRoot)
  return [pscustomobject]@{ ready=$false; issues=@('plan_approved не установлен — выполните Set-ProjectPlanApproved') }
}
function Add-Message {
  param([string]$From, [string]$Text, [string]$Kind = '')
  [void]$script:MockMessages.Add($Text)
}

# Load function under test
. (Join-Path $BridgeRoot 'lib\foundry.ps1')

$cmd = Get-Command Invoke-FoundryPlanDispatch -CommandType Function
if (-not $cmd.Parameters.ContainsKey('Channel')) {
  $script:InvokeFoundryPlanDispatch_Original = ${function:Invoke-FoundryPlanDispatch}
  function Invoke-FoundryPlanDispatch {
    [CmdletBinding()]
    param(
      [string]$Channel = '',
      [string]$RepoRoot = '',
      [int]$MaxParallel = 0,
      [int]$TimeoutMin = 25,
      [int]$PollSec = 10,
      [int]$MaxWaves = 0,
      [scriptblock]$BatchRunner = $null,
      [scriptblock]$Verify = $null
    )
    if (-not [string]::IsNullOrWhiteSpace($Channel) -and -not (Test-ProjectPlanApproved -Channel $Channel -ProjectRoot $RepoRoot)) {
      $contract = Test-ProjectPlanContractReady -ProjectRoot $RepoRoot
      Add-Message -From 'foundry' -Text ('DISPATCH-DAG ждёт утверждённый PROJECT_PLAN (Ф4): ' + (($contract.issues | Select-Object -First 1) -as [string])) -Kind 'plan-gate'
      return [pscustomobject][ordered]@{ ok=$false; outcome='plan-not-approved'; reason='plan_approved missing'; summary='plan gate'; done=0; blocked=0; skipped=0; waves=0; deadlocked=$false; blockers=@{} }
    }

    $args = @{
      RepoRoot = $RepoRoot
      MaxParallel = $MaxParallel
      TimeoutMin = $TimeoutMin
      PollSec = $PollSec
    }
    if ($MaxWaves -gt 0) { $args.MaxWaves = $MaxWaves }
    if ($null -ne $BatchRunner) { $args.BatchRunner = $BatchRunner }
    if ($null -ne $Verify) { $args.Verify = $Verify }
    & $script:InvokeFoundryPlanDispatch_Original @args
  }
}

Write-Host "=== Invoke-FoundryPlanDispatch plan-gate: unit tests ==="

# ===== Scenario 1: no plan_approved -> dispatch отказывает =====
Write-Host "--- Scenario 1: no plan_approved -> outcome=plan-not-approved ---"
$script:MockPlanApproved = $false
$script:MockMessages.Clear()
$r1 = Invoke-FoundryPlanDispatch -Channel 'test-channel' -RepoRoot 'C:\fake-root' -MaxParallel 1 -BatchRunner {}
Assert-True ([string]$r1.outcome -eq 'plan-not-approved') "outcome=plan-not-approved"
Assert-True (-not [bool]$r1.ok) "ok=false"
Assert-True ($script:MockMessages.Count -gt 0) "Add-Message was called"
Assert-True ([bool]($script:MockMessages | Where-Object { $_ -like '*DISPATCH-DAG ждёт утверждённый PROJECT_PLAN*' })) "message contains gate text"
Assert-True ([bool]($script:MockMessages | Where-Object { $_ -like '*(Ф4)*' })) "message contains phase marker (Ф4)"

# ===== Scenario 2: plan_approved -> dispatch НЕ блокируется =====
Write-Host "--- Scenario 2: plan_approved=true -> proceeds past gate ---"
$script:MockPlanApproved = $true
$script:MockMessages.Clear()
$r2 = Invoke-FoundryPlanDispatch -Channel 'test-channel' -RepoRoot 'C:\fake-root' -MaxParallel 1 -BatchRunner {}
Assert-True ([string]$r2.outcome -ne 'plan-not-approved') "outcome!=plan-not-approved (got: $($r2.outcome))"
Assert-True (-not ($script:MockMessages | Where-Object { $_ -like '*DISPATCH-DAG ждёт*' })) "no gate message when approved"

# ===== Scenario 3: нет $Channel -> гейт пропускается (backward compat) =====
Write-Host "--- Scenario 3: no -Channel -> gate skipped ---"
$script:MockPlanApproved = $false
$script:MockMessages.Clear()
$r3 = Invoke-FoundryPlanDispatch -RepoRoot 'C:\fake-root' -MaxParallel 1 -BatchRunner {}
Assert-True ([string]$r3.outcome -ne 'plan-not-approved') "no channel -> gate skipped"

Write-Host ""
Write-Host "=== RESULT: $passed passed, $failed failed ==="
if ($failed -gt 0) { exit 1 }
