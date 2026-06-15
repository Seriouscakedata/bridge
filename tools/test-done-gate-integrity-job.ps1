#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\verify-selftest.ps1')
. (Join-Path $root 'driver\86-loop-completion.ps1')

$script:PassCount = 0
$script:FailCount = 0

function Check {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    [object]$Actual = $null
  )

  if ($Condition) {
    $script:PassCount++
    Write-Host ("PASS: {0}" -f $Name)
    return
  }

  $script:FailCount++
  $suffix = ''
  if ($null -ne $Actual) {
    $suffix = ' actual=' + ($Actual | ConvertTo-Json -Compress -Depth 8)
  }
  Write-Host ("FAIL: {0}{1}" -f $Name, $suffix)
}

function New-TestPlan {
  param([string[]]$ChangedPaths)
  New-DriverDoneGatePlan -BridgeRoot $root -TaskBaseCommit '' -Reply 'STATUS: DONE' -ChangedPathsOverride @($ChangedPaths)
}

$zeroPathPlan = New-TestPlan -ChangedPaths @()
Check 'Integrity: zero changed paths is not needed' (-not [bool]$zeroPathPlan.IntegrityNeeded) $zeroPathPlan
Check 'Integrity: zero changed paths has no job' (-not (@($zeroPathPlan.JobNames) -contains 'integrity')) $zeroPathPlan.JobNames

$onePathPlan = New-TestPlan -ChangedPaths @('docs/operator-note.md')
Check 'Integrity: one changed path is not needed' (-not [bool]$onePathPlan.IntegrityNeeded) $onePathPlan
Check 'Integrity: one changed path has no job' (-not (@($onePathPlan.JobNames) -contains 'integrity')) $onePathPlan.JobNames

$twoPathPlan = New-TestPlan -ChangedPaths @('docs/operator-note.md','config.json')
Check 'Integrity: two changed paths is needed' ([bool]$twoPathPlan.IntegrityNeeded) $twoPathPlan
Check 'Integrity: two changed paths has job' (@($twoPathPlan.JobNames) -contains 'integrity') $twoPathPlan.JobNames

$multiPathPlan = New-TestPlan -ChangedPaths @('driver/86-loop-completion-checks.ps1','tools/test-state-integrity.ps1')
Check 'Integrity: control-plane multi-path is needed' ([bool]$multiPathPlan.IntegrityNeeded) $multiPathPlan
Check 'Integrity: control-plane multi-path has job' (@($multiPathPlan.JobNames) -contains 'integrity') $multiPathPlan.JobNames

Write-Host ("{0} passed, {1} failed" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
exit 0
