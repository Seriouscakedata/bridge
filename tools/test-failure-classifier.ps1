param()

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-failure-classifier-test-' + [guid]::NewGuid().ToString('N'))
$script:EffectiveChannel = 'main'
$script:ClassifierCalls = 0

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-BridgeRoot { return $script:TestBridgeRoot }
function Get-EffectiveChannel { return $script:EffectiveChannel }
function Get-ChannelDir {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = 'main' }
  return (Join-Path (Join-Path $script:TestBridgeRoot 'channels') $Slug)
}
function Get-ChannelBacklogPath {
  param([string]$Slug = $null)
  return (Join-Path (Get-ChannelDir -Slug $Slug) 'backlog.jsonl')
}
function Use-BridgeLock {
  param([scriptblock]$Body)
  & $Body
}

try {
  $mainDir = Get-ChannelDir -Slug 'main'
  New-Item -ItemType Directory -Path $mainDir -Force | Out-Null
  $backlogPath = Get-ChannelBacklogPath -Slug 'main'
  $items = @(
    [ordered]@{ id='failed-existing'; ts='2026-06-04T00:00:00Z'; status='failed'; text='existing flaky failure'; reason='timeout'; fail_class='flaky' },
    [ordered]@{ id='failed-new-bug'; ts='2026-06-04T00:01:00Z'; status='failed'; text='smoke reports parse regression'; reason='smoke failed' },
    [ordered]@{ id='failed-new-blocked'; ts='2026-06-04T00:02:00Z'; status='failed'; text='requires operator approval for forbidden scope'; reason='hard constraint conflict' },
    [ordered]@{ id='done-ignore'; ts='2026-06-04T00:03:00Z'; status='done'; text='not failed'; reason='' }
  )
  $jsonl = (($items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join "`n") + "`n"
  [System.IO.File]::WriteAllText($backlogPath, $jsonl, (New-Object System.Text.UTF8Encoding($false)))

  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\backlog.ps1')

  $mock = {
    param($Item)
    $script:ClassifierCalls++
    if ([string]$Item.id -eq 'failed-new-bug') { return 'real-bug' }
    if ([string]$Item.id -eq 'failed-new-blocked') { return 'blocked' }
    return 'spec-unclear'
  }

  $result = Update-BacklogFailureClasses -BacklogPath $backlogPath -Classifier $mock
  Assert-True ([int]$result.checked -eq 3) ("expected checked=3, got {0}" -f [int]$result.checked)
  Assert-True ([int]$result.updated -eq 2) ("expected updated=2, got {0}" -f [int]$result.updated)
  Assert-True ([int]$script:ClassifierCalls -eq 2) ("expected classifier calls=2, got {0}" -f [int]$script:ClassifierCalls)

  $saved = @(Get-Backlog)
  $byId = @{}
  foreach ($item in $saved) { $byId[[string]$item.id] = $item }
  Assert-True ([string]$byId['failed-existing'].fail_class -eq 'flaky') 'existing fail_class was overwritten'
  Assert-True ([string]$byId['failed-new-bug'].fail_class -eq 'real-bug') 'new real-bug class was not stored'
  Assert-True ([string]$byId['failed-new-blocked'].fail_class -eq 'blocked') 'new blocked class was not stored'

  $allowed = @(Get-BacklogFailureClassValues)
  foreach ($item in @($saved | Where-Object { [string]$_.status -eq 'failed' })) {
    Assert-True ($allowed -contains [string]$item.fail_class) ("invalid fail_class for {0}: {1}" -f [string]$item.id, [string]$item.fail_class)
  }

  $groups = Get-BacklogFailureClassGroups -Items $saved
  Assert-True ($groups['flaky'].Count -eq 1) 'expected one flaky failure'
  Assert-True ($groups['real-bug'].Count -eq 1) 'expected one real-bug failure'
  Assert-True ($groups['blocked'].Count -eq 1) 'expected one blocked failure'
  Assert-True ($groups['unclassified'].Count -eq 0) 'expected no unclassified failures'

  $pulseLibDir = Join-Path $script:TestBridgeRoot 'lib'
  New-Item -ItemType Directory -Path $pulseLibDir -Force | Out-Null
  $repoLibDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
  foreach ($backlogLib in @(Get-ChildItem -LiteralPath $repoLibDir -Filter 'backlog*.ps1' -File)) {
    Copy-Item -LiteralPath $backlogLib.FullName -Destination (Join-Path $pulseLibDir $backlogLib.Name) -Force
  }
  $pulseScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\operator-pulse.ps1'
  $oldBridgeRoot = [string]$env:BRIDGE_ROOT
  $env:BRIDGE_ROOT = $script:TestBridgeRoot
  try {
    $pulseOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $pulseScript -Channel main 2>&1
  } finally {
    $env:BRIDGE_ROOT = $oldBridgeRoot
  }
  $pulseText = ($pulseOut | Out-String)
  Assert-True ($pulseText -match 'FAILED blocked \(1\)') 'operator-pulse did not group blocked failures'
  Assert-True ($pulseText -match 'FAILED real-bug \(1\)') 'operator-pulse did not group real-bug failures'
  Assert-True ($pulseText -match 'FAILED flaky \(1\)') 'operator-pulse did not group flaky failures'

  Write-Host 'failure-classifier tests: PASS'
} finally {
  try { if (Test-Path -LiteralPath $script:TestBridgeRoot) { Remove-Item -LiteralPath $script:TestBridgeRoot -Recurse -Force -ErrorAction SilentlyContinue } } catch {}
}
