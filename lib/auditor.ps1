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
  $headFull = ''
  $ageMin = 999999
  try {
    $status = @(& git -C $Path status --porcelain 2>$null | ForEach-Object { [string]$_ })
  } catch { $status = @() }
  try {
    $head = [string]((& git -C $Path rev-parse --short HEAD 2>$null) | Select-Object -First 1)
    $head = $head.Trim()
  } catch { $head = '' }
  try {
    $headFull = [string]((& git -C $Path rev-parse HEAD 2>$null) | Select-Object -First 1)
    $headFull = $headFull.Trim()
  } catch { $headFull = '' }
  try {
    $raw = [string]((& git -C $Path log -1 --format=%cI HEAD 2>$null) | Select-Object -First 1)
    $dt = ConvertTo-AuditorDateTime $raw
    if ($dt) { $ageMin = [int][Math]::Max(0, [Math]::Round(((Get-Date) - $dt).TotalMinutes)) }
  } catch { $ageMin = 999999 }
  $commitMsg = ''
  try {
    $commitMsg = [string]((& git -C $Path log -1 --format=%s HEAD 2>$null) | Select-Object -First 1)
    $commitMsg = $commitMsg.Trim()
  } catch { $commitMsg = '' }
  return [ordered]@{
    head = $head
    head_full = $headFull
    status_short = ($status -join "`n")
    working_tree_lines = [int]$status.Count
    last_commit_age_min = [int]$ageMin
    last_commit_msg = $commitMsg
  }
}

function Test-AuditorDoctorCommitMessage {
  param([string]$Message)
  if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
  $msg = ([string]$Message).Trim()
  if ($msg -match '^(?:[^:]+:\s*)?[^A-Za-zА-Яа-я0-9]{0,8}ДОКТОР\s*[—-]') { return $true }
  if ($msg -match '^\[salvage\].*?:\s*[^A-Za-zА-Яа-я0-9]{0,8}ДОКТОР\s*[—-]') { return $true }
  return $false
}

function Test-AuditorQaCachePass {
  param(
    $QaVerdictCache,
    [string]$CommitSha,
    [int]$MaxMinutes = 360
  )
  if ($null -eq $QaVerdictCache -or [string]::IsNullOrWhiteSpace($CommitSha)) { return $false }
  try {
    $qcHead = [string](Get-AuditorObjectProperty -Object $QaVerdictCache -Name 'head')
    $qcVerdict = [string](Get-AuditorObjectProperty -Object $QaVerdictCache -Name 'verdict')
    $qcSource = [string](Get-AuditorObjectProperty -Object $QaVerdictCache -Name 'source')
    $qcTs = Get-AuditorObjectProperty -Object $QaVerdictCache -Name 'ts'
    if ([string]::IsNullOrWhiteSpace($qcHead) -or [string]::IsNullOrWhiteSpace($qcVerdict)) { return $false }
    if ($qcVerdict -ne 'PASS' -or $qcSource -ne 'post_commit') { return $false }

    $commit = ([string]$CommitSha).Trim()
    $cacheHead = $qcHead.Trim()
    $headMatches = ($cacheHead -eq $commit)
    if (-not $headMatches -and $cacheHead.Length -ge 7 -and $commit.Length -ge 7) {
      $headMatches = $cacheHead.StartsWith($commit, [System.StringComparison]::OrdinalIgnoreCase) -or $commit.StartsWith($cacheHead, [System.StringComparison]::OrdinalIgnoreCase)
    }
    if (-not $headMatches) { return $false }

    $dt = ConvertTo-AuditorDateTime $qcTs
    if (-not $dt) { return $false }
    $cutoff = (Get-Date).AddMinutes(-[Math]::Abs($MaxMinutes))
    return [bool]($dt -ge $cutoff)
  } catch {}
  return $false
}

function Test-AuditorDoctorRepairComplete {
  param(
    [int]$MaxMinutes = 360,
    [string]$LogPath = $null
  )
  if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path (Get-BridgeRoot) 'control\doctor.log'
  }
  if (-not (Test-Path -LiteralPath $LogPath)) { return $false }
  try {
    $lines = Get-Content -LiteralPath $LogPath -Tail 100 -Encoding UTF8 -ErrorAction Stop
    $cutoff = (Get-Date).AddMinutes(-[Math]::Abs($MaxMinutes))
    $lastComplete = $null
    foreach ($line in $lines) {
      if ([string]$line -match '\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] Doctor complete: repaired') {
        try { $lastComplete = [DateTime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', $null) } catch {}
      }
    }
    if ($lastComplete -and $lastComplete -ge $cutoff) { return $true }
  } catch {}
  return $false
}

function Test-AuditorDoctorQaPass {
  param(
    [int]$MaxMinutes = 360,
    [string]$LogPath = $null,
    $QaVerdictCache = $null,
    [string]$CommitSha = ''
  )
  if (-not (Test-AuditorDoctorRepairComplete -MaxMinutes $MaxMinutes -LogPath $LogPath)) { return $false }
  return (Test-AuditorQaCachePass -QaVerdictCache $QaVerdictCache -CommitSha $CommitSha -MaxMinutes $MaxMinutes)
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

function Get-AuditorLastSeqAge {
  # 2026-05-27v7: track lastSeq per channel + return minutes since it last advanced.
  # Uses control/auditor-seqtrack.json. Each call updates the tracker. If seq has
  # advanced since last call, returns 0. If unchanged, returns minutes-since-last-advance.
  # Used by 'wait_state_stuck' trigger -- detects driver in waiting state with no
  # message activity (zombie-job freeze, stuck agent, lost background work).
  param([string]$Slug, [int]$CurrentSeq)
  if ([string]::IsNullOrWhiteSpace($Slug) -or $CurrentSeq -le 0) { return 0 }
  $now = Get-Date
  $trackPath = Join-Path (Get-BridgeRoot) 'control\auditor-seqtrack.json'
  $track = @{}
  if (Test-Path -LiteralPath $trackPath) {
    try {
      $raw = Get-Content -LiteralPath $trackPath -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($raw) {
        foreach ($p in $raw.PSObject.Properties) {
          $track[$p.Name] = @{ seq = [int]$p.Value.seq; ts = [string]$p.Value.ts }
        }
      }
    } catch {}
  }
  $ageMin = 0
  if ($track.ContainsKey($Slug)) {
    $prev = $track[$Slug]
    if ([int]$prev.seq -eq $CurrentSeq) {
      try { $ageMin = [int](($now - [datetime]$prev.ts).TotalMinutes) } catch { $ageMin = 0 }
    } else {
      $track[$Slug] = @{ seq = $CurrentSeq; ts = $now.ToString('o') }
      $ageMin = 0
    }
  } else {
    $track[$Slug] = @{ seq = $CurrentSeq; ts = $now.ToString('o') }
  }
  try {
    $obj = [pscustomobject]@{}
    foreach ($k in $track.Keys) { $obj | Add-Member -NotePropertyName $k -NotePropertyValue ([pscustomobject]$track[$k]) -Force }
    [System.IO.File]::WriteAllText($trackPath, ($obj | ConvertTo-Json -Compress -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
  return $ageMin
}

function Get-AuditorTimestampAgeMinutes {
  param(
    $State,
    [string[]]$Names
  )
  if (-not $State -or -not $Names) { return $null }
  foreach ($name in @($Names)) {
    try {
      if (-not ($State.PSObject.Properties.Name -contains $name)) { continue }
      $raw = [string]$State.$name
      if ([string]::IsNullOrWhiteSpace($raw)) { continue }
      $ts = [datetime]::Parse($raw, $null, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
      return [int](((Get-Date).ToUniversalTime() - $ts).TotalMinutes)
    } catch {}
  }
  return $null
}

function Test-AuditorInDecisionSynthesis {
  param($Channel)
  if (-not $Channel) { return $false }
  if ([string]$Channel.task_mode -eq 'synthesis') { return $true }

  # During Decision Synthesis the driver can legitimately have active_jobs=0
  # between model stages. Treat a fresh synthesis checkpoint as forward progress.
  try {
    if ($Channel.PSObject.Properties.Name -contains 'synthesis_last_step_age_min') {
      $age = [Nullable[int]]$Channel.synthesis_last_step_age_min
      if ($null -ne $age -and [int]$age -ge 0 -and [int]$age -lt 15) { return $true }
    }
  } catch {}
  return $false
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
    # 2026-05-27v7: extra fields for 'wait_state_stuck' trigger detection
    $lastSeq = Get-AuditorStateInt -State $st -Names @('lastSeq') -Default 0
    $lastSeqAge = Get-AuditorLastSeqAge -Slug $slug -CurrentSeq $lastSeq
    $statusText = if ($st -and $st.PSObject.Properties.Name -contains 'status_text') { [string]$st.status_text } else { '' }
    $activeJobsCount = 0
    try { if ($st -and $st.PSObject.Properties.Name -contains 'active_jobs') { $activeJobsCount = @($st.active_jobs).Count } } catch {}
    $activeAgent = if ($st -and $st.PSObject.Properties.Name -contains 'active_agent') { [string]$st.active_agent } else { '' }
    $synthesisLastStepAge = Get-AuditorTimestampAgeMinutes -State $st -Names @('synthesis_last_step_at','last_synthesis_step_at','synthesis_heartbeat','synthesis_updated_at')
    $qaVerdictCache = $null
    try { if ($st -and $st.PSObject.Properties.Name -contains 'qa_verdict_cache') { $qaVerdictCache = $st.qa_verdict_cache } } catch { $qaVerdictCache = $null }
    $channels[$slug] = [ordered]@{
      status = if ($st) { [string]$st.status } else { 'missing_state' }
      doctor_active = if ($st) { [bool]$st.doctor_active } else { $false }
      agent_pid_alive = Test-AuditorPidAlive -PidValue $agentPid
      hb_age_sec = [int]$hbAge
      task_turn = Get-AuditorStateInt -State $st -Names @('task_turn','current_task_turn') -Default 0
      task_mode = if ($st -and $st.PSObject.Properties.Name -contains 'task_mode') { [string]$st.task_mode } else { 'normal' }
      discuss_turn = Get-AuditorStateInt -State $st -Names @('discuss_turn') -Default 0
      task_id = if ($st -and $st.PSObject.Properties.Name -contains 'task_id') { [string]$st.task_id } else { '' }
      task_start_seq = Get-AuditorStateInt -State $st -Names @('task_start_seq') -Default 0
      critic_retry_count = Get-AuditorStateInt -State $st -Names @('critic_retry_count') -Default 0
      current_task_short = if ($st) { Get-AuditorCurrentTaskShort -State $st } else { '' }
      restart_events_20min = [int]$restartCount
      head = [string]$git.head
      head_full = [string]$git.head_full
      working_tree_lines = [int]$git.working_tree_lines
      last_commit_age_min = [int]$git.last_commit_age_min
      last_commit_msg = [string]$git.last_commit_msg
      qa_verdict_cache = $qaVerdictCache
      empty_reply_streak = [int](Get-AuditorEmptyReplyStreak -Slug $slug)
      progress_fingerprint_repeats = [int]$progressRepeats
      task_age_min = [int]$taskAge
      last_seq = [int]$lastSeq
      last_seq_age_min = [int]$lastSeqAge
      status_text = $statusText
      active_jobs_count = [int]$activeJobsCount
      active_agent = $activeAgent
      synthesis_last_step_age_min = $synthesisLastStepAge
      paused = if ($st -and $st.PSObject.Properties.Name -contains 'paused') { [bool]$st.paused } else { $false }
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

function Get-StaleAuditLaunchInfo {
  param(
    [Parameter(Mandatory=$true)][string]$AuditDir,
    [int]$WindowHours = 36
  )
  $reportAgeHours = [double]999
  $recentDenies   = 0
  $recentStarts   = 0
  try {
    $markerPath = Join-Path $AuditDir 'audit.last'
    if (Test-Path -LiteralPath $markerPath) {
      $raw = [System.IO.File]::ReadAllText($markerPath).Trim()
      if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $last = [datetime]::Parse($raw, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        $reportAgeHours = ((Get-Date).ToUniversalTime() - $last.ToUniversalTime()).TotalHours
      }
    }
  } catch {}
  try {
    $ledgerPath = Join-Path $AuditDir 'audit.launches.jsonl'
    if (Test-Path -LiteralPath $ledgerPath) {
      $cutoff = (Get-Date).ToUniversalTime().AddHours(-[Math]::Abs($WindowHours))
      $lines = @()
      try { $lines = [System.IO.File]::ReadAllLines($ledgerPath) } catch {}
      foreach ($line in @($lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
          $entry = ConvertFrom-Json -InputObject $line -ErrorAction Stop
          if (-not $entry) { continue }
          $ts = [datetime]::Parse([string]$entry.ts, $null, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
          if ($ts -lt $cutoff) { continue }
          $dec = [string]$entry.decision
          if ($dec -eq 'denied')  { $recentDenies++ }
          elseif ($dec -eq 'started') { $recentStarts++ }
        } catch {}
      }
    }
  } catch {}
  return [pscustomobject]@{ report_age_hours = $reportAgeHours; recent_denies = $recentDenies; recent_starts = $recentStarts }
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

    # 2026-05-27v7: wait_state_stuck — driver claims working + heartbeat fresh,
    # but lastSeq hasn't moved for >= 5 min. Real cases: zombie .done jobs,
    # dead agent process not noticed by polling, lost background work after
    # restart. AUTOMATIC remediation: call Recover-ZombieJobs to write fake
    # .done markers for jobs with dead PIDs. Then if still stuck after 10 min,
    # escalate to full Doctor activation.
    $isWorking = ([string]$c.status -eq 'working')
    $hbFresh   = ([int]$c.hb_age_sec -lt 60)
    $seqAge    = [int]$c.last_seq_age_min
    $waitsBg   = ([int]$c.active_jobs_count -gt 0) -or ([string]$c.status_text -match 'Жду фоновую|waiting|stuck|pending')
    $noAgent   = [string]::IsNullOrWhiteSpace([string]$c.active_agent) -and [int]$c.task_turn -eq 0
    $inSynthesis = Test-AuditorInDecisionSynthesis -Channel $c
    if ($isWorking -and $hbFresh -and $seqAge -ge 5 -and -not $inSynthesis -and ($waitsBg -or $noAgent)) {
      # First try the cheap fix: recover zombie jobs in-place.
      $rec = $null
      try { $rec = Recover-ZombieJobs -Slug $slug } catch {}
      $recCount = if ($rec) { [int]$rec.recovered } else { 0 }
      if ($recCount -gt 0) {
        try { Invoke-AuditorInChannel -Slug $slug -Body { Add-Message -From system -Text ("🔧 Auditor: разморозил " + $recCount + " zombie-jobs (seq stuck " + $seqAge + " min). Driver продолжит.") -Kind event | Out-Null } } catch {}
      } else {
        # No jobs to fix -- something else is stuck. Raise trigger for Doctor.
        [void]$items.Add((New-AuditorTrigger -Name 'wait_state_stuck' -Channel $slug -Detail ("last_seq_age_min={0}, status_text={1}, active_jobs={2}, active_agent={3}" -f $seqAge, [string]$c.status_text, [int]$c.active_jobs_count, [string]$c.active_agent)))
      }
    }

    if ([int]$c.empty_reply_streak -ge 2) {
      [void]$items.Add((New-AuditorTrigger -Name 'empty_reply_streak' -Channel $slug -Detail ("{0} consecutive empty agent replies" -f [int]$c.empty_reply_streak)))
    }
    # After a hard restart doctor.ps1 resets task_mode='normal' and discuss_turn=0,
    # so also detect DISCUSS tasks by their title prefix — current_task_short survives restarts.
    $inDiscussion = ([string]$c.task_mode -eq 'discuss') -or ([int]$c.discuss_turn -gt 0) -or ([string]$c.current_task_short -match '^\[DISCUSS\]')
    if ([int]$c.task_turn -gt 30 -and [int]$c.hb_age_sec -lt 60 -and -not $inDiscussion) {
      [void]$items.Add((New-AuditorTrigger -Name 'same_task_too_long' -Channel $slug -Detail ("task_turn={0}, hb_age_sec={1}" -f [int]$c.task_turn, [int]$c.hb_age_sec)))
    }
    if ([int]$c.critic_retry_count -ge $criticMax -and -not [string]::IsNullOrWhiteSpace([string]$c.current_task_short)) {
      [void]$items.Add((New-AuditorTrigger -Name 'critic_pingpong' -Channel $slug -Detail ("critic_retry_count={0}, max={1}" -f [int]$c.critic_retry_count, $criticMax)))
    }
    $active = ([string]$c.status -ne 'idle' -and -not [string]::IsNullOrWhiteSpace([string]$c.current_task_short))
    $lastCommitIsDoctor = Test-AuditorDoctorCommitMessage -Message ([string]$c.last_commit_msg)
    $lastCommitSha = [string]$c.head_full
    if ([string]::IsNullOrWhiteSpace($lastCommitSha)) { $lastCommitSha = [string]$c.head }
    $doctorQaOk = if ($lastCommitIsDoctor) { Test-AuditorDoctorQaPass -MaxMinutes 360 -CommitSha $lastCommitSha -QaVerdictCache $c.qa_verdict_cache } else { $false }
    # 2026-06-19 FIX: progress-aware commit_famine. The old gate was purely time + dirty-tree
    # with NO progress check, so a big task that is genuinely progressing but legitimately needs
    # >30 min before its first atomic commit looked identical to a dead one and got suspended into
    # the Doctor (held/failed with edits abandoned). Now exempt a task when a LIVE agent is
    # actively working it, when the channel is operator-paused, or when the channel made fresh
    # non-spinning progress between turns. Missing seq-age data is treated as stale.
    $liveAgentRunning = (-not [string]::IsNullOrWhiteSpace([string]$c.active_agent)) -and [bool]$c.agent_pid_alive
    $freshProgressMin = 10
    $freshRepeatLimit = 3
    $seqAgeForFreshness = [int]::MaxValue
    $repeatForFreshness = 0
    try {
      $rawSeqAge = $null
      if ($c -is [System.Collections.IDictionary]) {
        if ($c.Contains('last_seq_age_min')) { $rawSeqAge = $c['last_seq_age_min'] }
      } elseif ($c.PSObject.Properties.Name -contains 'last_seq_age_min') {
        $rawSeqAge = $c.last_seq_age_min
      }
      if ($null -ne $rawSeqAge -and -not [string]::IsNullOrWhiteSpace([string]$rawSeqAge)) { $seqAgeForFreshness = [int]$rawSeqAge }
    } catch { $seqAgeForFreshness = [int]::MaxValue }
    try {
      $rawRepeats = $null
      if ($c -is [System.Collections.IDictionary]) {
        if ($c.Contains('progress_fingerprint_repeats')) { $rawRepeats = $c['progress_fingerprint_repeats'] }
      } elseif ($c.PSObject.Properties.Name -contains 'progress_fingerprint_repeats') {
        $rawRepeats = $c.progress_fingerprint_repeats
      }
      if ($null -ne $rawRepeats -and -not [string]::IsNullOrWhiteSpace([string]$rawRepeats)) { $repeatForFreshness = [int]$rawRepeats }
    } catch { $repeatForFreshness = 0 }
    $freshWork = ($seqAgeForFreshness -lt $freshProgressMin -and $repeatForFreshness -lt $freshRepeatLimit)
    if ($active -and -not $inDiscussion -and -not $liveAgentRunning -and -not [bool]$c.paused -and -not $freshWork -and [int]$c.task_age_min -gt 30 -and [int]$c.working_tree_lines -gt 0 -and [int]$c.last_commit_age_min -gt 30 -and -not ($lastCommitIsDoctor -and $doctorQaOk)) {
      [void]$items.Add((New-AuditorTrigger -Name 'commit_famine' -Channel $slug -Detail ("task_age_min={0}, working_tree_lines={1}, last_commit_age_min={2}, last_seq_age_min={3}, progress_fingerprint_repeats={4}, live_agent={5}, paused={6}" -f [int]$c.task_age_min, [int]$c.working_tree_lines, [int]$c.last_commit_age_min, $seqAgeForFreshness, $repeatForFreshness, $liveAgentRunning, [bool]$c.paused)))
    }
  }

  # stale_audit: audit has not produced a report in >30h while launch ledger shows recent denied/started.
  # Threshold 30h = slightly more than one day - a missed night becomes visible.
  try {
    $staleAuditDir = Join-Path (Get-BridgeRoot) 'audit'
    $staleInfo = Get-StaleAuditLaunchInfo -AuditDir $staleAuditDir -WindowHours 36
    $staleThresholdHours = 30
    $hasRecentActivity = ([int]$staleInfo.recent_denies -gt 0 -or [int]$staleInfo.recent_starts -gt 0)
    if ([double]$staleInfo.report_age_hours -ge $staleThresholdHours -and $hasRecentActivity) {
      [void]$items.Add((New-AuditorTrigger -Name 'stale_audit' -Detail ("report_age_hours={0:F1}, recent_denies={1}, recent_starts={2}" -f [double]$staleInfo.report_age_hours, [int]$staleInfo.recent_denies, [int]$staleInfo.recent_starts)))
    }
  } catch { Write-AuditorLog ("stale_audit check error: {0}" -f $_.Exception.Message) }

  if ([int]$Snapshot.git.working_tree_lines -gt 500) {
    [void]$items.Add((New-AuditorTrigger -Name 'working_tree_drift' -Detail ("working_tree_lines={0}" -f [int]$Snapshot.git.working_tree_lines)))
  }
  if ([int]$Snapshot.supervisor_restarts_20min -gt 4) {
    [void]$items.Add((New-AuditorTrigger -Name 'restart_frequency' -Detail ("supervisor_restarts_20min={0}" -f [int]$Snapshot.supervisor_restarts_20min)))
  }
  # Recidivism is actionable only while Doctor is currently active.
  # The historical 24h count alone can keep firing after the system recovers.
  $recMax = [int]$cfg.doctorRecidivismMax
  if ([int]$Snapshot.doctor_activations_24h -ge $recMax) {
    $anyDoctorActiveNow = $false
    try {
      $channels = $Snapshot.channels
      if ($channels -is [System.Collections.IDictionary]) {
        foreach ($k in @($channels.Keys)) {
          $chSlot = $channels[$k]
          if ($chSlot -and [bool](Get-AuditorObjectProperty -Object $chSlot -Name 'doctor_active')) { $anyDoctorActiveNow = $true; break }
        }
      } else {
        foreach ($p in @($channels.PSObject.Properties)) {
          $chSlot = $p.Value
          if ($chSlot -and [bool](Get-AuditorObjectProperty -Object $chSlot -Name 'doctor_active')) { $anyDoctorActiveNow = $true; break }
        }
      }
    } catch {
      Write-AuditorLog ("doctor recidivism active-check error: {0}" -f $_.Exception.Message)
    }
    if ($anyDoctorActiveNow) {
      [void]$items.Add((New-AuditorTrigger -Name 'doctor_recidivism' -Detail ("doctor_activations_24h={0}, max={1}, doctor_currently_active=true" -f [int]$Snapshot.doctor_activations_24h, $recMax)))
    }
  }
  return @($items.ToArray())
}

function Get-AuditorMemoryBlock {
  param([object[]]$Triggers)
  try {
    if (-not (Get-Command Search-Memory -ErrorAction SilentlyContinue)) { return '' }
    $q = (@($Triggers) | ForEach-Object { "$($_.name) $($_.detail)" }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($q)) { $q = 'Auditor verdict bridge failure recovery' }
    $channel = 'main'
    try { if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { $channel = [string](Get-EffectiveChannel) } } catch {}
    $hits = @(Search-Memory -Query $q -RequireTag 'auditor-verdict' -TopK 3 -MinScore 0.2 -Channel $channel)
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
      $channel = $null
      try {
        if (Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue) { $channel = [string](Get-EffectiveScope).slug }
      } catch { $channel = $null }
      if ([string]::IsNullOrWhiteSpace($channel)) {
        try { $channel = [string](Get-CurrentMemoryChannel) } catch { $channel = $null }
      }
      Add-Memory -Text $text -Tags @('auditor-verdict') -Source ('auditor:' + $Class) -Importance 0.65 -Channel $channel | Out-Null
    }
  } catch {}
}

function Get-AuditorObjectProperty {
  param($Object, [string]$Name)
  if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
  try {
    if ($Object -is [System.Collections.IDictionary]) {
      if ($Object.Contains($Name)) { return $Object[$Name] }
      return $null
    }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
  } catch {}
  return $null
}

function Set-AuditorObjectProperty {
  param($Object, [string]$Name, $Value)
  if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) { return }
  try {
    if ($Object -is [System.Collections.IDictionary]) {
      $Object[$Name] = $Value
    } elseif ($Object.PSObject.Properties.Name -contains $Name) {
      $Object.$Name = $Value
    } else {
      $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
  } catch {}
}

function Get-AuditorHashPrefix {
  param([string]$Text, [int]$Length = 12)
  if ($Length -lt 1) { $Length = 12 }
  $md5 = [System.Security.Cryptography.MD5]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
    $hash = $md5.ComputeHash($bytes)
    $hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
    if ($Length -gt $hex.Length) { $Length = $hex.Length }
    return $hex.Substring(0, $Length)
  } finally {
    $md5.Dispose()
  }
}

function Get-AuditorSuppressionFilePath {
  Join-Path (Get-BridgeRoot) 'control\auditor.suppressed.json'
}

function Test-AuditorUnsolvableSuppressed {
  param([string]$Hash)
  if ([string]::IsNullOrWhiteSpace($Hash)) { return $false }
  $path = Get-AuditorSuppressionFilePath
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  try {
    $obj = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $arr = @($obj.hashes) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    return ($arr -contains $Hash)
  } catch {
    Write-AuditorLog ("suppression read error: {0}" -f $_.Exception.Message)
    return $false
  }
}

function Save-AuditorUnsolvableSuppressionFile {
  param([string]$Hash, [int]$Max = 100)
  if ([string]::IsNullOrWhiteSpace($Hash)) { return }
  if ($Max -lt 1) { $Max = 100 }
  $path = Get-AuditorSuppressionFilePath
  $arr = @()
  try {
    if (Test-Path -LiteralPath $path) {
      $obj = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      $arr = @($obj.hashes) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    }
  } catch {
    Write-AuditorLog ("suppression load error: {0}" -f $_.Exception.Message)
    $arr = @()
  }
  if ($arr -notcontains $Hash) { $arr = @($arr) + @($Hash) }
  if ($arr.Count -gt $Max) {
    $start = [Math]::Max(0, $arr.Count - $Max)
    $arr = @($arr[$start..($arr.Count - 1)])
  }
  $newObj = [ordered]@{ updated = (Get-Date).ToString('o'); hashes = @($arr) }
  try {
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($path, ($newObj | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
  } catch {
    Write-AuditorLog ("suppression write error: {0}" -f $_.Exception.Message)
  }
}

function Get-AuditorReasonHash {
  param([string]$TaskKey, [string]$TriggerName, [string]$Detail)
  $norm = ([string]$Detail).ToLowerInvariant()
  $norm = [regex]::Replace($norm, '\s+', ' ').Trim()
  $norm = [regex]::Replace($norm, '\d+', '#')
  $raw = "{0}|{1}|{2}" -f $TaskKey, $TriggerName, $norm
  return (Get-AuditorHashPrefix -Text $raw -Length 12)
}

function Test-AuditorSuppressed {
  param($State, [string]$Hash)
  if (-not $State -or [string]::IsNullOrWhiteSpace($Hash)) { return $false }
  $node = Get-AuditorObjectProperty -Object $State -Name 'auditor'
  if (-not $node) { return $false }
  $arr = @(Get-AuditorObjectProperty -Object $node -Name 'suppressed_hashes') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
  return ($arr -contains $Hash)
}

function Add-AuditorSuppressedHash {
  param($State, [string]$Hash, [int]$Max = 50)
  if (-not $State -or [string]::IsNullOrWhiteSpace($Hash)) { return }
  if ($Max -lt 1) { $Max = 50 }
  $node = Get-AuditorObjectProperty -Object $State -Name 'auditor'
  if (-not $node) {
    $node = [ordered]@{ suppressed_hashes = @() }
    Set-AuditorObjectProperty -Object $State -Name 'auditor' -Value $node
  }
  $arr = @(Get-AuditorObjectProperty -Object $node -Name 'suppressed_hashes') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
  $arr = @($arr) + @($Hash)
  if ($arr.Count -gt $Max) {
    $start = [Math]::Max(0, $arr.Count - $Max)
    $arr = @($arr[$start..($arr.Count - 1)])
  }
  Set-AuditorObjectProperty -Object $node -Name 'suppressed_hashes' -Value @($arr)
}

function Get-AuditorSnapshotChannel {
  param($Snapshot, [string]$Channel)
  if (-not $Snapshot -or [string]::IsNullOrWhiteSpace($Channel)) { return $null }
  try {
    $channels = Get-AuditorObjectProperty -Object $Snapshot -Name 'channels'
    if ($channels -is [System.Collections.IDictionary]) {
      if ($channels.Contains($Channel)) { return $channels[$Channel] }
      return $null
    }
    return (Get-AuditorObjectProperty -Object $channels -Name $Channel)
  } catch { return $null }
}

function Get-AuditorTaskKey {
  param($State, $Snapshot = $null, [string]$Channel = 'main')
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }
  $snapChannel = Get-AuditorSnapshotChannel -Snapshot $Snapshot -Channel $Channel

  $taskId = [string](Get-AuditorObjectProperty -Object $State -Name 'task_id')
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = [string](Get-AuditorObjectProperty -Object $snapChannel -Name 'task_id') }
  if (-not [string]::IsNullOrWhiteSpace($taskId)) { return ("task_id:{0}" -f $taskId) }

  $seq = 0
  try { $seq = [int](Get-AuditorObjectProperty -Object $State -Name 'task_start_seq') } catch { $seq = 0 }
  if ($seq -le 0) {
    try { $seq = [int](Get-AuditorObjectProperty -Object $snapChannel -Name 'task_start_seq') } catch { $seq = 0 }
  }
  if ($seq -gt 0) { return ("seq:{0}:{1}" -f $Channel, $seq) }

  $task = [string](Get-AuditorObjectProperty -Object $State -Name 'current_task')
  if ([string]::IsNullOrWhiteSpace($task)) { $task = [string](Get-AuditorObjectProperty -Object $snapChannel -Name 'current_task_short') }
  if (-not [string]::IsNullOrWhiteSpace($task)) { return ("task:{0}:{1}" -f $Channel, (Get-AuditorHashPrefix -Text $task -Length 8)) }

  return ("unknown:{0}" -f $Channel)
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

function Get-AuditorStateForChannel {
  param([string]$Channel)
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }
  $script:AuditorTargetState = $null
  try {
    Invoke-AuditorInChannel -Slug $Channel -Body { $script:AuditorTargetState = Read-State }
    return $script:AuditorTargetState
  } catch {
    try { return (Read-State) } catch { return $null }
  }
}

function Save-AuditorSuppressedHash {
  param([string]$Channel, [string]$Hash)
  if ([string]::IsNullOrWhiteSpace($Hash)) { return }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }
  $body = {
    Update-State ({ param($s) Add-AuditorSuppressedHash -State $s -Hash $Hash -Max 50 }.GetNewClosure()) | Out-Null
  }.GetNewClosure()
  try {
    Invoke-AuditorInChannel -Slug $Channel -Body $body
  } catch {
    try { Update-State ({ param($s) Add-AuditorSuppressedHash -State $s -Hash $Hash -Max 50 }.GetNewClosure()) | Out-Null } catch {}
  }
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

  $primaryDetail = [string]$primary.detail
  $targetState = Get-AuditorStateForChannel -Channel $targetChannel
  $taskKey = Get-AuditorTaskKey -State $targetState -Snapshot $Snapshot -Channel $targetChannel
  $reasonHash = Get-AuditorReasonHash -TaskKey $taskKey -TriggerName $primaryName -Detail $primaryDetail
  if (Test-AuditorSuppressed -State $targetState -Hash $reasonHash) {
    Write-AuditorLog ("auditor:suppressed task_key={0} trigger={1} hash={2} detail={3}" -f $taskKey, $primaryName, $reasonHash, $primaryDetail)
    return [pscustomobject]@{ class=$class; action='suppressed'; reason=$reason; task_key=$taskKey; trigger=$primaryName; hash=$reasonHash; channel=$targetChannel }
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
      if ($activated -and -not $DryRun) { Save-AuditorSuppressedHash -Channel $targetChannel -Hash $reasonHash }
      return [pscustomobject]@{ class='hung'; action='Activate-Doctor'; activated=$activated; reason=$doctorReason; detail=$reason; channel=$targetChannel }
    }
  }

  if ($class -eq 'corrupted_state') {
    $msg = "⚠ Auditor: corrupted_state -- $reason"
    Add-AuditorMainMessage -Text $msg
    Write-AuditorLog ("corrupted_state: {0}" -f $reason)
    Add-AuditorVerdictMemory -Class $class -Reason $reason
    if (-not $DryRun) { Save-AuditorSuppressedHash -Channel $targetChannel -Hash $reasonHash }
    return [pscustomobject]@{ class=$class; action='notify'; reason=$reason }
  }

  if ($class -eq 'unsolvable') {
    if (Test-AuditorUnsolvableSuppressed -Hash $reasonHash) {
      Write-AuditorLog ("auditor:suppressed(unsolvable) hash={0}" -f $reasonHash)
      return [pscustomobject]@{ class=$class; action='suppressed'; reason=$reason; hash=$reasonHash }
    }
    $msg = "⚠ Auditor: unsolvable -- $reason"
    Add-AuditorMainMessage -Text $msg
    Write-AuditorLog ("unsolvable: pause requested but not written by Auditor; {0}" -f $reason)
    Add-AuditorVerdictMemory -Class $class -Reason $reason
    if (-not $DryRun) {
      Save-AuditorUnsolvableSuppressionFile -Hash $reasonHash
      Save-AuditorSuppressedHash -Channel $targetChannel -Hash $reasonHash
    }
    return [pscustomobject]@{ class=$class; action='notify_pause_requested'; reason=$reason }
  }

  Write-AuditorLog ("ok: {0}" -f $reason)
  return [pscustomobject]@{ class='transient'; action='none'; reason=$reason }
}

function Should-RunAuditor {
  $lockPath = Join-Path (Get-BridgeRoot) 'control\auditor.lock'
  if (Test-Path -LiteralPath $lockPath) {
    try {
      $lockAge = ((Get-Date) - (Get-Item -LiteralPath $lockPath -ErrorAction Stop).LastWriteTime).TotalMinutes
      if ($lockAge -lt 5) { return $false }
    } catch {
      Write-AuditorLog ("lock stat error: {0}" -f $_.Exception.Message)
    }
  }

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

function New-AuditorLockToken {
  [guid]::NewGuid().ToString('n')
}

function Try-EnterAuditorLock {
  param([string]$Token, [int]$StaleMinutes = 5)
  $path = Join-Path (Get-BridgeRoot) 'control\auditor.lock'
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if (Test-Path -LiteralPath $path) {
    try {
      $lockAge = ((Get-Date) - (Get-Item -LiteralPath $path -ErrorAction Stop).LastWriteTime).TotalMinutes
      if ($lockAge -ge $StaleMinutes) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
    } catch {
      Write-AuditorLog ("stale lock cleanup error: {0}" -f $_.Exception.Message)
    }
  }

  $stream = $null
  try {
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    $payload = "{0}`n{1}" -f $Token, (Get-Date).ToString('o')
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $stream.Write($bytes, 0, $bytes.Length)
    return $true
  } catch [System.IO.IOException] {
    return $false
  } catch {
    Write-AuditorLog ("lock acquire error: {0}" -f $_.Exception.Message)
    return $false
  } finally {
    if ($stream) { $stream.Dispose() }
  }
}

function Exit-AuditorLock {
  param([string]$Token)
  $path = Join-Path (Get-BridgeRoot) 'control\auditor.lock'
  if (-not (Test-Path -LiteralPath $path)) { return }
  try {
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $firstLine = ([string]$raw -split "\r?\n", 2)[0]
    if ($firstLine -eq $Token) { Remove-Item -LiteralPath $path -ErrorAction Stop }
  } catch {
    Write-AuditorLog ("lock release error: {0}" -f $_.Exception.Message)
  }
}

function Invoke-Auditor {
  $lockToken = New-AuditorLockToken
  if (-not (Try-EnterAuditorLock -Token $lockToken)) {
    Write-AuditorLog 'auditor:lock busy'
    return [pscustomobject]@{ class='normal'; action='lock_busy' }
  }
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
  } finally {
    Exit-AuditorLock -Token $lockToken
  }
}

function Start-AuditorIfDue {
  # Side-effecting idle-tick hook (like Start-ArchitectIfDue / Start-DeepThinkIfDue):
  # returns NOTHING. It used to `return $true/$false`, but both call sites invoke it
  # bare (driver idle loop + auditor-tick.ps1), so that boolean leaked onto the
  # driver's stdout once per idle tick -- driver.main.out.log filled with True/False.
  # No caller consumes the value; valueless return keeps the success stream clean.
  try {
    if (-not (Should-RunAuditor)) { return }
    Invoke-Auditor | Out-Null
    return
  } catch {
    Write-AuditorLog ("Start-AuditorIfDue error: " + $_.Exception.Message)
    try { Add-Message -From system -Text ("⚠ Auditor error: " + $_.Exception.Message) -Kind event | Out-Null } catch {}
    return
  }
}
