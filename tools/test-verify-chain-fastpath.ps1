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

class FastpathCase {
  [string]$Name
  [string[]]$ChangedPaths
  [bool]$ExpectSnapshotSuite

  FastpathCase([string]$name, [string[]]$changedPaths, [bool]$expectSnapshotSuite) {
    $this.Name = $name
    $this.ChangedPaths = $changedPaths
    $this.ExpectSnapshotSuite = $expectSnapshotSuite
  }
}

function Invoke-FastpathCase {
  param([Parameter(Mandatory=$true)][FastpathCase]$Case)

  $scope = @(Get-GateRegressionScope -ChangedPaths @($Case.ChangedPaths))
  $plan = New-DriverDoneGatePlan -BridgeRoot $root -TaskBaseCommit '' -Reply 'STATUS: DONE' -ChangedPathsOverride @($Case.ChangedPaths)
  $jobCount = @($plan.JobNames).Count
  $suiteJobPresent = @($plan.JobNames) -contains 'gate-regression'

  if ($Case.Name -eq 'TRIVIAL') {
    Check 'Class TRIVIAL: Get-GateRegressionScope returns empty for docs/test' ($scope.Count -eq 0) $scope
    Check 'Class TRIVIAL: snapshot suite is not scheduled' (-not [bool]$plan.GateSuiteNeeded) $plan
    Check 'Class TRIVIAL: job count <= 1' ($jobCount -le 1) $plan.JobNames
    return
  }

  if ($Case.Name -eq 'CONTROL_PLANE') {
    Check 'Class CONTROL_PLANE: Get-GateRegressionScope returns non-empty for driver.ps1' ($scope.Count -gt 0) $scope
    Check 'Class CONTROL_PLANE: snapshot suite is scheduled' ([bool]$plan.GateSuiteNeeded) $plan
    Check 'Class CONTROL_PLANE: gate-regression job is present' $suiteJobPresent $plan.JobNames
    return
  }

  Check ("Class {0}: known test class" -f $Case.Name) $false $Case
}

$cases = @(
  [FastpathCase]::new('TRIVIAL', [string[]]@('docs/test'), $false),
  [FastpathCase]::new('CONTROL_PLANE', [string[]]@('driver.ps1'), $true)
)

foreach ($case in $cases) {
  Invoke-FastpathCase -Case $case
}

Write-Host ("{0} passed, {1} failed" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
exit 0
