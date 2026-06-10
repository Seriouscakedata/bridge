# lib/bridge-lock.ps1 -- singleton launch guard for supervisor.ps1.
# Uses a named mutex so Windows releases the lock automatically on process death.

function Get-SupervisorLaunchLockName {
  $override = ''
  try { $override = [string]$env:BRIDGE_SUPERVISOR_LOCK_NAME } catch { $override = '' }
  if (-not [string]::IsNullOrWhiteSpace($override)) { return $override }
  return 'Global\ClaudeCodexBridgeSupervisorInstance'
}

function Acquire-SupervisorLaunchLock {
  param([int]$TimeoutMs = 0)

  $mutex = $null
  try {
    $mutex = New-Object System.Threading.Mutex($false, (Get-SupervisorLaunchLockName))
    try {
      $got = $mutex.WaitOne($TimeoutMs)
    } catch [System.Threading.AbandonedMutexException] {
      $got = $true
    }

    if ($got) {
      return @{ acquired = $true; mutex = $mutex; reason = '' }
    }

    $mutex.Dispose()
    return @{ acquired = $false; mutex = $null; reason = 'another supervisor instance holds the lock' }
  } catch {
    $reason = $_.Exception.Message
    if ($mutex) {
      try { $mutex.Dispose() }
      catch { [System.Diagnostics.Trace]::TraceError("supervisor launch lock Dispose failed: " + $_.Exception.Message) }
    }
    return @{ acquired = $false; mutex = $null; reason = $reason }
  }
}

function Release-SupervisorLaunchLock {
  param($Lock)

  if (-not $Lock -or -not $Lock.acquired -or -not $Lock.mutex) { return }
  try {
    $Lock.mutex.ReleaseMutex()
  } catch {
    [System.Diagnostics.Trace]::TraceError("supervisor launch lock ReleaseMutex failed: " + $_.Exception.Message)
  } finally {
    try { $Lock.mutex.Dispose() }
    catch { [System.Diagnostics.Trace]::TraceError("supervisor launch lock Dispose failed: " + $_.Exception.Message) }
    $Lock['acquired'] = $false
    $Lock['mutex'] = $null
  }
}
