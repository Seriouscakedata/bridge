param()

# ==============================================================================
# tools/test-diffusion-coldstart-e2e.ps1
#   END-TO-END unit test for the COLD-START diffusion ingest chain that
#   Add-ProjectBacklogFromMarker (lib/backlog-autopilot.ps1) wires together.
#
# On cold start the coordinator emits atoms carrying provides/consumes but NO
# contract files on disk. The wiring must still reach a GREEN diffusion gate so
# contract-consumers parallelize -- via (a) in-memory synthesized contracts and
# (b) a freeze manifest that makes them stable, then (c) additive emit-shaping.
#
# NO live bridge, NO backlog I/O. This exercises the CHAIN via the underlying
# pure functions in the SAME ORDER the real wiring runs them (mirrored below),
# rather than calling Add-ProjectBacklogFromMarker end to end (which would need
# real backlog writes + the global lock).
#
# STEP-9 NOTE (option B): the real wiring evaluates Test-ProjectAutopilotDiffusionGate
# on the RAW coordinator batch (before shaping) with -StitchingTestsPresent:$true,
# BECAUSE New-ProjectAutopilotShapedBatch deterministically appends the stitch atom
# right after a green gate. Option (A) -- evaluating the gate on the SHAPED batch --
# is NOT viable without editing diffusion-planner.ps1 (forbidden): the shaped batch's
# freeze-marker and stitch atom BOTH own the stub file, so the gate on the shaped
# batch reddens with 'file-conflict-unresolved'. So this test mirrors option B:
# gate on the RAW batch (green), then schedule on the SHAPED batch (the dispatched
# set). The parallelization payoff is asserted on the shaped schedule: each consumer's
# single HARD dep becomes the FAST freeze marker (wave-1 independent) instead of the
# SLOW provider, so consumers run one wave behind the marker, in parallel with the
# provider -- exactly the diffusion win.
# ==============================================================================

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

# --- stubs the freeze-manifest lock path needs (mirror tools/test-diffusion-synthesis.ps1
#     and tools/test-project-autopilot-diffusion-contracts.ps1) ---
$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-diffusion-coldstart-e2e-' + [guid]::NewGuid().ToString('N'))
$script:EffectiveChannel = 'diffusion-coldstart-e2e'
function Get-BridgeRoot { return $script:TestBridgeRoot }
function Get-EffectiveChannel { return $script:EffectiveChannel }
function Get-ChannelDir {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = $script:EffectiveChannel }
  return (Join-Path (Join-Path $script:TestBridgeRoot 'channels') $Slug)
}
function Use-BridgeLock { param([scriptblock]$Body) & $Body }

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

try {
  New-Item -ItemType Directory -Path (Get-ChannelDir) -Force | Out-Null
  $tempProj = Join-Path $script:TestBridgeRoot 'project'
  New-Item -ItemType Directory -Path $tempProj -Force | Out-Null

  # ---- cold-start batch: complete metadata so Test-ProjectAutopilotTaskMetadata passes; NO contract
  #      file on disk, NO stitch atom. provider+consumers share the 'user-api' interface. ----
  $atoms = @(
    [pscustomobject]@{ slug='provider';   title='Provider module';   task='Build the provider module that implements and provides the user-api interface.'; acceptance=@('provider builds and exposes user-api'); checks=@('build'); risk='normal'; provides=@('user-api'); files=@('src/provider.ts'); chapter='Chapter 1'; depends_on=@() }
    [pscustomobject]@{ slug='consumer-a'; title='Consumer A';         task='Build consumer A which consumes the user-api interface.';                       acceptance=@('consumer A builds against user-api'); checks=@('build'); risk='normal'; consumes=@('user-api'); files=@('src/a.ts'); chapter='Chapter 2'; depends_on=@('provider') }
    [pscustomobject]@{ slug='consumer-b'; title='Consumer B';         task='Build consumer B which consumes the user-api interface.';                       acceptance=@('consumer B builds against user-api'); checks=@('build'); risk='normal'; consumes=@('user-api'); files=@('src/b.ts'); chapter='Chapter 3'; depends_on=@('provider') }
    [pscustomobject]@{ slug='indep';      title='Independent atom';   task='An independent atom that touches only its own file and shares no interface.';    acceptance=@('indep builds'); checks=@('build'); risk='normal'; files=@('src/x.ts'); chapter='Chapter 1'; depends_on=@() }
  )

  # === 1. SYNTHESIS: exactly one synthesized contract for 'user-api' (both provider+consumer atoms). ===
  $syn = New-ProjectAutopilotSynthesizedContracts -Tasks $atoms -ExistingContracts @()
  Assert-True (@($syn.synthesized).Count -eq 1) "1a: exactly one contract synthesized on cold start"
  Assert-True ([string]@($syn.synthesized)[0].id -eq 'user-api') "1b: synthesized contract id is 'user-api'"

  # === 2. FREEZE MANIFEST: the synthesized (merged) contract is freezable and writes a lock. ===
  $contracts = @($syn.synthesized)   # the merged set (cold start: no real disk contracts to win)
  $fm = New-ProjectAutopilotContractFreezeManifest -Tasks $atoms -Contracts $contracts -ProjectRoot $tempProj -Channel 'test' -Mode 'diffusion' -WriteLocks:$true
  Assert-True ([bool]@($fm.contracts)[0].freeze_ready -eq $true) "2a: freeze manifest contract freeze_ready is true"
  Assert-True ([bool]@($fm.contracts)[0].lock_written -eq $true) "2b: freeze manifest wrote the lock"

  # === 3. STABLE-FROM-FREEZE-MANIFEST: apply the SAME update the wiring does after the disk re-read --
  #        set synthesized contract stable=$true for every id whose manifest entry has lock_written. ===
  $lockedIds = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($e in @($fm.contracts)) {
    if ([bool](Get-BacklogPackObjectValue -Obj $e -Name 'lock_written' -Default $false)) {
      $lid = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $e -Name 'id' -Default ''))
      if (-not [string]::IsNullOrWhiteSpace($lid)) { [void]$lockedIds.Add($lid) }
    }
  }
  foreach ($c in @($contracts)) {
    $cid = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $c -Name 'id' -Default ''))
    if ($lockedIds.Contains($cid)) { $c | Add-Member -Force -NotePropertyName stable -NotePropertyValue $true }
  }
  Assert-True ([bool]@($contracts)[0].stable -eq $true) "3: synthesized contract is stable after freeze-manifest update"

  # === 4. SHAPING: additive emit-shaping adds a freeze marker + a stitch atom; NO shaped atom is
  #        dropped by the ingest metadata gate (a dropped marker/stitch would strand consumers). ===
  $shaped = New-ProjectAutopilotShapedBatch -Tasks $atoms -Contracts $contracts -FreezeManifest $fm
  Assert-True ([int]$shaped.markers_added -ge 1) "4a: shaping added at least one freeze marker"
  Assert-True ([int]$shaped.stitch_added -eq 1) "4b: shaping added exactly one stitch atom"
  $metaOffenders = @()
  foreach ($t in @($shaped.tasks)) {
    $mc = Test-ProjectAutopilotTaskMetadata -Task $t
    if (-not [bool]$mc.ok) { $metaOffenders += ([string](Get-BacklogPackObjectValue -Obj $t -Name 'slug' -Default '?') + ' missing=' + (@($mc.missing) -join ',')) }
  }
  Assert-True ($metaOffenders.Count -eq 0) ("4c: every shaped atom passes the ingest metadata gate (offenders: " + ($metaOffenders -join '; ') + ")")

  # === 5. GATE GREEN: mirror the REAL wiring (option B) -- evaluate the gate on the RAW batch with
  #        -StitchingTestsPresent:$true (shaping deterministically adds the stitch atom afterward). On
  #        the RAW batch there is no marker/stitch file-conflict, so the gate greens. (The gate on the
  #        SHAPED batch reddens with file-conflict-unresolved -- see the STEP-9 header note -- which is
  #        why option A is not viable without editing diffusion-planner.ps1.) ===
  $gate = Test-ProjectAutopilotDiffusionGate -Tasks $atoms -Contracts $contracts -OptIn:$true -CleanKnownState $true -StitchingTestsPresent $true -MinIndependentAtoms 1 -MaxWaveSize 20
  Assert-True ([bool]$gate.enabled -eq $true) ("5a: diffusion gate is GREEN on the raw cold-start batch")
  Assert-True (@($gate.reasons).Count -eq 0) ("5b: gate reasons are empty; got [" + (@($gate.reasons) -join ', ') + "]")

  # === 6. PARALLEL: on the SHAPED batch (the actual dispatched set) the consumers parallelize with the
  #        provider because their single HARD dep is now the FAST freeze marker (wave-1 independent), not
  #        the SLOW provider. Assert the independent set + the per-consumer single-hard-dep = marker. ===
  $sched = New-ProjectAutopilotWaveSchedule -Tasks $shaped.tasks -Contracts $contracts
  $indep = @($sched.classification.independent)
  $hardDep = @($sched.classification.hard_dependent)
  Assert-True ($indep -contains 'freeze-user-api') "6a: 'freeze-user-api' marker is independent (wave 1)"
  Assert-True ($indep -contains 'indep') "6b: 'indep' atom is independent"
  Assert-True ($hardDep -contains 'consumer-a' -and $hardDep -contains 'consumer-b') "6c: consumer-a AND consumer-b are hard-dependent on the (wave-1) marker, so they run in parallel with the provider"
  $softGraph = New-ProjectAutopilotUnifiedGraph -Tasks $shaped.tasks -Contracts $contracts -AllowContractSoftEdges:$true
  foreach ($cons in @('consumer-a','consumer-b')) {
    $hardFrom = @($softGraph.edges | Where-Object { [string]$_.to -eq $cons -and [string]$_.edge_type -eq 'hard' } | ForEach-Object { [string]$_.from } | Sort-Object -Unique)
    Assert-True ($hardFrom.Count -eq 1 -and $hardFrom[0] -eq 'freeze-user-api') ("6d: $cons's single HARD dep is the freeze marker, not 'provider'")
  }

  # === 7. NEGATIVE (safe serial): a DANGLING consume (no provider) -> synthesis skips it; the gate on
  #        the raw batch is DISABLED with a coverage/contract reason; the earliest-chapter collapse
  #        produces the serial one-chapter default; NO exception is thrown anywhere. ===
  $threw = $false
  try {
    $danglingAtoms = @(
      [pscustomobject]@{ slug='consumer-only'; title='Dangling consumer'; task='A consumer that consumes an interface no atom provides on cold start.'; acceptance=@('builds'); checks=@('build'); risk='normal'; consumes=@('missing'); files=@('src/only.ts'); chapter='Chapter 2'; depends_on=@() }
      [pscustomobject]@{ slug='lone';          title='Lone atom';         task='An independent atom in a later chapter with no interface at all.';           acceptance=@('builds'); checks=@('build'); risk='normal'; files=@('src/lone.ts'); chapter='Chapter 5'; depends_on=@() }
    )
    $synN = New-ProjectAutopilotSynthesizedContracts -Tasks $danglingAtoms -ExistingContracts @()
    Assert-True (@($synN.synthesized).Count -eq 0) "7a: synthesis produces NO contract for a dangling consume"
    $skipMissing = @($synN.skipped | Where-Object { [string]$_.id -eq 'missing' -and [string]$_.reason -eq 'dangling-consume' })
    Assert-True ($skipMissing.Count -eq 1) "7b: 'missing' id is skipped with reason dangling-consume"

    $gateN = Test-ProjectAutopilotDiffusionGate -Tasks $danglingAtoms -Contracts @($synN.synthesized) -OptIn:$true -CleanKnownState $true -StitchingTestsPresent $true -MinIndependentAtoms 1 -MaxWaveSize 20
    Assert-True (-not [bool]$gateN.enabled) "7c: gate is DISABLED for a dangling-consume batch"
    $covReason = @($gateN.reasons | Where-Object { $_ -match '(?i)coverage|contract' })
    Assert-True ($covReason.Count -ge 1) ("7d: disabled reason mentions coverage/contract; got [" + (@($gateN.reasons) -join ', ') + "]")

    $collapse = Get-ProjectAutopilotEarliestChapterTaskSet -Tasks $danglingAtoms
    Assert-True ([bool]$collapse.collapsed -eq $true) "7e: multi-chapter batch collapses to the earliest chapter (safe serial)"
    Assert-True ((@($collapse.tasks | ForEach-Object { $_.slug }) -contains 'consumer-only') -and (-not (@($collapse.tasks | ForEach-Object { $_.slug }) -contains 'lone'))) "7f: collapse keeps the earliest-chapter atom and drops the later chapter"
  } catch {
    $threw = $true
    Write-Host ("  (exception: " + $_.Exception.Message + ")")
  }
  Assert-True (-not $threw) "7g: the negative/safe-serial path threw NO exception"

  Write-Host ''
  $res = if ($fail -eq 0) { 'ALL PASS' } else { ("{0} FAILED" -f $fail) }
  Write-Host ("RESULT: {0}" -f $res)
} catch {
  Write-Host ("FATAL: {0}" -f $_.Exception.Message)
  Write-Host ([string]$_.ScriptStackTrace)
  $fail++
  Write-Host ''
  Write-Host ("RESULT: {0} FAILED" -f $fail)
} finally {
  if (Test-Path -LiteralPath $script:TestBridgeRoot) {
    Remove-Item -LiteralPath $script:TestBridgeRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

exit $fail
