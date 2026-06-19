#Requires -Version 5.1
# test-cli-flag-diff.ps1 -- regression tests for deterministic CLI flag diff guard.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$driverPath = Join-Path $root 'driver\00-task-session.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($driverPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
  throw ('driver parse failed: ' + (($errors | ForEach-Object { $_.Message }) -join '; '))
}

$neededFunctions = @('Test-CliFlagDiffLineLooksLikeInvocation', 'Test-CliFlagsInDiff')
$functions = @($ast.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $neededFunctions -contains $node.Name
}, $true) | Sort-Object { $_.Extent.StartOffset })
foreach ($name in $neededFunctions) {
  if (-not (@($functions | Where-Object { $_.Name -eq $name }).Count -eq 1)) {
    throw ("missing function in driver AST: " + $name)
  }
}
foreach ($fn in $functions) {
  Invoke-Expression $fn.Extent.Text
}

function Get-CliHelpText {
  param([string]$Cli)
  if ($Cli -eq 'codex') {
    return 'usage: codex exec --color --skip-git-repo-check --add-dir -c -C -m -o -s'
  }
  if ($Cli -eq 'claude') {
    return 'usage: claude -p --permission-mode --add-dir --allowedTools --model'
  }
  return ''
}

$script:pass = 0
$script:fail = 0

function Check {
  param(
    [string]$Name,
    [bool]$Condition,
    [object]$Actual = $null
  )

  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name)
  } else {
    $script:fail++
    $suffix = if ($null -ne $Actual) { " actual=" + ($Actual | ConvertTo-Json -Compress -Depth 6) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix)
  }
}

$artifactDiff = @'
+                                  "why": "In driver/85 the block mentions `codex` and compares `git -C $bridgeRoot diff --stat HEAD` in prose."
'@
$artifactIssues = @(Test-CliFlagsInDiff -Diff $artifactDiff)
Check 'decision artifact prose does not make git --stat a codex flag' ($artifactIssues.Count -eq 0) $artifactIssues

$assignmentProseDiff = @'
+$why = "The word codex appears near git diff --stat HEAD, but this is a diagnostic string."
'@
$assignmentProseIssues = @(Test-CliFlagsInDiff -Diff $assignmentProseDiff)
Check 'diagnostic string prose does not make git --stat a codex flag' ($assignmentProseIssues.Count -eq 0) $assignmentProseIssues

$badCodexDiff = @'
+& codex exec --definitely-not-a-real-codex-flag -
'@
$badCodexIssues = @(Test-CliFlagsInDiff -Diff $badCodexDiff)
Check 'real codex invocation with unknown flag is detected' (
  $badCodexIssues.Count -eq 1 -and
  [string]$badCodexIssues[0].cli -eq 'codex' -and
  [string]$badCodexIssues[0].flag -eq '--definitely-not-a-real-codex-flag'
) $badCodexIssues

$goodCodexDiff = @'
+& codex exec --color never --skip-git-repo-check -
'@
$goodCodexIssues = @(Test-CliFlagsInDiff -Diff $goodCodexDiff)
Check 'real codex invocation with known flags passes' ($goodCodexIssues.Count -eq 0) $goodCodexIssues

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
