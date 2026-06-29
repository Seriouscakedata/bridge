param()
# Verifies the 2026-06-29 latency root-fix in lib/parallel.ps1 Get-WorkerWorktree: a STALE worktree
# registration left by a prior failed/quarantined run of the same task hash must NOT cause `git worktree
# add` to throw (which forced the slow planner fallback + a quarantine). The fix prunes stale registrations
# (and retries with a fresh branch) so the worker worktree is (re)created on the fast path.
$ErrorActionPreference = 'Stop'
function Assert-True { param([bool]$Cond,[string]$Msg) if (-not $Cond) { throw ("FAIL: " + $Msg) } }

$gitExe = (Get-Command git -ErrorAction Stop).Source
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('wt-stale-test-' + [guid]::NewGuid().ToString('N'))
$script:Repo = Join-Path $tmp 'repo'
$script:WtRoot = Join-Path $tmp 'worktrees'
try {
  New-Item -ItemType Directory -Path $script:Repo -Force | Out-Null
  & $gitExe -C $script:Repo init -q 2>&1 | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $script:Repo 'a.txt'), 'hello')
  & $gitExe -C $script:Repo add -A 2>&1 | Out-Null
  & $gitExe -C $script:Repo -c user.name=t -c user.email=t@t commit -q -m init 2>&1 | Out-Null
  $script:Base = ((& $gitExe -C $script:Repo rev-parse HEAD) | Select-Object -First 1).Trim()

  . 'C:\Users\rafie\.bridge-runtime\tmp\op-bootstrap.ps1' *> $null
  # Load parallel.ps1 explicitly (Get-WorkerWorktree lives there).
  . 'C:\Users\rafie\OneDrive\Documents\bridge\lib\parallel.ps1' *> $null

  # Override the environment helpers to point at the temp repo.
  function Get-ParallelRoot { return $script:WtRoot }
  function Get-ParallelRepoRoot { return $script:Repo }
  function Get-ParallelTaskBaseCommit { return $script:Base }
  function Get-GitExe { return $gitExe }

  # Case A — NORMAL: first creation works.
  $pA = Get-WorkerWorktree -StreamId 'wp1' -TaskHash 'h1'
  Assert-True (Test-Path -LiteralPath $pA) "Case A: worktree wp1 created"
  & $gitExe -C $script:Repo show-ref --verify --quiet 'refs/heads/wip/parallel/h1/wp1'
  Assert-True ($LASTEXITCODE -eq 0) "Case A: branch exists"

  # Case B — STALE REGISTRATION: delete the worktree DIR without `git worktree remove` (exactly what a
  # cleaned/crashed prior run leaves), then re-request the SAME stream+hash. Pre-fix this threw; post-fix
  # the prune+retry must (re)create it successfully.
  Remove-Item -LiteralPath $pA -Recurse -Force
  Assert-True (-not (Test-Path -LiteralPath $pA)) "Case B: dir removed (registration now stale)"
  $threw = $false
  try { $pB = Get-WorkerWorktree -StreamId 'wp1' -TaskHash 'h1' } catch { $threw = $true }
  Assert-True (-not $threw) "Case B: Get-WorkerWorktree did NOT throw on stale registration (fix works)"
  Assert-True (Test-Path -LiteralPath $pB) "Case B: worktree wp1 RE-created after stale registration"

  # Case C — second independent stream of same task still works alongside.
  $pC = Get-WorkerWorktree -StreamId 'wp2' -TaskHash 'h1'
  Assert-True (Test-Path -LiteralPath $pC) "Case C: independent stream wp2 created"
  Assert-True ($pC -ne $pB) "Case C: wp2 path distinct from wp1"

  Write-Host "OK worktree-stale-recovery: normal + stale-registration-recovery + independent-stream (4/4 asserts groups)"
} finally {
  try {
    & $gitExe -C $script:Repo worktree prune 2>&1 | Out-Null
    $resolved = [System.IO.Path]::GetFullPath($tmp)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
      Get-ChildItem -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes='Normal' } catch {} }
      Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}
