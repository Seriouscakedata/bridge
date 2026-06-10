#Requires -Version 5.1
# test-git-native-helpers.ps1 -- regression coverage for native git argument/result helpers.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')

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
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:fail++
    $suffix = if ($null -ne $Actual) { " actual=" + ($Actual | ConvertTo-Json -Compress -Depth 6) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

$bad = $null
try {
  $bad = Invoke-GitNative -RepoRoot $root -GitArgs @('definitely-not-a-git-subcommand-for-bridge-test')
  Check 'Invoke-GitNative returns nonzero result instead of throwing' (($bad -ne $null) -and ([int]$bad.ExitCode -ne 0) -and (@($bad.Output).Count -gt 0)) $bad
} catch {
  Check 'Invoke-GitNative returns nonzero result instead of throwing' $false $_.Exception.Message
}

$emptyAdd = Invoke-GitAddPaths -RepoRoot $root -Paths @('', $null, '   ')
Check 'Invoke-GitAddPaths skips empty path list' (([int]$emptyAdd.ExitCode -eq 0) -and [bool]$emptyAdd.Skipped) $emptyAdd

$repo = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-git-native-' + [guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Path $repo -Force | Out-Null
  $init = Invoke-GitNative -RepoRoot $repo -GitArgs @('init')
  Check 'Invoke-GitNative runs git init in temp repo' ([int]$init.ExitCode -eq 0) $init
  [void](Invoke-GitNative -RepoRoot $repo -GitArgs @('config','user.email','bridge-test@example.invalid'))
  [void](Invoke-GitNative -RepoRoot $repo -GitArgs @('config','user.name','Bridge Test'))
  [System.IO.File]::WriteAllText((Join-Path $repo 'file with spaces.txt'), "ok`n", [System.Text.Encoding]::ASCII)
  $add = Invoke-GitAddPaths -RepoRoot $repo -Paths @('file with spaces.txt')
  Check 'Invoke-GitAddPaths preserves path with spaces as one native arg' ([int]$add.ExitCode -eq 0) $add
  $commit = Invoke-GitCommitMessage -RepoRoot $repo -Message 'commit message with spaces'
  Check 'Invoke-GitCommitMessage preserves commit message as one native arg' ([int]$commit.ExitCode -eq 0) $commit
} finally {
  if (Test-Path -LiteralPath $repo) { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:fail -gt 0) {
  Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed") -ForegroundColor Red
  exit 1
}

Write-Host ("RESULT: " + $script:pass + " passed, 0 failed") -ForegroundColor Green
