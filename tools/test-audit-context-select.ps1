[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:PassCount = 0
$script:FailCount = 0

function Write-TestResult {
  param([string]$SuccessMessage, [bool]$Condition, [string]$FailureDetail = '')
  if ($Condition) {
    $script:PassCount++
    Write-Host ("PASS: {0}" -f $SuccessMessage)
    return
  }
  $script:FailCount++
  if ([string]::IsNullOrWhiteSpace($FailureDetail)) {
    Write-Host ("FAIL: {0}" -f $SuccessMessage)
  } else {
    Write-Host ("FAIL: {0} - {1}" -f $SuccessMessage, $FailureDetail)
  }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$agentScript = Join-Path $repoRoot 'tools\deep-audit-agent.ps1'

# --- Parse check ---
try {
  $errs = $null; $toks = $null
  [System.Management.Automation.Language.Parser]::ParseFile($agentScript, [ref]$toks, [ref]$errs) | Out-Null
  Write-TestResult -SuccessMessage 'deep-audit-agent.ps1 passes ParseFile' -Condition ($errs.Count -eq 0) -FailureDetail ($errs | Select-Object -First 1 | ForEach-Object { $_.Message })
} catch {
  Write-TestResult -SuccessMessage 'deep-audit-agent.ps1 passes ParseFile' -Condition $false -FailureDetail $_.Exception.Message
}

# --- Test-AgentExcludedPath exists in source ---
try {
  $src = [System.IO.File]::ReadAllText($agentScript, [System.Text.Encoding]::UTF8)
  Write-TestResult -SuccessMessage 'deep-audit-agent.ps1 contains Test-AgentExcludedPath' -Condition ($src -match 'function Test-AgentExcludedPath')
  Write-TestResult -SuccessMessage 'deep-audit-agent.ps1 contains Get-AgentRiskRankedFiles' -Condition ($src -match 'function Get-AgentRiskRankedFiles')
  Write-TestResult -SuccessMessage 'deep-audit-agent.ps1 contains prompt_chars in result' -Condition ($src -match 'prompt_chars')
  Write-TestResult -SuccessMessage 'deep-audit-agent.ps1 contains context_policy in result' -Condition ($src -match 'context_policy')
  Write-TestResult -SuccessMessage 'deep-audit-agent.ps1 empty_llm_reply includes prompt_chars' -Condition ($src -match "empty_llm_reply.*prompt_chars")
} catch {
  Write-TestResult -SuccessMessage 'source inspection' -Condition $false -FailureDetail $_.Exception.Message
}

# --- Run security-model in NoLLM mode and check output ---
try {
  $rawJson = & powershell -NoProfile -ExecutionPolicy Bypass -File $agentScript -Role 'security-model' -NoLLM -BridgePath $repoRoot 2>&1
  $joined = ($rawJson -join '')
  $result = $null
  try { $result = $joined | ConvertFrom-Json } catch {}

  Write-TestResult -SuccessMessage 'security-model -NoLLM produces valid JSON' -Condition ($null -ne $result)

  if ($null -ne $result) {
    Write-TestResult -SuccessMessage 'security-model result has prompt_chars > 0' -Condition ($result.prompt_chars -gt 0) -FailureDetail "prompt_chars=$($result.prompt_chars)"
    Write-TestResult -SuccessMessage "security-model context_policy is 'risk_ranked'" -Condition ($result.context_policy -eq 'risk_ranked') -FailureDetail "got: $($result.context_policy)"
    Write-TestResult -SuccessMessage "security-model status is 'prompt_ready'" -Condition ($result.status -eq 'prompt_ready') -FailureDetail "got: $($result.status)"

    # Confirm control/curator-launchers not in coverage
    $badPaths = @($result.coverage | Where-Object { $_ -match '(?i)curator.launchers' })
    Write-TestResult -SuccessMessage 'security-model coverage excludes control/curator-launchers' -Condition ($badPaths.Count -eq 0) -FailureDetail ("found: " + ($badPaths -join ', '))

    # Confirm no .git in coverage
    $gitPaths = @($result.coverage | Where-Object { $_ -match '(?i)\\\.git\\' -or $_ -eq '.git' -or $_ -match '^\.git\\' })
    Write-TestResult -SuccessMessage 'security-model coverage excludes .git' -Condition ($gitPaths.Count -eq 0) -FailureDetail ("found: " + ($gitPaths -join ', '))
  }
} catch {
  Write-TestResult -SuccessMessage 'security-model -NoLLM run' -Condition $false -FailureDetail $_.Exception.Message
}

# --- architecture-model NoLLM ---
try {
  $rawJson2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $agentScript -Role 'architecture-model' -NoLLM -BridgePath $repoRoot 2>&1
  $joined2 = ($rawJson2 -join '')
  $result2 = $null
  try { $result2 = $joined2 | ConvertFrom-Json } catch {}
  if ($null -ne $result2) {
    $badPaths2 = @($result2.coverage | Where-Object { $_ -match '(?i)curator.launchers' })
    Write-TestResult -SuccessMessage 'architecture-model coverage excludes control/curator-launchers' -Condition ($badPaths2.Count -eq 0) -FailureDetail ("found: " + ($badPaths2 -join ', '))
    Write-TestResult -SuccessMessage 'architecture-model result has context_policy' -Condition (-not [string]::IsNullOrWhiteSpace($result2.context_policy))
  } else {
    Write-TestResult -SuccessMessage 'architecture-model -NoLLM produces valid JSON' -Condition $false -FailureDetail "parse failed: $joined2"
  }
} catch {
  Write-TestResult -SuccessMessage 'architecture-model -NoLLM run' -Condition $false -FailureDetail $_.Exception.Message
}

Write-Host ("RESULT: {0} PASS, {1} FAIL" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -eq 0) { exit 0 }
exit 1
