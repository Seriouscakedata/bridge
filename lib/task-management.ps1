# task-management.ps1 -- read-only execution management snapshot for task claims.
#
# This module does not authorize execution. It combines existing delivery-mode
# facts with workpack/frontier context and writes an optional shadow JSONL record
# so the bridge can explain why a task is single, parallel, serial, or blocked.

$script:TaskManagementRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:TaskManagementRoot 'lib\delivery-mode.ps1')

function Get-TaskManagementSchema {
  return [ordered]@{
    task_id          = 'string'
    channel          = 'string'
    execution_path   = 'single|workpack_parallel|protected_serial|blocked'
    delivery_mode    = 'object from Get-DeliveryModeDecision'
    parallel_applied = 'bool'
    serial_reason    = 'string'
    warnings         = 'string[]'
    blockers         = 'string[]'
    frontier         = 'object|null'
    batch_ids        = 'string[]'
    touched_files    = 'string[]'
  }
}

function Get-TaskManagementValue {
  param($Object, [string[]]$Names, $Default = $null)
  if ($null -eq $Object) { return $Default }
  foreach ($name in @($Names)) {
    if ($Object -is [hashtable] -and $Object.ContainsKey($name)) { return $Object[$name] }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($name)) { return $Object[$name] }
    $prop = $Object.PSObject.Properties[$name]
    if ($null -ne $prop) { return $prop.Value }
  }
  return $Default
}

function ConvertTo-TaskManagementStringArray {
  param($Value)
  $items = New-Object 'System.Collections.Generic.List[string]'
  if ($null -eq $Value) { return [string[]]@() }
  if ($Value -is [string]) {
    if (-not [string]::IsNullOrWhiteSpace($Value)) { [void]$items.Add($Value.Trim()) }
    return [string[]]@($items.ToArray())
  }
  if ($Value -is [System.Collections.IEnumerable]) {
    foreach ($item in $Value) {
      if ($null -eq $item) { continue }
      $s = ([string]$item).Trim()
      if (-not [string]::IsNullOrWhiteSpace($s) -and -not $items.Contains($s)) {
        [void]$items.Add($s)
      }
    }
  }
  return [string[]]@($items.ToArray())
}

function Add-TaskManagementIssue {
  param(
    [Parameter(Mandatory)]$List,
    [string]$Value
  )
  if ([string]::IsNullOrWhiteSpace($Value)) { return }
  if (-not $List.Contains($Value)) { [void]$List.Add($Value) }
}

function ConvertTo-TaskManagementFrontierSnapshot {
  param($Frontier)
  if ($null -eq $Frontier) { return $null }
  return [pscustomobject][ordered]@{
    reason           = [string](Get-TaskManagementValue -Object $Frontier -Names @('reason') -Default '')
    batch_available  = [bool](Get-TaskManagementValue -Object $Frontier -Names @('batch_available') -Default $false)
    parallel_required = [bool](Get-TaskManagementValue -Object $Frontier -Names @('parallel_required') -Default $false)
    approved         = [int](Get-TaskManagementValue -Object $Frontier -Names @('approved','approved_count') -Default 0)
    eligible         = [int](Get-TaskManagementValue -Object $Frontier -Names @('eligible','eligible_count') -Default 0)
    ready            = [int](Get-TaskManagementValue -Object $Frontier -Names @('ready','ready_count') -Default 0)
    selected         = [int](Get-TaskManagementValue -Object $Frontier -Names @('selected','selected_count') -Default 0)
    min_items        = [int](Get-TaskManagementValue -Object $Frontier -Names @('min_items') -Default 0)
    dependency_wait  = [int](Get-TaskManagementValue -Object $Frontier -Names @('dependency_wait','dependency_wait_count') -Default 0)
    structural_wait  = [int](Get-TaskManagementValue -Object $Frontier -Names @('structural_wait','structural_wait_count') -Default 0)
    conflict_skips   = [int](Get-TaskManagementValue -Object $Frontier -Names @('conflict_skips','conflict_skip_count') -Default 0)
    touch_skips      = [int](Get-TaskManagementValue -Object $Frontier -Names @('touch_skips','touch_skip_count') -Default 0)
    selected_ids     = @(ConvertTo-TaskManagementStringArray (Get-TaskManagementValue -Object $Frontier -Names @('selected_ids') -Default @()))
    selected_groups  = @(ConvertTo-TaskManagementStringArray (Get-TaskManagementValue -Object $Frontier -Names @('selected_groups') -Default @()))
  }
}

function New-TaskManagementSnapshot {
  param(
    [string]$TaskId = '',
    [string]$TaskText = '',
    [string]$Channel = 'main',
    [string[]]$TouchedFiles = @(),
    [string[]]$BatchIds = @(),
    [string]$WorkpackBatchMode = '',
    $WorkpackFrontier = $null,
    $ChannelFacts = $null,
    $Context = $null
  )

  $files = @(ConvertTo-TaskManagementStringArray $TouchedFiles)
  $batch = @(ConvertTo-TaskManagementStringArray $BatchIds)
  $frontier = ConvertTo-TaskManagementFrontierSnapshot -Frontier $WorkpackFrontier
  $warnings = New-Object 'System.Collections.Generic.List[string]'
  $blockers = New-Object 'System.Collections.Generic.List[string]'

  $ctx = [ordered]@{}
  if ($Context) {
    if ($Context -is [System.Collections.IDictionary]) {
      foreach ($key in @($Context.Keys)) { $ctx[[string]$key] = $Context[$key] }
    } else {
      foreach ($prop in @($Context.PSObject.Properties)) { $ctx[$prop.Name] = $prop.Value }
    }
  }
  $ctx['BatchCount'] = [int]$batch.Count
  $ctx['WorkpackBatchMode'] = [string]$WorkpackBatchMode
  if ($frontier) { $ctx['WorkpackFrontier'] = $frontier }

  $delivery = Get-DeliveryModeDecision -TaskText $TaskText -ChannelFacts $ChannelFacts -TouchedFiles $files -Context $ctx

  $executionPath = 'single'
  $parallelApplied = $false
  $serialReason = [string]$delivery.serial_reason
  if ($batch.Count -ge 2) {
    if ([string]$WorkpackBatchMode -eq 'serial') {
      $executionPath = 'protected_serial'
      if ([string]::IsNullOrWhiteSpace($serialReason)) { $serialReason = 'critical_bridge_self' }
    } else {
      $executionPath = 'workpack_parallel'
      $parallelApplied = $true
    }
  } elseif ([string]$delivery.mode -eq 'blocked') {
    $executionPath = 'blocked'
    Add-TaskManagementIssue -List $blockers -Value ([string]$delivery.reason)
  }

  if ($frontier) {
    $readyCount = [int]$frontier.ready
    if ($readyCount -le 0) { $readyCount = [int]$frontier.eligible }
    $minItems = [int]$frontier.min_items
    if ($minItems -le 0) { $minItems = 2 }
    $hasReadyParallelFrontier = ([bool]$frontier.batch_available -and $readyCount -ge $minItems)

    if ([bool]$frontier.parallel_required -and -not $parallelApplied -and $hasReadyParallelFrontier) {
      Add-TaskManagementIssue -List $warnings -Value 'parallel_obligation_unsatisfied'
      if ([string]::IsNullOrWhiteSpace($serialReason)) { $serialReason = 'missing_serial_reason' }
    }
    if (-not [bool]$frontier.batch_available -and [int]$frontier.eligible -ge 2 -and [int]$frontier.selected -lt [int]$frontier.min_items) {
      $frontierReason = [string]$frontier.reason
      if ($frontierReason -eq 'dependency-wait') {
        Add-TaskManagementIssue -List $warnings -Value 'frontier_waiting_on_dependencies'
      } else {
        Add-TaskManagementIssue -List $warnings -Value ('frontier_no_batch:' + $frontierReason)
      }
    }
  }

  $deliveryReadyParallelFrontier = $false
  if ($frontier) {
    $readyCount = [int]$frontier.ready
    if ($readyCount -le 0) { $readyCount = [int]$frontier.eligible }
    $minItems = [int]$frontier.min_items
    if ($minItems -le 0) { $minItems = 2 }
    $deliveryReadyParallelFrontier = ([bool]$frontier.batch_available -and $readyCount -ge $minItems)
  } else {
    $deliveryReadyParallelFrontier = ($batch.Count -ge 2)
  }

  if ([string]$delivery.parallel_policy -eq 'required' -and -not $parallelApplied -and [string]$executionPath -notin @('blocked','protected_serial') -and [bool]$deliveryReadyParallelFrontier) {
    Add-TaskManagementIssue -List $warnings -Value 'delivery_parallel_required_not_applied'
  }

  return [pscustomobject][ordered]@{
    task_id          = [string]$TaskId
    channel          = [string]$Channel
    execution_path   = $executionPath
    delivery_mode    = $delivery
    parallel_applied = [bool]$parallelApplied
    serial_reason    = [string]$serialReason
    warnings         = @($warnings.ToArray())
    blockers         = @($blockers.ToArray())
    frontier         = $frontier
    batch_ids        = @($batch)
    touched_files    = @($files)
  }
}

function Normalize-TaskManagementChannel {
  param([string]$Channel)
  if ([string]::IsNullOrWhiteSpace($Channel)) { return '' }
  $slug = $Channel.Trim()
  if ($slug -match '[\\/]' -or $slug -eq '.' -or $slug -eq '..' -or $slug -match '\.\.') { return '' }
  if ($slug -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { return '' }
  return $slug
}

function Write-TaskManagementShadowRecord {
  param(
    [string]$BridgeRoot,
    [string]$Channel,
    [string]$TaskId,
    $Snapshot,
    [string]$Note = ''
  )

  $targetPath = ''
  try {
    if ([string]::IsNullOrWhiteSpace($BridgeRoot)) {
      return [pscustomobject]@{ ok=$false; path=''; error='BridgeRoot is required' }
    }
    $channelSlug = Normalize-TaskManagementChannel -Channel $Channel
    if ([string]::IsNullOrWhiteSpace($channelSlug)) {
      return [pscustomobject]@{ ok=$false; path=''; error='Channel is invalid' }
    }
    $rootPath = [System.IO.Path]::GetFullPath($BridgeRoot)
    $channelsPath = [System.IO.Path]::GetFullPath((Join-Path $rootPath 'channels'))
    $channelPath = [System.IO.Path]::GetFullPath((Join-Path $channelsPath $channelSlug))
    if (-not $channelPath.StartsWith($channelsPath, [System.StringComparison]::OrdinalIgnoreCase)) {
      return [pscustomobject]@{ ok=$false; path=''; error='Channel path escapes channels root' }
    }
    if (-not (Test-Path -LiteralPath $channelPath)) {
      New-Item -ItemType Directory -Path $channelPath -Force | Out-Null
    }
    $targetPath = Join-Path $channelPath 'task-management-shadow.jsonl'
    $record = [ordered]@{
      ts       = (Get-Date).ToUniversalTime().ToString('o')
      channel  = $channelSlug
      task_id  = [string]$TaskId
      snapshot = $Snapshot
      note     = [string]$Note
    }
    $json = $record | ConvertTo-Json -Depth 10 -Compress
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($targetPath, ($json + "`n"), $utf8NoBom)
    return [pscustomobject]@{ ok=$true; path=$targetPath; error='' }
  } catch {
    return [pscustomobject]@{ ok=$false; path=$targetPath; error=$_.Exception.Message }
  }
}

function Format-TaskManagementSummary {
  param($Snapshot)
  if (-not $Snapshot) { return '' }
  $mode = [string]$Snapshot.delivery_mode.mode
  $flow = [string]$Snapshot.delivery_mode.flow
  $path = [string]$Snapshot.execution_path
  $parallel = [string]$Snapshot.delivery_mode.parallel_policy
  $warnCount = @($Snapshot.warnings).Count
  $suffix = ''
  if ($warnCount -gt 0) { $suffix = '; warnings=' + $warnCount }
  if ($Snapshot.frontier) {
    $suffix += '; frontier=' + [string]$Snapshot.frontier.selected + '/' + [string]$Snapshot.frontier.min_items + ' ' + [string]$Snapshot.frontier.reason
  }
  return ('Task management: mode=' + $mode + '; flow=' + $flow + '; path=' + $path + '; parallel=' + $parallel + $suffix)
}
