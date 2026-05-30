# jobs.ps1 -- background job manager for LONG-running commands (e.g. a project run that
# takes hours to debug). The agent launches a job via the [[RUNJOB: cmd | dir]] marker;
# it runs detached with output to jobs/<id>.log; the driver polls (not idle, no per-turn
# timeout) and, when done, feeds the result back to the agents. Dot-sourced from common.ps1.

function Get-JobsDir { Join-Path (Get-BridgeRoot) 'jobs' }

function Start-BridgeJob {
  # Launch $Command in the background. Returns a job record (hashtable) or $null.
  param([string]$Command, [string]$WorkDir = '')
  if ([string]::IsNullOrWhiteSpace($Command)) { return $null }
  $dir = Get-JobsDir
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $id      = [guid]::NewGuid().ToString('N').Substring(0,8)
  $mtxName = "Global\BridgeJob-$id"
  $log  = Join-Path $dir "$id.log"
  $done = Join-Path $dir "$id.done"
  $cmdF = Join-Path $dir "$id.cmd"
  $run  = Join-Path $dir "$id.run.ps1"
  if ([string]::IsNullOrWhiteSpace($WorkDir)) { try { $WorkDir = [string](Get-BridgeConfig).workRoot } catch { $WorkDir = (Get-BridgeRoot) } }
  $u8 = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($cmdF, [string]$Command, $u8)
  # Runner: holds Global\BridgeJob-<id> mutex for identity verification throughout execution.
  # Stop-BridgeJob uses this: if mutex acquirable (or abandoned), original process already exited.
  $runner = @"
`$ErrorActionPreference='Continue'
`$_jm = `$null
try { `$_jm = New-Object System.Threading.Mutex(`$true, '$mtxName') } catch {}
try {
  try { Set-Location -LiteralPath '$WorkDir' } catch {}
  `$c = (Get-Content -LiteralPath '$cmdF' -Raw)
  try { & `$env:ComSpec /c `$c *>> '$log' 2>&1 } catch { `$_ | Out-File -Append -LiteralPath '$log' }
  `$code = `$LASTEXITCODE; if (`$null -eq `$code) { `$code = 0 }
  [System.IO.File]::WriteAllText('$done', [string]`$code)
} finally {
  if (`$_jm) { try { `$_jm.ReleaseMutex() } catch {}; `$_jm.Dispose() }
}
"@
  [System.IO.File]::WriteAllText($run, $runner, (New-Object System.Text.UTF8Encoding($true)))
  try {
    $p = Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
      Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$run -WindowStyle Hidden -PassThru
    }
    $null = $p.Handle
    $ticks = 0; try { $ticks = $p.StartTime.Ticks } catch {}
    return [ordered]@{
      id = $id; cmd = [string]$Command; dir = $WorkDir; pid = $p.Id; startTicks = $ticks
      log = $log; done = $done; started = (Get-Date).ToUniversalTime().ToString('o')
      mutexName = $mtxName
    }
  } catch { return $null }
}

function Test-JobDone {
  param($Job)
  try { return (Test-Path -LiteralPath ([string]$Job.done)) } catch { return $true }
}

function Get-JobResult {
  # Returns @{ exitCode; tail } for a finished job (tail of output, capped).
  param($Job)
  $code = ''
  try { $raw = Get-Content -LiteralPath ([string]$Job.done) -Raw -ErrorAction SilentlyContinue; if ($raw) { $code = ([string]$raw).Trim() } } catch {}
  $tail = ''
  try { $tail = Get-Content -LiteralPath ([string]$Job.log) -Raw -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
  if ($null -eq $tail) { $tail = '' }
  if ($tail.Length -gt 3000) { $tail = '...(обрезано)...' + "`n" + $tail.Substring($tail.Length - 3000) }
  return @{ exitCode = $code; tail = $tail }
}

function Stop-BridgeJob {
  # Kill a job's process tree -- 3-layer identity verification:
  #   1. .done exists -> job completed naturally, skip.
  #   2. startTicks > 0 AND matches live process -> avoids killing when ticks unavailable
  #      (old: $ticks-le-0 killed blindly; fixed: require valid ticks).
  #   3. Named mutex Global\BridgeJob-<id>: acquirable or abandoned -> process already exited.
  #      Falls back to PID+ticks only for legacy records without mutexName.
  param($Job)
  $jp = 0; try { $jp = [int]$Job.pid } catch {}
  if ($jp -le 0) { return }
  if (Test-JobDone $Job) { return }
  try {
    $proc = Get-Process -Id $jp -ErrorAction SilentlyContinue
    $ticks = 0; try { $ticks = [long]$Job.startTicks } catch {}
    if ($proc -and $ticks -gt 0 -and $proc.StartTime.Ticks -eq $ticks) {
      $mtxName = ''; try { $mtxName = [string]$Job.mutexName } catch {}
      $kill = $true
      if ($mtxName -ne '') {
        try {
          $m = [System.Threading.Mutex]::OpenExisting($mtxName)
          try {
            if ($m.WaitOne(0)) {
              $kill = $false   # acquired -> process released -> already exited
              try { $m.ReleaseMutex() } catch {}
            }
            # WaitOne(0)=false -> mutex still held -> process running -> kill proceeds
          } catch [System.Threading.AbandonedMutexException] {
            $kill = $false     # abandoned -> process crashed/exited
            try { $m.ReleaseMutex() } catch {}
          } finally { $m.Dispose() }
        } catch {
          $kill = $false       # OpenExisting threw -> mutex gone -> process already exited
        }
      }
      if ($kill) { & taskkill /PID $jp /T /F 2>$null | Out-Null }
    }
  } catch {}
}
