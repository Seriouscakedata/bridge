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
$runTests  = Join-Path $toolsDir 'run-tests.ps1'
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

Write-Host ''
Write-Host "gate-regression-timeout-tolerance: $Pass PASS, $Fail FAIL"
if ($Fail -gt 0) { exit 1 }
exit 0
