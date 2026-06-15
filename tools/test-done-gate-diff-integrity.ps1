# test-done-gate-diff-integrity.ps1 - unit tests for Test-DoneGateDiffIntegrity
param([string]$BridgeRoot = $null)

if ([string]::IsNullOrWhiteSpace($BridgeRoot)) { $BridgeRoot = Split-Path -Parent $PSScriptRoot }

$d86 = Join-Path $BridgeRoot 'driver\86-loop-completion-checks.ps1'
$src = [System.IO.File]::ReadAllText($d86, [System.Text.Encoding]::UTF8)
$fnStart = $src.IndexOf('function Test-DoneGateDiffIntegrity')
$fnEnd = $src.IndexOf('function New-DriverDoneGatePlan', $fnStart)
if ($fnStart -lt 0 -or $fnEnd -le $fnStart) {
  Write-Error 'Test-DoneGateDiffIntegrity function block not found'
  exit 1
}
Invoke-Expression $src.Substring($fnStart, $fnEnd - $fnStart)

$pass = 0
$fail = 0
function Assert-Equal {
  param($Actual, $Expected, [string]$Message)
  if ($Actual -eq $Expected) {
    $script:pass++
  } else {
    $script:fail++
    Write-Host "FAIL $Message : got '$Actual' expected '$Expected'"
  }
}

$r = Test-DoneGateDiffIntegrity -CommitSha '' -BridgeRoot $BridgeRoot
Assert-Equal $r.ok $false 'missing args ok'
Assert-Equal $r.reason 'missing-args' 'missing args reason'

$head = (& git -c "safe.directory=$BridgeRoot" -C $BridgeRoot rev-parse HEAD 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($head)) {
  Write-Error 'git rev-parse HEAD returned empty output'
  exit 1
}

$r2 = Test-DoneGateDiffIntegrity -CommitSha $head -BridgeRoot $BridgeRoot -DeclaredFiles @()
Assert-Equal $r2.ok $true 'HEAD no declared files ok'
Assert-Equal $r2.reason 'no-declared-files' 'HEAD no declared files reason'

if ($r2.changedFiles.Count -le 0) {
  $fail++
  Write-Host 'FAIL HEAD changed files should not be empty'
} else {
  $pass++
}

$declared = @([string]$r2.changedFiles[0])
$r3 = Test-DoneGateDiffIntegrity -CommitSha $head -BridgeRoot $BridgeRoot -DeclaredFiles $declared
Assert-Equal $r3.ok $true 'declared overlap ok'
Assert-Equal $r3.reason 'overlap-found' 'declared overlap reason'

$r4 = Test-DoneGateDiffIntegrity -CommitSha $head -BridgeRoot $BridgeRoot -DeclaredFiles @('definitely/not/in/head.diff')
Assert-Equal $r4.ok $false 'foreign diff ok'
Assert-Equal $r4.reason 'foreign-diff' 'foreign diff reason'

Write-Host "Results: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
