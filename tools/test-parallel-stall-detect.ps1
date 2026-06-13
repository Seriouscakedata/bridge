#Requires -Version 5.1
# Test: Stop-ParallelDispatchStalledWorker exists and writes failed result to Completed
param()
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\parallel.ps1')

if (-not (Get-Command Stop-ParallelDispatchStalledWorker -ErrorAction SilentlyContinue)) {
  Write-Error 'FAIL stall-detect: Stop-ParallelDispatchStalledWorker is not visible after dot-source'
  exit 1
}

$completed = @{}
$reason = 'zero_output_stall'
$proc = $null
$proc2 = $null

try {
  $proc = Start-Process powershell.exe -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  Start-Sleep -Milliseconds 300
  $ticks = [long]0
  try { $ticks = (Get-Process -Id $proc.Id -ErrorAction Stop).StartTime.Ticks } catch {}

  $worker = [pscustomobject]@{
    id      = 'test-stall-001'
    pid     = if ($proc) { [int]$proc.Id } else { 0 }
    pidTicks = $ticks
    process = $proc
    outFile = ''
    errFile = ''
  }

  Stop-ParallelDispatchStalledWorker -Completed $completed -Worker $worker -Reason $reason

  if ($proc) {
    try { $null = $proc.WaitForExit(5000) } catch {}
    try { $proc.Refresh() } catch {}
  }

  $result = $null
  if ($completed.ContainsKey('test-stall-001')) {
    $result = $completed['test-stall-001']
  }

  $killed = $false
  if ($proc) {
    try { $killed = [bool]$proc.HasExited } catch { $killed = $false }
  }

  $ok = $killed -and
        $null -ne $result -and
        $result.status -eq 'failed' -and
        $result.error -eq $reason

  $proc2 = Start-Process powershell.exe -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  Start-Sleep -Milliseconds 300
  $ticks2 = [long]0
  try { $ticks2 = (Get-Process -Id $proc2.Id -ErrorAction Stop).StartTime.Ticks } catch {}

  $worker2 = [pscustomobject]@{
    id       = 'test-stall-pidonly'
    pid      = if ($proc2) { [int]$proc2.Id } else { 0 }
    pidTicks = $ticks2
    process  = $null
    outFile  = ''
    errFile  = ''
  }

  Stop-ParallelDispatchStalledWorker -Completed $completed -Worker $worker2 -Reason $reason

  if ($proc2) {
    try { $null = $proc2.WaitForExit(5000) } catch {}
    try { $proc2.Refresh() } catch {}
  }

  $result2 = $null
  if ($completed.ContainsKey('test-stall-pidonly')) {
    $result2 = $completed['test-stall-pidonly']
  }

  $killed2 = $false
  if ($proc2) {
    try { $killed2 = [bool]$proc2.HasExited } catch { $killed2 = $false }
  }

  $ok = $ok -and
        $killed2 -and
        $null -ne $result2 -and
        $result2.status -eq 'failed' -and
        $result2.error -eq $reason

  if ($ok) {
    Write-Host '{"testPassed":true,"test":"stall-detect-helper"}'
  } else {
    $dump = if ($null -ne $result) { $result | ConvertTo-Json -Compress -Depth 5 } else { 'null' }
    $dump2 = if ($null -ne $result2) { $result2 | ConvertTo-Json -Compress -Depth 5 } else { 'null' }
    Write-Error ("FAIL stall-detect: killed=" + $killed + " result=" + $dump + " killedPidOnly=" + $killed2 + " resultPidOnly=" + $dump2)
    exit 1
  }
} finally {
  if ($proc) {
    try {
      if (-not $proc.HasExited) {
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
      }
    } catch {}
    try { $proc.Dispose() } catch {}
  }
  if ($proc2) {
    try {
      if (-not $proc2.HasExited) {
        Stop-Process -Id $proc2.Id -Force -ErrorAction SilentlyContinue
      }
    } catch {}
    try { $proc2.Dispose() } catch {}
  }
}
