$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$repo = Join-Path $root 'tmp\learning-loop-autorevert-guard-test'
if (Test-Path -LiteralPath $repo) { Remove-Item -LiteralPath $repo -Recurse -Force }
New-Item -ItemType Directory -Path $repo -Force | Out-Null

$script:TestRepo = $repo
$script:BridgeConfig = [pscustomobject]@{
  learningLoop = [pscustomobject]@{
    autoRevert = $false
    autoRevertShadow = $true
    autoRevertMaxHypothesisAgeHours = 30
    autoRevertMaxCommitsBehindHead = 0
    autoRevertRequireUnhealthy = $false
    autoRevertRequireCleanWorktree = $true
  }
}

function Get-BridgeRoot { return $script:TestRepo }
function Get-BridgeConfig { return $script:BridgeConfig }
function Add-Memory { return 'test-memory' }
function Add-Idea { return 'test-idea' }

. (Join-Path $root 'lib\metrics.ps1')

$script:Pass = 0
$script:Fail = 0
function Check {
  param([string]$Name, [bool]$Condition, $Context = $null)
  if ($Condition) {
    $script:Pass++
    Write-Host "PASS: $Name"
  } else {
    $script:Fail++
    Write-Host "FAIL: $Name"
    if ($null -ne $Context) { $Context | ConvertTo-Json -Depth 8 | Write-Host }
  }
}

function Invoke-TestGit {
  param([string[]]$ArgsList)
  $out = & git.exe -C $script:TestRepo @ArgsList 2>&1
  if ($LASTEXITCODE -ne 0) { throw "git $($ArgsList -join ' ') failed: $out" }
  return $out
}

function Write-TestFile {
  param([string]$Text)
  [System.IO.File]::WriteAllText((Join-Path $script:TestRepo 'file.txt'), $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-TestConfig {
  param(
    [bool]$AutoRevert = $false,
    [bool]$Shadow = $true,
    [double]$MaxAgeHours = 30,
    [int]$MaxBehind = 0,
    [bool]$RequireUnhealthy = $false,
    [bool]$RequireClean = $true
  )
  $script:BridgeConfig = [pscustomobject]@{
    learningLoop = [pscustomobject]@{
      autoRevert = $AutoRevert
      autoRevertShadow = $Shadow
      autoRevertMaxHypothesisAgeHours = $MaxAgeHours
      autoRevertMaxCommitsBehindHead = $MaxBehind
      autoRevertRequireUnhealthy = $RequireUnhealthy
      autoRevertRequireCleanWorktree = $RequireClean
    }
  }
}

Invoke-TestGit @('init', '-q') | Out-Null
Invoke-TestGit @('config', 'user.email', 'bridge-test@example.invalid') | Out-Null
Invoke-TestGit @('config', 'user.name', 'Bridge Test') | Out-Null

Write-TestFile 'one'
Invoke-TestGit @('add', 'file.txt') | Out-Null
Invoke-TestGit @('commit', '-q', '-m', 'initial') | Out-Null
$commitA = (Invoke-TestGit @('rev-parse', 'HEAD')).Trim()

Write-TestFile 'two'
Invoke-TestGit @('add', 'file.txt') | Out-Null
Invoke-TestGit @('commit', '-q', '-m', 'change two') | Out-Null
$commitB = (Invoke-TestGit @('rev-parse', 'HEAD')).Trim()
$recentTs = [DateTime]::UtcNow.ToString('o')

Set-TestConfig -AutoRevert:$false -RequireUnhealthy:$false -MaxBehind 0
$cfg = Get-LearningLoopConfig
$allowed = Test-LearningLoopAutoRevertGuard -Root $repo -Commit $commitB -HypothesisTs $recentTs -Config $cfg
Check 'fresh HEAD commit passes guard when health requirement is disabled' ([bool]$allowed.allowed -and [string]$allowed.reason -eq 'guard_passed') $allowed

$staleTs = ([DateTime]::UtcNow.AddHours(-40)).ToString('o')
$stale = Test-LearningLoopAutoRevertGuard -Root $repo -Commit $commitB -HypothesisTs $staleTs -Config $cfg
Check 'stale hypothesis is blocked' ((-not [bool]$stale.allowed) -and [string]$stale.reason -eq 'stale_hypothesis') $stale

$behind = Test-LearningLoopAutoRevertGuard -Root $repo -Commit $commitA -HypothesisTs $recentTs -Config $cfg
Check 'commit behind HEAD is blocked by max-behind guard' ((-not [bool]$behind.allowed) -and [string]$behind.reason -eq 'commit_too_far_behind_head') $behind

Write-TestFile 'dirty'
$dirty = Test-LearningLoopAutoRevertGuard -Root $repo -Commit $commitB -HypothesisTs $recentTs -Config $cfg
Check 'tracked dirty worktree blocks auto-revert' ((-not [bool]$dirty.allowed) -and [string]$dirty.reason -eq 'dirty_worktree') $dirty
Write-TestFile 'two'

Set-TestConfig -AutoRevert:$false -RequireUnhealthy:$true -MaxBehind 0
$cfgHealth = Get-LearningLoopConfig
$healthOk = Test-LearningLoopAutoRevertGuard -Root $repo -Commit $commitB -HypothesisTs $recentTs -Config $cfgHealth -HealthRed:$false
Check 'healthy bridge blocks auto-revert when red-health is required' ((-not [bool]$healthOk.allowed) -and [string]$healthOk.reason -eq 'health_not_red') $healthOk

Invoke-TestGit @('checkout', '-q', '-b', 'side', $commitA) | Out-Null
Write-TestFile 'side'
Invoke-TestGit @('add', 'file.txt') | Out-Null
Invoke-TestGit @('commit', '-q', '-m', 'side change') | Out-Null
$sideCommit = (Invoke-TestGit @('rev-parse', 'HEAD')).Trim()
Invoke-TestGit @('checkout', '-q', 'master') | Out-Null
Set-TestConfig -AutoRevert:$false -RequireUnhealthy:$false -MaxBehind 10
$cfgLineage = Get-LearningLoopConfig
$notLineage = Test-LearningLoopAutoRevertGuard -Root $repo -Commit $sideCommit -HypothesisTs $recentTs -Config $cfgLineage
Check 'commit outside HEAD lineage is blocked' ((-not [bool]$notLineage.allowed) -and [string]$notLineage.reason -eq 'commit_not_in_head_lineage') $notLineage

Set-TestConfig -AutoRevert:$false -Shadow:$true -RequireUnhealthy:$false -MaxBehind 0
$headBeforeShadow = (Invoke-TestGit @('rev-parse', 'HEAD')).Trim()
$shadow = Invoke-VerdictActuation -Verdict 'worse' -Commit $commitB -Task 'shadow test' -HypothesisTs $recentTs -AfterTurns 12
$headAfterShadow = (Invoke-TestGit @('rev-parse', 'HEAD')).Trim()
Check 'autoRevert=false records shadow without changing HEAD' ([string]$shadow.action -eq 'revert_shadow' -and $headBeforeShadow -eq $headAfterShadow) $shadow

Set-TestConfig -AutoRevert:$true -RequireUnhealthy:$true -MaxBehind 0
$blocked = Invoke-VerdictActuation -Verdict 'worse' -Commit $commitB -Task 'guard blocked test' -HypothesisTs $recentTs -AfterTurns 12
Check 'autoRevert=true still blocks when guard fails' ([string]$blocked.action -eq 'revert_guard_blocked') $blocked

Set-TestConfig -AutoRevert:$true -RequireUnhealthy:$false -MaxBehind 0
$reverted = Invoke-VerdictActuation -Verdict 'worse' -Commit $commitB -Task 'guarded revert test' -HypothesisTs $recentTs -AfterTurns 12
$headAfterRevert = (Invoke-TestGit @('rev-parse', 'HEAD')).Trim()
Check 'guarded auto-revert can revert only when all guard checks pass' ([string]$reverted.action -eq 'reverted' -and $headAfterRevert -ne $commitB) $reverted

Set-TestConfig -AutoRevert:$true -RequireUnhealthy:$false -MaxBehind 10
$already = Test-LearningLoopAutoRevertGuard -Root $repo -Commit $commitB -HypothesisTs $recentTs -Config (Get-LearningLoopConfig)
Check 'already reverted commit is blocked' ((-not [bool]$already.allowed) -and [string]$already.reason -eq 'already_reverted') $already

$records = @()
$metricsPath = Join-Path $repo 'metrics.jsonl'
if (Test-Path -LiteralPath $metricsPath) {
  $records = @(Get-Content -LiteralPath $metricsPath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}
Check 'metrics records include revert_shadow' (@($records | Where-Object { [string]$_.action -eq 'revert_shadow' }).Count -ge 1) $records
Check 'metrics records include revert_guard_blocked' (@($records | Where-Object { [string]$_.action -eq 'revert_guard_blocked' }).Count -ge 1) $records
Check 'metrics records include reverted only after guarded pass' (@($records | Where-Object { [string]$_.action -eq 'reverted' }).Count -eq 1) $records

Write-Host "Learning-loop auto-revert guard tests: $script:Pass PASS, $script:Fail FAIL"
if ($script:Fail -gt 0) { exit 1 }
