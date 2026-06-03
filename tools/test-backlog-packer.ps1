param()

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-backlog-packer-test-' + [guid]::NewGuid().ToString('N'))
$script:EffectiveChannel = 'main'

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
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
    "checks": ["powershell -NoProfile -ExecutionPolicy Bypass -File .\\tools\\test-backlog-packer.ps1"],
    "risk": "high",
    "serial_reason": "",
    "severity": "info"
  }
]
'@
  $mainResult = Add-ProjectBacklogFromMarker -Block $mainMarker -Channel 'main' -Source 'test' -SourceTaskId 'main-test'
  Assert-True ([int]$mainResult.created -eq 1) ("expected one main bridge-self atom, got {0}" -f [int]$mainResult.created)
  Assert-True (-not (@($mainResult.errors) -contains 'project backlog marker ignored outside project channel')) 'main channel marker was ignored'
  $mainItem = @(Get-Backlog | Where-Object { [string]$_.slug -eq 'bridge-self-project-backlog-test' } | Select-Object -First 1)
  Assert-True ($mainItem.Count -eq 1) 'missing main bridge-self item'
  Assert-True ([string]$mainItem[0].status -eq 'approved') 'main bridge-self item is not approved'
  Assert-True ([string]$mainItem[0].scope -eq 'bridge') 'main bridge-self item scope is not bridge'
  Assert-True (@($mainItem[0].tags) -contains 'project-autopilot') 'main bridge-self item missing project-autopilot tag'
  Assert-True (@($mainItem[0].tags) -contains 'bridge-self') 'main bridge-self item missing bridge-self tag'
  Assert-True (@($mainItem[0].tags) -contains 'atom') 'main bridge-self item missing atom tag'
  Assert-True ($mainItem[0].PSObject.Properties.Name -contains 'depends_on') 'main bridge-self item missing top-level depends_on'
  $dependsType = if ($null -eq $mainItem[0].depends_on) { '<null>' } else { $mainItem[0].depends_on.GetType().FullName }
  $dependsCount = if ($null -eq $mainItem[0].depends_on) { -1 } else { [int]$mainItem[0].depends_on.Count }
  Assert-True (($null -ne $mainItem[0].depends_on) -and ($mainItem[0].depends_on -is [System.Collections.IEnumerable]) -and ($mainItem[0].depends_on -isnot [string]) -and ($dependsCount -eq 0)) ("main bridge-self item depends_on is not an empty array: type={0} count={1} value={2}" -f $dependsType, $dependsCount, ([string]$mainItem[0].depends_on))
  Assert-True ($mainItem[0].PSObject.Properties.Name -contains 'files') 'main bridge-self item missing top-level files'
  Assert-True (@($mainItem[0].files) -contains 'lib/review-verdict.ps1') 'main bridge-self item files were not normalized'
  Assert-True (@($mainItem[0].acceptance) -contains 'Main PROJECT_BACKLOG marker creates an approved bridge-self atom.') 'main bridge-self item missing top-level acceptance'
  Assert-True (@($mainItem[0].acceptance_checks) -contains 'Main PROJECT_BACKLOG marker creates an approved bridge-self atom.') 'main bridge-self item missing acceptance_checks alias'
  Assert-True (@($mainItem[0].checks) -contains 'powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test-backlog-packer.ps1') 'main bridge-self item missing top-level checks'
  Assert-True (@($mainItem[0].verification_checks) -contains 'powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\test-backlog-packer.ps1') 'main bridge-self item missing verification_checks alias'
  Assert-True ([string]$mainItem[0].risk -eq 'high') 'main bridge-self item risk was not normalized from marker risk'
  Assert-True ($mainItem[0].PSObject.Properties.Name -contains 'serial_reason') 'main bridge-self item missing top-level serial_reason'
  $metadataResult = Test-WorkpackAtomMetadata -Atom $mainItem[0]
  Assert-True ([bool]$metadataResult.ok) ("main bridge-self item did not pass workpack metadata validation: {0}" -f ((@($metadataResult.blockers) + @($metadataResult.missing)) -join ', '))

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
