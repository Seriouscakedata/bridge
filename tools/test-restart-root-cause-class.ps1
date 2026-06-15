# test-restart-root-cause-class.ps1 - unit tests for Get-RestartRootCauseClass
param([string]$BridgeRoot = $null)

if ([string]::IsNullOrWhiteSpace($BridgeRoot)) { $BridgeRoot = Split-Path -Parent $PSScriptRoot }

$d60 = Join-Path $BridgeRoot 'driver\60-startup.ps1'
$src = [System.IO.File]::ReadAllText($d60, [System.Text.Encoding]::UTF8)
$fnStart = $src.IndexOf('function Get-RestartRootCauseClass')
$fnEnd = $src.IndexOf('Sweep-AgentOrphans', $fnStart)
if ($fnStart -lt 0 -or $fnEnd -le $fnStart) {
  Write-Error 'Get-RestartRootCauseClass function block not found'
  exit 1
}
Invoke-Expression $src.Substring($fnStart, $fnEnd - $fnStart)

$pass = 0
$fail = 0
function Assert-Eq {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -eq $Expected) {
    $script:pass++
  } else {
    $script:fail++
    Write-Host "FAIL $Message : got '$Actual' expected '$Expected'"
  }
}

$r = Get-RestartRootCauseClass -BootState $null -IsTrustedApply $true
Assert-Eq $r 'operator' 'trusted apply'

$fakeState = [pscustomobject]@{ status='timeout'; status_text=''; agent_pid=0 }
$r = Get-RestartRootCauseClass -BootState $fakeState -IsTrustedApply $false
Assert-Eq $r 'timeout' 'status timeout'

$fakeState2 = [pscustomobject]@{ status='idle'; status_text=''; agent_pid=0 }
$r = Get-RestartRootCauseClass -BootState $fakeState2 -IsTrustedApply $false
Assert-Eq $r 'crash' 'idle no pid'

$deadPid = 999999
$fakeState3 = [pscustomobject]@{ status='working'; status_text=''; agent_pid=$deadPid }
$r = Get-RestartRootCauseClass -BootState $fakeState3 -IsTrustedApply $false
Assert-Eq $r 'killed' 'dead pid'

$fakeState4 = [pscustomobject]@{ status='working'; status_text='timed out waiting for agent'; agent_pid=$PID }
$r = Get-RestartRootCauseClass -BootState $fakeState4 -IsTrustedApply $false
Assert-Eq $r 'timeout' 'status text timeout'

$r = Get-RestartRootCauseClass -BootState $null -IsTrustedApply $false
Assert-Eq $r 'crash' 'null state'

Write-Host "Results: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
