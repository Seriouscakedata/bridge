# common-files.ps1 -- decomposed helpers from common.ps1. Dot-sourced by common.ps1.

function Resolve-BridgeContainedPath {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [string]$BasePath = $null,
    [string]$Purpose = 'bridge path'
  )
  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "Resolve-BridgeContainedPath: empty path for $Purpose"
  }
  if ([string]::IsNullOrWhiteSpace($BasePath)) { $BasePath = Get-BridgeRoot }

  try {
    $baseInfo = Resolve-Path -LiteralPath $BasePath -ErrorAction Stop
    $baseResolved = [string]$baseInfo.ProviderPath
  } catch {
    $baseResolved = [System.IO.Path]::GetFullPath($BasePath)
  }
  $baseFull = [System.IO.Path]::GetFullPath($baseResolved).TrimEnd('\','/')

  $targetInput = $Path
  if (-not [System.IO.Path]::IsPathRooted($targetInput)) {
    $targetInput = Join-Path $baseFull $targetInput
  }

  if (Test-Path -LiteralPath $targetInput) {
    try {
      $targetInfo = Resolve-Path -LiteralPath $targetInput -ErrorAction Stop
      $targetResolved = [string]$targetInfo.ProviderPath
    } catch {
      throw "Resolve-BridgeContainedPath: cannot resolve $Purpose '$Path': $($_.Exception.Message)"
    }
  } else {
    $parent = Split-Path -Parent $targetInput
    $leaf = Split-Path -Leaf $targetInput
    if (-not [string]::IsNullOrWhiteSpace($parent) -and (Test-Path -LiteralPath $parent)) {
      try {
        $parentInfo = Resolve-Path -LiteralPath $parent -ErrorAction Stop
        $targetResolved = Join-Path ([string]$parentInfo.ProviderPath) $leaf
      } catch {
        throw "Resolve-BridgeContainedPath: cannot resolve parent for $Purpose '$Path': $($_.Exception.Message)"
      }
    } else {
      $targetResolved = [System.IO.Path]::GetFullPath($targetInput)
    }
  }
  $targetFull = [System.IO.Path]::GetFullPath($targetResolved).TrimEnd('\','/')

  if ($targetFull.Equals($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $targetFull }
  $basePrefix = $baseFull + [System.IO.Path]::DirectorySeparatorChar
  if ($targetFull.StartsWith($basePrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $targetFull }
  throw "Resolve-BridgeContainedPath: $Purpose escapes bridge root: $targetFull (base: $baseFull)"
}

function Remove-FileWithRetry {
  # Helper: try removing a file 5 times with exp backoff. Returns $true on success.
  # On final failure logs to control/tmp-leak.log so orphans are auditable.
  param([string]$Path, [string]$Reason = 'cleanup')
  if (-not (Test-Path -LiteralPath $Path)) { return $true }
  $tries = 0
  while ($tries -lt 5) {
    try { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop; return $true }
    catch { $tries++; Start-Sleep -Milliseconds (50 * $tries) }
  }
  # Final failure: log to leak audit. Do NOT use SilentlyContinue silent-swallow.
  try {
    $logDir = Join-Path (Get-BridgeRoot) 'control'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logPath = Join-Path $logDir 'tmp-leak.log'
    $u8 = New-Object System.Text.UTF8Encoding($false)
    $line = (Get-Date).ToString('o') + " | reason=$Reason | path=$Path" + "`n"
    [System.IO.File]::AppendAllText($logPath, $line, $u8)
  } catch {}
  return $false
}

function Write-AtomicFile {
  # Atomic file replacement that survives OneDrive sync locks.
  # 2026-05-27v6: tmp-leak fix. Removal failures now log to control/tmp-leak.log
  # (was SilentlyContinue silent-swallow leading to 100+ orphan .tmp.* files).
  # On startup, Sweep-OrphanTmpFiles() picks them up.
  param([string]$Path, [string]$Content, [switch]$NoCopyFallback)
  $tmp = "$Path.tmp.$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
  [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
  $tries = 0; $maxTries = 6
  while ($true) {
    try {
      if (Test-Path -LiteralPath $Path) {
        [System.IO.File]::Replace($tmp, $Path, $null)
      } else {
        [System.IO.File]::Move($tmp, $Path)
      }
      return
    } catch {
      $tries++
      if ($tries -ge $maxTries) {
        if ($NoCopyFallback) {
          Remove-FileWithRetry -Path $tmp -Reason 'atomic-nocopy-fail' | Out-Null
          throw "Write-AtomicFile: exhausted $maxTries retries on '$Path' (-NoCopyFallback: refusing Copy-Item torn write)"
        }
        try {
          Copy-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
          Remove-FileWithRetry -Path $tmp -Reason 'atomic-fallback-copy-success' | Out-Null
          return
        } catch {
          Remove-FileWithRetry -Path $tmp -Reason 'atomic-final-fail' | Out-Null
          throw
        }
      }
      Start-Sleep -Milliseconds (60 * $tries)
    }
  }
}

function Merge-UnflushedSidecars {
  # 2026-05-27v6: P3 audit finding -- Add-Message writes lost messages to
  # `$convPath.unflushed` when main append fails (OneDrive lock, fs error).
  # Previously there was no recovery on startup -- user never knew messages
  # were lost. Now we scan for *.unflushed sidecars next to channels'
  # conversation.jsonl files and merge them in (append + delete sidecar).
  # Safe to call multiple times; idempotent (sidecar deleted after merge).
  $root = Get-BridgeRoot
  $chanRoot = Join-Path $root 'channels'
  if (-not (Test-Path -LiteralPath $chanRoot)) { return @{ merged = 0 } }
  $totalLines = 0; $totalSidecars = 0
  try {
    $sidecars = Get-ChildItem -LiteralPath $chanRoot -File -Recurse -Force -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like 'conversation.jsonl.unflushed' }
    foreach ($sc in $sidecars) {
      try {
        $convPath = $sc.FullName -replace '\.unflushed$', ''
        if (-not (Test-Path -LiteralPath $convPath)) { continue }
        $u8 = New-Object System.Text.UTF8Encoding($false)
        $content = [System.IO.File]::ReadAllText($sc.FullName, $u8)
        if ([string]::IsNullOrWhiteSpace($content)) { Remove-FileWithRetry -Path $sc.FullName -Reason 'unflushed-empty' | Out-Null; continue }
        # Append to main conversation
        $fs = [System.IO.File]::Open($convPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
          $bytes = [System.Text.Encoding]::UTF8.GetBytes($content)
          $fs.Write($bytes, 0, $bytes.Length)
          $totalLines += ($content -split "`n").Count
          $totalSidecars++
        } finally { $fs.Dispose() }
        # Only delete sidecar after successful merge
        Remove-FileWithRetry -Path $sc.FullName -Reason 'unflushed-merged' | Out-Null
      } catch {
        # If anything fails for this sidecar, leave it for next startup attempt.
        try {
          $logPath = Join-Path (Join-Path $root 'control') 'tmp-leak.log'
          $line = (Get-Date).ToString('o') + " | reason=unflushed-merge-fail | path=" + $sc.FullName + " | err=" + $_.Exception.Message + "`n"
          [System.IO.File]::AppendAllText($logPath, $line, (New-Object System.Text.UTF8Encoding($false)))
        } catch {}
      }
    }
  } catch {}
  return @{ merged = $totalLines; sidecars = $totalSidecars }
}

function Rotate-LogIfBig {
  # Rotates a log file when it exceeds $MaxKB. Keeps last $Keep rotated copies
  # as $Path.1, $Path.2, ... Older rotations are deleted. Idempotent.
  # 2026-05-27v6: P1 audit finding -- metrics.jsonl/usage.jsonl/bridge-lock.log
  # were growing without TTL. This is called from driver idle loop periodically.
  param([string]$Path, [int]$MaxKB = 2048, [int]$Keep = 3)
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  try {
    $size = (Get-Item -LiteralPath $Path).Length
    if ($size -lt ($MaxKB * 1024)) { return $false }
    # Rotate: $Path.3 -> delete, .2 -> .3, .1 -> .2, $Path -> .1
    for ($i = $Keep; $i -ge 1; $i--) {
      $src = "$Path.$i"
      $dst = "$Path.$($i + 1)"
      if ($i -eq $Keep -and (Test-Path -LiteralPath $src)) {
        Remove-FileWithRetry -Path $src -Reason 'log-rotate-drop' | Out-Null
        continue
      }
      if (Test-Path -LiteralPath $src) {
        try { Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop } catch {}
      }
    }
    try { Move-Item -LiteralPath $Path -Destination "$Path.1" -Force -ErrorAction Stop } catch {}
    return $true
  } catch { return $false }
}

function Sweep-OrphanTmpFiles {
  # Periodic cleanup of *.tmp.* files older than 1 hour (rough heuristic: tmp files
  # actively in use are deleted within seconds; older ones are orphans from crashes
  # or silent-fail removals). Called once at driver startup.
  # SAFE: only touches files matching *.tmp.* pattern, skips files mid-write
  # (mtime within last 60 seconds).
  param([int]$MinAgeMin = 60)
  $root = Get-BridgeRoot
  $scanDirs = @(
    $root,
    (Join-Path $root 'channels'),
    (Join-Path $root 'memory')
  )
  $cutoff = (Get-Date).AddMinutes(-$MinAgeMin)
  $logDir = Join-Path $root 'control'
  if (-not (Test-Path -LiteralPath $logDir)) { try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch {} }
  $logPath = Join-Path $logDir 'tmp-sweep.log'
  $u8 = New-Object System.Text.UTF8Encoding($false)
  $cleaned = 0; $failed = 0
  foreach ($d in $scanDirs) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    try {
      $tmpFiles = Get-ChildItem -LiteralPath $d -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '\.tmp\.[a-f0-9]+$' -and $_.LastWriteTime -lt $cutoff }
      foreach ($f in $tmpFiles) {
        if (Remove-FileWithRetry -Path $f.FullName -Reason 'sweep-orphan') { $cleaned++ } else { $failed++ }
      }
    } catch {}
  }
  if ($cleaned -gt 0 -or $failed -gt 0) {
    try {
      $line = (Get-Date).ToString('o') + " | cleaned=$cleaned failed=$failed`n"
      [System.IO.File]::AppendAllText($logPath, $line, $u8)
    } catch {}
  }
  return @{ cleaned = $cleaned; failed = $failed }
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

function Get-BridgePrivateRoot {
  # Protected store OUTSIDE the bridge root -- and therefore outside the coder's
  # workspace-write sandbox, whose cwd for a bridge-self task IS the bridge root.
  # Holds operator-only material a coder turn must never be able to overwrite or
  # delete: API secrets (secrets.json), HTTP-auth creds (auth.json), and the
  # watchdog kill-switch (watchdog.pause). On Windows the codex sandbox runs as a
  # SEPARATE restricted OS user (confirmed in Gate C); a path outside its cwd is not
  # in its writable-roots, so it cannot create/clobber anything here. %USERPROFILE%
  # is per-user, NOT OneDrive-synced (KFM only moves Documents/Desktop/Pictures), and
  # NOT MSIX-virtualized for the host. Falls back to <bridge>/.private only if
  # USERPROFILE is unset (degraded, but still better than the repo root).
  $base = [string]$env:USERPROFILE
  if ([string]::IsNullOrWhiteSpace($base)) { $dir = Join-Path (Get-BridgeRoot) '.private' }
  else { $dir = Join-Path $base '.bridge-private' }
  if (-not (Test-Path -LiteralPath $dir)) { try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {} }
  return $dir
}

function Get-RuntimeRoot {
  # Mutable runtime telemetry that must survive supervisor restarts but must NOT
  # live under OneDrive/MSIX-virtualized roots. USERPROFILE was empirically stable
  # for bridge worktrees; fall back to control/ only when USERPROFILE is absent.
  $base = [string]$env:USERPROFILE
  if ([string]::IsNullOrWhiteSpace($base)) { $dir = Join-Path (Get-BridgeRoot) 'control' }
  else { $dir = Join-Path $base '.bridge-runtime' }
  if (-not (Test-Path -LiteralPath $dir)) { try { New-Item -ItemType Directory -Path $dir -Force | Out-Null } catch {} }
  return $dir
}

function Get-PrivateFilePath {
  # Resolve a protected file by name. Prefers the out-of-bridge store, but transparently
  # falls back to the legacy in-bridge path if a file hasn't been migrated yet, so a
  # half-migrated tree still reads. Writers/creators should always target the new path
  # (the default return when neither exists).
  param([Parameter(Mandatory=$true)][string]$Name)
  $new = Join-Path (Get-BridgePrivateRoot) $Name
  if (Test-Path -LiteralPath $new) { return $new }
  $old = Join-Path (Get-BridgeRoot) $Name
  if (Test-Path -LiteralPath $old) { return $old }
  return $new
}

function Get-SecretsPath { Get-PrivateFilePath 'secrets.json' }

function Get-AuthPath    { Get-PrivateFilePath 'auth.json' }

function Get-DecisionsPath { Resolve-BridgeContainedPath -Path 'decisions' -Purpose 'decisions directory' }

function Get-ConversationArchivePath {
  $cp = Get-ConversationPath
  return (Join-Path (Split-Path $cp -Parent) 'conversation.archive.jsonl')
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
