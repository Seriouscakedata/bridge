[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:PassCount = 0
$script:FailCount = 0

function Write-TestResult {
  param(
    [string]$SuccessMessage,
    [bool]$Condition,
    [string]$FailureDetail = ''
  )

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

function Test-FunctionExists {
  param([string]$Name)

  $command = Get-Command -Name $Name -CommandType Function -ErrorAction SilentlyContinue
  Write-TestResult -SuccessMessage ("function exists: {0}" -f $Name) -Condition ($null -ne $command)
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$auditPath = Join-Path $repoRoot 'tools\audit.ps1'

try {
  . $auditPath
  Write-TestResult -SuccessMessage 'dot-sourced tools/audit.ps1' -Condition $true
} catch {
  Write-TestResult -SuccessMessage 'dot-sourced tools/audit.ps1' -Condition $false -FailureDetail $_.Exception.Message
  Write-Host ("RESULT: {0} PASS, {1} FAIL" -f $script:PassCount, $script:FailCount)
  exit 1
}

$helperFunctions = @(
  'Resolve-AuditProjectScope',
  'Invoke-AuditSignalCollection',
  'Invoke-DeepAuditProcess',
  'Initialize-AuditBacklogHelpers',
  'Add-DeepAuditFindingsToBacklog',
  'Add-DeepAuditSectionsToMarkdown'
)

foreach ($helperName in $helperFunctions) {
  Test-FunctionExists -Name $helperName
}

Test-FunctionExists -Name 'Invoke-BridgeAudit'

try {
  $lines = Get-Content -Path $auditPath -Encoding UTF8
  $startIndex = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^function Invoke-BridgeAudit\b') {
      $startIndex = $i
      break
    }
  }

  if ($startIndex -lt 0) {
    Write-TestResult -SuccessMessage 'Invoke-BridgeAudit definition found in tools/audit.ps1' -Condition $false -FailureDetail 'function header not found'
  } else {
    $endExclusive = $lines.Count
    for ($i = $startIndex + 1; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match '^function\b') {
        $endExclusive = $i
        break
      }
    }

    $definitionLineCount = $endExclusive - $startIndex
    Write-TestResult -SuccessMessage 'Invoke-BridgeAudit definition found in tools/audit.ps1' -Condition $true
    Write-TestResult `
      -SuccessMessage ("Invoke-BridgeAudit definition length <= 200 lines ({0})" -f $definitionLineCount) `
      -Condition ($definitionLineCount -le 200) `
      -FailureDetail ("actual line count is {0}" -f $definitionLineCount)
  }
} catch {
  Write-TestResult -SuccessMessage 'Invoke-BridgeAudit definition length <= 200 lines' -Condition $false -FailureDetail $_.Exception.Message
}

Write-Host ("RESULT: {0} PASS, {1} FAIL" -f $script:PassCount, $script:FailCount)

if ($script:FailCount -eq 0) {
  exit 0
}

exit 1
