function Wait-BridgeIdle {
  # Polls state.json until idle (no agent_pid, no active_jobs, status=='idle'). Returns
  # $true on idle, $false on timeout. Designed to be called inside a Start-Job from
  # driver.ps1 so a long wait doesn't block the main loop.
  param(
    [string]$StateFile,
    [int]$MaxMinutes = 60,
    [int]$PollSeconds = 30,
    [int]$StablePolls = 1
  )
  if ([string]::IsNullOrWhiteSpace($StateFile)) { return $false }
  if ($StablePolls -lt 1) { $StablePolls = 1 }
  $stableCount = 0
  $deadline = (Get-Date).AddMinutes($MaxMinutes)
  while ((Get-Date) -lt $deadline) {
    $isIdle = $false
    try {
      if (Test-Path -LiteralPath $StateFile) {
        $raw = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
          $st = $raw | ConvertFrom-Json
          $status = ''
          $agentPid = 0
          $activeCount = 0
          try { $status = [string]$st.status } catch {}
          try {
            if ($st.PSObject.Properties.Name -contains 'agent_pid' -and $null -ne $st.agent_pid) {
              $agentPid = [int]$st.agent_pid
            }
          } catch {}
          if (-not $agentPid) {
            try {
              if ($st.PSObject.Properties.Name -contains 'current_agent_pid' -and $null -ne $st.current_agent_pid) {
                $agentPid = [int]$st.current_agent_pid
              }
            } catch {}
          }
          try {
            if ($st.PSObject.Properties.Name -contains 'active_jobs' -and $st.active_jobs) {
              $activeCount = @($st.active_jobs).Count
            }
          } catch {}
          if ($status -eq 'idle' -and $agentPid -eq 0 -and $activeCount -eq 0) { $isIdle = $true }
        }
      }
    } catch {}
    if ($isIdle) {
      $stableCount++
      if ($stableCount -ge $StablePolls) { return $true }
    } else {
      $stableCount = 0
    }
    Start-Sleep -Seconds $PollSeconds
  }
  return $false
}
