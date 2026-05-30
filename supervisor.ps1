# supervisor.ps1 -- persistent ELEVATED host for the bridge (autostart task action).
# Keeps server.ps1 + driver.ps1 alive, auto-restarts crashes, honors restart/stop flags
# WITHOUT a new UAC prompt. Never exits on its own (its job keeps children alive).
# Instrumented: captures child stdout/stderr to control/*.log for diagnosis.
. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\circuit-breaker.ps1')
. (Join-Path $PSScriptRoot 'lib\replay.ps1')
$ErrorActionPreference = 'Continue'
$enc = New-Object System.Text.UTF8Encoding($false); $OutputEncoding = $enc
try { [Console]::OutputEncoding = $enc } catch {}

$root = Get-BridgeRoot
$cfg  = Get-BridgeConfig
$port = [int]$cfg.port
$ctl  = Join-Path $root 'control'
if (-not (Test-Path $ctl)) { New-Item -ItemType Directory -Path $ctl -Force | Out-Null }
$flagRestart = Join-Path $ctl 'restart.flag'
$flagStop    = Join-Path $ctl 'stop.flag'
$supLog = Join-Path $ctl 'supervisor.log'
$srvOut = Join-Path $ctl 'server.out.log'; $srvErr = Join-Path $ctl 'server.err.log'
function Log($m){ ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) | Out-File $supLog -Append -Encoding utf8 }
$null = Initialize-Bridge
# Auto-clean snapshots older than 7 days at startup
try {
  $snapCutoff = (Get-Date).AddDays(-7)
  $chansRoot = Join-Path $root 'channels'
  if (Test-Path -LiteralPath $chansRoot) {
    Get-ChildItem -LiteralPath $chansRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $snapDir = Join-Path $_.FullName 'snapshots'
      if (Test-Path -LiteralPath $snapDir) {
        $old = Get-ChildItem -LiteralPath $snapDir -Filter 'state.*.json' -ErrorAction SilentlyContinue |
          Where-Object { $_.LastWriteTime -lt $snapCutoff }
        if ($old) {
          $cnt = @($old).Count
          $old | Remove-Item -Force -ErrorAction SilentlyContinue
          Log ("startup snapshot cleanup: removed $cnt files older than 7 days in $snapDir")
        }
      }
    }
  }
} catch { Log ("startup snapshot cleanup error: " + $_.Exception.Message) }

# Phase 3 (full): supervisor keeps ONE driver per non-archived channel. Each driver is
# pinned to its channel for life. $drivers hashtable: slug -> Process object.
$drivers = @{}

function Get-TrackedBridgeProcesses {
  $tracked = @()
  if ($script:srv) { $tracked += $script:srv }
  if ($script:drivers) {
    foreach ($proc in $script:drivers.Values) {
      if ($proc) { $tracked += $proc }
    }
  }
  return @($tracked)
}
function Test-TrackedBridgeProcess {
  param([System.Diagnostics.Process]$Process)
  if ($null -eq $Process) { return $false }
  try { $trackedPid = [int]$Process.Id } catch { return $false }
  if ($trackedPid -le 0 -or $trackedPid -eq $PID) {
    Log ("PID guard: refusing to stop PID " + $trackedPid)
    return $false
  }
  try {
    $current = Get-Process -Id $trackedPid -ErrorAction Stop
    # Guard against PID reuse: only stop the same process instance we spawned/tracked.
    if ($current.StartTime -ne $Process.StartTime) {
      Log ("PID owner validation: refusing to stop PID " + $trackedPid + " because StartTime changed")
      return $false
    }
  } catch {
    return $false
  }
  return $true
}
function Stop-TrackedBridgeProcess {
  param(
    [System.Diagnostics.Process]$Process,
    [string]$Reason
  )
  if (-not (Test-TrackedBridgeProcess -Process $Process)) { return $false }
  $trackedPid = [int]$Process.Id
  try {
    Log ($Reason + " -> stopping tracked PID " + $trackedPid)
    Stop-Process -Id $trackedPid -Force -ErrorAction SilentlyContinue
    return $true
  } catch {
    Log ($Reason + " stop error for PID " + $trackedPid + ": " + $_.Exception.Message)
    return $false
  }
}
function Kill-Bridge {
  foreach ($proc in (Get-TrackedBridgeProcesses)) {
    $null = Stop-TrackedBridgeProcess -Process $proc -Reason 'Kill-Bridge'
  }
}
function Reap-Bloated {
  # Memory-leak guard: kill any bridge server/driver powershell whose PRIVATE memory exceeds the
  # cap. A runaway (e.g. the /api/radar ConvertTo-Json -Depth 10 OOM that spawned 50-70GB zombie powershell)
  # never recovers and strangles the whole machine. The loop below then restarts a fresh one.
  # The supervisor is ELEVATED, so it CAN kill these (a non-elevated watchdog cannot). Match by
  # PRIVATE memory (zombies had small working sets but 70GB private). /F only (no /T) to spare
  # any codex children. Cap 8GB: no healthy bridge powershell ever approaches this.
  $reaped = $false
  try {
    foreach ($proc in (Get-TrackedBridgeProcesses)) {
      if (Test-TrackedBridgeProcess -Process $proc) {
        $priv = 0; try { $priv = [int64](Get-Process -Id $proc.Id -ErrorAction SilentlyContinue).PrivateMemorySize64 } catch {}
        if ($priv -gt 8GB) {
          Log ("REAP: bloated tracked PID " + $proc.Id + " private=" + [int]($priv/1MB) + "MB > 8GB -> kill (mem-leak guard)")
          $null = Stop-TrackedBridgeProcess -Process $proc -Reason 'REAP'
          $reaped = $true
        }
      }
    }
  } catch { Log ("reap error: " + $_.Exception.Message) }
  return $reaped
}
function Start-Srv {
  Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'server.ps1') `
    -NoNewWindow -PassThru -RedirectStandardOutput $srvOut -RedirectStandardError $srvErr
}
function Start-Drv {
  # Spawn a driver pinned to a specific channel. Per-channel log files keep crashes attributable.
  param([string]$Slug)
  $drvOut = Join-Path $ctl ("driver." + $Slug + ".out.log")
  $drvErr = Join-Path $ctl ("driver." + $Slug + ".err.log")
  Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'driver.ps1'),'-Channel',$Slug `
    -NoNewWindow -PassThru -RedirectStandardOutput $drvOut -RedirectStandardError $drvErr
}
function Get-ActiveSlugs {
  # Non-archived channel slugs, in stable order.
  $list = @(Get-ChannelList)
  $slugs = @($list | ForEach-Object { [string]$_.slug } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($slugs.Count -eq 0) { $slugs = @('main') }
  return $slugs
}
function Record-CircuitRestart {
  param([string]$Detail, [bool]$ReapFired = $false, [bool]$FlagPresent = $false)
  try {
    $res = Invoke-CircuitRestartRecord -ControlDir $ctl -Root $root -Slugs (Get-ActiveSlugs) -Detail $Detail -ReapFired:$ReapFired -FlagPresent:$FlagPresent -FreezeFlagPath $flagCbFreeze -LogCallback { param($m) Log $m } -MessageCallback { param($m) Add-Message -From system -Text $m -Kind event | Out-Null } -PushCallback { param($m) try { Send-PushEvent -Kind need_you -Text $m } catch {} }
    if ($res.cooldownUntil) { $script:cbCooldownUntil = $res.cooldownUntil }
  } catch {
    Log ("circuit record error (fail-safe allow restart): " + $_.Exception.Message)
  }
}
function Test-CircuitSpawnPaused {
  try {
    $res = Test-CircuitSpawnPauseState -FreezeFlagPath $flagCbFreeze -CooldownUntil $script:cbCooldownUntil -LogCallback { param($m) Log $m } -MessageCallback { param($m) Add-Message -From system -Text $m -Kind event | Out-Null }
    $script:cbCooldownUntil = $res.cooldownUntil
    return [bool]$res.paused
  } catch {
    Log ("circuit pause check error (fail-safe allow restart): " + $_.Exception.Message)
    return $false
  }
}

Log "=== supervisor start, PID $PID ==="
Kill-Bridge
Start-Sleep -Seconds 2
$srv = $null
$lastRecycleTs = $null   # rate-limit: prevent restart-storm
$minRecycleSec = 60      # at least 60s between consecutive recycles
$lastWdSpawn   = $null   # rate-limit watchdog (re)spawns (guards against a spawn storm)
$minWdSpawnSec = 60      # at least 60s between watchdog spawn attempts
$flagCbFreeze  = Join-Path $ctl 'cb-freeze.flag'
$script:cbCooldownUntil = $null
$script:startupFailureCount = 0
$script:startupFailureLimit = 10
$script:startupFailureBackoffBaseSec = 3
$script:startupFailureBackoffMaxSec = 120
function Reset-StartupFailures {
  param([string]$Operation)
  if ($script:startupFailureCount -gt 0) {
    Log ($Operation + " recovered after " + $script:startupFailureCount + " consecutive startup failure(s)")
  }
  $script:startupFailureCount = 0
}
function Register-StartupFailure {
  param(
    [string]$Operation,
    [object]$ErrorRecord
  )
  $script:startupFailureCount += 1
  $exp = [Math]::Min(($script:startupFailureCount - 1), 6)
  $delay = [int]($script:startupFailureBackoffBaseSec * [Math]::Pow(2, $exp))
  if ($delay -gt $script:startupFailureBackoffMaxSec) { $delay = $script:startupFailureBackoffMaxSec }
  $msg = [string]$ErrorRecord
  if ($ErrorRecord -and $ErrorRecord.Exception) { $msg = $ErrorRecord.Exception.Message }
  if ($script:startupFailureCount -ge $script:startupFailureLimit) {
    Log ("FATAL: " + $Operation + " failed " + $script:startupFailureCount + " consecutive time(s); retrying after " + $delay + "s. Last error: " + $msg)
  } else {
    Log ($Operation + " failed (" + $script:startupFailureCount + "/" + $script:startupFailureLimit + "); retrying after " + $delay + "s. Error: " + $msg)
  }
  Start-Sleep -Seconds $delay
}
Add-Message -From system -Text "Супервизор запущен (elevated). Сервер + по одному драйверу на каждый канал (параллельно). Перезапуск без UAC по флагу; авто-подъём при падении." -Kind event | Out-Null

while ($true) {
  try {
    $reapFired = $false
    try { $reapFired = [bool](Reap-Bloated) } catch { Log ("reap error: " + $_.Exception.Message) }
    if ($reapFired) { Record-CircuitRestart -Detail 'reap-bloated OOM guard killed bridge child' -ReapFired:$true -FlagPresent:$false }
    if (Test-Path $flagStop) {
      Remove-Item $flagStop -Force -ErrorAction SilentlyContinue
      Log "stop flag -> exit"; Kill-Bridge; break
    }
    if (Test-Path $flagRestart) {
      # FIX 2026-05-26: rate-limit restart.flag honoring. If we recycled less than
      # $minRecycleSec ago, drop the flag with a warning instead of recycling again.
      # This prevents restart-storms when Codex (or any actor) sets the flag faster
      # than the bridge can finish a turn. Without this, 6+ restarts/10min from a
      # single task in progress have been observed -- Codex never lands its commit
      # because the next restart kills it mid-turn.
      $now = Get-Date
      $tooSoon = $false
      if ($lastRecycleTs) {
        $sinceLast = ($now - $lastRecycleTs).TotalSeconds
        if ($sinceLast -lt $minRecycleSec) {
          $tooSoon = $true
          Remove-Item $flagRestart -Force -ErrorAction SilentlyContinue
          Log ("restart flag IGNORED (rate-limit: " + [int]$sinceLast + "s < " + $minRecycleSec + "s since last recycle)")
          Add-Message -From system -Text ("⚠ Restart-flag сброшен супервизором: rate-limit (" + [int]$sinceLast + "s < " + $minRecycleSec + "s). Кто-то (Codex?) пытается рестартить мост слишком часто -- даю текущему ходу доработать.") -Kind event | Out-Null
        }
      }
      if (-not $tooSoon) {
        Remove-Item $flagRestart -Force -ErrorAction SilentlyContinue
        Log "restart flag -> recycle"
        Add-Message -From system -Text "Перезапуск по запросу (без UAC)." -Kind event | Out-Null
        try { foreach ($_slug in (Get-ActiveSlugs)) { try { Save-StateSnapshot -Reason 'restart_flag' -Channel $_slug } catch {} } } catch {}
        Kill-Bridge; $srv = $null; $drivers = @{}; Start-Sleep -Seconds 3
        $lastRecycleTs = Get-Date
        Record-CircuitRestart -Detail 'restart.flag recycle' -ReapFired:$false -FlagPresent:$true
      }
    }
    $slugs = Get-ActiveSlugs
    if (-not (Test-CircuitSpawnPaused)) {
      if ($null -eq $srv -or $srv.HasExited) {
        if ($null -ne $srv -and $srv.HasExited -and -not $reapFired) {
          Record-CircuitRestart -Detail ("server exited with code " + $srv.ExitCode) -ReapFired:$false -FlagPresent:$false
        }
        if (-not (Test-CircuitSpawnPaused)) {
          Log "starting server..."
          try {
            $srv = Start-Srv; Start-Sleep -Seconds 3
            if ($null -eq $srv) { throw "Start-Srv returned no process" }
            if ($srv.HasExited) { throw ("server exited immediately with code " + $srv.ExitCode) }
            Reset-StartupFailures -Operation 'Start-Srv'
          } catch {
            Register-StartupFailure -Operation 'Start-Srv' -ErrorRecord $_
            continue
          }
          Log ("server pid=" + $(if($srv){$srv.Id}else{'?'}) + " hasExited=" + $(if($srv){$srv.HasExited}else{'?'}))
        }
      }
      # Spawn one driver per non-archived channel; restart any that died.
      $driverStartupFailed = $false
      foreach ($slug in $slugs) {
        $proc = $drivers[$slug]
        if ($null -eq $proc -or $proc.HasExited) {
          if ($null -ne $proc -and $proc.HasExited -and -not $reapFired) {
            Record-CircuitRestart -Detail ("driver[" + $slug + "] exited with code " + $proc.ExitCode) -ReapFired:$false -FlagPresent:$false
          }
          if (Test-CircuitSpawnPaused) { break }
          Log ("starting driver for channel '" + $slug + "'...")
          try {
            $proc = Start-Drv -Slug $slug
            Start-Sleep -Seconds 2
            if ($null -eq $proc) { throw ("Start-Drv[" + $slug + "] returned no process") }
            if ($proc.HasExited) { throw ("driver[" + $slug + "] exited immediately with code " + $proc.ExitCode) }
            Reset-StartupFailures -Operation ("Start-Drv[" + $slug + "]")
          } catch {
            Register-StartupFailure -Operation ("Start-Drv[" + $slug + "]") -ErrorRecord $_
            $driverStartupFailed = $true
            break
          }
          Log ("driver[" + $slug + "] pid=" + $(if($proc){$proc.Id}else{'?'}) + " hasExited=" + $(if($proc){$proc.HasExited}else{'?'}))
          $drivers[$slug] = $proc
        }
      }
      if ($driverStartupFailed) { continue }
    }
    # Ensure the INDEPENDENT watchdog safety-net is alive. By design it's a separate
    # scheduled task (install-watchdog.ps1), but task registration needs elevation and the
    # task can go missing (observed 2026-05-29: task ClaudeCodexBridge-Watchdog absent, the
    # watchdog had been DOWN ~3 days, leaving the bridge with no git auto-rollback). The
    # supervisor is already the elevated, autostarted host, so it (re)spawns the watchdog as
    # a detached process whenever none is alive -- durable across reboots without a manual
    # elevated install step. PRECISE match (-File ...watchdog.ps1, excluding -Command) so we
    # don't mistake an ad-hoc inspection command that merely mentions the script name for a
    # live loop. Rate-limited so a watchdog that dies instantly can't trigger a spawn storm.
    try {
      $wdAlive = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*-File*watchdog.ps1*' -and $_.CommandLine -notlike '*-Command*' }).Count -gt 0
      if (-not $wdAlive) {
        $nowWd = Get-Date
        if (-not $lastWdSpawn -or ($nowWd - $lastWdSpawn).TotalSeconds -ge $minWdSpawnSec) {
          $wdScript = Join-Path $root 'watchdog.ps1'
          if (Test-Path $wdScript) {
            Start-Process powershell -ArgumentList '-NoProfile','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',$wdScript -WindowStyle Hidden | Out-Null
            $lastWdSpawn = $nowWd
            Log "watchdog not running -> spawned detached safety-net"
          }
        }
      }
    } catch { Log ("watchdog-ensure error: " + $_.Exception.Message) }

    # Reap drivers whose channel was archived (channel no longer in $slugs).
    $known = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in $drivers.Keys) { $known.Add([string]$k) }
    foreach ($k in $known) {
      if (-not ($slugs -contains $k)) {
        Log ("channel '" + $k + "' archived -> stopping its driver")
        $p = $drivers[$k]
        if ($p -and -not $p.HasExited) { $null = Stop-TrackedBridgeProcess -Process $p -Reason ("archive channel '" + $k + "'") }
        $drivers.Remove($k)
      }
    }
  } catch { Log ("ERR " + $_.Exception.Message) }
  Start-Sleep -Seconds 5
}
