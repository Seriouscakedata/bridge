# qa-agent.ps1 -- Runs bridge QA checks and records PASS/FAIL verdicts for tasks and channels.
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
    [string]$Summary,
    [string]$BridgeRoot = ''
  )
  try {
    $bridge = [string]$BridgeRoot
    if ([string]::IsNullOrWhiteSpace($bridge)) { $bridge = Get-QAAgentBridgeRoot }
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
    [object[]]$Bugs = @(),
    [string]$BridgeRoot = ''
  )
  Write-QAAgentResult -TaskId $TaskId -TaskTitle $TaskTitle -Channel $Channel -Verdict $Verdict -Summary $Summary -BridgeRoot $BridgeRoot
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

function Get-QAAgentScenarioSafety {
  param([string]$Path)
  $safe = $true
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $safe }
  try {
    $head = [string]::Join("`n", @(Get-Content -LiteralPath $Path -Encoding UTF8 -TotalCount 12))
    $m = [regex]::Match($head, '(?im)^\s*//\s*@audit-safe\s*:\s*(yes|no|true|false)\b')
    if ($m.Success) {
      $v = $m.Groups[1].Value.ToLowerInvariant()
      $safe = ($v -eq 'yes' -or $v -eq 'true')
    }
  } catch {}
  return $safe
}

function Get-QAAgentConfig {
  param([string]$BridgeRoot)
  $cfg = [ordered]@{
    RunUnsafeScenarios = $false
    ScenarioTimeoutSec = 90
    ScenarioUrl = 'http://localhost:8787'
  }
  try {
    $configPath = Join-Path $BridgeRoot 'config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { return [pscustomobject]$cfg }
    $jsonText = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
    $json = $jsonText | ConvertFrom-Json
    if ($json -and $json.PSObject.Properties.Name -contains 'qaRunner' -and $json.qaRunner) {
      if ($json.qaRunner.PSObject.Properties.Name -contains 'runUnsafeScenarios') { $cfg.RunUnsafeScenarios = [bool]$json.qaRunner.runUnsafeScenarios }
      if ($json.qaRunner.PSObject.Properties.Name -contains 'scenarioTimeoutSec') { $cfg.ScenarioTimeoutSec = [int]$json.qaRunner.scenarioTimeoutSec }
      if ($json.qaRunner.PSObject.Properties.Name -contains 'scenarioUrl' -and -not [string]::IsNullOrWhiteSpace([string]$json.qaRunner.scenarioUrl)) { $cfg.ScenarioUrl = [string]$json.qaRunner.scenarioUrl }
    }
  } catch {}
  if ([int]$cfg.ScenarioTimeoutSec -le 0) { $cfg.ScenarioTimeoutSec = 90 }
  return [pscustomobject]$cfg
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
    if (Test-Path -LiteralPath $chJson) {
      $chRaw = [System.IO.File]::ReadAllText($chJson, [System.Text.Encoding]::UTF8)
      $pr = [string](($chRaw | ConvertFrom-Json).project_root)
    }
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

function Invoke-QAAgentScenarioSuite {
  param(
    [string]$BridgeRoot,
    [string]$Url = 'http://localhost:8787',
    [int]$TimeoutSec = 90,
    [switch]$IncludeUnsafe
  )
  $result = [pscustomobject]@{
    Ok = $true
    Ran = $false
    Passed = 0
    Failed = 0
    Skipped = 0
    SkippedUnsafe = @()
    Summary = ''
    Bugs = @()
  }
  $runner = Join-Path (Join-Path $BridgeRoot 'tools') 'scenario.ps1'
  $scenarioDir = Join-Path (Join-Path $BridgeRoot 'tools') 'scenarios'
  if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    $result.Summary = 'scenario runner not found'
    return $result
  }
  if (-not (Test-Path -LiteralPath $scenarioDir -PathType Container)) {
    $result.Summary = 'scenario directory not found'
    return $result
  }
  $scenarioFiles = @(Get-ChildItem -LiteralPath $scenarioDir -Filter '*.js' -File -ErrorAction SilentlyContinue | Sort-Object Name)
  if ($scenarioFiles.Count -eq 0) {
    $result.Summary = 'no scenarios found'
    return $result
  }

  $runnable = New-Object 'System.Collections.Generic.List[object]'
  $skippedUnsafe = New-Object 'System.Collections.Generic.List[string]'
  foreach ($sf in $scenarioFiles) {
    if (-not $IncludeUnsafe -and -not (Get-QAAgentScenarioSafety -Path $sf.FullName)) {
      [void]$skippedUnsafe.Add($sf.Name)
      continue
    }
    [void]$runnable.Add($sf)
  }
  $result.Skipped = $skippedUnsafe.Count
  $result.SkippedUnsafe = @($skippedUnsafe.ToArray())
  if ($runnable.Count -eq 0) {
    $result.Summary = if ($skippedUnsafe.Count -gt 0) { 'no audit-safe scenarios found; skipped unsafe: ' + [string]::Join(',', @($skippedUnsafe.ToArray())) } else { 'no scenarios found' }
    return $result
  }

  $result.Ran = $true
  $failures = New-Object 'System.Collections.Generic.List[string]'
  foreach ($sf in @($runnable.ToArray())) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($sf.Name)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File ' + (Quote-QAAgentArgument $runner) + ' -Name ' + (Quote-QAAgentArgument $name) + ' -Url ' + (Quote-QAAgentArgument $Url) + ' -TimeoutSec ' + [string]$TimeoutSec
    $psi.WorkingDirectory = $BridgeRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
      [void]$proc.Start()
      $completed = $proc.WaitForExit(($TimeoutSec + 20) * 1000)
      if (-not $completed) {
        try { $proc.Kill() } catch {}
        $result.Failed++
        [void]$failures.Add($name + ': timed out')
        continue
      }
      $out = ''
      try { $out += $proc.StandardOutput.ReadToEnd() } catch {}
      try {
        $err = $proc.StandardError.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($err)) { $out += "`n" + $err }
      } catch {}
      if ($proc.ExitCode -eq 0) {
        $result.Passed++
      } else {
        $short = ($out -replace '\s+', ' ').Trim()
        if ($short.Length -gt 500) { $short = $short.Substring(0, 500) }
        if ([string]::IsNullOrWhiteSpace($short)) { $short = 'exit ' + [string]$proc.ExitCode }
        $result.Failed++
        [void]$failures.Add($name + ': ' + $short)
      }
    } catch {
      $result.Failed++
      [void]$failures.Add($name + ': ' + $_.Exception.Message)
    }
  }
  if ($result.Failed -gt 0) {
    $result.Ok = $false
    $result.Bugs = @($failures.ToArray())
    $result.Summary = ('scenarios FAIL: ' + [string]::Join(' ; ', @($failures.ToArray())))
    if ($result.Summary.Length -gt 900) { $result.Summary = $result.Summary.Substring(0, 900) }
  } else {
    $skipText = if ($result.Skipped -gt 0) { ('; skipped unsafe: ' + $result.Skipped) } else { '' }
    $result.Summary = ('scenarios PASS: ' + $result.Passed + '/' + $runnable.Count + $skipText)
  }
  return $result
}

function Invoke-QAAgentPostCommit {
  param(
    [string]$BridgeRoot,
    [string]$CommitSha = '',
    [string]$TaskId = '',
    [string]$TaskTitle = '',
    [string]$Channel = '',
    [switch]$IncludeUnsafe
  )
  if ([string]::IsNullOrWhiteSpace($BridgeRoot)) { $BridgeRoot = Get-QAAgentBridgeRoot }
  # 2026-06-11 W2b: post-commit QA runs the BRIDGE scenario suite (smoke + HTTP scenarios against
  # the bridge server). On a PROJECT channel the commit changed the project app, NOT the bridge,
  # so these scenarios are irrelevant AND fail (sandbox/HTTP) -> qa_failed -> the same close-lag
  # loop W2 fixed for gate-regression (the second onion layer the slopvid benchmark exposed).
  # Skip bridge scenarios off main; project acceptance is owned by the project-contract flow.
  $qaPostChannel = Get-QAAgentChannel -Channel $Channel
  if (-not [string]::IsNullOrWhiteSpace($qaPostChannel) -and $qaPostChannel -ne 'main') {
    $short = [string]$CommitSha; if ($short.Length -gt 7) { $short = $short.Substring(0,7) }
    if ([string]::IsNullOrWhiteSpace($short)) { $short = '<unknown>' }
    return New-QAAgentResult -TaskId $TaskId -TaskTitle $TaskTitle -Channel $qaPostChannel -Verdict 'PASS' -Summary ('post-commit ' + $short + ': bridge QA scenarios skipped (project channel ' + $qaPostChannel + ' — bridge smoke is not relevant to project changes)') -Bugs @() -BridgeRoot $BridgeRoot
  }
  $qaCfg = Get-QAAgentConfig -BridgeRoot $BridgeRoot
  $runUnsafe = [bool]$IncludeUnsafe -or [bool]$qaCfg.RunUnsafeScenarios
  $scenarioResult = Invoke-QAAgentScenarioSuite -BridgeRoot $BridgeRoot -Url ([string]$qaCfg.ScenarioUrl) -TimeoutSec ([int]$qaCfg.ScenarioTimeoutSec) -IncludeUnsafe:$runUnsafe
  $short = [string]$CommitSha
  if ($short.Length -gt 7) { $short = $short.Substring(0,7) }
  if ([string]::IsNullOrWhiteSpace($short)) { $short = '<unknown>' }
  $summary = ('post-commit ' + $short + ': ' + [string]$scenarioResult.Summary)
  if ($summary.Length -gt 900) { $summary = $summary.Substring(0, 900) }
  $verdict = if ($scenarioResult.Ran -and -not [bool]$scenarioResult.Ok) { 'FAIL' } else { 'PASS' }
  return New-QAAgentResult -TaskId $TaskId -TaskTitle $TaskTitle -Channel (Get-QAAgentChannel -Channel $Channel) -Verdict $verdict -Summary $summary -Bugs @($scenarioResult.Bugs) -BridgeRoot $BridgeRoot
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

    $qaCfg = Get-QAAgentConfig -BridgeRoot $bridgeRoot
    $scenarioResult = Invoke-QAAgentScenarioSuite -BridgeRoot $bridgeRoot -Url ([string]$qaCfg.ScenarioUrl) -TimeoutSec ([int]$qaCfg.ScenarioTimeoutSec) -IncludeUnsafe:([bool]$qaCfg.RunUnsafeScenarios)
    if ($scenarioResult.Ran -and -not $scenarioResult.Ok) {
      return New-QAAgentResult -TaskId $TaskId -TaskTitle $TaskTitle -Channel $channelName -Verdict 'FAIL' -Summary ('E2E SCENARIOS FAILED — ' + $scenarioResult.Summary) -Bugs @($scenarioResult.Bugs)
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
        $scenarioSummary = if ($scenarioResult.Ran) { ' + ' + $scenarioResult.Summary } else { '' }
        return New-QAAgentResult -TaskId $TaskId -TaskTitle $TaskTitle -Channel $channelName -Verdict 'PASS' -Summary ('Smoke OK' + $scenarioSummary + ' + ' + $pbg.Summary)
      }
    } catch {}
    $scenarioSummary2 = if ($scenarioResult.Ran) { ' + ' + $scenarioResult.Summary } else { '' }
    return New-QAAgentResult -TaskId $TaskId -TaskTitle $TaskTitle -Channel $channelName -Verdict 'PASS' -Summary ('Smoke OK' + $scenarioSummary2)
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
