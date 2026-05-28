# channels.ps1 -- multi-chat workspaces.
#
# Each channel is a workspace with its own conversation, plan, backlog, and files. Memory
# stays in a single global store but each record carries a 'channel' tag; recall filters
# by current channel + 'shared'. Per-channel driver processes are introduced in phase 3;
# in phase 1 we keep a single driver with a global state.json (read by watchdog/smoke),
# and only the LIST-style files (conversation, plan, backlog) move per-channel.
#
# Layout:
#   channels/
#   ├── <slug>/
#   │   ├── channel.json       { slug, name, description, project_root, created, archived }
#   │   ├── conversation.jsonl
#   │   ├── plan.jsonl, plan.archive.jsonl
#   │   ├── backlog.jsonl
#   │   └── files/
#   └── _archive/<slug>/...    (archived channels — preserved, hidden from default list)
#
# Active channel pointer: control/active_channel (single line, the slug). Defaults to 'main'.

function Get-ChannelsRoot { Join-Path (Get-BridgeRoot) 'channels' }
function Get-ChannelArchivesRoot { Join-Path (Get-ChannelsRoot) '_archive' }
function Get-ActiveChannelMarkerPath { Join-Path (Get-BridgeRoot) 'control\active_channel' }

function Get-ActiveChannel {
  # Returns the slug of the currently-active channel, or 'main' if none set.
  $p = Get-ActiveChannelMarkerPath
  if (-not (Test-Path $p)) { return 'main' }
  try {
    $s = ([string](Get-Content $p -Raw -Encoding UTF8)).Trim()
    if (-not [string]::IsNullOrWhiteSpace($s)) { return $s }
  } catch {}
  return 'main'
}

# --- pinned channel (phase 3-lite) ---
# Driver pins the channel for the duration of a task so that switching the active
# channel via UI mid-task doesn't yank data out from under it. The server process
# does NOT pin -- it always operates on Get-ActiveChannel for fresh user requests.
$script:PinnedChannel = $null
function Set-PinnedChannel { param([string]$Slug) $script:PinnedChannel = (Normalize-ChannelSlug $Slug) }
function Clear-PinnedChannel { $script:PinnedChannel = $null }
function Get-PinnedChannel { return $script:PinnedChannel }
function Get-EffectiveChannel {
  # Channel to actually read/write from. Pinned wins, then inherited env, else active marker.
  if (-not [string]::IsNullOrWhiteSpace([string]$script:PinnedChannel)) { return [string]$script:PinnedChannel }
  if ($env:BRIDGE_CHANNEL) {
    $envSlug = [string]$env:BRIDGE_CHANNEL
    if ($envSlug -match '^[a-z0-9][a-z0-9_-]*$') {
      $channelDir = Join-Path (Get-BridgeRoot) "channels/$envSlug"
      if ($envSlug -eq 'main' -or (Test-Path -LiteralPath $channelDir -PathType Container)) { return $envSlug }
    }
  }
  return (Get-ActiveChannel)
}

function Invoke-WithChannelEnv {
  param(
    [Parameter(Mandatory=$true)][string]$Slug,
    [Parameter(Mandatory=$true)][scriptblock]$Action
  )
  $prevSlug = $env:BRIDGE_CHANNEL
  try {
    [Environment]::SetEnvironmentVariable('BRIDGE_CHANNEL', $Slug, 'Process')
    & $Action
  } finally {
    [Environment]::SetEnvironmentVariable('BRIDGE_CHANNEL', $prevSlug, 'Process')
  }
}

function Normalize-ChannelSlug {
  param([string]$Slug)
  if ([string]::IsNullOrWhiteSpace($Slug)) { return 'main' }
  $s = $Slug.Trim().ToLowerInvariant()
  $s = ($s -replace '\s+', '-' -replace '[^a-z0-9-]+', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($s)) { return 'main' }
  try {
    $channelsRoot = Get-ChannelsRoot
    if (Test-Path -LiteralPath (Join-Path $channelsRoot $s) -PathType Container) { return $s }
    $lookupKey = ($s -replace '[^a-z0-9]+', '')
    if (-not [string]::IsNullOrWhiteSpace($lookupKey) -and (Test-Path -LiteralPath $channelsRoot -PathType Container)) {
      foreach ($dir in @(Get-ChildItem -LiteralPath $channelsRoot -Directory -ErrorAction SilentlyContinue)) {
        if ($dir.Name -eq '_archive') { continue }
        $candidates = New-Object System.Collections.Generic.List[string]
        [void]$candidates.Add([string]$dir.Name)
        $cfgPath = Join-Path $dir.FullName 'channel.json'
        if (Test-Path -LiteralPath $cfgPath) {
          try {
            $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($cfg) {
              if ($cfg.PSObject.Properties['slug']) { [void]$candidates.Add([string]$cfg.slug) }
              if ($cfg.PSObject.Properties['name']) { [void]$candidates.Add([string]$cfg.name) }
            }
          } catch {}
        }
        foreach ($cand in @($candidates.ToArray())) {
          $candKey = (([string]$cand).Trim().ToLowerInvariant() -replace '[^a-z0-9]+', '')
          if ($candKey -eq $lookupKey) { return [string]$dir.Name }
        }
      }
    }
  } catch {}
  return $s
}

function Get-ChannelSettingsProjectConfig {
  param([string]$Slug = $null)
  $Slug = Normalize-ChannelSlug $Slug
  $settingsPath = Join-Path (Get-BridgeRoot) 'settings.json'
  if (-not (Test-Path -LiteralPath $settingsPath)) { return $null }

  try {
    $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
  } catch {
    return $null
  }
  if (-not $settings) { return $null }

  $entry = $null
  try {
    if ($settings.PSObject.Properties['channels'] -and $settings.channels) {
      $ch = $settings.channels
      if ($ch.PSObject.Properties[$Slug]) {
        $entry = $ch.PSObject.Properties[$Slug].Value
      }
    }
  } catch {}

  if ($null -eq $entry) {
    foreach ($k in @(
      "channels.$Slug.projectPath",
      "channels.$Slug.project_root",
      "channels.$Slug.path"
    )) {
      try {
        if ($settings.PSObject.Properties[$k]) {
          $entry = [pscustomobject]@{ projectPath = $settings.PSObject.Properties[$k].Value }
          break
        }
      } catch {}
    }
  }

  if ($null -eq $entry) { return $null }

  $path = ''
  foreach ($k in @('projectPath','project_root','path')) {
    try {
      if ($entry.PSObject.Properties[$k] -and -not [string]::IsNullOrWhiteSpace([string]$entry.$k)) {
        $path = [string]$entry.$k
        break
      }
    } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($path)) { return $null }

  $ptype = ''
  foreach ($k in @('projectType','type')) {
    try {
      if ($entry.PSObject.Properties[$k]) { $ptype = [string]$entry.$k; break }
    } catch {}
  }

  $pdesc = ''
  foreach ($k in @('projectDescription','description')) {
    try {
      if ($entry.PSObject.Properties[$k]) { $pdesc = [string]$entry.$k; break }
    } catch {}
  }

  return [pscustomobject]@{
    project_root        = $path
    project_type        = $ptype
    project_description = $pdesc
    source              = 'settings.json'
  }
}

function Get-ChannelProjectBinding {
  param([string]$Slug = $null)
  $Slug = Normalize-ChannelSlug $Slug
  $bridgeRoot = Get-BridgeRoot

  if ($Slug -eq 'main') {
    return [pscustomobject]@{
      slug                = $Slug
      project_root        = $bridgeRoot
      project_type        = 'bridge (self)'
      project_description = 'Default bridge development channel'
      source              = 'main-default'
      ok                  = $true
      error               = ''
    }
  }

  $cfg = Get-ChannelSettingsProjectConfig -Slug $Slug
  if (-not $cfg) {
    $ch = Get-ChannelConfig -Slug $Slug
    if ($ch -and $ch.PSObject.Properties['project_root'] -and -not [string]::IsNullOrWhiteSpace([string]$ch.project_root)) {
      $chDesc = ''
      try { if ($ch.PSObject.Properties['description']) { $chDesc = [string]$ch.description } } catch {}
      $cfg = [pscustomobject]@{
        project_root        = [string]$ch.project_root
        project_type        = ''
        project_description = $chDesc
        source              = 'channel.json'
      }
    }
  }

  if (-not $cfg -or [string]::IsNullOrWhiteSpace([string]$cfg.project_root)) {
    return [pscustomobject]@{
      slug                = $Slug
      project_root        = ''
      project_type        = ''
      project_description = ''
      source              = ''
      ok                  = $false
      error               = "Канал '$Slug' не привязан к проекту"
    }
  }

  $pr = [string]$cfg.project_root
  if (-not (Test-Path -LiteralPath $pr -PathType Container)) {
    return [pscustomobject]@{
      slug                = $Slug
      project_root        = $pr
      project_type        = [string]$cfg.project_type
      project_description = [string]$cfg.project_description
      source              = [string]$cfg.source
      ok                  = $false
      error               = "projectPath канала '$Slug' не найден: $pr"
    }
  }

  try { $pr = [System.IO.Path]::GetFullPath($pr) } catch {}
  return [pscustomobject]@{
    slug                = $Slug
    project_root        = $pr
    project_type        = [string]$cfg.project_type
    project_description = [string]$cfg.project_description
    source              = [string]$cfg.source
    ok                  = $true
    error               = ''
  }
}

function Get-EffectiveProjectRoot {
  # Channel-specific project root. main is the bridge; non-main has no silent fallback.
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = Get-EffectiveChannel }
  $binding = Get-ChannelProjectBinding -Slug $Slug
  if ($binding -and [bool]$binding.ok) { return [string]$binding.project_root }
  return ''
}

function Get-EffectiveScope {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = Get-EffectiveChannel }
  if ($Slug -notmatch '^[a-z0-9][a-z0-9_-]*$') {
    throw "Get-EffectiveScope: invalid slug '$Slug' (must match ^[a-z0-9][a-z0-9_-]*$)"
  }

  $bridgeRoot = Get-BridgeRoot
  $isBridge = ($Slug -eq 'main')
  $channelDir = Join-Path $bridgeRoot "channels/$Slug"
  if (-not $isBridge -and -not (Test-Path -LiteralPath $channelDir -PathType Container)) {
    throw "Get-EffectiveScope: channel '$Slug' does not exist at $channelDir"
  }

  if ($isBridge) {
    $featuresRoot = Join-Path $bridgeRoot 'features'
    $memoryRoot = Join-Path $bridgeRoot 'memory'
    $projectRoot = $bridgeRoot
    $backlogPath = Join-Path $bridgeRoot 'backlog.jsonl'
  } else {
    $featuresRoot = Join-Path $channelDir 'features'
    $memoryRoot = Join-Path $channelDir 'memory'
    $projectRoot = Get-EffectiveProjectRoot -Slug $Slug
    $backlogPath = Join-Path $channelDir 'backlog.jsonl'
  }

  [pscustomobject]@{
    slug                     = $Slug
    is_bridge                = $isBridge
    bridge_root              = $bridgeRoot
    project_root             = $projectRoot
    features_root            = $featuresRoot
    features_registry        = (Join-Path $featuresRoot 'registry.json')
    features_state           = (Join-Path $featuresRoot 'state.json')
    features_exists          = (Test-Path -LiteralPath $featuresRoot -PathType Container)
    memory_root              = $memoryRoot
    memory_store             = (Join-Path $memoryRoot 'memory.jsonl')
    memory_exists            = (Test-Path -LiteralPath $memoryRoot -PathType Container)
    backlog_path             = $backlogPath
    bridge_features_registry = (Join-Path $bridgeRoot 'features/registry.json')
    bridge_memory_root       = (Join-Path $bridgeRoot 'memory')
    bridge_memory_store      = (Join-Path $bridgeRoot 'memory/memory.jsonl')
  }
}

function Get-ChannelFeatureRegistryPath {
  param([string]$Slug = $null)
  return [string]((Get-EffectiveScope -Slug $Slug).features_registry)
}

function Set-ActiveChannel {
  param([string]$Slug)
  if ([string]::IsNullOrWhiteSpace($Slug)) { return $false }
  $Slug = Normalize-ChannelSlug $Slug
  $cdir = Get-ChannelDir -Slug $Slug
  if (-not (Test-Path $cdir)) { return $false }
  try {
    $ctl = Join-Path (Get-BridgeRoot) 'control'
    if (-not (Test-Path $ctl)) { New-Item -ItemType Directory -Path $ctl -Force | Out-Null }
    [System.IO.File]::WriteAllText((Get-ActiveChannelMarkerPath), $Slug, (New-Object System.Text.UTF8Encoding($false)))
    return $true
  } catch { return $false }
}

function Get-ChannelDir {
  # Path to a channel's directory (does not check existence).
  # $Slug=$null -> effective channel (pinned-in-driver overrides active marker; see Get-EffectiveChannel).
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = Get-EffectiveChannel }
  $Slug = Normalize-ChannelSlug $Slug
  return (Join-Path (Get-ChannelsRoot) $Slug)
}

function Get-ChannelConfig {
  param([string]$Slug = $null)
  $dir = Get-ChannelDir -Slug $Slug
  $cfg = Join-Path $dir 'channel.json'
  if (-not (Test-Path $cfg)) { return $null }
  try { return Get-Content $cfg -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Save-ChannelConfig {
  param([string]$Slug, [hashtable]$Patch)
  $dir = Get-ChannelDir -Slug $Slug
  if (-not (Test-Path $dir)) { return $false }
  $cur = Get-ChannelConfig -Slug $Slug
  if (-not $cur) { $cur = [pscustomobject]@{ slug = $Slug } }
  foreach ($k in $Patch.Keys) { $cur | Add-Member -NotePropertyName $k -NotePropertyValue $Patch[$k] -Force }
  try {
    $json = $cur | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText((Join-Path $dir 'channel.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
    return $true
  } catch { return $false }
}

function New-Channel {
  # Create a new channel. $Slug is what's in the filesystem path; $Name is the display name.
  # $ProjectRoot (optional) - phase 5 will route Codex's -C arg there.
  param([string]$Slug, [string]$Name = '', [string]$Description = '', [string]$ProjectRoot = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { return $null }
  # Conservative slug: lowercase, alphanum + hyphen
  $Slug = ($Slug.ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($Slug)) { return $null }
  $dir = Get-ChannelDir -Slug $Slug
  if (Test-Path $dir) { return $null }   # already exists
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $dir 'files') -Force | Out-Null
  # Touch empty list files so consumers don't have to check existence
  foreach ($f in 'conversation.jsonl','plan.jsonl','plan.archive.jsonl','backlog.jsonl') {
    $fp = Join-Path $dir $f
    if (-not (Test-Path $fp)) { [System.IO.File]::WriteAllText($fp, '', (New-Object System.Text.UTF8Encoding($false))) }
  }
  $cfg = [ordered]@{
    slug         = $Slug
    name         = if ([string]::IsNullOrWhiteSpace($Name)) { $Slug } else { $Name }
    description  = [string]$Description
    project_root = $ProjectRoot
    created      = (Get-Date).ToString('o')
    archived     = $false
  }
  $json = $cfg | ConvertTo-Json -Depth 6
  [System.IO.File]::WriteAllText((Join-Path $dir 'channel.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
  return $cfg
}

function Get-ChannelList {
  # List non-archived channels with their metadata. Always returns an array.
  param([switch]$IncludeArchived)
  $root = Get-ChannelsRoot
  if (-not (Test-Path $root)) { return @() }
  $items = New-Object 'System.Collections.Generic.List[object]'
  foreach ($d in Get-ChildItem $root -Directory -ErrorAction SilentlyContinue) {
    if ($d.Name -eq '_archive') { continue }
    $cfg = Get-ChannelConfig -Slug $d.Name
    if (-not $cfg) {
      # legacy folder without channel.json -- synthesize minimal record so we don't lose it
      $cfg = [pscustomobject]@{ slug = $d.Name; name = $d.Name; created = $d.CreationTime.ToString('o'); archived = $false }
    }
    if ([bool]$cfg.archived -and -not $IncludeArchived) { continue }
    [void]$items.Add($cfg)
  }
  return @($items.ToArray() | Sort-Object { [string]$_.slug })
}

function Archive-Channel {
  param([string]$Slug)
  if ([string]::IsNullOrWhiteSpace($Slug)) { return $false }
  if ($Slug -eq 'main') { return $false }   # refuse to archive the default channel
  if ($Slug -eq (Get-ActiveChannel)) { return $false }   # refuse to archive the active one
  $dir = Get-ChannelDir -Slug $Slug
  if (-not (Test-Path $dir)) { return $false }
  $arch = Get-ChannelArchivesRoot
  if (-not (Test-Path $arch)) { New-Item -ItemType Directory -Path $arch -Force | Out-Null }
  $dest = Join-Path $arch $Slug
  if (Test-Path $dest) {
    $dest = Join-Path $arch ($Slug + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
  }
  try { Move-Item -LiteralPath $dir -Destination $dest -Force; return $true } catch { return $false }
}

# --- channel-aware path helpers (used by common.ps1's path resolvers) ---

function Get-ChannelConversationPath {
  param([string]$Slug = $null)
  return (Join-Path (Get-ChannelDir -Slug $Slug) 'conversation.jsonl')
}
function Get-ChannelPlanPath {
  param([string]$Slug = $null)
  return (Join-Path (Get-ChannelDir -Slug $Slug) 'plan.jsonl')
}
function Get-ChannelPlanArchivePath {
  param([string]$Slug = $null)
  return (Join-Path (Get-ChannelDir -Slug $Slug) 'plan.archive.jsonl')
}
function Get-ChannelBacklogPath {
  param([string]$Slug = $null)
  return (Join-Path (Get-ChannelDir -Slug $Slug) 'backlog.jsonl')
}
function Get-ChannelFilesPath {
  param([string]$Slug = $null)
  return (Join-Path (Get-ChannelDir -Slug $Slug) 'files')
}
function Get-ChannelStatePath {
  # Phase 3 (full multi-driver): each channel has its own state.json so drivers run in parallel.
  param([string]$Slug = $null)
  return (Join-Path (Get-ChannelDir -Slug $Slug) 'state.json')
}

function Initialize-Channels {
  # One-shot migration: if old-layout files exist at bridge root and channels/main/ is empty,
  # move conversation/plan/backlog/files into channels/main/ and write a default channel.json.
  # Idempotent: if channels/main already has the expected files, do nothing.
  $root = Get-BridgeRoot
  $chRoot = Get-ChannelsRoot
  if (-not (Test-Path $chRoot)) { New-Item -ItemType Directory -Path $chRoot -Force | Out-Null }
  $mainDir = Get-ChannelDir -Slug 'main'
  if (-not (Test-Path $mainDir)) {
    New-Item -ItemType Directory -Path $mainDir -Force | Out-Null
  }
  # Write/refresh main's channel.json
  if (-not (Test-Path (Join-Path $mainDir 'channel.json'))) {
    $cfg = [ordered]@{
      slug = 'main'; name = 'Bridge (main)'
      description = 'Default channel — bridge development, meta-improvement, all original work'
      project_root = $null
      created = (Get-Date).ToString('o')
      archived = $false
    }
    $json = $cfg | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText((Join-Path $mainDir 'channel.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
  }
  # files/ subfolder
  if (-not (Test-Path (Join-Path $mainDir 'files'))) {
    New-Item -ItemType Directory -Path (Join-Path $mainDir 'files') -Force | Out-Null
  }
  # Migrate top-level conversation/plan/backlog into main/ if NOT already moved.
  foreach ($fname in 'conversation.jsonl','plan.jsonl','plan.archive.jsonl','backlog.jsonl') {
    $src = Join-Path $root $fname
    $dst = Join-Path $mainDir $fname
    if ((Test-Path $src) -and -not (Test-Path $dst)) {
      try { Move-Item -LiteralPath $src -Destination $dst -Force } catch {}
    } elseif (-not (Test-Path $dst)) {
      # Create empty so consumers don't have to check
      [System.IO.File]::WriteAllText($dst, '', (New-Object System.Text.UTF8Encoding($false)))
    }
  }
  # Phase 3 (full multi-driver): migrate root state.json into channels/main/state.json.
  # MOVE so there's exactly one canonical location and no stale-shadow risk. Watchdog
  # was updated to read channels/main/state.json with root as legacy fallback.
  $stateSrc = Join-Path $root 'state.json'
  $stateDst = Join-Path $mainDir 'state.json'
  if ((Test-Path $stateSrc) -and -not (Test-Path $stateDst)) {
    try { Move-Item -LiteralPath $stateSrc -Destination $stateDst -Force } catch {}
  }
  # For NON-main channels: state.json gets seeded by each channel's driver on its first
  # Initialize-Bridge call (which now also self-heals lastSeq from any existing
  # conversation.jsonl, so the per-channel UI poll picks up new messages correctly).
  # Migrate files/ subfolder: contents go into main/files/
  $srcFiles = Join-Path $root 'files'
  $dstFiles = Join-Path $mainDir 'files'
  if ((Test-Path $srcFiles) -and (Test-Path $dstFiles)) {
    $srcReal = (Get-Item $srcFiles).FullName
    $dstReal = (Get-Item $dstFiles).FullName
    if ($srcReal -ne $dstReal) {
      foreach ($f in Get-ChildItem $srcFiles -ErrorAction SilentlyContinue) {
        $target = Join-Path $dstFiles $f.Name
        if (-not (Test-Path $target)) {
          try { Move-Item -LiteralPath $f.FullName -Destination $target -Force } catch {}
        }
      }
      # Remove old files/ if now empty
      try { if (-not @(Get-ChildItem $srcFiles -Force -ErrorAction SilentlyContinue).Count) { Remove-Item $srcFiles -Force -Recurse -ErrorAction SilentlyContinue } } catch {}
    }
  }
  # Set active channel marker if not yet set
  $activeMk = Get-ActiveChannelMarkerPath
  if (-not (Test-Path $activeMk)) {
    try {
      $ctl = Join-Path $root 'control'
      if (-not (Test-Path $ctl)) { New-Item -ItemType Directory -Path $ctl -Force | Out-Null }
      [System.IO.File]::WriteAllText($activeMk, 'main', (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
  }
}
