# agent-wait.ps1 -- Waits for agent processes while tracking output progress and timeout reasons.
# Shared agent process wait helper.

function Wait-AgentProcess {
  # Wait for an agent process up to $TimeoutMs, refreshing the heartbeat every ~5s so a
  # long turn does not look dead to the watchdog.
  # Returns $true if the process exited within the timeout. When -StopReason is passed,
  # it receives: exited, zero_output_grace, hard_timeout, soft_timeout_no_signal,
  # or stagnation_timeout.
  param(
    $Proc,
    [int]$TimeoutMs,
    [string]$MsgFile='',
    [string]$ErrFile='',
    [string]$OutFile='',
    [int]$FirstOutputGraceMs=0,
    $StopReason=$null
  )
  if ($StopReason) { $StopReason.Value = 'running' }

  # 2026-05-29: ADAPTIVE timeout: kill by output stagnation, not by wall clock.
  # While out+err bytes keep growing the agent is alive; abort only after the
  # soft timeout plus a stall grace, or after the absolute hard ceiling.
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $softMs = [int]$TimeoutMs
  $stallGraceMs = 300000                                  # 5 min of zero output growth past soft = hung
  $hardMs = [Math]::Max([int]$TimeoutMs * 2, 3600000)     # absolute ceiling: 2x soft or 1h, whichever larger
  $haveSignal = (-not [string]::IsNullOrWhiteSpace($OutFile)) -or (-not [string]::IsNullOrWhiteSpace($ErrFile))
  $lastProgressMs = 0
  $lastTotLen = [long](-1)
  $lastTelemetrySec = -1
  $announcedAlive = $false
  $announcedZero = $false   # ERR-001: separate flag for the honest zero-output notice
  $sawAnyOutput = $false

  while ($true) {
    if ($Proc.WaitForExit(5000)) {
      if ($StopReason) { $StopReason.Value = 'exited' }
      return $true
    }

    try { Update-State { param($s) $s.heartbeat=(Get-Date).ToString('o') } | Out-Null } catch {}

    # Recycle coalescer (mid-turn): if a self-dev restart.flag appears while an
    # agent is running, defer it so the supervisor does not kill this turn.
    if ($Channel -eq 'main') {
      try {
        $rcCtl = Join-Path $bridgeRoot 'control'
        $rcF = Join-Path $rcCtl 'restart.flag'
        if (Test-Path -LiteralPath $rcF) {
          Move-Item -LiteralPath $rcF -Destination (Join-Path $rcCtl 'restart.deferred') -Force
          Write-Host 'recycle: deferred mid-turn restart.flag'
        }
      } catch {}
    }

    $elapsedMs = $sw.ElapsedMilliseconds
    $elapsedSec = [int]($elapsedMs / 1000)

    # Liveness signal: total bytes written to out+err. Growth means progress.
    $totLen = [long]0
    foreach ($fp in @($OutFile, $ErrFile)) {
      if (-not [string]::IsNullOrWhiteSpace($fp)) {
        $fi = Get-Item -LiteralPath $fp -ErrorAction SilentlyContinue
        if ($fi) { $totLen += [long]$fi.Length }
      }
    }
    if ($totLen -gt 0) { $sawAnyOutput = $true }
    if ($totLen -gt $lastTotLen) { $lastProgressMs = $elapsedMs; $lastTotLen = $totLen }
    $stalledMs = $elapsedMs - $lastProgressMs

    if ($elapsedSec - $lastTelemetrySec -ge 60) {
      $lastTelemetrySec = $elapsedSec
      try {
        $cpuSec = $null
        try { $cpuSec = [math]::Round((Get-Process -Id $Proc.Id -ErrorAction Stop).TotalProcessorTime.TotalSeconds, 2) } catch {}
        $fInfo = [ordered]@{}
        foreach ($pair in @(,@('msgF',$MsgFile),@('errF',$ErrFile),@('outF',$OutFile))) {
          $label = $pair[0]; $fpath = $pair[1]
          if (-not [string]::IsNullOrWhiteSpace($fpath)) {
            $fi = Get-Item $fpath -ErrorAction SilentlyContinue
            $fInfo[$label] = if ($fi) { [ordered]@{ len=[long]$fi.Length; mtime=$fi.LastWriteTime.ToString('o') } } else { [ordered]@{ len=0; mtime=$null } }
          }
        }
        $restartsHour = 0
        try {
          $rlPath = Join-Path (Get-RuntimeRoot) 'restarts.jsonl'
          if (Test-Path -LiteralPath $rlPath) {
            $since = (Get-Date).ToUniversalTime().AddHours(-1)
            $enc8 = New-Object System.Text.UTF8Encoding($false)
            $lines = [System.IO.File]::ReadAllLines($rlPath, $enc8)
            foreach ($rl in $lines) {
              $rlt = ([string]$rl).Trim()
              if ([string]::IsNullOrWhiteSpace($rlt)) { continue }
              try {
                $rev = $rlt | ConvertFrom-Json
                if ($rev.ts -and [datetime]::Parse($rev.ts, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) -ge $since) { $restartsHour++ }
              } catch {}
            }
          }
        } catch {}
        $telem = [ordered]@{ ts=(Get-Date).ToString('o'); elapsed_sec=$elapsedSec; cpu_sec=$cpuSec; stalled_sec=[int]($stalledMs/1000); files=$fInfo; restarts_last_hour=$restartsHour }
        Update-State ({ param($s) $s | Add-Member -NotePropertyName agent_telemetry -NotePropertyValue $telem -Force }.GetNewClosure()) | Out-Null
      } catch {}

      # 2026-06-01 ERR-001 fix: tell the TRUTH about output state past the soft timeout. The old code
      # claimed "output is still growing" whenever a file PATH existed ($haveSignal) and we were inside
      # the stall grace — even when out+err were 0 bytes the whole time (lastTotLen starts at -1, so the
      # first 0-byte sample counts as "growth" and freezes lastProgressMs at ~5s, making stalledMs look
      # small). Now we distinguish three real states using $sawAnyOutput and actual growth.
      if ($haveSignal -and $elapsedMs -ge $softMs) {
        $stSec = [int]($stalledMs / 1000)
        if ($sawAnyOutput -and $stalledMs -lt $stallGraceMs) {
          if (-not $announcedAlive) {
            $announcedAlive = $true
            try { Add-Message -From system -Text ("Agent is past the soft timeout (${elapsedSec}s), output is still growing (${totLen}B, last growth ${stSec}s ago); continuing to wait.") -Kind event | Out-Null } catch {}
          }
        } elseif (-not $sawAnyOutput -and -not $announcedZero) {
          $announcedZero = $true
          try { Add-Message -From system -Text ("⚠ Agent past soft timeout (${elapsedSec}s) with ZERO output so far (0 bytes in out+err). This is a stall, not progress — process is alive but silent; it will hit the stall-grace / hard ceiling if it stays silent.") -Kind event | Out-Null } catch {}
        }
      }
    }

    # Cold-start zero-output fast-fail: only for callers that opt in, and only
    # while the process is still alive and no byte has ever appeared in out+err.
    if ($FirstOutputGraceMs -gt 0 -and $haveSignal -and (-not $sawAnyOutput) -and $elapsedMs -ge $FirstOutputGraceMs) {
      if ($StopReason) { $StopReason.Value = 'zero_output_grace' }
      return $false
    }

    if ($elapsedMs -ge $hardMs) {
      if ($StopReason) { $StopReason.Value = 'hard_timeout' }
      return $false
    }
    if ($elapsedMs -ge $softMs) {
      if (-not $haveSignal) {
        if ($StopReason) { $StopReason.Value = 'soft_timeout_no_signal' }
        return $false
      }
      if ($stalledMs -ge $stallGraceMs) {
        if ($StopReason) { $StopReason.Value = 'stagnation_timeout' }
        return $false
      }
    }
  }
}
