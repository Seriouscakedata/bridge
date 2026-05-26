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

function Set-ActiveChannel {
  param([string]$Slug)
  if ([string]::IsNullOrWhiteSpace($Slug)) { return $false }
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
  # Path to a channel's directory (does not check existence). $Slug=$null -> active channel.
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = Get-ActiveChannel }
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
