# backlog-state-reaper.ps1 -- read-only Queue Governor zombie task recovery proposals

if (-not (Get-Command Get-BacklogGovernorObjectValue -ErrorAction SilentlyContinue)) {
  $script:BacklogStateReaperGovernorPath = Join-Path $PSScriptRoot 'backlog-governor.ps1'
  if (Test-Path -LiteralPath $script:BacklogStateReaperGovernorPath) {
    . $script:BacklogStateReaperGovernorPath
  }
}
if (-not (Get-Command Get-BridgeObjectValue -ErrorAction SilentlyContinue)) {
  try { . (Join-Path $PSScriptRoot 'primitives.ps1') } catch {}
}

function Get-BacklogStateReaperObjectValue {
  # Delegate preserves original state-reaper semantics: present-but-null is returned.
  param(
    [Parameter(Mandatory=$false)]$Object,
    [Parameter(Mandatory=$true)][string[]]$Names,
    [Parameter(Mandatory=$false)]$Default = $null
  )
  return Get-BridgeObjectValue -Object $Object -Names $Names -Default $Default
}

function Copy-BacklogStateReaperItem {
  param([Parameter(Mandatory=$false)]$Item)
  $copy = [ordered]@{}
  if ($null -eq $Item) { return [pscustomobject]$copy }
  if ($Item -is [System.Collections.IDictionary]) {
    foreach ($key in @($Item.Keys)) { $copy[[string]$key] = $Item[$key] }
  } else {
    foreach ($prop in @($Item.PSObject.Properties)) { $copy[$prop.Name] = $prop.Value }
  }
  return [pscustomobject]$copy
}

function Set-BacklogStateReaperObjectValue {
  param(
    [Parameter(Mandatory=$false)]$Object,
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$false)]$Value
  )
  if ($null -eq $Object) { return }
  if ($Object -is [System.Collections.IDictionary]) {
    $Object[$Name] = $Value
    return
  }
  $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function ConvertTo-BacklogStateReaperItemArray {
  param([Parameter(Mandatory=$false)]$Value)
  if ($null -eq $Value) { return @() }
  if ($Value -is [string]) { return @($Value) }
  if ($Value -is [System.Collections.IEnumerable]) { return @($Value) }
  return @($Value)
}

function ConvertTo-BacklogStateReaperUtc {
  param([Parameter(Mandatory=$false)]$Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [datetime]) { return ([datetime]$Value).ToUniversalTime() }
  $raw = [string]$Value
  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  try { return ([datetime]::Parse($raw, $null, [Globalization.DateTimeStyles]::RoundtripKind)).ToUniversalTime() } catch {}
  try { return ([datetime]::Parse($raw)).ToUniversalTime() } catch {}
  return $null
}

function Test-BacklogStateReaperFreshTime {
  param(
    [Parameter(Mandatory=$false)]$Value,
    [Parameter(Mandatory=$true)][datetime]$NowUtc,
    [Parameter(Mandatory=$true)][int]$HeartbeatMaxAgeSeconds
  )
  $stamp = ConvertTo-BacklogStateReaperUtc -Value $Value
  if ($null -eq $stamp) { return $false }
  $ageSeconds = ($NowUtc.ToUniversalTime() - $stamp).TotalSeconds
  return ($ageSeconds -ge 0 -and $ageSeconds -le $HeartbeatMaxAgeSeconds)
}

function Get-BacklogStateReaperPid {
  param([Parameter(Mandatory=$false)]$Object)
  foreach ($name in @('agent_pid','current_agent_pid','pid','process_id')) {
    $raw = Get-BacklogStateReaperObjectValue -Object $Object -Names @($name)
    if ($null -eq $raw) { continue }
    try {
      $pidValue = [int]$raw
      if ($pidValue -gt 0) { return $pidValue }
    } catch {}
  }
  return 0
}

function Test-BacklogStateReaperLivePid {
  param(
    [Parameter(Mandatory=$false)]$Object,
    [Parameter(Mandatory=$false)][int[]]$LivePids = @()
  )
  $pidValue = Get-BacklogStateReaperPid -Object $Object
  if ($pidValue -le 0) { return $false }
  if (@($LivePids).Count -gt 0) {
    return (@($LivePids) -contains $pidValue)
  }
  try {
    $proc = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    return ($null -ne $proc)
  } catch {
    return $false
  }
}

function Get-BacklogStateReaperItemId {
  param([Parameter(Mandatory=$false)]$Item)
  foreach ($name in @('id','task_id','backlog_id')) {
    $raw = [string](Get-BacklogStateReaperObjectValue -Object $Item -Names @($name) -Default '')
    if (-not [string]::IsNullOrWhiteSpace($raw)) { return $raw.Trim() }
  }
  return ''
}

function Get-BacklogStateReaperRecordIds {
  param([Parameter(Mandatory=$false)]$Record)
  $ids = @()
  foreach ($name in @('id','task_id','backlog_id','current_task_id','current_backlog_id')) {
    $raw = [string](Get-BacklogStateReaperObjectValue -Object $Record -Names @($name) -Default '')
    if (-not [string]::IsNullOrWhiteSpace($raw)) { $ids += $raw.Trim() }
  }
  return @($ids | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
}

function Get-BacklogStateReaperRuntimeRecords {
  param([Parameter(Mandatory=$false)]$RuntimeState)
  $records = New-Object 'System.Collections.Generic.List[object]'
  foreach ($entry in @(ConvertTo-BacklogStateReaperItemArray -Value $RuntimeState)) {
    if ($null -eq $entry) { continue }
    [void]$records.Add($entry)
    foreach ($containerName in @('tasks','active_tasks','running_tasks','workers','channels','channel_states')) {
      $container = Get-BacklogStateReaperObjectValue -Object $entry -Names @($containerName)
      if ($null -eq $container) { continue }
      if ($container -is [System.Collections.IDictionary]) {
        foreach ($key in @($container.Keys)) {
          if ($null -ne $container[$key]) { [void]$records.Add($container[$key]) }
        }
      } else {
        foreach ($child in @(ConvertTo-BacklogStateReaperItemArray -Value $container)) {
          if ($null -ne $child) { [void]$records.Add($child) }
        }
      }
    }
  }
  return @($records.ToArray())
}

function Get-BacklogStateReaperHeartbeatValue {
  param(
    [Parameter(Mandatory=$false)]$Object,
    [Parameter(Mandatory=$false)][string[]]$Names = @('heartbeat','heartbeat_at','last_heartbeat','last_heartbeat_at','worker_heartbeat','worker_heartbeat_at')
  )
  foreach ($name in $Names) {
    $raw = Get-BacklogStateReaperObjectValue -Object $Object -Names @($name)
    if ($null -ne $raw -and -not [string]::IsNullOrWhiteSpace([string]$raw)) { return $raw }
  }
  return $null
}

function Get-BacklogStateReaperWorkerHeartbeat {
  param(
    [Parameter(Mandatory=$false)][string]$WorkerId,
    [Parameter(Mandatory=$false)]$WorkerHeartbeats,
    [Parameter(Mandatory=$false)]$RuntimeState
  )
  if ([string]::IsNullOrWhiteSpace($WorkerId)) { return $null }
  $sources = @($WorkerHeartbeats)
  foreach ($state in @(ConvertTo-BacklogStateReaperItemArray -Value $RuntimeState)) {
    foreach ($name in @('worker_heartbeats','workerHeartbeats','heartbeats','workers')) {
      $candidate = Get-BacklogStateReaperObjectValue -Object $state -Names @($name)
      if ($null -ne $candidate) { $sources += $candidate }
    }
  }
  foreach ($source in @($sources)) {
    if ($null -eq $source) { continue }
    if ($source -is [System.Collections.IDictionary]) {
      foreach ($key in @($source.Keys)) {
        if ([string]::Equals([string]$key, $WorkerId, [System.StringComparison]::OrdinalIgnoreCase)) {
          $value = $source[$key]
          $hb = Get-BacklogStateReaperHeartbeatValue -Object $value
          if ($null -ne $hb) { return $hb }
          return $value
        }
      }
    } else {
      foreach ($record in @(ConvertTo-BacklogStateReaperItemArray -Value $source)) {
        $rid = [string](Get-BacklogStateReaperObjectValue -Object $record -Names @('worker_id','id') -Default '')
        if ([string]::Equals($rid, $WorkerId, [System.StringComparison]::OrdinalIgnoreCase)) {
          $hb = Get-BacklogStateReaperHeartbeatValue -Object $record
          if ($null -ne $hb) { return $hb }
        }
      }
    }
  }
  return $null
}

function Test-BacklogStateReaperFreshWorkerHeartbeat {
  param(
    [Parameter(Mandatory=$false)]$Item,
    [Parameter(Mandatory=$false)]$RuntimeState,
    [Parameter(Mandatory=$false)]$WorkerHeartbeats,
    [Parameter(Mandatory=$true)][datetime]$NowUtc,
    [Parameter(Mandatory=$true)][int]$HeartbeatMaxAgeSeconds
  )
  $itemHeartbeat = Get-BacklogStateReaperHeartbeatValue -Object $Item
  if (Test-BacklogStateReaperFreshTime -Value $itemHeartbeat -NowUtc $NowUtc -HeartbeatMaxAgeSeconds $HeartbeatMaxAgeSeconds) {
    return $true
  }
  $workerId = [string](Get-BacklogStateReaperObjectValue -Object $Item -Names @('worker_id','worker','owner_worker_id') -Default '')
  $workerHeartbeat = Get-BacklogStateReaperWorkerHeartbeat -WorkerId $workerId -WorkerHeartbeats $WorkerHeartbeats -RuntimeState $RuntimeState
  return (Test-BacklogStateReaperFreshTime -Value $workerHeartbeat -NowUtc $NowUtc -HeartbeatMaxAgeSeconds $HeartbeatMaxAgeSeconds)
}

function Test-BacklogStateReaperMatchingRuntimeState {
  param(
    [Parameter(Mandatory=$false)]$Item,
    [Parameter(Mandatory=$false)]$RuntimeState,
    [Parameter(Mandatory=$true)][datetime]$NowUtc,
    [Parameter(Mandatory=$true)][int]$HeartbeatMaxAgeSeconds,
    [Parameter(Mandatory=$false)][int[]]$LivePids = @()
  )
  $itemId = Get-BacklogStateReaperItemId -Item $Item
  if ([string]::IsNullOrWhiteSpace($itemId)) { return $false }
  foreach ($record in @(Get-BacklogStateReaperRuntimeRecords -RuntimeState $RuntimeState)) {
    $ids = @(Get-BacklogStateReaperRecordIds -Record $record)
    if (@($ids | Where-Object { [string]::Equals([string]$_, $itemId, [System.StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) { continue }
    $stateStatus = ([string](Get-BacklogStateReaperObjectValue -Object $record -Names @('status','state') -Default '')).ToLowerInvariant()
    $activeStatus = @('working','running','busy','active') -contains $stateStatus
    $freshHeartbeat = Test-BacklogStateReaperFreshTime -Value (Get-BacklogStateReaperHeartbeatValue -Object $record) -NowUtc $NowUtc -HeartbeatMaxAgeSeconds $HeartbeatMaxAgeSeconds
    $livePid = Test-BacklogStateReaperLivePid -Object $record -LivePids $LivePids
    if (($activeStatus -and $freshHeartbeat) -or $livePid) { return $true }
  }
  return $false
}

function Invoke-BacklogStateReaper {
  param(
    [Parameter(Mandatory=$false)]$Items = @(),
    [Parameter(Mandatory=$false)]$RuntimeState = $null,
    [Parameter(Mandatory=$false)][datetime]$NowUtc = (Get-Date).ToUniversalTime(),
    [Parameter(Mandatory=$false)][int]$HeartbeatMaxAgeSeconds = 900,
    [Parameter(Mandatory=$false)][int[]]$LivePids = @(),
    [Parameter(Mandatory=$false)]$WorkerHeartbeats = $null,
    [Parameter(Mandatory=$false)][int]$MaxZombieRetries = 2
  )
  $now = $NowUtc.ToUniversalTime()
  if ($HeartbeatMaxAgeSeconds -lt 1) { $HeartbeatMaxAgeSeconds = 1 }
  $resultItems = New-Object 'System.Collections.Generic.List[object]'
  $recovered = New-Object 'System.Collections.Generic.List[object]'
  $preserved = New-Object 'System.Collections.Generic.List[object]'

  foreach ($item in @(ConvertTo-BacklogStateReaperItemArray -Value $Items)) {
    $copy = Copy-BacklogStateReaperItem -Item $item
    $status = ([string](Get-BacklogStateReaperObjectValue -Object $copy -Names @('status') -Default '')).ToLowerInvariant()
    $id = Get-BacklogStateReaperItemId -Item $copy

    if (@('working','running') -notcontains $status) {
      [void]$resultItems.Add($copy)
      [void]$preserved.Add([pscustomobject][ordered]@{ id = $id; status = $status; reason = 'status-not-governed' })
      continue
    }

    $livePid = Test-BacklogStateReaperLivePid -Object $copy -LivePids $LivePids
    $freshWorkerHeartbeat = Test-BacklogStateReaperFreshWorkerHeartbeat -Item $copy -RuntimeState $RuntimeState -WorkerHeartbeats $WorkerHeartbeats -NowUtc $now -HeartbeatMaxAgeSeconds $HeartbeatMaxAgeSeconds
    $matchingRuntime = Test-BacklogStateReaperMatchingRuntimeState -Item $copy -RuntimeState $RuntimeState -NowUtc $now -HeartbeatMaxAgeSeconds $HeartbeatMaxAgeSeconds -LivePids $LivePids

    if ($livePid -or $freshWorkerHeartbeat -or $matchingRuntime) {
      [void]$resultItems.Add($copy)
      [void]$preserved.Add([pscustomobject][ordered]@{
        id = $id
        status = $status
        reason = $(if ($livePid) { 'live-agent-pid' } elseif ($freshWorkerHeartbeat) { 'fresh-worker-heartbeat' } else { 'matching-runtime-state' })
      })
      continue
    }

    # Recover the zombie for RETRY, not permanent sideline: a worker can die transiently (a restart,
    # timeout, or killed parallel stream) without the task itself being broken. Recover to 'approved'
    # so it re-claims and finishes -- but CAP it: after MaxZombieRetries deaths fall back to 'held' for
    # operator review, so a genuinely-broken atom can never retry-loop forever.
    $priorRecoveries = 0
    try { $priorRecoveries = [int](Get-BacklogStateReaperObjectValue -Object $copy -Names @('zombie_recovery_count') -Default 0) } catch { $priorRecoveries = 0 }
    $recoveryCount = $priorRecoveries + 1
    $recoverTo = if ($recoveryCount -le $MaxZombieRetries) { 'approved' } else { 'held' }
    $reason = ("zombie-{0}: no live agent_pid, no fresh worker heartbeat, no active runtime state (recovery {1}/{2} -> {3})" -f $status, $recoveryCount, $MaxZombieRetries, $recoverTo)
    Set-BacklogStateReaperObjectValue -Object $copy -Name 'status' -Value $recoverTo
    Set-BacklogStateReaperObjectValue -Object $copy -Name 'zombie_recovery_count' -Value $recoveryCount
    Set-BacklogStateReaperObjectValue -Object $copy -Name 'recovered_reason' -Value $reason
    Set-BacklogStateReaperObjectValue -Object $copy -Name 'recovered_at' -Value ($now.ToString('o'))
    [void]$resultItems.Add($copy)
    [void]$recovered.Add([pscustomobject][ordered]@{
      id = $id
      from_status = $status
      to_status = $recoverTo
      recovery_count = $recoveryCount
      recovered_reason = $reason
      recovered_at = $now.ToString('o')
    })
  }

  return [pscustomobject][ordered]@{
    items = @($resultItems.ToArray())
    recovered = @($recovered.ToArray())
    preserved = @($preserved.ToArray())
    evidence = [pscustomobject][ordered]@{
      now_utc = $now.ToString('o')
      heartbeat_max_age_seconds = $HeartbeatMaxAgeSeconds
      live_pids = @($LivePids)
    }
  }
}
