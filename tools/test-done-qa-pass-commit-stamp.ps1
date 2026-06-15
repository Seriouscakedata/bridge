#Requires -Version 5.1
param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$script:PassCount = 0
$script:FailCount = 0

if ($PSVersionTable.PSVersion.Major -ge 7) {
  $PSNativeCommandUseErrorActionPreference = $false
}

. (Join-Path $BridgeRoot 'lib\backlog-crud.ps1')
. (Join-Path $BridgeRoot 'lib\backlog-core.ps1')
. (Join-Path $BridgeRoot 'lib\backlog-io.ps1')

function Enable-GitSafeDirectoryForProcess {
  param([Parameter(Mandatory = $true)][string]$Path)

  $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
  $count = 0
  if (-not [int]::TryParse([string]$env:GIT_CONFIG_COUNT, [ref]$count)) {
    $count = 0
  }

  Set-Item -Path ("Env:GIT_CONFIG_KEY_{0}" -f $count) -Value 'safe.directory'
  Set-Item -Path ("Env:GIT_CONFIG_VALUE_{0}" -f $count) -Value $resolvedPath
  $env:GIT_CONFIG_COUNT = [string]($count + 1)
}

function Assert-True {
  param(
    [Parameter(Mandatory = $true)][bool]$Condition,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if ($Condition) {
    $script:PassCount++
    Write-Host "PASS: $Label"
    return
  }

  $script:FailCount++
  Write-Host "FAIL: $Label"
}

function New-MockBacklogItem {
  param([hashtable]$Props)

  $item = [PSCustomObject]@{}
  foreach ($name in $Props.Keys) {
    $item | Add-Member -NotePropertyName $name -NotePropertyValue $Props[$name] -Force
  }
  return $item
}

function Test-DoneQaPassCommitFastPath {
  param($Item, [string]$BridgeRoot)
  if (-not ($Item.PSObject.Properties.Name -contains 'done_qa_pass_commit')) { return $false }
  $sha = ([string]$Item.done_qa_pass_commit).Trim()
  if ([string]::IsNullOrWhiteSpace($sha)) { return $false }
  $out = ''
  try {
    $out = ([string](& git -C $BridgeRoot rev-parse --verify ($sha + '^{commit}') 2>$null | Out-String)).Trim()
  } catch {
    $out = ''
  }
  return (-not [string]::IsNullOrWhiteSpace($out))
}

Enable-GitSafeDirectoryForProcess -Path $BridgeRoot

Write-Host "=== done_qa_pass_commit fast-path ==="

Write-Host "--- Scenario 1: field missing -> fast-path does not trigger ---"
$item1 = New-MockBacklogItem @{
  id = 'item-001'
  status = 'done'
}
Assert-True (-not (Test-DoneQaPassCommitFastPath -Item $item1 -BridgeRoot $BridgeRoot)) 'Scenario 1: missing field returns false'

Write-Host "--- Scenario 2: empty string -> fast-path does not trigger ---"
$item2 = New-MockBacklogItem @{
  id = 'item-002'
  status = 'done'
  done_qa_pass_commit = ''
}
Assert-True (-not (Test-DoneQaPassCommitFastPath -Item $item2 -BridgeRoot $BridgeRoot)) 'Scenario 2: empty string returns false'

Write-Host "--- Scenario 3: nonexistent sha -> fast-path does not trigger ---"
$item3 = New-MockBacklogItem @{
  id = 'item-003'
  status = 'done'
  done_qa_pass_commit = 'nonexistent_sha_xyz'
}
Assert-True (-not (Test-DoneQaPassCommitFastPath -Item $item3 -BridgeRoot $BridgeRoot)) 'Scenario 3: nonexistent sha returns false'

Write-Host "--- Scenario 4: HEAD sha -> fast-path triggers ---"
$headSha = ([string](& git -C $BridgeRoot rev-parse HEAD | Out-String)).Trim()
Assert-True (-not [string]::IsNullOrWhiteSpace($headSha)) 'Scenario 4 setup: HEAD sha resolved'
$item4 = New-MockBacklogItem @{
  id = 'item-004'
  status = 'done'
  done_qa_pass_commit = $headSha
}
Assert-True (Test-DoneQaPassCommitFastPath -Item $item4 -BridgeRoot $BridgeRoot) 'Scenario 4: HEAD sha returns true'

Write-Host "--- Scenario 5: null value -> fast-path does not trigger ---"
$item5 = New-MockBacklogItem @{
  id = 'item-005'
  status = 'done'
  done_qa_pass_commit = $null
}
Assert-True (-not (Test-DoneQaPassCommitFastPath -Item $item5 -BridgeRoot $BridgeRoot)) 'Scenario 5: null returns false'

Write-Host "--- Scenario 6: canary child skips when parent has done_qa_pass_commit ---"
$parent6 = New-MockBacklogItem @{
  id = 'parent-006'
  status = 'done'
  done_qa_pass_commit = $headSha
}
$child6 = New-MockBacklogItem @{
  id = 'child-006'
  status = 'new'
  tags = @('bridge-self-canary-gate')
  canary_gate_parent_id = 'parent-006'
}
$result6 = Test-CanaryGateChildAlreadyVerified -Item $child6 -AllItems @($parent6, $child6)
Assert-True ([bool]$result6.verified) 'Scenario 6: canary child reports verified'
Assert-True (([string]$result6.reason).Contains('done_qa_pass_commit')) 'Scenario 6: reason mentions done_qa_pass_commit'

Write-Host ("{0} passed, {1} failed" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
exit 0




