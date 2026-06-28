# Regression: the cross-stream conflict guard (zero-conflict enforcement for wide parallel waves).
# Get-ParallelCrossStreamClaimedCollisions returns the subset of a stream's actual changed files that an
# EARLIER stream this wave already delivered. The collect path quarantines a stream with any collision so
# two streams never silently last-write-wins the same bridge-root file (closes the G4/G5/G6 hole).

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
. .\lib\common.ps1
if (-not (Get-Command Get-ParallelCrossStreamClaimedCollisions -ErrorAction SilentlyContinue)) { . .\lib\parallel.ps1 }

$pass = 0; $fail = 0
function Check($name, $cond, $got) {
  if ($cond) { Write-Output ("PASS  " + $name); $script:pass++ } else { Write-Output ("FAIL  " + $name + "  got=[" + (@($got) -join ',') + "]"); $script:fail++ }
}

function Claimed($arr) { $l = New-Object 'System.Collections.Generic.List[string]'; foreach ($x in $arr) { [void]$l.Add((([string]$x).Trim().ToLowerInvariant() -replace '\\','/')) }; return $l }

# 1) A stream changing a file already delivered by another stream -> collision detected.
$c1 = @(Get-ParallelCrossStreamClaimedCollisions -AllowedPaths @('a.kt','b.kt') -ClaimedPaths (Claimed @('b.kt')))
Check "collision on already-delivered b.kt" ($c1.Count -eq 1 -and $c1[0] -eq 'b.kt') $c1

# 2) Truly disjoint -> no collision (the wide-wave happy path).
$c2 = @(Get-ParallelCrossStreamClaimedCollisions -AllowedPaths @('a.kt') -ClaimedPaths (Claimed @('c.kt','d.kt')))
Check "disjoint -> no collision" ($c2.Count -eq 0) $c2

# 3) Normalization: mixed case + backslash still collides with the normalized claim.
$c3 = @(Get-ParallelCrossStreamClaimedCollisions -AllowedPaths @('Util\Shared.KT') -ClaimedPaths (Claimed @('util/shared.kt')))
Check "normalized (case/backslash) collision" ($c3.Count -eq 1) $c3

# 4) No claims yet (first stream of the wave) -> no collision.
$c4 = @(Get-ParallelCrossStreamClaimedCollisions -AllowedPaths @('a.kt','b.kt') -ClaimedPaths (Claimed @()))
Check "empty claims (first stream) -> no collision" ($c4.Count -eq 0) $c4

# 5) Null claims -> no collision (defensive).
$c5 = @(Get-ParallelCrossStreamClaimedCollisions -AllowedPaths @('a.kt') -ClaimedPaths $null)
Check "null claims -> no collision" ($c5.Count -eq 0) $c5

# 6) Multiple collisions reported.
$c6 = @(Get-ParallelCrossStreamClaimedCollisions -AllowedPaths @('a.kt','b.kt','c.kt') -ClaimedPaths (Claimed @('a.kt','c.kt')))
Check "reports all collisions (a.kt,c.kt)" ($c6.Count -eq 2) $c6

Write-Output ("`n=== RESULT pass=" + $pass + " fail=" + $fail + " ===")
if ($fail -gt 0) { exit 1 } else { exit 0 }
