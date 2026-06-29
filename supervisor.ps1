# supervisor.ps1 -- persistent ELEVATED host for the bridge (autostart task action).
# Keeps server.ps1 + driver.ps1 alive, auto-restarts crashes, honors restart/stop flags
# WITHOUT a new UAC prompt. Never exits on its own (its job keeps children alive).
# Instrumented: captures child stdout/stderr to control/*.log for diagnosis.
. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\circuit-breaker.ps1')
. (Join-Path $PSScriptRoot 'lib\supervisor-restart-limit.ps1')
. (Join-Path $PSScriptRoot 'lib\replay.ps1')
. (Join-Path $PSScriptRoot 'lib\script-integrity.ps1')
. (Join-Path $PSScriptRoot 'lib\bridge-lock.ps1')
$script:supervisorLaunchLock = Acquire-SupervisorLaunchLock -TimeoutMs 0
if (-not $script:supervisorLaunchLock.acquired) {
  Write-Host ("supervisor: another instance already running ($($script:supervisorLaunchLock.reason)) - exiting")
  exit 2
}
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
function Invoke-SupervisorLogMutex {
  param(
    [Parameter(Mandatory=$true)][scriptblock]$Body,
    [int]$TimeoutMs = 5000
  )
  $mutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeCodexBridgeSupervisorLog')
  $got = $false
  try {
    try { $got = $mutex.WaitOne($TimeoutMs) }
    catch [System.Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { throw "Could not acquire supervisor-log mutex within ${TimeoutMs}ms" }
    return (& $Body)
  } finally {
    if ($got) {
      try { $mutex.ReleaseMutex() }
      catch { [System.Diagnostics.Trace]::TraceError("supervisor Log ReleaseMutex failed: " + $_.Exception.Message) }
    }
    if ($mutex) { $mutex.Dispose() }
  }
}
function Log($m) {
  try {
    $line = "{0}  {1}`r`n" -f (Get-Date -Format 'HH:mm:ss'), $m
    $enc = New-Object System.Text.UTF8Encoding($false)
    $bytes = $enc.GetBytes($line)
    Invoke-SupervisorLogMutex -TimeoutMs 5000 -Body {
      $fs = $null
      try {
        $fs = New-Object System.IO.FileStream($supLog, ([System.IO.FileMode]::Append), ([System.IO.FileAccess]::Write), ([System.IO.FileShare]::Read))
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)
      } finally {
        if ($fs) { $fs.Dispose() }
      }
    }
  } catch {
    [System.Diagnostics.Trace]::TraceError("supervisor Log failed: " + $_.Exception.Message)
  }
}
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

# Compact oversized backlog files once at startup. The helper script keeps the
# policy local: 10MB threshold, last-line-wins by id, atomic replacement.
try {
  $compactBacklogScript = Join-Path $root 'tools\compact-backlog.ps1'
  $channelsRoot = Join-Path $root 'channels'
  if ((Test-Path -LiteralPath $compactBacklogScript) -and (Test-Path -LiteralPath $channelsRoot)) {
    Get-ChildItem -LiteralPath $channelsRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
      $backlogPath = Join-Path $_.FullName 'backlog.jsonl'
      if (Test-Path -LiteralPath $backlogPath) {
        try {
          $output = @(& $compactBacklogScript -Path $backlogPath 2>&1)
          foreach ($line in $output) {
            if ($null -ne $line -and ('' -ne [string]$line)) {
              Log ("startup backlog compaction: " + [string]$line)
            }
          }
        } catch {
          Log ("startup backlog compaction error for " + $backlogPath + ": " + $_.Exception.Message)
        }
      }
    }
  }
} catch { Log ("startup backlog compaction error: " + $_.Exception.Message) }

# Phase 3 (full): supervisor keeps ONE driver per non-archived channel. Each driver is
# pinned to its channel for life. $drivers hashtable: slug -> Process object.
$drivers = @{}
$script:bloatedSince = @{}
$script:integrityFailureLogged = @{}
$script:stopWaitMs = 5000

function Get-SupervisorStopWaitMs {
  param([int]$RequestedWaitMs = 0)
  if ($RequestedWaitMs -gt 0) { return $RequestedWaitMs }
  if ($script:stopWaitMs -gt 0) { return [int]$script:stopWaitMs }
  return 5000
}

function ConvertTo-SupervisorStopWaitMs {
  param(
    [object]$Value,
    [int]$DefaultMs = 5000,
    [string]$Source = 'supervisor.stopWaitMs'
  )
  $parsed = 0
  if ($null -ne $Value -and [int]::TryParse(([string]$Value), [ref]$parsed) -and $parsed -gt 0) {
    return $parsed
  }
  Log ("WARN: invalid " + $Source + "='" + $Value + "', using " + $DefaultMs + "ms")
  return $DefaultMs
}

function Invoke-TaskkillTree {
  param(
    [Parameter(Mandatory=$true)][int]$TargetPid,
    [string]$Reason = 'taskkill'
  )
  $taskkillPath = Join-Path $env:SystemRoot 'System32\taskkill.exe'
  if (-not (Test-Path -LiteralPath $taskkillPath)) { $taskkillPath = 'taskkill.exe' }
  $stdoutPath = [System.IO.Path]::GetTempFileName()
  $stderrPath = [System.IO.Path]::GetTempFileName()
  $previousErrorActionPreference = $ErrorActionPreference
  $taskkillExitCode = -1
  try {
    $ErrorActionPreference = 'Continue'
    & $taskkillPath /PID $TargetPid /F /T 1>$stdoutPath 2>$stderrPath
    $taskkillExitCode = [int]$LASTEXITCODE
    # Harden 2026-06-22 (operator, control-plane reliability): taskkill's exit code is an
    # UNRELIABLE success signal -- it returns non-0 when the PID has ALREADY exited (a false
    # failure), and 0 does not guarantee a reparented/zombie child actually died (a false
    # success -> orphaned worker). So verify the REAL outcome: poll briefly for the target to
    # disappear; if a straggler remains, force-kill it via Stop-Process; report success on
    # ACTUAL termination. That is what every caller of .success really wants ("is it dead").
    $stillAlive = $true
    for ($vi = 0; $vi -lt 10; $vi++) {
      if (-not (Get-Process -Id $TargetPid -ErrorAction SilentlyContinue)) { $stillAlive = $false; break }
      Start-Sleep -Milliseconds 300
    }
    if ($stillAlive) {
      try { Stop-Process -Id $TargetPid -Force -ErrorAction SilentlyContinue } catch {}
      Start-Sleep -Milliseconds 300
      $stillAlive = [bool](Get-Process -Id $TargetPid -ErrorAction SilentlyContinue)
    }
    $stdoutText = Read-SupervisorTempFirstLine -Path $stdoutPath -Label 'taskkill stdout'
    $stderrText = Read-SupervisorTempFirstLine -Path $stderrPath -Label 'taskkill stderr'
    return [pscustomobject]@{
      success = (-not $stillAlive)
      stillAlive = $stillAlive
      exitCode = $taskkillExitCode
      stdout = $stdoutText
      stderr = $stderrText
      reason = $Reason
    }
  } catch {
    return [pscustomobject]@{
      success = $false
      exitCode = -1
      stdout = ''
      stderr = $_.Exception.Message
      reason = $Reason
    }
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
    foreach ($path in @($stdoutPath, $stderrPath)) {
      try {
        if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
      } catch {
        [System.Diagnostics.Trace]::TraceError("taskkill temp cleanup failed: " + $_.Exception.Message)
      }
    }
  }
}

function Read-SupervisorTempFirstLine {
  param(
    [string]$Path,
    [string]$Label = 'temp output'
  )
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return '' }
  try {
    $lines = @(Get-Content -LiteralPath $Path -TotalCount 1 -ErrorAction Stop)
    if ($lines.Count -eq 0) { return '' }
    return ([string]$lines[0]).Trim()
  } catch {
    [System.Diagnostics.Trace]::TraceError($Label + " read failed: " + $_.Exception.Message)
    return ''
  }
}

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

function Close-BridgeProcessHandle {
  param(
    [System.Diagnostics.Process]$Process,
    [string]$Reason = 'cleanup'
  )
  if ($null -eq $Process) { return }
  $pidForLog = '?'
  try { $pidForLog = [string]([int]$Process.Id) } catch {}
  try {
    $Process.Dispose()
  } catch {
    [System.Diagnostics.Trace]::TraceError($Reason + " process handle cleanup failed for PID " + $pidForLog + ": " + $_.Exception.Message)
  }
}

function Clear-TrackedBridgeProcessReference {
  param(
    [System.Diagnostics.Process]$Process,
    [string]$Reason = 'cleanup'
  )
  if ($null -eq $Process) { return $false }
  $targetPid = $null
  $targetStartTime = $null
  try { $targetPid = [int]$Process.Id } catch {}
  try { $targetStartTime = $Process.StartTime } catch {}
  $cleared = $false
  if (Test-SameBridgeProcessHandle -Candidate $script:srv -Target $Process -TargetPid $targetPid -TargetStartTime $targetStartTime) {
    $script:srv = $null
    $cleared = $true
  }
  if ($script:drivers) {
    foreach ($slug in @($script:drivers.Keys)) {
      if (Test-SameBridgeProcessHandle -Candidate $script:drivers[$slug] -Target $Process -TargetPid $targetPid -TargetStartTime $targetStartTime) {
        $script:drivers[$slug] = $null
        $cleared = $true
      }
    }
  }
  Close-BridgeProcessHandle -Process $Process -Reason $Reason
  return $cleared
}

function Test-SameBridgeProcessHandle {
  param(
    [System.Diagnostics.Process]$Candidate,
    [System.Diagnostics.Process]$Target,
    [object]$TargetPid = $null,
    [object]$TargetStartTime = $null
  )
  if ($null -eq $Candidate -or $null -eq $Target) { return $false }
  if ([object]::ReferenceEquals($Candidate, $Target)) { return $true }
  if ($null -eq $TargetPid) { return $false }
  try {
    if ([int]$Candidate.Id -ne [int]$TargetPid) { return $false }
    if ($null -ne $TargetStartTime) { return ($Candidate.StartTime -eq $TargetStartTime) }
    return $true
  } catch {
    return $false
  }
}

function Stop-TrackedBridgeProcess {
  param(
    [System.Diagnostics.Process]$Process,
    [string]$Reason,
    [int]$WaitMs = 0
  )
  if (-not (Test-TrackedBridgeProcess -Process $Process)) { return $false }
  $trackedPid = [int]$Process.Id
  $waitForExitMs = Get-SupervisorStopWaitMs -RequestedWaitMs $WaitMs
  try {
    Log ($Reason + " -> stopping tracked PID " + $trackedPid)
    $killResult = Invoke-TaskkillTree -TargetPid $trackedPid -Reason $Reason
    if (-not $killResult.success) {
      Log ("WARN: taskkill failed for PID " + $trackedPid + " exitCode=" + $killResult.exitCode + " stdout=" + $killResult.stdout + " stderr=" + $killResult.stderr)
    }
    $exited = $Process.WaitForExit($waitForExitMs)
    if (-not $exited) {
      Log ("WARN: PID " + $trackedPid + " did not exit within " + $waitForExitMs + "ms after kill - possible zombie; issuing secondary kill")
      $secondaryKill = Invoke-TaskkillTree -TargetPid $trackedPid -Reason ($Reason + ' secondary')
      if (-not $secondaryKill.success) {
        Log ("WARN: secondary taskkill failed for PID " + $trackedPid + " exitCode=" + $secondaryKill.exitCode + " stdout=" + $secondaryKill.stdout + " stderr=" + $secondaryKill.stderr)
        try {
          Stop-Process -Id $trackedPid -Force -ErrorAction Stop
        } catch {
          Log ("WARN: Stop-Process fallback failed for PID " + $trackedPid + ": " + $_.Exception.Message)
        }
      }
      if (-not [bool]$Process.WaitForExit(1000)) {
        Log ("WARN: PID " + $trackedPid + " still did not report exit after secondary kill; caller will clear tracked handle and continue")
      }
    }
    return $true
  } catch {
    Log ($Reason + " stop error for PID " + $trackedPid + ": " + $_.Exception.Message)
    return $false
  }
}
function Kill-Bridge {
  $currentUser = "$env:USERDOMAIN\$env:USERNAME"
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*\server.ps1*' -or $_.CommandLine -like '*\driver.ps1*' } |
    Where-Object {
      if ($_.ProcessId -eq $PID) { return $false }
      try {
        $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwner
        "$($owner.Domain)\$($owner.User)" -eq $currentUser
      } catch { $false }
    } |
    ForEach-Object { $null = Invoke-TaskkillTree -TargetPid ([int]$_.ProcessId) -Reason 'Kill-Bridge' }
}
function Reap-Bloated {
  # Memory-leak guard: kill any bridge server/driver powershell whose PRIVATE memory exceeds the
  # cap. A runaway (e.g. the /api/radar ConvertTo-Json -Depth 10 OOM that spawned 50-70GB zombie powershell)
  # never recovers and strangles the whole machine. The loop below then restarts a fresh one.
  # The supervisor is ELEVATED, so it CAN kill these (a non-elevated watchdog cannot). Match by
  # PRIVATE memory (zombies had small working sets but 70GB private). /F only (no /T) to spare
  # any codex children. Defaults: cap 8GB, warn 6GB; no healthy bridge powershell approaches this.
  $reaped = $false
  try {
    $reapCapMb = 8192
    $reapWarnMb = 6144
    $reapGraceMs = 60000
    try {
      $reapCfg = Get-BridgeConfig
      if ($reapCfg -and $reapCfg.supervisor) {
        if ($null -ne $reapCfg.supervisor.reapBloatedMB) { $reapCapMb = [int]$reapCfg.supervisor.reapBloatedMB }
        if ($null -ne $reapCfg.supervisor.reapWarnMB) { $reapWarnMb = [int]$reapCfg.supervisor.reapWarnMB }
        if ($null -ne $reapCfg.supervisor.reapGraceMs) { $reapGraceMs = [int]$reapCfg.supervisor.reapGraceMs }
      }
    } catch {
      Log ("WARN: Reap-Bloated config read failed, using defaults: " + $_.Exception.Message)
    }
    if ($reapCapMb -le 0) { $reapCapMb = 8192 }
    if ($reapWarnMb -le 0) { $reapWarnMb = 6144 }
    if ($reapGraceMs -lt 0) { $reapGraceMs = 60000 }
    $now = Get-Date
    foreach ($proc in (Get-TrackedBridgeProcesses)) {
      if (Test-TrackedBridgeProcess -Process $proc) {
        $priv = 0; try { $priv = [int64](Get-Process -Id $proc.Id -ErrorAction SilentlyContinue).PrivateMemorySize64 } catch {}
        if ($priv -gt ($reapCapMb * 1MB)) {
          if (-not $script:bloatedSince.ContainsKey($proc.Id)) {
            $script:bloatedSince[$proc.Id] = $now
            Log ("WARN: bloated PID " + $proc.Id + " private=" + [int]($priv/1MB) + "MB > cap threshold " + $reapCapMb + "MB; grace started")
          }
          $elapsedMs = ($now - $script:bloatedSince[$proc.Id]).TotalMilliseconds
          if ($elapsedMs -ge $reapGraceMs) {
            $reapedPid = [int]$proc.Id
            Log ("REAP: bloated tracked PID " + $reapedPid + " private=" + [int]($priv/1MB) + "MB > " + $reapCapMb + "MB for " + [int]$elapsedMs + "ms -> kill (mem-leak guard)")
            if (Stop-TrackedBridgeProcess -Process $proc -Reason 'REAP') {
              $script:bloatedSince.Remove($reapedPid)
              $null = Clear-TrackedBridgeProcessReference -Process $proc -Reason 'REAP'
              $reaped = $true
            }
          }
        } else {
          if ($script:bloatedSince.ContainsKey($proc.Id)) { $script:bloatedSince.Remove($proc.Id) }
          if ($priv -gt ($reapWarnMb * 1MB)) {
            Log ("WARN: bloated PID " + $proc.Id + " private=" + [int]($priv/1MB) + "MB > warn threshold")
          }
        }
      }
    }
  } catch { Log ("reap error: " + $_.Exception.Message) }
  return $reaped
}
function Test-RedirectLogWritable {
  param([string]$Path, [string]$Label)
  $target = $Path
  try {
    $fs = [System.IO.File]::Open($target, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
    if ($fs) { $fs.Dispose() }
  } catch {
    $fallback = [System.IO.Path]::GetTempFileName()
    Log ("WARN: cannot write " + $Label + " log " + $target + ", fallback to " + $fallback + ": " + $_.Exception.Message)
    $target = $fallback
  }
  return $target
}
function Get-ProcessExitTail {
  param(
    [string]$ErrLogPath,
    [int]$Lines = 20
  )
  if ([string]::IsNullOrWhiteSpace($ErrLogPath) -or -not (Test-Path -LiteralPath $ErrLogPath)) {
    return "(no stderr output)"
  }
  try {
    $tail = @(Get-Content -LiteralPath $ErrLogPath -Encoding UTF8 -Tail $Lines -ErrorAction Stop)
    if ($tail.Count -eq 0 -or [string]::IsNullOrWhiteSpace(($tail -join "`n"))) {
      return "(no stderr output)"
    }
    return ($tail -join "`n")
  } catch {
    return "(no stderr output)"
  }
}
function Write-ProcessExitTailLog {
  param(
    [Parameter(Mandatory=$true)][string]$ProcessKey,
    [Parameter(Mandatory=$true)][string]$ErrLogPath,
    [int]$Lines = 20
  )
  $tail = Get-ProcessExitTail -ErrLogPath $ErrLogPath -Lines $Lines
  foreach ($line in @($tail -split "\r?\n")) {
    Log ("  stderr> " + $line)
  }
}
function Invoke-FatalProcessExitBlock {
  param(
    [Parameter(Mandatory=$true)][string]$ProcessKey,
    [Parameter(Mandatory=$true)][int]$ExitCode,
    [Parameter(Mandatory=$true)][string]$FatalListName,
    [Parameter(Mandatory=$true)][string]$OperatorText
  )
  Log ($ProcessKey + " FATAL exitCode=" + $ExitCode + " in " + $FatalListName + " - NOT restarting. Manual fix required.")
  try { Add-Message -From system -Text $OperatorText -Kind event | Out-Null }
  catch { Log ("WARN: failed to add fatal-exit operator message: " + $_.Exception.Message) }
  try { Send-PushEvent -Kind need_you -Text $OperatorText }
  catch { Log ("WARN: failed to send fatal-exit push event: " + $_.Exception.Message) }
}
function Invoke-ServerExitHandling {
  param(
    [Parameter(Mandatory=$true)][System.Diagnostics.Process]$Process,
    [bool]$ReapFired = $false
  )
  $exitCode = 0
  try { $exitCode = [int]$Process.ExitCode } catch { $exitCode = -1 }
  Log (Format-SupervisorProcessExitLine -ProcessKey 'server' -ExitCode $exitCode)
  Write-ProcessExitTailLog -ProcessKey 'server' -ErrLogPath $srvErr
  # 2026-06-01 ROOT FIX: a CLEAN exit (code 0) is a managed/normal restart (restart.flag recycle,
  # operator stop/start, graceful supervisor reload), NOT a crash — it must NOT trip the circuit
  # breaker. Only abnormal (non-zero) exits count toward the restart-storm window. Observed: a single
  # operator restart cascaded into 4 clean "server exited with code 0" records, which (mislabeled
  # cause=unknown) tripped a 15-min cooldown that froze ALL drivers across every channel.
  if (-not $ReapFired -and $exitCode -ne 0) {
    Record-CircuitRestart -Detail ("server exited with code " + $exitCode) -ReapFired:$false -FlagPresent:$false
  }
  if (Test-SupervisorFatalExitCode -ExitCode $exitCode -FatalCodes $script:fatalExitSettings.fatalServerExitCodes) {
    $script:serverFatalBlock = Get-Date
    Invoke-FatalProcessExitBlock -ProcessKey 'server' -ExitCode $exitCode -FatalListName 'fatalServerExitCodes' -OperatorText ("🚨 Server завершился с фатальным кодом " + $exitCode + ". Авто-рестарт ЗАБЛОКИРОВАН. Нужно вмешательство оператора.")
    return $true
  }
  return $false
}
function Invoke-DriverExitHandling {
  param(
    [Parameter(Mandatory=$true)][string]$Slug,
    [Parameter(Mandatory=$true)][System.Diagnostics.Process]$Process,
    [bool]$ReapFired = $false
  )
  $exitCode = 0
  try { $exitCode = [int]$Process.ExitCode } catch { $exitCode = -1 }
  $processKey = "driver[" + $Slug + "]"
  $errPath = Join-Path $ctl ("driver." + $Slug + ".err.log")
  Log (Format-SupervisorProcessExitLine -ProcessKey $processKey -ExitCode $exitCode)
  Write-ProcessExitTailLog -ProcessKey $processKey -ErrLogPath $errPath
  # 2026-06-01 ROOT FIX: clean driver exit (code 0) = managed/normal restart (restart.flag, operator
  # stop/start, graceful recycle), NOT a crash — must NOT trip the breaker. Only non-zero exits count.
  if (-not $ReapFired -and $exitCode -ne 0) {
    Record-CircuitRestart -Detail ("driver[" + $Slug + "] exited with code " + $exitCode) -ReapFired:$false -FlagPresent:$false
  }
  if (Test-SupervisorFatalExitCode -ExitCode $exitCode -FatalCodes $script:fatalExitSettings.fatalDriverExitCodes) {
    $script:driverFatalBlock[$Slug] = Get-Date
    Invoke-FatalProcessExitBlock -ProcessKey $processKey -ExitCode $exitCode -FatalListName 'fatalDriverExitCodes' -OperatorText ("🚨 Driver[" + $Slug + "] завершился с фатальным кодом " + $exitCode + " (конфиг/инициализация). Авто-рестарт ЗАБЛОКИРОВАН. Нужно вмешательство оператора.")
    return $true
  }
  return $false
}
function Start-Srv {
  $integrityEnabled = [bool]($cfg.supervisor.scriptIntegrityEnabled)
  $manifestRelPath  = if ($cfg.supervisor.scriptIntegrityManifest) { [string]$cfg.supervisor.scriptIntegrityManifest } else { 'security/script-integrity.json' }
  if ($integrityEnabled) {
    $guardResult = Invoke-BridgeIntegrityGuard -Root $root -RelativePath 'server.ps1' -ManifestRelativePath $manifestRelPath -Action {
      $out2 = Test-RedirectLogWritable -Path $srvOut -Label 'server stdout'
      $err2 = Test-RedirectLogWritable -Path $srvErr -Label 'server stderr'
      try {
        $proc = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'server.ps1') `
          -NoNewWindow -PassThru -RedirectStandardOutput $out2 -RedirectStandardError $err2 -ErrorAction Stop
        if ($null -eq $proc) { Log "WARN: Start-Srv returned null process" }
        elseif ($proc.HasExited) { Log ("WARN: Start-Srv process exited immediately with code " + $proc.ExitCode) }
        return $proc
      } catch {
        Log ("START-FAIL: " + $_.Exception.Message)
        return $null
      }
    }
    if (-not $guardResult.Ok) {
      $failKey = 'server.ps1:' + $guardResult.Reason
      if (-not $script:integrityFailureLogged[$failKey]) {
        Log ("ERROR: integrity check failed for server.ps1 reason=" + $guardResult.Reason + " expected=" + $guardResult.Expected + " actual=" + $guardResult.Actual)
        $script:integrityFailureLogged[$failKey] = $true
      }
      return $null
    }
    return $guardResult.ActionResult
  }
  $out = Test-RedirectLogWritable -Path $srvOut -Label 'server stdout'
  $err = Test-RedirectLogWritable -Path $srvErr -Label 'server stderr'
  try {
    $proc = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'server.ps1') `
      -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err -ErrorAction Stop
    if ($null -eq $proc) { Log "WARN: Start-Srv returned null process" }
    elseif ($proc.HasExited) { Log ("WARN: Start-Srv process exited immediately with code " + $proc.ExitCode) }
    return $proc
  } catch {
    Log ("START-FAIL: " + $_.Exception.Message)
    return $null
  }
}
function Start-Drv {
  param([string]$Slug)
  $integrityEnabled = [bool]($cfg.supervisor.scriptIntegrityEnabled)
  $manifestRelPath  = if ($cfg.supervisor.scriptIntegrityManifest) { [string]$cfg.supervisor.scriptIntegrityManifest } else { 'security/script-integrity.json' }
  $drvOut = Join-Path $ctl ("driver." + $Slug + ".out.log")
  $drvErr = Join-Path $ctl ("driver." + $Slug + ".err.log")
  if ($integrityEnabled) {
    $guardResult = Invoke-BridgeIntegrityGuard -Root $root -RelativePath 'driver.ps1' -ManifestRelativePath $manifestRelPath -Action {
      $out2 = Test-RedirectLogWritable -Path $drvOut -Label ("driver[" + $Slug + "] stdout")
      $err2 = Test-RedirectLogWritable -Path $drvErr -Label ("driver[" + $Slug + "] stderr")
      try {
        $proc = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'driver.ps1'),'-Channel',$Slug `
          -NoNewWindow -PassThru -RedirectStandardOutput $out2 -RedirectStandardError $err2 -ErrorAction Stop
        if ($null -eq $proc) { Log ("WARN: Start-Drv[" + $Slug + "] returned null process") }
        elseif ($proc.HasExited) { Log ("WARN: Start-Drv[" + $Slug + "] process exited immediately with code " + $proc.ExitCode) }
        return $proc
      } catch {
        Log ("START-FAIL: " + $_.Exception.Message)
        return $null
      }
    }
    if (-not $guardResult.Ok) {
      $failKey = 'driver.ps1:' + $guardResult.Reason
      if (-not $script:integrityFailureLogged[$failKey]) {
        Log ("ERROR: integrity check failed for driver.ps1 reason=" + $guardResult.Reason + " expected=" + $guardResult.Expected + " actual=" + $guardResult.Actual)
        $script:integrityFailureLogged[$failKey] = $true
      }
      return $null
    }
    return $guardResult.ActionResult
  }
  $out = Test-RedirectLogWritable -Path $drvOut -Label ("driver[" + $Slug + "] stdout")
  $err = Test-RedirectLogWritable -Path $drvErr -Label ("driver[" + $Slug + "] stderr")
  try {
    $proc = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $root 'driver.ps1'),'-Channel',$Slug `
      -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err -ErrorAction Stop
    if ($null -eq $proc) { Log ("WARN: Start-Drv[" + $Slug + "] returned null process") }
    elseif ($proc.HasExited) { Log ("WARN: Start-Drv[" + $Slug + "] process exited immediately with code " + $proc.ExitCode) }
    return $proc
  } catch {
    Log ("START-FAIL: " + $_.Exception.Message)
    return $null
  }
}
function Get-ActiveSlugs {
  # Non-archived channel slugs, in stable order.
  $list = @(Get-ChannelList)
  $slugs = @($list | ForEach-Object { [string]$_.slug } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($slugs.Count -eq 0) { $slugs = @('main') }
  return $slugs
}
function Invoke-SupervisorPinnedChannel {
  param(
    [Parameter(Mandatory=$true)][string]$Slug,
    [Parameter(Mandatory=$true)][scriptblock]$Body
  )
  $oldPin = $null; $hadPin = $false
  try {
    if (Get-Command Get-PinnedChannel -ErrorAction SilentlyContinue) { $oldPin = Get-PinnedChannel; $hadPin = $true }
    if (Get-Command Set-PinnedChannel -ErrorAction SilentlyContinue) { Set-PinnedChannel $Slug }
    return (& $Body)
  } finally {
    if ($hadPin -and (Get-Command Set-PinnedChannel -ErrorAction SilentlyContinue)) {
      try { Set-PinnedChannel $oldPin } catch {}
    }
  }
}
function Get-SupervisorChannelStatePath {
  param([Parameter(Mandatory=$true)][string]$Slug)
  return (Invoke-SupervisorPinnedChannel -Slug $Slug -Body { Get-StatePath })
}
function Update-SupervisorSuccessfulHeartbeat {
  param([string[]]$Slugs)
  $nowIso = (Get-Date).ToUniversalTime().ToString('o')
  foreach ($slug in @($Slugs)) {
    if ([string]::IsNullOrWhiteSpace($slug)) { continue }
    try {
      $heartbeatIso = $nowIso
      Invoke-SupervisorPinnedChannel -Slug $slug -Body ({
        Update-State {
          param($s)
          $s | Add-Member -NotePropertyName lastSuccessfulHeartbeat -NotePropertyValue $heartbeatIso -Force
        } | Out-Null
      }.GetNewClosure()) | Out-Null
    } catch {
      Log ("WARN: lastSuccessfulHeartbeat update failed for channel '" + $slug + "': " + $_.Exception.Message)
    }
  }
}
function Get-SupervisorStaleHeartbeatSlugs {
  param(
    [string[]]$Slugs,
    [int]$MaxAgeSeconds = 600
  )
  $now = Get-Date
  $stale = New-Object 'System.Collections.Generic.List[string]'
  foreach ($slug in @($Slugs)) {
    if ([string]::IsNullOrWhiteSpace($slug)) { continue }
    try {
      $statePath = Get-SupervisorChannelStatePath -Slug $slug
      if (-not $statePath -or -not (Test-Path -LiteralPath $statePath)) { continue }
      $state = $null
      try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
      $rawHeartbeat = $null
      try {
        if ($state -and ($state.PSObject.Properties.Name -contains 'lastSuccessfulHeartbeat')) {
          $rawHeartbeat = [string]$state.lastSuccessfulHeartbeat
        }
      } catch {}
      if ([string]::IsNullOrWhiteSpace($rawHeartbeat)) {
        if (-not $script:watchdogHeartbeatMissingSince.ContainsKey($slug)) { $script:watchdogHeartbeatMissingSince[$slug] = $now }
        if (($now - [datetime]$script:watchdogHeartbeatMissingSince[$slug]).TotalSeconds -ge $MaxAgeSeconds) { [void]$stale.Add($slug) }
        continue
      }
      if ($script:watchdogHeartbeatMissingSince.ContainsKey($slug)) { $script:watchdogHeartbeatMissingSince.Remove($slug) }
      $hb = $null
      try { $hb = [datetime]::Parse($rawHeartbeat).ToUniversalTime() } catch { $hb = $null }
      if ($null -eq $hb) {
        if (-not $script:watchdogHeartbeatMissingSince.ContainsKey($slug)) { $script:watchdogHeartbeatMissingSince[$slug] = $now }
        if (($now - [datetime]$script:watchdogHeartbeatMissingSince[$slug]).TotalSeconds -ge $MaxAgeSeconds) { [void]$stale.Add($slug) }
        continue
      }
      if (((Get-Date).ToUniversalTime() - $hb).TotalSeconds -ge $MaxAgeSeconds) { [void]$stale.Add($slug) }
    } catch {
      Log ("WARN: lastSuccessfulHeartbeat stale-check failed for channel '" + $slug + "': " + $_.Exception.Message)
    }
  }
  return @($stale.ToArray())
}
function Reset-WatchdogForSupervisorHeartbeat {
  param([string[]]$StaleSlugs)
  if (-not $StaleSlugs -or @($StaleSlugs).Count -eq 0) { return $false }
  $now = Get-Date
  if ($script:watchdogHeartbeatResetUntil -and $now -lt $script:watchdogHeartbeatResetUntil) { return $false }
  $script:watchdogHeartbeatResetUntil = $now.AddMinutes(10)
  $sample = (@($StaleSlugs) | Select-Object -First 4) -join ','
  Log ("lastSuccessfulHeartbeat stale/missing for channel(s) " + $sample + " -> watchdog reset")
  try {
    Add-Message -From system -Text ("⚠ lastSuccessfulHeartbeat stale/missing >10min for channel(s): " + $sample + " — resetting watchdog safety-net.") -Kind event | Out-Null
  } catch {}
  try {
    $wdProcs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -like '*-File*watchdog.ps1*' -and $_.CommandLine -notlike '*-Command*' })
    foreach ($wd in $wdProcs) {
      try { Stop-Process -Id ([int]$wd.ProcessId) -Force -ErrorAction SilentlyContinue } catch {}
    }
  } catch { Log ("watchdog reset stop error: " + $_.Exception.Message) }
  return $true
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

function Get-SupervisorRestartLimitFilePath {
  # Lives under the user profile (NOT OneDrive/bridge root) so counters survive
  # supervisor crashes AND bridge-root rollbacks alike.
  return (Join-Path $HOME '.bridge-runtime\restart-limits.json')
}
function ConvertTo-SupervisorRestartLimitDocument {
  # Pure: in-memory limiter state -> persistable contract document.
  # Prunes attempts older than the configured window and expired cooldowns.
  param(
    [Parameter(Mandatory=$true)][hashtable]$State,
    [Parameter(Mandatory=$true)][object]$Settings,
    [datetime]$Now = (Get-Date)
  )
  $nowUtc = ([datetime]$Now).ToUniversalTime()
  $cutoffUtc = $nowUtc.AddMinutes(-1 * [Math]::Max(1, [int]$Settings.windowMin))
  $channels = [ordered]@{}
  foreach ($key in @($State.Keys | Sort-Object)) {
    $entry = $State[$key]
    if ($null -eq $entry) { continue }
    $attempts = @(@($entry.attempts) | ForEach-Object {
      try { ([datetime]$_).ToUniversalTime() } catch {}
    } | Where-Object { $_ -is [datetime] -and $_ -ge $cutoffUtc } | Sort-Object)
    $cooldownIso = $null
    if ($entry.cooldownUntil) {
      try {
        $cu = ([datetime]$entry.cooldownUntil).ToUniversalTime()
        if ($cu -gt $nowUtc) { $cooldownIso = $cu.ToString('o') }
      } catch {}
    }
    if ((@($attempts).Count -eq 0) -and (-not $cooldownIso)) { continue }
    $channels[$key] = [ordered]@{
      count = @($attempts).Count
      windowStart = $(if (@($attempts).Count) { ([datetime]@($attempts)[0]).ToString('o') } else { $null })
      lastRestart = $(if (@($attempts).Count) { ([datetime]@($attempts)[-1]).ToString('o') } else { $null })
      attempts = @(@($attempts) | ForEach-Object { $_.ToString('o') })
      cooldownUntil = $cooldownIso
    }
  }
  return [ordered]@{ channels = $channels; updatedAt = $nowUtc.ToString('o') }
}
function Save-SupervisorRestartLimitStateFile {
  # Atomic persist (temp file + Move-Item -Force). Warn-only on failure: the
  # limiter must keep working in-memory even if the file is locked/unwritable.
  param(
    [Parameter(Mandatory=$true)][hashtable]$State,
    [Parameter(Mandatory=$true)][object]$Settings,
    [string]$Path = (Get-SupervisorRestartLimitFilePath),
    [datetime]$Now = (Get-Date)
  )
  $tmp = $null
  try {
    $doc = ConvertTo-SupervisorRestartLimitDocument -State $State -Settings $Settings -Now $Now
    $json = [pscustomobject]$doc | ConvertTo-Json -Depth 6
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $Path + '.tmp.' + $PID
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return $true
  } catch {
    try { Log ("WARN: restart-limit persist failed (continuing in-memory): " + $_.Exception.Message) } catch {}
    try { if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } } catch {}
    return $false
  }
}
function Import-SupervisorRestartLimitStateFile {
  # Restore limiter state across supervisor restarts. Any error -> empty state
  # (warn-only); stale attempts/expired cooldowns are pruned on load.
  param(
    [Parameter(Mandatory=$true)][object]$Settings,
    [string]$Path = (Get-SupervisorRestartLimitFilePath),
    [datetime]$Now = (Get-Date)
  )
  $state = New-SupervisorRestartLimitState
  try {
    if (-not (Test-Path -LiteralPath $Path)) { return $state }
    $raw = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $state }
    $doc = $raw | ConvertFrom-Json
    if (-not $doc -or -not ($doc.PSObject.Properties.Name -contains 'channels') -or -not $doc.channels) { return $state }
    $nowUtc = ([datetime]$Now).ToUniversalTime()
    $cutoffUtc = $nowUtc.AddMinutes(-1 * [Math]::Max(1, [int]$Settings.windowMin))
    foreach ($prop in @($doc.channels.PSObject.Properties)) {
      $key = [string]$prop.Name
      $chan = $prop.Value
      if ([string]::IsNullOrWhiteSpace($key) -or $null -eq $chan) { continue }
      $attempts = @()
      if (($chan.PSObject.Properties.Name -contains 'attempts') -and $chan.attempts) {
        foreach ($a in @($chan.attempts)) {
          try {
            $ts = ([datetime]$a).ToUniversalTime()
            if ($ts -ge $cutoffUtc -and $ts -le $nowUtc.AddMinutes(5)) { $attempts += $ts }
          } catch {}
        }
      } elseif (($chan.PSObject.Properties.Name -contains 'count') -and $chan.lastRestart) {
        # Contract-only shape (no attempts array): synthesize count attempts at lastRestart.
        try {
          $n = [int]$chan.count
          $ts = ([datetime]$chan.lastRestart).ToUniversalTime()
          if ($n -gt 0 -and $ts -ge $cutoffUtc) { for ($i = 0; $i -lt $n; $i++) { $attempts += $ts } }
        } catch {}
      }
      $cooldownUntil = $null
      if (($chan.PSObject.Properties.Name -contains 'cooldownUntil') -and $chan.cooldownUntil) {
        try {
          $cu = ([datetime]$chan.cooldownUntil).ToUniversalTime()
          if ($cu -gt $nowUtc) { $cooldownUntil = $cu }
        } catch {}
      }
      if ((@($attempts).Count -eq 0) -and ($null -eq $cooldownUntil)) { continue }
      $state[$key] = [pscustomobject]@{
        attempts = @($attempts | Sort-Object)
        cooldownUntil = $cooldownUntil
        lastCooldownNoticeAt = $null
      }
    }
    if (@($state.Keys).Count -gt 0) {
      try { Log ("restart-limit state restored from " + $Path + " (" + @($state.Keys).Count + " channel(s))") } catch {}
    }
  } catch {
    try { Log ("WARN: restart-limit state load failed (starting empty): " + $_.Exception.Message) } catch {}
    return (New-SupervisorRestartLimitState)
  }
  return $state
}

$script:restartLimitSettings = Get-SupervisorRestartLimitSettings -Config $cfg
$script:restartLimitState = Import-SupervisorRestartLimitStateFile -Settings $script:restartLimitSettings
$script:fatalExitSettings = Get-SupervisorFatalExitCodeSettings -Config $cfg
try {
  if ($cfg -and $cfg.supervisor -and $null -ne $cfg.supervisor.stopWaitMs) {
    $script:stopWaitMs = ConvertTo-SupervisorStopWaitMs -Value $cfg.supervisor.stopWaitMs -DefaultMs 5000
  }
} catch {
  Log ("WARN: supervisor.stopWaitMs config read failed, using " + $script:stopWaitMs + "ms: " + $_.Exception.Message)
}
$script:driverFatalBlock = @{}
$script:serverFatalBlock = $null
$script:maxConcurrentDrivers = 20
try {
  if ($cfg -and $cfg.supervisor -and $null -ne $cfg.supervisor.maxConcurrentDrivers) {
    $parsed = 0
    if ([int]::TryParse(([string]$cfg.supervisor.maxConcurrentDrivers), [ref]$parsed) -and $parsed -gt 0) {
      $script:maxConcurrentDrivers = $parsed
    } else {
      Log ("WARN: invalid supervisor.maxConcurrentDrivers='" + $cfg.supervisor.maxConcurrentDrivers + "', using default " + $script:maxConcurrentDrivers)
    }
  }
} catch {
  Log ("WARN: supervisor.maxConcurrentDrivers config read failed, using default " + $script:maxConcurrentDrivers + ": " + $_.Exception.Message)
}
function Test-SupervisorProcessStartAllowed {
  param([Parameter(Mandatory=$true)][string]$Key)
  $res = Test-SupervisorRestartAllowed -State $script:restartLimitState -Key $Key -Settings $script:restartLimitSettings `
    -LogCallback { param($m) Log $m } `
    -MessageCallback { param($m) Add-Message -From system -Text $m -Kind event | Out-Null } `
    -PushCallback { param($m) try { Send-PushEvent -Kind need_you -Text $m } catch {} }
  # Every gate call mutates state (attempt append / cooldown enter / window prune):
  # persist so counters survive a supervisor crash+restart. Warn-only inside.
  Save-SupervisorRestartLimitStateFile -State $script:restartLimitState -Settings $script:restartLimitSettings | Out-Null
  return [bool]$res.allowed
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
$script:watchdogHeartbeatMissingSince = @{}
$script:watchdogHeartbeatResetUntil = $null
$script:cbCooldownUntil = $null
$script:startupFailureCount = 0
$script:startupFailureLimit = 10
$script:startupFailureBackoffBaseSec = 3
$script:startupFailureBackoffMaxSec = 120
# Health-check state
$hcSrvIntervalSec  = 30    # server HTTP probe interval
$hcSrvTimeoutSec   = 8     # HTTP timeout per probe
$hcSrvHungLimit    = 3     # consecutive failures before kill+restart
$hcSrvLastTs       = [datetime]::MinValue
$hcSrvFails        = 0
$hcDrvIntervalSec  = 60    # driver CPU-stagnation probe interval
$hcDrvHungLimit    = 25    # consecutive zero-CPU intervals before kill+restart.
                           # 2026-06-12 (zatyk #5): 5 min false-killed drivers that were
                           # legitimately blocked on long Codex/LLM calls (3 kills in one
                           # evening); surviving tasks then died on the restart cap. Long
                           # coder chunks run 10-12 min, so the hung bar is 15 min now.
                           # 2026-06-20: 15->25 (operator directive: add time where a timeout
                           # kills a WORKING process). The heavy DONE-gate/finalization cycle
                           # (parse 307 ps1 + smoke + gate-regression) can hold the loop CPU-quiet
                           # ~12-15 min and looked stagnant; 25 min gives a working driver room.
$hcDrvGraceSec     = 300   # skip check if driver uptime < 5 min
$hcDrvLastTs       = [datetime]::MinValue
$hcDrvCpuSnaps     = @{}   # slug -> last TotalProcessorTime.Ticks (long)
$hcDrvFails        = @{}   # slug -> consecutive stagnant count
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

# 2026-06-03: ensure the EXTERNAL reliability anchor task exists. It heals a DEAD or HUNG
# supervisor/watchdog and a OneDrive-zeroed git ref every 5 min -- the failure modes the AtLogon
# task can't (orphaned children keep it "Running", so RestartCount never fires). The supervisor is
# elevated, so it can register the task with no manual admin step. Idempotent: registers only if missing.
try {
  $ensureTaskExists = $null
  try { $ensureTaskExists = Get-ScheduledTask -TaskName 'ClaudeCodexBridge-Ensure' -ErrorAction SilentlyContinue } catch {}
  if (-not $ensureTaskExists) {
    $installEnsure = Join-Path $root 'install-ensure-bridge.ps1'
    if (Test-Path $installEnsure) {
      & powershell -NoProfile -ExecutionPolicy Bypass -File $installEnsure 2>&1 | Out-Null
      Log "registered ClaudeCodexBridge-Ensure reliability anchor (was missing)"
    }
  }
} catch { Log ("ensure-anchor registration error: " + $_.Exception.Message) }

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
        Kill-Bridge; $srv = $null; $drivers = @{}; $script:driverFatalBlock = @{}; $script:serverFatalBlock = $null; Start-Sleep -Seconds 3
        $hcSrvFails = 0; $hcSrvLastTs = [datetime]::MinValue
        $hcDrvCpuSnaps = @{}; $hcDrvFails = @{}; $hcDrvLastTs = [datetime]::MinValue
        $lastRecycleTs = Get-Date
        Record-CircuitRestart -Detail 'restart.flag recycle' -ReapFired:$false -FlagPresent:$true
      }
    }
    $slugs = Get-ActiveSlugs
    try {
      $staleHeartbeatSlugs = @(Get-SupervisorStaleHeartbeatSlugs -Slugs $slugs -MaxAgeSeconds 600)
      if (Reset-WatchdogForSupervisorHeartbeat -StaleSlugs $staleHeartbeatSlugs) { $lastWdSpawn = $null }
      Update-SupervisorSuccessfulHeartbeat -Slugs $slugs
    } catch { Log ("lastSuccessfulHeartbeat supervisor loop error: " + $_.Exception.Message) }
    if (-not (Test-CircuitSpawnPaused)) {
      if ($null -eq $srv -or $srv.HasExited) {
        if ($null -ne $srv -and $srv.HasExited -and -not $reapFired) {
          $serverFatal = Invoke-ServerExitHandling -Process $srv -ReapFired:$false
          if ($serverFatal) { $srv = $null }
        }
        if ($script:serverFatalBlock) {
          # Fatal server exits require operator action or a supervisor recycle.
        } elseif (-not (Test-CircuitSpawnPaused)) {
          if (-not (Test-SupervisorProcessStartAllowed -Key 'server')) { continue }
          Log "starting server..."
          try {
            $srv = Start-Srv; Start-Sleep -Seconds 3
            if ($null -eq $srv) { throw "Start-Srv returned no process" }
            if ($srv.HasExited) {
              $serverFatal = Invoke-ServerExitHandling -Process $srv -ReapFired:$false
              if ($serverFatal) { $srv = $null; continue }
              throw ("server exited immediately with code " + $srv.ExitCode)
            }
            Reset-StartupFailures -Operation 'Start-Srv'
            $hcSrvFails = 0
            $hcSrvLastTs = Get-Date
          } catch {
            Register-StartupFailure -Operation 'Start-Srv' -ErrorRecord $_
            continue
          }
          Log ("server pid=" + $(if($srv){$srv.Id}else{'?'}) + " hasExited=" + $(if($srv){$srv.HasExited}else{'?'}))
        }
      }
      # Spawn one driver per non-archived channel; restart any that died.
      $driverStartupFailed = $false
      $activeDriverCount = @($drivers.Values | Where-Object { $_ -and -not $_.HasExited }).Count
      $maxDrvLimitWarnedThisPass = $false
      foreach ($slug in $slugs) {
        if ($script:driverFatalBlock.ContainsKey($slug)) { continue }
        $proc = $drivers[$slug]
        if ($null -eq $proc -or $proc.HasExited) {
          if ($null -ne $proc -and $proc.HasExited -and -not $reapFired) {
            $driverFatal = Invoke-DriverExitHandling -Slug $slug -Process $proc -ReapFired:$false
            if ($driverFatal) { $drivers[$slug] = $null; continue }
          }
          if (Test-CircuitSpawnPaused) { break }
          if (-not (Test-SupervisorProcessStartAllowed -Key ("driver:" + $slug))) { continue }
          # Enforce concurrent driver limit
          if ($activeDriverCount -ge $script:maxConcurrentDrivers) {
            if (-not $maxDrvLimitWarnedThisPass) {
              Log ("WARN: concurrent driver limit reached (" + $activeDriverCount + "/" + $script:maxConcurrentDrivers + ") - skipping spawn for '" + $slug + "' and possibly other channels (total channels: " + $slugs.Count + ")")
              $maxDrvLimitWarnedThisPass = $true
            }
            continue
          }
          Log ("starting driver for channel '" + $slug + "'...")
          try {
            $proc = Start-Drv -Slug $slug
            Start-Sleep -Seconds 2
            if ($null -eq $proc) { throw ("Start-Drv[" + $slug + "] returned no process") }
            if ($proc.HasExited) {
              $driverFatal = Invoke-DriverExitHandling -Slug $slug -Process $proc -ReapFired:$false
              if ($driverFatal) { $drivers[$slug] = $null; continue }
              throw ("driver[" + $slug + "] exited immediately with code " + $proc.ExitCode)
            }
            Reset-StartupFailures -Operation ("Start-Drv[" + $slug + "]")
            $hcDrvFails[$slug] = 0
            $hcDrvCpuSnaps[$slug] = $null
          } catch {
            Register-StartupFailure -Operation ("Start-Drv[" + $slug + "]") -ErrorRecord $_
            $driverStartupFailed = $true
            break
          }
          Log ("driver[" + $slug + "] pid=" + $(if($proc){$proc.Id}else{'?'}) + " hasExited=" + $(if($proc){$proc.HasExited}else{'?'}))
          $drivers[$slug] = $proc
          $activeDriverCount++
        }
      }
      if ($driverStartupFailed) { continue }
    }
    # --- Server HTTP health-check (hung detection) ---
    $hcNow = Get-Date
    if ($srv -and -not $srv.HasExited -and ($hcNow - $hcSrvLastTs).TotalSeconds -ge $hcSrvIntervalSec) {
      $hcSrvLastTs = $hcNow
      $srvHcOk = $false
      $srvHcError = ''
      $resp = $null
      try {
        $req = [System.Net.HttpWebRequest]::Create("http://localhost:$port/api/health")
        $req.Method = 'GET'
        $req.UserAgent = 'bridge-supervisor-healthcheck/1.0'
        $req.Timeout = $hcSrvTimeoutSec * 1000
        $req.ReadWriteTimeout = $hcSrvTimeoutSec * 1000
        $resp = $req.GetResponse()
        $statusCode = [int]$resp.StatusCode
        if ($statusCode -ge 200 -and $statusCode -lt 300) { $srvHcOk = $true }
        else { $srvHcError = "status=" + $statusCode }
      } catch {
        $srvHcError = $_.Exception.Message
      } finally {
        if ($resp) { $resp.Close() }
      }
      if ($srvHcOk) {
        if ($hcSrvFails -gt 0) { Log ("server health-check recovered after " + $hcSrvFails + " failure(s)") }
        $hcSrvFails = 0
      } else {
        $hcSrvFails++
        if ([string]::IsNullOrWhiteSpace($srvHcError)) { $srvHcError = 'no response' }
        Log ("server health-check FAIL (" + $hcSrvFails + "/" + $hcSrvHungLimit + "): " + $srvHcError)
        if ($hcSrvFails -ge $hcSrvHungLimit) {
          Log ("server HUNG (" + $hcSrvFails + " consecutive health-check failures) -> kill+restart")
          Add-Message -From system -Text ("⚠ Сервер не отвечает на /api/health " + $hcSrvHungLimit + " раз подряд — принудительный перезапуск.") -Kind event | Out-Null
          $stoppedSrv = $srv
          $null = Stop-TrackedBridgeProcess -Process $stoppedSrv -Reason 'health-check: server hung'
          $null = Clear-TrackedBridgeProcessReference -Process $stoppedSrv -Reason 'health-check: server hung'
          $srv = $null
          $hcSrvFails = 0
          $hcSrvLastTs = [datetime]::MinValue
          Record-CircuitRestart -Detail 'server unresponsive (health-check)'
        }
      }
    }

    # --- Driver CPU-stagnation health-check ---
    if (($hcNow - $hcDrvLastTs).TotalSeconds -ge $hcDrvIntervalSec) {
      $hcDrvLastTs = $hcNow
      foreach ($slug in @($drivers.Keys)) {
        $dproc = $drivers[$slug]
        if (-not $dproc -or $dproc.HasExited) { continue }
        try {
          $freshProc = Get-Process -Id $dproc.Id -ErrorAction Stop
          $uptimeSec = ($hcNow - $freshProc.StartTime).TotalSeconds
          if ($uptimeSec -lt $hcDrvGraceSec) { continue }
          $curTicks = $freshProc.TotalProcessorTime.Ticks
          $prevTicks = $hcDrvCpuSnaps[$slug]
          if ($null -ne $prevTicks -and $curTicks -eq $prevTicks) {
            $failCount = $hcDrvFails[$slug]
            if ($null -eq $failCount) { $failCount = 0 }
            $failCount++
            $hcDrvFails[$slug] = $failCount
            Log ("driver[" + $slug + "] CPU stagnant check " + $failCount + "/" + $hcDrvHungLimit + " (ticks=" + $curTicks + ")")
            if ($failCount -ge $hcDrvHungLimit) {
              Log ("driver[" + $slug + "] HUNG (CPU stagnant " + $hcDrvHungLimit + " x " + $hcDrvIntervalSec + "s) -> kill+restart")
              Add-Message -From system -Text ("⚠ Driver[" + $slug + "] завис (CPU не менялся " + ($hcDrvHungLimit * $hcDrvIntervalSec / 60) + " мин) — принудительный перезапуск.") -Kind event | Out-Null
              $stoppedDriver = $dproc
              $null = Stop-TrackedBridgeProcess -Process $stoppedDriver -Reason ("health-check: driver[" + $slug + "] hung")
              $null = Clear-TrackedBridgeProcessReference -Process $stoppedDriver -Reason ("health-check: driver[" + $slug + "] hung")
              $drivers[$slug] = $null
              $hcDrvFails[$slug] = 0
              $hcDrvCpuSnaps[$slug] = $null
              Record-CircuitRestart -Detail ("driver[" + $slug + "] unresponsive (CPU-stagnation health-check)")
            }
          } else {
            $prevFails = $hcDrvFails[$slug]
            if ($null -ne $prevFails -and $prevFails -gt 0) {
              Log ("driver[" + $slug + "] CPU active again after " + $prevFails + " stagnant check(s)")
            }
            $hcDrvFails[$slug] = 0
          }
          $hcDrvCpuSnaps[$slug] = $curTicks
        } catch {
          Log ("driver[" + $slug + "] health-check error: " + $_.Exception.Message)
        }
      }
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
        if ($p) {
          if (-not $p.HasExited) { $null = Stop-TrackedBridgeProcess -Process $p -Reason ("archive channel '" + $k + "'") }
          $null = Clear-TrackedBridgeProcessReference -Process $p -Reason ("archive channel '" + $k + "'")
        }
        $drivers.Remove($k)
      }
    }
  } catch { Log ("ERR " + $_.Exception.Message) }
  Start-Sleep -Seconds 5
}
Release-SupervisorLaunchLock -Lock $script:supervisorLaunchLock
