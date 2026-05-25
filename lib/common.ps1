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
  param([string]$Path, [string]$Content)
  $tmp = "$Path.tmp.$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
  [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
  # Move-Item -Force is atomic enough on the same volume
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Get-StatePath { Join-Path (Get-BridgeRoot) 'state.json' }
function Get-ConversationPath { Join-Path (Get-BridgeRoot) 'conversation.jsonl' }
function Get-FilesPath { Join-Path (Get-BridgeRoot) 'files' }
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
    $got = $mutex.WaitOne(15000)
    if (-not $got) { throw 'Could not acquire bridge lock within 15s' }
    & $Body
  } finally {
    if ($got) { $mutex.ReleaseMutex() }
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

function Add-Message {
  param(
    [ValidateSet('claude','codex','user','system')] [string]$From,
    [string]$Text,
    [string]$Kind = 'message',
    [object[]]$Attachments = @()
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
  foreach ($d in @('lib','web','sandbox','files','decisions')) {
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
      discuss_turn   = 0
      research_count = 0
      task_start_seq = 0
      no_progress_count = 0
      timeout_retry_count = 0
      last_user_seq  = 0
      summarized_seq = 0
      turn           = 0
      lastSeq        = 0
      heartbeat      = $null
      driver_started = $null
      claimed_at     = $null
    }
    Write-State -State $state
  } else {
    # migrate older state.json: add any fields introduced later
    $defaults = @{
      status='idle'; paused=$false; stop=$false; abort=$false
      active_agent=$null; active_model=$null; status_text=$null; agent_pid=$null
      current_task=$null; task_turn=0; task_mode='normal'; discuss_turn=0; research_count=0; task_start_seq=0
      no_progress_count=0; timeout_retry_count=0
      last_user_seq=0; summarized_seq=0; turn=0; lastSeq=0
      heartbeat=$null; driver_started=$null; claimed_at=$null
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
