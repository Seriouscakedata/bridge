#Requires -Version 5.1
# test-quality-bypass-diff.ps1 -- regression tests for deterministic quality-bypass diff guard.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$driverPath = Join-Path $root 'driver\00-task-session.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($driverPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
  throw ('driver parse failed: ' + (($errors | ForEach-Object { $_.Message }) -join '; '))
}

$neededFunctions = @('Test-QualityBypassDiffLineIsCommentOnly', 'Test-QualityBypassesInDiff')
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

Check 'helper visible' ($null -ne (Get-Command Test-QualityBypassesInDiff -ErrorAction SilentlyContinue))

$codeDiff = @'
+module.exports = {
+  typescript: {
+    ignoreBuildErrors: true,
+  },
+}
'@
$codeIssues = @(Test-QualityBypassesInDiff -Diff $codeDiff)
Check 'executable Next.js bypass detected' ($codeIssues.Count -eq 1 -and $codeIssues[0].key -eq 'next-ignore-build-errors') $codeIssues

$commentDiff = @'
+# "ignoreBuildErrors: true" appears in a comment.
+// ignoreDuringBuilds: true appears in a comment.
+/* @ts-nocheck appears in a comment. */
+const ok = true
'@
$commentIssues = @(Test-QualityBypassesInDiff -Diff $commentDiff)
Check 'comment-only bypass examples ignored' ($commentIssues.Count -eq 0) $commentIssues

$mixedDiff = @'
+// ignoreBuildErrors: true appears in a comment.
+const nextConfig = { typescript: { ignoreBuildErrors: true } }
'@
$mixedIssues = @(Test-QualityBypassesInDiff -Diff $mixedDiff)
Check 'mixed comment plus executable bypass still detected' ($mixedIssues.Count -eq 1 -and $mixedIssues[0].key -eq 'next-ignore-build-errors') $mixedIssues

$swallowedDiff = '+npm run build || true'
$swallowedIssues = @(Test-QualityBypassesInDiff -Diff $swallowedDiff)
Check 'swallowed build command detected' ($swallowedIssues.Count -eq 1 -and $swallowedIssues[0].key -eq 'swallow-verify-failure') $swallowedIssues

Write-Host ''
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed")
exit $(if ($script:fail -gt 0) { 1 } else { 0 })
