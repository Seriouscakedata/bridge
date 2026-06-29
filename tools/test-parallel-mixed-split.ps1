# test-parallel-mixed-split.ps1 -- unit tests for Get-ParallelDispatchBatchMixedSplitPlan
# Pure planner: on a MIXED parallel result, split into merged-done / requeue / hold (attempt-capped).
# Does NOT spawn workers or touch state; purely exercises the split logic.
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\parallel.ps1')

if (-not (Get-Command Get-ParallelDispatchBatchMixedSplitPlan -ErrorAction SilentlyContinue)) {
  Write-Host "FAIL: production helper Get-ParallelDispatchBatchMixedSplitPlan is not visible after dot-source"
  exit 1
}

$pass = 0
$fail = 0
function Assert {
  param([bool]$C, [string]$M)
  if ($C) { $script:pass++; Write-Host "PASS: $M" } else { $script:fail++; Write-Host "FAIL: $M" }
}
function SortJoin { param($a) return (@($a) | Sort-Object) -join ',' }

$map = @{ s1='a1'; s2='a2'; s3='a3'; s4='a4' }

# 1. Basic split: two merged, one quarantined, no prior attempts.
$r1 = Get-ParallelDispatchBatchMixedSplitPlan -Result ([pscustomobject]@{ merged_ids=@('s1','s2'); quarantined_ids=@('s3') }) -StreamToBacklogId $map -AtomAttempts @{} -MaxAttempts 3
Assert ((SortJoin $r1.merged_done_ids) -eq 'a1,a2') "basic: merged_done = a1,a2"
Assert ((SortJoin $r1.requeue_ids) -eq 'a3') "basic: requeue = a3 (under cap)"
Assert (@($r1.hold_ids).Count -eq 0) "basic: hold empty"

# 2. Cap reached: a3 already had 2 attempts, this round is attempt 3 -> hold (cap 3).
$r2 = Get-ParallelDispatchBatchMixedSplitPlan -Result ([pscustomobject]@{ merged_ids=@('s1','s2'); quarantined_ids=@('s3') }) -StreamToBacklogId $map -AtomAttempts @{ a3=2 } -MaxAttempts 3
Assert ((SortJoin $r2.merged_done_ids) -eq 'a1,a2') "cap: merged still done"
Assert (@($r2.requeue_ids).Count -eq 0) "cap: requeue empty at cap"
Assert ((SortJoin $r2.hold_ids) -eq 'a3') "cap: a3 held at attempt 3"

# 3. Cap mid: a3 had 1 attempt, this round is attempt 2 -> still requeue.
$r3 = Get-ParallelDispatchBatchMixedSplitPlan -Result ([pscustomobject]@{ merged_ids=@('s1'); quarantined_ids=@('s3') }) -StreamToBacklogId $map -AtomAttempts @{ a3=1 } -MaxAttempts 3
Assert ((SortJoin $r3.requeue_ids) -eq 'a3') "mid-cap: a3 requeued on attempt 2"
Assert (@($r3.hold_ids).Count -eq 0) "mid-cap: hold empty"

# 4. merged WINS over quarantined when the same backlog id appears in both.
$r4 = Get-ParallelDispatchBatchMixedSplitPlan -Result ([pscustomobject]@{ merged_ids=@('s3'); quarantined_ids=@('s3') }) -StreamToBacklogId $map -AtomAttempts @{ a3=5 } -MaxAttempts 3
Assert ((SortJoin $r4.merged_done_ids) -eq 'a3') "merged-wins: a3 done"
Assert (@($r4.requeue_ids).Count -eq 0 -and @($r4.hold_ids).Count -eq 0) "merged-wins: a3 not requeued/held despite over-cap"

# 5. dedup: two merged streams map to the same backlog id -> one done entry.
$dmap = @{ s1='a1'; s2='a1' }
$r5 = Get-ParallelDispatchBatchMixedSplitPlan -Result ([pscustomobject]@{ merged_ids=@('s1','s2'); quarantined_ids=@() }) -StreamToBacklogId $dmap -MaxAttempts 3
Assert ((SortJoin $r5.merged_done_ids) -eq 'a1') "dedup: a1 appears once"

# 6. unknown stream id (not in map) in quarantine -> skipped, no crash.
$r6 = Get-ParallelDispatchBatchMixedSplitPlan -Result ([pscustomobject]@{ merged_ids=@('s1'); quarantined_ids=@('s9') }) -StreamToBacklogId $map -MaxAttempts 3
Assert ((SortJoin $r6.merged_done_ids) -eq 'a1' -and @($r6.requeue_ids).Count -eq 0 -and @($r6.hold_ids).Count -eq 0) "unknown stream skipped"

# 7. blank backlog id mapping -> skipped.
$bmap = @{ s1='a1'; s5='' }
$r7 = Get-ParallelDispatchBatchMixedSplitPlan -Result ([pscustomobject]@{ merged_ids=@('s1'); quarantined_ids=@('s5') }) -StreamToBacklogId $bmap -MaxAttempts 3
Assert ((SortJoin $r7.merged_done_ids) -eq 'a1' -and @($r7.requeue_ids).Count -eq 0) "blank backlog id skipped"

# 8. empty result -> all empty, no crash.
$r8 = Get-ParallelDispatchBatchMixedSplitPlan -Result ([pscustomobject]@{ merged_ids=@(); quarantined_ids=@() }) -StreamToBacklogId $map -MaxAttempts 3
Assert (@($r8.merged_done_ids).Count -eq 0 -and @($r8.requeue_ids).Count -eq 0 -and @($r8.hold_ids).Count -eq 0) "empty result -> all empty"

# 9. MaxAttempts=1: first quarantine round (attempts 0, round 1) -> hold immediately.
$r9 = Get-ParallelDispatchBatchMixedSplitPlan -Result ([pscustomobject]@{ merged_ids=@('s1'); quarantined_ids=@('s3') }) -StreamToBacklogId $map -AtomAttempts @{} -MaxAttempts 1
Assert ((SortJoin $r9.hold_ids) -eq 'a3' -and @($r9.requeue_ids).Count -eq 0) "MaxAttempts=1: hold on first round"

# 10. null/missing AtomAttempts defaults safely (no prior attempts).
$r10 = Get-ParallelDispatchBatchMixedSplitPlan -Result ([pscustomobject]@{ merged_ids=@('s2'); quarantined_ids=@('s3') }) -StreamToBacklogId $map
Assert ((SortJoin $r10.requeue_ids) -eq 'a3') "default AtomAttempts -> requeue"

# 11. multiple quarantined, mixed cap states.
$r11 = Get-ParallelDispatchBatchMixedSplitPlan -Result ([pscustomobject]@{ merged_ids=@('s1'); quarantined_ids=@('s2','s3','s4') }) -StreamToBacklogId $map -AtomAttempts @{ a2=2; a3=0 } -MaxAttempts 3
Assert ((SortJoin $r11.merged_done_ids) -eq 'a1') "multi: a1 done"
Assert ((SortJoin $r11.requeue_ids) -eq 'a3,a4') "multi: a3,a4 requeued"
Assert ((SortJoin $r11.hold_ids) -eq 'a2') "multi: a2 held at cap"

# ---- requeue persistence helpers (mocked backlog RMW) ----
$script:MockBacklog = @(
  [pscustomobject]@{ id='a1'; status='running' },
  [pscustomobject]@{ id='a3'; status='running'; requeue_attempts=1; held_reason='x' }
)
function Get-Backlog { return $script:MockBacklog }
function Save-Backlog { param($items) $script:MockBacklog = @($items) }
function Invoke-BacklogLocked { param($sb) return (& $sb) }

# 12. requeue a fresh atom -> approved + requeue_attempts=1
$ok1 = Set-ParallelDispatchBacklogRequeue -Id 'a1'
$ra1 = @($script:MockBacklog | Where-Object { $_.id -eq 'a1' })[0]
Assert ($ok1 -and ($ra1.status -eq 'approved') -and ([int]$ra1.requeue_attempts -eq 1)) "requeue: a1 -> approved, attempts=1"

# 13. requeue an atom that already had attempts=1 -> attempts=2, held_reason cleared
$ok2 = Set-ParallelDispatchBacklogRequeue -Id 'a3'
$ra3 = @($script:MockBacklog | Where-Object { $_.id -eq 'a3' })[0]
Assert ($ok2 -and ($ra3.status -eq 'approved') -and ([int]$ra3.requeue_attempts -eq 2) -and ([string]$ra3.held_reason -eq '')) "requeue: a3 attempts 1->2, held_reason cleared"

# 14. read attempts back
$attMap = Get-ParallelDispatchBacklogRequeueAttempts -Ids @('a1','a3','a9')
Assert (([int]$attMap['a1'] -eq 1) -and ([int]$attMap['a3'] -eq 2) -and (-not $attMap.ContainsKey('a9'))) "read requeue_attempts: a1=1 a3=2 a9 absent"

# 15. requeue unknown id -> false, no mutation
$okU = Set-ParallelDispatchBacklogRequeue -Id 'zzz'
Assert (-not $okU) "requeue unknown id -> false"

# 16. blank id -> false
Assert (-not (Set-ParallelDispatchBacklogRequeue -Id '   ')) "requeue blank id -> false"

# 17. end-to-end: split says requeue a3 (attempts seeded from backlog) -> under cap 3 (attempt 3 -> hold)
$attSeed = Get-ParallelDispatchBacklogRequeueAttempts -Ids @('a3')   # a3 now has 2
$splitE = Get-ParallelDispatchBatchMixedSplitPlan -Result ([pscustomobject]@{ merged_ids=@('s1'); quarantined_ids=@('s3') }) -StreamToBacklogId @{ s1='a1'; s3='a3' } -AtomAttempts $attSeed -MaxAttempts 3
Assert ((SortJoin $splitE.hold_ids) -eq 'a3' -and @($splitE.requeue_ids).Count -eq 0) "e2e: a3 at attempts=2 -> held on this (3rd) round"

Write-Host ""
Write-Host ("RESULT: pass=$pass fail=$fail")
if ($fail -gt 0) { exit 1 } else { exit 0 }
