param()

# ==============================================================================
# tools/test-allchapters-decompose.ps1
#   Unit test for the all-chapters decomposition changes in
#   New-ProjectAutopilotCoordinatorTaskText (lib/backlog-autopilot.ps1):
#     * bug#2 Root-1 channel filter -- decomposed-chapter counting must scan only
#       THIS channel's project-autopilot atoms, not the global (all-channel) backlog.
#     * scope line -- diffusion|wide decompose ALL remaining chapters in one turn;
#       off decomposes ONLY the next chapter; diffusion adds the provides/consumes
#       contract clause, wide does not.
# ==============================================================================

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

. (Join-Path $root 'lib\common.ps1') | Out-Null

$fail = 0
function Assert-True { param([bool]$Cond, [string]$Label)
  $res = if ($Cond) { 'PASS' } else { 'FAIL' }
  if (-not $Cond) { $script:fail++ }
  Write-Host ("[{0}] {1}" -f $res, $Label)
}

# temp project with a 3-chapter PROJECT_PLAN.md
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('allchap-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
@"
# Selfie Styler plan

## Chapter 1 - Scaffold and routes
stuff

## Chapter 2 - Filter engine
stuff

## Chapter 3 - Screens and integration
stuff
"@ | Set-Content -LiteralPath (Join-Path $tmp 'PROJECT_PLAN.md') -Encoding UTF8

# Get-Backlog override: cross-channel atoms. 'other' project atoms must NOT count for 'testch'.
$script:BL = @()
function Get-Backlog { return $script:BL }
function Atom { param([string]$Proj,[string]$Chapter) [pscustomobject]@{ from='project-autopilot'; project=$Proj; chapter=$Chapter; status='approved' } }

function Coord { param([string]$Mode) New-ProjectAutopilotCoordinatorTaskText -Slug 'testch' -ProjectRoot $tmp -MaxTasks 12 -DiffusionMode $Mode -DiffusionMinIndependentAtoms 2 -DiffusionMaxWaveSize 12 }

# ---- A: channel filter -- other channel's chapters must NOT inflate testch's count ----
$script:BL = @( (Atom 'other' 'Chapter 1'), (Atom 'other' 'Chapter 2') )  # different project
$pA = Coord 'diffusion'
Assert-True ($pA -match 'NEXT chapter to decompose NOW: Chapter 1\b') "channel filter: other-project atoms ignored -> next=Chapter 1"
Assert-True ($pA -notmatch 'all .* approved plan chapters are already decomposed') "channel filter: NOT falsely 'all decomposed'"

# ---- B: own channel's decomposed chapter IS counted ----
$script:BL = @( (Atom 'testch' 'Chapter 1'), (Atom 'other' 'Chapter 2'), (Atom 'other' 'Chapter 3') )
$pB = Coord 'diffusion'
Assert-True ($pB -match 'NEXT chapter to decompose NOW: Chapter 2\b') "own decomposed ch1 counted, other channels ignored -> next=Chapter 2"

# ---- C: diffusion scope = ALL chapters + contract clause ----
$script:BL = @()
$pC = Coord 'diffusion'
Assert-True ($pC -match 'Decompose ALL remaining approved chapters') "diffusion -> decompose ALL remaining chapters (one turn)"
Assert-True ($pC -match '(?i)provides' -and $pC -match '(?i)consumes') "diffusion -> emits provides/consumes contract clause"
Assert-True ($pC -match 'Chapter 1 through Chapter 3') "diffusion -> spans Chapter 1..3"

# ---- D: off scope = ONLY next chapter ----
$pD = Coord 'off'
Assert-True ($pD -match 'Decompose ONLY Chapter 1') "off -> decompose ONLY the next chapter"
Assert-True ($pD -notmatch 'Decompose ALL remaining approved chapters') "off -> NOT all-chapters"

# ---- E: wide scope = ALL chapters, NO contract ceremony ----
$pE = Coord 'wide'
Assert-True ($pE -match 'Decompose ALL remaining approved chapters') "wide -> decompose ALL remaining chapters"
Assert-True ($pE -match 'No interface-contract') "wide -> no contract ceremony clause"

try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}

Write-Host ""
if ($fail -eq 0) { Write-Host "RESULT: ALL PASS" } else { Write-Host ("RESULT: {0} FAIL" -f $fail); exit 1 }
