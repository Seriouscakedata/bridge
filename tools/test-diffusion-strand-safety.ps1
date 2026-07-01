param()

# ==============================================================================
# tools/test-diffusion-strand-safety.ps1
#   Unit test for B1 (diffusion strand-safety): the frontier must recognise a
#   TERMINALLY-failed hard dependency so a dependent (e.g. the diffusion stitch
#   atom) is held+surfaced instead of spinning 'dependency-wait' forever.
#
# Covers the two PURE functions (no live bridge, no backlog I/O):
#   * Get-BacklogTerminalFailedSlugs  -- classifies which slugs are terminal-failed
#   * Test-BacklogTaskDependenciesReady -- returns the new terminal_failed bucket
# The frontier hold+save wiring itself is verified by parse + adversarial review +
# live smoke (it depends on Get-Backlog/Save-Backlog and is not pure).
# ==============================================================================

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\backlog-core.ps1')
. (Join-Path $root 'lib\backlog-workpack.ps1')

$fail = 0
function Assert-True { param([bool]$Cond, [string]$Label)
  $res = if ($Cond) { 'PASS' } else { 'FAIL' }
  if (-not $Cond) { $script:fail++ }
  Write-Host ("[{0}] {1}" -f $res, $Label)
}

function New-Item2 { param([string]$Slug,[string]$Status,[string]$HeldReason='',[string[]]$DependsOn=@())
  [pscustomobject]@{ slug=$Slug; id=$Slug; status=$Status; held_reason=$HeldReason; depends_on=@($DependsOn) }
}

# ---- 1. Get-BacklogTerminalFailedSlugs classification ----
$items = @(
  (New-Item2 -Slug 'prov-failed'      -Status 'failed')
  (New-Item2 -Slug 'prov-rejected'    -Status 'rejected')
  (New-Item2 -Slug 'prov-dropped'     -Status 'dropped')
  (New-Item2 -Slug 'prov-autodropped' -Status 'auto-dropped')
  (New-Item2 -Slug 'prov-deduped'     -Status 'deduped')
  (New-Item2 -Slug 'prov-superseded'  -Status 'superseded')
  (New-Item2 -Slug 'prov-giveup'      -Status 'held' -HeldReason 'batch-quarantine-giveup')
  (New-Item2 -Slug 'prov-heldplain'   -Status 'held' -HeldReason '')
  (New-Item2 -Slug 'prov-famine'      -Status 'held' -HeldReason 'commit_famine doctor pause')
  (New-Item2 -Slug 'prov-done'        -Status 'done')
  (New-Item2 -Slug 'prov-working'     -Status 'working')
)
$term = Get-BacklogTerminalFailedSlugs -Items $items

Assert-True ($term.Contains('prov-failed'))      "failed is terminal"
Assert-True ($term.Contains('prov-rejected'))    "rejected is terminal"
Assert-True ($term.Contains('prov-dropped'))     "dropped is terminal"
Assert-True ($term.Contains('prov-autodropped')) "auto-dropped is terminal (real production drop status)"
Assert-True ($term.Contains('prov-deduped'))     "deduped is terminal"
Assert-True ($term.Contains('prov-superseded'))  "superseded is terminal"
Assert-True ($term.Contains('prov-giveup'))      "held+giveup reason is terminal"
Assert-True (-not $term.Contains('prov-heldplain')) "plain held is NOT terminal (transient Doctor pause)"
Assert-True (-not $term.Contains('prov-famine'))    "held+commit_famine is NOT terminal (recoverable)"
Assert-True (-not $term.Contains('prov-done'))      "done is NOT terminal-failed"
Assert-True (-not $term.Contains('prov-working'))   "working is NOT terminal-failed"

# ---- 2. Test-BacklogTaskDependenciesReady terminal_failed bucket ----
$statusBySlug = @{}
foreach ($it in $items) { $statusBySlug[$it.slug] = $it.status }

# 2a. dep done -> ready, no terminal
$depDone = New-Item2 -Slug 'stitch-a' -Status 'approved' -DependsOn @('prov-done')
$rDone = Test-BacklogTaskDependenciesReady -Item $depDone -StatusBySlug $statusBySlug -TerminalFailedSlugs $term
Assert-True ([bool]$rDone.ready)                       "dep=done -> ready"
Assert-True (@($rDone.terminal_failed).Count -eq 0)    "dep=done -> no terminal_failed"

# 2b. dep failed -> not ready, terminal_failed populated
$depFail = New-Item2 -Slug 'stitch-b' -Status 'approved' -DependsOn @('prov-failed')
$rFail = Test-BacklogTaskDependenciesReady -Item $depFail -StatusBySlug $statusBySlug -TerminalFailedSlugs $term
Assert-True (-not [bool]$rFail.ready)                  "dep=failed -> not ready"
Assert-True (@($rFail.terminal_failed).Count -ge 1)    "dep=failed -> terminal_failed populated"
Assert-True ((($rFail.terminal_failed -join ',')) -match 'prov-failed') "terminal_failed names the failed dep"

# 2c. dep plain-held -> not ready, but NOT terminal (stays dependency-wait, does not strand)
$depHeld = New-Item2 -Slug 'stitch-c' -Status 'approved' -DependsOn @('prov-heldplain')
$rHeld = Test-BacklogTaskDependenciesReady -Item $depHeld -StatusBySlug $statusBySlug -TerminalFailedSlugs $term
Assert-True (-not [bool]$rHeld.ready)                  "dep=plain-held -> not ready"
Assert-True (@($rHeld.unmet).Count -ge 1)             "dep=plain-held -> unmet populated"
Assert-True (@($rHeld.terminal_failed).Count -eq 0)   "dep=plain-held -> NOT terminal_failed (no false strand)"

# 2d. dep giveup-held -> terminal
$depGiveup = New-Item2 -Slug 'stitch-d' -Status 'approved' -DependsOn @('prov-giveup')
$rGiveup = Test-BacklogTaskDependenciesReady -Item $depGiveup -StatusBySlug $statusBySlug -TerminalFailedSlugs $term
Assert-True (@($rGiveup.terminal_failed).Count -ge 1)  "dep=giveup-held -> terminal_failed populated"

# 2d2. dep auto-dropped -> terminal (the production drop path B1 must cover)
$depAuto = New-Item2 -Slug 'stitch-f' -Status 'approved' -DependsOn @('prov-autodropped')
$rAuto = Test-BacklogTaskDependenciesReady -Item $depAuto -StatusBySlug $statusBySlug -TerminalFailedSlugs $term
Assert-True (-not [bool]$rAuto.ready)                  "dep=auto-dropped -> not ready"
Assert-True (@($rAuto.terminal_failed).Count -ge 1)   "dep=auto-dropped -> terminal_failed populated (production strand path)"

# 2e. mixed deps (one done, one failed) -> not ready, terminal names only the failed one
$depMixed = New-Item2 -Slug 'stitch-e' -Status 'approved' -DependsOn @('prov-done','prov-failed')
$rMixed = Test-BacklogTaskDependenciesReady -Item $depMixed -StatusBySlug $statusBySlug -TerminalFailedSlugs $term
Assert-True (-not [bool]$rMixed.ready)                 "mixed(done+failed) -> not ready"
Assert-True (@($rMixed.terminal_failed).Count -eq 1)   "mixed -> exactly one terminal_failed"
Assert-True ((($rMixed.terminal_failed -join ',')) -match 'prov-failed') "mixed -> terminal is the failed dep, not the done one"

# 2f. BACKWARD COMPAT: no TerminalFailedSlugs passed -> terminal_failed empty, ready unchanged
$rCompat = Test-BacklogTaskDependenciesReady -Item $depFail -StatusBySlug $statusBySlug
Assert-True (-not [bool]$rCompat.ready)                "compat: dep=failed still not ready"
Assert-True (@($rCompat.terminal_failed).Count -eq 0)  "compat: no set passed -> terminal_failed empty (old behaviour)"

# 2g. no deps -> ready, terminal_failed empty
$depNone = New-Item2 -Slug 'indep' -Status 'approved' -DependsOn @()
$rNone = Test-BacklogTaskDependenciesReady -Item $depNone -StatusBySlug $statusBySlug -TerminalFailedSlugs $term
Assert-True ([bool]$rNone.ready)                       "no deps -> ready"
Assert-True (@($rNone.terminal_failed).Count -eq 0)    "no deps -> terminal_failed empty"

Write-Host ""
if ($fail -eq 0) { Write-Host "RESULT: ALL PASS" } else { Write-Host ("RESULT: {0} FAIL" -f $fail); exit 1 }
