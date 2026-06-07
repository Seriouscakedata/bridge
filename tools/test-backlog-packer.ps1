param()

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-backlog-packer-test-' + [guid]::NewGuid().ToString('N'))
$script:EffectiveChannel = 'main'

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-BacklogItemBySlug {
  param([string]$Slug, [string]$Label)
  $items = @(Get-Backlog | Where-Object { [string]$_.slug -eq $Slug } | Select-Object -First 1)
  Assert-True ($items.Count -eq 1) ("missing {0}" -f $Label)
  return $items[0]
}

function Assert-BacklogItemLane {
  param(
    $Item,
    [string]$Label,
    [string]$ExpectedLane = ''
  )
  Assert-True ($Item.PSObject.Properties.Name -contains 'lane') ("{0} missing top-level lane" -f $Label)
  $lane = [string]$Item.lane
  Assert-True (-not [string]::IsNullOrWhiteSpace($lane)) ("{0} lane is blank" -f $Label)
  if (-not [string]::IsNullOrWhiteSpace($ExpectedLane)) {
    Assert-True ($lane -eq $ExpectedLane) ("{0} lane mismatch: expected '{1}', got '{2}'" -f $Label, $ExpectedLane, $lane)
  }
  return $lane
}

function Get-BridgeRoot { return $script:TestBridgeRoot }
function Get-EffectiveChannel { return $script:EffectiveChannel }
function Get-ChannelDir {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = 'main' }
  return (Join-Path (Join-Path $script:TestBridgeRoot 'channels') $Slug)
}
function Get-ChannelBacklogPath {
  param([string]$Slug = $null)
  return (Join-Path (Get-ChannelDir -Slug $Slug) 'backlog.jsonl')
}
function Use-BridgeLock {
  param([scriptblock]$Body)
  & $Body
}
function Get-AutonomySettings {
  return [pscustomobject]@{
    backlogPackEnabled            = $true
    backlogPackBurstCount         = 5
    backlogPackWindowMinutes      = 60
    backlogPackUnpackedOpenCount  = 8
    backlogPackAuditBurstCount    = 3
    backlogPackAuditWindowMinutes = 30
    backlogPackCooldownMinutes    = 30
    backlogPackMinItems           = 2
  }
}

try {
  $mainDir = Get-ChannelDir -Slug 'main'
  New-Item -ItemType Directory -Path $mainDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug 'main'), '', (New-Object System.Text.UTF8Encoding($false)))

  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\backlog.ps1')
  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\workpack-obligation.ps1')

  [void](Add-Idea -Text '[audit/ui] surface web/index.html status badge for watchdog fatal state' -From 'audit' -Tags @('audit') -Status 'new' -SkipCurator)
  [void](Add-Idea -Text '[audit/backlog] harden lib/backlog.ps1 curator held reason visibility' -From 'audit' -Tags @('audit') -Status 'new' -SkipCurator)
  [void](Add-Idea -Text '[audit/memory] check memory embeddings recall for large project maps' -From 'audit' -Tags @('audit') -Status 'new' -SkipCurator)
  [void](Add-Idea -Text 'group related backlog ideas before autonomy drains them one by one' -From 'architect' -Tags @('architect') -Status 'new' -SkipCurator)
  [void](Add-Idea -Text 'record workpack lane hints for future parallel backlog execution' -From 'architect' -Tags @('architect') -Status 'new' -SkipCurator)

  $requestPath = Get-BacklogPackRequestPath
  Assert-True (Test-Path -LiteralPath $requestPath) 'expected pack request after burst threshold'

  $run = Invoke-BacklogPackerIfDue
  Assert-True ($run -and [bool]$run.ran) 'expected packer to run'
  Assert-True ([int]$run.packed_items -eq 5) ("expected 5 packed items, got {0}" -f [int]$run.packed_items)
  Assert-True ([int]$run.workpack_count -ge 1) 'expected at least one workpack'
  Assert-True (-not (Test-Path -LiteralPath $requestPath)) 'expected pack request to be consumed'

  $items = @(Get-Backlog)
  Assert-True ($items.Count -eq 5) ("expected 5 backlog items, got {0}" -f $items.Count)
  foreach ($item in $items) {
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$item.workpack_id)) 'missing workpack_id'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$item.workpack_root_cause_key)) 'missing workpack_root_cause_key'
    Assert-True ($item.PSObject.Properties.Name -contains 'workpack_touch_set') 'missing workpack_touch_set'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$item.workpack_conflict_group)) 'missing workpack_conflict_group'
  }

  $pressure = Get-BacklogPackPressure
  Assert-True ([int]$pressure.open_unpacked -eq 0) ("expected no unpacked open items, got {0}" -f [int]$pressure.open_unpacked)

  $forbiddenClass = Get-BacklogWorkpackClassification ([pscustomobject]@{
    text = "files: lib/review-verdict.ps1 for delivery gate checks. НЕ трогать lib/backlog.ps1 lib/parallel.ps1 driver/84-loop-reply-markers.ps1 driver/*"
  })
  Assert-True (@($forbiddenClass.touch_set) -contains 'lib/review-verdict.ps1') 'expected explicit target file in touch_set'
  Assert-True (-not (@($forbiddenClass.touch_set) -contains 'lib/backlog.ps1')) 'forbidden lib/backlog.ps1 leaked into touch_set'
  Assert-True (-not (@($forbiddenClass.touch_set) -contains 'lib/parallel.ps1')) 'forbidden lib/parallel.ps1 leaked into touch_set'
  Assert-True (-not (@($forbiddenClass.touch_set) -contains 'driver/84-loop-reply-markers.ps1')) 'forbidden driver file leaked into touch_set'

  $explicitClass = Get-BacklogWorkpackClassification ([pscustomobject]@{
    text = "files: lib/backlog.ps1`nImplement the marker handling change in the explicit file above.`nНЕ трогать driver/84-loop-reply-markers.ps1 driver/*"
  })
  Assert-True (@($explicitClass.touch_set) -contains 'lib/backlog.ps1') 'explicit files target did not win'
  Assert-True (-not (@($explicitClass.touch_set) -contains 'driver/84-loop-reply-markers.ps1')) 'forbidden driver file leaked into explicit target touch_set'

  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug 'main'), '', (New-Object System.Text.UTF8Encoding($false)))
  $mainMarker = @'
[
  {
    "slug": "bridge-self-project-backlog-test",
    "title": "Bridge self project backlog marker test",
    "task": "Create a synthetic bridge self backlog atom that proves PROJECT_BACKLOG markers work safely in the main channel.",
    "files": ["lib/review-verdict.ps1"],
    "depends_on": [],
    "acceptance": ["Main PROJECT_BACKLOG marker creates an approved bridge-self atom."],
    "checks": ["powershell -NoProfile -ExecutionPolicy Bypass -File .\\tools\\test-backlog-packer.ps1", "powershell -NoProfile -ExecutionPolicy Bypass -File .\\driver.ps1 -SelfTest", "powershell -NoProfile -ExecutionPolicy Bypass -File .\\smoke.ps1", "Invoke-CanaryCycle -Force"],
    "risk": "high",
    "serial_reason": "",
    "severity": "info",
    "bridge_self_admission": {
      "admitted": true,
      "mode": "bridge_self_canary",
      "canary_required": true,
      "checks": ["powershell -NoProfile -ExecutionPolicy Bypass -File .\\driver.ps1 -SelfTest", "powershell -NoProfile -ExecutionPolicy Bypass -File .\\smoke.ps1", "Invoke-CanaryCycle -Force"],
      "rollback_plan": "Use stable ref + watchdog rollback if health/smoke/canary fails."
    }
  }
]
'@
  $mainResult = Add-ProjectBacklogFromMarker -Block $mainMarker -Channel 'main' -Source 'test' -SourceTaskId 'main-test'
  Assert-True ([int]$mainResult.created -eq 1) ("expected one main bridge-self atom, got {0}" -f [int]$mainResult.created)
  Assert-True (-not (@($mainResult.errors) -contains 'project backlog marker ignored outside project channel')) 'main channel marker was ignored'
  $mainItem = Get-BacklogItemBySlug -Slug 'bridge-self-project-backlog-test' -Label 'main bridge-self item'
  Assert-True ([string]$mainItem.status -eq 'approved') 'main bridge-self item is not approved'
  Assert-True ([string]$mainItem.scope -eq 'bridge') 'main bridge-self item scope is not bridge'
  Assert-True (@($mainItem.tags) -contains 'project-autopilot') 'main bridge-self item missing project-autopilot tag'
  Assert-True (@($mainItem.tags) -contains 'bridge-self') 'main bridge-self item missing bridge-self tag'
  Assert-True (@($mainItem.tags) -contains 'atom') 'main bridge-self item missing atom tag'
  $mainLane = Assert-BacklogItemLane -Item $mainItem -Label 'main bridge-self item'
  Assert-True (-not (Test-WorkpackControlPlaneLane -Lane $mainLane)) 'main bridge-self item lane was misclassified as control-plane'
  Assert-True ($mainItem.PSObject.Properties.Name -contains 'depends_on') 'main bridge-self item missing top-level depends_on'
  $dependsType = if ($null -eq $mainItem.depends_on) { '<null>' } else { $mainItem.depends_on.GetType().FullName }
  $dependsCount = if ($null -eq $mainItem.depends_on) { -1 } else { [int]$mainItem.depends_on.Count }
  Assert-True (($null -ne $mainItem.depends_on) -and ($mainItem.depends_on -is [System.Collections.IEnumerable]) -and ($mainItem.depends_on -isnot [string]) -and ($dependsCount -eq 0)) ("main bridge-self item depends_on is not an empty array: type={0} count={1} value={2}" -f $dependsType, $dependsCount, ([string]$mainItem.depends_on))
  Assert-True ($mainItem.PSObject.Properties.Name -contains 'files') 'main bridge-self item missing top-level files'
  Assert-True (@($mainItem.files) -contains 'lib/review-verdict.ps1') 'main bridge-self item files were not normalized'
  Assert-True (@($mainItem.acceptance) -contains 'Main PROJECT_BACKLOG marker creates an approved bridge-self atom.') 'main bridge-self item missing top-level acceptance'
  Assert-True (@($mainItem.acceptance_checks) -contains 'Main PROJECT_BACKLOG marker creates an approved bridge-self atom.') 'main bridge-self item missing acceptance_checks alias'
  Assert-True (@($mainItem.checks) -contains 'powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test-backlog-packer.ps1') 'main bridge-self item missing top-level checks'
  Assert-True (@($mainItem.verification_checks) -contains 'powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test-backlog-packer.ps1') 'main bridge-self item missing verification_checks alias'
  Assert-True ($mainItem.PSObject.Properties.Name -contains 'bridge_self_admission') 'main bridge-self item missing bridge_self_admission'
  $mainAdmission = Test-IdeaBridgeSelfAdmitted -Idea $mainItem
  Assert-True ([bool]$mainAdmission.ok) ("main bridge-self admission did not validate: {0}" -f (@($mainAdmission.missing) -join ', '))
  Assert-True ([string]$mainItem.risk -eq 'high') 'main bridge-self item risk was not normalized from marker risk'
  Assert-True ($mainItem.PSObject.Properties.Name -contains 'serial_reason') 'main bridge-self item missing top-level serial_reason'
  $metadataResult = Test-WorkpackAtomMetadata -Atom $mainItem
  Assert-True ([bool]$metadataResult.ok) ("main bridge-self item did not pass workpack metadata validation: {0}" -f ((@($metadataResult.blockers) + @($metadataResult.missing)) -join ', '))

  $missingAcceptanceChecksMarker = @'
[
  {
    "slug": "bridge-self-incomplete-no-acceptance-checks",
    "title": "Bridge self incomplete metadata rejection test",
    "task": "Create a synthetic incomplete bridge self atom that must be rejected before it reaches approved backlog.",
    "files": ["lib/backlog.ps1"],
    "risk": "normal"
  }
]
'@
  $missingAcceptanceChecksResult = Add-ProjectBacklogFromMarker -Block $missingAcceptanceChecksMarker -Channel 'main' -Source 'test' -SourceTaskId 'invalid-no-acceptance-checks'
  Assert-True ([int]$missingAcceptanceChecksResult.created -eq 0) ("expected zero incomplete atoms without acceptance/checks, got {0}" -f [int]$missingAcceptanceChecksResult.created)
  $missingAcceptanceChecksErrors = (@($missingAcceptanceChecksResult.errors) -join "`n")
  Assert-True ($missingAcceptanceChecksErrors -match "incomplete PROJECT_BACKLOG atom 'bridge-self-incomplete-no-acceptance-checks'") 'missing incomplete atom error for acceptance/checks case'
  Assert-True ($missingAcceptanceChecksErrors -match 'missing .*acceptance') 'missing acceptance was not reported'
  Assert-True ($missingAcceptanceChecksErrors -match 'missing .*checks') 'missing checks was not reported'
  $missingAcceptanceChecksItem = @(Get-Backlog | Where-Object { [string]$_.slug -eq 'bridge-self-incomplete-no-acceptance-checks' })
  Assert-True ($missingAcceptanceChecksItem.Count -eq 0) 'incomplete atom without acceptance/checks reached backlog'

  $missingFilesMarker = @'
[
  {
    "slug": "bridge-self-incomplete-no-files",
    "title": "Bridge self incomplete files rejection test",
    "task": "Create a synthetic incomplete bridge self atom without files that must be rejected before approved backlog.",
    "acceptance": ["Incomplete atoms without files are rejected."],
    "checks": ["powershell -NoProfile -ExecutionPolicy Bypass -File .\\tools\\test-backlog-packer.ps1"],
    "risk": "normal"
  }
]
'@
  $missingFilesResult = Add-ProjectBacklogFromMarker -Block $missingFilesMarker -Channel 'main' -Source 'test' -SourceTaskId 'invalid-no-files'
  Assert-True ([int]$missingFilesResult.created -eq 0) ("expected zero incomplete atoms without files, got {0}" -f [int]$missingFilesResult.created)
  $missingFilesErrors = (@($missingFilesResult.errors) -join "`n")
  Assert-True ($missingFilesErrors -match "incomplete PROJECT_BACKLOG atom 'bridge-self-incomplete-no-files'") 'missing incomplete atom error for files case'
  Assert-True ($missingFilesErrors -match 'missing .*files') 'missing files was not reported'
  $missingFilesItem = @(Get-Backlog | Where-Object { [string]$_.slug -eq 'bridge-self-incomplete-no-files' })
  Assert-True ($missingFilesItem.Count -eq 0) 'incomplete atom without files reached backlog'

  $missingDependsMarker = @'
[
  {
    "slug": "bridge-self-no-depends-default-test",
    "title": "Bridge self no depends default test",
    "task": "Create a synthetic bridge self atom without depends_on to prove ingestion keeps the Atom 2 empty array default.",
    "files": ["lib/backlog.ps1"],
    "acceptance_checks": ["Missing depends_on defaults to an empty top-level array."],
    "verification": ["powershell -NoProfile -ExecutionPolicy Bypass -File .\\tools\\test-backlog-packer.ps1"],
    "risk": "normal",
    "serial_reason": ""
  }
]
'@
  $missingDependsResult = Add-ProjectBacklogFromMarker -Block $missingDependsMarker -Channel 'main' -Source 'test' -SourceTaskId 'missing-depends'
  Assert-True ([int]$missingDependsResult.created -eq 1) ("expected one atom without depends_on, got {0}" -f [int]$missingDependsResult.created)
  $missingDependsItem = @(Get-Backlog | Where-Object { [string]$_.slug -eq 'bridge-self-no-depends-default-test' } | Select-Object -First 1)
  Assert-True ($missingDependsItem.Count -eq 1) 'missing depends_on default item was not created'
  Assert-True ($missingDependsItem[0].PSObject.Properties.Name -contains 'depends_on') 'item without depends_on did not get top-level depends_on'
  $missingDependsCount = if ($null -eq $missingDependsItem[0].depends_on) { -1 } else { [int]$missingDependsItem[0].depends_on.Count }
  Assert-True (($null -ne $missingDependsItem[0].depends_on) -and ($missingDependsItem[0].depends_on -is [System.Collections.IEnumerable]) -and ($missingDependsItem[0].depends_on -isnot [string]) -and ($missingDependsCount -eq 0)) ("item without depends_on did not get an empty array: count={0}" -f $missingDependsCount)
  $missingDependsMetadata = Test-WorkpackAtomMetadata -Atom $missingDependsItem[0]
  Assert-True ([bool]$missingDependsMetadata.ok) ("item without depends_on did not pass workpack metadata validation: {0}" -f ((@($missingDependsMetadata.blockers) + @($missingDependsMetadata.missing)) -join ', '))

  $explicitMarker = @'
[
  {
    "slug": "bridge-self-explicit-workpack-test",
    "title": "Bridge self explicit workpack metadata test",
    "task": "Create a synthetic bridge self atom proving explicit workpack touch metadata wins over files-derived fallback.",
    "files": ["lib/backlog.ps1"],
    "acceptance_checks": ["Explicit workpack touch metadata is preserved."],
    "verification": ["powershell -NoProfile -ExecutionPolicy Bypass -File .\\tools\\test-backlog-packer.ps1"],
    "workpack_touch_set": ["lib/workpack-obligation.ps1"],
    "workpack_conflict_group": "custom:operatorless-metadata",
    "severity": "warning"
  }
]
'@
  $explicitResult = Add-ProjectBacklogFromMarker -Block $explicitMarker -Channel 'main' -Source 'test' -SourceTaskId 'explicit-test'
  Assert-True ([int]$explicitResult.created -eq 1) ("expected one explicit workpack metadata atom, got {0}" -f [int]$explicitResult.created)
  $explicitItem = @(Get-Backlog | Where-Object { [string]$_.slug -eq 'bridge-self-explicit-workpack-test' } | Select-Object -First 1)
  Assert-True ($explicitItem.Count -eq 1) 'missing explicit workpack metadata item'
  Assert-True (@($explicitItem[0].workpack_touch_set) -contains 'lib/workpack-obligation.ps1') 'explicit workpack_touch_set was not preserved'
  Assert-True (-not (@($explicitItem[0].workpack_touch_set) -contains 'lib/backlog.ps1')) 'files-derived fallback overrode explicit workpack_touch_set'
  Assert-True ([string]$explicitItem[0].workpack_conflict_group -eq 'custom:operatorless-metadata') 'explicit workpack_conflict_group was not preserved'
  Assert-True ([string]$explicitItem[0].risk -eq 'high') 'explicit item severity warning did not normalize to high risk'

  $laneSeparatedMarker = @'
[
  {
    "slug": "bridge-self-lane-separated-test",
    "title": "Bridge self lane separation metadata test",
    "task": "Create a synthetic bridge self atom proving marker-created default lane is top-level metadata and does not overwrite parallel_group.",
    "parallel_group": "pg-ui-layout",
    "files": ["src/ui/lane-separated.tsx"],
    "depends_on": [],
    "acceptance": ["Marker-created atoms keep lane and parallel_group distinct."],
    "checks": ["powershell -NoProfile -ExecutionPolicy Bypass -File .\\tools\\test-backlog-packer.ps1"],
    "risk": "normal",
    "serial_reason": ""
  }
]
'@
  $laneSeparatedResult = Add-ProjectBacklogFromMarker -Block $laneSeparatedMarker -Channel 'main' -Source 'test' -SourceTaskId 'lane-separated-test'
  Assert-True ([int]$laneSeparatedResult.created -eq 1) ("expected one lane-separated atom, got {0}" -f [int]$laneSeparatedResult.created)
  $laneSeparatedItem = Get-BacklogItemBySlug -Slug 'bridge-self-lane-separated-test' -Label 'lane-separated item'
  $laneSeparatedLane = Assert-BacklogItemLane -Item $laneSeparatedItem -Label 'lane-separated item' -ExpectedLane 'bridge'
  Assert-True ($laneSeparatedItem.PSObject.Properties.Name -contains 'parallel_group') 'lane-separated item missing top-level parallel_group'
  Assert-True ([string]$laneSeparatedItem.parallel_group -eq 'pg-ui-layout') 'lane-separated item parallel_group was not preserved'
  Assert-True ([string]$laneSeparatedItem.parallel_group -ne $laneSeparatedLane) 'lane-separated item mixed lane with parallel_group'
  Assert-True (-not (Test-WorkpackControlPlaneLane -Lane $laneSeparatedLane)) 'project lane was incorrectly treated as control-plane'
  Assert-True (-not (Test-WorkpackControlPlaneLane -Lane ([string]$laneSeparatedItem.parallel_group))) 'parallel_group value was incorrectly treated as control-plane lane'
  $laneSeparatedMetadata = Test-WorkpackAtomMetadata -Atom $laneSeparatedItem
  Assert-True ([bool]$laneSeparatedMetadata.ok) ("lane-separated item did not pass workpack metadata validation: {0}" -f ((@($laneSeparatedMetadata.blockers) + @($laneSeparatedMetadata.missing)) -join ', '))

  $controlPlaneExplicitMarker = @'
[
  {
    "slug": "bridge-self-control-plane-explicit-lane-test",
    "title": "Bridge self explicit control-plane lane test",
    "task": "Create a synthetic bridge self control-plane atom proving an explicit lane marker survives as top-level control-plane metadata.",
    "lane": "control-plane",
    "parallel_group": "pg-control-explicit",
    "files": ["driver.ps1"],
    "depends_on": [],
    "acceptance": ["Explicit control-plane markers normalize top-level lane correctly."],
    "checks": ["powershell -NoProfile -ExecutionPolicy Bypass -File .\\tools\\test-backlog-packer.ps1", "powershell -NoProfile -ExecutionPolicy Bypass -File .\\driver.ps1 -SelfTest", "powershell -NoProfile -ExecutionPolicy Bypass -File .\\smoke.ps1", "Invoke-CanaryCycle -Force"],
    "risk": "high",
    "serial_reason": "control_plane",
    "bridge_self_admission": {
      "admitted": true,
      "mode": "bridge_self_canary",
      "canary_required": true,
      "checks": ["powershell -NoProfile -ExecutionPolicy Bypass -File .\\driver.ps1 -SelfTest", "powershell -NoProfile -ExecutionPolicy Bypass -File .\\smoke.ps1", "Invoke-CanaryCycle -Force"],
      "rollback_plan": "Use stable ref + watchdog rollback if health/smoke/canary fails."
    }
  }
]
'@
  $controlPlaneExplicitResult = Add-ProjectBacklogFromMarker -Block $controlPlaneExplicitMarker -Channel 'main' -Source 'test' -SourceTaskId 'control-plane-explicit-lane-test'
  Assert-True ([int]$controlPlaneExplicitResult.created -eq 1) ("expected one explicit control-plane lane atom, got {0}" -f [int]$controlPlaneExplicitResult.created)
  $controlPlaneExplicitItem = Get-BacklogItemBySlug -Slug 'bridge-self-control-plane-explicit-lane-test' -Label 'explicit control-plane lane item'
  $controlPlaneExplicitLane = Assert-BacklogItemLane -Item $controlPlaneExplicitItem -Label 'explicit control-plane lane item' -ExpectedLane 'control-plane'
  Assert-True ($controlPlaneExplicitItem.PSObject.Properties.Name -contains 'parallel_group') 'explicit control-plane lane item missing top-level parallel_group'
  Assert-True ([string]$controlPlaneExplicitItem.parallel_group -eq 'pg-control-explicit') 'explicit control-plane lane item parallel_group was not preserved'
  Assert-True ([string]$controlPlaneExplicitItem.parallel_group -ne $controlPlaneExplicitLane) 'explicit control-plane lane item mixed lane with parallel_group'
  Assert-True (Test-WorkpackControlPlaneLane -Lane $controlPlaneExplicitLane) 'explicit control-plane lane was not recognized by Test-WorkpackControlPlaneLane'
  Assert-True (-not (Test-WorkpackControlPlaneLane -Lane ([string]$controlPlaneExplicitItem.parallel_group))) 'explicit control-plane parallel_group was incorrectly treated as control-plane lane'
  $controlPlaneExplicitMetadata = Test-WorkpackAtomMetadata -Atom $controlPlaneExplicitItem
  Assert-True ([bool]$controlPlaneExplicitMetadata.ok) ("explicit control-plane lane item did not pass workpack metadata validation: {0}" -f ((@($controlPlaneExplicitMetadata.blockers) + @($controlPlaneExplicitMetadata.missing)) -join ', '))

  $controlPlaneInferredMarker = @'
[
  {
    "slug": "bridge-self-control-plane-inferred-lane-test",
    "title": "Bridge self inferred control-plane lane test",
    "task": "Create a synthetic bridge self control-plane atom proving inferred control-plane touch sets lane without clobbering parallel_group.",
    "parallel_group": "pg-control-inferred",
    "files": ["lib/parallel.ps1"],
    "depends_on": [],
    "acceptance": ["Inferred control-plane markers normalize top-level lane correctly."],
    "checks": ["powershell -NoProfile -ExecutionPolicy Bypass -File .\\tools\\test-backlog-packer.ps1", "powershell -NoProfile -ExecutionPolicy Bypass -File .\\driver.ps1 -SelfTest", "powershell -NoProfile -ExecutionPolicy Bypass -File .\\smoke.ps1", "Invoke-CanaryCycle -Force"],
    "risk": "high",
    "serial_reason": "control_plane",
    "bridge_self_admission": {
      "admitted": true,
      "mode": "bridge_self_canary",
      "canary_required": true,
      "checks": ["powershell -NoProfile -ExecutionPolicy Bypass -File .\\driver.ps1 -SelfTest", "powershell -NoProfile -ExecutionPolicy Bypass -File .\\smoke.ps1", "Invoke-CanaryCycle -Force"],
      "rollback_plan": "Use stable ref + watchdog rollback if health/smoke/canary fails."
    }
  }
]
'@
  $controlPlaneInferredResult = Add-ProjectBacklogFromMarker -Block $controlPlaneInferredMarker -Channel 'main' -Source 'test' -SourceTaskId 'control-plane-inferred-lane-test'
  Assert-True ([int]$controlPlaneInferredResult.created -eq 1) ("expected one inferred control-plane lane atom, got {0}" -f [int]$controlPlaneInferredResult.created)
  $controlPlaneInferredItem = Get-BacklogItemBySlug -Slug 'bridge-self-control-plane-inferred-lane-test' -Label 'inferred control-plane lane item'
  $controlPlaneInferredLane = Assert-BacklogItemLane -Item $controlPlaneInferredItem -Label 'inferred control-plane lane item' -ExpectedLane 'control-plane'
  Assert-True ($controlPlaneInferredItem.PSObject.Properties.Name -contains 'parallel_group') 'inferred control-plane lane item missing top-level parallel_group'
  Assert-True ([string]$controlPlaneInferredItem.parallel_group -eq 'pg-control-inferred') 'inferred control-plane lane item parallel_group was not preserved'
  Assert-True ([string]$controlPlaneInferredItem.parallel_group -ne $controlPlaneInferredLane) 'inferred control-plane lane item mixed lane with parallel_group'
  Assert-True (Test-WorkpackControlPlaneLane -Lane $controlPlaneInferredLane) 'inferred control-plane lane was not recognized by Test-WorkpackControlPlaneLane'
  Assert-True (-not (Test-WorkpackControlPlaneLane -Lane ([string]$controlPlaneInferredItem.parallel_group))) 'inferred control-plane parallel_group was incorrectly treated as control-plane lane'
  $controlPlaneInferredMetadata = Test-WorkpackAtomMetadata -Atom $controlPlaneInferredItem
  Assert-True ([bool]$controlPlaneInferredMetadata.ok) ("inferred control-plane lane item did not pass workpack metadata validation: {0}" -f ((@($controlPlaneInferredMetadata.blockers) + @($controlPlaneInferredMetadata.missing)) -join ', '))

  $script:EffectiveChannel = 'external-project'
  $externalDir = Get-ChannelDir -Slug 'external-project'
  New-Item -ItemType Directory -Path $externalDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug 'external-project'), '', (New-Object System.Text.UTF8Encoding($false)))
  $externalMarker = @'
[
  {
    "slug": "external-project-backlog-test",
    "title": "External project backlog marker test",
    "task": "Create a synthetic external project backlog atom that proves legacy project channel behavior still uses project scope.",
    "files": ["src/app/page.tsx"],
    "depends_on": [],
    "acceptance": ["External PROJECT_BACKLOG marker still creates a project-scoped atom."],
    "checks": ["powershell -NoProfile -ExecutionPolicy Bypass -File .\\tools\\test-backlog-packer.ps1"],
    "severity": "info"
  }
]
'@
  $externalResult = Add-ProjectBacklogFromMarker -Block $externalMarker -Channel 'external-project' -Source 'test' -SourceTaskId 'external-test'
  Assert-True ([int]$externalResult.created -eq 1) ("expected one external project atom, got {0}" -f [int]$externalResult.created)
  $externalItem = @(Get-Backlog | Where-Object { [string]$_.slug -eq 'external-project-backlog-test' } | Select-Object -First 1)
  Assert-True ($externalItem.Count -eq 1) 'missing external project item'
  Assert-True ([string]$externalItem[0].status -eq 'approved') 'external project item is not approved'
  Assert-True ([string]$externalItem[0].scope -eq 'project') 'external project item scope changed'
  Assert-True ([string]$externalItem[0].project -eq 'external-project') 'external project item project slug changed'
  Assert-True (-not (@($externalItem[0].tags) -contains 'bridge-self')) 'external project item got bridge-self tag'
  $script:EffectiveChannel = 'main'

  Write-Host ('OK backlog packer: packed {0} items into {1} workpacks; marker and forbidden touch-set tests passed' -f [int]$run.packed_items, [int]$run.workpack_count)
} finally {
  try {
    $resolved = [System.IO.Path]::GetFullPath($script:TestBridgeRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
      Remove-Item -LiteralPath $resolved -Recurse -Force
    }
  } catch {}
}
