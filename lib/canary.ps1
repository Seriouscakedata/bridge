# canary.ps1 -- idle-safe bridge heartbeat foundation.

function New-DefaultCanaryState {
  [pscustomobject]@{
    last_heartbeat_at    = $null
    last_outcome         = 'unknown'
    consecutive_failures = 0
    quarantine_until     = $null
    total_heartbeats     = 0
    total_failures       = 0
  }
}

# FIX 2026-05-28: canary_state recursive-nesting bug. Historically, a buggy read-modify-write
# seeded a canary_state property INSIDE the canary_state sub-object; since Get/Set neither
# stripped it nor whitelisted fields, the nesting persisted on disk (state.json bloated to
# ~1290 lines, capped only by ConvertTo-Json -Depth 10). This helper rebuilds a clean state
# carrying ONLY the canonical fields, copying values where present -- dropping any nested
# canary_state or other junk. Used on BOTH read and write so nesting can never recur.
function ConvertTo-CleanCanaryState {
  param($Source)
  $clean = New-DefaultCanaryState
  if ($Source) {
    foreach ($p in $clean.PSObject.Properties.Name) {
      $has = $false
      try { $has = ($Source.PSObject.Properties.Name -contains $p) } catch {}
      if ($has) { $clean.$p = $Source.$p }
    }
  }
  return $clean
}

function Get-CanaryConfig {
  $def = [ordered]@{
    enabled            = $true
    intervalHours      = 6
    cooldownMinutes    = 30
    llmModel           = 'gemini-2.5-flash-lite'
    quarantineFailures = 2
    quarantineHours    = 12
    worktreePath       = 'C:\Users\rafie\OneDrive\Documents\bridge-canary-worktree'
    branchName         = 'canary/heartbeat'
  }

  $cfg = $null
  try { $cfg = Get-BridgeConfig } catch {}
  if ($cfg -and $cfg.canary) {
    foreach ($k in $def.Keys) {
      if (-not ($cfg.canary.PSObject.Properties.Name -contains $k)) {
        $cfg.canary | Add-Member -NotePropertyName $k -NotePropertyValue $def[$k] -Force
      }
    }
    return $cfg.canary
  }

  return [pscustomobject]$def
}

function Get-CanaryState {
  $st = $null
  try { $st = Read-State } catch {}
  if (-not $st -or -not $st.canary_state) { return (New-DefaultCanaryState) }

  # Whitelist-rebuild: fills missing fields with defaults AND strips any nested canary_state
  # or other junk that historical buggy writes may have left on disk.
  return (ConvertTo-CleanCanaryState -Source $st.canary_state)
}

function Set-CanaryState {
  param($State)

  # Persist ONLY the canonical fields. Even if $State carries a nested canary_state (e.g. it
  # was read from a still-bloated disk), the clean rebuild guarantees a single flat level.
  $clean = ConvertTo-CleanCanaryState -Source $State

  if (Get-Command Update-State -ErrorAction SilentlyContinue) {
    Update-State {
      param($s)
      $s | Add-Member -NotePropertyName canary_state -NotePropertyValue $clean -Force
    } | Out-Null
    return
  }

  $st = Read-State
  if (-not $st) { throw 'state.json missing; cannot persist canary_state' }
  $st | Add-Member -NotePropertyName canary_state -NotePropertyValue $clean -Force
  Write-State $st
}

function Test-CanaryStateBusy {
  param($State, [string]$Label = 'current')

  if (-not $State) { return $null }

  if ($State.task_mode -and ([string]$State.task_mode -in @('active', 'discuss', 'code', 'running'))) {
    return "$Label task_mode=$($State.task_mode)"
  }
  if ($State.auditor_state -and $State.auditor_state.status -eq 'active') {
    return "$Label auditor active"
  }
  if ($State.doctor_state -and ([string]$State.doctor_state.status -in @('active', 'running'))) {
    return "$Label doctor $($State.doctor_state.status)"
  }
  if ($State.doctor_active -eq $true) {
    return "$Label doctor_active=true"
  }

  return $null
}

function Test-CanaryIdleGate {
  $cfg = Get-CanaryConfig
  if (-not $cfg.enabled) {
    return [pscustomobject]@{ idle = $false; reason = 'disabled in config' }
  }

  $state = Get-CanaryState
  $now = Get-Date

  if ($state.quarantine_until) {
    try {
      $quarantineUntil = [datetime]$state.quarantine_until
      if ($now -lt $quarantineUntil) {
        return [pscustomobject]@{ idle = $false; reason = "quarantine until $($quarantineUntil.ToString('o'))" }
      }
    } catch {
      return [pscustomobject]@{ idle = $false; reason = 'invalid quarantine_until' }
    }
  }

  if ($state.last_heartbeat_at) {
    try {
      $last = [datetime]$state.last_heartbeat_at
      $sinceHours = ($now - $last).TotalHours
      if ($sinceHours -lt [double]$cfg.intervalHours) {
        return [pscustomobject]@{ idle = $false; reason = "interval not elapsed ($([math]::Round($sinceHours, 2))h < $($cfg.intervalHours)h)" }
      }
    } catch {
      return [pscustomobject]@{ idle = $false; reason = 'invalid last_heartbeat_at' }
    }
  }

  $root = Get-BridgeRoot
  $lockPath = Join-Path $root 'control\codex.lock'
  if (Test-Path -LiteralPath $lockPath) {
    return [pscustomobject]@{ idle = $false; reason = 'codex.lock held' }
  }

  $currentState = $null
  try { $currentState = Read-State } catch {}
  $busyReason = Test-CanaryStateBusy -State $currentState -Label 'current channel'
  if ($busyReason) {
    return [pscustomobject]@{ idle = $false; reason = $busyReason }
  }

  if (Get-Command Get-OtherChannelsAgents -ErrorAction SilentlyContinue) {
    try {
      $agents = Get-OtherChannelsAgents
      if ($agents -and $agents.Count -gt 0) {
        $pairs = @($agents.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" })
        return [pscustomobject]@{ idle = $false; reason = "other channel agents active: $($pairs -join ', ')" }
      }
    } catch {}
  }

  $channelsRoot = Join-Path $root 'channels'
  if (Test-Path -LiteralPath $channelsRoot) {
    foreach ($dir in @(Get-ChildItem -LiteralPath $channelsRoot -Directory -ErrorAction SilentlyContinue)) {
      if ($dir.Name -eq '_archive') { continue }
      $statePath = Join-Path $dir.FullName 'state.json'
      if (-not (Test-Path -LiteralPath $statePath)) { continue }
      try {
        $channelState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $busyReason = Test-CanaryStateBusy -State $channelState -Label "channel $($dir.Name)"
        if ($busyReason) {
          return [pscustomobject]@{ idle = $false; reason = $busyReason }
        }
      } catch {
        return [pscustomobject]@{ idle = $false; reason = "cannot read channel $($dir.Name) state" }
      }
    }
  }

  return [pscustomobject]@{ idle = $true; reason = 'all clear' }
}

function ConvertTo-CanaryFullPath {
  param([string]$Path)
  return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/')
}

function Test-CanaryPathInside {
  param([string]$ChildPath, [string]$ParentPath)

  $child = ConvertTo-CanaryFullPath -Path $ChildPath
  $parent = ConvertTo-CanaryFullPath -Path $ParentPath
  if ($child.Equals($parent, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  $parentWithSlash = $parent + [System.IO.Path]::DirectorySeparatorChar
  return $child.StartsWith($parentWithSlash, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-CanaryRegisteredWorktrees {
  param([string]$RepoRoot)

  $paths = New-Object System.Collections.Generic.List[string]
  $raw = @(& git -C $RepoRoot worktree list --porcelain 2>$null)
  foreach ($line in $raw) {
    if ($line -like 'worktree *') {
      $p = $line.Substring('worktree '.Length).Trim()
      if (-not [string]::IsNullOrWhiteSpace($p)) {
        [void]$paths.Add((ConvertTo-CanaryFullPath -Path $p))
      }
    }
  }
  return @($paths)
}

function Invoke-CanaryGit {
  param(
    [string]$RepoPath,
    [string[]]$GitArgs
  )

  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = @(& git -C $RepoPath @GitArgs 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldPreference
  }

  return [pscustomobject]@{
    ExitCode = $exitCode
    Output   = $output
  }
}

function Initialize-CanaryWorktree {
  param([string]$RepoRoot = 'C:\Users\rafie\OneDrive\Documents\bridge')

  $cfg = Get-CanaryConfig
  $wtPath = [string]$cfg.worktreePath
  $branch = [string]$cfg.branchName
  if ([string]::IsNullOrWhiteSpace($wtPath)) { throw 'canary worktreePath is empty' }
  if ([string]::IsNullOrWhiteSpace($branch)) { throw 'canary branchName is empty' }

  $repoFull = ConvertTo-CanaryFullPath -Path (Resolve-Path -LiteralPath $RepoRoot).Path
  $wtFull = ConvertTo-CanaryFullPath -Path $wtPath
  if (Test-CanaryPathInside -ChildPath $wtFull -ParentPath $repoFull) {
    throw "canary worktreePath must be outside repo root: $wtFull is inside $repoFull"
  }

  $registered = @(Get-CanaryRegisteredWorktrees -RepoRoot $repoFull)
  foreach ($p in $registered) {
    if ($p.Equals($wtFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $wtFull }
  }

  if (Test-Path -LiteralPath $wtFull) {
    throw "canary worktree path exists but is not registered: $wtFull"
  }

  $branchResult = Invoke-CanaryGit -RepoPath $repoFull -GitArgs @('branch', '--list', $branch)
  if ($branchResult.ExitCode -ne 0) {
    throw "git branch --list failed: $($branchResult.Output -join ' ')"
  }
  $branchExists = ($branchResult.Output -join "`n").Trim()
  if (-not $branchExists) {
    $branchCreate = Invoke-CanaryGit -RepoPath $repoFull -GitArgs @('branch', $branch, 'HEAD')
    if ($branchCreate.ExitCode -ne 0) { throw "git branch failed: $($branchCreate.Output -join ' ')" }
  }

  $addResult = Invoke-CanaryGit -RepoPath $repoFull -GitArgs @('worktree', 'add', $wtFull, $branch)
  if ($addResult.ExitCode -ne 0) { throw "git worktree add failed: $($addResult.Output -join ' ')" }
  if (-not (Test-Path -LiteralPath $wtFull)) { throw "worktree provisioning failed: $wtFull" }
  return $wtFull
}

function Write-CanaryHeartbeat {
  param([hashtable]$Record)

  $logDir = Join-Path (Get-BridgeRoot) 'logs'
  if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
  }
  $logPath = Join-Path $logDir 'heartbeat.jsonl'
  $Record['timestamp'] = (Get-Date).ToString('o')
  $line = ($Record | ConvertTo-Json -Compress -Depth 5)
  [System.IO.File]::AppendAllText($logPath, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
}

function Sync-CanaryWorktreeFromMain {
  param(
    [string]$RepoRoot,
    [string]$WorktreePath
  )

  $sourceBranchResult = Invoke-CanaryGit -RepoPath $RepoRoot -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')
  if ($sourceBranchResult.ExitCode -ne 0) {
    throw "git rev-parse main branch failed: $($sourceBranchResult.Output -join ' ')"
  }
  $sourceBranch = ($sourceBranchResult.Output | Select-Object -First 1).ToString().Trim()
  if ([string]::IsNullOrWhiteSpace($sourceBranch) -or $sourceBranch -eq 'HEAD') {
    throw "cannot sync canary from detached source branch: $sourceBranch"
  }

  $statusResult = Invoke-CanaryGit -RepoPath $WorktreePath -GitArgs @('status', '--porcelain')
  if ($statusResult.ExitCode -ne 0) {
    throw "git status failed in canary worktree: $($statusResult.Output -join ' ')"
  }
  $dirty = @($statusResult.Output | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  if ($dirty.Count -gt 0) {
    throw "canary worktree dirty before sync: $($dirty -join '; ')"
  }

  $mergeResult = Invoke-CanaryGit -RepoPath $WorktreePath -GitArgs @('merge', '--no-edit', $sourceBranch)
  if ($mergeResult.ExitCode -ne 0) {
    throw "git merge $sourceBranch into canary failed: $($mergeResult.Output -join ' ')"
  }
  return $sourceBranch
}

function Add-CanaryStateCounters {
  param($State, [bool]$Success)

  if ($Success) {
    $State.last_outcome = 'ok'
    $State.consecutive_failures = 0
    $State.total_heartbeats = [int]$State.total_heartbeats + 1
    return
  }

  $State.last_outcome = 'fail'
  $State.consecutive_failures = [int]$State.consecutive_failures + 1
  $State.total_failures = [int]$State.total_failures + 1

  $cfg = Get-CanaryConfig
  if ([int]$State.consecutive_failures -ge [int]$cfg.quarantineFailures) {
    $State.quarantine_until = (Get-Date).AddHours([double]$cfg.quarantineHours).ToString('o')
  }
}

function Write-CanaryRun {
  param(
    [bool]$Ok,
    [long]$DurationMs,
    [string[]]$Errors = @(),
    [bool]$Skipped = $false
  )

  $entry = [ordered]@{
    timestamp   = (Get-Date).ToUniversalTime().ToString('o')
    ok          = $Ok
    duration_ms = $DurationMs
    errors      = @($Errors)
  }
  if ($Skipped) { $entry.skipped = $true }
  $path = Join-Path (Get-BridgeRoot) 'control\canary-runs.jsonl'
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::AppendAllText($path, (($entry | ConvertTo-Json -Compress -Depth 5) + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
}

function Get-CanaryHealthUri {
  try {
    $cfg = Get-BridgeConfig
    $port = if ($cfg.port) { [int]$cfg.port } else { 8787 }
    return "http://localhost:$port/api/health"
  } catch {
    return 'http://localhost:8787/api/health'
  }
}

function Invoke-CanarySmokeChecks {
  param([string]$RepoRoot)

  $errors = New-Object 'System.Collections.Generic.List[string]'

  try {
    foreach ($file in @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) {
      $full = [string]$file.FullName
      if ($full -match '\\\.git\\' -or $full -match '\\worktrees\\') { continue }
      $tokens = $null; $parseErrors = $null
      [void][System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$parseErrors)
      if ($parseErrors -and $parseErrors.Count -gt 0) {
        [void]$errors.Add(("parse {0}: {1}" -f $file.Name, [string]$parseErrors[0].Message))
      }
    }
  } catch {
    [void]$errors.Add("parse sweep failed: $($_.Exception.Message)")
  }

  $uri = Get-CanaryHealthUri
  # 2026-05-29 fix: /api/health exposes lastSeq ONLY to AUTHENTICATED callers; the public (unauth)
  # response was trimmed (no lastSeq) ~2026-05-28, so canary's unauth read got lastSeq=null->0 and
  # reported a FALSE "lastSeq did not advance (0 -> 0)" on every run (smoke fail -> quarantine), even
  # though the bridge was healthy. Canary is an internal localhost caller, so it authenticates with
  # the same Basic creds the driver uses (auth.json in the protected store).
  $authHeaders = @{}
  try {
    $authP = if (Get-Command Get-AuthPath -ErrorAction SilentlyContinue) { Get-AuthPath } else { Join-Path (Get-BridgeRoot) 'auth.json' }
    if ($authP -and (Test-Path -LiteralPath $authP)) {
      $auth = Get-Content -LiteralPath $authP -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($auth.user -and $auth.password) {
        $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(("{0}:{1}" -f [string]$auth.user, [string]$auth.password)))
        $authHeaders = @{ Authorization = "Basic $basic" }
      }
    }
  } catch {}
  try {
    $before = Invoke-WebRequest -Uri $uri -Headers $authHeaders -UseBasicParsing -TimeoutSec 5
    if ($before.StatusCode -ne 200) { [void]$errors.Add("health before HTTP $($before.StatusCode)") }
    $beforeObj = $before.Content | ConvertFrom-Json
    $beforeSeq = 0
    try { $beforeSeq = [int]$beforeObj.lastSeq } catch {}

    [void](Add-Message -From system -Kind event -Text ("🧪 Canary smoke heartbeat " + (Get-Date).ToUniversalTime().ToString('o')))

    Start-Sleep -Milliseconds 200
    $after = Invoke-WebRequest -Uri $uri -Headers $authHeaders -UseBasicParsing -TimeoutSec 5
    if ($after.StatusCode -ne 200) { [void]$errors.Add("health after HTTP $($after.StatusCode)") }
    $afterObj = $after.Content | ConvertFrom-Json
    $afterSeq = 0
    try { $afterSeq = [int]$afterObj.lastSeq } catch {}
    if ($afterSeq -le $beforeSeq) {
      [void]$errors.Add("lastSeq did not advance ($beforeSeq -> $afterSeq)")
    }
  } catch {
    [void]$errors.Add("health/lastSeq check failed: $($_.Exception.Message)")
  }

  return @($errors.ToArray())
}

function Invoke-CanaryCycle {
  [CmdletBinding()]
  param(
    [switch]$Force,
    [switch]$NoStateUpdate
  )

  if (-not $Force) {
    $gate = Test-CanaryIdleGate
    if (-not $gate.idle) {
      Write-CanaryHeartbeat @{ outcome = 'skip'; reason = $gate.reason; manual = $false }
      Write-CanaryRun -Ok $true -DurationMs 0 -Errors @("skipped: $($gate.reason)") -Skipped $true
      return [pscustomobject]@{ ok = $true; skipped = $true; reason = $gate.reason; manual = $false }
    }
  }

  $state = Get-CanaryState
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $wtPath = $null

  try {
    $repoRoot = Get-BridgeRoot
    $wtPath = Initialize-CanaryWorktree -RepoRoot $repoRoot
    $syncedFrom = Sync-CanaryWorktreeFromMain -RepoRoot $repoRoot -WorktreePath $wtPath
    $markerDir = Join-Path $wtPath 'canary'
    if (-not (Test-Path -LiteralPath $markerDir)) {
      New-Item -ItemType Directory -Path $markerDir -Force | Out-Null
    }

    $markerFile = Join-Path $markerDir 'marker.md'
    $ts = (Get-Date).ToString('o')
    [System.IO.File]::WriteAllText($markerFile, "heartbeat $ts`n", (New-Object System.Text.UTF8Encoding($false)))

    $addResult = Invoke-CanaryGit -RepoPath $wtPath -GitArgs @('add', '--', 'canary/marker.md')
    if ($addResult.ExitCode -ne 0) { throw "git add failed: $($addResult.Output -join ' ')" }

    $commitResult = Invoke-CanaryGit -RepoPath $wtPath -GitArgs @('commit', '-m', "canary heartbeat $ts")
    if ($commitResult.ExitCode -ne 0) { throw "git commit failed: $($commitResult.Output -join ' ')" }

    $smokeErrors = @(Invoke-CanarySmokeChecks -RepoRoot $repoRoot)
    if ($smokeErrors.Count -gt 0) { throw ("smoke failed: " + ($smokeErrors -join '; ')) }

    $sw.Stop()
    if (-not $NoStateUpdate) {
      $state.last_heartbeat_at = $ts
      Add-CanaryStateCounters -State $state -Success $true
      Set-CanaryState -State $state
    }

    Write-CanaryHeartbeat @{
      outcome     = 'ok'
      phase       = 1
      duration_ms = $sw.ElapsedMilliseconds
      worktree    = $wtPath
      synced_from = $syncedFrom
      manual      = [bool]$Force
    }
    Write-CanaryRun -Ok $true -DurationMs $sw.ElapsedMilliseconds -Errors @()
    return [pscustomobject]@{ ok = $true; skipped = $false; duration_ms = $sw.ElapsedMilliseconds; manual = [bool]$Force }
  } catch {
    $sw.Stop()
    $err = $_.Exception.Message

    if (-not $NoStateUpdate) {
      Add-CanaryStateCounters -State $state -Success $false
      Set-CanaryState -State $state
    }

    Write-CanaryHeartbeat @{
      outcome     = 'fail'
      phase       = 1
      duration_ms = $sw.ElapsedMilliseconds
      error       = $err
      manual      = [bool]$Force
    }
    Write-CanaryRun -Ok $false -DurationMs $sw.ElapsedMilliseconds -Errors @($err)
    try {
      $cst2 = Get-CanaryState
      if ([int]$cst2.consecutive_failures -ge 2) {
        try { Send-PushEvent -Kind need_you -Text "Canary: 2 consecutive failures. Last error: $err" } catch {}
      }
    } catch {}
    return [pscustomobject]@{ ok = $false; skipped = $false; error = $err; manual = [bool]$Force }
  }
}
