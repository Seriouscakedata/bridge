# ==============================================================================
# tools/test-diffusion-shaping.ps1 -- unit test for Ch3 emit-shaping
#   New-ProjectAutopilotShapedBatch (lib/diffusion-planner.ps1)
# Pure-function test: no I/O, no live bridge. Source the libs, build a synthetic
# batch + freeze manifest, reshape it, and assert the additive shaping invariants
# plus the downstream wave-schedule placement.
# ==============================================================================

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\backlog-autopilot.ps1')
. (Join-Path $root 'lib\diffusion-planner.ps1')

$fail = 0
function Assert-True {
  param([bool]$Cond, [string]$Label)
  $res = if ($Cond) { 'PASS' } else { 'FAIL' }
  if (-not $Cond) { $script:fail++ }
  Write-Host ("[{0}] {1}" -f $res, $Label)
}

# -- helper: find a task by slug in a reshaped batch --
function Find-Task {
  param($Tasks, [string]$Slug)
  foreach ($t in @($Tasks)) {
    $s = [string](Get-BacklogPackObjectValue -Obj $t -Name 'slug' -Default '')
    if ($s -eq $Slug) { return $t }
  }
  return $null
}
function Get-Arr {
  param($Obj, [string]$Name)
  return @(Get-BacklogPackObjectValue -Obj $Obj -Name $Name -Default @())
}

# ---- synthetic batch ----
# NOTE: realistic complete atoms (as the coordinator emits them) so the metadata-gate assertion below
# exercises the FULL shaped batch (originals + shaped additions), not a strawman.
$atoms = @(
  [pscustomobject]@{ slug='styler';        title='Styler domain';  task='Build the Styler.';  chapter='Chapter 2'; files=@('app/Styler.kt'); depends_on=@();         provides=@('styler-iface'); acceptance=@('styler applies a filter'); checks=@('gradle build'); risk='normal' }
  [pscustomobject]@{ slug='vm-bake';       title='Bake ViewModel';  task='Build the bake VM.'; chapter='Chapter 7'; files=@('app/Vm.kt');     depends_on=@('styler'); consumes=@('styler-iface'); acceptance=@('vm bakes via styler'); checks=@('gradle build'); risk='normal' }
  [pscustomobject]@{ slug='screen-result'; title='Result screen';   task='Build the result screen.'; chapter='Chapter 6'; files=@('app/Result.kt'); depends_on=@('styler'); consumes=@('styler-iface'); acceptance=@('result renders'); checks=@('gradle build'); risk='normal' }
  [pscustomobject]@{ slug='gitignore';     title='Add .gitignore'; task='Add .gitignore.';     chapter='Chapter 1'; files=@('.gitignore');    depends_on=@(); acceptance=@('ignores build dirs'); checks=@('file exists'); risk='normal' }
)

$fm = [pscustomobject]@{
  contracts = @(
    [pscustomobject]@{
      id='styler-iface'
      provider_atoms=@('styler')
      consumer_atoms=@('vm-bake','screen-result')
      generated_stub_language='kotlin'
      generated_stub_source="// stub`ninterface Styler { fun apply(b: Bitmap): Bitmap }`n"
      freeze_ready=$true
      lock_written=$true
    }
  )
}

$shaped = New-ProjectAutopilotShapedBatch -Tasks $atoms -Contracts @() -FreezeManifest $fm -ProjectRoot 'X:\proj' -Channel 'test'

# ---- top-level counters ----
Assert-True ([bool]$shaped.applied -eq $true) "applied is true"
Assert-True ([int]$shaped.markers_added -eq 1) "markers_added -eq 1"
Assert-True ([int]$shaped.consumers_rewritten -eq 2) "consumers_rewritten -eq 2"
Assert-True ([int]$shaped.stitch_added -eq 1) "stitch_added -eq 1"

# ---- freeze-marker atom ----
$marker = Find-Task $shaped.tasks 'freeze-styler-iface'
Assert-True ($null -ne $marker) "freeze-marker atom 'freeze-styler-iface' exists"
if ($null -ne $marker) {
  Assert-True ((Get-Arr $marker 'depends_on').Count -eq 0) "freeze-marker depends_on is empty"
  $mf = @(Get-Arr $marker 'files')
  Assert-True ($mf.Count -eq 1 -and $mf[0] -eq '.bridge/stubs/styler-iface.kt') "freeze-marker files = @('.bridge/stubs/styler-iface.kt')"
}

# ---- consumers rewritten ----
$vm = Find-Task $shaped.tasks 'vm-bake'
Assert-True ($null -ne $vm) "consumer 'vm-bake' exists"
if ($null -ne $vm) {
  $vmDeps = @(Get-Arr $vm 'depends_on')
  Assert-True ($vmDeps.Count -eq 1 -and $vmDeps[0] -eq 'freeze-styler-iface') "vm-bake depends_on = @('freeze-styler-iface') (provider removed)"
  $vmScope = [string](Get-BacklogPackObjectValue -Obj $vm -Name 'acceptance_scope' -Default '')
  Assert-True ($vmScope -eq 'contract') "vm-bake acceptance_scope -eq 'contract'"
}
$sr = Find-Task $shaped.tasks 'screen-result'
Assert-True ($null -ne $sr) "consumer 'screen-result' exists"
if ($null -ne $sr) {
  $srDeps = @(Get-Arr $sr 'depends_on')
  Assert-True ($srDeps.Count -eq 1 -and $srDeps[0] -eq 'freeze-styler-iface') "screen-result depends_on = @('freeze-styler-iface') (provider removed)"
  $srScope = [string](Get-BacklogPackObjectValue -Obj $sr -Name 'acceptance_scope' -Default '')
  Assert-True ($srScope -eq 'contract') "screen-result acceptance_scope -eq 'contract'"
}

# ---- stitch atom (slug now carries a deterministic hash suffix; find by kind) ----
$stitch = $null
foreach ($t in @($shaped.tasks)) { if (([string](Get-BacklogPackObjectValue -Obj $t -Name 'kind' -Default '')) -eq 'consolidation') { $stitch = $t; break } }
Assert-True ($null -ne $stitch) "stitch (consolidation) atom exists"
if ($null -ne $stitch) {
  $stSlug = [string](Get-BacklogPackObjectValue -Obj $stitch -Name 'slug' -Default '')
  Assert-True ($stSlug -like 'stitch-integration*') "stitch slug starts with 'stitch-integration'"
  $stDeps = @(Get-Arr $stitch 'depends_on')
  Assert-True ($stDeps -contains 'styler') "stitch depends_on contains 'styler'"
  Assert-True ($stDeps -contains 'vm-bake') "stitch depends_on contains 'vm-bake'"
  Assert-True ($stDeps -contains 'screen-result') "stitch depends_on contains 'screen-result'"
}

# ---- provider + independent unchanged ----
$styler = Find-Task $shaped.tasks 'styler'
Assert-True ($null -ne $styler -and (Get-Arr $styler 'depends_on').Count -eq 0) "provider 'styler' unchanged (depends_on empty)"
$gi = Find-Task $shaped.tasks 'gitignore'
Assert-True ($null -ne $gi -and (Get-Arr $gi 'depends_on').Count -eq 0) "independent 'gitignore' unchanged (depends_on empty)"

# ---- determinism: two calls serialize identically ----
$a = New-ProjectAutopilotShapedBatch -Tasks $atoms -Contracts @() -FreezeManifest $fm -ProjectRoot 'X:\proj' -Channel 'test'
$b = New-ProjectAutopilotShapedBatch -Tasks $atoms -Contracts @() -FreezeManifest $fm -ProjectRoot 'X:\proj' -Channel 'test'
$ja = ($a.tasks | ConvertTo-Json -Depth 12)
$jb = ($b.tasks | ConvertTo-Json -Depth 12)
Assert-True ($ja -eq $jb) "determinism: two reshaped task arrays serialize identically"

# ---- no-throw on empty/null ----
$threw = $false
$no = $null
try { $no = New-ProjectAutopilotShapedBatch -Tasks @() -FreezeManifest $null } catch { $threw = $true }
Assert-True (-not $threw) "no-throw: empty tasks + null manifest does not throw"
Assert-True ($null -ne $no -and [bool]$no.applied -eq $false) "no-op shape: applied=$false on null manifest"

# ---- downstream: wave schedule places marker in wave 1, consumers depend only on marker ----
$sched = New-ProjectAutopilotWaveSchedule -Tasks $shaped.tasks -Contracts @()
$indep = @($sched.classification.independent)
$hardDep = @($sched.classification.hard_dependent)
Assert-True ($indep -contains 'freeze-styler-iface') "schedule: 'freeze-styler-iface' is independent (wave 1)"
Assert-True ($hardDep -contains 'vm-bake') "schedule: 'vm-bake' is hard_dependent"

# vm-bake's single hard dep in the soft graph must be the marker (not the provider)
$softGraph = New-ProjectAutopilotUnifiedGraph -Tasks $shaped.tasks -Contracts @() -AllowContractSoftEdges:$true
$vmHardFrom = @($softGraph.edges | Where-Object { [string]$_.to -eq 'vm-bake' -and [string]$_.edge_type -eq 'hard' } | ForEach-Object { [string]$_.from } | Sort-Object -Unique)
Assert-True ($vmHardFrom.Count -eq 1 -and $vmHardFrom[0] -eq 'freeze-styler-iface') "schedule: vm-bake's single hard dep is the freeze marker"

# also verify the marker is in wave 1 of the soft schedule
$softWave1 = @()
if (@($sched.soft.waves).Count -gt 0) { $softWave1 = @(@($sched.soft.waves)[0].atoms) }
Assert-True ($softWave1 -contains 'freeze-styler-iface') "schedule: freeze marker is in soft wave 1"

# ---- CRITICAL regression: every shaped atom MUST pass the write-loop metadata gate. A freeze-marker or
#      stitch atom dropped at ingest (missing title/checks/files) would strand every rewritten consumer
#      forever on a nonexistent dependency. ----
$gateFails = @()
foreach ($t in @($shaped.tasks)) {
  $mc = Test-ProjectAutopilotTaskMetadata -Task $t
  if (-not [bool]$mc.ok) { $gateFails += ([string](Get-BacklogPackObjectValue -Obj $t -Name 'slug' -Default '?') + ' missing=' + (@($mc.missing) -join ',')) }
}
Assert-True ($gateFails.Count -eq 0) ("metadata gate: ALL shaped atoms accepted (offenders: " + ($gateFails -join '; ') + ")")

if ($fail -eq 0) { Write-Host "RESULT: ALL PASS" } else { Write-Host ("RESULT: {0} FAILED" -f $fail) }
exit $fail
