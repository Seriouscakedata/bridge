#Requires -Version 5.1
# test-relaunch-protection.ps1 -- real mutex relaunch protection checks.

$ErrorActionPreference = 'Stop'

$bridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $bridgeRoot 'lib\bridge-lock.ps1')

$script:OldSupervisorLockName = [string]$env:BRIDGE_SUPERVISOR_LOCK_NAME
$env:BRIDGE_SUPERVISOR_LOCK_NAME = 'Global\ClaudeCodexBridgeSupervisorInstanceTest-' + [guid]::NewGuid().ToString('N')

$script:pass = 0
$script:fail = 0

function Assert-RelaunchProtection {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    [Parameter(Mandatory=$false)]$Detail = ''
  )

  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name)
    return
  }

  $script:fail++
  if ([string]::IsNullOrWhiteSpace([string]$Detail)) {
    Write-Host ("FAIL " + $Name)
  } else {
    Write-Host ("FAIL {0}: {1}" -f $Name, $Detail)
  }
}

function Join-RelaunchProtectionArguments {
  param([string[]]$Arguments)

  $quoted = @()
  foreach ($arg in @($Arguments)) {
    if ($null -eq $arg) { $arg = '' }
    $value = [string]$arg
    if ($value -notmatch '[\s"]') {
      $quoted += $value
      continue
    }
    $quoted += ('"' + ($value -replace '"','\"') + '"')
  }
  return ($quoted -join ' ')
}

function Invoke-RelaunchProtectionProbe {
  param([Parameter(Mandatory=$true)][string]$BridgeRoot)

  try { $ps = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $ps = '' }
  if ([string]::IsNullOrWhiteSpace($ps) -or -not (Test-Path -LiteralPath $ps)) {
    throw 'Cannot resolve current PowerShell executable for relaunch protection probe.'
  }

  $probePath = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-relaunch-probe-' + [guid]::NewGuid().ToString('N') + '.ps1')
  $probeSource = @'
param([Parameter(Mandatory=$true)][string]$BridgeRoot)
$ErrorActionPreference = 'Stop'
. (Join-Path $BridgeRoot 'lib\bridge-lock.ps1')
$lock = $null
try {
  $lock = Acquire-SupervisorLaunchLock -TimeoutMs 0
  if (-not $lock.acquired) {
    Write-Host ("LOCK_BUSY: " + $lock.reason)
    exit 2
  }
  Write-Host 'LOCK_ACQUIRED'
  exit 0
} finally {
  if ($lock -and $lock.acquired) {
    Release-SupervisorLaunchLock -Lock $lock
    Write-Host 'LOCK_RELEASED'
  }
}
'@

  $stdout = ''
  $stderr = ''
  $exitCode = -1
  try {
    [System.IO.File]::WriteAllText($probePath, $probeSource, (New-Object System.Text.UTF8Encoding($true)))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ps
    $psi.Arguments = Join-RelaunchProtectionArguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $probePath, $BridgeRoot)
    $psi.WorkingDirectory = $BridgeRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(10000)) {
      try { $proc.Kill() } catch {}
      $exitCode = 124
      $stderr = 'probe timeout after 10s'
    } else {
      $proc.WaitForExit()
      $exitCode = [int]$proc.ExitCode
      $stdout = [string]$stdoutTask.Result
      $stderr = [string]$stderrTask.Result
    }
  } finally {
    Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
  }

  return [pscustomobject]@{
    ExitCode = $exitCode
    StdOut = $stdout
    StdErr = $stderr
    Combined = (($stdout, $stderr) -join "`n")
  }
}

$heldLock = $null
try {
  $heldLock = Acquire-SupervisorLaunchLock -TimeoutMs 0
  Assert-RelaunchProtection 'parent process can acquire relaunch lock for occupied-lock case' ([bool]$heldLock.acquired) $heldLock.reason

  if ($heldLock.acquired) {
    $blocked = Invoke-RelaunchProtectionProbe -BridgeRoot $bridgeRoot
    Assert-RelaunchProtection 'held relaunch lock rejects a second process with nonzero exit' ($blocked.ExitCode -ne 0) ("exit={0}; output={1}" -f $blocked.ExitCode, $blocked.Combined.Trim())
    Assert-RelaunchProtection 'held relaunch lock reports the supervisor lock owner' ($blocked.Combined -match 'LOCK_BUSY' -and $blocked.Combined -match 'another supervisor instance holds the lock') $blocked.Combined.Trim()
  }
} finally {
  if ($heldLock -and $heldLock.acquired) {
    Release-SupervisorLaunchLock -Lock $heldLock
  }
}

$freeProbe = Invoke-RelaunchProtectionProbe -BridgeRoot $bridgeRoot
Assert-RelaunchProtection 'free relaunch lock allows child acquire and release' ($freeProbe.ExitCode -eq 0 -and $freeProbe.Combined -match 'LOCK_ACQUIRED' -and $freeProbe.Combined -match 'LOCK_RELEASED') ("exit={0}; output={1}" -f $freeProbe.ExitCode, $freeProbe.Combined.Trim())

$cleanupLock = $null
try {
  $cleanupLock = Acquire-SupervisorLaunchLock -TimeoutMs 0
  Assert-RelaunchProtection 'parent process can acquire relaunch lock before cleanup case' ([bool]$cleanupLock.acquired) $cleanupLock.reason
} finally {
  if ($cleanupLock -and $cleanupLock.acquired) {
    Release-SupervisorLaunchLock -Lock $cleanupLock
  }
}

$afterCleanupProbe = Invoke-RelaunchProtectionProbe -BridgeRoot $bridgeRoot
Assert-RelaunchProtection 'released relaunch lock allows the next child launch again' ($afterCleanupProbe.ExitCode -eq 0 -and $afterCleanupProbe.Combined -match 'LOCK_ACQUIRED' -and $afterCleanupProbe.Combined -match 'LOCK_RELEASED') ("exit={0}; output={1}" -f $afterCleanupProbe.ExitCode, $afterCleanupProbe.Combined.Trim())

Write-Host ("relaunch protection tests: {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ([string]::IsNullOrWhiteSpace($script:OldSupervisorLockName)) {
  Remove-Item Env:\BRIDGE_SUPERVISOR_LOCK_NAME -ErrorAction SilentlyContinue
} else {
  $env:BRIDGE_SUPERVISOR_LOCK_NAME = $script:OldSupervisorLockName
}
if ($script:fail -gt 0) { exit 1 }
exit 0
