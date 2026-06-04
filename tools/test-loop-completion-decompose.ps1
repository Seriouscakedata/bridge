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

function Test-Utf8Bom {
  param([string]$Path)

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function Test-ParseFile {
  param([string]$Path)

  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
  return @($errors).Count -eq 0
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$driverDir = Join-Path $repoRoot 'driver'
$wrapperPath = Join-Path $driverDir '86-loop-completion.ps1'
$checksPath = Join-Path $driverDir '86-loop-completion-checks.ps1'
$actionsPath = Join-Path $driverDir '86-loop-completion-actions.ps1'
$cleanupPath = Join-Path $driverDir '86-loop-completion-cleanup.ps1'
$selfPath = $MyInvocation.MyCommand.Path

$modulePaths = @($wrapperPath, $checksPath, $actionsPath, $cleanupPath)
foreach ($path in $modulePaths) {
  Write-TestResult -SuccessMessage ("file exists: {0}" -f (Resolve-Path -LiteralPath $path -Relative)) -Condition (Test-Path -LiteralPath $path)
}

foreach ($path in @($modulePaths + @($selfPath))) {
  $name = Resolve-Path -LiteralPath $path -Relative
  Write-TestResult -SuccessMessage ("UTF-8 BOM: {0}" -f $name) -Condition (Test-Utf8Bom -Path $path)
  Write-TestResult -SuccessMessage ("ParseFile OK: {0}" -f $name) -Condition (Test-ParseFile -Path $path)
}

try {
  . $wrapperPath
  Write-TestResult -SuccessMessage 'dot-sourced loop-completion wrapper' -Condition $true
} catch {
  Write-TestResult -SuccessMessage 'dot-sourced loop-completion wrapper' -Condition $false -FailureDetail $_.Exception.Message
}

$refreshCommand = Get-Command -Name Invoke-PostTaskSelfModelRefresh -CommandType Function -ErrorAction SilentlyContinue
Write-TestResult -SuccessMessage 'Invoke-PostTaskSelfModelRefresh remains available' -Condition ($null -ne $refreshCommand)
Write-TestResult -SuccessMessage 'DriverLoopCompletionBlock is a scriptblock' -Condition ($script:DriverLoopCompletionBlock -is [scriptblock])
Write-TestResult -SuccessMessage 'initial checks fragment is a scriptblock' -Condition ($script:DriverLoopCompletionInitialChecksBlock -is [scriptblock])
Write-TestResult -SuccessMessage 'critic actions fragment is a scriptblock' -Condition ($script:DriverLoopCompletionCriticActionsBlock -is [scriptblock])
Write-TestResult -SuccessMessage 'runtime checks fragment is a scriptblock' -Condition ($script:DriverLoopCompletionRuntimeChecksBlock -is [scriptblock])
Write-TestResult -SuccessMessage 'project actions fragment is a scriptblock' -Condition ($script:DriverLoopCompletionProjectActionsBlock -is [scriptblock])
Write-TestResult -SuccessMessage 'cleanup fragment is a scriptblock' -Condition ($script:DriverLoopCompletionCleanupBlock -is [scriptblock])

$wrapperText = Get-Content -LiteralPath $wrapperPath -Raw -Encoding UTF8
foreach ($moduleName in @(
  '86-loop-completion-checks.ps1',
  '86-loop-completion-actions.ps1',
  '86-loop-completion-cleanup.ps1'
)) {
  Write-TestResult -SuccessMessage ("wrapper dot-sources {0}" -f $moduleName) -Condition ($wrapperText -match [regex]::Escape($moduleName))
}

$wrapperLineCount = (Get-Content -LiteralPath $wrapperPath).Count
Write-TestResult `
  -SuccessMessage ("wrapper is compact ({0} lines)" -f $wrapperLineCount) `
  -Condition ($wrapperLineCount -le 80) `
  -FailureDetail ("actual line count is {0}" -f $wrapperLineCount)

Write-Host ("RESULT: {0} PASS, {1} FAIL" -f $script:PassCount, $script:FailCount)

if ($script:FailCount -eq 0) {
  exit 0
}

exit 1
