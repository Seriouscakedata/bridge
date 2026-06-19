#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

# Tests for truncation telemetry in deep-audit-agent.ps1
# (prompt_truncated + truncated_sections).
$root = Split-Path -Parent $PSScriptRoot
$agentScript = Join-Path $root 'tools\deep-audit-agent.ps1'
$deepAuditScript = Join-Path $root 'tools\deep-audit.ps1'
$script:PowerShellExe = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($script:PowerShellExe)) {
  $script:PowerShellExe = 'powershell.exe'
}

. $agentScript -NoLLM -Role 'security-model' -BridgePath $root -ProjectRoot $root 2>$null | Out-Null

$script:PassCount = 0
$script:FailCount = 0

function Check {
  param(
    [string]$Name,
    [bool]$Condition,
    [object]$Actual = $null
  )

  if ($Condition) {
    $script:PassCount++
    Write-Host ("PASS: $Name")
    return
  }

  $script:FailCount++
  $sfx = if ($null -ne $Actual) {
    ' actual=' + ($Actual | ConvertTo-Json -Compress -Depth 6)
  } else {
    ''
  }
  Write-Host ("FAIL: $Name$sfx")
}

function Invoke-AgentTelemetrySubprocess {
  param(
    [string]$BridgeRoot,
    [string]$ProjectRoot
  )

  $outFile = Join-Path $BridgeRoot 'agent-output.json'
  try {
    & $script:PowerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
      -File $agentScript `
      -NoLLM `
      -Role 'dependency-model' `
      -BridgePath $BridgeRoot `
      -ProjectRoot $ProjectRoot `
      -OutputFile $outFile | Out-Null

    $exitCode = $LASTEXITCODE
    $raw = if (Test-Path -LiteralPath $outFile -PathType Leaf) {
      Get-Content -LiteralPath $outFile -Raw -Encoding UTF8
    } else {
      ''
    }
    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      try { $json = $raw | ConvertFrom-Json } catch {}
    }

    return [pscustomobject]@{
      exit_code = $exitCode
      raw = $raw
      json = $json
    }
  } finally {
    Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue
  }
}

function Invoke-DeepAuditSubprocess {
  param(
    [string]$BridgeRoot,
    [string]$ProjectRoot
  )

  $outFile = Join-Path $BridgeRoot 'deep-audit-output.json'
  try {
    & $script:PowerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
      -File $deepAuditScript `
      -NoLLM `
      -BridgePath $BridgeRoot `
      -ProjectRoot $ProjectRoot `
      -OutputFile $outFile | Out-Null

    $exitCode = $LASTEXITCODE
    $raw = if (Test-Path -LiteralPath $outFile -PathType Leaf) {
      Get-Content -LiteralPath $outFile -Raw -Encoding UTF8
    } else {
      ''
    }
    $json = $null
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      try { $json = $raw | ConvertFrom-Json } catch {}
    }

    return [pscustomobject]@{
      exit_code = $exitCode
      raw = $raw
      json = $json
    }
  } finally {
    Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue
  }
}

$deepAuditFunctionsOnlyPath = [System.IO.Path]::Combine(
  [System.IO.Path]::GetTempPath(),
  ('deep-audit-functions-only-' + [Guid]::NewGuid().ToString('N') + '.ps1')
)
try {
  $deepAuditRaw = [System.IO.File]::ReadAllText($deepAuditScript, [System.Text.Encoding]::UTF8)
  $mainMarker = '# --- Main ---'
  $mainIndex = $deepAuditRaw.IndexOf($mainMarker, [System.StringComparison]::Ordinal)
  if ($mainIndex -lt 0) {
    throw "main marker not found in $deepAuditScript"
  }
  $deepAuditFunctionsOnly = $deepAuditRaw.Substring(0, $mainIndex)
  $utf8Bom = New-Object System.Text.UTF8Encoding($true)
  [System.IO.File]::WriteAllText($deepAuditFunctionsOnlyPath, $deepAuditFunctionsOnly, $utf8Bom)
  . $deepAuditFunctionsOnlyPath
} finally {
  Remove-Item -LiteralPath $deepAuditFunctionsOnlyPath -ErrorAction SilentlyContinue
}

$hasTestAgentContentTruncated = [bool](Get-Command Test-AgentContentTruncated -ErrorAction SilentlyContinue)
$hasGetAgentFileContentCapped = [bool](Get-Command Get-AgentFileContentCapped -ErrorAction SilentlyContinue)
$hasNewAgentPrompt = [bool](Get-Command New-AgentPrompt -ErrorAction SilentlyContinue)
$hasGetAgentPromptContext = [bool](Get-Command Get-AgentPromptContext -ErrorAction SilentlyContinue)
$hasCompleteDeepAuditAgentProcess = [bool](Get-Command Complete-DeepAuditAgentProcess -ErrorAction SilentlyContinue)

# --- Unit: Test-AgentContentTruncated ---
Check 'T1: function Test-AgentContentTruncated defined' $hasTestAgentContentTruncated
Check 'T2: truncated content with marker -> true' $(if ($hasTestAgentContentTruncated) { Test-AgentContentTruncated -Content 'hello...[truncated at 5 chars]' } else { $false })
Check 'T3: truncated content short marker -> true' $(if ($hasTestAgentContentTruncated) { Test-AgentContentTruncated -Content 'hi...[truncated]' } else { $false })
Check 'T4: normal short content -> false' $(if ($hasTestAgentContentTruncated) { -not (Test-AgentContentTruncated -Content 'hello world') } else { $false })
Check 'T5: empty content -> false' $(if ($hasTestAgentContentTruncated) { -not (Test-AgentContentTruncated -Content '') } else { $false })

# --- Unit: Get-AgentFileContentCapped ---
Check 'T6: Get-AgentFileContentCapped defined' $hasGetAgentFileContentCapped
$tmpFile = [System.IO.Path]::GetTempFileName()
try {
  [System.IO.File]::WriteAllText($tmpFile, 'short content', [System.Text.Encoding]::UTF8)
  $small = if ($hasGetAgentFileContentCapped) { Get-AgentFileContentCapped -Path $tmpFile -Cap 1000 } else { '' }
  Check 'T7: small file no truncation marker' $(if ($hasTestAgentContentTruncated -and $hasGetAgentFileContentCapped) { -not (Test-AgentContentTruncated -Content $small) } else { $false }) $small

  $bigText = 'X' * 200
  [System.IO.File]::WriteAllText($tmpFile, $bigText, [System.Text.Encoding]::UTF8)
  $big = if ($hasGetAgentFileContentCapped) { Get-AgentFileContentCapped -Path $tmpFile -Cap 100 } else { '' }
  Check 'T8: oversized file has truncation marker' $(if ($hasTestAgentContentTruncated -and $hasGetAgentFileContentCapped) { Test-AgentContentTruncated -Content $big } else { $false }) $big
  Check 'T8b: oversized content length <= cap + suffix' $(if ($hasGetAgentFileContentCapped) { $big.Length -lt 200 } else { $false }) $(if ($hasGetAgentFileContentCapped) { $big.Length } else { $null })
} finally {
  Remove-Item -LiteralPath $tmpFile -ErrorAction SilentlyContinue
}

# --- Integration surface: exported prompt helpers ---
Check 'T9: New-AgentPrompt defined' $hasNewAgentPrompt
Check 'T10: Get-AgentPromptContext defined' $hasGetAgentPromptContext

$tmpDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('deep-audit-trunc-test-' + [Guid]::NewGuid().ToString('N')))
try {
  New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $tmpDir 'tools') -Force | Out-Null

  $bigJson = '{"key":"' + ('X' * 35000) + '"}'
  [System.IO.File]::WriteAllText((Join-Path $tmpDir 'config.json'), $bigJson, [System.Text.Encoding]::UTF8)
  $bigResult = Invoke-AgentTelemetrySubprocess -BridgeRoot $tmpDir -ProjectRoot $tmpDir
  $bigJsonResult = $bigResult.json
  $bigSections = if ($bigJsonResult -and $bigJsonResult.PSObject.Properties.Name -contains 'truncated_sections') { @($bigJsonResult.truncated_sections) } else { @() }
  Check 'T11: dependency-model big config subprocess exits 0' ($bigResult.exit_code -eq 0) $bigResult.exit_code
  Check 'T11b: prompt_truncated=true for oversized config' ($bigJsonResult -and ($bigJsonResult.PSObject.Properties.Name -contains 'prompt_truncated') -and $bigJsonResult.prompt_truncated -eq $true) $bigJsonResult
  Check 'T11c: truncated_sections names config.json' ($bigSections -contains 'config.json') $bigSections

  $smallJson = '{"key":"small"}'
  [System.IO.File]::WriteAllText((Join-Path $tmpDir 'config.json'), $smallJson, [System.Text.Encoding]::UTF8)
  $smallResult = Invoke-AgentTelemetrySubprocess -BridgeRoot $tmpDir -ProjectRoot $tmpDir
  $smallJsonResult = $smallResult.json
  $smallSections = if ($smallJsonResult -and $smallJsonResult.PSObject.Properties.Name -contains 'truncated_sections') { @($smallJsonResult.truncated_sections) } else { @() }
  Check 'T12: dependency-model small config subprocess exits 0' ($smallResult.exit_code -eq 0) $smallResult.exit_code
  Check 'T12b: prompt_truncated=false for small config' ($smallJsonResult -and ($smallJsonResult.PSObject.Properties.Name -contains 'prompt_truncated') -and $smallJsonResult.prompt_truncated -eq $false) $smallJsonResult
  Check 'T12c: truncated_sections empty for small config' ($smallJsonResult -and ($smallJsonResult.PSObject.Properties.Name -contains 'truncated_sections') -and $smallSections.Count -eq 0) $smallSections

  $deepAuditResult = Invoke-DeepAuditSubprocess -BridgeRoot $root -ProjectRoot $root
  $deepAuditAgents = if ($deepAuditResult.json -and ($deepAuditResult.json.PSObject.Properties.Name -contains 'agents')) {
    @($deepAuditResult.json.agents)
  } else {
    @()
  }
  $allAgentsHaveTelemetry = $deepAuditAgents.Count -gt 0
  foreach ($agent in $deepAuditAgents) {
    $hasPromptTruncated = $agent.PSObject.Properties.Name -contains 'prompt_truncated'
    $hasTruncatedSections = $agent.PSObject.Properties.Name -contains 'truncated_sections'
    if (-not ($hasPromptTruncated -and $hasTruncatedSections)) {
      $allAgentsHaveTelemetry = $false
      break
    }
  }
  Check 'T12d: deep-audit -NoLLM exits 0' ($deepAuditResult.exit_code -eq 0) $deepAuditResult.exit_code
  Check 'T12e: deep-audit agents expose prompt_truncated + truncated_sections' $allAgentsHaveTelemetry $deepAuditAgents

  Check 'T13: Complete-DeepAuditAgentProcess defined' $hasCompleteDeepAuditAgentProcess
  $legacyResultPath = Join-Path $tmpDir 'legacy-agent.json'
  [System.IO.File]::WriteAllText(
    $legacyResultPath,
    '{"role":"legacy-model","model":"test-model","status":"ok","runtime_sec":0.1,"findings":[],"errors":[],"coverage":[],"confidence":0.5}',
    [System.Text.Encoding]::UTF8
  )
  $legacyState = [pscustomobject]@{
    spec = [pscustomobject]@{ role = 'legacy-model'; model = 'test-model' }
    proc = $null
    resultF = $legacyResultPath
    outF = Join-Path $tmpDir 'legacy-agent.out'
    errF = Join-Path $tmpDir 'legacy-agent.err'
    startedAt = Get-Date
    timeoutSec = 1
  }
  $legacyParsed = if ($hasCompleteDeepAuditAgentProcess) { Complete-DeepAuditAgentProcess -State $legacyState } else { $null }
  $legacyCoverageGap = if ($legacyParsed -and ($legacyParsed.PSObject.Properties.Name -contains 'coverage_gap')) { @($legacyParsed.coverage_gap) } else { @('missing') }
  $legacyTruncatedSections = if ($legacyParsed -and ($legacyParsed.PSObject.Properties.Name -contains 'truncated_sections')) { @($legacyParsed.truncated_sections) } else { @('missing') }
  Check 'T13b: missing coverage_gap normalizes to empty array' ($legacyCoverageGap.Count -eq 0) $legacyCoverageGap
  Check 'T13c: missing truncated_sections normalizes to empty array' ($legacyTruncatedSections.Count -eq 0) $legacyTruncatedSections

  $nullResultPath = Join-Path $tmpDir 'null-agent.json'
  [System.IO.File]::WriteAllText(
    $nullResultPath,
    '{"role":"null-model","model":"test-model","status":"ok","runtime_sec":0.1,"findings":null,"errors":null,"coverage":null,"coverage_gap":null,"confidence":0.5,"truncated_sections":null}',
    [System.Text.Encoding]::UTF8
  )
  $nullState = [pscustomobject]@{
    spec = [pscustomobject]@{ role = 'null-model'; model = 'test-model' }
    proc = $null
    resultF = $nullResultPath
    outF = Join-Path $tmpDir 'null-agent.out'
    errF = Join-Path $tmpDir 'null-agent.err'
    startedAt = Get-Date
    timeoutSec = 1
  }
  $nullParsed = if ($hasCompleteDeepAuditAgentProcess) { Complete-DeepAuditAgentProcess -State $nullState } else { $null }
  $nullCoverageGap = if ($nullParsed -and ($nullParsed.PSObject.Properties.Name -contains 'coverage_gap')) { @($nullParsed.coverage_gap) } else { @('missing') }
  $nullTruncatedSections = if ($nullParsed -and ($nullParsed.PSObject.Properties.Name -contains 'truncated_sections')) { @($nullParsed.truncated_sections) } else { @('missing') }
  Check 'T14: null coverage_gap normalizes to empty array' ($nullCoverageGap.Count -eq 0) $nullCoverageGap
  Check 'T14b: null truncated_sections normalizes to empty array' ($nullTruncatedSections.Count -eq 0) $nullTruncatedSections
} finally {
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("deep-audit truncation telemetry: {0} PASS, {1} FAIL" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
exit 0
