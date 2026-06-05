# test-backlog-state-reaper.ps1 -- Queue Governor state reaper tests

$ErrorActionPreference = 'Stop'
$bridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $bridgeRoot 'lib\backlog-governor.ps1')
. (Join-Path $bridgeRoot 'lib\backlog-state-reaper.ps1')

$script:pass = 0
$script:fail = 0

function Assert-BacklogStateReaper {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    [Parameter(Mandatory=$false)]$Detail = ''
  )
  if ($Condition) {
    Write-Host "PASS: $Name"
    $script:pass++
  } else {
    Write-Host "FAIL: $Name $Detail"
    $script:fail++
  }
}

function New-ReaperItem {
  param(
    [string]$Id,
    [string]$Status = 'working',
    [int]$AgentPid = 0,
    [string]$WorkerId = ''
  )
  $item = [pscustomobject][ordered]@{
    id = $Id
    status = $Status
    title = "Task $Id"
    text = "Run state reaper case $Id"
    touch_set = @('lib/backlog-state-reaper.ps1')
    root_cause_key = "queue-governor:state-reaper:$Id"
  }
  if ($AgentPid -gt 0) { $item | Add-Member -NotePropertyName agent_pid -NotePropertyValue $AgentPid -Force }
  if (-not [string]::IsNullOrWhiteSpace($WorkerId)) { $item | Add-Member -NotePropertyName worker_id -NotePropertyValue $WorkerId -Force }
  return $item
}

function Get-ReaperItemById {
  param([object[]]$Items, [string]$Id)
  return @($Items | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)[0]
}

try {
  $now = [datetime]::Parse('2026-06-05T12:00:00Z').ToUniversalTime()
  $fresh = $now.AddSeconds(-30).ToString('o')
  $stale = $now.AddMinutes(-30).ToString('o')

  $dead = New-ReaperItem -Id 'dead-pid-working' -Status 'working' -AgentPid 424242
  $deadRun = Invoke-BacklogStateReaper -Items @($dead) -RuntimeState $null -NowUtc $now -HeartbeatMaxAgeSeconds 120 -LivePids @($PID)
  $deadOut = Get-ReaperItemById -Items $deadRun.items -Id 'dead-pid-working'
  Assert-BacklogStateReaper 'dead PID working item becomes held' (
    [string]$deadOut.status -eq 'held' -and -not [string]::IsNullOrWhiteSpace([string]$deadOut.recovered_reason)
  ) ($deadRun | ConvertTo-Json -Compress -Depth 8)
  Assert-BacklogStateReaper 'dead PID working item gets recovered_reason' (
    [string]$deadOut.recovered_reason -like 'zombie-working:*no live agent_pid*'
  ) ([string]$deadOut.recovered_reason)

  $live = New-ReaperItem -Id 'live-pid-running' -Status 'running' -AgentPid $PID
  $liveRun = Invoke-BacklogStateReaper -Items @($live) -RuntimeState $null -NowUtc $now -HeartbeatMaxAgeSeconds 120 -LivePids @($PID)
  $liveOut = Get-ReaperItemById -Items $liveRun.items -Id 'live-pid-running'
  Assert-BacklogStateReaper 'live PID preserves running item' (
    [string]$liveOut.status -eq 'running' -and [string]$liveOut.PSObject.Properties['recovered_reason'] -eq ''
  ) ($liveRun | ConvertTo-Json -Compress -Depth 8)

  $heartbeat = New-ReaperItem -Id 'fresh-worker' -Status 'working' -AgentPid 555555 -WorkerId 'worker-a'
  $heartbeatMap = @{
    'worker-a' = [pscustomobject][ordered]@{ worker_id = 'worker-a'; heartbeat = $fresh }
  }
  $heartbeatRun = Invoke-BacklogStateReaper -Items @($heartbeat) -RuntimeState $null -WorkerHeartbeats $heartbeatMap -NowUtc $now -HeartbeatMaxAgeSeconds 120 -LivePids @()
  $heartbeatOut = Get-ReaperItemById -Items $heartbeatRun.items -Id 'fresh-worker'
  Assert-BacklogStateReaper 'fresh worker_id heartbeat preserves working item' (
    [string]$heartbeatOut.status -eq 'working'
  ) ($heartbeatRun | ConvertTo-Json -Compress -Depth 8)

  $newItem = New-ReaperItem -Id 'new-item' -Status 'new' -AgentPid 666666
  $approvedItem = New-ReaperItem -Id 'approved-item' -Status 'approved' -AgentPid 777777
  $openRun = Invoke-BacklogStateReaper -Items @($newItem,$approvedItem) -RuntimeState $null -NowUtc $now -HeartbeatMaxAgeSeconds 120 -LivePids @()
  $newOut = Get-ReaperItemById -Items $openRun.items -Id 'new-item'
  $approvedOut = Get-ReaperItemById -Items $openRun.items -Id 'approved-item'
  Assert-BacklogStateReaper 'new and approved statuses are not auto-recovered' (
    [string]$newOut.status -eq 'new' -and [string]$approvedOut.status -eq 'approved' -and @($openRun.recovered).Count -eq 0
  ) ($openRun | ConvertTo-Json -Compress -Depth 8)
  Assert-BacklogStateReaper 'no runnable status is introduced for new or approved' (
    @($openRun.items | Where-Object { [string]$_.status -eq 'runnable' }).Count -eq 0
  ) ($openRun | ConvertTo-Json -Compress -Depth 8)

  $stuckRunning = New-ReaperItem -Id 'stuck-running' -Status 'running'
  $stuckRun = Invoke-BacklogStateReaper -Items @($stuckRunning) -RuntimeState @([pscustomobject][ordered]@{ current_backlog_id = 'other'; status = 'working'; heartbeat = $fresh }) -NowUtc $now -HeartbeatMaxAgeSeconds 120 -LivePids @()
  $stuckOut = Get-ReaperItemById -Items $stuckRun.items -Id 'stuck-running'
  Assert-BacklogStateReaper 'running without matching runtime state becomes held' (
    [string]$stuckOut.status -eq 'held' -and [string]$stuckOut.recovered_reason -like 'zombie-running:*'
  ) ($stuckRun | ConvertTo-Json -Compress -Depth 8)

  $runtimeMatched = New-ReaperItem -Id 'runtime-matched' -Status 'running'
  $runtimeState = [pscustomobject][ordered]@{
    current_backlog_id = 'runtime-matched'
    status = 'working'
    heartbeat = $fresh
  }
  $runtimeRun = Invoke-BacklogStateReaper -Items @($runtimeMatched) -RuntimeState $runtimeState -NowUtc $now -HeartbeatMaxAgeSeconds 120 -LivePids @()
  $runtimeOut = Get-ReaperItemById -Items $runtimeRun.items -Id 'runtime-matched'
  Assert-BacklogStateReaper 'matching fresh runtime state preserves running item' (
    [string]$runtimeOut.status -eq 'running'
  ) ($runtimeRun | ConvertTo-Json -Compress -Depth 8)

  $staleHeartbeat = New-ReaperItem -Id 'stale-worker' -Status 'working' -WorkerId 'worker-stale'
  $staleMap = @{ 'worker-stale' = $stale }
  $staleRun = Invoke-BacklogStateReaper -Items @($staleHeartbeat) -WorkerHeartbeats $staleMap -NowUtc $now -HeartbeatMaxAgeSeconds 120 -LivePids @()
  $staleOut = Get-ReaperItemById -Items $staleRun.items -Id 'stale-worker'
  Assert-BacklogStateReaper 'stale worker heartbeat does not preserve zombie item' (
    [string]$staleOut.status -eq 'held'
  ) ($staleRun | ConvertTo-Json -Compress -Depth 8)

  Assert-BacklogStateReaper 'original item is not mutated by proposal helper' (
    [string]$dead.status -eq 'working' -and [string]$stuckRunning.status -eq 'running'
  ) (@($dead,$stuckRunning) | ConvertTo-Json -Compress -Depth 8)

  $moduleText = Get-Content -LiteralPath (Join-Path $bridgeRoot 'lib\backlog-state-reaper.ps1') -Raw -Encoding UTF8
  $forbiddenTokens = @(
    'Save-Backlog',
    'Write-BacklogJsonLine',
    'Set-Content',
    'Out-File',
    'New-Item',
    'Remove-Item',
    'Start-Process',
    'driver/81-loop-idle-claim.ps1',
    'driver/83-loop-agent-turn.ps1',
    'driver/86-loop-completion-cleanup.ps1',
    'lib/backlog-workpack.ps1'
  )
  $foundForbidden = @($forbiddenTokens | Where-Object { $moduleText -like ('*' + $_ + '*') })
  Assert-BacklogStateReaper 'module has no write or hot-path tokens' ($foundForbidden.Count -eq 0) ($foundForbidden -join ', ')
} catch {
  Write-Host "FAIL: unhandled exception :: $($_.Exception.Message)"
  $script:fail++
}

Write-Host ("Backlog State Reaper tests: {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
