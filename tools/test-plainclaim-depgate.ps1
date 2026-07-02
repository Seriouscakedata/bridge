# test-plainclaim-depgate.ps1 -- plain single-claim dependency gate (2026-07-02 audit).
# The serial-fallback direct claim (driver -> Get-NextApprovedIdea) used to ignore depends_on:
# the final APK acceptance atom was claimed and 'verified' BEFORE its integration dependency
# existed. Get-NextApprovedIdea must now SKIP candidates whose deps are not ready and take the
# NEXT ready candidate; with no ready candidates it returns $null; items without dependency data
# are unaffected; if the workpack dep helpers are unavailable it fails OPEN to the old behavior.
# Mock-based (mirrors tools\test-dangling-dep-guard.ps1 / test-queue-governor-claim-hooks.ps1):
# backlog + control dir redirected to a temp folder, safe with the bridge stopped.

$ErrorActionPreference = 'Stop'
$bridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $bridgeRoot 'lib\backlog.ps1')

$script:pass = 0
$script:fail = 0
$script:tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-depgate-' + [guid]::NewGuid().ToString('N'))
$script:testBacklogPath = Join-Path $script:tmpRoot 'backlog.jsonl'
$script:testControlDir = Join-Path $script:tmpRoot 'control'

function Get-ChannelBacklogPath { return $script:testBacklogPath }
function Get-BacklogControlDir { return $script:testControlDir }
function Test-ProjectScopedApprovedBacklogAllowed { return $true }

function ok($c, $m) {
  if ($c) { $script:pass++; Write-Host "  ok: $m" }
  else { $script:fail++; Write-Host "  FAIL: $m" -ForegroundColor Red }
}

function Reset-TestBacklog {
  if (Test-Path -LiteralPath $script:tmpRoot) { Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force }
  New-Item -ItemType Directory -Path $script:testControlDir -Force | Out-Null
}

function New-DepGateItem {
  param(
    [string]$Id,
    [string]$Slug,
    [string]$Status = 'approved',
    [string[]]$DependsOn = $null,
    [double]$Score = 1.0,
    [string[]]$TouchSet = $null
  )
  if ($null -eq $TouchSet) { $TouchSet = @('app/' + $Id + '.kt') }
  $item = [pscustomobject][ordered]@{
    id = $Id
    ts = '2026-07-02T00:00:00Z'
    from = 'test'
    status = $Status
    tags = @()
    attempts = 0
    score = $Score
    project = ''
    scope = 'bridge'
    slug = $Slug
    title = 'dep-gate case ' + $Id
    text = 'Implement dep-gate test case ' + $Id
    touch_set = @($TouchSet)
    root_cause_key = 'depgate:test:' + $Id
  }
  if ($null -ne $DependsOn) {
    $item | Add-Member -NotePropertyName depends_on -NotePropertyValue @($DependsOn) -Force
  }
  return $item
}

try {
  # (a) approved item with depends_on on a non-done sibling is SKIPPED; the next dep-free item wins.
  Reset-TestBacklog
  Save-Backlog @(
    (New-DepGateItem -Id 'dep-sibling' -Slug 'dep-sibling' -Status 'running'),
    (New-DepGateItem -Id 'blocked-item' -Slug 'blocked-item' -DependsOn @('dep-sibling') -Score 5.0),
    (New-DepGateItem -Id 'free-item' -Slug 'free-item' -Score 1.0)
  )
  $pick = Get-NextApprovedIdea
  ok ($null -ne $pick -and [string]$pick.id -eq 'free-item') "(a) dep-blocked candidate skipped, next dep-free item returned (got: $(if($pick){[string]$pick.id}else{'null'}))"
  $blockedStored = @((Get-Backlog) | Where-Object { [string]$_.id -eq 'blocked-item' })[0]
  ok ([string]$blockedStored.status -eq 'approved') '(a) skipped candidate stays approved in the queue (not dropped/held)'
  $logPath = Join-Path $script:testControlDir 'curator-decisions.jsonl'
  $logText = ''
  try { $logText = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8 } catch {}
  ok ($logText -like '*single-claim-dep-gate-skip*blocked-item*') '(a) dep-gate skip is logged (single-claim-dep-gate-skip)'

  # (a2) ONLY dep-blocked candidates -> $null (normal nothing-claimable-now, no crash)
  Reset-TestBacklog
  Save-Backlog @(
    (New-DepGateItem -Id 'dep-sibling' -Slug 'dep-sibling' -Status 'running'),
    (New-DepGateItem -Id 'blocked-item' -Slug 'blocked-item' -DependsOn @('dep-sibling') -Score 5.0)
  )
  $pickNone = Get-NextApprovedIdea
  ok ($null -eq $pickNone) '(a2) all candidates dep-blocked -> returns $null (nothing claimable now)'

  # (b) item with all deps done IS returned
  Reset-TestBacklog
  Save-Backlog @(
    (New-DepGateItem -Id 'dep-done' -Slug 'dep-done' -Status 'done'),
    (New-DepGateItem -Id 'ready-item' -Slug 'ready-item' -DependsOn @('dep-done') -Score 5.0)
  )
  $pickReady = Get-NextApprovedIdea
  ok ($null -ne $pickReady -and [string]$pickReady.id -eq 'ready-item') "(b) all deps done -> item returned (got: $(if($pickReady){[string]$pickReady.id}else{'null'}))"

  # (c) item with no dependency fields is unaffected (plain non-project idea)
  Reset-TestBacklog
  Save-Backlog @((New-DepGateItem -Id 'plain-item' -Slug 'plain-item'))
  $pickPlain = Get-NextApprovedIdea
  ok ($null -ne $pickPlain -and [string]$pickPlain.id -eq 'plain-item') "(c) item without dependency data returned unchanged (got: $(if($pickPlain){[string]$pickPlain.id}else{'null'}))"

  # (d) fail-open: with Test-BacklogTaskDependenciesReady unavailable, old behavior returns the
  # dep-blocked item (gate silently disengages instead of breaking the claim path). Run LAST --
  # it removes the function for the rest of the process.
  Reset-TestBacklog
  Save-Backlog @(
    (New-DepGateItem -Id 'dep-sibling' -Slug 'dep-sibling' -Status 'running'),
    (New-DepGateItem -Id 'blocked-item' -Slug 'blocked-item' -DependsOn @('dep-sibling') -Score 5.0)
  )
  Remove-Item function:Test-BacklogTaskDependenciesReady -Force
  $pickOpen = Get-NextApprovedIdea
  ok ($null -ne $pickOpen -and [string]$pickOpen.id -eq 'blocked-item') "(d) helper unavailable -> fail-open to old behavior (got: $(if($pickOpen){[string]$pickOpen.id}else{'null'}))"
} catch {
  Write-Host "FAIL: unhandled exception :: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host $_.ScriptStackTrace
  $script:fail++
} finally {
  try { if (Test-Path -LiteralPath $script:tmpRoot) { Remove-Item -LiteralPath $script:tmpRoot -Recurse -Force } } catch {}
}

Write-Host ''
Write-Host "PASS=$script:pass FAIL=$script:fail"
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
