#Requires -Version 5.1
# VERIFY-COVERS: driver/86-loop-completion-cleanup.ps1
# Tests Get-DriverOutcomeLedgerBlockDecision (freeze-audit wave1 atom1): persisted 2-strike
# decision for outcome-ledger blocks. Strike 1 = retry; strike >= 2 (same task) = degrade to
# needs-review. Counter resets when the task changes (no cross-task bleed).
$ErrorActionPreference = 'Stop'

# Prefer the live function from driver/86 (post-apply); fall back to the staged tmp copy (pre-apply).
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$liveSource = Join-Path $root 'driver\86-loop-completion-cleanup.ps1'
$stagedSource = Join-Path $PSScriptRoot 'atom1-function.ps1'
if ((Test-Path -LiteralPath $liveSource) -and (Select-String -LiteralPath $liveSource -Pattern 'function Get-DriverOutcomeLedgerBlockDecision' -Quiet)) {
  . $liveSource
  Write-Host "SOURCE: live driver/86-loop-completion-cleanup.ps1"
} elseif (Test-Path -LiteralPath $stagedSource) {
  . $stagedSource
  Write-Host "SOURCE: staged atom1-function.ps1"
} else {
  Write-Host 'FAIL: no source for Get-DriverOutcomeLedgerBlockDecision'
  exit 1
}

$fails = 0
function Assert {
  param([string]$Name, [bool]$Cond)
  if ($Cond) { Write-Host "  PASS: $Name" }
  else { Write-Host "  FAIL: $Name"; $script:fails++ }
}

Write-Host "[OL1] first block on a task -> strike 1, no degrade"
$st = [pscustomobject]@{}
$d = Get-DriverOutcomeLedgerBlockDecision -State $st -TaskId 'task-A'
Assert 'OL1 strike=1' ($d.strike -eq 1)
Assert 'OL1 degrade=false' (-not $d.degrade)
Assert 'OL1 task stamped' ($d.task_id -eq 'task-A')

Write-Host "[OL2] second block same task -> strike 2, degrade"
$st = [pscustomobject]@{ outcome_ledger_block_count = 1; outcome_ledger_block_task = 'task-A' }
$d = Get-DriverOutcomeLedgerBlockDecision -State $st -TaskId 'task-A'
Assert 'OL2 strike=2' ($d.strike -eq 2)
Assert 'OL2 degrade=true' ([bool]$d.degrade)

Write-Host "[OL3] block on a DIFFERENT task -> counter resets, no cross-task bleed"
$st = [pscustomobject]@{ outcome_ledger_block_count = 5; outcome_ledger_block_task = 'task-A' }
$d = Get-DriverOutcomeLedgerBlockDecision -State $st -TaskId 'task-B'
Assert 'OL3 strike=1' ($d.strike -eq 1)
Assert 'OL3 degrade=false' (-not $d.degrade)

Write-Host "[OL4] null state -> strike 1, no degrade (fail-open first time)"
$d = Get-DriverOutcomeLedgerBlockDecision -State $null -TaskId 'task-C'
Assert 'OL4 strike=1' ($d.strike -eq 1)
Assert 'OL4 degrade=false' (-not $d.degrade)

Write-Host "[OL5] legacy state (count set, task field missing) -> treated as different task, reset"
$st = [pscustomobject]@{ outcome_ledger_block_count = 3 }
$d = Get-DriverOutcomeLedgerBlockDecision -State $st -TaskId 'task-D'
Assert 'OL5 strike=1' ($d.strike -eq 1)

Write-Host "[OL6] threshold respected (persisted count survives restart simulation)"
# Simulates: strike written to state, driver RESTARTS (in-memory lost), state re-read -> still 1.
$st = [pscustomobject]@{ outcome_ledger_block_count = 1; outcome_ledger_block_task = 'task-E' }
$d = Get-DriverOutcomeLedgerBlockDecision -State $st -TaskId 'task-E'
Assert 'OL6 degrade fires after restart' ([bool]$d.degrade)

Write-Host ''
if ($fails -eq 0) { Write-Host 'OUTCOME-LEDGER-DEGRADE: PASS'; exit 0 }
else { Write-Host "OUTCOME-LEDGER-DEGRADE: FAIL ($fails assertion(s))"; exit 1 }
