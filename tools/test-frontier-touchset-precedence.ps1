# Regression: the frontier's touch-set (Get-BacklogWorkpackItemEditTouches) must prefer the NARROWED
# declared touch-set (workpack_touch_set/touch_set, path-like) over the over-listed 'files' array, so
# independent atoms (whose 'files' lists read-for-context files) don't falsely collide and serialize.
# Speed lever #4 (2026-06-28). The control-plane gate is unaffected (policy.ps1:80 reads $Item.files direct).

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
. .\lib\common.ps1
if (-not (Get-Command Get-BacklogWorkpackItemEditTouches -ErrorAction SilentlyContinue)) { . .\lib\backlog-workpack.ps1 }

$pass = 0; $fail = 0
function Check($name, $cond, $got) {
  if ($cond) { Write-Output ("PASS  " + $name) ; $script:pass++ }
  else { Write-Output ("FAIL  " + $name + "  got=[" + ($got -join ',') + "]"); $script:fail++ }
}

# 1) Narrowed workpack_touch_set wins over over-listed files.
$i1 = [pscustomobject]@{ files=@('a.kt','b.kt','c.kt'); workpack_touch_set=@('a.kt') }
$t1 = @(Get-BacklogWorkpackItemEditTouches -Item $i1)
Check "narrowed workpack_touch_set wins over files (-> a.kt only)" ($t1.Count -eq 1 -and $t1[0] -eq 'a.kt') $t1

# 2) No touch_set -> fall back to files.
$i2 = [pscustomobject]@{ files=@('a.kt') }
$t2 = @(Get-BacklogWorkpackItemEditTouches -Item $i2)
Check "no touch_set -> uses files" ($t2.Count -eq 1 -and $t2[0] -eq 'a.kt') $t2

# 3) Coarse conflict-group word in workpack_touch_set is NOT a touch -> falls through to files.
$i3 = [pscustomobject]@{ files=@('a.kt'); workpack_touch_set=@('general') }
$t3 = @(Get-BacklogWorkpackItemEditTouches -Item $i3)
Check "coarse 'general' skipped -> uses files a.kt" ($t3.Count -eq 1 -and $t3[0] -eq 'a.kt') $t3

# 4) edit_touches is highest precedence.
$i4 = [pscustomobject]@{ edit_touches=@('x.kt'); files=@('a.kt'); workpack_touch_set=@('b.kt') }
$t4 = @(Get-BacklogWorkpackItemEditTouches -Item $i4)
Check "edit_touches highest (-> x.kt)" ($t4.Count -eq 1 -and $t4[0] -eq 'x.kt') $t4

# 5) Two atoms that share a file in 'files' but own DIFFERENT files no longer overlap (the whole point).
$a = [pscustomobject]@{ files=@('shared.kt','own_a.kt'); workpack_touch_set=@('own_a.kt') }
$b = [pscustomobject]@{ files=@('shared.kt','own_b.kt'); workpack_touch_set=@('own_b.kt') }
$ta = @(Get-BacklogWorkpackItemEditTouches -Item $a)
$tb = @(Get-BacklogWorkpackItemEditTouches -Item $b)
$overlap = @($ta | Where-Object { $tb -contains $_ })
Check "two atoms sharing only a read-context file no longer overlap" ($overlap.Count -eq 0) $overlap

Write-Output ("`n=== RESULT pass=" + $pass + " fail=" + $fail + " ===")
if ($fail -gt 0) { exit 1 } else { exit 0 }
