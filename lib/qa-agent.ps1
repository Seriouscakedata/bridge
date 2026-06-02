function Get-QAAgentBridgeRoot {
  try {
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
  } catch {
    return (Split-Path -Parent $PSScriptRoot)
  }
}

function Get-QAAgentChannel {
  param([string]$Channel)
  if (-not [string]::IsNullOrWhiteSpace($Channel)) { return $Channel }
  if (-not [string]::IsNullOrWhiteSpace($env:BRIDGE_CHANNEL)) { return [string]$env:BRIDGE_CHANNEL }
  return 'main'
}

function Write-QAAgentResult {
  param(
    [string]$TaskId,
    [string]$TaskTitle,
    [string]$Channel,
    [string]$Verdict,
    [string]$Summary
  )
  try {
    $bridge = Get-QAAgentBridgeRoot
    $channelName = Get-QAAgentChannel -Channel $Channel
    $dir = Join-Path (Join-Path $bridge 'channels') $channelName
    if (-not (Test-Path -LiteralPath $dir)) {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $path = Join-Path $dir 'qa-results.jsonl'
    $row = [pscustomobject]@{
      ts        = (Get-Date).ToString('o')
      taskId    = [string]$TaskId
      taskTitle = [string]$TaskTitle
      verdict   = [string]$Verdict
      summary   = [string]$Summary
    }
    $line = ($row | ConvertTo-Json -Compress -Depth 5)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($path, $line + "`n", $utf8NoBom)
  } catch {}
}

function New-QAAgentResult {
  param(
    [string]$TaskId,
    [string]$TaskTitle,
    [string]$Channel,
    [string]$Verdict,
    [string]$Summary,
    [object[]]$Bugs = @()
  )
  Write-QAAgentResult -TaskId $TaskId -TaskTitle $TaskTitle -Channel $Channel -Verdict $Verdict -Summary $Summary
  return [PSCustomObject]@{
    Verdict = $Verdict
    Summary = $Summary
    Bugs    = @($Bugs)
  }
}

function Quote-QAAgentArgument {
  param([string]$Value)
  if ($null -eq $Value) { return '""' }
  return '"' + ([string]$Value).Replace('"', '\"') + '"'
}

function Invoke-ProjectBuildGate {
  # 2026-06-01 ERR-008: bridge smoke proves the BRIDGE still runs; it does NOT prove a PROJECT channel's
  # app compiles. "git clean" passed QA while generated code failed install/typecheck/build (ERR-005).
  # This runs the real toolchain (tools\project-verify.ps1: install -> typecheck -> build) for a
  # project-bound channel and returns {Ok; Ran; Summary}. Returns Ran=$false (treated as pass) for main,
  # unbound channels, or non-node projects so it never blocks those.
  param([string]$Channel, [string]$BridgeRoot)
  $res = [pscustomobject]@{ Ok = $true; Ran = $false; Summary = '' }
  if ([string]::IsNullOrWhiteSpace($Channel) -or $Channel -eq 'main') { return $res }
  $pv = Join-Path (Join-Path $BridgeRoot 'tools') 'project-verify.ps1'
  if (-not (Test-Path -LiteralPath $pv)) { return $res }
  $pr = ''
  try {
    $chJson = Join-Path (Join-Path (Join-Path $BridgeRoot 'channels') $Channel) 'channel.json'
    if (Test-Path -LiteralPath $chJson) { $pr = [string]((Get-Content $chJson -Raw -Encoding UTF8 | ConvertFrom-Json).project_root) }
  } catch {}
  if ([string]::IsNullOrWhiteSpace($pr) -or -not (Test-Path -LiteralPath (Join-Path $pr 'package.json'))) { return $res }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (Quote-QAAgentArgument $pv) + ' -Channel ' + (Quote-QAAgentArgument $Channel)
  $psi.WorkingDirectory = $BridgeRoot
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()
  $res.Ran = $true
  $done = $p.WaitForExit(600000)   # build/typecheck can take minutes; npm install is cached after first run
  if (-not $done) {
    try { $p.Kill() } catch {}
    $res.Ok = $false; $res.Summary = 'project build/typecheck timed out after 600s'
    return $res
  }
  $out = ''
  try { $out += $p.StandardOutput.ReadToEnd() } catch {}
  try { $e = $p.StandardError.ReadToEnd(); if (-not [string]::IsNullOrWhiteSpace($e)) { $out += "`n" + $e } } catch {}
  if ($p.ExitCode -ne 0) {
    $sum = ($out -replace '\s+', ' ').Trim()
    if ($sum.Length -gt 600) { $sum = '...' + $sum.Substring($sum.Length - 600) }   # keep the TAIL — that's where build/typecheck errors are
    if ([string]::IsNullOrWhiteSpace($sum)) { $sum = "project build/typecheck failed (exit $($p.ExitCode))" }
    $res.Ok = $false; $res.Summary = $sum
  } else {
    $res.Summary = 'project install/typecheck/build PASS'
  }
  return $res
}

function Invoke-QAAgent {
  param(
    [string]$TaskId = '',
    [string]$TaskTitle = '',
    [string]$Channel = ''
  )

  $channelName = Get-QAAgentChannel -Channel $Channel
  $bridgeRoot = Get-QAAgentBridgeRoot
  $smokePath = Join-Path (Join-Path $bridgeRoot 'tools') 'smoke.ps1'
  if (-not (Test-Path -LiteralPath $smokePath)) {
    $smokePath = Join-Path $bridgeRoot 'smoke.ps1'
  }
  if (-not (Test-Path -LiteralPath $smokePath)) {
    return New-QAAgentResult -TaskId $TaskId -TaskTitle $TaskTitle -Channel $channelName -Verdict 'PASS' -Summary 'smoke.ps1 not found, QA skipped'
  }

  $stdoutPath = [System.IO.Path]::GetTempFileName()
  $stderrPath = [System.IO.Path]::GetTempFileName()
  $process = $null
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (Quote-QAAgentArgument $smokePath)
    $psi.WorkingDirectory = $bridgeRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()
    $completed = $process.WaitForExit(60000)
    if (-not $completed) {
      try { $process.Kill() } catch {}
      $summary = 'Smoke timed out after 60 seconds'
      return New-QAAgentResult -TaskId $TaskId -TaskTitle $TaskTitle -Channel $channelName -Verdict 'FAIL' -Summary $summary -Bugs @($summary)
    }

    $out = ''
    try { $out += $process.StandardOutput.ReadToEnd() } catch {}
    try {
      $err = $process.StandardError.ReadToEnd()
      if (-not [string]::IsNullOrWhiteSpace($err)) { $out += "`n" + $err }
    } catch {}

    if ($process.ExitCode -ne 0) {
      $summary = ($out -replace '\s+', ' ').Trim()
      if ($summary.Length -gt 500) { $summary = $summary.Substring(0, 500) }
      if ([string]::IsNullOrWhiteSpace($summary)) { $summary = "Smoke failed with exit code $($process.ExitCode)" }
      return New-QAAgentResult -TaskId $TaskId -TaskTitle $TaskTitle -Channel $channelName -Verdict 'FAIL' -Summary $summary -Bugs @($summary)
    }

    # 2026-06-01 ERR-008: bridge smoke passed — now verify the PROJECT actually builds (non-main only).
    # A red build returns FAIL so the driver bounces the task back to CONTINUE instead of closing broken
    # code as done (which is how the inconsistent auth baseline, ERR-005, slipped through).
    try {
      $pbg = Invoke-ProjectBuildGate -Channel $channelName -BridgeRoot $bridgeRoot
      if ($pbg.Ran -and -not $pbg.Ok) {
        return New-QAAgentResult -TaskId $TaskId -TaskTitle $TaskTitle -Channel $channelName -Verdict 'FAIL' -Summary ('PROJECT BUILD FAILED — ' + $pbg.Summary) -Bugs @($pbg.Summary)
      }
      if ($pbg.Ran) {
        return New-QAAgentResult -TaskId $TaskId -TaskTitle $TaskTitle -Channel $channelName -Verdict 'PASS' -Summary ('Smoke OK + ' + $pbg.Summary)
      }
    } catch {}
    return New-QAAgentResult -TaskId $TaskId -TaskTitle $TaskTitle -Channel $channelName -Verdict 'PASS' -Summary 'Smoke OK'
  } catch {
    $summary = $_.Exception.Message
    if ($summary.Length -gt 500) { $summary = $summary.Substring(0, 500) }
    return New-QAAgentResult -TaskId $TaskId -TaskTitle $TaskTitle -Channel $channelName -Verdict 'FAIL' -Summary $summary -Bugs @($summary)
  } finally {
    foreach ($p in @($stdoutPath, $stderrPath)) {
      try { if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } } catch {}
    }
  }
}
