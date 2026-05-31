param()

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-workpack-batch-test-' + [guid]::NewGuid().ToString('N'))

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-BridgeRoot { return $script:TestBridgeRoot }
function Get-EffectiveChannel { return 'main' }
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
function Get-AutonomySettings {
  return [pscustomobject]@{
    workpackExecEnabled = $true
    workpackExecMinItems = 2
    workpackExecMaxItems = 3
    workpackExecIncludeProtected = $false
    backlogPackEnabled = $true
    backlogPackBurstCount = 5
    backlogPackWindowMinutes = 60
    backlogPackUnpackedOpenCount = 8
    backlogPackAuditBurstCount = 3
    backlogPackAuditWindowMinutes = 30
    backlogPackCooldownMinutes = 30
    backlogPackMinItems = 2
  }
}

try {
  $mainDir = Get-ChannelDir -Slug 'main'
  New-Item -ItemType Directory -Path $mainDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug 'main'), '', (New-Object System.Text.UTF8Encoding($false)))

  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\backlog.ps1')

  $idAudit = Add-Idea -Text 'fix audit scenario stale warning in tools/audit-functional.ps1' -From 'test' -Status 'approved' -SkipCurator
  $idMemory = Add-Idea -Text 'tighten memory recall guard in lib/memory.ps1' -From 'test' -Status 'approved' -SkipCurator
  $idAudit2 = Add-Idea -Text 'another audit-only tweak in tools/audit.ps1' -From 'test' -Status 'approved' -SkipCurator
  $idSafety = Add-Idea -Text 'change watchdog safety behavior in watchdog.ps1' -From 'test' -Status 'approved' -SkipCurator

  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idAudit) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-audit' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'audit' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('tools/audit-functional.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idMemory) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-memory' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'memory' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('lib/memory.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idAudit2) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-audit-2' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'audit' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('tools/audit.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idSafety) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-safety' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'safety' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('watchdog.ps1') -Force
    }
  }
  Save-Backlog $items

  $batch = Get-NextBacklogWorkpackBatch
  Assert-True ($batch -ne $null) 'expected a workpack batch'
  Assert-True ([int]$batch.count -eq 2) ("expected 2 selected items, got {0}" -f [int]$batch.count)
  Assert-True (@($batch.ids) -contains [string]$idAudit) 'expected audit item'
  Assert-True (@($batch.ids) -contains [string]$idMemory) 'expected memory item'
  Assert-True (-not (@($batch.ids) -contains [string]$idAudit2)) 'same conflict group should be skipped'
  Assert-True (-not (@($batch.ids) -contains [string]$idSafety)) 'protected safety group should be skipped by default'

  $taskText = New-BacklogWorkpackBatchTaskText -Items @($batch.items)
  Assert-True ($taskText -match '\[\[PARALLEL:wp1\]\]') 'expected parallel template wp1'
  Assert-True ($taskText -match '\[\[PARALLEL:wp2\]\]') 'expected parallel template wp2'
  Assert-True ($taskText -match 'STATUS:\s*CONTINUE') 'expected planner status hint'

  Write-Host ('OK workpack batch: selected {0} independent items' -f [int]$batch.count)
} finally {
  try {
    $resolved = [System.IO.Path]::GetFullPath($script:TestBridgeRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
      Remove-Item -LiteralPath $resolved -Recurse -Force
    }
  } catch {}
}
