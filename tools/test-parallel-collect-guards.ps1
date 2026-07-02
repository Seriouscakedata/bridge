param()

# ==============================================================================
# tools/test-parallel-collect-guards.ps1  (2026-07-02 audit fixes)
#   Regression tests for the parallel collect/quarantine + dispatch guards:
#     1. Test-ParallelCollectedPathAllowed inverse parent-dir containment rule
#        (untracked new-directory collapse used to false-quarantine healthy streams)
#        + the built-in self-check with its new parent-dir cases.
#     2. Test-ParallelSalvageDecision: failed/partial commits=0 streams with a
#        clean in-touch-set diff are salvageable (collected, not discarded).
#     3. Test-ParallelStreamAlreadyCommitted: streams whose declared files are
#        fully committed since the task base are not (re-)dispatched.
#     4. Get-ParallelWorktreeChangedPaths uses 'status --porcelain -uall' so new
#        files inside NEW directories are reported individually (real temp repo).
#     5. Test-CanParallelize drops already-committed streams (duplicate dispatch).
#     6. Start-ParallelDispatchWorker spawns codex workers with -HostManagedCommit
#        (Windows codex sandbox cannot write linked-worktree git metadata).
#     7. Set-ParallelSharedGradleUserHome: one shared gradle home for all streams.
# ==============================================================================

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
. (Join-Path $root 'lib\common.ps1') | Out-Null
. (Join-Path $root 'lib\parallel.ps1') | Out-Null

# Silence channel side effects (event messages) for the whole test run.
function Add-Message { param([string]$From,[string]$Text,[string]$Kind) }

$fail = 0
function Assert-True { param([bool]$Cond, [string]$Label)
  $res = if ($Cond) { 'PASS' } else { 'FAIL' }
  if (-not $Cond) { $script:fail++ }
  Write-Host ("[{0}] {1}" -f $res, $Label)
}

# ---- 1. touch-set matcher: inverse parent-dir rule ----
Write-Host "== 1. touch-set matcher (parent-dir inverse rule) =="
$sc = $false
try { $sc = [bool](Test-ParallelCollectedPathAllowedSelfCheck) } catch { Write-Host ("self-check threw: " + $_.Exception.Message) }
Assert-True $sc "built-in self-check passes (incl. new parentdir cases)"
Assert-True (Test-ParallelCollectedPathAllowed -RelativePath 'app/src/main/res/' -DeclaredFiles @('app/src/main/androidmanifest.xml','app/src/main/res/values/strings.xml','app/src/main/res/values/themes.xml')) "live shape wp1: collapsed 'app/src/main/res/' allowed (parent of declared files)"
Assert-True (Test-ParallelCollectedPathAllowed -RelativePath 'app/src/main/java/com/x/ui/style/' -DeclaredFiles @('app/src/main/java/com/x/ui/style/stylescreen.kt')) "live shape wp3: collapsed '.../ui/style/' allowed"
Assert-True (-not (Test-ParallelCollectedPathAllowed -RelativePath 'app/src/other/' -DeclaredFiles @('app/src/main/res/values/strings.xml'))) "unrelated dir still denied"
Assert-True (-not (Test-ParallelCollectedPathAllowed -RelativePath 'app/src/main/resx/' -DeclaredFiles @('app/src/main/res/values/strings.xml'))) "prefix-lookalike dir denied (resx vs res)"
Assert-True (Test-ParallelCollectedPathAllowed -RelativePath 'APP\SRC\MAIN\RES\' -DeclaredFiles @('app/src/main/res/values/strings.xml')) "case-insensitive + backslash parent dir allowed"
Assert-True (-not (Test-ParallelCollectedPathAllowed -RelativePath '.git/' -DeclaredFiles @('.git/config'))) ".git parent never allowed"
Assert-True (-not (Test-ParallelCollectedPathAllowed -RelativePath 'app/' -DeclaredFiles @())) "no declared files -> denied"

# ---- 2. salvage decision (failed/partial commits=0) ----
Write-Host "== 2. salvage decision =="
Assert-True (Test-ParallelSalvageDecision -ChangedPaths @('app/a.kt','app/b.kt') -DeclaredFiles @('app/a.kt','app/b.kt')) "full in-touch-set diff -> salvage"
Assert-True (Test-ParallelSalvageDecision -ChangedPaths @('app/res/') -DeclaredFiles @('app/res/values/strings.xml')) "collapsed parent-dir entry -> salvage (inverse rule)"
Assert-True (-not (Test-ParallelSalvageDecision -ChangedPaths @() -DeclaredFiles @('app/a.kt'))) "empty diff -> no salvage"
Assert-True (-not (Test-ParallelSalvageDecision -ChangedPaths @('app/a.kt','outside/c.kt') -DeclaredFiles @('app/a.kt'))) "one outside path -> no salvage"
Assert-True (-not (Test-ParallelSalvageDecision -ChangedPaths @('app/a.kt') -DeclaredFiles @())) "no declared files -> no salvage"
Assert-True (Test-ParallelSalvageDecision -ChangedPaths @('app\a.kt') -DeclaredFiles @('app/a.kt')) "backslash changed path matches declared"

# ---- 3. already-committed decision ----
Write-Host "== 3. already-committed decision =="
Assert-True (Test-ParallelStreamAlreadyCommitted -DeclaredFiles @('app/a.kt','app/b.kt') -CommittedChangedPaths @('app/a.kt','app/b.kt','app/c.kt')) "all declared committed -> skip dispatch"
Assert-True (-not (Test-ParallelStreamAlreadyCommitted -DeclaredFiles @('app/a.kt','app/b.kt') -CommittedChangedPaths @('app/a.kt'))) "partial coverage -> still dispatch"
Assert-True (-not (Test-ParallelStreamAlreadyCommitted -DeclaredFiles @('app/a.kt') -CommittedChangedPaths @())) "no commits since base -> dispatch"
Assert-True (Test-ParallelStreamAlreadyCommitted -DeclaredFiles @('docs/release.md') -CommittedChangedPaths @('Docs\RELEASE.md')) "case/slash-insensitive match"
Assert-True (-not (Test-ParallelStreamAlreadyCommitted -DeclaredFiles @() -CommittedChangedPaths @('app/a.kt'))) "no declared files -> not covered"

# ---- 4. real git repo: -uall lists new files in new dirs individually ----
Write-Host "== 4. -uall in the collect changed-set (real temp repo) =="
$git = 'git'
try { if (Get-Command Get-GitExe -ErrorAction SilentlyContinue) { $git = [string](Get-GitExe) } } catch {}
$tmpRepo = Join-Path $env:TEMP ('collect-guards-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tmpRepo -Force | Out-Null
try {
  & $git -C $tmpRepo init -q 2>$null | Out-Null
  & $git -C $tmpRepo config user.email 'test@bridge.local' 2>$null | Out-Null
  & $git -C $tmpRepo config user.name 'bridge-test' 2>$null | Out-Null
  Set-Content -LiteralPath (Join-Path $tmpRepo 'base.txt') -Value 'base' -Encoding Ascii
  & $git -C $tmpRepo add -A 2>$null | Out-Null
  & $git -C $tmpRepo commit -q -m 'base' 2>$null | Out-Null
  $baseSha = ([string](& $git -C $tmpRepo rev-parse HEAD 2>$null)).Trim()
  Assert-True (-not [string]::IsNullOrWhiteSpace($baseSha)) "temp repo base commit created"

  # the exact defect shape: a new file inside a NEW directory + a modified tracked file
  New-Item -ItemType Directory -Path (Join-Path $tmpRepo 'newdir\deep') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $tmpRepo 'newdir\deep\file.kt') -Value 'x' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $tmpRepo 'base.txt') -Value 'changed' -Encoding Ascii

  # control: plain porcelain (no -uall) collapses the new dir (the old defect)
  $plain = @(& $git -C $tmpRepo status --porcelain 2>$null | Where-Object { $_ } | ForEach-Object { ($_.Substring([Math]::Min(3,$_.Length))).Trim() })
  Assert-True ($plain -contains 'newdir/') "control: plain porcelain collapses to 'newdir/' (defect shape)"

  # NOTE: assign directly -- @(<command>) would wrap the returned string[] into a
  # one-element object[] instead of passing it through (PS command vs expression rule).
  $changedArr = Get-ParallelWorktreeChangedPaths -GitExe $git -Worktree $tmpRepo -BaseCommit $baseSha
  $changedArr = @($changedArr)
  Assert-True ($changedArr -contains 'newdir/deep/file.kt') "-uall reports the new file individually"
  Assert-True (@($changedArr | Where-Object { [string]$_ -match '/$' }).Count -eq 0) "no collapsed 'dir/' entries in the changed set"
  Assert-True ($changedArr -contains 'base.txt') "modified tracked file reported"

  # ---- 5. Test-CanParallelize skips streams already committed since task base ----
  Write-Host "== 5. Test-CanParallelize duplicate-dispatch guard =="
  New-Item -ItemType Directory -Path (Join-Path $tmpRepo 'sa') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $tmpRepo 'sb') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $tmpRepo 'done') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $tmpRepo 'sa\a.kt') -Value 'a' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $tmpRepo 'sb\b.kt') -Value 'b' -Encoding Ascii
  Set-Content -LiteralPath (Join-Path $tmpRepo 'done\x.kt') -Value 'x' -Encoding Ascii

  function Get-ParallelRepoRoot { $tmpRepo }
  function Get-ParallelTaskBaseCommit { $baseSha }

  $plan = @"
[[PARALLEL:A]]
Files: sa/a.kt
Complexity: simple
build A
[[/PARALLEL:A]]
[[PARALLEL:B]]
Files: sb/b.kt
Complexity: simple
build B
[[/PARALLEL:B]]
[[PARALLEL:C]]
Files: done/x.kt
Complexity: simple
build C
[[/PARALLEL:C]]
"@

  # base == HEAD -> nothing committed yet -> all 3 streams dispatch
  $res1 = Test-CanParallelize -PlanText $plan
  Assert-True (@($res1).Count -eq 3) "no committed work since base -> all 3 streams kept"

  # commit stream C's declared file -> C must be dropped as already delivered
  & $git -C $tmpRepo add -- done/x.kt 2>$null | Out-Null
  & $git -C $tmpRepo commit -q -m 'delivered C by main turn' 2>$null | Out-Null
  $res2 = Test-CanParallelize -PlanText $plan
  $ids2 = @(@($res2) | ForEach-Object { [string]$_.id })
  Assert-True (@($res2).Count -eq 2) "committed stream dropped -> 2 streams remain"
  Assert-True (-not ($ids2 -contains 'c')) "the already-committed stream (C) is the dropped one"
  Assert-True (($ids2 -contains 'a') -and ($ids2 -contains 'b')) "unfinished streams (A,B) still dispatch"
} finally {
  try { Remove-Item -LiteralPath $tmpRepo -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

# ---- 6. codex workers spawn in host-managed-commit mode ----
Write-Host "== 6. codex host-managed-commit spawn =="
$script:capturedHMC = $null
function Get-ParallelDispatchBranchName { param([string]$StreamId,[string]$TaskHash) 'wip-test-branch' }
function Get-WorkerWorktree { param([string]$StreamId,[string]$TaskHash) $env:TEMP }
function Write-ParallelDispatchSpawnMessage { param([object]$Stream,[object]$WorkerSpec) }
function Spawn-Worker {
  param([string]$StreamId,[string]$Body,[string]$Worktree,[string]$BranchName,[switch]$HostManagedCommit,[object]$WorkerSpec)
  $script:capturedHMC = [bool]$HostManagedCommit
  return [pscustomobject]@{ id=$StreamId; workerId=[string]$WorkerSpec.id; status='running' }
}
function Resolve-ParallelDispatchWorkerSpec { param([object]$Stream,[string[]]$AlreadyUsedIds) [pscustomobject]@{ id='codex-high'; cli='codex'; model='gpt-5.5'; reasoning='high'; strength=4; speed=2; cost=4; domains=@('any') } }
$mockStream = [pscustomobject]@{ id='s1'; body='Files: sa/a.kt'; files=@('sa/a.kt'); complexity='simple' }
$r1 = Start-ParallelDispatchWorker -Stream $mockStream -TaskHash 'thash' -AlreadyUsedIds @()
Assert-True ([bool]$r1.ok) "codex spawn ok"
Assert-True ($script:capturedHMC -eq $true) "codex worker gets -HostManagedCommit"
function Resolve-ParallelDispatchWorkerSpec { param([object]$Stream,[string[]]$AlreadyUsedIds) [pscustomobject]@{ id='claude-sonnet'; cli='claude'; model='sonnet'; reasoning=''; strength=3; speed=3; cost=2; domains=@('any') } }
$script:capturedHMC = $null
$r2 = Start-ParallelDispatchWorker -Stream $mockStream -TaskHash 'thash' -AlreadyUsedIds @()
Assert-True ([bool]$r2.ok) "claude spawn ok"
Assert-True ($script:capturedHMC -eq $false) "claude worker does NOT get -HostManagedCommit"

# ---- 7. shared GRADLE_USER_HOME ----
Write-Host "== 7. shared GRADLE_USER_HOME =="
$origGuh = [Environment]::GetEnvironmentVariable('GRADLE_USER_HOME','Process')
try {
  [Environment]::SetEnvironmentVariable('GRADLE_USER_HOME',$null,'Process')
  $set1 = Set-ParallelSharedGradleUserHome
  $expected = Join-Path $env:USERPROFILE '.bridge-runtime\gradle-user-home'
  Assert-True ($set1 -eq $expected) "unset env -> shared machine-local gradle home"
  Assert-True (Test-Path -LiteralPath $expected) "shared gradle home directory exists/created"
  Assert-True ([string][Environment]::GetEnvironmentVariable('GRADLE_USER_HOME','Process') -eq $expected) "process env carries shared home (inherited by worker processes)"
  [Environment]::SetEnvironmentVariable('GRADLE_USER_HOME','X:\custom\gradle','Process')
  $set2 = Set-ParallelSharedGradleUserHome
  Assert-True ($set2 -eq 'X:\custom\gradle') "operator-set env respected (no override)"
} finally {
  [Environment]::SetEnvironmentVariable('GRADLE_USER_HOME',$origGuh,'Process')
}

Write-Host ""
if ($fail -eq 0) { Write-Host "RESULT: ALL PASS" } else { Write-Host ("RESULT: {0} FAIL" -f $fail); exit 1 }
