#Requires -Version 5.1
# test-sequential-touchset-enforce.ps1 -- regression coverage for sequential declared touch-set enforcement.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\policy.ps1')
. (Join-Path $root 'lib\parallel.ps1')

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

function Invoke-TestGit {
  param(
    [string]$Repo,
    [string[]]$GitArgs
  )
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = @(& git -C $Repo @GitArgs 2>&1)
    if ($LASTEXITCODE -ne 0) {
      throw ("git " + ($GitArgs -join ' ') + " failed: " + (($out -join ' ') -replace '\s+', ' ').Trim())
    }
    return @($out)
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
}

function New-TouchSetTestRepo {
  $repo = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-seq-touch-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $repo -Force | Out-Null
  Invoke-TestGit -Repo $repo -GitArgs @('init') | Out-Null
  Invoke-TestGit -Repo $repo -GitArgs @('config','user.email','bridge-test@example.invalid') | Out-Null
  Invoke-TestGit -Repo $repo -GitArgs @('config','user.name','Bridge Test') | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $repo 'state.json'), "{}`n", [System.Text.Encoding]::ASCII)
  [System.IO.File]::WriteAllText((Join-Path $repo 'driver.ps1'), "# baseline`n", [System.Text.Encoding]::ASCII)
  Invoke-TestGit -Repo $repo -GitArgs @('add','--','state.json','driver.ps1') | Out-Null
  Invoke-TestGit -Repo $repo -GitArgs @('commit','-m','baseline') | Out-Null
  $base = (Invoke-TestGit -Repo $repo -GitArgs @('rev-parse','HEAD') | Select-Object -First 1).Trim()
  return [pscustomobject]@{ Repo = $repo; Base = $base }
}

if (-not (Get-Command Invoke-SequentialTouchSetCheck -ErrorAction SilentlyContinue)) {
  Write-Host 'FAIL Invoke-SequentialTouchSetCheck is not visible'
  exit 1
}

$case1 = New-TouchSetTestRepo
try {
  Add-Content -LiteralPath (Join-Path $case1.Repo 'driver.ps1') -Value '# changed outside declared set' -Encoding ASCII
  $res = Invoke-SequentialTouchSetCheck -RepoRoot $case1.Repo -DeclaredFiles @('state.json') -BaseCommit $case1.Base -IsOperatorAuthorized:$false
  Check 'undeclared control-plane edit is rejected' ((-not [bool]$res.ok) -and [string]$res.reason -eq 'undeclared-control-plane-edit' -and [string]$res.violatingFile -eq 'driver.ps1') $res
} finally {
  if (Test-Path -LiteralPath $case1.Repo) { Remove-Item -LiteralPath $case1.Repo -Recurse -Force }
}

$case2 = New-TouchSetTestRepo
try {
  Add-Content -LiteralPath (Join-Path $case2.Repo 'driver.ps1') -Value '# changed outside declared set' -Encoding ASCII
  $res = Invoke-SequentialTouchSetCheck -RepoRoot $case2.Repo -DeclaredFiles @('state.json') -BaseCommit $case2.Base -IsOperatorAuthorized:$true
  Check 'operator-authorized task is exempt' ([bool]$res.ok) $res
} finally {
  if (Test-Path -LiteralPath $case2.Repo) { Remove-Item -LiteralPath $case2.Repo -Recurse -Force }
}

$case3 = New-TouchSetTestRepo
try {
  [System.IO.File]::WriteAllText((Join-Path $case3.Repo 'state.json'), "{`"ok`":true}`n", [System.Text.Encoding]::ASCII)
  $res = Invoke-SequentialTouchSetCheck -RepoRoot $case3.Repo -DeclaredFiles @('state.json') -BaseCommit $case3.Base -IsOperatorAuthorized:$false
  Check 'declared-only edit is allowed' ([bool]$res.ok) $res
} finally {
  if (Test-Path -LiteralPath $case3.Repo) { Remove-Item -LiteralPath $case3.Repo -Recurse -Force }
}

$case4 = New-TouchSetTestRepo
try {
  [System.IO.File]::WriteAllText((Join-Path $case4.Repo 'STATE.JSON'), "{`"case`":true}`n", [System.Text.Encoding]::ASCII)
  $res = Invoke-SequentialTouchSetCheck -RepoRoot $case4.Repo -DeclaredFiles @('state.json') -BaseCommit $case4.Base -IsOperatorAuthorized:$false
  Check 'declared path matching is case-insensitive on Windows' ([bool]$res.ok) $res
} finally {
  if (Test-Path -LiteralPath $case4.Repo) { Remove-Item -LiteralPath $case4.Repo -Recurse -Force }
}

$case5 = New-TouchSetTestRepo
try {
  $res = Invoke-SequentialTouchSetCheck -RepoRoot $case5.Repo -DeclaredFiles @('state.json') -BaseCommit 'not-a-real-base-commit' -IsOperatorAuthorized:$false
  Check 'changed-file enumeration failure is fail-closed' ((-not [bool]$res.ok) -and [string]$res.reason -eq 'changed-files-unavailable') $res
} finally {
  if (Test-Path -LiteralPath $case5.Repo) { Remove-Item -LiteralPath $case5.Repo -Recurse -Force }
}

$case6 = New-TouchSetTestRepo
try {
  $res = Invoke-SequentialTouchSetCheck -RepoRoot $case6.Repo -DeclaredFiles @('state.json') -BaseCommit 'not-a-real-base-commit' -IsOperatorAuthorized:$false -ChangedFiles @('state.json')
  Check 'changed-file enumeration failure is fail-closed even with caller-provided changed files' ((-not [bool]$res.ok) -and [string]$res.reason -eq 'changed-files-unavailable') $res
} finally {
  if (Test-Path -LiteralPath $case6.Repo) { Remove-Item -LiteralPath $case6.Repo -Recurse -Force }
}

if ($script:fail -gt 0) {
  Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed") -ForegroundColor Red
  exit 1
}

Write-Host ("RESULT: " + $script:pass + " passed, 0 failed") -ForegroundColor Green
