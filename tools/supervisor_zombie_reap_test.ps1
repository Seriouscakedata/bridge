# supervisor_zombie_reap_test.ps1 -- smoke test for post-kill WaitForExit behavior.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\supervisor-restart-limit.ps1')

function Stop-TestProcessTree {
  param([Parameter(Mandatory=$true)][System.Diagnostics.Process]$Process)

  $targetPid = [int]$Process.Id
  $null = & cmd.exe /c "taskkill /PID $targetPid /F /T >nul 2>nul"
  $taskkillExitCode = $LASTEXITCODE
  $Process.Refresh()
  if ($taskkillExitCode -eq 0 -or $Process.HasExited) {
    return [pscustomobject]@{ method = 'taskkill'; taskkillExitCode = $taskkillExitCode }
  }

  Stop-Process -Id $targetPid -Force -ErrorAction Stop
  return [pscustomobject]@{ method = 'stop-process'; taskkillExitCode = $taskkillExitCode }
}

$proc = $null
$proc2 = $null
$waitExited = $false
$timedOutPath = $false
$timedOutFallback = $false
$killMethod = ''
$taskkillExitCode = $null

try {
  $proc = Start-Process powershell.exe -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  Start-Sleep -Milliseconds 300
  $killResult = Stop-TestProcessTree -Process $proc
  $killMethod = $killResult.method
  $taskkillExitCode = $killResult.taskkillExitCode
  $waitExited = [bool]$proc.WaitForExit(5000)

  $proc2 = Start-Process powershell.exe -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  Start-Sleep -Milliseconds 300
  $timedOutPath = -not [bool]$proc2.WaitForExit(100)
  if ($timedOutPath) {
    $null = Stop-TestProcessTree -Process $proc2
    $timedOutFallback = -not [bool]$proc2.WaitForExit(5000)
  }
} finally {
  foreach ($p in @($proc, $proc2)) {
    if ($p -and -not $p.HasExited) {
      try {
        $null = Stop-TestProcessTree -Process $p
        $null = $p.WaitForExit(5000)
      } catch {
        [System.Diagnostics.Trace]::TraceError("cleanup failed for PID " + $p.Id + ": " + $_.Exception.Message)
      }
    }
  }
}

$testPassed = $waitExited -and $timedOutPath -and -not $timedOutFallback
if (-not $testPassed) {
  throw ("supervisor zombie reap smoke failed: waitExited=" + $waitExited + " timedOutPath=" + $timedOutPath + " timedOutFallback=" + $timedOutFallback)
}

[pscustomobject]@{
  waitExited = $waitExited
  timedOutPath = $timedOutPath
  timedOutFallback = $timedOutFallback
  killMethod = $killMethod
  taskkillExitCode = $taskkillExitCode
  testPassed = $testPassed
} | ConvertTo-Json -Compress -Depth 5
