function Clear-AuditorSuppressedHashes {
  param($State)
  if (-not $State) { return }
  $node = $null
  try {
    if ($State -is [System.Collections.IDictionary]) {
      if (-not $State.Contains('auditor') -or $null -eq $State['auditor']) {
        $State['auditor'] = [ordered]@{ suppressed_hashes = @() }
        return
      }
      $node = $State['auditor']
    } else {
      if (-not ($State.PSObject.Properties.Name -contains 'auditor') -or $null -eq $State.auditor) {
        $State | Add-Member -NotePropertyName auditor -NotePropertyValue ([ordered]@{ suppressed_hashes = @() }) -Force
        return
      }
      $node = $State.auditor
    }

    if ($node -is [System.Collections.IDictionary]) {
      $node['suppressed_hashes'] = @()
    } else {
      if ($node.PSObject.Properties.Name -contains 'suppressed_hashes') {
        $node.suppressed_hashes = @()
      } else {
        $node | Add-Member -NotePropertyName suppressed_hashes -NotePropertyValue @() -Force
      }
    }
  } catch {}
}

function Get-CheckpointKey {
  param([string]$Kind, [string]$Text)

  $norm = ([string]$Text -replace '\s+', ' ').Trim().ToLowerInvariant()
  if ($norm.Length -gt 200) { $norm = $norm.Substring(0, 200) }
  return (([string]$Kind).ToLowerInvariant() + '|' + $norm)
}

function Add-TaskCheckpoint {
  param(
    [Parameter(Mandatory)][ValidateSet('verified','step_done','file','commit')][string]$Kind,
    [Parameter(Mandatory)][string]$Text
  )

  $cleanText = ([string]$Text -replace '\s+', ' ').Trim()
  if ([string]::IsNullOrWhiteSpace($cleanText)) { return }
  if ($cleanText.Length -gt 240) { $cleanText = $cleanText.Substring(0, 240) + '...' }
  $key = Get-CheckpointKey -Kind $Kind -Text $cleanText
  $ts = (Get-Date).ToString('o')

  Update-State ({
    param($s)
    if (-not ($s.PSObject.Properties.Name -contains 'task_checkpoints')) {
      $s | Add-Member -NotePropertyName task_checkpoints -NotePropertyValue @() -Force
    }
    $cur = @()
    if ($null -ne $s.task_checkpoints) {
      $cur = @($s.task_checkpoints | Where-Object { $null -ne $_ })
    }
    foreach ($cp in $cur) {
      try {
        if ([string]$cp.key -eq $key) { return }
      } catch {}
    }
    $seq = 0
    try { $seq = [int]$s.lastSeq } catch { $seq = 0 }
    $entry = [pscustomobject]@{
      kind = $Kind
      text = $cleanText
      key  = $key
      seq  = $seq
      ts   = $ts
    }
    $arr = @($cur + @($entry))
    if ($arr.Count -gt 5) {
      $arr = @($arr | Select-Object -Last 5)
    }
    $s.task_checkpoints = @($arr)
  }.GetNewClosure()) | Out-Null
}

function Set-TaskLastFailure {
  param(
    [Parameter(Mandatory)][ValidateSet('preflight_blocked','smoke_failed','test_failed','critic_rejected')][string]$Kind,
    [Parameter(Mandatory)][string]$Text
  )

  $cleanText = ([string]$Text -replace '\s+', ' ').Trim()
  if ([string]::IsNullOrWhiteSpace($cleanText)) { return }
  if ($cleanText.Length -gt 300) { $cleanText = $cleanText.Substring(0, 300) + '...' }
  $ts = (Get-Date).ToString('o')
  Update-State ({
    param($s)
    $s | Add-Member -NotePropertyName task_last_failure -NotePropertyValue ([pscustomobject]@{
      kind = $Kind
      text = $cleanText
      ts   = $ts
    }) -Force
  }.GetNewClosure()) | Out-Null
}

function Clear-TaskCheckpoint {
  Update-State {
    param($s)
    $s | Add-Member -NotePropertyName task_checkpoints -NotePropertyValue @() -Force
    $s | Add-Member -NotePropertyName task_last_failure -NotePropertyValue $null -Force
  } | Out-Null
}

function Add-SessionDecisionEvent {
  param(
    [string]$EventType,
    [hashtable]$Meta = @{},
    [string]$Channel = ''
  )
  try {
    if (@('task_start','convergence','verified_commit','doctor_fix','post_mortem') -notcontains $EventType) { return }
    $ch = $Channel
    if ([string]::IsNullOrWhiteSpace($ch)) {
      $s = Read-State -ErrorAction SilentlyContinue
      if ($s -and $s.current_channel) { $ch = [string]$s.current_channel } else { $ch = 'main' }
    }
    $dir = Get-DecisionsPath
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $ledger = Join-Path $dir 'session-ledger.jsonl'
    $entry = [ordered]@{ ts=(Get-Date).ToString('o'); event=$EventType; channel=$ch }
    if ($Meta) {
      foreach ($k in $Meta.Keys) { $entry[$k] = $Meta[$k] }
    }
    $line = $entry | ConvertTo-Json -Compress -Depth 5
    $u8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($ledger, ($line + [Environment]::NewLine), $u8NoBom)
  } catch {}
}

function Get-SessionLedgerBlock {
  param([string]$Channel='main', [int]$LastN=5)
  try {
    if ($LastN -le 0) { return '' }
    $ledger = Join-Path (Get-DecisionsPath) 'session-ledger.jsonl'
    if (-not (Test-Path $ledger)) { return '' }
    $u8NoBom = New-Object System.Text.UTF8Encoding($false)
    $all = [System.IO.File]::ReadAllLines($ledger, $u8NoBom)
    if (-not $all -or $all.Count -eq 0) { return '' }
    $items = @()
    foreach ($rawLine in ($all | Select-Object -Last ([Math]::Max($LastN * 4, 1)))) {
      try {
        $line = ([string]$rawLine).Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.Length -gt 0 -and [int][char]$line[0] -eq 0xFEFF) { $line = $line.Substring(1) }
        $e = $line | ConvertFrom-Json
        if ($e.PSObject.Properties.Name -contains 'channel' -and -not [string]::IsNullOrWhiteSpace([string]$Channel) -and [string]$e.channel -ne [string]$Channel) { continue }
        $taskText = if ($e.PSObject.Properties.Name -contains 'task' -and $null -ne $e.task) { [string]$e.task } else { '' }
        $suffix = if ($taskText.Length -gt 0) { ': ' + $taskText.Substring(0,[Math]::Min(60,$taskText.Length)) } else { '' }
        $tsText = if ($e.PSObject.Properties.Name -contains 'ts' -and $null -ne $e.ts) { [string]$e.ts } else { '' }
        $tsShort = if ($tsText.Length -gt 16) { $tsText.Substring(0,16) } else { $tsText }
        $items += "$($e.event) @ $tsShort$suffix"
      } catch { $items += [string]$line }
    }
    $items = @($items | Select-Object -Last $LastN)
    if (-not $items -or $items.Count -eq 0) { return '' }
    return ($items -join ' | ')
  } catch { return '' }
}

function Save-StateSnapshot {
  param([string]$Reason = 'risky', [string]$Channel = '')
  try {
    $ch = $Channel
    $s = $null
    if (-not [string]::IsNullOrWhiteSpace($ch)) {
      $statePath = Join-Path (Get-BridgeRoot) "channels\$ch\state.json"
      if (Test-Path -LiteralPath $statePath) {
        try { $s = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $s = $null }
      }
    }
    if ($null -eq $s) { $s = Read-State -ErrorAction SilentlyContinue }
    if ($null -eq $s) { return $null }
    if ([string]::IsNullOrWhiteSpace($ch)) {
      if ($s.current_channel) { $ch = [string]$s.current_channel } else { $ch = 'main' }
    }
    $taskId = ''
    if ($s.PSObject.Properties.Name -contains 'task_id') { $taskId = [string]$s.task_id }
    if ([string]::IsNullOrWhiteSpace($taskId) -and $s.PSObject.Properties.Name -contains 'current_backlog_id') { $taskId = [string]$s.current_backlog_id }
    if ([string]::IsNullOrWhiteSpace($taskId) -and $s.PSObject.Properties.Name -contains 'task_start_seq') {
      $seq = [string]$s.task_start_seq
      if (-not [string]::IsNullOrWhiteSpace($seq) -and $seq -ne '0') { $taskId = "seq:${ch}:$seq" }
    }
    if ([string]::IsNullOrWhiteSpace($taskId) -and $s.PSObject.Properties.Name -contains 'current_task') {
      $taskText = [string]$s.current_task
      if (-not [string]::IsNullOrWhiteSpace($taskText)) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
          $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($taskText))
          $taskId = "task:${ch}:" + (-join ($hash | ForEach-Object { $_.ToString('x2') })).Substring(0,12)
        } finally {
          try { $sha.Dispose() } catch {}
        }
      }
    }
    try {
      $s | Add-Member -NotePropertyName 'snapshot_meta' -NotePropertyValue ([ordered]@{
        ts      = (Get-Date).ToString('o')
        reason  = $Reason
        channel = $ch
        task_id = $taskId
      }) -Force
    } catch {}
    $dir = Join-Path (Get-BridgeRoot) "channels\$ch\snapshots"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Dedup: skip if a recent snapshot with the same Reason already exists
    try {
      $dedupMin = 15
      try { $cfg2 = Get-BridgeConfig; if ($cfg2.PSObject.Properties.Name -contains 'snapshotDedupMinutes') { $dedupMin = [int]$cfg2.snapshotDedupMinutes } } catch {}
      $cutoff = (Get-Date).AddMinutes(-[Math]::Max(1, $dedupMin))
      $recent = Get-ChildItem $dir -Filter "state.*.$Reason.json" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
      if ($recent -and $recent.LastWriteTime -ge $cutoff) { return $recent.FullName }
    } catch {}
    $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $snapPath = Join-Path $dir "state.${ts}.${Reason}.json"
    $json = $s | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($snapPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    $all = Get-ChildItem $dir -Filter 'state.*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($all -and $all.Count -gt 10) { $all | Select-Object -Skip 10 | Remove-Item -Force -ErrorAction SilentlyContinue }
    return $snapPath
  } catch { return $null }
}

function Get-LastSnapshot {
  param([string]$Channel = 'main')
  try {
    $dir = Join-Path (Get-BridgeRoot) "channels\$Channel\snapshots"
    if (-not (Test-Path $dir)) { return $null }
    $snap = Get-ChildItem $dir -Filter 'state.*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($snap) { return $snap.FullName } else { return $null }
  } catch { return $null }
}

function Get-TaskCheckpointBlock {
  $st = Read-State
  if ($null -eq $st) { return '' }

  $cps = @()
  if ($st.PSObject.Properties.Name -contains 'task_checkpoints' -and $null -ne $st.task_checkpoints) {
    $cps = @($st.task_checkpoints | Where-Object { $null -ne $_ })
  }
  $lf = $null
  if ($st.PSObject.Properties.Name -contains 'task_last_failure') { $lf = $st.task_last_failure }
  if ($cps.Count -eq 0 -and $null -eq $lf) { return '' }

  $lines = New-Object 'System.Collections.Generic.List[string]'
  if ($cps.Count -gt 0) {
    [void]$lines.Add('=== TASK CHECKPOINTS (последние факты, FIFO-5) ===')
    foreach ($c in $cps) {
      $tag = switch ([string]$c.kind) {
        'verified'  { 'VERIFIED' }
        'step_done' { 'STEP-DONE' }
        'file'      { 'FILE' }
        'commit'    { 'COMMIT' }
        default     { ([string]$c.kind).ToUpperInvariant() }
      }
      [void]$lines.Add(("- [{0}] {1}" -f $tag, [string]$c.text))
    }
  }
  if ($null -ne $lf) {
    if ($lines.Count -gt 0) { [void]$lines.Add('') }
    [void]$lines.Add('=== LAST FAILURE ===')
    [void]$lines.Add(("[{0}] {1}" -f [string]$lf.kind, [string]$lf.text))
  }
  $block = [string]::Join("`n", [string[]]@($lines.ToArray()))
  if ($block.Length -gt 600) { $block = $block.Substring(0, 600) + '...' }
  return $block
}

function Get-CoderRuntimeContextBlock {
  [CmdletBinding()]
  param([string]$RepoRoot = '')

  $bridgeRoot = Get-BridgeRoot
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    try {
      if (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) {
        $RepoRoot = [string](Get-EffectiveProjectRoot)
      }
    } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = $bridgeRoot }
  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add('=== RUNTIME CONTEXT (только чтение, для ориентации) ===')
  [void]$lines.Add("repo: $RepoRoot")

  $st = $null
  try {
    $st = Read-State
    $ch = ''
    try {
      if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { $ch = [string](Get-EffectiveChannel) }
    } catch {}
    if ([string]::IsNullOrWhiteSpace($ch)) { $ch = if ($st.current_channel) { [string]$st.current_channel } else { 'main' } }
    [void]$lines.Add("channel: $ch")
  } catch {
    [void]$lines.Add('channel: n/a')
  }

  try {
    $sha = (& git -C $RepoRoot log -1 --format='%h' 2>$null).Trim()
    $sub = (& git -C $RepoRoot log -1 --format='%s' 2>$null).Trim()
    if ($sha) {
      if ($sub.Length -gt 80) { $sub = $sub.Substring(0, 80) + '…' }
      [void]$lines.Add("last_commit: $sha $sub")
    } else {
      [void]$lines.Add('last_commit: n/a')
    }
  } catch {
    [void]$lines.Add('last_commit: n/a')
  }

  try {
    $dirty = @(& git -C $RepoRoot status --short 2>$null) | Where-Object {
      $_ -and ($_ -notmatch '(secrets\.json|\.env|auth\.json)')
    }
    if ($dirty.Count -eq 0) {
      [void]$lines.Add('dirty: clean')
    } else {
      $first3 = ($dirty | Select-Object -First 3) -join '; '
      $extra = if ($dirty.Count -gt 3) { " (+$($dirty.Count - 3) more)" } else { '' }
      [void]$lines.Add("dirty: $($dirty.Count) files | $first3$extra")
    }
  } catch {
    [void]$lines.Add('dirty: n/a')
  }

  try {
    $lockPath = Join-Path $bridgeRoot 'runtime\codex.lock'
    if (Test-Path $lockPath) {
      $lockInfo = (Get-Content $lockPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue).Trim()
      if ($lockInfo) {
        if ($lockInfo.Length -gt 80) { $lockInfo = $lockInfo.Substring(0, 80) + '…' }
        [void]$lines.Add("agent_lock: HELD | $lockInfo")
      } else {
        [void]$lines.Add('agent_lock: HELD (no owner info)')
      }
    } else {
      [void]$lines.Add('agent_lock: free')
    }
  } catch {
    [void]$lines.Add('agent_lock: n/a')
  }

  try {
    if (Get-Command Get-TaskCheckpointBlock -ErrorAction SilentlyContinue) {
      $cp = Get-TaskCheckpointBlock
      if ($cp) {
        $cpTrim = ($cp -replace '\s+', ' ').Trim()
        if ($cpTrim.Length -gt 120) { $cpTrim = $cpTrim.Substring(0, 120) + '…' }
        [void]$lines.Add("last_checkpoint: $cpTrim")
      } else {
        [void]$lines.Add('last_checkpoint: none')
      }
    } else {
      [void]$lines.Add('last_checkpoint: n/a')
    }
  } catch {
    [void]$lines.Add('last_checkpoint: n/a')
  }

  try {
    if ($st -and $st.task_last_failure) {
      $f = $st.task_last_failure
      $failOne = $null
      if ($f -is [string]) {
        $failOne = $f
      } else {
        foreach ($k in @('reason', 'message', 'type', 'text')) {
          if ($f.PSObject.Properties[$k] -and $f.$k) {
            $failOne = [string]$f.$k
            break
          }
        }
        if (-not $failOne) {
          try { $failOne = ($f | ConvertTo-Json -Compress -Depth 3) } catch { $failOne = '' }
        }
      }
      $failOne = ($failOne -replace '\s+', ' ').Trim()
      if ($failOne.Length -gt 100) { $failOne = $failOne.Substring(0, 100) + '…' }
      if ($failOne) {
        [void]$lines.Add("last_failure: $failOne")
      } else {
        [void]$lines.Add('last_failure: none')
      }
    } else {
      [void]$lines.Add('last_failure: none')
    }
  } catch {
    [void]$lines.Add('last_failure: n/a')
  }

  # current_decisions: last events from session ledger
  try {
    $_ch = if ($st -and $st.current_channel) { [string]$st.current_channel } else { 'main' }
    $_decBlock = Get-SessionLedgerBlock -Channel $_ch -LastN 5
    if (-not [string]::IsNullOrWhiteSpace($_decBlock)) {
      [void]$lines.Add('')
      [void]$lines.Add('## current_decisions')
      [void]$lines.Add($_decBlock)
    }
  } catch {}

  [void]$lines.Add('=== END RUNTIME CONTEXT ===')
  return ($lines -join "`n")
}

function Get-OtherChannelsAgentsImpl {
  # Returns @{channelSlug = 'claude'|'codex'} for channels other than the current one
  # whose state.current_agent points to a live driver process. PID start ticks protect
  # against PID reuse; entries older than the agent timeout are treated as stale.
  $result = @{}
  try {
    $currentChannel = ''
    try { $currentChannel = [string]$Channel } catch {}
    if ([string]::IsNullOrWhiteSpace($currentChannel)) {
      try { $currentChannel = [string](Get-EffectiveChannel) } catch {}
    }

    $channelsRoot = Join-Path (Get-BridgeRoot) 'channels'
    if (-not (Test-Path -LiteralPath $channelsRoot)) { return $result }

    foreach ($dir in @(Get-ChildItem -LiteralPath $channelsRoot -Directory -ErrorAction SilentlyContinue)) {
      $slug = [string]$dir.Name
      if (-not [string]::IsNullOrWhiteSpace($currentChannel) -and $slug -eq $currentChannel) { continue }

      $stateF = Join-Path $dir.FullName 'state.json'
      if (-not (Test-Path -LiteralPath $stateF)) { continue }

      try {
        $st = Get-Content -LiteralPath $stateF -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
        $agent = ([string]$st.current_agent).ToLowerInvariant()
        if ($agent -ne 'claude' -and $agent -ne 'codex') { continue }

        $apid = 0
        try { $apid = [int]$st.current_agent_pid } catch { $apid = 0 }
        $aTicks = [long]0
        try { $aTicks = [long]$st.current_agent_ticks } catch { $aTicks = [long]0 }
        $aSince = $null
        try {
          $sinceRaw = [string]$st.current_agent_since
          if (-not [string]::IsNullOrWhiteSpace($sinceRaw)) { $aSince = [datetime]$sinceRaw }
        } catch { $aSince = $null }

        $live = $false
        if ($apid -gt 0 -and $aTicks -gt 0 -and $aSince) {
          $ageSec = [math]::Max(0, [int](((Get-Date) - $aSince).TotalSeconds))
          if ($ageSec -le 920) {
            $proc = Get-Process -Id $apid -ErrorAction SilentlyContinue
            if ($proc) {
              try {
                if ($proc.StartTime.Ticks -eq $aTicks) { $live = $true }
              } catch {
                $live = $false
              }
            }
          }
        }

        if ($live) { $result[$slug] = $agent }
      } catch {
        continue
      }
    }
  } catch {}
  return $result
}

function Set-CurrentAgentImpl {
  param([string]$Agent)
  # Mark this channel's driver as running the given agent so parallel channel drivers can
  # route around a busy Claude/Codex pair. Cleared in each Invoke-* finally block.
  try {
    if ([string]::IsNullOrWhiteSpace($Agent)) {
      Update-State {
        param($s)
        $s | Add-Member -NotePropertyName current_agent -NotePropertyValue $null -Force
        $s | Add-Member -NotePropertyName current_agent_pid -NotePropertyValue 0 -Force
        $s | Add-Member -NotePropertyName current_agent_ticks -NotePropertyValue 0 -Force
        $s | Add-Member -NotePropertyName current_agent_since -NotePropertyValue $null -Force
      } | Out-Null
      return
    }

    $normAgent = ([string]$Agent).ToLowerInvariant()
    if ($normAgent -ne 'claude' -and $normAgent -ne 'codex') { return }

    $pidValue = [int]$PID
    $ticks = [long]0
    try { $ticks = (Get-Process -Id $pidValue -ErrorAction Stop).StartTime.Ticks } catch { $ticks = [long]0 }
    $nowIso = (Get-Date).ToString('o')
    Update-State ({
      param($s)
      $s | Add-Member -NotePropertyName current_agent -NotePropertyValue $normAgent -Force
      $s | Add-Member -NotePropertyName current_agent_pid -NotePropertyValue $pidValue -Force
      $s | Add-Member -NotePropertyName current_agent_ticks -NotePropertyValue $ticks -Force
      $s | Add-Member -NotePropertyName current_agent_since -NotePropertyValue $nowIso -Force
    }.GetNewClosure()) | Out-Null
  } catch {}
}

function Get-OtherChannelsAgents { Get-OtherChannelsAgentsImpl }
function Set-CurrentAgent {
  param([string]$Agent)
  Set-CurrentAgentImpl -Agent $Agent
}

