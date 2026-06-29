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

Write-Host ""
Write-Host ("RESULT: pass=$pass fail=$fail")
if ($fail -gt 0) { exit 1 } else { exit 0 }
