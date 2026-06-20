# test-phase-latency-baseline.ps1 -- acceptance test for ATOM_013
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\metrics.ps1')

$pass = 0
$fail = 0

function Assert-Eq($label, $actual, $expected) {
  if ([string]$actual -eq [string]$expected) {
    Write-Host "PASS: $label (=$actual)"
    $script:pass++
  } else {
    Write-Host "FAIL: $label (expected=$expected, got=$actual)"
    $script:fail++
  }
}

# Synthetic records with known phase_timings values
$recs = @(
  [pscustomobject]@{ type='task-latency'; phase_timings=@{ planner_ms=100; verify_ms=50  } },
  [pscustomobject]@{ type='task-latency'; phase_timings=@{ planner_ms=200; verify_ms=100 } },
  [pscustomobject]@{ type='task-latency'; phase_timings=@{ planner_ms=300; verify_ms=150 } },
  [pscustomobject]@{ type='task-latency'; phase_timings=@{ planner_ms=400; verify_ms=200 } },
  [pscustomobject]@{ type='task-latency'; phase_timings=@{ planner_ms=500; verify_ms=250 } }
)
# planner_ms sorted: 100,200,300,400,500  => median(p50)=300, p90=500, max=500, count=5
# verify_ms  sorted: 50,100,150,200,250   => median(p50)=150, p90=250, max=250, count=5

$baseline = Get-PhaseLatencyBaseline -Records $recs

$planner = $baseline | Where-Object { $_.phase -eq 'planner_ms' }
$verify  = $baseline | Where-Object { $_.phase -eq 'verify_ms' }

Assert-Eq 'planner count'     $planner.count      5
Assert-Eq 'planner median_ms' $planner.median_ms  300
Assert-Eq 'planner p90_ms'    $planner.p90_ms     500
Assert-Eq 'planner max_ms'    $planner.max_ms     500

Assert-Eq 'verify count'     $verify.count      5
Assert-Eq 'verify median_ms' $verify.median_ms  150
Assert-Eq 'verify p90_ms'    $verify.p90_ms     250
Assert-Eq 'verify max_ms'    $verify.max_ms     250

# Edge case: empty records => empty result
$empty = Get-PhaseLatencyBaseline -Records @()
Assert-Eq 'empty result count' $empty.Count 0

# Edge case: record with zero ms => skipped
$zeroRec = @(
  [pscustomobject]@{ type='task-latency'; phase_timings=@{ planner_ms=0; verify_ms=999 } }
)
$zeroBase = Get-PhaseLatencyBaseline -Records $zeroRec
$zeroPlanner = $zeroBase | Where-Object { $_.phase -eq 'planner_ms' }
$zeroVerify  = $zeroBase | Where-Object { $_.phase -eq 'verify_ms' }
Assert-Eq 'zero-ms planner absent'  ($null -eq $zeroPlanner) $true
Assert-Eq 'zero-ms verify present'  $zeroVerify.count        1
Assert-Eq 'zero-ms verify max_ms'   $zeroVerify.max_ms       999

Write-Host ''
Write-Host "$pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
exit 0
