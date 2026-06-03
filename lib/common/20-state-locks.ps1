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

function Get-DecisionsPath { Resolve-BridgeContainedPath -Path 'decisions' -Purpose 'decisions directory' }

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

function Read-StateJsonRawValidated {
  # Raw read+parse without calling Read-State/Write-State — safe on the recovery path (no recursion).
  param([string]$Path)
  if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return ($text | ConvertFrom-Json)
  } catch { return $null }
}

function Restore-StateFromBackup {
  # Recover state.json from the write-through backup (.bak file).
  # Uses raw helpers only — does NOT call Read-State or Write-State (no recursion).
  # Returns restored PSObject on success; $null if backup is missing, invalid, or restore write failed.
  $statePath  = Get-StatePath
  $backupPath = $statePath + '.bak'
  $bak = Read-StateJsonRawValidated -Path $backupPath
  if ($null -eq $bak) { return $null }
  $check = Test-StateShape -State $bak
  if (-not $check.ok) {
    try {
      $alog = Join-Path (Get-BridgeRoot) 'control\state-guard.log'
      Add-Content -LiteralPath $alog -Value ("{0}  BACKUP-INVALID shape-fail: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $check.reason) -Encoding utf8 -ErrorAction SilentlyContinue
    } catch {}
    return $null
  }
  try {
    $json = $bak | ConvertTo-Json -Depth 10
    Write-AtomicFile -Path $statePath -Content $json
  } catch { return $null }
  return $bak
}

function Read-State {
  # FIX 2026-05-27: shape-guard — broken state forces Initialize-Bridge recreate.
  # FIX 2026-05-30: 3×50ms retry-backoff on transient parse-fail before returning $null;
  #   on real corruption quarantines bytes + tries Restore-StateFromBackup before defaults.
  #   Protects all ~40 call-sites, not only driver:3178.
  $p = Get-StatePath
  if (-not (Test-Path $p)) { return $null }
  $state = $null
  $maxRetry = 3; $retryMs = 50
  for ($attempt = 1; $attempt -le $maxRetry; $attempt++) {
    try {
      $state = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
      break
    } catch {
      if ($attempt -lt $maxRetry) {
        Start-Sleep -Milliseconds $retryMs
      } else {
        # All retries exhausted: quarantine corrupt bytes for forensics, then try backup
        try {
          $qDir = Join-Path (Get-BridgeRoot) 'control\quarantine'
          if (-not (Test-Path -LiteralPath $qDir)) { New-Item -ItemType Directory -Path $qDir -Force | Out-Null }
          $qFile = Join-Path $qDir ("state-corrupt-$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
          Copy-Item -LiteralPath $p -Destination $qFile -Force -ErrorAction SilentlyContinue
          $alog = Join-Path (Get-BridgeRoot) 'control\state-guard.log'
          Add-Content -LiteralPath $alog -Value ("{0}  PARSE-FAIL quarantined to $qFile — trying backup" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding utf8 -ErrorAction SilentlyContinue
        } catch {}
        $restored = Restore-StateFromBackup
        if ($null -ne $restored) { return $restored }
        return $null  # degrade: Initialize-Bridge defaults (same as current behaviour)
      }
    }
  }
  if ($null -eq $state) { return $null }
  $check = Test-StateShape -State $state
  if (-not $check.ok) {
    try {
      $alog = Join-Path (Get-BridgeRoot) 'control\state-guard.log'
      Add-Content -LiteralPath $alog -Value ("{0}  BROKEN-DETECTED {1} — trying backup before defaults" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $check.reason) -Encoding utf8 -ErrorAction SilentlyContinue
    } catch {}
    $restored = Restore-StateFromBackup
    if ($null -ne $restored) { return $restored }
    return $null
  }
  return $state
}

function Test-StateShape {
  # Verify a state object has the minimum critical fields. Used as gate by Write-State to
  # reject partial/replacement-style writes that would wipe runtime state.
  # FIX 2026-05-27: yesterday a Codex-experimental script wrote @{parallel_streams=@()} as
  # FULL state replacement -- nuked status/lastSeq/heartbeat/current_task. Driver couldn't
  # boot. State.json now only accepts writes that PRESERVE these critical fields.
  param($State)
  if ($null -eq $State) { return @{ ok=$false; reason='null state' } }
  $required = @('status','lastSeq','paused','stop','abort','heartbeat')
  $missing = New-Object 'System.Collections.Generic.List[string]'
  foreach ($f in $required) {
    $has = $false
    try { $has = ($State.PSObject.Properties.Name -contains $f) } catch {}
    if (-not $has) { [void]$missing.Add($f) }
  }
  if ($missing.Count -gt 0) {
    return @{ ok=$false; reason=('missing critical fields: ' + ($missing -join ',')) }
  }
  return @{ ok=$true; reason='' }
}

function Write-State {
  param($State, [switch]$AllowPartial)
  # FIX 2026-05-27: guard against state-wipe. Reject writes that lack minimum runtime fields,
  # UNLESS explicit -AllowPartial (only Initialize-Bridge default-create branch uses this).
  if (-not $AllowPartial) {
    $check = Test-StateShape -State $State
    if (-not $check.ok) {
      $msg = "Write-State refused: $($check.reason). Use Update-State+Add-Member for mutations; only Initialize-Bridge -Reset may use -AllowPartial."
      try {
        $alog = Join-Path (Get-BridgeRoot) 'control\state-guard.log'
        Add-Content -LiteralPath $alog -Value ("{0}  REFUSED {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $check.reason) -Encoding utf8 -ErrorAction SilentlyContinue
      } catch {}
      throw $msg
    }
  }
  $json = $State | ConvertTo-Json -Depth 10
  $sp = Get-StatePath
  Write-AtomicFile -Path $sp -Content $json
  # Write-through backup (best-effort: fail = warning only, not rollback of the main write).
  # M1 (load audit): throttle the .bak to ~10s. It used to be written on EVERY state write -- but
  # heartbeat ticks (~every 5s x N drivers) dominate, doubling the work done INSIDE the bridge lock
  # and feeding the 15s-timeout contention under load. The live state.json is always current; the
  # crash backup only needs to be RECENT, so skip it when a fresh .bak already exists.
  try {
    $bakPath = $sp + '.bak'
    $bakFresh = $false
    if (Test-Path -LiteralPath $bakPath) {
      try { $bakFresh = (((Get-Date) - (Get-Item -LiteralPath $bakPath).LastWriteTime).TotalSeconds -lt 10) } catch {}
    }
    if (-not $bakFresh) { Write-AtomicFile -Path $bakPath -Content $json }
  } catch {
    try {
      $alog = Join-Path (Get-BridgeRoot) 'control\state-guard.log'
      Add-Content -LiteralPath $alog -Value ("{0}  BACKUP-WARN write failed: $($_.Exception.Message)" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding utf8 -ErrorAction SilentlyContinue
    } catch {}
    # Do NOT rethrow — main write succeeded; backup is best-effort
  }
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

function Get-RuntimeStateMetrics {
  $root = Get-BridgeRoot
  $runtime = Get-RuntimeRoot
  $channelNames = @{}
  foreach ($base in @((Join-Path $root 'channels'), (Join-Path $runtime 'channels'))) {
    if (-not (Test-Path -LiteralPath $base)) { continue }
    try {
      Get-ChildItem -LiteralPath $base -Directory -ErrorAction Stop | ForEach-Object {
        $channelNames[[string]$_.Name] = $true
      }
    } catch {}
  }

  $statePaths = @{}
  foreach ($candidate in @((Join-Path $root 'state.json'), (Join-Path $runtime 'state.json'))) {
    if (Test-Path -LiteralPath $candidate) { $statePaths[[string](Resolve-Path -LiteralPath $candidate)] = $true }
  }
  foreach ($base in @((Join-Path $root 'channels'), (Join-Path $runtime 'channels'))) {
    if (-not (Test-Path -LiteralPath $base)) { continue }
    try {
      Get-ChildItem -LiteralPath $base -Directory -ErrorAction Stop | ForEach-Object {
        $sp = Join-Path $_.FullName 'state.json'
        if (Test-Path -LiteralPath $sp) { $statePaths[[string](Resolve-Path -LiteralPath $sp)] = $true }
      }
    } catch {}
  }

  $stateBytes = [long]0
  foreach ($p in $statePaths.Keys) {
    try { $stateBytes += [long](Get-Item -LiteralPath $p -ErrorAction Stop).Length } catch {}
  }

  $locks = 0
  try {
    if (Test-Path -LiteralPath $runtime) {
      $locks = @((Get-ChildItem -LiteralPath $runtime -Recurse -Filter '*.lock' -File -ErrorAction SilentlyContinue)).Count
    }
  } catch { $locks = 0 }

  $jobs = 0
  $jobsDir = Join-Path $runtime 'jobs'
  try {
    if (Test-Path -LiteralPath $jobsDir) {
      $jobs = @((Get-ChildItem -LiteralPath $jobsDir -Recurse -File -ErrorAction SilentlyContinue)).Count
    }
  } catch { $jobs = 0 }

  $checkpoints = 0
  $checkpointsDir = Join-Path $runtime 'checkpoints'
  try {
    if (Test-Path -LiteralPath $checkpointsDir) {
      $checkpoints = @((Get-ChildItem -LiteralPath $checkpointsDir -Recurse -File -ErrorAction SilentlyContinue)).Count
    }
  } catch { $checkpoints = 0 }

  $restartsHour = 0
  $restartsPath = Join-Path $runtime 'restarts.jsonl'
  if (Test-Path -LiteralPath $restartsPath) {
    $cutoff = [DateTimeOffset]::UtcNow.AddHours(-1)
    try {
      foreach ($line in [System.IO.File]::ReadLines($restartsPath)) {
        $s = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        try {
          $e = $s | ConvertFrom-Json
          if ($e -and $e.ts) {
            $ts = [DateTimeOffset]::Parse([string]$e.ts)
            if ($ts.UtcDateTime -ge $cutoff.UtcDateTime) { $restartsHour++ }
          }
        } catch {}
      }
    } catch {}
  }

  return [pscustomobject]@{
    channels     = [int]$channelNames.Count
    stateKb      = [int][Math]::Ceiling([double]$stateBytes / 1024.0)
    locks        = [int]$locks
    jobs         = [int]$jobs
    checkpoints  = [int]$checkpoints
    restartsHour = [int]$restartsHour
  }
}

function Get-ProbeTimeoutDefaults {
  return [pscustomobject]@{
    minMs   = 120000
    baseMs  = 180000
    maxMs   = 900000
    metrics = [pscustomobject]@{
      channels     = [pscustomobject]@{ weight = 10000; capMs = 90000 }
      stateKb      = [pscustomobject]@{ weight = 120;   capMs = 180000 }
      locks        = [pscustomobject]@{ weight = 15000; capMs = 120000 }
      jobs         = [pscustomobject]@{ weight = 5000;  capMs = 180000 }
      checkpoints  = [pscustomobject]@{ weight = 8000;  capMs = 180000 }
      restartsHour = [pscustomobject]@{ weight = 45000; capMs = 270000 }
    }
  }
}

function Get-ConfigIntValue {
  param($Object, [string]$Name, [int]$Default)
  try {
    if ($Object -and ($Object.PSObject.Properties.Name -contains $Name) -and $null -ne $Object.$Name) {
      $v = [int]$Object.$Name
      if ($v -ge 0) { return $v }
    }
  } catch {}
  return $Default
}

function Get-AdaptiveProbeTimeoutMs {
  param($Metrics = $null, [int]$CoderTimeoutMs = 0, $ProbeTimeoutConfig = $null)
  if ($null -eq $Metrics) { $Metrics = Get-RuntimeStateMetrics }

  $defaults = Get-ProbeTimeoutDefaults
  $cfg = $null
  try { $cfg = Get-BridgeConfig } catch {}
  $pt = $ProbeTimeoutConfig
  if ($null -eq $pt -and $cfg -and ($cfg.PSObject.Properties.Name -contains 'probeTimeout')) { $pt = $cfg.probeTimeout }

  $minMs = Get-ConfigIntValue -Object $pt -Name 'minMs' -Default ([int]$defaults.minMs)
  $baseMs = Get-ConfigIntValue -Object $pt -Name 'baseMs' -Default ([int]$defaults.baseMs)
  $maxMs = Get-ConfigIntValue -Object $pt -Name 'maxMs' -Default ([int]$defaults.maxMs)

  if ($CoderTimeoutMs -le 0) {
    $CoderTimeoutMs = Get-ConfigIntValue -Object $cfg -Name 'coderTimeoutMs' -Default 900000
  }
  if ($CoderTimeoutMs -gt 0) { $maxMs = [Math]::Min($maxMs, $CoderTimeoutMs) }
  if ($maxMs -lt 1) { $maxMs = [int]$defaults.maxMs }
  if ($minMs -lt 1) { $minMs = [int]$defaults.minMs }
  if ($minMs -gt $maxMs) { $minMs = $maxMs }
  if ($baseMs -lt 0) { $baseMs = [int]$defaults.baseMs }

  $score = [double]$baseMs
  $metricCfg = $null
  if ($pt -and ($pt.PSObject.Properties.Name -contains 'metrics')) { $metricCfg = $pt.metrics }
  foreach ($name in @('channels','stateKb','locks','jobs','checkpoints','restartsHour')) {
    $def = $defaults.metrics.$name
    $mc = $null
    if ($metricCfg -and ($metricCfg.PSObject.Properties.Name -contains $name)) { $mc = $metricCfg.$name }
    $weight = Get-ConfigIntValue -Object $mc -Name 'weight' -Default ([int]$def.weight)
    $capMs = Get-ConfigIntValue -Object $mc -Name 'capMs' -Default ([int]$def.capMs)
    $value = 0
    try {
      if ($Metrics -and ($Metrics.PSObject.Properties.Name -contains $name) -and $null -ne $Metrics.$name) {
        $value = [double]$Metrics.$name
      }
    } catch { $value = 0 }
    if ($value -lt 0) { $value = 0 }
    $score += [Math]::Min(([double]$weight * $value), [double]$capMs)
  }

  $clamped = [Math]::Max([double]$minMs, [Math]::Min($score, [double]$maxMs))
  return [int][Math]::Round($clamped)
}

function Test-IsProbeTask {
  param([string]$Prompt = '', [string]$Command = '', [string[]]$Tags = @())
  foreach ($tag in @($Tags)) {
    $t = ([string]$tag).Trim().ToLowerInvariant()
    if ($t -eq 'probe' -or $t -eq 'diag') { return $true }
  }

  $promptScope = [string]$Prompt
  try {
    $m = [regex]::Match(
      $promptScope,
      '(?s)(?:ТЕКУЩАЯ ЗАДАЧА ОТ ПОЛЬЗОВАТЕЛЯ:|ЗАДАЧА ОТ ОПЕРАТОРА:)\s*(.*?)(?:\r?\n(?:ОБЛАСТЬ|РОЛИ:|ПРАВИЛА:|ДИАЛОГ:|===|ПЛАН ЗАДАЧИ:)|\z)'
    )
    if ($m.Success) { $promptScope = [string]$m.Groups[1].Value }
  } catch {}

  $hay = ($promptScope + "`n" + ([string]$Command)).ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($hay)) { return $false }
  if ($hay -match '(?i)(^|[^\p{L}\p{N}_-])probe(?:\s+|[-‑–—])(?:task|tasks|job|jobs|задач|провер|диаг|diag|health)\b') { return $true }
  if ($hay -match '(?i)\bproof-probe\b') { return $true }
  if ($hay -match '(?i)tools[\\/]+diag[\\/]+[^\s''"]*-probe\.ps1\b') { return $true }
  if (-not [string]::IsNullOrWhiteSpace($Command) -and ([string]$Command).ToLowerInvariant() -match '(?i)(^|[\\/])[^\\/]*-probe\.ps1\b') { return $true }
  return $false
}

function Write-ProbeDuration {
  param(
    [int]$ComputedTimeoutMs,
    [int]$ActualDurationMs,
    $Metrics,
    [string]$Exit = 'unknown',
    [string]$Verdict = ''
  )
  $runtime = Get-RuntimeRoot
  if (-not (Test-Path -LiteralPath $runtime)) { New-Item -ItemType Directory -Path $runtime -Force | Out-Null }
  $path = Join-Path $runtime 'probe-durations.jsonl'
  $rec = [pscustomobject]@{
    ts                  = (Get-Date).ToUniversalTime().ToString('o')
    computed_timeout_ms = [int]$ComputedTimeoutMs
    actual_duration_ms  = [int]$ActualDurationMs
    metrics             = $Metrics
    exit                = [string]$Exit
    verdict             = [string]$Verdict
  }
  $line = ($rec | ConvertTo-Json -Compress -Depth 8)
  Use-BridgeLock {
    try {
      [System.IO.File]::AppendAllText($path, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {
      $old = ''
      if (Test-Path -LiteralPath $path) {
        try { $old = Get-Content -LiteralPath $path -Raw -Encoding UTF8 } catch { $old = '' }
      }
      if (-not [string]::IsNullOrEmpty($old) -and -not $old.EndsWith("`n")) { $old += "`n" }
      Write-AtomicFile -Path $path -Content ($old + $line + "`n")
    }
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

