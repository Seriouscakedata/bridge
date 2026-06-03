function Get-BridgeRoot {
  # lib/ is one level under the bridge root. common modules live under lib/common/.
  $libRoot = $script:CommonLibRoot
  if ([string]::IsNullOrWhiteSpace($libRoot)) { $libRoot = Split-Path -Parent $PSScriptRoot }
  Split-Path -Parent $libRoot
}

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

function Get-BridgeConfig {
  # Loads config.json then overlays settings.json (gitignored, survives rollbacks).
  # Keys: flat ("maxAutonomousTasksPerDay") or dotted ("parallel.maxStreams").
  # Dotted-path goes into nested config; flat key overlays only if cfg has root key.
  #
  # PERF (2026-05-29): the idle driver loop calls this 10-15x PER SECOND, and each call
  # used to read BOTH config.json and settings.json from disk on a OneDrive-backed folder
  # where reads are network-latency-bound -- a major source of "redundant loop" overhead.
  # We now cache the RAW TEXT of both files keyed on a cheap (mtime,size) stamp and re-read
  # ONLY when a file actually changes. We still ConvertFrom-Json + overlay FRESH on every
  # call, so the returned object is always a brand-new instance: callers that Add-Member
  # onto it cannot poison the cache, and a settings.json edit (e.g. a UI toggle) is picked
  # up on the very next call because the stamp changes. If stat throws (transient OneDrive
  # hiccup) the stamp goes empty and we fall back to a direct read -- correctness never
  # depends on the cache.
  $root = Get-BridgeRoot
  $cfgPath = Join-Path $root 'config.json'
  $setPath = Join-Path $root 'settings.json'

  $stamp = ''
  try { $ci = Get-Item -LiteralPath $cfgPath -ErrorAction Stop; $stamp = '' + $ci.LastWriteTimeUtc.Ticks + ':' + $ci.Length } catch { $stamp = '' }
  if ($stamp -ne '') {
    try {
      if (Test-Path -LiteralPath $setPath) { $si = Get-Item -LiteralPath $setPath -ErrorAction Stop; $stamp += '|' + $si.LastWriteTimeUtc.Ticks + ':' + $si.Length }
      else { $stamp += '|none' }
    } catch { $stamp = '' }
  }

  if ($script:__bridgeCfgCache -and $stamp -ne '' -and [string]$script:__bridgeCfgCache.stamp -eq $stamp) {
    $cfgRaw = [string]$script:__bridgeCfgCache.cfgRaw
    $setRaw = [string]$script:__bridgeCfgCache.setRaw
  } else {
    $cfgRaw = Get-Content $cfgPath -Raw -Encoding UTF8
    $setRaw = ''
    if (Test-Path -LiteralPath $setPath) { try { $setRaw = Get-Content $setPath -Raw -Encoding UTF8 } catch { $setRaw = '' } }
    if ($stamp -ne '') { $script:__bridgeCfgCache = @{ stamp = $stamp; cfgRaw = $cfgRaw; setRaw = $setRaw } }
  }

  $cfg = $cfgRaw | ConvertFrom-Json
  try {
    if (-not [string]::IsNullOrWhiteSpace($setRaw)) {
      $s = $setRaw | ConvertFrom-Json
      if ($s) {
        foreach ($p in $s.PSObject.Properties) {
          $k = [string]$p.Name; $v = $p.Value
          if ($k -match '\.') {
            $parts = $k -split '\.', 2
            $section = $parts[0]; $field = $parts[1]
            if ($cfg.PSObject.Properties.Name -notcontains $section) {
              $cfg | Add-Member -NotePropertyName $section -NotePropertyValue ([pscustomobject]@{}) -Force
            }
            $cfg.$section | Add-Member -NotePropertyName $field -NotePropertyValue $v -Force
          } else {
            if ($cfg.PSObject.Properties.Name -contains $k) {
              $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $v -Force
            }
          }
        }
      }
    }
  } catch {}
  return $cfg
}

function Test-TaskControlMarker {
  param([string]$TaskText, [string]$Marker)
  if ([string]::IsNullOrWhiteSpace($TaskText) -or [string]::IsNullOrWhiteSpace($Marker)) { return $false }
  $markerRegex = '(?m)^\s*\[\[' + [regex]::Escape($Marker.Trim()) + '\]\]\s*$'
  foreach ($line in ([string]$TaskText -split '\r?\n')) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    return [bool]([regex]::IsMatch($line, $markerRegex))
  }
  return $false
}

function Get-FastLaneSettings {
  $out = @{ autoDetect = $false; minChars = 100; embedBatchEnabled = $true }
  try {
    $cfgF = Get-BridgeConfig
    if ($cfgF -and ($cfgF.PSObject.Properties.Name -contains 'fastLane') -and $cfgF.fastLane) {
      $fl = $cfgF.fastLane
      if (($fl.PSObject.Properties.Name -contains 'autoDetect') -and $null -ne $fl.autoDetect) { $out.autoDetect = [bool]$fl.autoDetect }
      if (($fl.PSObject.Properties.Name -contains 'minChars') -and $fl.minChars) { $out.minChars = [int]$fl.minChars }
      if (($fl.PSObject.Properties.Name -contains 'embedBatchEnabled') -and $null -ne $fl.embedBatchEnabled) { $out.embedBatchEnabled = [bool]$fl.embedBatchEnabled }
    }
  } catch {}
  if ([int]$out.minChars -le 0) { $out.minChars = 100 }
  return $out
}

function Test-IsTrivialTask {
  param([string]$TaskText, [int]$MinChars = 0)
  $t = ([string]$TaskText -replace '\[\[FAST\]\]', '').Trim()
  if ($MinChars -le 0) {
    try { $MinChars = [int](Get-FastLaneSettings).minChars } catch { $MinChars = 100 }
  }
  if ($MinChars -le 0) { $MinChars = 100 }
  if ($t.Length -ge $MinChars) { return $false }
  if ($t -match '\[\[REASONING:high\]\]') { return $false }
  if ($t -match '(?m)^#+\s') { return $false }
  if ($t -match '(?m)^\d+\.\s') { return $false }
  if ($t -match '```') { return $false }
  if ($t -match '(?i)(архитектур|разбер|исследу|спроектир|design|refactor|audit)') { return $false }
  if (Test-IsUnsafeFastLaneTask -TaskText $t) { return $false }
  return [bool](Test-IsSafeOsFastLaneTask -TaskText $t)
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

