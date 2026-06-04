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

function Get-FunctionLineCount {
  param([string]$Path, [string]$Name)

  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) {
    throw ("Parse errors in {0}: {1}" -f $Path, ($errors | Select-Object -First 1).Message)
  }

  $fn = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
  }, $true)

  if ($null -eq $fn) { return -1 }
  return ($fn.Extent.EndLineNumber - $fn.Extent.StartLineNumber + 1)
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$driverRootPath = Join-Path $repoRoot 'driver.ps1'
$driverPromptPath = Join-Path $repoRoot 'driver\30-prompt-agent-state.ps1'
$promptBuilderPath = Join-Path $repoRoot 'lib\prompt-builder.ps1'

foreach ($path in @($driverRootPath, $driverPromptPath, $promptBuilderPath)) {
  Write-TestResult -SuccessMessage ("file exists: {0}" -f (Resolve-Path -LiteralPath $path -Relative)) -Condition (Test-Path -LiteralPath $path)
}

try {
  $script:bridgeRoot = $repoRoot
  $script:Channel = 'main'
  $script:workRoot = $repoRoot
  $script:discussMinTurns = 3
  $script:discussMaxTurns = 8
  $script:studyMaxTurns = 5
  $script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  $global:bridgeRoot = $repoRoot
  $global:Channel = 'main'
  $global:workRoot = $repoRoot
  $global:discussMinTurns = 3
  $global:discussMaxTurns = 8
  $global:studyMaxTurns = 5
  $global:Utf8NoBom = $script:Utf8NoBom

  . $promptBuilderPath
  . $driverPromptPath
  Write-TestResult -SuccessMessage 'dot-sourced prompt builder and driver prompt module' -Condition $true
} catch {
  Write-TestResult -SuccessMessage 'dot-sourced prompt builder and driver prompt module' -Condition $false -FailureDetail $_.Exception.Message
  Write-Host ("RESULT: {0} PASS, {1} FAIL" -f $script:PassCount, $script:FailCount)
  exit 1
}

$requiredFunctions = @(
  'Build-Prompt',
  'Invoke-PromptBuilder',
  'New-PromptBuilderContext',
  'Get-PromptAutoScopeLine',
  'New-FastLanePrompt',
  'New-SharedPromptBlock',
  'New-ClaudePromptSuffix',
  'New-CodexPromptSuffix'
)

foreach ($name in $requiredFunctions) {
  Test-FunctionExists -Name $name
}

try {
  $rootText = Get-Content -LiteralPath $driverRootPath -Raw -Encoding UTF8
  Write-TestResult `
    -SuccessMessage 'driver.ps1 dot-sources lib/prompt-builder.ps1' `
    -Condition ($rootText -match "lib\\prompt-builder\.ps1")

  $promptText = Get-Content -LiteralPath $driverPromptPath -Raw -Encoding UTF8
  Write-TestResult `
    -SuccessMessage 'Build-Prompt delegates to Invoke-PromptBuilder' `
    -Condition ($promptText -match 'Invoke-PromptBuilder')
} catch {
  Write-TestResult -SuccessMessage 'prompt-builder wiring checks completed' -Condition $false -FailureDetail $_.Exception.Message
}

try {
  $lineCount = Get-FunctionLineCount -Path $driverPromptPath -Name 'Build-Prompt'
  Write-TestResult -SuccessMessage 'Build-Prompt definition found in driver prompt module' -Condition ($lineCount -gt 0)
  Write-TestResult `
    -SuccessMessage ("Build-Prompt definition length <= 160 lines ({0})" -f $lineCount) `
    -Condition ($lineCount -gt 0 -and $lineCount -le 160) `
    -FailureDetail ("actual line count is {0}" -f $lineCount)
} catch {
  Write-TestResult -SuccessMessage 'Build-Prompt definition length <= 160 lines' -Condition $false -FailureDetail $_.Exception.Message
}

Write-Host ("RESULT: {0} PASS, {1} FAIL" -f $script:PassCount, $script:FailCount)

if ($script:FailCount -eq 0) {
  exit 0
}

exit 1
