# auditor.ps1 -- read-only bridge sensor. It detects anomalies and delegates repair to Doctor.

$script:AuditorClasses = @('normal','transient','hung','corrupted_state','unsolvable')

function Get-AuditorMarkerPath {
  Join-Path (Get-BridgeRoot) 'control\auditor.last'
}

function Get-AuditorLogPath {
  Join-Path (Get-BridgeRoot) 'control\auditor.log'
}

function Get-AuditorConfig {
  $defaults = @{
    enabled = $true
    intervalMin = 15
    cooldownMin = 30
    model = 'gemini-2.5-flash-lite'
    doctorRecidivismHours = 24
    doctorRecidivismMax = 2
  }
  $cfgNode = $null
  try {
    $cfg = Get-BridgeConfig
    if ($cfg.PSObject.Properties.Name -contains 'auditor') { $cfgNode = $cfg.auditor }
  } catch {}
  $out = @{}
  foreach ($k in $defaults.Keys) {
    if ($cfgNode -and ($cfgNode.PSObject.Properties.Name -contains $k) -and $null -ne $cfgNode.$k) { $out[$k] = $cfgNode.$k }
    else { $out[$k] = $defaults[$k] }
  }
  return $out
}

function Write-AuditorLog {
  param([string]$Message)
  try {
    $path = Get-AuditorLogPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ([string]$Message)
    Add-Content -LiteralPath $path -Value $line -Encoding UTF8
  } catch {}
}

function ConvertTo-AuditorDateTime {
  param($Value)
  if ($null -eq $Value) { return $null }
  try {
    if ($Value -is [DateTime]) { return ([DateTime]$Value) }
    $raw = [string]$Value
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $dto = [DateTimeOffset]::Parse($raw)
    return $dto.LocalDateTime
  } catch {
    try { return [DateTime]$Value } catch { return $null }
  }
}

function Get-AuditorAgeSeconds {
  param($Value)
  $dt = ConvertTo-AuditorDateTime $Value
  if (-not $dt) { return 999999 }
  return [int][Math]::Max(0, [Math]::Round(((Get-Date) - $dt).TotalSeconds))
}

function Read-AuditorJsonFile {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $txt = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
    return ($txt | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Read-AuditorJsonl {
  param([string]$Path)
  $items = New-Object 'System.Collections.Generic.List[object]'
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return @() }
  foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $obj = $line | ConvertFrom-Json
      if ($obj) { [void]$items.Add($obj) }
    } catch {}
  }
  return @($items.ToArray())
}

function Get-AuditorChannelStatePath {
  param([string]$Slug)
  Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Slug) 'state.json'
}

function Get-AuditorChannelConversationPath {
  param([string]$Slug)
  Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Slug) 'conversation.jsonl'
}

function Test-AuditorPidAlive {
  param($PidValue)
  $pidInt = 0
  try { $pidInt = [int]$PidValue } catch { $pidInt = 0 }
  if ($pidInt -le 0) { return $false }
  return [bool](Get-Process -Id $pidInt -ErrorAction SilentlyContinue)
}

function Get-AuditorGitInfo {
  param([string]$Path)
  $root = Get-BridgeRoot
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { $Path = $root }
  $status = @()
  $head = ''
  $ageMin = 999999
  try {
    $status = @(& git -C $Path status --porcelain 2>$null | ForEach-Object { [string]$_ })
  } catch { $status = @() }
  try {
    $head = [string]((& git -C $Path rev-parse --short HEAD 2>$null) | Select-Object -First 1)
    $head = $head.Trim()
  } catch { $head = '' }
  try {
    $raw = [string]((& git -C $Path log -1 --format=%cI HEAD 2>$null) | Select-Object -First 1)
    $dt = ConvertTo-AuditorDateTime $raw
    if ($dt) { $ageMin = [int][Math]::Max(0, [Math]::Round(((Get-Date) - $dt).TotalMinutes)) }
  } catch { $ageMin = 999999 }
  return [ordered]@{
    head = $head
    status_short = ($status -join "`n")
    working_tree_lines = [int]$status.Count
    last_commit_age_min = [int]$ageMin
  }
}

function Get-AuditorSupervisorRestartCount {
  param([int]$WindowMinutes = 20)
  $path = Join-Path (Get-BridgeRoot) 'control\supervisor.log'
  if (-not (Test-Path -LiteralPath $path)) { return 0 }
  $now = Get-Date
  $cutoff = $now.AddMinutes(-[Math]::Abs($WindowMinutes))
  $count = 0
  $lines = @()
  try { $lines = Get-Content -LiteralPath $path -Tail 500 -Encoding UTF8 -ErrorAction Stop } catch { return 0 }
  foreach ($line in $lines) {
    $m = [regex]::Match([string]$line, '^\s*(\d{1,2}):(\d{2}):(\d{2})\s+(.*)$')
    if (-not $m.Success) { continue }
    $dt = [DateTime]::Today.AddHours([int]$m.Groups[1].Value).AddMinutes([int]$m.Groups[2].Value).AddSeconds([int]$m.Groups[3].Value)
    if ($dt -gt $now.AddMinutes(5)) { $dt = $dt.AddDays(-1) }
    if ($dt -lt $cutoff) { continue }
    $msg = [string]$m.Groups[4].Value
    if ($msg -imatch 'restart\s+flag\s*->\s*recycle|restart flag|recycle') { $count++ }
  }
  return $count
}

function Get-AuditorTurnsStats {
  param([int]$WindowHours = 24)
  $path = Join-Path (Get-BridgeRoot) 'turns.jsonl'
  $cutoff = [DateTime]::UtcNow.AddHours(-[Math]::Abs($WindowHours))
  $ok = 0; $timeout = 0; $empty = 0
  foreach ($rec in @(Read-AuditorJsonl -Path $path)) {
    $ts = $null
    try { $ts = ([DateTime]$rec.ts).ToUniversalTime() } catch { $ts = $null }
    if (-not $ts -or $ts -lt $cutoff) { continue }
    $status = ''
    if ($rec.PSObject.Properties.Name -contains 'outcome') { $status = [string]$rec.outcome }
    elseif ($rec.PSObject.Properties.Name -contains 'status') { $status = [string]$rec.status }
    switch -Regex ($status) {
      '^ok$' { $ok++; continue }
      'timeout' { $timeout++; continue }
      'empty' { $empty++; continue }
    }
  }
  return [ordered]@{ ok = $ok; timeout = $timeout; empty = $empty }
}

function Get-AuditorDoctorActivations {
  param([int]$WindowHours = 24, [switch]$IncludeTestEvents)
  $cutoff = [DateTime]::UtcNow.AddHours(-[Math]::Abs($WindowHours))
  $count = 0
  $metricPath = Join-Path (Get-BridgeRoot) 'metrics.jsonl'
  foreach ($rec in @(Read-AuditorJsonl -Path $metricPath)) {
    if ([string]$rec.type -ne 'doctor_event' -or [string]$rec.event -ne 'activate') { continue }
    $ts = $null
    try { $ts = ([DateTime]$rec.ts).ToUniversalTime() } catch { $ts = $null }
    if (-not $ts -or $ts -lt $cutoff) { continue }
    $reason = [string]$rec.reason
    if (-not $IncludeTestEvents -and $reason -imatch '(^test$|_test$|test_)') { continue }
    $count++
  }
  $legacyPath = Join-Path (Get-BridgeRoot) 'control\doctor-events.log'
  foreach ($lineRec in @(Read-AuditorJsonl -Path $legacyPath)) {
    if ([string]$lineRec.event -ne 'activate') { continue }
    $ts = $null
    try { $ts = ([DateTime]$lineRec.ts).ToUniversalTime() } catch { $ts = $null }
    if (-not $ts -or $ts -lt $cutoff) { continue }
    $reason = [string]$lineRec.reason
    if (-not $IncludeTestEvents -and $reason -imatch '(^test$|_test$|test_)') { continue }
    $count++
  }
  return $count
}

function Test-AuditorEmptyReplyText {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $true }
  $t = ([string]$Text).Trim()
  if ($t -imatch '^\(\s*(нет ответа от|no answer from)') { return $true }
  return [bool]($t.StartsWith('(') -and $t.EndsWith(')') -and $t.Length -lt 80 -and $t -imatch '(codex|claude)')
}

function Get-AuditorEmptyReplyStreak {
  param([string]$Slug)
  $path = Get-AuditorChannelConversationPath -Slug $Slug
  $msgs = @(Read-AuditorJsonl -Path $path)
  if ($msgs.Count -eq 0) { return 0 }
  $streak = 0
  for ($i = $msgs.Count - 1; $i -ge 0; $i--) {
    $from = [string]$msgs[$i].from
    if ($from -ne 'claude' -and $from -ne 'codex') { continue }
    if (Test-AuditorEmptyReplyText -Text ([string]$msgs[$i].text)) { $streak++ }
    else { break }
  }
  return $streak
}

function Get-AuditorTaskAgeMinutes {
  param($State, [string]$Slug)
  if (-not $State) { return 0 }
  $start = $null
  try {
    $seq = [int]$State.task_start_seq
    if ($seq -gt 0) {
      foreach ($m in @(Read-AuditorJsonl -Path (Get-AuditorChannelConversationPath -Slug $Slug))) {
        try {
          if ([int]$m.seq -eq $seq) { $start = ConvertTo-AuditorDateTime $m.ts; break }
        } catch {}
      }
    }
  } catch {}
  if (-not $start) {
    foreach ($field in @('claimed_at','doctor_started_at','current_agent_since','driver_started','heartbeat')) {
      try {
        if ($State.PSObject.Properties.Name -contains $field) {
          $start = ConvertTo-AuditorDateTime $State.$field
          if ($start) { break }
        }
      } catch {}
    }
  }
  if (-not $start) { return 0 }
  return [int][Math]::Max(0, [Math]::Round(((Get-Date) - $start).TotalMinutes))
}

function Get-AuditorCurrentTaskShort {
  param($State, [int]$Max = 140)
  $task = ''
  try { $task = [string]$State.current_task } catch { $task = '' }
  $task = ($task -replace '\s+', ' ').Trim()
  if ($task.Length -gt $Max) { return ($task.Substring(0, $Max) + '...') }
  return $task
}

function Get-AuditorStateInt {
  param($State, [string[]]$Names, [int]$Default = 0)
  if (-not $State) { return $Default }
  foreach ($name in @($Names)) {
    try {
      if ($State.PSObject.Properties.Name -contains $name -and $null -ne $State.$name) {
        return [int]$State.$name
      }
    } catch {}
  }
  return $Default
}

function Get-AuditorChannelProjectRoot {
  param($ChannelConfig)
  try {
    $pr = [string]$ChannelConfig.project_root
    if (-not [string]::IsNullOrWhiteSpace($pr) -and (Test-Path -LiteralPath $pr)) { return $pr }
  } catch {}
  return (Get-BridgeRoot)
}

function Get-AuditorSnapshot {
  $cfg = Get-AuditorConfig
  $channels = [ordered]@{}
  $restartCount = Get-AuditorSupervisorRestartCount -WindowMinutes 20
  $globalGit = Get-AuditorGitInfo -Path (Get-BridgeRoot)
  $list = @()
  try { $list = @(Get-ChannelList) } catch { $list = @() }
  if ($list.Count -eq 0) { $list = @([pscustomobject]@{ slug = 'main'; project_root = $null }) }

  foreach ($ch in $list) {
    $slug = [string]$ch.slug
    if ([string]::IsNullOrWhiteSpace($slug)) { continue }
    $statePath = Get-AuditorChannelStatePath -Slug $slug
    $st = Read-AuditorJsonFile -Path $statePath
    $projectRoot = Get-AuditorChannelProjectRoot -ChannelConfig $ch
    $git = Get-AuditorGitInfo -Path $projectRoot
    $hbAge = if ($st) { Get-AuditorAgeSeconds $st.heartbeat } else { 999999 }
    $taskAge = if ($st) { Get-AuditorTaskAgeMinutes -State $st -Slug $slug } else { 0 }
    $agentPid = 0
    try { $agentPid = [int]$st.agent_pid } catch { $agentPid = 0 }
    $progressRepeats = 0
    try {
      if ($st.PSObject.Properties.Name -contains 'progress_fingerprint_repeats') { $progressRepeats = [int]$st.progress_fingerprint_repeats }
      elseif ($st.PSObject.Properties.Name -contains 'no_progress_count') { $progressRepeats = [int]$st.no_progress_count }
    } catch { $progressRepeats = 0 }
    $channels[$slug] = [ordered]@{
      status = if ($st) { [string]$st.status } else { 'missing_state' }
      doctor_active = if ($st) { [bool]$st.doctor_active } else { $false }
      agent_pid_alive = Test-AuditorPidAlive -PidValue $agentPid
      hb_age_sec = [int]$hbAge
      task_turn = Get-AuditorStateInt -State $st -Names @('task_turn','current_task_turn') -Default 0
      critic_retry_count = Get-AuditorStateInt -State $st -Names @('critic_retry_count') -Default 0
      current_task_short = if ($st) { Get-AuditorCurrentTaskShort -State $st } else { '' }
      restart_events_20min = [int]$restartCount
      working_tree_lines = [int]$git.working_tree_lines
      last_commit_age_min = [int]$git.last_commit_age_min
      empty_reply_streak = [int](Get-AuditorEmptyReplyStreak -Slug $slug)
      progress_fingerprint_repeats = [int]$progressRepeats
      task_age_min = [int]$taskAge
    }
  }

  return [ordered]@{
    ts = (Get-Date).ToString('o')
    channels = $channels
    git = $globalGit
    turns_24h = (Get-AuditorTurnsStats -WindowHours 24)
    doctor_activations_24h = [int](Get-AuditorDoctorActivations -WindowHours ([int]$cfg.doctorRecidivismHours))
    supervisor_restarts_20min = [int]$restartCount
  }
}

function New-AuditorTrigger {
  param([string]$Name, [string]$Detail, [string]$Channel = '*')
  [pscustomobject]@{ name = $Name; detail = $Detail; channel = $Channel }
}

function Test-AuditorTriggers {
  param($Snapshot)
  if (-not $Snapshot) { $Snapshot = Get-AuditorSnapshot }
  $cfg = Get-AuditorConfig
  $items = New-Object 'System.Collections.Generic.List[object]'
  $criticMax = 2
  try {
    $bcfg = Get-BridgeConfig
    if ($bcfg.PSObject.Properties.Name -contains 'criticMaxRetries') { $criticMax = [int]$bcfg.criticMaxRetries }
  } catch {}

  foreach ($slug in @($Snapshot.channels.Keys)) {
    $c = $Snapshot.channels[$slug]
    if ([int]$c.empty_reply_streak -ge 2) {
      [void]$items.Add((New-AuditorTrigger -Name 'empty_reply_streak' -Channel $slug -Detail ("{0} consecutive empty agent replies" -f [int]$c.empty_reply_streak)))
    }
    if ([int]$c.task_turn -gt 10 -and [int]$c.hb_age_sec -lt 60) {
      [void]$items.Add((New-AuditorTrigger -Name 'same_task_too_long' -Channel $slug -Detail ("task_turn={0}, hb_age_sec={1}" -f [int]$c.task_turn, [int]$c.hb_age_sec)))
    }
    if ([int]$c.critic_retry_count -ge $criticMax -and -not [string]::IsNullOrWhiteSpace([string]$c.current_task_short)) {
      [void]$items.Add((New-AuditorTrigger -Name 'critic_pingpong' -Channel $slug -Detail ("critic_retry_count={0}, max={1}" -f [int]$c.critic_retry_count, $criticMax)))
    }
    $active = ([string]$c.status -ne 'idle' -and -not [string]::IsNullOrWhiteSpace([string]$c.current_task_short))
    if ($active -and [int]$c.task_age_min -gt 30 -and [int]$c.working_tree_lines -gt 0 -and [int]$c.last_commit_age_min -gt 30) {
      [void]$items.Add((New-AuditorTrigger -Name 'commit_famine' -Channel $slug -Detail ("task_age_min={0}, working_tree_lines={1}, last_commit_age_min={2}" -f [int]$c.task_age_min, [int]$c.working_tree_lines, [int]$c.last_commit_age_min)))
    }
  }

  if ([int]$Snapshot.git.working_tree_lines -gt 500) {
    [void]$items.Add((New-AuditorTrigger -Name 'working_tree_drift' -Detail ("working_tree_lines={0}" -f [int]$Snapshot.git.working_tree_lines)))
  }
  if ([int]$Snapshot.supervisor_restarts_20min -gt 4) {
    [void]$items.Add((New-AuditorTrigger -Name 'restart_frequency' -Detail ("supervisor_restarts_20min={0}" -f [int]$Snapshot.supervisor_restarts_20min)))
  }
  $recMax = [int]$cfg.doctorRecidivismMax
  if ([int]$Snapshot.doctor_activations_24h -ge $recMax) {
    [void]$items.Add((New-AuditorTrigger -Name 'doctor_recidivism' -Detail ("doctor_activations_24h={0}, max={1}" -f [int]$Snapshot.doctor_activations_24h, $recMax)))
  }
  return @($items.ToArray())
}

function Get-AuditorMemoryBlock {
  param([object[]]$Triggers)
  try {
    if (-not (Get-Command Search-Memory -ErrorAction SilentlyContinue)) { return '' }
    $q = (@($Triggers) | ForEach-Object { "$($_.name) $($_.detail)" }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($q)) { $q = 'Auditor verdict bridge failure recovery' }
    $hits = @(Search-Memory -Query $q -RequireTag 'auditor-verdict' -TopK 3 -MinScore 0.2 -Channel '__all__')
    if ($hits.Count -eq 0) { return '' }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($h in $hits) {
      $txt = ''
      try { $txt = [string]$h.Mem.text } catch { $txt = '' }
      $txt = ($txt -replace '\s+', ' ').Trim()
      if ($txt.Length -gt 220) { $txt = $txt.Substring(0,220) + '...' }
      if ($txt) { [void]$lines.Add(("- {0}" -f $txt)) }
    }
    return ($lines.ToArray() -join "`n")
  } catch { return '' }
}

function Invoke-AuditorLLM {
  param($Snapshot, [object[]]$Triggers)
  $cfg = Get-AuditorConfig
  $model = [string]$cfg.model
  if ([string]::IsNullOrWhiteSpace($model)) { $model = 'gemini-2.5-flash-lite' }
  $snapJson = ($Snapshot | ConvertTo-Json -Depth 10)
  $trigJson = (@($Triggers) | ConvertTo-Json -Depth 8)
  $mem = Get-AuditorMemoryBlock -Triggers $Triggers
  if ([string]::IsNullOrWhiteSpace($mem)) { $mem = '(none)' }
  $prompt = @"
You are Auditor, a sensor-only diagnostic agent for a Windows bridge that runs Claude and Codex.
Classify the current anomaly. Do not propose code patches. Return only compact JSON:
{"class":"normal|transient|hung|corrupted_state|unsolvable","confidence":0.0,"reason":"short reason","recommended_action":"short action"}

Rules:
- normal: no action needed.
- transient: temporary noise; do not activate Doctor.
- hung: task appears stuck but Doctor can likely repair or restart the flow.
- corrupted_state: state/conversation data looks inconsistent and needs operator-visible notice.
- unsolvable: repeated Doctor calls or manual operator decision needed; do not call Doctor again.

Recent auditor-verdict memory:
$mem

Triggers:
$trigJson

Snapshot:
$snapJson
"@
  $raw = $null
  try { $raw = Invoke-LLM -Purpose 'audit' -Model $model -Prompt $prompt -TimeoutSec 60 -Temperature 0.2 } catch { $raw = $null }
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return [pscustomobject]@{ class='transient'; confidence=0.0; reason='LLM returned empty response'; recommended_action='log only' }
  }
  try {
    $txt = ([string]$raw).Trim()
    $txt = [regex]::Replace($txt, '^\s*```(?:json)?\s*', '')
    $txt = [regex]::Replace($txt, '\s*```\s*$', '')
    $m = [regex]::Match($txt, '(?s)\{.*\}')
    if ($m.Success) { $txt = $m.Value }
    $obj = $txt | ConvertFrom-Json
    $class = ([string]$obj.class).ToLowerInvariant()
    if ($script:AuditorClasses -notcontains $class) { $class = 'transient' }
    $conf = 0.0
    try { $conf = [double]$obj.confidence } catch { $conf = 0.0 }
    return [pscustomobject]@{
      class = $class
      confidence = $conf
      reason = [string]$obj.reason
      recommended_action = [string]$obj.recommended_action
    }
  } catch {
    return [pscustomobject]@{ class='transient'; confidence=0.0; reason=('LLM parse error: ' + $_.Exception.Message); recommended_action='log only' }
  }
}

function Add-AuditorVerdictMemory {
  param([string]$Class, [string]$Reason)
  if ([string]$Class -eq 'normal') { return }
  try {
    if (Get-Command Add-Memory -ErrorAction SilentlyContinue) {
      $text = ("{0} -- {1}" -f $Class, $Reason)
      Add-Memory -Text $text -Tags @('auditor-verdict') -Source ('auditor:' + $Class) -Importance 0.65 -Channel 'main' | Out-Null
    }
  } catch {}
}

function Invoke-AuditorInChannel {
  param([string]$Slug, [scriptblock]$Body)
  $old = $null
  $had = $false
  try {
    if (Get-Command Get-PinnedChannel -ErrorAction SilentlyContinue) {
      $old = Get-PinnedChannel
      $had = $true
    }
    if (Get-Command Set-PinnedChannel -ErrorAction SilentlyContinue) { Set-PinnedChannel $Slug }
    & $Body
  } finally {
    try {
      if ($had -and (Get-Command Set-PinnedChannel -ErrorAction SilentlyContinue)) { Set-PinnedChannel $old }
    } catch {}
  }
}

function Add-AuditorMainMessage {
  param([string]$Text)
  try {
    Invoke-AuditorInChannel -Slug 'main' -Body { Add-Message -From system -Text $Text -Kind event | Out-Null }
  } catch {}
}

function Dispatch-AuditorVerdict {
  param($Verdict, [object[]]$Triggers = @(), $Snapshot = $null, [switch]$DryRun)
  $class = ([string]$Verdict.class).ToLowerInvariant()
  if ($script:AuditorClasses -notcontains $class) { $class = 'transient' }
  $reason = [string]$Verdict.reason
  if ([string]::IsNullOrWhiteSpace($reason)) { $reason = 'no reason provided' }
  $primary = if (@($Triggers).Count -gt 0) { @($Triggers)[0] } else { [pscustomobject]@{ name='unknown'; channel='*'; detail='' } }
  $primaryName = [string]$primary.name
  if ([string]::IsNullOrWhiteSpace($primaryName)) { $primaryName = 'unknown' }
  $targetChannel = [string]$primary.channel
  if ([string]::IsNullOrWhiteSpace($targetChannel) -or $targetChannel -eq '*') {
    try { $targetChannel = Get-EffectiveChannel } catch { $targetChannel = 'main' }
  }

  if ($class -eq 'normal') {
    Write-AuditorLog ("ok: {0}" -f $reason)
    return [pscustomobject]@{ class=$class; action='none'; reason=$reason }
  }
  if ($class -eq 'transient') {
    Write-AuditorLog ("ok: {0}" -f $reason)
    Add-AuditorVerdictMemory -Class $class -Reason $reason
    return [pscustomobject]@{ class=$class; action='none'; reason=$reason }
  }

  if ($class -eq 'hung') {
    $cfg = Get-AuditorConfig
    $max = [int]$cfg.doctorRecidivismMax
    $activations = 0
    try { if ($Snapshot) { $activations = [int]$Snapshot.doctor_activations_24h } } catch { $activations = 0 }
    if ($activations -ge $max) {
      $class = 'unsolvable'
      $reason = ("Doctor recidivism guard: {0} activations in window; original hung reason: {1}" -f $activations, $reason)
    } else {
      $doctorReason = 'auditor:' + $primaryName
      if ($DryRun) {
        Write-AuditorLog ("dry-run: Activate-Doctor -Reason {0} -Detail {1}" -f $doctorReason, $reason)
        return [pscustomobject]@{ class='hung'; action='Activate-Doctor'; reason=$doctorReason; detail=$reason; channel=$targetChannel; dry_run=$true }
      }
      $activated = $false
      try {
        Invoke-AuditorInChannel -Slug $targetChannel -Body { $script:AuditorActivated = Activate-Doctor -Reason $doctorReason -Detail $reason }
        $activated = [bool]$script:AuditorActivated
      } catch { $activated = $false }
      Write-AuditorLog ("hung: doctor={0}; reason={1}; detail={2}; channel={3}" -f $activated, $doctorReason, $reason, $targetChannel)
      Add-AuditorVerdictMemory -Class 'hung' -Reason $reason
      return [pscustomobject]@{ class='hung'; action='Activate-Doctor'; activated=$activated; reason=$doctorReason; detail=$reason; channel=$targetChannel }
    }
  }

  if ($class -eq 'corrupted_state') {
    $msg = "⚠ Auditor: corrupted_state -- $reason"
    Add-AuditorMainMessage -Text $msg
    Write-AuditorLog ("corrupted_state: {0}" -f $reason)
    Add-AuditorVerdictMemory -Class $class -Reason $reason
    return [pscustomobject]@{ class=$class; action='notify'; reason=$reason }
  }

  if ($class -eq 'unsolvable') {
    $msg = "⚠ Auditor: unsolvable -- $reason"
    Add-AuditorMainMessage -Text $msg
    Write-AuditorLog ("unsolvable: pause requested but not written by Auditor; {0}" -f $reason)
    Add-AuditorVerdictMemory -Class $class -Reason $reason
    return [pscustomobject]@{ class=$class; action='notify_pause_requested'; reason=$reason }
  }

  Write-AuditorLog ("ok: {0}" -f $reason)
  return [pscustomobject]@{ class='transient'; action='none'; reason=$reason }
}

function Should-RunAuditor {
  $cfg = Get-AuditorConfig
  try { if (-not [bool]$cfg.enabled) { return $false } } catch {}
  try {
    $st = Read-State
    if ($st) {
      if ([string]$st.status -ne 'idle') { return $false }
      if ([bool]$st.doctor_active) { return $false }
    }
  } catch { return $false }

  $path = Get-AuditorMarkerPath
  if (-not (Test-Path -LiteralPath $path)) { return $true }
  try {
    $raw = ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)).Trim()
    $dt = ConvertTo-AuditorDateTime $raw
    if (-not $dt) { return $true }
    $ageMin = ((Get-Date) - $dt).TotalMinutes
    return ($ageMin -ge [double]$cfg.intervalMin)
  } catch {
    return $true
  }
}

function Save-AuditorMarker {
  try {
    $path = Get-AuditorMarkerPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($path, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

function Invoke-Auditor {
  try {
    $snapshot = Get-AuditorSnapshot
    $triggers = @(Test-AuditorTriggers -Snapshot $snapshot)
    if ($triggers.Count -eq 0) {
      Write-AuditorLog 'no anomaly'
      Save-AuditorMarker
      return [pscustomobject]@{ class='normal'; action='none'; triggers=0 }
    }
    $verdict = Invoke-AuditorLLM -Snapshot $snapshot -Triggers $triggers
    $result = Dispatch-AuditorVerdict -Verdict $verdict -Triggers $triggers -Snapshot $snapshot
    Save-AuditorMarker
    return $result
  } catch {
    Write-AuditorLog ("error: " + $_.Exception.Message)
    Save-AuditorMarker
    return [pscustomobject]@{ class='transient'; action='error'; reason=$_.Exception.Message }
  }
}

function Start-AuditorIfDue {
  try {
    if (-not (Should-RunAuditor)) { return $false }
    Invoke-Auditor | Out-Null
    return $true
  } catch {
    Write-AuditorLog ("Start-AuditorIfDue error: " + $_.Exception.Message)
    try { Add-Message -From system -Text ("⚠ Auditor error: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    return $false
  }
}
