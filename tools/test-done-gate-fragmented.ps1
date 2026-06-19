#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
# Tests for Test-DoneGateIsFragmented (driver/86-loop-completion-checks.ps1).
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'driver\86-loop-completion-checks.ps1')

$script:PassCount = 0
$script:FailCount = 0
function Check {
  param([string]$Name,[bool]$Condition,[object]$Actual=$null)
  if ($Condition) { $script:PassCount++; Write-Host ("PASS: $Name"); return }
  $script:FailCount++
  $sfx = if ($null -ne $Actual) { ' actual=' + ($Actual | ConvertTo-Json -Compress -Depth 4) } else { '' }
  Write-Host ("FAIL: $Name$sfx")
}

Check 'Function Test-DoneGateIsFragmented defined' ([bool](Get-Command Test-DoneGateIsFragmented -ErrorAction SilentlyContinue))

# T1: empty TaskId -> false
Check 'T1 empty TaskId -> false' (-not (Test-DoneGateIsFragmented -TaskId '' -AllItems @()))
# T2: unknown task, empty backlog -> false
Check 'T2 unknown task no backlog -> false' (-not (Test-DoneGateIsFragmented -TaskId 'ghost' -AllItems @()))
# T3: status=decomposed -> true
Check 'T3 status=decomposed -> true' (Test-DoneGateIsFragmented -TaskId 'A' -AllItems @([pscustomobject]@{id='A';status='decomposed'}))
# T4: is_decomposed=true -> true
Check 'T4 is_decomposed=true -> true' (Test-DoneGateIsFragmented -TaskId 'B' -AllItems @([pscustomobject]@{id='B';status='approved';is_decomposed=$true}))
# T5: is_fragmented=true -> true
Check 'T5 is_fragmented=true -> true' (Test-DoneGateIsFragmented -TaskId 'C' -AllItems @([pscustomobject]@{id='C';status='approved';is_fragmented=$true}))
# T6: decomposed_at set -> true
Check 'T6 decomposed_at set -> true' (Test-DoneGateIsFragmented -TaskId 'D' -AllItems @([pscustomobject]@{id='D';status='approved';decomposed_at='2026-06-19T00:00:00Z'}))
# T7: child with parent_id -> true
$parent7=[pscustomobject]@{id='E';status='working'}
$child7=[pscustomobject]@{id='E-c1';status='approved';parent_id='E'}
Check 'T7 child with parent_id -> true' (Test-DoneGateIsFragmented -TaskId 'E' -AllItems @($parent7,$child7))
# T8: normal working task, no children -> false
Check 'T8 normal working no children -> false' (-not (Test-DoneGateIsFragmented -TaskId 'F' -AllItems @([pscustomobject]@{id='F';status='working'})))
# T9: is_decomposed=false -> false
Check 'T9 is_decomposed=false -> false' (-not (Test-DoneGateIsFragmented -TaskId 'G' -AllItems @([pscustomobject]@{id='G';status='approved';is_decomposed=$false})))
# T10: child points to other task -> false
$parent10=[pscustomobject]@{id='H';status='working'}
$child10=[pscustomobject]@{id='H-c';status='approved';parent_id='other-task'}
Check 'T10 child parent_id points elsewhere -> false' (-not (Test-DoneGateIsFragmented -TaskId 'H' -AllItems @($parent10,$child10)))
# T11: decomposed=true string field -> true
Check 'T11 decomposed=true string -> true' (Test-DoneGateIsFragmented -TaskId 'J' -AllItems @([pscustomobject]@{id='J';status='approved';decomposed='true'}))
# T12: task not in backlog but child exists -> true
$child12=[pscustomobject]@{id='K-c';status='approved';parent_id='K'}
Check 'T12 task not in backlog but has child -> true' (Test-DoneGateIsFragmented -TaskId 'K' -AllItems @($child12))

Write-Host ("Test-DoneGateIsFragmented: {0} PASS, {1} FAIL" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
exit 0
