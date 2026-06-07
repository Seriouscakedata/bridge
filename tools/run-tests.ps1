# run-tests.ps1 -- consolidated gate/regression suite runner for the bridge (Hardening Roadmap E).
# Runs every tools/test-*.ps1 in an isolated child process and reports a single pass/fail summary.
# Exit 0 = all passed; Exit 1 = one or more failed. This is the operational "are all gates green?"
# check: the bridge can run it before/after any control-plane self-modification so a gate change
# cannot regress a sibling gate (the gate-cascade root). Each test owns its own sandbox.
param(
  [int]$TimeoutSec = 120,
  [string]$Filter = 'test-*.ps1',
  [string[]]$Only = @(),
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$toolsDir = $PSScriptRoot
$bridgeRoot = Split-Path -Parent $toolsDir
try { $ps = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { $ps = '' }
if ([string]::IsNullOrWhiteSpace($ps) -or -not (Test-Path -LiteralPath $ps)) {
  throw 'Cannot resolve current PowerShell executable for isolated test runner.'
}

function Join-TestProcessArguments {
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

$testFiles = @(Get-ChildItem -LiteralPath $toolsDir -Filter $Filter -File -ErrorAction SilentlyContinue | Sort-Object Name)
if ($Only.Count -gt 0) {
  $testFiles = @($testFiles | Where-Object {
    $name = $_.Name
    @($Only | Where-Object { $name -like ("*" + $_ + "*") }).Count -gt 0
  })
}

$results = New-Object System.Collections.Generic.List[object]
foreach ($t in $testFiles) {
  $tmpOut = [System.IO.Path]::GetTempFileName()
  $tmpErr = [System.IO.Path]::GetTempFileName()
  $ok = $false; $code = -1; $tail = ''
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ps
    $psi.Arguments = Join-TestProcessArguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $t.FullName)
    $psi.WorkingDirectory = $bridgeRoot
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if ($proc.WaitForExit($TimeoutSec * 1000)) {
      $proc.WaitForExit()
      $code = [int]$proc.ExitCode
      $ok = ($code -eq 0)
      try { [System.IO.File]::WriteAllText($tmpOut, [string]$outTask.Result, (New-Object System.Text.UTF8Encoding($false))) } catch {}
      try { [System.IO.File]::WriteAllText($tmpErr, [string]$errTask.Result, (New-Object System.Text.UTF8Encoding($false))) } catch {}
    } else {
      try { $proc.Kill() } catch {}
      $code = 124
      $tail = ("TIMEOUT after {0}s" -f $TimeoutSec)
    }
  } catch {
    $tail = $_.Exception.Message
  }
  if ([string]::IsNullOrWhiteSpace($tail)) {
    $lines = @()
    try { $lines = @(Get-Content -LiteralPath $tmpOut -ErrorAction SilentlyContinue) } catch {}
    if ($lines.Count -eq 0) { try { $lines = @(Get-Content -LiteralPath $tmpErr -ErrorAction SilentlyContinue) } catch {} }
    if ($lines.Count -gt 0) { $tail = [string]($lines[-1]) }
  }
  Remove-Item -LiteralPath $tmpOut, $tmpErr -Force -ErrorAction SilentlyContinue
  $results.Add([pscustomobject]@{ name = $t.Name; ok = $ok; code = $code; tail = [string]$tail })
  if (-not $Quiet) {
    $tag = if ($ok) { 'PASS' } else { 'FAIL' }
    Write-Host ("{0,-5} {1}" -f $tag, $t.Name)
  }
}

$arr = @($results.ToArray())
$failed = @($arr | Where-Object { -not $_.ok })
$passCount = $arr.Count - $failed.Count
Write-Host ''
Write-Host ("=== gate-regression suite: {0}/{1} passed, {2} failed ===" -f $passCount, $arr.Count, $failed.Count)
foreach ($f in $failed) { Write-Host ("  FAIL {0} (exit {1}): {2}" -f $f.name, $f.code, $f.tail) }
if ($failed.Count -gt 0) { exit 1 }
exit 0
