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

# Test: Partial overlap - declared set has one changed file and one unrelated file.
$partialDeclared = @([string]$r2.changedFiles[0], 'definitely/not/here/fake.txt')
$rPartial = Test-DoneGateDiffIntegrity -CommitSha $head -BridgeRoot $BridgeRoot -DeclaredFiles $partialDeclared
Assert-Equal $rPartial.ok $true 'partial overlap ok'
Assert-Equal $rPartial.reason 'overlap-found' 'partial overlap reason'
if ($rPartial.overlap.Count -ge 1) { $pass++ } else { $fail++; Write-Host "FAIL partial overlap count: $($rPartial.overlap.Count)" }

# Test: Empty diff - create a commit object with the same tree and no file changes.
$emptyCommitSha = $null
try {
  $treeRef = (& git -c "safe.directory=$BridgeRoot" -C $BridgeRoot rev-parse ('HEAD^{tree}') 2>$null | Out-String).Trim()
  if (-not [string]::IsNullOrWhiteSpace($treeRef)) {
    $emptyCommitSha = (& git -c "safe.directory=$BridgeRoot" -C $BridgeRoot commit-tree $treeRef -p HEAD -m 'test-empty-diff-for-gate' 2>$null | Out-String).Trim()
  }
} catch {}
if ([string]::IsNullOrWhiteSpace($emptyCommitSha)) {
  try {
    $emptyCommitSha = (& git -c "safe.directory=$BridgeRoot" -C $BridgeRoot rev-list --max-parents=0 HEAD 2>$null | Select-Object -First 1 | Out-String).Trim()
  } catch {}
}
if (-not [string]::IsNullOrWhiteSpace($emptyCommitSha)) {
  $rEmpty = Test-DoneGateDiffIntegrity -CommitSha $emptyCommitSha -BridgeRoot $BridgeRoot
  Assert-Equal $rEmpty.ok $false 'empty diff commit ok'
  Assert-Equal $rEmpty.reason 'empty-diff' 'empty diff commit reason'
} else {
  $fail++
  Write-Host 'FAIL empty-diff: could not create test commit-tree object'
}

# Test: Write-DiffIntegrityDecision creates a decisions file with expected fields.
$evPath = Join-Path $BridgeRoot 'lib\task-action-evidence.ps1'
if (Test-Path $evPath -PathType Leaf) {
  try { . $evPath } catch {}
}
if (Get-Command Write-DiffIntegrityDecision -ErrorAction SilentlyContinue) {
  $mockResult = [pscustomobject]@{ ok=$false; reason='empty-diff'; changedFiles=@(); overlap=@() }
  $decFile = Write-DiffIntegrityDecision -CommitSha 'deadbeef' -BridgeRoot $BridgeRoot -CheckResult $mockResult -DeclaredFiles @('test.ps1') -BacklogId 'unit-test-id'
  if ($null -ne $decFile -and (Test-Path $decFile -PathType Leaf)) {
    $pass++
    try {
      $decObj = [System.IO.File]::ReadAllText($decFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      Assert-Equal $decObj.result 'failed' 'decisions result field'
      Assert-Equal $decObj.reason 'empty-diff' 'decisions reason field'
      Remove-Item $decFile -Force -ErrorAction SilentlyContinue
    } catch { $fail++; Write-Host "FAIL decisions file content: $_" }
  } else {
    $fail++; Write-Host "FAIL Write-DiffIntegrityDecision: file not created (path=$decFile)"
  }
} else {
  $fail++; Write-Host 'FAIL Write-DiffIntegrityDecision: function not loaded'
}

Write-Host "Results: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
