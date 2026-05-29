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
