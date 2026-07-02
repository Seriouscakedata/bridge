param()
# 2026-06-30 verifies the "cross-chapter wide" diffusion step:
#  - Test-ProjectAutopilotWideGate: light gate (acyclic + disjoint files + >=K independent), NO contracts.
#  - Get-ProjectAutopilotEarliestChapterTaskSet: safe collapse to the earliest chapter.
#  - New-ProjectAutopilotCoordinatorTaskText -DiffusionMode wide: emits "decompose ALL remaining chapters".
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function A { param([bool]$c,[string]$m) if($c){$script:pass++}else{$script:fail++;Write-Host "FAIL: $m"} }

$root = Split-Path -Parent $PSScriptRoot
$script:TestBridgeRoot = Join-Path ([IO.Path]::GetTempPath()) ('bridge-wide-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $script:TestBridgeRoot 'channels\main') -Force | Out-Null
function Get-BridgeRoot { return $script:TestBridgeRoot }
. (Join-Path $root 'lib\backlog.ps1')
# empty backlog so the coordinator's "done chapters" = 0 -> next chapter = 1
function Get-Backlog { return @() }

function New-Atom { param($slug,$chapter,$files,$deps=@()) [pscustomobject]@{ slug=$slug; title=$slug; task=("do " + $slug + " " + ('x'*40)); chapter=$chapter; files=@($files); depends_on=@($deps) } }

# ---- Test-ProjectAutopilotWideGate ----
$ch1='Chapter 1 - Skeleton'; $ch2='Chapter 2 - Screens'
# GREEN: 2 chapters, disjoint files, acyclic cross-chapter dep (b1 depends on a1), >=2 independent
$green = @(
  (New-Atom 'a1' $ch1 'app/A1.kt'),
  (New-Atom 'a2' $ch1 'app/A2.kt'),
  (New-Atom 'b1' $ch2 'app/B1.kt' @('a1')),
  (New-Atom 'b2' $ch2 'app/B2.kt')
)
$g = Test-ProjectAutopilotWideGate -Tasks $green -MinIndependentAtoms 2
A ([bool]$g.enabled) ("wide gate GREEN for valid cross-chapter set (reasons=" + (@($g.reasons) -join ',') + ")")
A ($g.independent_atom_count -ge 3) ("independent count >=3 (got " + $g.independent_atom_count + ")")

# RED: file conflict (a1,a2 same file)
$conflict = @( (New-Atom 'a1' $ch1 'app/SAME.kt'), (New-Atom 'a2' $ch1 'app/SAME.kt'), (New-Atom 'b2' $ch2 'app/B2.kt') )
$gc = Test-ProjectAutopilotWideGate -Tasks $conflict -MinIndependentAtoms 2
A (-not [bool]$gc.enabled) 'wide gate RED on same-file conflict'
A (@($gc.reasons) -contains 'file-conflict-unresolved') 'reason file-conflict-unresolved'

# RED: cycle (a1->b1->a1)
$cycle = @( (New-Atom 'a1' $ch1 'app/A1.kt' @('b1')), (New-Atom 'b1' $ch2 'app/B1.kt' @('a1')), (New-Atom 'c1' $ch1 'app/C1.kt') )
$gy = Test-ProjectAutopilotWideGate -Tasks $cycle -MinIndependentAtoms 2
A (-not [bool]$gy.enabled) 'wide gate RED on dependency cycle'
A (@($gy.reasons) -contains 'graph-cyclic') 'reason graph-cyclic'

# RED: too few independent (chain)
$chain = @( (New-Atom 'a1' $ch1 'app/A1.kt'), (New-Atom 'a2' $ch1 'app/A2.kt' @('a1')), (New-Atom 'a3' $ch2 'app/A3.kt' @('a2')) )
$gk = Test-ProjectAutopilotWideGate -Tasks $chain -MinIndependentAtoms 2
A (-not [bool]$gk.enabled) 'wide gate RED when independent atoms < K'
A (@($gk.reasons) -contains 'independent-atom-count-below-floor') 'reason independent-atom-count-below-floor'

# ---- Get-ProjectAutopilotEarliestChapterTaskSet ----
$cset = Get-ProjectAutopilotEarliestChapterTaskSet -Tasks $green
A ([bool]$cset.collapsed) 'collapse fires on multi-chapter set'
A ($cset.chapter -eq $ch1) ("collapsed to earliest chapter (got " + $cset.chapter + ")")
A (@($cset.tasks).Count -eq 2) ("kept only Chapter 1 atoms (got " + @($cset.tasks).Count + ")")
$single = @( (New-Atom 'a1' $ch1 'app/A1.kt'), (New-Atom 'a2' $ch1 'app/A2.kt') )
$cset2 = Get-ProjectAutopilotEarliestChapterTaskSet -Tasks $single
A (-not [bool]$cset2.collapsed) 'no collapse on single-chapter set'

# ---- New-ProjectAutopilotCoordinatorTaskText prompt ----
$proj = Join-Path $script:TestBridgeRoot 'proj'
New-Item -ItemType Directory -Path $proj -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $proj 'PROJECT_PLAN.md'), "## Chapter 1 - Skeleton`nx`n## Chapter 2 - Screens`ny`n## Chapter 3 - Wiring`nz`n", (New-Object Text.UTF8Encoding($false)))
$wideTxt = New-ProjectAutopilotCoordinatorTaskText -Slug 'main' -ProjectRoot $proj -DiffusionMode 'wide'
A ($wideTxt -match 'Decompose ALL remaining approved chapters') 'wide prompt: decompose ALL remaining chapters'
A (-not ($wideTxt -match 'Decompose ONLY Chapter')) 'wide prompt: no one-chapter clamp'
A ($wideTxt -match 'diffusion_mode: wide') 'wide prompt: mode reported as wide'
$offTxt = New-ProjectAutopilotCoordinatorTaskText -Slug 'main' -ProjectRoot $proj -DiffusionMode 'off'
A ($offTxt -match 'Decompose ONLY Chapter') 'off prompt: keeps one-chapter default'

Remove-Item -LiteralPath $script:TestBridgeRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "PASS=$script:pass FAIL=$script:fail"
if ($script:fail) { exit 1 } else { Write-Host 'OK' }
