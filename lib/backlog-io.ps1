# backlog-io.ps1 -- runtime, process, path, and persistence helpers for backlog.ps1.

if ([string]::IsNullOrWhiteSpace([string]$script:BacklogCuratorModel)) { $script:BacklogCuratorModel = 'gemini-2.5-flash-lite' }
if ([string]::IsNullOrWhiteSpace([string]$script:BacklogLibraryDir)) {
  $script:BacklogLibraryDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }
}

#region Backlog runtime and persistence helpers

function Get-BacklogLibraryDir {
  if (-not [string]::IsNullOrWhiteSpace([string]$script:BacklogLibraryDir)) { return [string]$script:BacklogLibraryDir }
  return (Join-Path (Get-BacklogFallbackBridgeRoot) 'lib')
}

function Get-BacklogFallbackBridgeRoot {
  if (Get-Command Get-BridgeRoot -ErrorAction SilentlyContinue) { return (Get-BridgeRoot) }
  return (Split-Path -Parent (Get-BacklogLibraryDir))
}

function Invoke-BacklogLocked {
  param([scriptblock]$ScriptBlock)
  if (Get-Command Use-BridgeLock -ErrorAction SilentlyContinue) { return (Use-BridgeLock $ScriptBlock) }
  return (& $ScriptBlock)
}

function Write-BacklogAtomicFile {
  param([string]$Path, [string]$Content)
  if (Get-Command Write-AtomicFile -ErrorAction SilentlyContinue) { Write-AtomicFile -Path $Path -Content $Content; return }
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = "$Path.tmp.$([guid]::NewGuid().ToString('N').Substring(0,8))"
  [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
  if (Test-Path -LiteralPath $Path) { Move-Item -LiteralPath $tmp -Destination $Path -Force }
  else { Move-Item -LiteralPath $tmp -Destination $Path }
}

function Get-BacklogControlDir {
  Join-Path (Get-BacklogFallbackBridgeRoot) 'control'
}

function Get-BacklogCuratorLauncherDir {
  # Curator launchers are ephemeral runtime artifacts; prefer the runtime root so
  # they do not accumulate under control/ in the source tree.
  $candidates = New-Object 'System.Collections.Generic.List[string]'

  if (Get-Command Get-RuntimeRoot -ErrorAction SilentlyContinue) {
    try {
      $runtimeRoot = [string](Get-RuntimeRoot)
      if (-not [string]::IsNullOrWhiteSpace($runtimeRoot)) {
        [void]$candidates.Add((Join-Path $runtimeRoot 'curator-launchers'))
      }
    } catch {}
  }

  $userProfile = [string]$env:USERPROFILE
  if (-not [string]::IsNullOrWhiteSpace($userProfile)) {
    $userRuntime = Join-Path (Join-Path $userProfile '.bridge-runtime') 'curator-launchers'
    if (-not $candidates.Contains($userRuntime)) { [void]$candidates.Add($userRuntime) }
  }

  $repoRuntime = Join-Path (Join-Path (Get-BacklogFallbackBridgeRoot) 'runtime') 'curator-launchers'
  if (-not $candidates.Contains($repoRuntime)) { [void]$candidates.Add($repoRuntime) }

  $legacyControl = Join-Path (Get-BacklogControlDir) 'curator-launchers'
  if (-not $candidates.Contains($legacyControl)) { [void]$candidates.Add($legacyControl) }

  foreach ($dir in $candidates) {
    try {
      if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
      return $dir
    } catch {}
  }

  throw 'Unable to prepare backlog curator launcher directory.'
}

function Write-BacklogJsonLine {
  # 2026-05-27: critic-flagged fix. Add-Content -Encoding UTF8 on PS 5.1 writes
  # UTF-8 WITH BOM on first call (when file is created), breaking strict JSONL
  # parsers. ConvertTo-Json -Depth 10 on a hashtable Record is shallow-safe but
  # we reduce to Depth 6 (matches memory rule "Depth<=10 OK, prefer flat DTOs").
  param($Record)
  try {
    $dir = Get-BacklogControlDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'curator-decisions.jsonl'
    $line = $Record | ConvertTo-Json -Compress -Depth 6
    $u8NoBom = New-Object System.Text.UTF8Encoding($false)
    Invoke-BacklogLocked ({ [System.IO.File]::AppendAllText($path, ($line + "`n"), $u8NoBom) }.GetNewClosure()) | Out-Null
  } catch {}
}

function Write-LastAddIdeaMarker {
  param($Record)
  try {
    $dir = Get-BacklogControlDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir 'last-add-idea.json'
    $json = ($Record | ConvertTo-Json -Compress -Depth 6) + "`n"
    Invoke-BacklogLocked ({ Write-BacklogAtomicFile -Path $path -Content $json }.GetNewClosure()) | Out-Null
  } catch {}
}

function Start-BacklogCuratorJob {
  param([string]$ItemId)
  if ([string]::IsNullOrWhiteSpace($ItemId)) { return $false }
  try {
    $root = Get-BacklogFallbackBridgeRoot
    # 2026-05-28 BUG-fix (backlog item c825502cba): the launcher previously
    # dot-sourced ONLY `lib/backlog.ps1`. But Invoke-BacklogCurator -> Get-Backlog
    # -> Get-BacklogPath, which needs Get-ChannelBacklogPath defined in
    # lib/channels.ps1 to resolve channels/<slug>/backlog.jsonl. Without
    # channels.ps1 loaded, Get-BacklogPath fell back to <root>/backlog.jsonl
    # (doesn't exist) -> Get-Backlog returned empty -> curator returned $null
    # silently -> EVERY new item since 2026-05-27 12:26 stayed at status=new
    # with no auto_curator verdict.
    # Fix: dot-source lib/common.ps1 (which itself dot-sources channels.ps1 +
    # backlog.ps1 + memory.ps1 + llm.ps1 in the right order). Pin the active
    # channel before invoking so Get-EffectiveChannel resolves correctly.
    $commonLib = Join-Path $PSScriptRoot 'common.ps1'
    $log = Join-Path (Get-BacklogControlDir) 'curator.log'
    $launcherDir = Get-BacklogCuratorLauncherDir
    $stamp = (Get-Date -Format 'yyyyMMddHHmmss') + '_' + ([guid]::NewGuid().ToString('N').Substring(0,6))
    $launcher = Join-Path $launcherDir ("curator_" + $stamp + ".ps1")
    # Capture the channel slug at launch time so the launcher pins to it
    # (matches the channel whose backlog the item lives in).
    $channelSlug = 'main'
    try {
      if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) {
        $channelSlug = [string](Get-EffectiveChannel)
      }
    } catch {}
    if ([string]::IsNullOrWhiteSpace($channelSlug)) { $channelSlug = 'main' }
    $launcherBody = @"
`$ErrorActionPreference = 'Continue'
try {
  . '$($commonLib.Replace("'", "''"))'
  if (Get-Command Set-PinnedChannel -ErrorAction SilentlyContinue) {
    Set-PinnedChannel '$($channelSlug.Replace("'", "''"))'
  }
  `$result = Invoke-BacklogCurator -ItemId '$($ItemId.Replace("'", "''"))' 2>`$null
  `$line = (Get-Date).ToString('o') + " | item=$($ItemId.Replace("'", "''")) | channel=$($channelSlug.Replace("'", "''")) | result=" + (`$result | ConvertTo-Json -Compress -Depth 4) + "`n"
  [System.IO.File]::AppendAllText('$($log.Replace("'", "''"))', `$line, (New-Object System.Text.UTF8Encoding(`$false)))
} catch {
  `$err = (Get-Date).ToString('o') + " | item=$($ItemId.Replace("'", "''")) | error=" + `$_.Exception.Message + "`n"
  [System.IO.File]::AppendAllText('$($log.Replace("'", "''"))', `$err, (New-Object System.Text.UTF8Encoding(`$false)))
}
"@
    $u8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($launcher, $launcherBody, $u8Bom)
    Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
      Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$launcher) -WorkingDirectory $root -WindowStyle Hidden | Out-Null
    }
    return $true
  } catch {
    Write-BacklogJsonLine ([ordered]@{
      ts = (Get-Date).ToUniversalTime().ToString('o')
      action = 'judge-launch-error'
      item_id = $ItemId
      error = [string]$_.Exception.Message
    })
    return $false
  }
}

function Ensure-BacklogMemoryLoaded {
  if (-not (Get-Command Get-Embedding -ErrorAction SilentlyContinue)) {
    $p = Join-Path (Get-BacklogLibraryDir) 'memory.ps1'
    if (Test-Path -LiteralPath $p) { . $p }
  }
}

function Ensure-BacklogLLMLoaded {
  Ensure-BacklogMemoryLoaded
  if (-not (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)) {
    $p = Join-Path (Get-BacklogLibraryDir) 'llm.ps1'
    if (Test-Path -LiteralPath $p) { . $p }
  }
}

function ConvertFrom-BacklogStrictJson {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $clean = ([string]$Text -replace '```(?:json)?', '' -replace '```', '').Trim()
  $mt = [regex]::Match($clean, '(?s)\{.*\}')
  if (-not $mt.Success) { return $null }
  try { return ($mt.Value | ConvertFrom-Json) } catch { return $null }
}

function ConvertTo-BacklogProcessArgument {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }
  $escaped = ([string]$Value) -replace '(\\*)"', '$1$1\"'
  $escaped = $escaped -replace '(\\+)$', '$1$1'
  return '"' + $escaped + '"'
}

function Invoke-BacklogProcess {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string[]]$Arguments = @(),
    [string]$WorkingDirectory = (Get-BacklogFallbackBridgeRoot),
    [int]$TimeoutSec = 30
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = (@($Arguments) | ForEach-Object { ConvertTo-BacklogProcessArgument ([string]$_) }) -join ' '
  $psi.WorkingDirectory = $WorkingDirectory
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  try {
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  } catch {}

  $timeout = [Math]::Max(1, [int]$TimeoutSec)
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEndAsync()
  $stderr = $proc.StandardError.ReadToEndAsync()
  $timedOut = $false
  if (-not $proc.WaitForExit($timeout * 1000)) {
    $timedOut = $true
    try { $proc.Kill() } catch {}
    try { $proc.WaitForExit(3000) | Out-Null } catch {}
  }
  try { $stdout.Wait(3000) | Out-Null } catch {}
  try { $stderr.Wait(3000) | Out-Null } catch {}
  return [pscustomobject]@{
    ExitCode = if ($timedOut) { 124 } else { [int]$proc.ExitCode }
    TimedOut = [bool]$timedOut
    Output = @(
      if ($stdout.IsCompleted -and -not [string]::IsNullOrEmpty($stdout.Result)) { $stdout.Result }
      if ($stderr.IsCompleted -and -not [string]::IsNullOrEmpty($stderr.Result)) { $stderr.Result }
    )
  }
}

function Get-BacklogGitOutput {
  param([string[]]$GitArgs)
  try {
    if ($null -eq $GitArgs -or $GitArgs.Count -eq 0) { return '' }
    $root = Get-BacklogFallbackBridgeRoot
    $git = if (Get-Command Get-GitExe -ErrorAction SilentlyContinue) { Get-GitExe } else { 'git' }
    $args = @('-c', "safe.directory=$root", '-C', $root) + @($GitArgs)
    $result = Invoke-BacklogProcess -FilePath $git -Arguments $args -WorkingDirectory $root -TimeoutSec 30
    if ($result.TimedOut -or $result.ExitCode -ne 0) { return '' }
    if ($null -eq $result.Output) { return '' }
    return (($result.Output | Out-String).Trim())
  } catch { return '' }
}

function Get-BacklogCurrentSha {
  $sha = Get-BacklogGitOutput -GitArgs @('rev-parse', 'HEAD')
  return ([string]$sha).Trim()
}

function Get-BacklogStatusSummary {
  try {
    $p = Join-Path (Get-BacklogControlDir) 'status.json'
    if (-not (Test-Path -LiteralPath $p)) { return 'status.json missing' }
    $raw = (Get-Content -LiteralPath $p -Raw -Encoding UTF8).Trim()
    if ($raw.Length -gt 1200) { $raw = $raw.Substring(0, 1200) + '...' }
    return $raw
  } catch { return 'status unavailable' }
}

function Resolve-BacklogPathValue {
  if (Get-Command Get-ChannelBacklogPath -ErrorAction SilentlyContinue) { return (Get-ChannelBacklogPath) }
  return (Join-Path (Get-BacklogFallbackBridgeRoot) 'backlog.jsonl')
}

function Ensure-BacklogPathFunction {
  # 2026-06-04 registry_drift fix: some inline/dynamic callers were keeping
  # Add-Idea / Invoke-BacklogCurator loaded while Get-BacklogPath had fallen out
  # of scope. Re-register the helper into script scope on demand so backlog
  # append/read/save paths stay callable even in a narrowed execution scope.
  if (Get-Command Get-BacklogPath -ErrorAction SilentlyContinue) { return }
  function script:Get-BacklogPath {
    return (Resolve-BacklogPathValue)
  }
}

function Get-BacklogPath {
  return (Resolve-BacklogPathValue)
}

#endregion Backlog runtime and persistence helpers
