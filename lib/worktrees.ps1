# worktrees.ps1 -- isolation primitives for parallel/sandboxed work via git worktrees.
# Each sub-task runs in its OWN worktree (own branch, own working copy) -> no file
# conflicts between parallel workers; merge back to the repo only after the work is done.
# This is the foundation for both Скачок №1 (параллель) and №2 (песочница).
# Dot-sourced from common.ps1. All git ops are best-effort and never throw.

function Get-GitExe {
  $p = 'C:\Program Files\Git\cmd\git.exe'
  if (Test-Path $p) { return $p }
  $c = Get-Command git -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  return 'git'
}

function New-Worktree {
  # Create an isolated worktree on a new branch off HEAD inside $RepoRoot/.bridge-wt/<Name>.
  # Returns @{ repo; branch; path } or $null. Use for a project repo OR the bridge repo.
  param([string]$RepoRoot, [string]$Name)
  $ErrorActionPreference = 'Continue'   # git writes progress to stderr; don't let it throw under EAP=Stop
  if ([string]::IsNullOrWhiteSpace($RepoRoot) -or -not (Test-Path (Join-Path $RepoRoot '.git'))) { return $null }
  $git = Get-GitExe
  $safe = ([string]$Name) -replace '[^A-Za-z0-9_.-]+','-'
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = [guid]::NewGuid().ToString('N').Substring(0,8) }
  $branch = "bridge-wt/$safe"
  $path   = Join-Path (Join-Path $RepoRoot '.bridge-wt') $safe
  try {
    & $git -C $RepoRoot worktree add -b $branch $path HEAD 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $path)) { return $null }
    return [ordered]@{ repo = $RepoRoot; branch = $branch; path = $path }
  } catch { return $null }
}

function Merge-Worktree {
  # Commit any changes in the worktree, then merge its branch into the repo's current branch.
  # Returns @{ ok; conflict; committed }. On conflict, aborts the merge (no half-merged state).
  param($Wt, [string]$Message = 'bridge: merge worktree')
  $ErrorActionPreference = 'Continue'
  $git = Get-GitExe
  $committed = $false
  try {
    & $git -C $Wt.path add -A 2>&1 | Out-Null
    & $git -C $Wt.path commit -m $Message 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $committed = $true }   # non-zero usually = nothing to commit
    & $git -C $Wt.repo merge --no-edit $Wt.branch 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { return @{ ok = $true; conflict = $false; committed = $committed } }
    & $git -C $Wt.repo merge --abort 2>&1 | Out-Null
    return @{ ok = $false; conflict = $true; committed = $committed }
  } catch { return @{ ok = $false; conflict = $false; committed = $committed } }
}

function Remove-Worktree {
  # Tear down a worktree and delete its branch. Safe to call even if already gone.
  param($Wt)
  $ErrorActionPreference = 'Continue'
  $git = Get-GitExe
  try { & $git -C $Wt.repo worktree remove --force $Wt.path 2>&1 | Out-Null } catch {}
  try { & $git -C $Wt.repo branch -D $Wt.branch 2>&1 | Out-Null } catch {}
}

function Get-Worktrees {
  param([string]$RepoRoot)
  $git = Get-GitExe
  try { return (& $git -C $RepoRoot worktree list 2>&1) } catch { return @() }
}

function Clear-OrphanWorktrees {
  # Best-effort janitor for leaked linked-worktree admin dirs under .git/worktrees/.
  # Parallel workers create linked worktrees; if teardown ('git worktree remove') runs
  # while OneDrive holds .git/worktrees/<name> files as READONLY reparse points (Files
  # On-Demand), git deletes the working tree + gitdir but cannot delete the readonly
  # metadata -> every later commit's auto-gc logs "failed to delete .git/worktrees/X:
  # Permission denied". We identify admin dirs that no longer map to a live worktree (by
  # PATH, per 'git worktree list --porcelain', so git's dedup naming can't fool us) and
  # force-remove them after clearing readonly. Never throws; returns count removed.
  param([string]$RepoRoot)
  $ErrorActionPreference = 'Continue'
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) { try { $RepoRoot = Get-BridgeRoot } catch {} }
  if ([string]::IsNullOrWhiteSpace($RepoRoot)) { return 0 }
  $adminRoot = Join-Path $RepoRoot '.git\worktrees'
  if (-not (Test-Path -LiteralPath $adminRoot)) { return 0 }
  $git = Get-GitExe
  $removed = 0
  try {
    # 1) set of live worktree paths (normalized) straight from git
    $valid = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    try {
      foreach ($line in (& $git -C $RepoRoot worktree list --porcelain 2>$null)) {
        if ([string]$line -match '^worktree\s+(.+)$') {
          $wp = $matches[1].Trim()
          try { $wp = ([System.IO.Path]::GetFullPath($wp)).TrimEnd('\','/') } catch {}
          [void]$valid.Add($wp)
        }
      }
    } catch {}
    # 2) let git prune the easy ones first (readonly leftovers will survive)
    try { & $git -C $RepoRoot worktree prune 2>$null | Out-Null } catch {}
    # 3) force-remove leftover admin dirs that don't map to a live worktree
    foreach ($d in @(Get-ChildItem -LiteralPath $adminRoot -Directory -Force -ErrorAction SilentlyContinue)) {
      $gitdir = Join-Path $d.FullName 'gitdir'
      $isOrphan = $false
      if (-not (Test-Path -LiteralPath $gitdir)) {
        $isOrphan = $true
      } else {
        $wtPath = $null
        try {
          $target = (Get-Content -LiteralPath $gitdir -Raw -ErrorAction Stop).Trim()
          if (-not [string]::IsNullOrWhiteSpace($target)) {
            $wtPath = ([System.IO.Path]::GetFullPath((Split-Path -Parent $target))).TrimEnd('\','/')
          }
        } catch {}
        if ([string]::IsNullOrWhiteSpace($wtPath) -or -not $valid.Contains($wtPath)) { $isOrphan = $true }
      }
      if (-not $isOrphan) { continue }
      try {
        Get-ChildItem -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }
        try { (Get-Item -LiteralPath $d.FullName -Force).Attributes = 'Directory' } catch {}
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop
        $removed++
      } catch {}
    }
  } catch {}
  return $removed
}
