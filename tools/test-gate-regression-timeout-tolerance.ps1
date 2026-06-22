#Requires -Version 5.1
# Tests that run-tests.ps1 treats per-test timeouts as inconclusive, not failures,
# so the suite exits 0 and does not block DONE-gate.
$ErrorActionPreference = 'Stop'

$Pass = 0; $Fail = 0
function Assert { param([string]$Name,[bool]$Condition,[string]$Detail='')
  if ($Condition) { $script:Pass++; Write-Host "PASS: $Name" }
  else { $script:Fail++; Write-Host "FAIL: $Name$(if($Detail){" :: $Detail"})"}
}

$toolsDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $toolsDir
$runTests  = Join-Path $toolsDir 'run-tests.ps1'
$verifySelftest = Join-Path $repoRoot 'lib\verify-selftest.ps1'
$ps = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
if (-not (Test-Path -LiteralPath $ps)) { $ps = Join-Path $PSHOME 'powershell.exe' }

# Unique prefix so -OnlyCsv matches only our temp files (run-tests.ps1 scans $PSScriptRoot = tools/)
$uid = 'grtt-' + [guid]::NewGuid().ToString('N').Substring(0,8)
$hangFile = Join-Path $toolsDir ("test-$uid-hang.ps1")
$passFile = Join-Path $toolsDir ("test-$uid-pass.ps1")

try {
  [System.IO.File]::WriteAllText($hangFile, "Start-Sleep 999`n", (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText($passFile, "Write-Host 'ok'; exit 0`n", (New-Object System.Text.UTF8Encoding($false)))

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ps
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runTests`" -NoSnapshot -TimeoutSec 3 -OnlyCsv `"$uid`""
  $psi.WorkingDirectory = $toolsDir
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  $finished = $proc.WaitForExit(30000)
  if (-not $finished) { try { $proc.Kill() } catch {} }
  try { $proc.WaitForExit() | Out-Null } catch {}
  try { $outTask.Wait(3000) | Out-Null } catch {}
  $exitCode = if ($finished) { [int]$proc.ExitCode } else { -1 }
  $out = if ($outTask.IsCompleted) { [string]$outTask.Result } else { '' }

  Assert 'suite exits 0 with only inconclusive tests' ($exitCode -eq 0) "exit=$exitCode"
  Assert 'output contains INCONCL for timed-out test' ($out -match 'INCONCL') $out
  Assert 'output contains PASS for passing test' ($out -match 'PASS') $out
  Assert 'output does not contain FAIL for timed-out test' ($out -notmatch '\bFAIL\b.*hang') $out
  Assert 'summary shows 0 failed' ($out -match '0 failed') $out
  Assert 'summary shows 1 inconclusive' ($out -match '1 inconclusive') $out
} finally {
  Remove-Item -LiteralPath $hangFile -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $passFile -Force -ErrorAction SilentlyContinue
}

. $verifySelftest
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-grtt-suite-' + [guid]::NewGuid().ToString('N').Substring(0,8))
try {
  New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'tools') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'lib') -Force | Out-Null
  Copy-Item -LiteralPath $runTests -Destination (Join-Path $tmpRoot 'tools\run-tests.ps1') -Force
  [System.IO.File]::WriteAllText((Join-Path $tmpRoot 'lib\foo.ps1'), "function Test-Foo { 'ok' }`n", (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText((Join-Path $tmpRoot 'tools\test-foo-hang.ps1'), "Start-Sleep 999`n", (New-Object System.Text.UTF8Encoding($false)))
  & git -C $tmpRoot init | Out-Null
  & git -C $tmpRoot -c user.name=bridge-test -c user.email=bridge-test@example.invalid add . | Out-Null
  & git -C $tmpRoot -c user.name=bridge-test -c user.email=bridge-test@example.invalid commit -m init | Out-Null

  $suite = Invoke-GateRegressionSuite -BridgeRoot $tmpRoot -TimeoutSec 3 -ChangedPaths @('lib/foo.ps1')
  Assert 'scoped suite uses caller timeout as wrapper cap' ([bool]$suite.TimedOut -and [int]$suite.ExitCode -eq 124) ("exit=$($suite.ExitCode) timedOut=$($suite.TimedOut)")
  Assert 'scoped suite does not use selected-test expansion budget' ($suite.Elapsed.TotalSeconds -lt 15) ("elapsed=$($suite.Elapsed.TotalSeconds)")
} finally {
  Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "gate-regression-timeout-tolerance: $Pass PASS, $Fail FAIL"
if ($Fail -gt 0) { exit 1 }
exit 0
