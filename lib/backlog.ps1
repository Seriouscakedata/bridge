# backlog.ps1 -- compatibility aggregator for the bridge self-improvement backlog.
# Dot-source this file to load the domain modules that preserve the historical API.

$script:BacklogCuratorModel = 'gemini-2.5-flash-lite'
$script:BacklogLibraryDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }

$script:BacklogModuleDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } elseif (-not [string]::IsNullOrWhiteSpace($script:BacklogLibraryDir)) { $script:BacklogLibraryDir } else { Split-Path -Parent $PSCommandPath }

foreach ($script:BacklogModuleName in @(
  'primitives.ps1',
  'policy.ps1',
  'backlog-io.ps1',
  'backlog-governor.ps1',
  'backlog-crud.ps1',
  'backlog-dedup.ps1',
  'backlog-core.ps1',
  'backlog-autopilot.ps1',
  'backlog-workpack.ps1',
  'backlog-state-reaper.ps1'
)) {
  $script:BacklogModulePath = Join-Path $script:BacklogModuleDir $script:BacklogModuleName
  . $script:BacklogModulePath
}

# Wrap workpack batch helpers here so execution metadata can evolve without
# editing the larger backlog-workpack module in every stream.
if (-not $script:BacklogOriginalGetBacklogWorkpackFrontierReport) {
  try { $script:BacklogOriginalGetBacklogWorkpackFrontierReport = (Get-Command Get-BacklogWorkpackFrontierReport -CommandType Function -ErrorAction Stop).ScriptBlock } catch {}
}
if (-not $script:BacklogOriginalGetNextBacklogWorkpackBatch) {
  try { $script:BacklogOriginalGetNextBacklogWorkpackBatch = (Get-Command Get-NextBacklogWorkpackBatch -CommandType Function -ErrorAction Stop).ScriptBlock } catch {}
}
if (-not $script:BacklogOriginalNewBacklogWorkpackBatchTaskText) {
  try { $script:BacklogOriginalNewBacklogWorkpackBatchTaskText = (Get-Command New-BacklogWorkpackBatchTaskText -CommandType Function -ErrorAction Stop).ScriptBlock } catch {}
}

function Get-BacklogWorkpackPerTaskTimeoutSec {
  return 600
}

function Get-BacklogWorkpackDispatchTimeoutMin {
  param(
    [int]$TaskCount = 1,
    [int]$PerTaskTimeoutSec = 600
  )

  $safeTaskCount = [Math]::Max(1, [int]$TaskCount)
  $safePerTaskTimeoutSec = [Math]::Max(1, [int]$PerTaskTimeoutSec)
  return [int][Math]::Ceiling(($safeTaskCount * $safePerTaskTimeoutSec) / 60.0)
}

function Set-BacklogWorkpackMetadataValue {
  param(
    $Target,
    [string]$Name,
    $Value
  )

  if ($null -eq $Target -or [string]::IsNullOrWhiteSpace($Name)) { return }
  if ($Target -is [System.Collections.IDictionary]) {
    $Target[$Name] = $Value
    return
  }
  try { $Target | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force } catch {}
}

function Add-BacklogWorkpackBatchExecutionMetadata {
  param($Target)

  if ($null -eq $Target) { return $null }

  $items = @()
  try { $items = @((Get-BacklogPackObjectValue -Obj $Target -Name 'items' -Default @()) | Where-Object { $_ }) } catch { $items = @() }

  $count = 0
  try { $count = [int](Get-BacklogPackObjectValue -Obj $Target -Name 'count' -Default 0) } catch { $count = 0 }
  if ($count -lt 1) {
    try { $count = [int](Get-BacklogPackObjectValue -Obj $Target -Name 'selected_count' -Default 0) } catch { $count = 0 }
  }
  if ($count -lt 1) { $count = $items.Count }

  $frontierReport = $null
  try { $frontierReport = Get-BacklogPackObjectValue -Obj $Target -Name 'frontier_report' -Default $null } catch { $frontierReport = $null }
  if ($count -lt 1 -and $frontierReport) {
    try { $count = [int](Get-BacklogPackObjectValue -Obj $frontierReport -Name 'selected_count' -Default 0) } catch { $count = 0 }
  }
  if ($count -lt 1) { $count = 1 }

  $mode = ''
  try { $mode = [string](Get-BacklogPackObjectValue -Obj $Target -Name 'workpack_batch_mode' -Default '') } catch { $mode = '' }
  if ([string]::IsNullOrWhiteSpace($mode) -and $frontierReport) {
    try { $mode = [string](Get-BacklogPackObjectValue -Obj $frontierReport -Name 'workpack_batch_mode' -Default '') } catch { $mode = '' }
  }

  $serialRequired = $false
  try { $serialRequired = [bool](Get-BacklogPackObjectValue -Obj $Target -Name 'serial_required' -Default $false) } catch { $serialRequired = $false }
  if ((-not $serialRequired) -and $frontierReport) {
    try { $serialRequired = [bool](Get-BacklogPackObjectValue -Obj $frontierReport -Name 'serial_required' -Default $false) } catch { $serialRequired = $false }
  }

  $perTaskTimeoutSec = Get-BacklogWorkpackPerTaskTimeoutSec
  $timeoutMin = Get-BacklogWorkpackDispatchTimeoutMin -TaskCount $count -PerTaskTimeoutSec $perTaskTimeoutSec
  $autoParallel = (($mode -eq 'parallel') -and (-not $serialRequired) -and ($count -gt 1))

  foreach ($metaTarget in @($Target, $frontierReport)) {
    if ($null -eq $metaTarget) { continue }
    Set-BacklogWorkpackMetadataValue -Target $metaTarget -Name 'per_task_timeout_sec' -Value $perTaskTimeoutSec
    Set-BacklogWorkpackMetadataValue -Target $metaTarget -Name 'timeout_min' -Value $timeoutMin
    Set-BacklogWorkpackMetadataValue -Target $metaTarget -Name 'parallel_timeout_min' -Value $timeoutMin
    Set-BacklogWorkpackMetadataValue -Target $metaTarget -Name 'auto_parallel' -Value $autoParallel
  }

  return $Target
}

function Get-BacklogWorkpackFrontierReport {
  param($Config = $null)
  if (-not $script:BacklogOriginalGetBacklogWorkpackFrontierReport) { return $null }
  $report = & $script:BacklogOriginalGetBacklogWorkpackFrontierReport -Config $Config
  return (Add-BacklogWorkpackBatchExecutionMetadata -Target $report)
}

function Get-NextBacklogWorkpackBatch {
  param($Config = $null)
  if (-not $script:BacklogOriginalGetNextBacklogWorkpackBatch) { return $null }
  $batch = & $script:BacklogOriginalGetNextBacklogWorkpackBatch -Config $Config
  return (Add-BacklogWorkpackBatchExecutionMetadata -Target $batch)
}

function New-BacklogWorkpackBatchTaskText {
  param([object[]]$Items)

  if (-not $script:BacklogOriginalNewBacklogWorkpackBatchTaskText) { return '' }
  $taskText = & $script:BacklogOriginalNewBacklogWorkpackBatchTaskText -Items $Items
  $itemsArr = @($Items | Where-Object { $_ })
  $perTaskTimeoutSec = Get-BacklogWorkpackPerTaskTimeoutSec
  $timeoutMin = Get-BacklogWorkpackDispatchTimeoutMin -TaskCount $itemsArr.Count -PerTaskTimeoutSec $perTaskTimeoutSec
  $autoParallel = ($itemsArr.Count -gt 1)

  $lines = @($taskText -split "\r?\n")
  $header = @(
    ('auto_parallel: ' + ($(if ($autoParallel) { 'true' } else { 'false' }))),
    ('per_task_timeout_sec: ' + $perTaskTimeoutSec),
    ('timeout_min: ' + $timeoutMin),
    ''
  )

  if ($lines.Count -ge 2) {
    $lines = @($lines[0], $lines[1]) + $header + @($lines[2..($lines.Count - 1)])
  } else {
    $lines = @($lines) + $header
  }

  $rendered = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in $lines) {
    [void]$rendered.Add([string]$line)
    if ($line -match '^[Cc]omplexity:\s+') {
      [void]$rendered.Add(('timeout_sec: ' + $perTaskTimeoutSec))
    }
  }

  return (($rendered.ToArray()) -join [Environment]::NewLine).Trim()
}

Remove-Variable -Name BacklogModuleName -Scope Script -ErrorAction SilentlyContinue
Remove-Variable -Name BacklogModulePath -Scope Script -ErrorAction SilentlyContinue
