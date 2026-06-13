#Requires -Version 5.1
param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0

function Assert {
  param([string]$Name, [bool]$Condition)
  if ($Condition) { Write-Host "PASS: $Name"; $script:pass++ }
  else { Write-Host "FAIL: $Name"; $script:fail++ }
}

function Get-PlanScheduleState { return [pscustomobject]@{ reason='no-plan'; total=0; complete=$true; done=0; blocked=0; skipped=0; deadlocked=$false; blockers=@{} } }
function Get-ReadyPlanSteps { param([int]$Max = 1) return @() }
function Set-PlanStepStatus { param([string]$Id, [string]$Status, [string]$Result = '') }
function Normalize-PlanStatus { param([string]$Status) return $Status }

. (Join-Path $BridgeRoot 'lib\foundry.ps1')

Assert 'default node timeout is 300s' ((Get-FoundryNodeTimeoutSec) -eq 300)
Assert 'non-positive node timeout falls back to 300s' ((Get-FoundryNodeTimeoutSec -NodeTimeoutSec 0) -eq 300)
Assert 'custom node timeout preserved' ((Get-FoundryNodeTimeoutSec -NodeTimeoutSec 42) -eq 42)

$ctx = @{ sid='n1'; timedOut=$true; timeoutSec=7; worker=$null }
$ops = @{
  Prepare = { param($Step) return @{ ok=$true; ctx=$ctx } }
  Await = { param($Contexts) }
  Result = { param($Ctx) if ([bool](Get-RunnerField $Ctx 'timedOut' $false)) { return @{ status='failed'; reply=('node timeout after ' + [int](Get-RunnerField $Ctx 'timeoutSec' 300) + 's at step ' + [string](Get-RunnerField $Ctx 'sid' 'step')); commits=@() } } return @{ status='done'; reply='ok'; commits=@('c1') } }
  Merge = { param($Ctx) return @{ ok=$true; conflict=$false } }
  Cleanup = { param($Ctx) }
}
$runner = New-FoundryStepRunner -Ops $ops -NodeTimeoutSec 7
$result = @(& $runner @([pscustomobject]@{ id='n1'; title='node 1' }))
Assert 'timed out node becomes blocked' ([string]$result[0].status -eq 'blocked')
Assert 'timeout result logs step and seconds' ([string]$result[0].result -match 'node timeout after 7s at step n1')

Write-Host "RESULT: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 }
exit 0
