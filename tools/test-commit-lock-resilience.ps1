#Requires -Version 5.1
# test-commit-lock-resilience.ps1 -- focused coverage for stale index.lock commit retry.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\parallel.ps1')

$script:pass = 0
$script:fail = 0
$script:heartbeatCount = 0

function Update-ChannelHeartbeat {
  param([string]$Slug)
  $script:heartbeatCount++
}

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

function New-TestRepoWithLock {
  $repo = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-index-lock-' + [guid]::NewGuid().ToString('N'))
  $gitDir = Join-Path $repo '.git'
  New-Item -ItemType Directory -Path $gitDir -Force | Out-Null
  $lockPath = Join-Path $gitDir 'index.lock'
  [System.IO.File]::WriteAllText($lockPath, 'stale', [System.Text.Encoding]::ASCII)
  (Get-Item -LiteralPath $lockPath).LastWriteTime = (Get-Date).AddSeconds(-45)
  return [pscustomobject]@{ Repo = $repo; Lock = $lockPath }
}

function New-TestWorktreeStyleRepoWithLock {
  $repo = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-index-lock-wt-' + [guid]::NewGuid().ToString('N'))
  $gitDir = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-index-lock-gitdir-' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $repo -Force | Out-Null
  New-Item -ItemType Directory -Path $gitDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $repo '.git'), ('gitdir: ' + $gitDir + "`n"), [System.Text.Encoding]::ASCII)
  $lockPath = Join-Path $gitDir 'index.lock'
  [System.IO.File]::WriteAllText($lockPath, 'stale', [System.Text.Encoding]::ASCII)
  (Get-Item -LiteralPath $lockPath).LastWriteTime = (Get-Date).AddSeconds(-45)
  return [pscustomobject]@{ Repo = $repo; GitDir = $gitDir; Lock = $lockPath }
}

function Wait-NoGitProcess {
  $deadline = (Get-Date).AddSeconds(3)
  while ((Get-Date) -lt $deadline) {
    if (@(Get-Process -Name 'git' -ErrorAction SilentlyContinue).Count -eq 0) { return $true }
    Start-Sleep -Milliseconds 100
  }
  return (@(Get-Process -Name 'git' -ErrorAction SilentlyContinue).Count -eq 0)
}

if (-not (Get-Command Remove-StaleIndexLock -ErrorAction SilentlyContinue)) {
  Write-Host 'FAIL Remove-StaleIndexLock is not visible'
  exit 1
}

$case1 = New-TestRepoWithLock
try {
  $noGit = Wait-NoGitProcess
  $removed = Remove-StaleIndexLock -RepoRoot $case1.Repo
  Check 'stale lock is removed when no git process is alive' ($noGit -and $removed -and -not (Test-Path -LiteralPath $case1.Lock)) @{ noGit = $noGit; removed = $removed; exists = (Test-Path -LiteralPath $case1.Lock) }
} finally {
  if (Test-Path -LiteralPath $case1.Repo) { Remove-Item -LiteralPath $case1.Repo -Recurse -Force }
}

$case2 = New-TestRepoWithLock
$gitProc = $null
try {
  $fakeGit = Join-Path $case2.Repo 'git.exe'
  Copy-Item -LiteralPath (Get-Command powershell.exe).Source -Destination $fakeGit -Force
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $fakeGit
  $psi.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 10"'
  $psi.UseShellExecute = $false
  $gitProc = New-Object System.Diagnostics.Process
  $gitProc.StartInfo = $psi
  [void]$gitProc.Start()
  Start-Sleep -Milliseconds 250
  $blocked = Remove-StaleIndexLock -RepoRoot $case2.Repo
  Check 'live git process prevents stale lock removal' ((-not $blocked) -and (Test-Path -LiteralPath $case2.Lock)) @{ removed = $blocked; exists = (Test-Path -LiteralPath $case2.Lock) }
} finally {
  try {
    if ($gitProc -and -not $gitProc.HasExited) {
      $gitProc.Kill()
      [void]$gitProc.WaitForExit(3000)
    }
  } catch {}
  try { if ($gitProc) { $gitProc.Dispose() } } catch {}
  if (Test-Path -LiteralPath $case2.Repo) { Remove-Item -LiteralPath $case2.Repo -Recurse -Force -ErrorAction SilentlyContinue }
}

$caseWorktree = New-TestWorktreeStyleRepoWithLock
try {
  $noGit = Wait-NoGitProcess
  $removed = Remove-StaleIndexLock -RepoRoot $caseWorktree.Repo
  Check 'stale lock is removed from resolved worktree gitdir' ($noGit -and $removed -and -not (Test-Path -LiteralPath $caseWorktree.Lock)) @{ noGit = $noGit; removed = $removed; exists = (Test-Path -LiteralPath $caseWorktree.Lock) }
} finally {
  if (Test-Path -LiteralPath $caseWorktree.Repo) { Remove-Item -LiteralPath $caseWorktree.Repo -Recurse -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $caseWorktree.GitDir) { Remove-Item -LiteralPath $caseWorktree.GitDir -Recurse -Force -ErrorAction SilentlyContinue }
}

$casePreflight = New-TestRepoWithLock
try {
  $script:preflightAttempts = 0
  $preflightResult = Invoke-ParallelDispatchGitCommitWithRetry -RepoRoot $casePreflight.Repo -BackoffSeconds 0 -Operation {
    $script:preflightAttempts++
    if (Test-Path -LiteralPath $casePreflight.Lock) {
      return [pscustomobject]@{ ExitCode = 1; Output = @("fatal: Unable to create '.git/index.lock': File exists") }
    }
    return [pscustomobject]@{ ExitCode = 0; Output = @('commit ok') }
  }
  Check 'commit preflight clears stale index.lock before first attempt' (([int]$preflightResult.ExitCode -eq 0) -and $script:preflightAttempts -eq 1 -and [bool]$preflightResult.PreRemovedLock -and -not (Test-Path -LiteralPath $casePreflight.Lock)) @{ exit = $preflightResult.ExitCode; attempts = $script:preflightAttempts; preRemoved = $preflightResult.PreRemovedLock; exists = (Test-Path -LiteralPath $casePreflight.Lock) }
} finally {
  if (Test-Path -LiteralPath $casePreflight.Repo) { Remove-Item -LiteralPath $casePreflight.Repo -Recurse -Force }
}

$case3 = New-TestRepoWithLock
try {
  $countPath = Join-Path $case3.Repo 'commit-count.txt'
  $logPath = Join-Path $case3.Repo 'git-log.txt'
  [System.IO.File]::WriteAllText($countPath, '0', [System.Text.Encoding]::ASCII)
  $fakeGitCmd = Join-Path $case3.Repo 'git.cmd'
  $cmd = @"
@echo off
echo %*>>"$logPath"
echo %* | findstr /C:"commit" >nul
if errorlevel 1 exit /b 0
set /p COUNT=<"$countPath"
if "%COUNT%"=="0" (
  >"$countPath" echo 1
  echo fatal: Unable to create '.git/index.lock': File exists
  exit /b 1
)
>"$countPath" echo 2
exit /b 0
"@
  [System.IO.File]::WriteAllText($fakeGitCmd, $cmd, [System.Text.Encoding]::ASCII)

  $delivered = New-Object 'System.Collections.Generic.HashSet[string]'
  [void]$delivered.Add('file.txt')
  $ctx = @{
    collectedStreams = 1
    deliveredPaths = $delivered
    gitExe = $fakeGitCmd
    bridgeRoot = $case3.Repo
    merged = 0
    workers = @()
    completed = @{}
    quarantined = (New-Object 'System.Collections.Generic.List[string]')
  }
  Commit-ParallelDispatchCollectedOutputs -Context $ctx
  $attemptCount = [int](Get-Content -LiteralPath $countPath -Raw)
  Check 'commit retry succeeds after index.lock failure' ($ctx.merged -eq 1 -and $attemptCount -eq 2 -and $script:heartbeatCount -ge 1) @{ merged = $ctx.merged; attempts = $attemptCount; heartbeat = $script:heartbeatCount }
} finally {
  if (Test-Path -LiteralPath $case3.Repo) { Remove-Item -LiteralPath $case3.Repo -Recurse -Force }
}

if ($script:fail -gt 0) {
  Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed") -ForegroundColor Red
  exit 1
}

Write-Host ("RESULT: " + $script:pass + " passed, 0 failed") -ForegroundColor Green
