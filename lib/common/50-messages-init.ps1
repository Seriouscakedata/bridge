function Add-Message {
  param(
    [ValidateSet('claude','codex','user','system')] [string]$From,
    [string]$Text,
    [string]$Kind = 'message',
    [object[]]$Attachments = @(),
    [string]$Model = ''
  )
  Use-BridgeLock {
    $state = Read-State
    if ($null -eq $state) { throw 'state.json missing; run init first' }
    $seq = [int]$state.lastSeq + 1
    # 2026-05-30: dedup identical system events. A recycle mid-task replays a step
    # (claim / compaction), so the SAME "Беру задачу" / "История свёрнута" event
    # gets posted twice. Skip if the previous message is an identical system event
    # from the last 3 minutes. Only applies to system events (user/agent repeats
    # can be legitimate).
    if ($From -eq 'system') {
      try {
        $cpDedup = Get-ConversationPath
        $lastLn = Get-Content -LiteralPath $cpDedup -Tail 1 -ErrorAction SilentlyContinue
        if ($lastLn) {
          $lm = $lastLn | ConvertFrom-Json
          if ((([string]$lm.from) -eq 'system') -and (([string]$lm.text) -eq ([string]$Text))) {
            $ageSec = ((Get-Date).ToUniversalTime() - ([datetimeoffset]$lm.ts).UtcDateTime).TotalSeconds
            if ($ageSec -lt 180) { return }
          }
        }
      } catch {}
    }
    $msg = [ordered]@{
      seq  = $seq
      ts   = (Get-Date).ToUniversalTime().ToString('o')
      from = $From
      kind = $Kind
      text = $Text
    }
    if (-not [string]::IsNullOrWhiteSpace($Model)) { $msg.model = $Model }
    if ($Attachments -and @($Attachments).Count -gt 0) {
      $msg.attachments = @($Attachments)
    }
    $line = ($msg | ConvertTo-Json -Compress -Depth 10)
    # FIX 2026-05-27: Add-Content fails when another process briefly holds an exclusive write
    # handle on conversation.jsonl (OneDrive sync, parallel driver writes). Retry with backoff
    # because losing a message is far worse than waiting 300ms. After max retries, append via
    # FileStream with FileShare.ReadWrite as last resort.
    $convPath = Get-ConversationPath
    $appended = $false
    $attempts = 0
    while (-not $appended -and $attempts -lt 6) {
      try {
        Add-Content -LiteralPath $convPath -Value $line -Encoding UTF8 -ErrorAction Stop
        $appended = $true
      } catch {
        $attempts++
        Start-Sleep -Milliseconds (50 * $attempts)
      }
    }
    if (-not $appended) {
      # Fallback: use FileStream with FileShare.ReadWrite (more forgiving than Add-Content).
      try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + "`r`n")
        $fs = [System.IO.File]::Open($convPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try { $fs.Write($bytes, 0, $bytes.Length); $appended = $true } finally { $fs.Dispose() }
      } catch {
        # Last resort: write to a sidecar so the line isn't lost; recovery script can merge later.
        try {
          $sidecar = "$convPath.unflushed"
          [System.IO.File]::AppendAllText($sidecar, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        } catch {}
      }
    }
    $state.lastSeq = $seq
    Write-State -State $state
    return $seq
  }
}

function Get-ConversationArchivePath {
  $cp = Get-ConversationPath
  return (Join-Path (Split-Path $cp -Parent) 'conversation.archive.jsonl')
}

function Invoke-ConversationArchive {
  # User-triggered chat cleanup: move all but the last $Keep messages from the live conversation.jsonl
  # into conversation.archive.jsonl. The bridge does NOT read the archive, so it never affects the
  # mind of the agents. lastSeq in state is untouched (seq continuity preserved) and summary.txt is
  # left intact (Format-Transcript still has its compressed history + the kept tail), so the agents
  # keep full context. Runs under the same Use-BridgeLock as Add-Message so a concurrent write can't
  # race. Returns @{ ok; archived; kept }.
  param([int]$Keep = 30)
  if ($Keep -lt 5) { $Keep = 5 }
  return (Use-BridgeLock {
    $convPath = Get-ConversationPath
    if (-not (Test-Path -LiteralPath $convPath)) { return [pscustomobject]@{ ok=$true; archived=0; kept=0 } }
    $lines = @(Get-Content -LiteralPath $convPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -le $Keep) { return [pscustomobject]@{ ok=$true; archived=0; kept=$lines.Count } }
    $cut = $lines.Count - $Keep
    $toArchive = $lines[0..($cut-1)]
    $toKeep    = $lines[$cut..($lines.Count-1)]
    $u8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText((Get-ConversationArchivePath), (($toArchive -join "`n") + "`n"), $u8)
    [System.IO.File]::WriteAllText($convPath, (($toKeep -join "`n") + "`n"), $u8)
    return [pscustomobject]@{ ok=$true; archived=$toArchive.Count; kept=$toKeep.Count }
  })
}

function Invoke-ConversationArchivePrune {
  # Permanently drop archive lines older than $MaxAgeDays. The live conversation + summary are never
  # touched; only the archive sidecar (which the bridge doesn't read) is trimmed. Safe to run weekly.
  # Lines whose ts can't be parsed are KEPT (fail-safe). Returns count removed.
  param([int]$MaxAgeDays = 7)
  $archPath = Get-ConversationArchivePath
  if (-not (Test-Path -LiteralPath $archPath)) { return 0 }
  $cut = (Get-Date).ToUniversalTime().AddDays(-[Math]::Abs($MaxAgeDays))
  $all  = @(Get-Content -LiteralPath $archPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($all.Count -eq 0) { return 0 }
  $keep = @($all | Where-Object {
    $ok = $true
    try { $o = $_ | ConvertFrom-Json; $ts = [datetime]::Parse([string]$o.ts).ToUniversalTime(); $ok = ($ts -ge $cut) } catch { $ok = $true }
    $ok
  })
  $removed = $all.Count - $keep.Count
  if ($removed -gt 0) {
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $body = if ($keep.Count -gt 0) { ($keep -join "`n") + "`n" } else { '' }
    [System.IO.File]::WriteAllText($archPath, $body, $u8)
  }
  return $removed
}

function Get-MimeForExt {
  param([string]$Ext)
  $e = ''
  if ($Ext) { $e = $Ext.Trim().TrimStart('.').ToLowerInvariant() }
  switch ($e) {
    'png'  { return 'image/png' }
    'jpg'  { return 'image/jpeg' }
    'jpeg' { return 'image/jpeg' }
    'gif'  { return 'image/gif' }
    'webp' { return 'image/webp' }
    'svg'  { return 'image/svg+xml' }
    'pdf'  { return 'application/pdf' }
    'txt'  { return 'text/plain; charset=utf-8' }
    'json' { return 'application/json; charset=utf-8' }
    default { return 'application/octet-stream' }
  }
}

function Get-SafeAttachmentName {
  param([string]$Name)
  $leaf = [System.IO.Path]::GetFileName([string]$Name)
  if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'file' }
  $leaf = $leaf -replace '[\x00-\x1F\x7F<>:"/\\|?*]+', '_'
  $leaf = $leaf -replace '\.\.+', '.'
  $leaf = $leaf.Trim(' ', '.')
  if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'file' }

  $ext = [System.IO.Path]::GetExtension($leaf)
  $stem = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
  if ($stem.Length -gt 120) { $stem = $stem.Substring(0, 120) }
  if ($ext.Length -gt 20) { $ext = $ext.Substring(0, 20) }
  return ($stem + $ext)
}

function New-AttachmentMetadata {
  param(
    [string]$Id,
    [string]$Name,
    [string]$StoredName,
    [long]$Size,
    [string]$Caption = ''
  )
  $displayName = [System.IO.Path]::GetFileName([string]$Name)
  if ([string]::IsNullOrWhiteSpace($displayName)) { $displayName = [System.IO.Path]::GetFileName($StoredName) }
  $mime = Get-MimeForExt ([System.IO.Path]::GetExtension($displayName))
  $kind = if ($mime.StartsWith('image/')) { 'image' } else { 'file' }
  $meta = [ordered]@{
    id   = $Id
    name = $displayName
    mime = $mime
    kind = $kind
    url  = '/files/' + [System.Uri]::EscapeDataString($StoredName)
    size = $Size
  }
  if (-not [string]::IsNullOrWhiteSpace($Caption)) { $meta.caption = $Caption }
  return $meta
}

function Save-AttachmentBytes {
  param(
    [byte[]]$Bytes,
    [string]$Name,
    [string]$Caption = ''
  )
  $files = Get-FilesPath
  if (-not (Test-Path $files)) { New-Item -ItemType Directory -Path $files -Force | Out-Null }
  $id = [System.Guid]::NewGuid().ToString('N')
  $safeName = Get-SafeAttachmentName $Name
  $storedName = "$id`__$safeName"
  $target = Join-Path $files $storedName
  [System.IO.File]::WriteAllBytes($target, $Bytes)
  return (New-AttachmentMetadata -Id $id -Name $Name -StoredName $storedName -Size $Bytes.Length -Caption $Caption)
}

function Register-AttachmentPath {
  param([string]$SourcePath)
  if ([string]::IsNullOrWhiteSpace($SourcePath)) { return $null }
  if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { return $null }

  $item = Get-Item -LiteralPath $SourcePath
  $files = Get-FilesPath
  if (-not (Test-Path $files)) { New-Item -ItemType Directory -Path $files -Force | Out-Null }
  $id = [System.Guid]::NewGuid().ToString('N')
  $safeName = Get-SafeAttachmentName $item.Name
  $storedName = "$id`__$safeName"
  $target = Join-Path $files $storedName
  Copy-Item -LiteralPath $item.FullName -Destination $target -Force
  return (New-AttachmentMetadata -Id $id -Name $item.Name -StoredName $storedName -Size $item.Length)
}

function Get-Messages {
  param([int]$Since = 0)
  $p = Get-ConversationPath
  if (-not (Test-Path $p)) { return @() }
  $out = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $m = $line | ConvertFrom-Json } catch { continue }
    if ([int]$m.seq -gt $Since) { [void]$out.Add($m) }
  }
  return @($out.ToArray())
}

function Initialize-Bridge {
  param([switch]$Reset)
  $root = Get-BridgeRoot
  foreach ($d in @('lib','web','sandbox','files','decisions','memory')) {
    $dp = Join-Path $root $d
    if (-not (Test-Path $dp)) { New-Item -ItemType Directory -Path $dp -Force | Out-Null }
  }
  $convo = Get-ConversationPath
  if ($Reset -or -not (Test-Path $convo)) {
    [System.IO.File]::WriteAllText($convo, '', (New-Object System.Text.UTF8Encoding($false)))
  }
  if ($Reset) {
    [System.IO.File]::WriteAllText((Get-SummaryPath), '', (New-Object System.Text.UTF8Encoding($false)))
  }
  $state = Read-State
  if ($Reset -or $null -eq $state) {
    # Phase 3 (full): when creating a fresh per-channel state.json, scan the channel's
    # existing conversation.jsonl and seed lastSeq from the max seq there. Otherwise UI
    # polling with ?since=<oldChannelSeq> would never see new sub-1 messages.
    $initialLastSeq = 0
    try {
      $convoPath = Get-ConversationPath
      if (Test-Path -LiteralPath $convoPath) {
        foreach ($line in (Get-Content -LiteralPath $convoPath -Encoding UTF8)) {
          if ([string]::IsNullOrWhiteSpace($line)) { continue }
          try {
            $obj = $line | ConvertFrom-Json
            $s = [int]$obj.seq
            if ($s -gt $initialLastSeq) { $initialLastSeq = $s }
          } catch {}
        }
      }
    } catch {}
    $state = [ordered]@{
      status         = 'idle'
      paused         = $false
      stop           = $false
      abort          = $false
      active_agent   = $null
      active_model   = $null
      status_text    = $null
      agent_pid      = $null
      current_task   = $null
      current_task_id = $null
      task_turn      = 0
      task_mode      = 'normal'
      discuss_turn     = 0
      discuss_snapshot = ''
      study_phase      = ''
      study_subtype    = ''
      study_snapshot   = ''
      research_count   = 0
      task_start_seq = 0
      no_progress_count = 0
      timeout_retry_count = 0
      task_did_actions   = $false
      verify_retry_count = 0
      force_planner      = $false
      last_user_seq  = 0
      summarized_seq = 0
      turn           = 0
      lastSeq        = $initialLastSeq
      heartbeat      = $null
      driver_started = $null
      claimed_at     = $null
      current_backlog_id = $null
      autonomous_day   = $null
      autonomous_count = 0
      active_jobs      = @()
      task_base_commit = ''
      chunk_progress    = ''
      chunk_base_commit = ''
      force_coder       = $false
      critic_retry_count = 0
      current_agent      = $null
      current_agent_pid  = 0
      current_agent_ticks = 0
      current_agent_since = $null
      coder_fired        = $false
      coder_bypass_retry_count = 0
      held_task          = $null
      doctor_active      = $false
      doctor_attempts    = 0
      doctor_reason      = ''
      doctor_started_at  = $null
      auditor            = @{ suppressed_hashes = @() }
      task_checkpoints   = @()
      task_last_failure  = $null
      agent_telemetry    = $null
      session_mission    = $null
    }
    Write-State -State $state -AllowPartial   # initial create; guard skip OK
  } else {
    # migrate older state.json: add any fields introduced later
    $defaults = @{
      status='idle'; paused=$false; stop=$false; abort=$false
      active_agent=$null; active_model=$null; status_text=$null; agent_pid=$null
      current_task=$null; current_task_id=$null; task_turn=0; task_mode='normal'; discuss_turn=0; discuss_snapshot=''; study_phase=''; study_subtype=''; study_snapshot=''; research_count=0; task_start_seq=0
      no_progress_count=0; timeout_retry_count=0; task_did_actions=$false; verify_retry_count=0; force_planner=$false
      last_user_seq=0; summarized_seq=0; turn=0; lastSeq=0
      heartbeat=$null; driver_started=$null; claimed_at=$null
      current_backlog_id=$null
      autonomous_day=$null; autonomous_count=0
      active_jobs=@(); task_base_commit=''; chunk_progress=''; chunk_base_commit=''; force_coder=$false; critic_retry_count=0
      current_agent=$null; current_agent_pid=0; current_agent_ticks=0; current_agent_since=$null
      coder_fired=$false; coder_bypass_retry_count=0
      held_task=$null; doctor_active=$false; doctor_attempts=0; doctor_reason=''; doctor_started_at=$null
      auditor=@{ suppressed_hashes=@() }
      task_checkpoints=@(); task_last_failure=$null
      agent_telemetry=$null
      session_mission=$null
    }
    $changed = $false
    foreach ($k in $defaults.Keys) {
      if (-not ($state.PSObject.Properties.Name -contains $k)) {
        $state | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] -Force
        $changed = $true
      }
    }
    if ($changed) { Write-State -State $state }
  }
  # Sanity-check: abort dead parallel streams on startup
  if ($state.PSObject.Properties['parallel_streams'] -and $state.parallel_streams.Count -gt 0) {
    $allAborted = $true
    $streamsChanged = $false
    foreach ($stream in $state.parallel_streams) {
      $proc = Get-Process -Id $stream.pid -ErrorAction SilentlyContinue
      $isDead = (-not $proc)
      if (-not $isDead -and $stream.PSObject.Properties['pidTicks'] -and $stream.pidTicks -gt 0) {
        $isDead = ($proc.StartTime.Ticks -ne $stream.pidTicks)
      }
      if ($isDead) {
        if ($stream.status -ne 'aborted') {
          $stream.status = 'aborted'
          $streamsChanged = $true
        }
      } else {
        $allAborted = $false
      }
    }
    if ($allAborted) {
      $state.parallel_streams = @()
      $streamsChanged = $true
    }
    if ($streamsChanged) { Write-State -State $state }
  }
  return (Read-State)
}

function Test-IsUnsafeFastLaneTask {
  # Destructive, irreversible, or outgoing actions must keep the normal safety gates.
  param([string]$TaskText)
  $t = ([string]$TaskText).Trim()
  if ([string]::IsNullOrWhiteSpace($t)) { return $false }
  return [bool]([regex]::IsMatch($t, '(?i)(удал\w*|сотр\w*|очист\w*|формат\w*|перезапиш\w*|перезапуст\w*|закро\w*|убе[йт]\w*|уби\w*|\bdelete\b|\bdel\b|\brm\b|remove-item|\bformat\b|reset\s+--hard|git\s+push|\bpush\b|\bdrop\b|truncate|wipe|\bkill\b|taskkill|заверш\w*|shutdown|restart-computer|выключ\w*\s+комп|перезагруз\w*\s+комп)'))
}

function Test-IsSafeOsFastLaneTask {
  # Reversible/read-only OS/UI commands that can skip the planner ceremony.
  param([string]$TaskText)
  $t = ([string]$TaskText).Trim()
  if ([string]::IsNullOrWhiteSpace($t)) { return $false }
  if (Test-IsUnsafeFastLaneTask -TaskText $t) { return $false }
  if ($t -match '(?i)(аудит|audit)') { return $false }
  if ($t -match '(?i)(обсуд\w*|согласу\w*|проанализ\w*|спроектир\w*|исследу\w*|изучи\w*|реализ\w*|внедр\w*|добав\w*|почин\w*|поправ\w*|обнов\w*|измен\w*|\bdesign\b|\brefactor\b|\bimplement\b|\bfix\b|\bupdate\b|\badd\b)') { return $false }
  return [bool]([regex]::IsMatch($t, '(?i)(скриншот|screenshot|снимок\s+экран|запуст\w*|launch\b|открой\w*|\bopen\b|покаж\w*|\bshow\b|найд\w*|\bfind\b|поищ\w*|список|\blist\b|статус\b|\bstatus\b|\blog\w*|логи?\b)'))
}

if ($null -eq $script:BridgeCapabilities) { $script:BridgeCapabilities = [ordered]@{} }

function Set-BridgeCapability {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][bool]$Ok,
    [string]$Error = '',
    [bool]$Required = $false
  )
  $script:BridgeCapabilities[$Name] = [pscustomobject]@{
    ok       = [bool]$Ok
    required = [bool]$Required
    path     = [string]$Path
    error    = [string]$Error
  }
}

function Get-BridgeCapabilities {
  return $script:BridgeCapabilities
}
