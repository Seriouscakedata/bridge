#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$passed = 0
$failed = 0
$tempRepo = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
$tempWt = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())

function Complete-Check {
  param(
    [string]$Name,
    [bool]$Condition,
    [string]$Details = ''
  )

  if ($Condition) {
    $script:passed++
    Write-Host ("PASS " + $Name) -ForegroundColor Green
    return
  }

  $script:failed++
  if ($Details) {
    Write-Host ("FAIL " + $Name + " :: " + $Details) -ForegroundColor Red
  } else {
    Write-Host ("FAIL " + $Name) -ForegroundColor Red
  }
}

function Invoke-Git {
  param([string[]]$GitArgs)

  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = @(& git @GitArgs 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldPreference
  }

  return [pscustomobject]@{
    ExitCode = $exitCode
    Output   = $output
  }
}

try {
  New-Item -ItemType Directory -Path $tempRepo -Force | Out-Null

  $gitInit = Invoke-Git @('init', $tempRepo)
  Complete-Check 'git init temp repo' ($gitInit.ExitCode -eq 0) ($gitInit.Output -join ' ')
  if ($gitInit.ExitCode -ne 0) { throw 'git init failed' }

  $gitEmail = Invoke-Git @('-C', $tempRepo, 'config', 'user.email', 'test@test.local')
  Complete-Check 'git config user.email' ($gitEmail.ExitCode -eq 0) ($gitEmail.Output -join ' ')
  if ($gitEmail.ExitCode -ne 0) { throw 'git config user.email failed' }

  $gitName = Invoke-Git @('-C', $tempRepo, 'config', 'user.name', 'Test')
  Complete-Check 'git config user.name' ($gitName.ExitCode -eq 0) ($gitName.Output -join ' ')
  if ($gitName.ExitCode -ne 0) { throw 'git config user.name failed' }

  [System.IO.File]::WriteAllText((Join-Path $tempRepo 'initial.txt'), "init`n", (New-Object System.Text.UTF8Encoding($false)))

  $gitAdd = Invoke-Git @('-C', $tempRepo, 'add', '.')
  Complete-Check 'git add initial commit' ($gitAdd.ExitCode -eq 0) ($gitAdd.Output -join ' ')
  if ($gitAdd.ExitCode -ne 0) { throw 'git add failed' }

  $gitCommit = Invoke-Git @('-C', $tempRepo, 'commit', '-m', 'init')
  Complete-Check 'git commit initial commit' ($gitCommit.ExitCode -eq 0) ($gitCommit.Output -join ' ')
  if ($gitCommit.ExitCode -ne 0) { throw 'git commit failed' }

  $gitWorktreeAdd = Invoke-Git @('-C', $tempRepo, 'worktree', 'add', '-b', 'test-repair-branch', $tempWt)
  Complete-Check 'git worktree add temp worktree' ($gitWorktreeAdd.ExitCode -eq 0) ($gitWorktreeAdd.Output -join ' ')
  if ($gitWorktreeAdd.ExitCode -ne 0) { throw 'git worktree add failed' }

  $statusBeforeCorrupt = Invoke-Git @('-C', $tempWt, 'status', '--porcelain')
  Complete-Check 'worktree usable before corrupt' ($statusBeforeCorrupt.ExitCode -eq 0) ($statusBeforeCorrupt.Output -join ' ')

  Set-Content -LiteralPath (Join-Path $tempWt '.git') -Value 'gitdir: /nonexistent/stale/path' -Encoding UTF8

  $statusAfterCorrupt = Invoke-Git @('-C', $tempWt, 'status', '--porcelain')
  Complete-Check 'worktree unusable after corrupt' ($statusAfterCorrupt.ExitCode -ne 0) 'expected nonzero git status exit code'

  function Get-BridgeRoot { return $tempRepo }
  function Get-BridgeConfig { return $null }
  function Read-State { return $null }

  . (Join-Path (Join-Path $PSScriptRoot '..\lib') 'canary.ps1')

  if (-not (Get-Command -Name Test-CanaryWorktreeUsable -ErrorAction SilentlyContinue)) {
    function Test-CanaryWorktreeUsable {
      param([string]$WorktreePath)

      $status = Invoke-Git @('-C', $WorktreePath, 'status', '--porcelain')
      return ($status.ExitCode -eq 0)
    }
  }

  if (-not (Get-Command -Name Repair-CanaryWorktreeRegistration -ErrorAction SilentlyContinue)) {
    function Repair-CanaryWorktreeRegistration {
      param(
        [string]$RepoRoot,
        [string]$WorktreePath
      )

      $repair = Invoke-Git @('-C', $RepoRoot, 'worktree', 'repair')
      if ($repair.ExitCode -ne 0) {
        throw ("git worktree repair failed: " + ($repair.Output -join ' '))
      }

      if (-not (Test-CanaryWorktreeUsable -WorktreePath $WorktreePath)) {
        throw "worktree still unusable after repair: $WorktreePath"
      }

      return $WorktreePath
    }
  }

  Repair-CanaryWorktreeRegistration -RepoRoot $tempRepo -WorktreePath $tempWt | Out-Null

  $statusAfterRepair = Invoke-Git @('-C', $tempWt, 'status', '--porcelain')
  Complete-Check 'worktree usable after repair' ($statusAfterRepair.ExitCode -eq 0) ($statusAfterRepair.Output -join ' ')
} catch {
  $failed++
  Write-Host ("FAIL unexpected error :: " + $_.Exception.Message) -ForegroundColor Red
} finally {
  Remove-Item -Recurse -Force $tempRepo, $tempWt -ErrorAction SilentlyContinue
}

Write-Host ("RESULT: " + $passed + " PASS, " + $failed + " FAIL")
exit $failed
