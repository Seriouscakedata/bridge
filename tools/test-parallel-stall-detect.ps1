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

try {
  $proc = Start-Process powershell.exe -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  Start-Sleep -Milliseconds 300

  $worker = [pscustomobject]@{
    id      = 'test-stall-001'
    pid     = if ($proc) { [int]$proc.Id } else { 0 }
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

  if ($ok) {
    Write-Host '{"testPassed":true,"test":"stall-detect-helper"}'
  } else {
    $dump = if ($null -ne $result) { $result | ConvertTo-Json -Compress -Depth 5 } else { 'null' }
    Write-Error ("FAIL stall-detect: killed=" + $killed + " result=" + $dump)
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
}
