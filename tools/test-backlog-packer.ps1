param()

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-backlog-packer-test-' + [guid]::NewGuid().ToString('N'))

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-BridgeRoot { return $script:TestBridgeRoot }
function Get-EffectiveChannel { return 'main' }
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

  Write-Host ('OK backlog packer: packed {0} items into {1} workpacks' -f [int]$run.packed_items, [int]$run.workpack_count)
} finally {
  try {
    $resolved = [System.IO.Path]::GetFullPath($script:TestBridgeRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
      Remove-Item -LiteralPath $resolved -Recurse -Force
    }
  } catch {}
}
