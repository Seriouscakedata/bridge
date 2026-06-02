# supervisor_zombie_reap_test.ps1 -- smoke test for post-kill WaitForExit behavior.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\supervisor-restart-limit.ps1')

function Read-TestTempFirstLine {
  param(
    [string]$Path,
    [string]$Label = 'temp output'
  )
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return '' }
  try {
    $lines = @(Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop)
    if ($lines.Count -eq 0) { return '' }
    return ([string]$lines[0]).Trim()
  } catch {
    [System.Diagnostics.Trace]::TraceError($Label + " read failed: " + $_.Exception.Message)
    return ''
  }
}

function Stop-TestProcessTree {
  param([Parameter(Mandatory=$true)][System.Diagnostics.Process]$Process)

  $targetPid = [int]$Process.Id
  $taskkillPath = Join-Path $env:SystemRoot 'System32\taskkill.exe'
  if (-not (Test-Path -LiteralPath $taskkillPath)) { $taskkillPath = 'taskkill.exe' }
  $stdoutPath = [System.IO.Path]::GetTempFileName()
  $stderrPath = [System.IO.Path]::GetTempFileName()
  $previousErrorActionPreference = $ErrorActionPreference
  $taskkillExitCode = -1
  $taskkillError = ''
  $taskkillOutput = ''
  try {
    $ErrorActionPreference = 'Continue'
    & $taskkillPath /PID $targetPid /F /T 1>$stdoutPath 2>$stderrPath
    $taskkillExitCode = [int]$LASTEXITCODE
    $taskkillOutput = Read-TestTempFirstLine -Path $stdoutPath -Label 'taskkill stdout'
    $taskkillError = Read-TestTempFirstLine -Path $stderrPath -Label 'taskkill stderr'
  } catch {
    $taskkillExitCode = -1
    $taskkillError = $_.Exception.Message
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
    foreach ($path in @($stdoutPath, $stderrPath)) {
      try {
        if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
      } catch {
        [System.Diagnostics.Trace]::TraceError("taskkill temp cleanup failed: " + $_.Exception.Message)
      }
    }
  }
  $Process.Refresh()
  if ($taskkillExitCode -eq 0 -or $Process.HasExited) {
    return [pscustomobject]@{ method = 'taskkill'; taskkillExitCode = $taskkillExitCode; taskkillOutput = $taskkillOutput; taskkillError = $taskkillError }
  }

  Stop-Process -Id $targetPid -Force -ErrorAction Stop
  return [pscustomobject]@{ method = 'stop-process'; taskkillExitCode = $taskkillExitCode; taskkillOutput = $taskkillOutput; taskkillError = $taskkillError }
}

$proc = $null
$proc2 = $null
$waitExited = $false
$timedOutPath = $false
$timedOutFallback = $false
$killMethod = ''
$taskkillExitCode = $null
$taskkillError = ''
$taskkillOutput = ''

try {
  $proc = Start-Process powershell.exe -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 30' -WindowStyle Hidden -PassThru
  Start-Sleep -Milliseconds 300
  $killResult = Stop-TestProcessTree -Process $proc
  $killMethod = $killResult.method
  $taskkillExitCode = $killResult.taskkillExitCode
  $taskkillError = $killResult.taskkillError
  $taskkillOutput = $killResult.taskkillOutput
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
    if ($p) {
      try { $p.Dispose() }
      catch { [System.Diagnostics.Trace]::TraceError("test process dispose failed: " + $_.Exception.Message) }
    }
  }
}

$testPassed = $waitExited -and $timedOutPath -and -not $timedOutFallback
if (-not $testPassed) {
  throw ("supervisor zombie reap smoke failed: waitExited=" + $waitExited + " timedOutPath=" + $timedOutPath + " timedOutFallback=" + $timedOutFallback)
}

[ordered]@{
  waitExited = $waitExited
  timedOutPath = $timedOutPath
  timedOutFallback = $timedOutFallback
  killMethod = $killMethod
  taskkillExitCode = $taskkillExitCode
  taskkillOutput = $taskkillOutput
  taskkillError = $taskkillError
  testPassed = $testPassed
} | ConvertTo-Json -Depth 5 -Compress
