#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$bridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $bridgeRoot 'lib\common.ps1')

$script:Failures = New-Object System.Collections.ArrayList
$script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-state-sha256-test-' + [guid]::NewGuid().ToString('N'))
$script:TestStatePath = Join-Path $script:TestRoot 'state.json'
$script:SleepCalls = 0
$script:ReadStateRetrySleepCalls = 0

function Add-Pass {
  param([string]$Name)
  Write-Host ("PASS {0}" -f $Name)
}

function Add-Fail {
  param([string]$Name, [string]$Detail = '')
  $msg = if ([string]::IsNullOrWhiteSpace($Detail)) { $Name } else { "$Name -- $Detail" }
  [void]$script:Failures.Add($msg)
  Write-Host ("FAIL {0}" -f $msg)
}

function Assert-True {
  param([string]$Name, [bool]$Condition, [string]$Detail = '')
  if ($Condition) { Add-Pass $Name } else { Add-Fail $Name $Detail }
}

function New-TestState {
  param([string]$Status = 'ok', [int]$Seq = 1)
  return [pscustomobject][ordered]@{
    status    = $Status
    lastSeq   = $Seq
    paused    = $false
    stop      = $false
    abort     = $false
    heartbeat = '2026-06-19T00:00:00Z'
  }
}

function Reset-TestFiles {
  if (Test-Path -LiteralPath $script:TestRoot) {
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
}

function Get-RawHash {
  param([string]$Path)
  $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  return Get-StateContentHash -Content $raw
}

function Write-PlainState {
  param([object]$State)
  $json = $State | ConvertTo-Json -Depth 10
  [System.IO.File]::WriteAllText($script:TestStatePath, $json, (New-Object System.Text.UTF8Encoding($false)))
  return $json
}

function Set-TestSidecarForState {
  [System.IO.File]::WriteAllText(($script:TestStatePath + '.sha256'), (Get-RawHash -Path $script:TestStatePath), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-BridgeRoot { return $script:TestRoot }
function Get-StatePath { return $script:TestStatePath }
function Start-Sleep {
  param([int]$Milliseconds)
  $script:SleepCalls++
  if ($Milliseconds -eq 50) { $script:ReadStateRetrySleepCalls++ }
}

try {
  Reset-TestFiles

  Write-State -State (New-TestState -Status 'written' -Seq 10)
  $mainHashPath = $script:TestStatePath + '.sha256'
  Assert-True 'Write-State creates .sha256 sidecar' (Test-Path -LiteralPath $mainHashPath)
  $expectedHash = Get-RawHash -Path $script:TestStatePath
  $actualHash = ([System.IO.File]::ReadAllText($mainHashPath, [System.Text.Encoding]::UTF8)).Trim()
  Assert-True 'Write-State sidecar contains SHA256 of state.json' ($expectedHash -eq $actualHash) "expected=$expectedHash actual=$actualHash"
  Assert-True 'Write-State creates backup .sha256 sidecar' (Test-Path -LiteralPath ($script:TestStatePath + '.bak.sha256'))

  $read = Read-State
  Assert-True 'Read-State accepts matching .sha256 sidecar' ($null -ne $read -and [string]$read.status -eq 'written') ("status={0}" -f $(if($read){$read.status}else{'<null>'}))

  Reset-TestFiles
  $backupState = New-TestState -Status 'backup' -Seq 21
  $liveState = New-TestState -Status 'live' -Seq 22
  $backupJson = Write-PlainState -State $backupState
  [System.IO.File]::WriteAllText(($script:TestStatePath + '.bak'), $backupJson, (New-Object System.Text.UTF8Encoding($false)))
  [void](Write-PlainState -State $liveState)
  Set-TestSidecarForState
  [void](Write-PlainState -State (New-TestState -Status 'torn' -Seq 23))
  $script:SleepCalls = 0
  $script:ReadStateRetrySleepCalls = 0
  $restored = Read-State
  Assert-True 'Read-State hash mismatch restores from backup' ($null -ne $restored -and [string]$restored.status -eq 'backup') ("status={0}" -f $(if($restored){$restored.status}else{'<null>'}))
  Assert-True 'Read-State hash mismatch bypasses JSON retry sleeps' ($script:ReadStateRetrySleepCalls -eq 0) ("retry_sleep_calls={0}; all_sleep_calls={1}" -f $script:ReadStateRetrySleepCalls, $script:SleepCalls)
  $postRestoreHash = ([System.IO.File]::ReadAllText(($script:TestStatePath + '.sha256'), [System.Text.Encoding]::UTF8)).Trim()
  Assert-True 'Restore-StateFromBackup refreshes main .sha256 sidecar' ($postRestoreHash -eq (Get-RawHash -Path $script:TestStatePath)) "sidecar=$postRestoreHash"
  $qDirAfterRestore = Join-Path $script:TestRoot 'control\quarantine'
  $qCountBeforeSecondRead = 0
  if (Test-Path -LiteralPath $qDirAfterRestore) {
    $qCountBeforeSecondRead = @(Get-ChildItem -LiteralPath $qDirAfterRestore -Filter 'state-torn-*.json' -File).Count
  }
  $secondRead = Read-State
  $qCountAfterSecondRead = 0
  if (Test-Path -LiteralPath $qDirAfterRestore) {
    $qCountAfterSecondRead = @(Get-ChildItem -LiteralPath $qDirAfterRestore -Filter 'state-torn-*.json' -File).Count
  }
  Assert-True 'Read-State after restore does not re-quarantine restored state' ($qCountAfterSecondRead -eq $qCountBeforeSecondRead -and $null -ne $secondRead -and [string]$secondRead.status -eq 'backup') ("before={0} after={1}" -f $qCountBeforeSecondRead, $qCountAfterSecondRead)

  Reset-TestFiles
  [void](Write-PlainState -State (New-TestState -Status 'legacy' -Seq 30))
  $legacy = Read-State
  Assert-True 'Read-State without .sha256 remains backward compatible' ($null -ne $legacy -and [string]$legacy.status -eq 'legacy') ("status={0}" -f $(if($legacy){$legacy.status}else{'<null>'}))

  Reset-TestFiles
  $backupState = New-TestState -Status 'backup-bitflip' -Seq 41
  $backupJson = Write-PlainState -State $backupState
  [System.IO.File]::WriteAllText(($script:TestStatePath + '.bak'), $backupJson, (New-Object System.Text.UTF8Encoding($false)))
  [void](Write-PlainState -State (New-TestState -Status 'bitflip-original' -Seq 42))
  Set-TestSidecarForState
  $bitflipJson = '{"status":"bitflip","lastSeq":43,"paused":false,"stop":false,"abort":false,"heartbeat":"2026-06-19T00:00:00Z"}'
  [System.IO.File]::WriteAllText($script:TestStatePath, $bitflipJson, (New-Object System.Text.UTF8Encoding($false)))
  $bitflip = Read-State
  $qDir = Join-Path $script:TestRoot 'control\quarantine'
  $qCount = 0
  if (Test-Path -LiteralPath $qDir) {
    $qCount = @(Get-ChildItem -LiteralPath $qDir -Filter 'state-torn-*.json' -File).Count
  }
  Assert-True 'Read-State quarantines JSON bitflip with mismatched .sha256' ($qCount -ge 1) ("quarantine_count={0}" -f $qCount)
  Assert-True 'Read-State restores backup after JSON bitflip mismatch' ($null -ne $bitflip -and [string]$bitflip.status -eq 'backup-bitflip') ("status={0}" -f $(if($bitflip){$bitflip.status}else{'<null>'}))

  Reset-TestFiles
  [void](Write-PlainState -State (New-TestState -Status 'empty-sidecar' -Seq 50))
  [System.IO.File]::WriteAllText(($script:TestStatePath + '.sha256'), '', (New-Object System.Text.UTF8Encoding($false)))
  $emptySidecar = Read-State
  Assert-True 'Read-State ignores empty .sha256 sidecar' ($null -ne $emptySidecar -and [string]$emptySidecar.status -eq 'empty-sidecar') ("status={0}" -f $(if($emptySidecar){$emptySidecar.status}else{'<null>'}))
} catch {
  Add-Fail 'unhandled exception' $_.Exception.Message
} finally {
  try { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

if ($script:Failures.Count -gt 0) {
  Write-Host ("RESULT FAIL count={0}" -f $script:Failures.Count)
  exit 1
}

Write-Host 'RESULT PASS'
exit 0
