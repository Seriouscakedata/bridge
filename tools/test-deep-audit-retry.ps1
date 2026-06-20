#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$bridgePath = Split-Path -Parent $PSScriptRoot
$agentScript = Join-Path $PSScriptRoot 'deep-audit-agent.ps1'
$powerShellExe = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($powerShellExe)) {
  $powerShellExe = 'powershell.exe'
}

$pass = 0
$fail = 0

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($agentScript, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -eq 0) {
  $pass++
  Write-Host 'PASS: ParseFile ok'
} else {
  $fail++
  Write-Host ("FAIL: ParseFile {0}" -f $parseErrors[0].Message)
}

$tmp = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.json')
try {
  & $powerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $agentScript `
    -Role 'security-model' `
    -BridgePath $bridgePath `
    -NoLLM `
    -OutputFile $tmp | Out-Null

  if (Test-Path -LiteralPath $tmp -PathType Leaf) {
    $result = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($result.status -eq 'prompt_ready') {
      $pass++
      Write-Host 'PASS: NoLLM -> prompt_ready'
    } else {
      $fail++
      Write-Host ("FAIL: NoLLM status={0}" -f $result.status)
    }
  } else {
    $fail++
    Write-Host 'FAIL: NoLLM no output file'
  }
} finally {
  Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}

$tmp2 = [System.IO.Path]::ChangeExtension([System.IO.Path]::GetTempFileName(), '.json')
try {
  & $powerShellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $agentScript `
    -Role 'reliability-model' `
    -BridgePath $bridgePath `
    -NoLLM `
    -OutputFile $tmp2 | Out-Null

  if (Test-Path -LiteralPath $tmp2 -PathType Leaf) {
    $result2 = Get-Content -LiteralPath $tmp2 -Raw -Encoding UTF8 | ConvertFrom-Json
    $keys = @($result2.PSObject.Properties.Name)
    $hasFields = ($keys -contains 'role') -and
      ($keys -contains 'status') -and
      ($keys -contains 'findings') -and
      ($keys -contains 'errors')
    if ($hasFields) {
      $pass++
      Write-Host 'PASS: JSON has required fields'
    } else {
      $fail++
      Write-Host ("FAIL: JSON missing required fields; keys={0}" -f ($keys -join ','))
    }
  } else {
    $fail++
    Write-Host 'FAIL: NoLLM (reliability) no output file'
  }
} finally {
  Remove-Item -LiteralPath $tmp2 -ErrorAction SilentlyContinue
}

Write-Host ("RESULT PASS pass={0} fail={1}" -f $pass, $fail)
