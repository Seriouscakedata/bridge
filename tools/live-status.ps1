param(
  [string]$Channel = '',
  [int]$Tail = 10,
  [switch]$Json,
  [switch]$Watch,
  [int]$IntervalSec = 5
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$script:Root = Split-Path -Parent $PSScriptRoot

function Limit-Text {
  param([AllowNull()][object]$Value, [int]$Max = 180)
  if ($null -eq $Value) { return '' }
  $text = ([string]$Value) -replace '\s+', ' '
  $text = $text.Trim()
  if ($text.Length -le $Max) { return $text }
  return ($text.Substring(0, $Max) + '...')
}

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try {
    $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function ConvertTo-DateSafe {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return $null }
  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  try { return [datetime]$text } catch { return $null }
}

function Get-AgeSeconds {
  param([AllowNull()][object]$Value)
  $dt = ConvertTo-DateSafe -Value $Value
  if ($null -eq $dt) { return $null }
  try { return [int]([datetime]::Now - $dt).TotalSeconds } catch { return $null }
}

function Format-Age {
  param([AllowNull()][object]$Value)
  $sec = $null
  if ($Value -is [int] -or $Value -is [long] -or $Value -is [double]) {
    $sec = [int]$Value
  } else {
    $sec = Get-AgeSeconds -Value $Value
  }
  if ($null -eq $sec) { return '-' }
  if ($sec -lt 60) { return "$sec s" }
  $min = [int]($sec / 60)
  if ($min -lt 60) { return "$min min" }
  $hr = [Math]::Round($min / 60.0, 1)
  return "$hr h"
}

function Read-JsonlTail {
  param([string]$Path, [int]$Count = 50)
  $items = New-Object 'System.Collections.Generic.List[object]'
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
  foreach ($line in @(Get-Content -LiteralPath $Path -Encoding UTF8 -Tail $Count -ErrorAction SilentlyContinue)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { [void]$items.Add(($line | ConvertFrom-Json)) } catch {}
  }
  return @($items.ToArray())
}

function Invoke-GitText {
  param([string[]]$ArgsList)
  try {
    $out = & git -C $script:Root @ArgsList 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return (($out | ForEach-Object { [string]$_ }) -join "`n").Trim()
  } catch {
    return ''
  }
}

function Get-GitSnapshot {
  $status = Invoke-GitText -ArgsList @('status','--short','--branch')
  $head = Invoke-GitText -ArgsList @('rev-parse','--short','HEAD')
  $stable = Invoke-GitText -ArgsList @('rev-parse','--short','stable')
  $last = Invoke-GitText -ArgsList @('log','-1','--format=%h %s')
  $dirtyLines = @()
  try { $dirtyLines = @(& git -C $script:Root status --porcelain 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } catch {}
  [pscustomobject]@{
    status = $status
    head = $head
    stable = $stable
    last_commit = $last
    dirty_count = @($dirtyLines).Count
    dirty = @($dirtyLines)
  }
}

function Get-HealthSnapshot {
  $uri = 'http://localhost:8787/api/health'
  try {
    $res = Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec 5
    $obj = $null
    try { $obj = ([string]$res.Content | ConvertFrom-Json) } catch {}
    return [pscustomobject]@{
      ok = ($res.StatusCode -eq 200)
      status_code = [int]$res.StatusCode
      content = [string]$res.Content
      uptime_sec = if ($obj) { $obj.uptime_sec } else { $null }
      heartbeat_age_sec = if ($obj) { $obj.heartbeat_age_sec } else { $null }
      recent_error_count_24h = if ($obj) { $obj.recent_error_count_24h } else { $null }
      error = ''
    }
  } catch {
    return [pscustomobject]@{
      ok = $false
      status_code = 0
      content = ''
      uptime_sec = $null
      heartbeat_age_sec = $null
      recent_error_count_24h = $null
      error = [string]$_.Exception.Message
    }
  }
}

function Get-SupervisorPidSnapshot {
  $logPath = Join-Path $script:Root 'control\supervisor.log'
  $serverPid = 0
  $drivers = @{}
  if (Test-Path -LiteralPath $logPath -PathType Leaf) {
    foreach ($line in @(Get-Content -LiteralPath $logPath -Encoding UTF8 -Tail 600 -ErrorAction SilentlyContinue)) {
      if ($line -match 'server pid=(\d+)') { $serverPid = [int]$Matches[1] }
      if ($line -match "driver\[([^\]]+)\] pid=(\d+)") { $drivers[[string]$Matches[1]] = [int]$Matches[2] }
    }
  }
  [pscustomobject]@{
    server = $serverPid
    drivers = $drivers
  }
}

function Get-ProcessSnapshot {
  param([int]$ProcessId)
  if ($ProcessId -le 0) {
    return [pscustomobject]@{ pid = $ProcessId; name = ''; alive = $false; cpu_sec = $null; start_time = $null; age_sec = $null; responding = $null }
  }
  try {
    $p = Get-Process -Id $ProcessId -ErrorAction Stop
    $age = $null
    $startTime = $null
    $responding = $null
    try { $age = [int]([datetime]::Now - $p.StartTime).TotalSeconds } catch {}
    try { $startTime = $p.StartTime.ToString('s') } catch {}
    try { $responding = [bool]$p.Responding } catch {}
    return [pscustomobject]@{
      pid = [int]$ProcessId
      name = [string]$p.ProcessName
      alive = $true
      cpu_sec = [Math]::Round([double]$p.CPU, 2)
      start_time = $startTime
      age_sec = $age
      responding = $responding
    }
  } catch {
    return [pscustomobject]@{ pid = [int]$ProcessId; name = ''; alive = $false; cpu_sec = $null; start_time = $null; age_sec = $null; responding = $null }
  }
}

function Get-WatchdogProcess {
  $watchdogPid = 0
  try {
    $cands = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction Stop |
      Where-Object { [string]$_.CommandLine -like '*watchdog.ps1*' } |
      Sort-Object ProcessId -Descending)
    if ($cands.Count -gt 0) { $watchdogPid = [int]$cands[0].ProcessId }
  } catch {}
  return (Get-ProcessSnapshot -ProcessId $watchdogPid)
}

function Get-ChannelDirs {
  $root = Join-Path $script:Root 'channels'
  if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
  $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne '_archive' } |
    Sort-Object Name)
  if (-not [string]::IsNullOrWhiteSpace($Channel)) {
    $dirs = @($dirs | Where-Object { $_.Name -eq $Channel })
  }
  return @($dirs)
}

function Get-QualitySignals {
  param([string]$Slug, [int]$SinceSeq = 0)
  $path = Join-Path $script:Root ("channels\$Slug\conversation.jsonl")
  $records = @(Read-JsonlTail -Path $path -Count 120)
  if ($SinceSeq -gt 0) { $records = @($records | Where-Object { [int]$_.seq -ge $SinceSeq }) }

  $lastCommit = $null
  $lastCritic = $null
  $lastQa = $null
  $lastError = $null
  $lastProgress = $null
  foreach ($r in $records) {
    $text = [string]$r.text
    if ($text -match 'Драйвер зафиксировал правки Codex|auto-commit|commit') { $lastCommit = $r }
    if ($text -match 'Критик|critic') { $lastCritic = $r }
    if ($text -match 'QA-агент|Smoke OK|SMOKE OK|ParseFile OK') { $lastQa = $r }
    if ($text -match '(?i)(error|fail|timeout|unexpected argument|нет ответа|stderr|rejected|rollback|FAILED|CRITICAL)') { $lastError = $r }
    if ($text -match 'вывод растёт|жив|зафиксировал|Готово|DONE|PASS|OK') { $lastProgress = $r }
  }

  $warnings = New-Object 'System.Collections.Generic.List[string]'
  if ($null -ne $lastCommit) {
    $commitSeq = [int]$lastCommit.seq
    $criticSeq = if ($null -ne $lastCritic) { [int]$lastCritic.seq } else { 0 }
    $qaSeq = if ($null -ne $lastQa) { [int]$lastQa.seq } else { 0 }
    if ($criticSeq -lt $commitSeq) { [void]$warnings.Add('commit есть, critic после него ещё не виден') }
    if ($qaSeq -lt $commitSeq) { [void]$warnings.Add('commit есть, QA/smoke после него ещё не виден') }
  }
  if ($null -ne $lastError) {
    [void]$warnings.Add('в последних событиях есть error/stderr/timeout/нет ответа')
  }

  [pscustomobject]@{
    last_commit = if ($lastCommit) { "seq=$($lastCommit.seq) " + (Limit-Text $lastCommit.text 160) } else { '' }
    last_critic = if ($lastCritic) { "seq=$($lastCritic.seq) " + (Limit-Text $lastCritic.text 160) } else { '' }
    last_qa = if ($lastQa) { "seq=$($lastQa.seq) " + (Limit-Text $lastQa.text 160) } else { '' }
    last_error = if ($lastError) { "seq=$($lastError.seq) " + (Limit-Text $lastError.text 160) } else { '' }
    last_progress = if ($lastProgress) { "seq=$($lastProgress.seq) " + (Limit-Text $lastProgress.text 160) } else { '' }
    warnings = @($warnings.ToArray())
    tail = @($records | Select-Object -Last $Tail | ForEach-Object {
      [pscustomobject]@{
        seq = [int]$_.seq
        from = [string]$_.from
        kind = [string]$_.kind
        text = Limit-Text $_.text 220
      }
    })
  }
}

function Get-ChannelSnapshot {
  param([System.IO.DirectoryInfo]$Dir, $PidSnapshot)
  $slug = [string]$Dir.Name
  $cfg = Read-JsonFile -Path (Join-Path $Dir.FullName 'channel.json')
  $state = Read-JsonFile -Path (Join-Path $Dir.FullName 'state.json')
  $driverPid = 0
  try {
    if ($PidSnapshot.drivers.ContainsKey($slug)) { $driverPid = [int]$PidSnapshot.drivers[$slug] }
  } catch {}
  $agentPid = 0
  if ($state -and $state.PSObject.Properties['agent_pid']) {
    try { $agentPid = [int]$state.agent_pid } catch {}
  }
  $taskStartSeq = 0
  if ($state -and $state.PSObject.Properties['task_start_seq']) {
    try { $taskStartSeq = [int]$state.task_start_seq } catch {}
  }
  $quality = Get-QualitySignals -Slug $slug -SinceSeq $taskStartSeq
  $warnings = New-Object 'System.Collections.Generic.List[string]'
  foreach ($w in @($quality.warnings)) { [void]$warnings.Add([string]$w) }
  $hbAge = if ($state) { Get-AgeSeconds $state.heartbeat } else { $null }
  if ($null -ne $hbAge -and $hbAge -gt 120) { [void]$warnings.Add("heartbeat старше 120s ($hbAge s)") }
  if ($state -and $state.agent_telemetry -and $state.agent_telemetry.PSObject.Properties['stalled_sec']) {
    try {
      $stalled = [int]$state.agent_telemetry.stalled_sec
      if ($stalled -gt 180) { [void]$warnings.Add("agent telemetry stalled_sec=$stalled") }
    } catch {}
  }
  [pscustomobject]@{
    slug = $slug
    name = if ($cfg) { [string]$cfg.name } else { $slug }
    project_root = if ($cfg) { [string]$cfg.project_root } else { '' }
    status = if ($state) { [string]$state.status } else { 'missing-state' }
    status_text = if ($state) { Limit-Text $state.status_text 220 } else { '' }
    active_agent = if ($state) { [string]$state.active_agent } else { '' }
    active_model = if ($state) { [string]$state.active_model } else { '' }
    task_turn = if ($state) { try { [int]$state.task_turn } catch { 0 } } else { 0 }
    turn = if ($state) { try { [int]$state.turn } catch { 0 } } else { 0 }
    heartbeat = if ($state) { [string]$state.heartbeat } else { '' }
    heartbeat_age_sec = $hbAge
    current_backlog_id = if ($state) { [string]$state.current_backlog_id } else { '' }
    current_task = if ($state) { Limit-Text $state.current_task 360 } else { '' }
    claimed_at = if ($state) { [string]$state.claimed_at } else { '' }
    task_age_sec = if ($state) { Get-AgeSeconds $state.claimed_at } else { $null }
    driver = Get-ProcessSnapshot -ProcessId $driverPid
    agent = Get-ProcessSnapshot -ProcessId $agentPid
    telemetry = if ($state -and $state.agent_telemetry) { $state.agent_telemetry } else { $null }
    quality = $quality
    warnings = @($warnings.ToArray())
  }
}

function Get-LiveSnapshot {
  $pidSnapshot = Get-SupervisorPidSnapshot
  $channels = New-Object 'System.Collections.Generic.List[object]'
  foreach ($dir in @(Get-ChannelDirs)) {
    [void]$channels.Add((Get-ChannelSnapshot -Dir $dir -PidSnapshot $pidSnapshot))
  }
  $activeChannel = ''
  $activePath = Join-Path $script:Root 'control\active_channel'
  if (Test-Path -LiteralPath $activePath -PathType Leaf) {
    try { $activeChannel = ([System.IO.File]::ReadAllText($activePath, [System.Text.Encoding]::UTF8)).Trim() } catch {}
  }
  [pscustomobject]@{
    ts = (Get-Date).ToString('s')
    root = $script:Root
    active_channel = $activeChannel
    health = Get-HealthSnapshot
    git = Get-GitSnapshot
    processes = [pscustomobject]@{
      server = Get-ProcessSnapshot -ProcessId ([int]$pidSnapshot.server)
      watchdog = Get-WatchdogProcess
    }
    channels = @($channels.ToArray())
  }
}

function Write-LiveSnapshot {
  param($Snap)
  Write-Host ("Bridge live status  " + $Snap.ts)
  Write-Host ("Root: " + $Snap.root)
  $healthText = "Health: "
  if ([bool]$Snap.health.ok) {
    $healthText += "OK"
  } else {
    $healthText += "BAD"
  }
  $healthText += " status=$($Snap.health.status_code) uptime=$(Format-Age $Snap.health.uptime_sec) heartbeat_age=$(Format-Age $Snap.health.heartbeat_age_sec) errors24h=$($Snap.health.recent_error_count_24h)"
  if (-not [bool]$Snap.health.ok -and -not [string]::IsNullOrWhiteSpace([string]$Snap.health.error)) {
    $healthText += " error=$($Snap.health.error)"
  }
  Write-Host $healthText
  Write-Host ("Git: head=$($Snap.git.head) stable=$($Snap.git.stable) dirty=$($Snap.git.dirty_count) last=$($Snap.git.last_commit)")
  Write-Host ("Active channel: " + $Snap.active_channel)
  Write-Host ("Processes: server pid=$($Snap.processes.server.pid) alive=$($Snap.processes.server.alive) cpu=$($Snap.processes.server.cpu_sec)s; watchdog pid=$($Snap.processes.watchdog.pid) alive=$($Snap.processes.watchdog.alive)")
  Write-Host ""

  foreach ($ch in @($Snap.channels)) {
    $hdr = "[$($ch.slug)] $($ch.status)"
    if (-not [string]::IsNullOrWhiteSpace([string]$ch.active_agent)) { $hdr += " agent=$($ch.active_agent)/$($ch.active_model)" }
    $hdr += " turn=$($ch.turn) task_turn=$($ch.task_turn) hb=$(Format-Age $ch.heartbeat_age_sec)"
    Write-Host $hdr
    if (-not [string]::IsNullOrWhiteSpace([string]$ch.project_root)) { Write-Host ("  project: " + $ch.project_root) }
    if (-not [string]::IsNullOrWhiteSpace([string]$ch.status_text)) { Write-Host ("  now: " + $ch.status_text) }
    if (-not [string]::IsNullOrWhiteSpace([string]$ch.current_task)) { Write-Host ("  task: " + $ch.current_task) }
    if (-not [string]::IsNullOrWhiteSpace([string]$ch.current_backlog_id)) { Write-Host ("  backlog: " + $ch.current_backlog_id) }
    Write-Host ("  driver: pid=$($ch.driver.pid) alive=$($ch.driver.alive) cpu=$($ch.driver.cpu_sec)s age=$(Format-Age $ch.driver.age_sec)")
    Write-Host ("  child:  pid=$($ch.agent.pid) name=$($ch.agent.name) alive=$($ch.agent.alive) cpu=$($ch.agent.cpu_sec)s age=$(Format-Age $ch.agent.age_sec)")
    if ($ch.telemetry) {
      $elapsed = ''
      $cpu = ''
      $stalled = ''
      try { $elapsed = [string]$ch.telemetry.elapsed_sec } catch {}
      try { $cpu = [string]$ch.telemetry.cpu_sec } catch {}
      try { $stalled = [string]$ch.telemetry.stalled_sec } catch {}
      Write-Host ("  telemetry: elapsed=$elapsed s cpu=$cpu s stalled=$stalled s")
    }
    if ($ch.quality.last_commit) { Write-Host ("  quality commit: " + $ch.quality.last_commit) }
    if ($ch.quality.last_critic) { Write-Host ("  quality critic: " + $ch.quality.last_critic) }
    if ($ch.quality.last_qa) { Write-Host ("  quality qa: " + $ch.quality.last_qa) }
    if ($ch.quality.last_error) { Write-Host ("  last risk: " + $ch.quality.last_error) }
    if (@($ch.warnings).Count -gt 0) {
      Write-Host ("  WARN: " + ((@($ch.warnings) | Select-Object -Unique) -join '; '))
    }
    Write-Host "  recent:"
    foreach ($ev in @($ch.quality.tail)) {
      Write-Host ("    seq=$($ev.seq) $($ev.from): $($ev.text)")
    }
    Write-Host ""
  }
}

function Run-Once {
  $snap = Get-LiveSnapshot
  if ($Json) {
    $snap | ConvertTo-Json -Depth 10
  } else {
    Write-LiveSnapshot -Snap $snap
  }
}

if ($Watch) {
  if ($IntervalSec -lt 1) { $IntervalSec = 1 }
  while ($true) {
    Clear-Host
    Run-Once
    Start-Sleep -Seconds $IntervalSec
  }
} else {
  Run-Once
}
