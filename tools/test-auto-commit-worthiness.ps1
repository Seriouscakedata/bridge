#Requires -Version 5.1
# test-auto-commit-worthiness.ps1 -- bridge auto-commit path filtering fixtures.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\auto-commit-worthiness.ps1')

$script:pass = 0
$script:fail = 0

function Check {
  param(
    [string]$Name,
    [bool]$Condition,
    [object]$Actual = $null
  )
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:fail++
    $suffix = if ($null -ne $Actual) { " actual=" + ($Actual | ConvertTo-Json -Compress -Depth 6) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

function Get-WorthyPaths {
  param([string[]]$StatusLines)
  $paths = @($StatusLines | ForEach-Object { Normalize-AutoCommitStatusPath -StatusLine $_ } | Where-Object { $_ })
  return @($paths | Where-Object { Test-BridgeAutoCommitWorthPath -Path $_ })
}

$telemetryOnly = @(
  ' M channels/main/task-management-shadow.jsonl',
  '?? channels/foo/some-shadow.jsonl',
  ' M channels/foo/driver.log',
  ' M logs/driver.log',
  ' M audit/latest.json',
  ' M control/restart.flag',
  ' M turns.jsonl',
  ' M decisions/session-ledger.jsonl',
  ' M features/state.json',
  ' M channels/main/state.json',
  ' M channels/main/conversation.jsonl'
)
$telemetryWorthy = @(Get-WorthyPaths -StatusLines $telemetryOnly)
Check 'telemetry-only dirty status has no commit-worthy paths' ($telemetryWorthy.Count -eq 0) $telemetryWorthy

$realChanges = @(
  ' M driver/83-loop-agent-turn.ps1',
  ' M tools/test-auto-commit-worthiness.ps1',
  ' M docs/example.md',
  ' M config.json',
  ' M lib/common.ps1'
)
$realWorthy = @(Get-WorthyPaths -StatusLines $realChanges)
foreach ($path in @('driver/83-loop-agent-turn.ps1','tools/test-auto-commit-worthiness.ps1','docs/example.md','config.json','lib/common.ps1')) {
  Check ("real path remains commit-worthy: {0}" -f $path) (@($realWorthy) -contains $path) $realWorthy
}

$mixed = @(
  ' M channels/main/task-management-shadow.jsonl',
  ' M docs/notes.md'
)
$mixedWorthy = @(Get-WorthyPaths -StatusLines $mixed)
Check 'mixed telemetry plus doc has a commit-worthy path' (@($mixedWorthy) -contains 'docs/notes.md') $mixedWorthy
Check 'mixed telemetry plus doc excludes telemetry path' ($mixedWorthy.Count -eq 1) $mixedWorthy

$renamed = Normalize-AutoCommitStatusPath -StatusLine 'R  docs/old.md -> docs/new.md'
Check 'renamed porcelain path normalizes to destination' ($renamed -eq 'docs/new.md') $renamed
Check 'renamed destination remains commit-worthy' (Test-BridgeAutoCommitWorthPath -Path $renamed) $renamed

if ($script:fail -gt 0) {
  Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed") -ForegroundColor Red
  exit 1
}

Write-Host ("RESULT: " + $script:pass + " passed, 0 failed") -ForegroundColor Green
