# common.ps1 -- shared helpers for the bridge. Dot-source this.
# All state lives in files under the bridge root so it survives reboots.

$ErrorActionPreference = 'Stop'

function Get-BridgeRoot {
  # lib/ is one level under the bridge root
  Split-Path -Parent $PSScriptRoot
}

function Get-BridgeConfig {
  $root = Get-BridgeRoot
  $cfg = Get-Content (Join-Path $root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  return $cfg
}

function Resolve-CodexExe {
  param($cfg)
  # Prefer the real (non-virtualized) MSIX package path -- it is reachable from ANY
  # context, including a bare Task Scheduler process. The AppData\Local\OpenAI path is
  # MSIX-virtualized and only visible inside the package context.
  $cands = @(
    "$env:LOCALAPPDATA\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\OpenAI\Codex\bin\codex.exe",
    $cfg.codexExe,
    "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe"
  )
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
  throw "codex.exe not found (tried: $($cands -join '; '))"
}

function Resolve-ClaudeExe {
  param($cfg)
  $globs = @(
    "$env:LOCALAPPDATA\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\claude-code\*\claude.exe",
    $cfg.claudeGlob,
    "$env:APPDATA\Claude\claude-code\*\claude.exe"
  )
  foreach ($g in $globs) {
    if (-not $g) { continue }
    $hit = Get-ChildItem -Path $g -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($hit) { return $hit.FullName }
  }
  throw "claude.exe not found (tried: $($globs -join '; '))"
}

function Write-AtomicFile {
  # Atomic file replacement that survives OneDrive sync locks.
  #
  # FIX 2026-05-26: Move-Item -Force was throwing IOException "Cannot create a file when that
  # file already exists" sporadically on files inside OneDrive folders, because OneDrive
  # holds a brief read handle during sync that prevents the rename. driver.travel-planner.err.log
  # was filling up with these errors, and individual state.json writes were silently lost.
  # Use [System.IO.File]::Replace for atomic swap (designed for this), with a retry loop for
  # transient lock contention, and a final fallback to copy+delete.
  param([string]$Path, [string]$Content)
  $tmp = "$Path.tmp.$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
  [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
  $tries = 0; $maxTries = 6
  while ($true) {
    try {
      if (Test-Path -LiteralPath $Path) {
        [System.IO.File]::Replace($tmp, $Path, $null)   # atomic, handles OneDrive lock retry internally too
      } else {
        [System.IO.File]::Move($tmp, $Path)
      }
      return
    } catch {
      $tries++
      if ($tries -ge $maxTries) {
        # Fallback: non-atomic copy+delete. Worse than Replace but still gets the bytes there.
        try {
          Copy-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
          Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
          return
        } catch {
          # Clean up tmp on terminal failure so we don't litter
          Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
          throw
        }
      }
      Start-Sleep -Milliseconds (60 * $tries)   # backoff: 60ms, 120ms, 180ms, 240ms, 300ms
    }
  }
}

function Get-StatePath {
  # Phase 3 (full): state.json lives PER channel under channels/<slug>/state.json so each
  # driver can work in parallel without trampling shared state. Falls back to legacy
  # root path during very first bootstrap (before channels.ps1 dot-sourced) or for
  # processes that didn't pin a channel.
  if (Get-Command Get-ChannelStatePath -ErrorAction SilentlyContinue) { return (Get-ChannelStatePath) }
  return (Join-Path (Get-BridgeRoot) 'state.json')
}
function Get-ConversationPath {
  # Channel-aware. Falls back to legacy root path if channels.ps1 hasn't loaded yet (during
  # very first Initialize-Bridge, before dot-source of channels.ps1).
  if (Get-Command Get-ChannelConversationPath -ErrorAction SilentlyContinue) { return (Get-ChannelConversationPath) }
  return (Join-Path (Get-BridgeRoot) 'conversation.jsonl')
}
function Get-FilesPath {
  if (Get-Command Get-ChannelFilesPath -ErrorAction SilentlyContinue) { return (Get-ChannelFilesPath) }
  return (Join-Path (Get-BridgeRoot) 'files')
}
function Get-SummaryPath { Join-Path (Get-BridgeRoot) 'summary.txt' }

function Read-Summary {
  $p = Get-SummaryPath
  if (-not (Test-Path $p)) { return '' }
  $s = Get-Content $p -Raw -Encoding UTF8
  if ($null -eq $s) { return '' }
  return $s
}
function Write-Summary {
  param([string]$Text)
  Write-AtomicFile -Path (Get-SummaryPath) -Content ([string]$Text)
}

function Get-DecisionsPath { Join-Path (Get-BridgeRoot) 'decisions' }

function Save-Decision {
  # Durable, uncompressed record of a conclusion/decision. Returns the file path.
  param([string]$Title, [string]$Content)
  $dir = Get-DecisionsPath
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $slug = ([string]$Title).ToLowerInvariant() -replace '[^\p{L}\p{Nd}]+','-'
  $slug = $slug.Trim('-'); if ($slug.Length -gt 50) { $slug = $slug.Substring(0,50) }
  if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'note' }
  $name = (Get-Date -Format 'yyyy-MM-dd_HHmmss') + '_' + $slug + '.md'
  $path = Join-Path $dir $name
  $body = "# $Title`n`n_Сохранено: $(Get-Date -Format 'yyyy-MM-dd HH:mm')_`n`n" + [string]$Content + "`n"
  Write-AtomicFile -Path $path -Content $body
  return $path
}

function Read-State {
  $p = Get-StatePath
  if (-not (Test-Path $p)) { return $null }
  Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-State {
  param($State)
  $json = $State | ConvertTo-Json -Depth 10
  Write-AtomicFile -Path (Get-StatePath) -Content $json
}

# A named mutex serializes appends + seq increment across the server and driver processes.
function Use-BridgeLock {
  param([scriptblock]$Body)
  $mutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeCodexBridgeLock')
  $got = $false
  try {
    # FIX 2026-05-27: handle AbandonedMutexException. When the previous holder PROCESS died
    # without releasing the mutex, WaitOne THROWS AbandonedMutexException -- but the lock
    # IS acquired by this thread (.NET semantics: the exception is a WARNING that previous
    # state may be corrupt, not a failure). Before this fix, $got stayed $false, the
    # finally block skipped ReleaseMutex, and the mutex remained abandoned for the NEXT
    # caller too -- chain of silent Update-State failures. Observed overnight: Auditor's
    # pause action failed 52 consecutive times exactly via this path, never landing.
    try {
      $got = $mutex.WaitOne(15000)
    } catch [System.Threading.AbandonedMutexException] {
      $got = $true   # we DO own the mutex; release in finally as usual
      try {
        $alog = Join-Path (Get-BridgeRoot) 'control\bridge-lock.log'
        Add-Content -LiteralPath $alog -Value ("{0}  abandoned mutex recovered by PID {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $PID) -Encoding utf8 -ErrorAction SilentlyContinue
      } catch {}
    }
    if (-not $got) { throw 'Could not acquire bridge lock within 15s' }
    & $Body
  } finally {
    if ($got) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
  }
}

function Update-State {
  # Mutate state safely under the shared lock. $Mutator receives the state object and modifies it.
  param([scriptblock]$Mutator)
  Use-BridgeLock {
    $state = Read-State
    if ($null -eq $state) { throw 'state.json missing; run init first' }
    & $Mutator $state
    Write-State -State $state
    return $state
  }
}

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
  param([string]$RepoRoot = 'C:\Users\rafie\OneDrive\Documents\bridge')

  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add('=== RUNTIME CONTEXT (только чтение, для ориентации) ===')
  [void]$lines.Add("repo: $RepoRoot")

  $st = $null
  try {
    $st = Read-State
    $ch = if ($st.current_channel) { [string]$st.current_channel } else { 'main' }
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
    $lockPath = Join-Path $RepoRoot 'runtime\codex.lock'
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

function Get-PreflightBlockers {
  param([string]$Channel = '')

  $hard = New-Object 'System.Collections.Generic.List[string]'
  $soft = New-Object 'System.Collections.Generic.List[string]'
  $root = Get-BridgeRoot

  if ([string]::IsNullOrWhiteSpace($Channel)) {
    try {
      if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { $Channel = [string](Get-EffectiveChannel) }
    } catch {
      [void]$soft.Add("не удалось определить текущий канал: $($_.Exception.Message)")
    }
  }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }

  $channelState = $null
  try {
    if (Get-Command Get-ChannelStatePath -ErrorAction SilentlyContinue) {
      $statePath = Get-ChannelStatePath -Slug $Channel
      if (Test-Path -LiteralPath $statePath) {
        $channelState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
      }
    }
    if ($null -eq $channelState) { $channelState = Read-State }
  } catch {
    [void]$soft.Add("не удалось прочитать state канала '$Channel': $($_.Exception.Message)")
  }

  # Codex MSIX supports one exec session per machine. Treat only a live, verified lock as hard.
  $lockPath = Join-Path $root 'runtime\codex.lock'
  if (Test-Path -LiteralPath $lockPath) {
    try {
      $raw = ([string](Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 -ErrorAction Stop)).Trim()
      $parts = @($raw -split '\|')
      $lockPid = 0
      $lockTicks = [long]0
      if ($parts.Count -ge 1) { [int]::TryParse($parts[0], [ref]$lockPid) | Out-Null }
      if ($parts.Count -ge 2) { [long]::TryParse($parts[1], [ref]$lockTicks) | Out-Null }

      if ($lockPid -gt 0) {
        $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
        if ($proc) {
          $sameProcess = $true
          if ($lockTicks -gt 0) {
            try {
              $sameProcess = ($proc.StartTime.Ticks -eq $lockTicks)
            } catch {
              $sameProcess = $false
              [void]$soft.Add("codex.lock PID $lockPid найден, но start-time не проверен: $($_.Exception.Message)")
            }
          }
          if ($sameProcess) {
            $lockAgeSec = 0
            try { $lockAgeSec = [math]::Max(0, [int](((Get-Date) - (Get-Item -LiteralPath $lockPath).LastWriteTime).TotalSeconds)) } catch { $lockAgeSec = 0 }
            if ($lockAgeSec -le 920) {
              $sameChannelActiveCodex = $false
              try {
                if ($channelState -and ([string]$channelState.current_agent).ToLowerInvariant() -eq 'codex' -and [int]$channelState.current_agent_pid -eq $lockPid) {
                  $sameChannelActiveCodex = $true
                }
              } catch {
                [void]$soft.Add("не удалось сверить codex.lock с current_agent канала '$Channel': $($_.Exception.Message)")
              }
              if (-not $sameChannelActiveCodex) {
                [void]$hard.Add("codex.lock активен (PID $lockPid) - другая coder-сессия в работе")
              }
            } else {
              [void]$soft.Add("codex.lock выглядит устаревшим (PID $lockPid, age ${lockAgeSec}s)")
            }
          } else {
            [void]$soft.Add("codex.lock выглядит устаревшим (PID $lockPid не совпал по start-time)")
          }
        } else {
          [void]$soft.Add("codex.lock выглядит устаревшим (PID $lockPid не найден)")
        }
      } elseif (-not [string]::IsNullOrWhiteSpace($raw)) {
        [void]$soft.Add("codex.lock имеет неожиданный формат")
      }
    } catch {
      [void]$soft.Add("не удалось проверить codex.lock: $($_.Exception.Message)")
    }
  }

  try {
    $st = $channelState
    if ($st -and [bool]$st.doctor_active) {
      $curTask = [string]$st.current_task
      $isDoctorTask = ($curTask -match '^\s*🩺\s*ДОКТОР' -or $curTask -match 'ДОКТОР\s+.\s+задача саморемонта моста')
      if (-not $isDoctorTask) {
        [void]$hard.Add("Doctor активен на канале '$Channel'")
      }
    }
  } catch {
    [void]$soft.Add("не удалось проверить Doctor на канале '$Channel': $($_.Exception.Message)")
  }

  $gitDir = Join-Path $root '.git'
  try {
    $gitDirRaw = @(& git -C $root rev-parse --git-dir 2>$null | Select-Object -First 1)
    if ($gitDirRaw -and -not [string]::IsNullOrWhiteSpace([string]$gitDirRaw[0])) {
      $gd = [string]$gitDirRaw[0]
      if ([System.IO.Path]::IsPathRooted($gd)) { $gitDir = $gd } else { $gitDir = Join-Path $root $gd }
    }
  } catch {
    [void]$soft.Add("не удалось определить .git каталог: $($_.Exception.Message)")
  }

  foreach ($m in @('MERGE_HEAD','CHERRY_PICK_HEAD','REBASE_HEAD','index.lock')) {
    if (Test-Path -LiteralPath (Join-Path $gitDir $m)) { [void]$hard.Add("git mid-op: .git/$m") }
  }
  foreach ($d in @('rebase-merge','rebase-apply')) {
    if (Test-Path -LiteralPath (Join-Path $gitDir $d) -PathType Container) { [void]$hard.Add("git mid-op: .git/$d/") }
  }

  try {
    $dirty = @(& git -C $root status --porcelain 2>$null)
    $dirtyCount = @($dirty | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
    if ($dirtyCount -gt 0) { [void]$soft.Add("worktree dirty: $dirtyCount изменённых/untracked файлов") }
  } catch {
    [void]$soft.Add("не удалось проверить git status: $($_.Exception.Message)")
  }

  return [pscustomobject]@{
    Hard = @($hard.ToArray())
    Soft = @($soft.ToArray())
  }
}

function Is-TestChannel {
  param([Parameter(Mandatory)][string]$Name)
  if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
  if ($Name -match '[\\/]') { return $false }
  return ($Name -match '^(smoke|test)[-_]')
}

function Get-TestChannelDriverProcessIds {
  param([Parameter(Mandatory)][string]$Name)

  $ids = New-Object 'System.Collections.Generic.List[int]'
  if (-not (Is-TestChannel -Name $Name)) { return @() }
  $pattern = "(?i)(^|\s)-Channel\s+[`"']?" + [regex]::Escape($Name) + "[`"']?(\s|$)"
  try {
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
      $cmd = [string]$p.CommandLine
      if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
      if ($cmd -notmatch '\\driver\.ps1\b') { continue }
      if ($cmd -match $pattern) { [void]$ids.Add([int]$p.ProcessId) }
    }
  } catch {}
  return @($ids.ToArray())
}

function Set-TestChannelArchivedFlag {
  param([Parameter(Mandatory)][string]$Name)

  if (-not (Is-TestChannel -Name $Name)) { return $false }
  $cfgPath = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Name) 'channel.json'
  try {
    if (Test-Path -LiteralPath $cfgPath) {
      $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
      $cfg = [pscustomobject]@{ slug=$Name; name=$Name }
    }
    $cfg | Add-Member -NotePropertyName archived -NotePropertyValue $true -Force
    $cfg | Add-Member -NotePropertyName archived_at -NotePropertyValue ((Get-Date).ToString('o')) -Force
    [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    return $true
  } catch {
    return $false
  }
}

function Archive-TestChannelIfIdle {
  param(
    [Parameter(Mandatory)][string]$Name,
    [int]$GraceMinutes = 10
  )

  if (-not (Is-TestChannel -Name $Name)) { return $null }
  if ($Name -ne [System.IO.Path]::GetFileName($Name)) { return $null }
  if ($GraceMinutes -lt 0) { $GraceMinutes = 0 }

  $root = Get-BridgeRoot
  $chRoot = Join-Path $root 'channels'
  $chDir = Join-Path $chRoot $Name
  if (-not (Test-Path -LiteralPath $chDir -PathType Container)) { return $null }

  $current = ''
  try {
    if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { $current = [string](Get-EffectiveChannel) }
  } catch {}
  if (-not [string]::IsNullOrWhiteSpace($current) -and $current -eq $Name) { return $null }
  try {
    $active = [string](Get-ActiveChannel)
    if (-not [string]::IsNullOrWhiteSpace($active) -and $active -eq $Name) { return $null }
  } catch {}

  $locks = @(Get-ChildItem -LiteralPath $chDir -Filter '*.lock' -File -ErrorAction SilentlyContinue)
  if ($locks.Count -gt 0) { return $null }

  $statePath = Join-Path $chDir 'state.json'
  if (Test-Path -LiteralPath $statePath) {
    try {
      $st = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
      $status = ([string]$st.status).ToLowerInvariant()
      if (-not [string]::IsNullOrWhiteSpace($status) -and $status -notin @('idle','done')) { return $null }
      if (-not [string]::IsNullOrWhiteSpace([string]$st.current_task)) { return $null }
      if (-not [string]::IsNullOrWhiteSpace([string]$st.active_agent)) { return $null }
      if (-not [string]::IsNullOrWhiteSpace([string]$st.current_agent)) { return $null }
      if ([bool]$st.doctor_active) { return $null }
      if ($st.active_jobs -and @($st.active_jobs).Count -gt 0) { return $null }
      if ($st.PSObject.Properties.Name -contains 'task_id') {
        if (-not [string]::IsNullOrWhiteSpace([string]$st.task_id) -and -not [bool]$st.task_archived) { return $null }
      }
    } catch {
      return [pscustomobject]@{ Name=$Name; Archived=$null; Error=("state read failed: " + $_.Exception.Message) }
    }
  }

  $lastTouch = (Get-Date).AddYears(-1)
  $sawActivityFile = $false
  foreach ($f in @('conversation.jsonl','turns.jsonl','channel.json','plan.jsonl','backlog.jsonl')) {
    $fp = Join-Path $chDir $f
    if (Test-Path -LiteralPath $fp) {
      $mt = (Get-Item -LiteralPath $fp).LastWriteTime
      $sawActivityFile = $true
      if ($mt -gt $lastTouch) { $lastTouch = $mt }
    }
  }
  if (-not $sawActivityFile) { $lastTouch = (Get-Item -LiteralPath $chDir).LastWriteTime }
  $ageMin = ((Get-Date) - $lastTouch).TotalMinutes
  if ($ageMin -lt $GraceMinutes) { return $null }

  $driverPids = @(Get-TestChannelDriverProcessIds -Name $Name)
  if ($driverPids.Count -gt 0) {
    if (Set-TestChannelArchivedFlag -Name $Name) {
      return [pscustomobject]@{ Name=$Name; Archived=$null; PendingStop=$true; DriverPids=$driverPids; AgeMinutes=[int]$ageMin }
    }
    return [pscustomobject]@{ Name=$Name; Archived=$null; Error='failed to mark channel archived before driver stop' }
  }

  $archRoot = Join-Path $chRoot '_archive'
  if (-not (Test-Path -LiteralPath $archRoot)) { New-Item -ItemType Directory -Path $archRoot -Force | Out-Null }
  $stamp = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
  $dest = Join-Path $archRoot ($stamp + '_' + $Name)
  $n = 1
  while (Test-Path -LiteralPath $dest) {
    $dest = Join-Path $archRoot ($stamp + '_' + $Name + '_' + $n)
    $n++
  }

  try {
    Move-Item -LiteralPath $chDir -Destination $dest -ErrorAction Stop
    return [pscustomobject]@{ Name=$Name; Archived=$dest; AgeMinutes=[int]$ageMin }
  } catch {
    return [pscustomobject]@{ Name=$Name; Archived=$null; Error=$_.Exception.Message }
  }
}

function Invoke-TestChannelCleanup {
  param([int]$GraceMinutes = 10)

  $root = Get-BridgeRoot
  $chRoot = Join-Path $root 'channels'
  if (-not (Test-Path -LiteralPath $chRoot -PathType Container)) { return @() }

  $results = New-Object 'System.Collections.Generic.List[object]'
  foreach ($ch in @(Get-ChildItem -LiteralPath $chRoot -Directory -ErrorAction SilentlyContinue)) {
    if ($ch.Name -eq '_archive') { continue }
    if (-not (Is-TestChannel -Name $ch.Name)) { continue }
    $r = Archive-TestChannelIfIdle -Name $ch.Name -GraceMinutes $GraceMinutes
    if ($r -and ($r.Archived -or $r.PendingStop)) {
      try {
        if ($r.PendingStop) {
          Add-Message -From system -Kind event -Text ("test_channel_archive_pending: " + $r.Name + " marked archived; waiting for driver stop (pid " + ((@($r.DriverPids) | ForEach-Object { [string]$_ }) -join ',') + ", age " + $r.AgeMinutes + " min)") | Out-Null
        } else {
          Add-Message -From system -Kind event -Text ("test_channel_archived: " + $r.Name + " -> " + $r.Archived + " (age " + $r.AgeMinutes + " min)") | Out-Null
        }
      } catch {}
      [void]$results.Add($r)
    }
  }
  return @($results.ToArray())
}

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
    Add-Content -LiteralPath (Get-ConversationPath) -Value $line -Encoding UTF8
    $state.lastSeq = $seq
    Write-State -State $state
    return $seq
  }
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
    }
    Write-State -State $state
  } else {
    # migrate older state.json: add any fields introduced later
    $defaults = @{
      status='idle'; paused=$false; stop=$false; abort=$false
      active_agent=$null; active_model=$null; status_text=$null; agent_pid=$null
      current_task=$null; task_turn=0; task_mode='normal'; discuss_turn=0; discuss_snapshot=''; study_phase=''; study_subtype=''; study_snapshot=''; research_count=0; task_start_seq=0
      no_progress_count=0; timeout_retry_count=0; task_did_actions=$false; verify_retry_count=0; force_planner=$false
      last_user_seq=0; summarized_seq=0; turn=0; lastSeq=0
      heartbeat=$null; driver_started=$null; claimed_at=$null
      current_backlog_id=$null
      autonomous_day=$null; autonomous_count=0
      active_jobs=@(); task_base_commit=''; critic_retry_count=0
      current_agent=$null; current_agent_pid=0; current_agent_ticks=0; current_agent_since=$null
      coder_fired=$false; coder_bypass_retry_count=0
      held_task=$null; doctor_active=$false; doctor_attempts=0; doctor_reason=''; doctor_started_at=$null
      auditor=@{ suppressed_hashes=@() }
      task_checkpoints=@(); task_last_failure=$null
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
  return (Read-State)
}

# Long-term vector memory (Gemini embeddings + Flash librarian). Best-effort: if this
# layer fails to load or Gemini is unreachable, the engine keeps running unchanged.
try { . (Join-Path $PSScriptRoot 'memory.ps1') } catch { Write-Warning "memory.ps1 failed to load: $($_.Exception.Message)" }
# Per-project semantic code memory, stored separately from ordinary long-term memory.
try { . (Join-Path $PSScriptRoot 'codemem.ps1') } catch { Write-Warning "codemem.ps1 failed to load: $($_.Exception.Message)" }
# LLM router (DeepSeek/Gemini for cheap background thinking) -- load AFTER memory.ps1.
try { . (Join-Path $PSScriptRoot 'llm.ps1') } catch { Write-Warning "llm.ps1 failed to load: $($_.Exception.Message)" }
# Usage accounting (prepaid agent turns + paid API calls). Best-effort and non-fatal.
try { . (Join-Path $PSScriptRoot 'usage.ps1') } catch { Write-Warning "usage.ps1 failed to load: $($_.Exception.Message)" }
# Planner model router layered on top of Get-PlannerModel; learns from turns.jsonl outcomes.
try { . (Join-Path $PSScriptRoot 'router.ps1') } catch { Write-Warning "router.ps1 failed to load: $($_.Exception.Message)" }
# Self-improvement backlog (ideas the agents raise themselves).
try { . (Join-Path $PSScriptRoot 'backlog.ps1') } catch { Write-Warning "backlog.ps1 failed to load: $($_.Exception.Message)" }
# User-tunable settings (gitignored overrides: idle-quiet, autonomy scope, etc.).
try { . (Join-Path $PSScriptRoot 'settings.ps1') } catch { Write-Warning "settings.ps1 failed to load: $($_.Exception.Message)" }
# Background job manager (long-running commands -- e.g. hour-long project runs).
try { . (Join-Path $PSScriptRoot 'jobs.ps1') } catch { Write-Warning "jobs.ps1 failed to load: $($_.Exception.Message)" }
# Worktree isolation primitives (foundation for parallel workers + sandbox).
try { . (Join-Path $PSScriptRoot 'worktrees.ps1') } catch { Write-Warning "worktrees.ps1 failed to load: $($_.Exception.Message)" }
# Parallel worker orchestration (run sub-tasks concurrently in worktrees, merge back).
try { . (Join-Path $PSScriptRoot 'parallel.ps1') } catch { Write-Warning "parallel.ps1 failed to load: $($_.Exception.Message)" }
try { . (Join-Path $PSScriptRoot 'doctor.ps1') } catch { Write-Warning "doctor.ps1 failed to load: $($_.Exception.Message)" }
try { . (Join-Path $PSScriptRoot 'architect.ps1') } catch { Write-Warning "architect.ps1 failed to load: $($_.Exception.Message)" }
try { . (Join-Path $PSScriptRoot 'channels.ps1') } catch { Write-Warning "channels.ps1 failed to load: $($_.Exception.Message)" }
# Run channel migration once — moves legacy bridge-root files into channels/main/ if needed.
# Idempotent; safe to call on every Initialize-Bridge.
try { Initialize-Channels } catch { Write-Warning "Initialize-Channels failed: $($_.Exception.Message)" }
# Telegram push notifications (best-effort, non-fatal).
try { . (Join-Path $PSScriptRoot 'notify.ps1') } catch { Write-Warning "notify.ps1 failed to load: $($_.Exception.Message)" }
# Study-mode detection (single source of truth; bounded command-verb gate).
try { . (Join-Path $PSScriptRoot 'study.ps1') } catch { Write-Warning "study.ps1 failed to load: $($_.Exception.Message)" }
