param()

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-autopilot-kind-test-' + [guid]::NewGuid().ToString('N'))
$script:EffectiveChannel = 'external-kind-test'

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-BridgeRoot { return $script:TestBridgeRoot }
function Get-EffectiveChannel { return $script:EffectiveChannel }
function Get-ChannelDir {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = $script:EffectiveChannel }
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
    backlogPackEnabled            = $false
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
  $root = Split-Path -Parent $PSScriptRoot
  $channelDir = Get-ChannelDir -Slug $script:EffectiveChannel
  New-Item -ItemType Directory -Path $channelDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug $script:EffectiveChannel), '', (New-Object System.Text.UTF8Encoding($false)))

  . (Join-Path $root 'lib\backlog.ps1')

  $autopilotText = [System.IO.File]::ReadAllText((Join-Path $root 'lib\backlog-autopilot.ps1'), [System.Text.Encoding]::UTF8)
  $coordStart = $autopilotText.IndexOf('function New-ProjectAutopilotCoordinatorTaskText', [System.StringComparison]::Ordinal)
  Assert-True ($coordStart -ge 0) 'coordinator prompt function not found'
  $coordEnd = $autopilotText.IndexOf('function Test-ProjectPlanApproved', $coordStart, [System.StringComparison]::Ordinal)
  Assert-True ($coordEnd -gt $coordStart) 'coordinator prompt end marker not found'
  $coordBlock = $autopilotText.Substring($coordStart, $coordEnd - $coordStart)
  Assert-True ($coordBlock.IndexOf('Order infra-first', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) 'coordinator prompt missing infra-first ordering rule'
  Assert-True ($coordBlock.IndexOf('"kind"', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) 'coordinator prompt missing kind field'
  Assert-True ($coordBlock.IndexOf('infra|feature|consolidation|planning', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) 'coordinator prompt missing kind enum values'

  $marker = @'
[
  {
    "slug": "infra-kind-persist-test",
    "title": "Infra kind persistence test",
    "task": "Create a synthetic project atom proving PROJECT_BACKLOG kind metadata is parsed and persisted for infrastructure work before consuming feature atoms.",
    "chapter": "chapter-kind",
    "wave": "wave-1",
    "kind": "infra",
    "parallel_group": "shared-contracts",
    "files": ["src/contracts/schema.ts"],
    "depends_on": [],
    "acceptance": ["Persisted atom exposes kind=infra as top-level metadata."],
    "checks": ["powershell -NoProfile -ExecutionPolicy Bypass -File .\\tools\\test-project-autopilot-atom-kind.ps1"],
    "risk": "normal",
    "serial_reason": ""
  },
  {
    "slug": "default-kind-persist-test",
    "title": "Default kind persistence test",
    "task": "Create a synthetic project atom proving PROJECT_BACKLOG kind metadata defaults to feature when the optional field is omitted.",
    "chapter": "chapter-kind",
    "wave": "wave-1",
    "parallel_group": "feature-work",
    "files": ["src/features/default-kind.ts"],
    "depends_on": [],
    "acceptance": ["Persisted atom exposes kind=feature when the source atom omits kind."],
    "checks": ["powershell -NoProfile -ExecutionPolicy Bypass -File .\\tools\\test-project-autopilot-atom-kind.ps1"],
    "risk": "normal",
    "serial_reason": ""
  }
]
'@

  $result = Add-ProjectBacklogFromMarker -Block $marker -Channel $script:EffectiveChannel -Source 'test' -SourceTaskId 'kind-test'
  Assert-True ([int]$result.created -eq 2) ("expected two created atoms, got {0}" -f [int]$result.created)
  Assert-True ([int]$result.skipped -eq 0) ("expected zero skipped atoms, got {0}" -f [int]$result.skipped)
  Assert-True (@($result.errors).Count -eq 0) ("unexpected ingest errors: {0}" -f (@($result.errors) -join '; '))

  $items = @(Get-Backlog | Where-Object { [string]$_.slug -eq 'infra-kind-persist-test' })
  Assert-True ($items.Count -eq 1) ("expected one persisted atom by slug, got {0}" -f $items.Count)
  $item = $items[0]
  Assert-True ($item.PSObject.Properties.Name -contains 'kind') 'persisted atom missing top-level kind'
  Assert-True ([string]$item.kind -eq 'infra') ("persisted top-level kind mismatch: {0}" -f [string]$item.kind)
  Assert-True ($item.PSObject.Properties.Name -contains 'autopilot_meta') 'persisted atom missing autopilot_meta'
  Assert-True ([string]$item.autopilot_meta.kind -eq 'infra') ("persisted autopilot_meta.kind mismatch: {0}" -f [string]$item.autopilot_meta.kind)
  Assert-True (([string]$item.text).IndexOf('Kind: infra', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) 'persisted atom text missing Kind detail'

  $defaultItems = @(Get-Backlog | Where-Object { [string]$_.slug -eq 'default-kind-persist-test' })
  Assert-True ($defaultItems.Count -eq 1) ("expected one persisted default-kind atom by slug, got {0}" -f $defaultItems.Count)
  $defaultItem = $defaultItems[0]
  Assert-True ($defaultItem.PSObject.Properties.Name -contains 'kind') 'default-kind atom missing top-level kind'
  Assert-True ([string]$defaultItem.kind -eq 'feature') ("default top-level kind mismatch: {0}" -f [string]$defaultItem.kind)
  Assert-True ([string]$defaultItem.autopilot_meta.kind -eq 'feature') ("default autopilot_meta.kind mismatch: {0}" -f [string]$defaultItem.autopilot_meta.kind)

  Write-Output 'PROJECT AUTOPILOT ATOM KIND TEST OK'
} finally {
  if (Test-Path -LiteralPath $script:TestBridgeRoot) {
    Remove-Item -LiteralPath $script:TestBridgeRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
