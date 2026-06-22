#Requires -Version 5.1
# Verifies Test-CoderClaims resolves git SHA claims through the explicit repo root,
# not through the current process directory or the bridge repo.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'driver\00-task-session.ps1')

$script:pass = 0
$script:fail = 0
function Check {
  param([string]$Name, [bool]$Condition, $Actual = $null)
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:fail++
    $suffix = if ($null -ne $Actual) { ' actual=' + ($Actual | ConvertTo-Json -Compress -Depth 6) } else { '' }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

function Invoke-Git {
  param([string]$Repo, [string[]]$GitArgs)
  $out = & git -C $Repo @GitArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw ("git -C " + $Repo + " " + ($GitArgs -join ' ') + " failed: " + (($out | ForEach-Object { [string]$_ }) -join "`n"))
  }
  return $out
}

function New-TestRepo {
  param([string]$Path)
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
  Invoke-Git -Repo $Path -GitArgs @('init','-q') | Out-Null
  Invoke-Git -Repo $Path -GitArgs @('config','user.email','bridge-test@example.invalid') | Out-Null
  Invoke-Git -Repo $Path -GitArgs @('config','user.name','Bridge Test') | Out-Null
  Invoke-Git -Repo $Path -GitArgs @('config','core.autocrlf','false') | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $Path 'README.md'), "init`n", [System.Text.UTF8Encoding]::new($false))
  Invoke-Git -Repo $Path -GitArgs @('add','README.md') | Out-Null
  Invoke-Git -Repo $Path -GitArgs @('commit','-q','-m','init') | Out-Null
}

$tmpRoot = Join-Path $root ('tmp\coder-claims-sha-' + [guid]::NewGuid().ToString('N'))
$oldLocation = Get-Location
try {
  $bridgeRepo = Join-Path $tmpRoot 'bridge-repo'
  $projectRepo = Join-Path $tmpRoot 'project-repo'
  New-TestRepo -Path $bridgeRepo
  New-TestRepo -Path $projectRepo

  [System.IO.File]::WriteAllText((Join-Path $projectRepo 'project.txt'), "project-only`n", [System.Text.UTF8Encoding]::new($false))
  Invoke-Git -Repo $projectRepo -GitArgs @('add','project.txt') | Out-Null
  Invoke-Git -Repo $projectRepo -GitArgs @('commit','-q','-m','project-only') | Out-Null
  $projectSha = ((Invoke-Git -Repo $projectRepo -GitArgs @('rev-parse','--short=12','HEAD')) | Select-Object -First 1).Trim()

  Set-Location $env:USERPROFILE
  $reply = "STATUS: DONE`ncommit $projectSha"
  $withoutRepoRoot = Test-CoderClaims -Reply $reply -BridgeRoot $bridgeRepo
  $withRepoRoot = Test-CoderClaims -Reply $reply -BridgeRoot $bridgeRepo -ProjectRoot $projectRepo

  Check 'control case misses project-only SHA from bridge repo' (@($withoutRepoRoot.violations | Where-Object { $_.kind -eq 'git-sha' }).Count -eq 1) $withoutRepoRoot
  Check 'explicit project repo root finds project-only SHA' (@($withRepoRoot.violations | Where-Object { $_.kind -eq 'git-sha' }).Count -eq 0) $withRepoRoot
  Check 'explicit project repo root records git-sha check' (@($withRepoRoot.checks | Where-Object { $_.kind -eq 'git-sha' }).Count -eq 1) $withRepoRoot
} finally {
  Set-Location $oldLocation
  $safeTmp = [System.IO.Path]::GetFullPath((Join-Path $root 'tmp')).TrimEnd('\') + '\'
  $fullTmp = [System.IO.Path]::GetFullPath($tmpRoot)
  if ($fullTmp.StartsWith($safeTmp, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullTmp)) {
    Remove-Item -LiteralPath $fullTmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}

if ($script:fail -gt 0) {
  Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed") -ForegroundColor Red
  exit 1
}
Write-Host ("RESULT: " + $script:pass + " passed, 0 failed") -ForegroundColor Green
