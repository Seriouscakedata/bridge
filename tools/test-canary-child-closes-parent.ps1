#Requires -Version 5.1
<#
.SYNOPSIS
  Unit test + one-time migration: Close-BacklogCanaryParent.
  Scenarios: unit checks; then migrate 4 held-zombie parents to done.
#>
param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$passed = 0
$failed = 0

function Assert-True([bool]$cond, [string]$label) {
  if ($cond) {
    Write-Host "  PASS: $label"
    $script:passed++
  } else {
    Write-Host "  FAIL: $label"
    $script:failed++
  }
}

function MakeFakeItem([hashtable]$props) {
  $o = [PSCustomObject]@{}
  foreach ($k in $props.Keys) {
    $o | Add-Member -NotePropertyName $k -NotePropertyValue $props[$k] -Force
  }
  return $o
}

. (Join-Path $BridgeRoot 'lib\backlog-core.ps1')

Write-Host "=== Close-BacklogCanaryParent: unit tests ==="

Write-Host "--- Scenario 1: parent(approved) + child(canary_gate_parent_id) -> parent done ---"
$p1 = MakeFakeItem @{ id = 'parent-001'; status = 'approved' }
$c1 = MakeFakeItem @{ id = 'child-001'; status = 'done'; canary_gate_parent_id = 'parent-001'; tags = @('bridge-self-canary-gate') }
$r1 = Close-BacklogCanaryParent -ChildItem $c1 -AllItems @($p1)
Assert-True ([bool]$r1.closed) "closed=true"
Assert-True ([string]$p1.status -eq 'done') "parent.status=done"
Assert-True ([string]$p1.done_reason -eq 'closed-by-canary-child:child-001') "parent.done_reason correct"
Assert-True ([string]$p1.done_by -eq 'canary-child') "parent.done_by=canary-child"
Assert-True ([string]$r1.was_status -eq 'approved') "was_status=approved"

Write-Host "--- Scenario 2: parent(held) -> also closed ---"
$p2 = MakeFakeItem @{ id = 'parent-002'; status = 'held' }
$c2 = MakeFakeItem @{ id = 'child-002'; status = 'done'; canary_gate_parent_id = 'parent-002'; tags = @() }
$r2 = Close-BacklogCanaryParent -ChildItem $c2 -AllItems @($p2)
Assert-True ([bool]$r2.closed) "held parent: closed=true"
Assert-True ([string]$p2.status -eq 'done') "held parent: status=done"
Assert-True ([string]$r2.was_status -eq 'held') "was_status=held"

Write-Host "--- Scenario 3: parent already done -> no-op ---"
$p3 = MakeFakeItem @{ id = 'parent-003'; status = 'done' }
$c3 = MakeFakeItem @{ id = 'child-003'; status = 'done'; canary_gate_parent_id = 'parent-003'; tags = @() }
$r3 = Close-BacklogCanaryParent -ChildItem $c3 -AllItems @($p3)
Assert-True (-not [bool]$r3.closed) "already-done: no-op"

Write-Host "--- Scenario 4: tag-based detection (bridge-self-canary-gate tag + parent_id) ---"
$p4 = MakeFakeItem @{ id = 'parent-004'; status = 'approved' }
$c4 = MakeFakeItem @{ id = 'child-004'; status = 'done'; parent_id = 'parent-004'; tags = @('operator','bridge-self-canary-gate','canary-gate') }
$r4 = Close-BacklogCanaryParent -ChildItem $c4 -AllItems @($p4)
Assert-True ([bool]$r4.closed) "tag-based: closed=true"
Assert-True ([string]$p4.status -eq 'done') "tag-based: parent.status=done"

Write-Host "--- Scenario 5: no canary marker -> no-op ---"
$p5 = MakeFakeItem @{ id = 'parent-005'; status = 'approved' }
$c5 = MakeFakeItem @{ id = 'child-005'; status = 'done'; tags = @('regular-task') }
$r5 = Close-BacklogCanaryParent -ChildItem $c5 -AllItems @($p5)
Assert-True (-not [bool]$r5.closed) "no marker: no-op"

Write-Host "--- Scenario 6: canary_gate_parent_id set but parent not found -> no-op ---"
$c6 = MakeFakeItem @{ id = 'child-006'; status = 'done'; canary_gate_parent_id = 'nonexistent-999'; tags = @() }
$r6 = Close-BacklogCanaryParent -ChildItem $c6 -AllItems @()
Assert-True (-not [bool]$r6.closed) "parent not found: no-op"
Assert-True ([string]$r6.reason -eq 'parent_not_found') "reason=parent_not_found"

Write-Host ""
Write-Host "=== MIGRATION: 4 held-zombie parents ==="
$backlogPath = Join-Path $BridgeRoot 'channels\main\backlog.jsonl'
if (-not (Test-Path -LiteralPath $backlogPath)) {
  Write-Host "  SKIP: backlog not found: $backlogPath"
} else {
  $byId = New-Object 'System.Collections.Specialized.OrderedDictionary'
  foreach ($line in [System.IO.File]::ReadAllLines($backlogPath, [System.Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $it = $line | ConvertFrom-Json
      $iid = [string]$it.id
      if (-not [string]::IsNullOrWhiteSpace($iid)) { $byId[$iid] = $it }
    } catch {
      Write-Host "  WARN: invalid backlog line skipped: $($_.Exception.Message)"
    }
  }
  $allItems = @($byId.Values)

  $childIds = @(
    '25d4a1e20b6046d1b9a2e80a6e3a7afb',
    '47a26f2941684b99baa2538cee3a20af',
    '78fc7b6c0f0b46bfa9af7c4c027bdc5c',
    '6ca243584efb4999897e44a4397c6466'
  )

  $appendLines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($cid in $childIds) {
    if (-not $byId.Contains($cid)) {
      Write-Host "  WARN: child $cid not in backlog"
      continue
    }
    $child = $byId[$cid]
    $result = Close-BacklogCanaryParent -ChildItem $child -AllItems $allItems
    if ($result.closed) {
      $updatedParent = $byId[$result.parent_id]
      [void]$appendLines.Add(($updatedParent | ConvertTo-Json -Depth 6 -Compress))
      Write-Host "  MIGRATED: $($result.parent_id.Substring(0,8)) (was: $($result.was_status)) <- child $($cid.Substring(0,8))"
    } else {
      Write-Host "  SKIP $($cid.Substring(0,8)): $($result.reason)"
    }
  }

  if ($appendLines.Count -gt 0) {
    [System.IO.File]::AppendAllLines($backlogPath, [string[]]@($appendLines), [System.Text.Encoding]::UTF8)
    Write-Host "  Appended $($appendLines.Count) updated parent line(s) to backlog."
  }

  $byId2 = New-Object 'System.Collections.Specialized.OrderedDictionary'
  foreach ($line in [System.IO.File]::ReadAllLines($backlogPath, [System.Text.Encoding]::UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $it = $line | ConvertFrom-Json
      $iid = [string]$it.id
      if (-not [string]::IsNullOrWhiteSpace($iid)) { $byId2[$iid] = $it }
    } catch {
      Write-Host "  WARN: invalid backlog line skipped during verify: $($_.Exception.Message)"
    }
  }
  $zombieIds = @(
    'f531c6fb240d482f92de98c02287f8bf',
    'e9df5d8072b44c06872645542a7a3887',
    'ca6f77925fdf4aee98c8636ce3aee0cb',
    'd962751fc87f4a22b975e33878c19e6e'
  )
  foreach ($zid in $zombieIds) {
    if ($byId2.Contains($zid)) {
      $st = [string]$byId2[$zid].status
      Assert-True ($st -eq 'done') "zombie $($zid.Substring(0,8)) -> done (got: $st)"
    } else {
      Write-Host "  WARN: zombie $zid not found in backlog"
      $script:failed++
    }
  }
}

Write-Host ""
Write-Host "=== RESULT: $passed passed, $failed failed ==="
if ($failed -gt 0) { exit 1 }
