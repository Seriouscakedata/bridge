# circuit-breaker.ps1 -- restart attribution + supervisor restart circuit-breaker.
# Keep this module dot-source friendly: no live supervisor side effects on import.

if (-not (Get-Command Get-BridgeRoot -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot 'common.ps1')
}

function Get-CircuitBreakerSettings {
  $out = [ordered]@{
    enabled     = $true
    windowMin   = 30
    maxRestarts = 5
    cooldownMin = 15
  }
  try {
    $cfg = Get-BridgeConfig
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'circuitBreaker') -and $cfg.circuitBreaker) {
      $cb = $cfg.circuitBreaker
      foreach ($k in @('enabled','windowMin','maxRestarts','cooldownMin')) {
        if ($cb.PSObject.Properties.Name -contains $k -and $null -ne $cb.$k) {
          if ($k -eq 'enabled') { $out[$k] = [bool]$cb.$k } else { $out[$k] = [int]$cb.$k }
        }
      }
    }
  } catch {}
  if ([int]$out.windowMin -lt 1) { $out.windowMin = 30 }
  if ([int]$out.maxRestarts -lt 1) { $out.maxRestarts = 5 }
  $out.cooldownMin = [Math]::Min(30, [Math]::Max(10, [int]$out.cooldownMin))
  return [pscustomobject]$out
}

function Get-RestartsLogPath {
  Join-Path (Get-RuntimeRoot) 'restarts.jsonl'
}

function Get-CircuitHash {
  param([string]$Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
    $hash = $sha.ComputeHash($bytes)
    return (-join ($hash | ForEach-Object { $_.ToString('x2') })).Substring(0,16)
  } finally {
    try { $sha.Dispose() } catch {}
  }
}

function Remove-CircuitLineBom {
  param([AllowNull()][string]$Line)
  $lineText = ([string]$Line).Trim()
  while ($lineText.Length -gt 0 -and [int][char]$lineText[0] -eq 0xFEFF) {
    $lineText = $lineText.Substring(1).TrimStart()
  }
  return $lineText
}

function Invoke-CircuitLogMutex {
  param(
    [Parameter(Mandatory=$true)][scriptblock]$Body,
    [int]$TimeoutMs = 5000
  )
  $mutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeCodexBridgeRestartsLog')
  $got = $false
  try {
    try { $got = $mutex.WaitOne($TimeoutMs) }
    catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { throw "Could not acquire restart-log mutex within ${TimeoutMs}ms" }
    return (& $Body)
  } finally {
    if ($got) { try { $mutex.ReleaseMutex() } catch {} }
    try { $mutex.Dispose() } catch {}
  }
}

function Repair-CircuitLogBom {
  param([Parameter(Mandatory=$true)][string]$LogPath)
  if (-not (Test-Path -LiteralPath $LogPath)) { return }
  try {
    $bytes = [System.IO.File]::ReadAllBytes($LogPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
      $next = New-Object byte[] ([Math]::Max(0, $bytes.Length - 3))
      if ($next.Length -gt 0) { [Array]::Copy($bytes, 3, $next, 0, $next.Length) }
      $tmp = $LogPath + ".nobom.$PID.tmp"
      [System.IO.File]::WriteAllBytes($tmp, $next)
      Move-Item -LiteralPath $tmp -Destination $LogPath -Force
    }
  } catch {}
}

function Read-CircuitLogLines {
  param([Parameter(Mandatory=$true)][string]$LogPath)
  if (-not (Test-Path -LiteralPath $LogPath)) { return @() }
  try {
    $text = Invoke-CircuitLogMutex -TimeoutMs 5000 -Body {
      $fs = $null
      $sr = $null
      try {
        $fs = New-Object System.IO.FileStream($LogPath, ([System.IO.FileMode]::Open), ([System.IO.FileAccess]::Read), ([System.IO.FileShare]::ReadWrite))
        $sr = New-Object System.IO.StreamReader($fs, ([System.Text.Encoding]::UTF8), $true)
        return $sr.ReadToEnd()
      } finally {
        if ($sr) { try { $sr.Dispose() } catch {} }
        elseif ($fs) { try { $fs.Dispose() } catch {} }
      }
    }
    if ([string]::IsNullOrEmpty([string]$text)) { return @() }
    return @(([string]$text) -split "(`r`n|`n|`r)")
  } catch {
    return @()
  }
}

function Normalize-CircuitErrorLine {
  param([string]$Text)
  $lines = @(([string]$Text) -split "(`r`n|`n|`r)")
  $key = ''
  foreach ($line in $lines) {
    $l = ([string]$line).Trim()
    if ([string]::IsNullOrWhiteSpace($l)) { continue }
    if ($l -match 'ParserError|ParseException|Parser::ParseFile|state\.json|corrupt|поврежд|sharing violation|used by another process|index\.lock|Permission denied|Access is denied') {
      $key = $l
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($key)) {
    foreach ($line in ($lines | Select-Object -Last 20)) {
      $l = ([string]$line).Trim()
      if (-not [string]::IsNullOrWhiteSpace($l)) { $key = $l; break }
    }
  }
  $key = $key.ToLowerInvariant()
  $key = $key -replace '[a-z]:\\[^\s\]''"]+', '<path>'
  $key = $key -replace '\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '<guid>'
  $key = $key -replace '\b\d{2,}\b', '<n>'
  $key = $key -replace '\s+', ' '
  return $key.Trim()
}

function Write-RestartEvent {
  param(
    [ValidateSet('parse-fail','state-corrupt','OOM','explicit-flag','task-survived-3x','unknown')]
    [string]$Cause,
    [string]$Signature,
    [string]$Detail,
    [string]$LogPath = ''
  )
  if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Get-RestartsLogPath }
  $dir = Split-Path -Parent $LogPath
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  if ([string]::IsNullOrWhiteSpace($Signature)) { $Signature = Get-CircuitHash ($Cause + ':nosig') }
  $rec = [pscustomobject]@{
    ts        = (Get-Date).ToUniversalTime().ToString('o')
    cause     = [string]$Cause
    signature = [string]$Signature
    detail    = [string]$Detail
    pid       = [int]$PID
  }
  $line = ($rec | ConvertTo-Json -Compress -Depth 5) + "`n"
  $enc = New-Object System.Text.UTF8Encoding($false)
  Invoke-CircuitLogMutex -TimeoutMs 5000 -Body {
    Repair-CircuitLogBom -LogPath $LogPath
    $bytes = $enc.GetBytes($line)
    $fs = $null
    try {
      $fs = New-Object System.IO.FileStream($LogPath, ([System.IO.FileMode]::Append), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::Read))
      $fs.Write($bytes, 0, $bytes.Length)
      $fs.Flush($true)
    } finally {
      if ($fs) { try { $fs.Dispose() } catch {} }
    }
  }
  return [pscustomobject]$rec
}

function Get-RestartCause {
  param(
    [string]$RecentErrLog = '',
    [bool]$ReapFired = $false,
    [bool]$FlagPresent = $false,
    [int]$StateAttempts = 0
  )
  $class = 'unknown'
  $key = ''
  if ($ReapFired) {
    $class = 'OOM'
    $key = 'reap-bloated private-memory cap'
  } elseif ($RecentErrLog -match '(?is)ParserError|ParseException|Parser::ParseFile|не удалось распарсить') {
    $class = 'parse-fail'
    $key = Normalize-CircuitErrorLine $RecentErrLog
  } elseif ($RecentErrLog -match '(?is)state\.json\s+поврежд|state\.json.*corrupt|corrupt.*state\.json|\bcorrupt\b|поврежд') {
    $class = 'state-corrupt'
    $key = Normalize-CircuitErrorLine $RecentErrLog
  } elseif ($StateAttempts -ge 3) {
    $class = 'task-survived-3x'
    $key = 'task_restart_count>=3'
  } elseif ($FlagPresent) {
    $class = 'explicit-flag'
    $key = 'restart.flag'
  } else {
    $key = Normalize-CircuitErrorLine $RecentErrLog
    if ([string]::IsNullOrWhiteSpace($key)) { $key = 'unknown' }
  }
  $sig = Get-CircuitHash ($class + ':' + $key)
  return [pscustomobject]@{ class = $class; signature = $sig }
}

function Test-CircuitTrip {
  param(
    [string]$LogPath = '',
    [int]$WindowMin = 30,
    [int]$MaxRestarts = 5,
    [datetime]$Now = (Get-Date)
  )
  if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Get-RestartsLogPath }
  $events = @()
  $invalidLines = 0
  if (Test-Path -LiteralPath $LogPath) {
    $nowUtc = ([datetime]$Now).ToUniversalTime()
    $cutoff = $nowUtc.AddMinutes(-1 * [Math]::Max(1, $WindowMin))
    foreach ($raw in (Read-CircuitLogLines -LogPath $LogPath)) {
      try {
        $line = Remove-CircuitLineBom $raw
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $e = $line | ConvertFrom-Json
        $ts = ([DateTimeOffset]::Parse([string]$e.ts)).UtcDateTime
        if ($ts -ge $cutoff -and $ts -le $nowUtc.AddMinutes(1)) {
          $cause = [string]$e.cause
          $sig = [string]$e.signature
          $events += [pscustomobject]@{
            ts        = $ts
            cause     = $cause
            signature = $sig
            pairKey   = ($cause + "`t" + $sig)
          }
        }
      } catch { $invalidLines++ }
    }
  }
  $count = @($events).Count
  $dominantCause = ''
  $dominantSignature = ''
  $dominantSignatureCause = ''
  $sameRatio = 0.0
  if ($count -gt 0) {
    $cg = @($events | Group-Object cause | Sort-Object Count -Descending | Select-Object -First 1)
    if ($cg.Count -gt 0) { $dominantCause = [string]$cg[0].Name }
    $pg = @($events | Group-Object pairKey | Sort-Object Count -Descending | Select-Object -First 1)
    if ($pg.Count -gt 0) {
      $pair = ([string]$pg[0].Name) -split "`t", 2
      if ($pair.Count -gt 0) { $dominantSignatureCause = [string]$pair[0] }
      if ($pair.Count -gt 1) { $dominantSignature = [string]$pair[1] }
      $sameRatio = [Math]::Round(([double]$pg[0].Count / [double]$count), 3)
    }
  }
  return [pscustomobject]@{
    tripped                = ($count -ge [Math]::Max(1, $MaxRestarts))
    countInWindow          = $count
    dominantCause          = $dominantCause
    dominantSignature      = $dominantSignature
    dominantSignatureCause = $dominantSignatureCause
    sameSignatureRatio     = $sameRatio
    invalidLineCount       = $invalidLines
  }
}

function Get-CircuitMode {
  param($Trip)
  if (-not $Trip -or -not [bool]$Trip.tripped) { return 'allow' }
  $deterministic = @('parse-fail','state-corrupt')
  $cause = [string]$Trip.dominantCause
  try {
    if (($Trip.PSObject.Properties.Name -contains 'dominantSignatureCause') -and -not [string]::IsNullOrWhiteSpace([string]$Trip.dominantSignatureCause)) {
      $cause = [string]$Trip.dominantSignatureCause
    }
  } catch {}
  $ratio = 0.0
  try { $ratio = [double]$Trip.sameSignatureRatio } catch {}
  if (($deterministic -contains $cause) -and $ratio -ge 0.8) { return 'hard-freeze' }
  return 'cooldown'
}

function Format-CircuitNativeArg {
  param([AllowNull()][string]$Value)
  $v = [string]$Value
  if ($v.Length -eq 0) { return '""' }
  if ($v -notmatch '[\s"]') { return $v }
  return '"' + ($v -replace '"','\"') + '"'
}

function Invoke-CircuitGitCapture {
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string[]]$Arguments,
    [Parameter(Mandatory=$true)][string]$OutPath
  )
  $enc = New-Object System.Text.UTF8Encoding($false)
  $files = New-Object 'System.Collections.Generic.List[string]'
  $stderrPath = $OutPath + '.stderr.txt'
  try {
    if (Test-Path -LiteralPath $stderrPath) { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.WorkingDirectory = $Root
    $psi.Arguments = (($Arguments | ForEach-Object { Format-CircuitNativeArg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    $exitCode = $p.ExitCode
    try { $p.Dispose() } catch {}
    [System.IO.File]::WriteAllText($OutPath, [string]$stdout, $enc)
    [void]$files.Add($OutPath)
    if ((-not [string]::IsNullOrWhiteSpace($stderr)) -or $exitCode -ne 0) {
      $errText = "exitCode: $exitCode`n" + [string]$stderr
      [System.IO.File]::WriteAllText($stderrPath, $errText, $enc)
      [void]$files.Add($stderrPath)
    }
    return [pscustomobject]@{ ok = ($exitCode -eq 0); outPath = $OutPath; stderrPath = $(if (Test-Path -LiteralPath $stderrPath) { $stderrPath } else { '' }); files = @($files) }
  } catch {
    [System.IO.File]::WriteAllText($OutPath, '', $enc)
    [System.IO.File]::WriteAllText($stderrPath, $_.Exception.Message, $enc)
    [void]$files.Add($OutPath)
    [void]$files.Add($stderrPath)
    return [pscustomobject]@{ ok = $false; outPath = $OutPath; stderrPath = $stderrPath; files = @($files) }
  }
}

function Save-CircuitDiagnostics {
  param([Parameter(Mandatory=$true)][string]$OutDir)
  $files = New-Object 'System.Collections.Generic.List[string]'
  try {
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $root = Get-BridgeRoot
    $statusPath = Join-Path $OutDir 'git-status.txt'
    $diffPath = Join-Path $OutDir 'git-diff.patch'
    $statusCapture = Invoke-CircuitGitCapture -Root $root -Arguments @('status','--short') -OutPath $statusPath
    foreach ($f in @($statusCapture.files)) { if ($f) { [void]$files.Add([string]$f) } }
    $diffCapture = Invoke-CircuitGitCapture -Root $root -Arguments @('diff','--binary','--no-color') -OutPath $diffPath
    foreach ($f in @($diffCapture.files)) { if ($f) { [void]$files.Add([string]$f) } }

    $snapDir = Join-Path $OutDir 'snapshots'
    if (-not (Test-Path -LiteralPath $snapDir)) { New-Item -ItemType Directory -Path $snapDir -Force | Out-Null }
    $snap = $null
    try {
      if (Get-Command Save-StateSnapshot -ErrorAction SilentlyContinue) { $snap = Save-StateSnapshot -Reason 'circuit_breaker' }
    } catch {}
    if ($snap -and (Test-Path -LiteralPath $snap)) {
      $dst = Join-Path $snapDir (Split-Path -Leaf $snap)
      Copy-Item -LiteralPath $snap -Destination $dst -Force
      [void]$files.Add($dst)
    }
    $legacy = Join-Path $root 'state.json'
    if (Test-Path -LiteralPath $legacy) {
      $dst = Join-Path $snapDir 'state.root.json'
      Copy-Item -LiteralPath $legacy -Destination $dst -Force
      [void]$files.Add($dst)
    }
    $channels = Join-Path $root 'channels'
    if (Test-Path -LiteralPath $channels) {
      Get-ChildItem -LiteralPath $channels -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $sp = Join-Path $_.FullName 'state.json'
        if (Test-Path -LiteralPath $sp) {
          $dst = Join-Path $snapDir ("state." + $_.Name + ".json")
          Copy-Item -LiteralPath $sp -Destination $dst -Force
          [void]$files.Add($dst)
        }
      }
    }
    return [pscustomobject]@{ ok = $true; outDir = $OutDir; files = @($files); error = '' }
  } catch {
    return [pscustomobject]@{ ok = $false; outDir = $OutDir; files = @($files); error = $_.Exception.Message }
  }
}

function Invoke-HealthProbe {
  # 2026-05-30 DEADLOCK FIX. The probe gates resume from circuit-breaker cooldown.
  # Previously ANY of {parse-fail (recursive over ALL .ps1), state-unreadable, disk}
  # made it red -> cooldown extended forever. But:
  #   * state.json corruption is what the SERVER repairs on spawn -> blocking resume
  #     on it created a deadlock (cooldown -> no server -> state stays corrupt ->
  #     probe red -> cooldown). So state issues are now WARNINGS, not blockers.
  #   * recursive scan let a broken .ps1 in canary-worktree/sandbox/projects (not even
  #     part of the running bridge) wedge the probe. Scope to CORE files only.
  # Only a real, fatal condition blocks resume now: a CORE .ps1 won't parse (would
  # crash-loop) or the bridge root is gone (real disk failure).
  $blockers = New-Object 'System.Collections.Generic.List[string]'
  $warnings = New-Object 'System.Collections.Generic.List[string]'
  try {
    $root = Get-BridgeRoot
    $coreFiles = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) { [void]$coreFiles.Add($f.FullName) }
    foreach ($sub in @('lib','tools')) {
      $sd = Join-Path $root $sub
      if (Test-Path -LiteralPath $sd) { foreach ($f in @(Get-ChildItem -LiteralPath $sd -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) { [void]$coreFiles.Add($f.FullName) } }
    }
    foreach ($fp in $coreFiles) {
      $tokens = $null; $errors = $null
      [System.Management.Automation.Language.Parser]::ParseFile($fp, [ref]$tokens, [ref]$errors) | Out-Null
      if ($errors -and $errors.Count -gt 0) { [void]$blockers.Add("parse-fail: $([System.IO.Path]::GetFileName($fp))") }
    }
  } catch {
    [void]$warnings.Add("parse-probe-error: $($_.Exception.Message)")
  }
  # state.json: WARNING only -- the server recreates/repairs it on spawn.
  try {
    $s = Read-State
    if ($null -eq $s) { [void]$warnings.Add('state-unreadable (server recreates on spawn)') }
  } catch {
    [void]$warnings.Add("state-read-error: $($_.Exception.Message)")
  }
  # bridge root gone is a real, blocking disk failure.
  try {
    $rootItem = Get-Item -LiteralPath (Get-BridgeRoot) -ErrorAction Stop
    if (-not $rootItem.Exists) { [void]$blockers.Add('bridge-root-missing') }
  } catch {
    [void]$blockers.Add("disk-probe-error: $($_.Exception.Message)")
  }
  $green = ($blockers.Count -eq 0)
  $reason = if ($green) { if ($warnings.Count -gt 0) { 'ok (warnings: ' + ($warnings -join '; ') + ')' } else { 'ok' } } else { ($blockers -join '; ') }
  return [pscustomobject]@{ green = $green; reason = $reason }
}

function Get-CircuitRecentErrLog {
  param([Parameter(Mandatory=$true)][string]$ControlDir)
  $parts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($p in @(Join-Path $ControlDir 'server.err.log')) {
    if (Test-Path -LiteralPath $p) {
      try { [void]$parts.Add(((Get-Content -LiteralPath $p -Tail 80 -ErrorAction Stop) -join "`n")) } catch {}
    }
  }
  try {
    Get-ChildItem -LiteralPath $ControlDir -Filter 'driver.*.err.log' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 5 |
      ForEach-Object {
        try { [void]$parts.Add(((Get-Content -LiteralPath $_.FullName -Tail 80 -ErrorAction Stop) -join "`n")) } catch {}
      }
  } catch {}
  return ($parts -join "`n")
}

function Get-CircuitStateAttempts {
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [string[]]$Slugs = @('main')
  )
  $max = 0
  try {
    foreach ($slug in $Slugs) {
      $p = Join-Path $Root ("channels\" + $slug + "\state.json")
      if (-not (Test-Path -LiteralPath $p)) { continue }
      try {
        $s = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($s -and ($s.PSObject.Properties.Name -contains 'task_restart_count')) {
          $v = [int]$s.task_restart_count
          if ($v -gt $max) { $max = $v }
        }
      } catch {}
    }
  } catch {}
  return $max
}

function Invoke-CircuitCallback {
  param([scriptblock]$Callback, [string]$Text)
  if ($Callback) {
    try { & $Callback $Text } catch {}
  }
}

function Invoke-CircuitPauseAction {
  param(
    $Trip,
    $Settings,
    [Parameter(Mandatory=$true)][string]$FreezeFlagPath,
    [scriptblock]$LogCallback = $null,
    [scriptblock]$MessageCallback = $null,
    [scriptblock]$PushCallback = $null
  )
  $result = [ordered]@{ mode = 'allow'; cooldownUntil = $null; diagnostics = ''; frozen = $false }
  try {
    $mode = Get-CircuitMode -Trip $Trip
    $result.mode = $mode
    $diagDir = Join-Path (Get-RuntimeRoot) ("circuit-breaker." + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $result.diagnostics = $diagDir
    try { Save-CircuitDiagnostics -OutDir $diagDir | Out-Null }
    catch { Invoke-CircuitCallback -Callback $LogCallback -Text ("circuit diagnostics error: " + $_.Exception.Message) }

    if ($mode -eq 'hard-freeze') {
      if (-not (Test-Path -LiteralPath $FreezeFlagPath)) {
        $msg = "Circuit-breaker: $($Trip.countInWindow) restarts/$($Settings.windowMin)min; dominantCause=$($Trip.dominantCause); signature=$($Trip.dominantSignature); diagnostics=$diagDir"
        [System.IO.File]::WriteAllText($FreezeFlagPath, $msg, (New-Object System.Text.UTF8Encoding($false)))
        $line = "🛑 Circuit-breaker: $($Trip.countInWindow) рестартов/$($Settings.windowMin)мин, доминирующая причина: $($Trip.dominantCause). Мост заморожен, жду оператора. Снять: удалить control/cb-freeze.flag"
        Invoke-CircuitCallback -Callback $MessageCallback -Text $line
        Invoke-CircuitCallback -Callback $PushCallback -Text $line
        Invoke-CircuitCallback -Callback $LogCallback -Text $msg
      }
      $result.frozen = $true
    } elseif ($mode -eq 'cooldown') {
      $mins = [Math]::Min(30, [Math]::Max(10, [int]$Settings.cooldownMin))
      $until = (Get-Date).AddMinutes($mins)
      $result.cooldownUntil = $until
      $line = "Circuit-breaker cooldown: $($Trip.countInWindow) restarts/$($Settings.windowMin)min; dominantCause=$($Trip.dominantCause); resumeProbeAt=$($until.ToString('o')); diagnostics=$diagDir"
      Invoke-CircuitCallback -Callback $MessageCallback -Text $line
      Invoke-CircuitCallback -Callback $LogCallback -Text $line
    }
  } catch {
    Invoke-CircuitCallback -Callback $LogCallback -Text ("circuit pause error (fail-safe allow restart): " + $_.Exception.Message)
  }
  return [pscustomobject]$result
}

function Invoke-CircuitRestartRecord {
  param(
    [Parameter(Mandatory=$true)][string]$ControlDir,
    [Parameter(Mandatory=$true)][string]$Root,
    [string[]]$Slugs = @('main'),
    [string]$Detail = '',
    [bool]$ReapFired = $false,
    [bool]$FlagPresent = $false,
    [Parameter(Mandatory=$true)][string]$FreezeFlagPath,
    [scriptblock]$LogCallback = $null,
    [scriptblock]$MessageCallback = $null,
    [scriptblock]$PushCallback = $null
  )
  $out = [ordered]@{ event = $null; tripped = $false; mode = 'allow'; cooldownUntil = $null }
  try {
    $settings = Get-CircuitBreakerSettings
    $cause = Get-RestartCause -RecentErrLog (Get-CircuitRecentErrLog -ControlDir $ControlDir) -ReapFired:$ReapFired -FlagPresent:$FlagPresent -StateAttempts (Get-CircuitStateAttempts -Root $Root -Slugs $Slugs)
    $out.event = Write-RestartEvent -Cause $cause.class -Signature $cause.signature -Detail $Detail
    if ([bool]$settings.enabled) {
      $trip = Test-CircuitTrip -WindowMin ([int]$settings.windowMin) -MaxRestarts ([int]$settings.maxRestarts)
      $out.tripped = [bool]$trip.tripped
      if ($trip.tripped) {
        $pause = Invoke-CircuitPauseAction -Trip $trip -Settings $settings -FreezeFlagPath $FreezeFlagPath -LogCallback $LogCallback -MessageCallback $MessageCallback -PushCallback $PushCallback
        $out.mode = [string]$pause.mode
        $out.cooldownUntil = $pause.cooldownUntil
      }
    }
  } catch {
    Invoke-CircuitCallback -Callback $LogCallback -Text ("circuit record error (fail-safe allow restart): " + $_.Exception.Message)
  }
  return [pscustomobject]$out
}

function Test-CircuitSpawnPauseState {
  param(
    [Parameter(Mandatory=$true)][string]$FreezeFlagPath,
    [AllowNull()][Nullable[datetime]]$CooldownUntil,
    [scriptblock]$LogCallback = $null,
    [scriptblock]$MessageCallback = $null
  )
  $out = [ordered]@{ paused = $false; cooldownUntil = $CooldownUntil }
  try {
    if (Test-Path -LiteralPath $FreezeFlagPath) { $out.paused = $true; return [pscustomobject]$out }
    if ($CooldownUntil) {
      $now = Get-Date
      if ($now -lt $CooldownUntil) { $out.paused = $true; return [pscustomobject]$out }
      $probe = Invoke-HealthProbe
      $extFile = Join-Path (Split-Path -Parent $FreezeFlagPath) 'cb-cooldown-extensions'
      if ($probe.green) {
        try { if (Test-Path -LiteralPath $extFile) { Remove-Item -LiteralPath $extFile -Force -ErrorAction SilentlyContinue } } catch {}
        Invoke-CircuitCallback -Callback $LogCallback -Text "circuit cooldown expired; health probe green -> resume"
        Invoke-CircuitCallback -Callback $MessageCallback -Text "Circuit-breaker: health-probe зелёный, возобновляю server/driver."
        $out.cooldownUntil = $null
        return [pscustomobject]$out
      }
      # 2026-05-30 FAILSAFE: a stuck-red probe must NOT keep the bridge dead forever
      # (the deadlock we just hit). After 3 extensions (~45 min), force-resume anyway
      # and escalate to the operator -- a live bridge with a warning beats a dead one.
      $extCount = 0
      try { if (Test-Path -LiteralPath $extFile) { $extCount = [int]((Get-Content -LiteralPath $extFile -Raw -ErrorAction SilentlyContinue).Trim()) } } catch { $extCount = 0 }
      $extCount++
      if ($extCount -ge 3) {
        try { if (Test-Path -LiteralPath $extFile) { Remove-Item -LiteralPath $extFile -Force -ErrorAction SilentlyContinue } } catch {}
        Invoke-CircuitCallback -Callback $LogCallback -Text ("circuit FAILSAFE force-resume after " + $extCount + " extensions; probe still not green: " + $probe.reason)
        Invoke-CircuitCallback -Callback $MessageCallback -Text ("Circuit-breaker: 3 продления подряд, health-probe не зелёный (" + $probe.reason + "). FAILSAFE — поднимаю мост принудительно, проверь причину.")
        $out.cooldownUntil = $null
        return [pscustomobject]$out
      }
      try { Set-Content -LiteralPath $extFile -Value ([string]$extCount) -Encoding ASCII -ErrorAction SilentlyContinue } catch {}
      $settings = Get-CircuitBreakerSettings
      $mins = [Math]::Min(30, [Math]::Max(10, [int]$settings.cooldownMin))
      $out.cooldownUntil = $now.AddMinutes($mins)
      $out.paused = $true
      Invoke-CircuitCallback -Callback $LogCallback -Text ("circuit cooldown extended (#" + $extCount + "/3); health probe not green: " + $probe.reason)
      Invoke-CircuitCallback -Callback $MessageCallback -Text ("Circuit-breaker: health-probe не зелёный (" + $probe.reason + "), продлеваю cooldown (#" + $extCount + "/3).")
    }
  } catch {
    Invoke-CircuitCallback -Callback $LogCallback -Text ("circuit pause check error (fail-safe allow restart): " + $_.Exception.Message)
    $out.paused = $false
  }
  return [pscustomobject]$out
}
