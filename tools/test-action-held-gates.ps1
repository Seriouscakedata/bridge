#Requires -Version 5.1
# test-action-held-gates.ps1 -- action evidence and held backlog claim guards.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\auto-commit-worthiness.ps1')
. (Join-Path $root 'lib\task-action-evidence.ps1')
. (Join-Path $root 'lib\backlog.ps1')

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

$telemetry = Test-TaskActionEvidencePathWorth -Path 'channels/main/task-management-shadow.jsonl' -RepoRoot $root -BridgeRoot $root
$real = Test-TaskActionEvidencePathWorth -Path 'driver/83-loop-agent-turn.ps1' -RepoRoot $root -BridgeRoot $root
Check 'bridge telemetry path is not action evidence' (-not $telemetry)
Check 'bridge code path is action evidence' ($real)

$held = [pscustomobject]@{ id='held-1'; status='held'; text='operator held task' }
$approved = [pscustomobject]@{ id='ok-1'; status='approved'; text='regular task'; tags=@(); scope='bridge' }
$heldClaim = Test-BacklogApprovedItemClaimable -Item $held
$approvedClaim = Test-BacklogApprovedItemClaimable -Item $approved
Check 'held item is detected directly' (Test-BacklogItemHeld -Item $held) $held
Check 'held item is not claimable with held reason' ((-not [bool]$heldClaim.claimable) -and [string]$heldClaim.reason -eq 'held') $heldClaim
Check 'approved regular item remains claimable' ([bool]$approvedClaim.claimable) $approvedClaim

$tmpRoot = Join-Path $root ('tmp\action-evidence-' + [guid]::NewGuid().ToString('N'))
function Invoke-Git {
  param([string]$Repo, [string[]]$GitArgs)
  & git -C $Repo @GitArgs 2>$null
}
function New-TestRepo {
  param([string]$Name)
  $repo = Join-Path $tmpRoot $Name
  New-Item -ItemType Directory -Path $repo -Force | Out-Null
  & git -C $repo init -q *> $null
  & git -C $repo config user.email test@example.invalid *> $null
  & git -C $repo config user.name 'Bridge Test' *> $null
  & git -C $repo config core.autocrlf false *> $null
  [System.IO.File]::WriteAllText((Join-Path $repo 'README.md'), "init`n", [System.Text.UTF8Encoding]::new($false))
  & git -C $repo add README.md *> $null
  & git -C $repo commit -q -m init *> $null
  return $repo
}

try {
  $repoDirty = New-TestRepo -Name 'dirty'
  $baseDirtyCommit = ((Invoke-Git -Repo $repoDirty -GitArgs @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
  [System.IO.File]::WriteAllText((Join-Path $repoDirty 'old.txt'), "pre-existing`n", [System.Text.UTF8Encoding]::new($false))
  New-Item -ItemType Directory -Path (Join-Path $repoDirty 'channels\main') -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $repoDirty 'channels\main\task-management-shadow.jsonl'), "{}" + "`n", [System.Text.UTF8Encoding]::new($false))
  $baselineDirty = @((Invoke-Git -Repo $repoDirty -GitArgs @('status','--porcelain','-uall')) | ForEach-Object { Normalize-TaskActionEvidencePath -StatusLine ([string]$_) } | Where-Object { $_ })
  $noAction = Get-TaskActionEvidence -RepoRoot $repoDirty -BaseCommit $baseDirtyCommit -BridgeRoot $repoDirty -BaseDirtyPaths $baselineDirty
  Check 'baseline dirty paths are not current action evidence' (-not [bool]$noAction.has_actions) $noAction
  New-Item -ItemType Directory -Path (Join-Path $repoDirty 'driver') -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $repoDirty 'driver\83-loop-agent-turn.ps1'), "changed`n", [System.Text.UTF8Encoding]::new($false))
  $dirtyAction = Get-TaskActionEvidence -RepoRoot $repoDirty -BaseCommit $baseDirtyCommit -BridgeRoot $repoDirty -BaseDirtyPaths $baselineDirty
  Check 'new real dirty path is current action evidence' ([bool]$dirtyAction.has_actions -and (@($dirtyAction.dirty_worthy) -contains 'driver/83-loop-agent-turn.ps1')) $dirtyAction

  $repoTelemetry = New-TestRepo -Name 'telemetry'
  $baseTelemetry = ((Invoke-Git -Repo $repoTelemetry -GitArgs @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
  New-Item -ItemType Directory -Path (Join-Path $repoTelemetry 'channels\main') -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $repoTelemetry 'channels\main\task-management-shadow.jsonl'), "{}" + "`n", [System.Text.UTF8Encoding]::new($false))
  & git -C $repoTelemetry add channels/main/task-management-shadow.jsonl 2>$null
  & git -C $repoTelemetry commit -q -m telemetry 2>$null
  $telemetryCommit = Get-TaskActionEvidence -RepoRoot $repoTelemetry -BaseCommit $baseTelemetry -BridgeRoot $repoTelemetry
  Check 'telemetry-only commit is not action evidence' (-not [bool]$telemetryCommit.has_actions) $telemetryCommit

  $repoCommit = New-TestRepo -Name 'commit'
  $baseCommit = ((Invoke-Git -Repo $repoCommit -GitArgs @('rev-parse','HEAD')) | Select-Object -First 1).Trim()
  [System.IO.File]::WriteAllText((Join-Path $repoCommit 'config.json'), "{}" + "`n", [System.Text.UTF8Encoding]::new($false))
  & git -C $repoCommit add config.json 2>$null
  & git -C $repoCommit commit -q -m config 2>$null
  $realCommit = Get-TaskActionEvidence -RepoRoot $repoCommit -BaseCommit $baseCommit -BridgeRoot $repoCommit
  Check 'real commit is action evidence' ([bool]$realCommit.has_actions -and (@($realCommit.committed_worthy) -contains 'config.json')) $realCommit
} finally {
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
