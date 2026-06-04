param()

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-backlog-dedupe-test-' + [guid]::NewGuid().ToString('N'))
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
    backlogPackDedupeEnabled      = $true
    backlogPackDedupeMinGroupSize = 2
  }
}

function Get-TestItemById {
  param([string]$Id)
  return @(Get-Backlog | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)[0]
}

function New-TestBacklogItem {
  param(
    [string]$Id,
    [string]$Text,
    [string]$From,
    [string[]]$Tags,
    [string]$Status,
    [string]$Severity,
    [string]$RootKey
  )
  return [pscustomobject][ordered]@{
    id = $Id
    ts = (Get-Date).ToUniversalTime().ToString('o')
    from = $From
    status = $Status
    tags = @($Tags)
    attempts = 0
    score = 0.0
    project = ''
    scope = 'bridge'
    severity = $Severity
    text = $Text
    workpack_root_cause_key = $RootKey
  }
}

try {
  $mainDir = Get-ChannelDir -Slug 'main'
  New-Item -ItemType Directory -Path $mainDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug 'main'), '', (New-Object System.Text.UTF8Encoding($false)))

  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\backlog.ps1')

  $rootKey = 'file:lib/circuit-breaker.ps1'
  # The intake gate now prevents new approved audit duplicates from being appended
  # through Add-Idea. This test intentionally creates a dirty historical backlog
  # directly so the post-facto compactor remains covered.
  $idKeep = [guid]::NewGuid().ToString('N')
  $idDupA = [guid]::NewGuid().ToString('N')
  $idDupB = [guid]::NewGuid().ToString('N')
  $idOtherKind = [guid]::NewGuid().ToString('N')
  $idManual = [guid]::NewGuid().ToString('N')
  $idRunning = [guid]::NewGuid().ToString('N')
  $idUntyped = [guid]::NewGuid().ToString('N')

  Save-Backlog @(
    (New-TestBacklogItem -Id $idKeep -Text '[deep-agent/runtime-incident-model/deepseek-v4-flash] orphan-restart -- Restart attribution is ambiguous in restarts.jsonl.' -From 'audit-deep-agent' -Tags @('audit','deep-audit') -Status 'approved' -Severity 'critical' -RootKey $rootKey),
    (New-TestBacklogItem -Id $idDupA -Text '[deep-agent/runtime-incident-model/claude-opus] orphan_restart -- Same restart attribution finding in different words.' -From 'audit-deep-agent' -Tags @('audit','deep-audit') -Status 'new' -Severity 'warning' -RootKey $rootKey),
    (New-TestBacklogItem -Id $idDupB -Text '[audit/safety] orphan-restart (lib/circuit-breaker.ps1:42) - Same root cause reported by another audit pass.' -From 'audit' -Tags @('audit') -Status 'approved' -Severity 'info' -RootKey $rootKey),
    (New-TestBacklogItem -Id $idOtherKind -Text '[deep-agent/runtime-incident-model/deepseek-v4-flash] restart-loop -- Different typed finding in the same file must survive.' -From 'audit-deep-agent' -Tags @('audit') -Status 'approved' -Severity 'critical' -RootKey $rootKey),
    (New-TestBacklogItem -Id $idManual -Text '[deep-agent/runtime-incident-model/deepseek-v4-flash] orphan-restart -- Manual/operator task with audit-looking text must survive without audit source.' -From 'operator' -Tags @('manual') -Status 'approved' -Severity 'critical' -RootKey $rootKey),
    (New-TestBacklogItem -Id $idRunning -Text '[deep-agent/runtime-incident-model/deepseek-v4-flash] orphan-restart -- Running item is not modified by the compactor.' -From 'audit-deep-agent' -Tags @('audit') -Status 'running' -Severity 'critical' -RootKey $rootKey),
    (New-TestBacklogItem -Id $idUntyped -Text '[audit/ui] surface web/index.html status badge for duplicate backlog telemetry.' -From 'audit' -Tags @('audit') -Status 'approved' -Severity 'info' -RootKey $rootKey)
  )

  Assert-True ((Get-BacklogDuplicateFindingType -Item (Get-TestItemById -Id $idKeep)) -eq 'orphan-restart') 'expected orphan-restart finding type'
  Assert-True ((Get-BacklogDuplicateFindingType -Item (Get-TestItemById -Id $idDupA)) -eq 'orphan-restart') 'expected underscore finding type to canonicalize'
  Assert-True ((Get-BacklogDuplicateFindingType -Item (Get-TestItemById -Id $idUntyped)) -eq '') 'expected broad prose audit item to be skipped'

  $run = Invoke-BacklogDuplicateCompactor -Reason @('test')
  Assert-True ([bool]$run.ran) 'expected compactor to run'
  Assert-True ([int]$run.duplicates_rejected -eq 2) ("expected 2 rejected duplicates, got {0}" -f [int]$run.duplicates_rejected)
  Assert-True ([int]$run.group_count -eq 1) ("expected 1 duplicate group, got {0}" -f [int]$run.group_count)

  $keep = Get-TestItemById -Id $idKeep
  $dupA = Get-TestItemById -Id $idDupA
  $dupB = Get-TestItemById -Id $idDupB
  $otherKind = Get-TestItemById -Id $idOtherKind
  $manual = Get-TestItemById -Id $idManual
  $running = Get-TestItemById -Id $idRunning
  $untyped = Get-TestItemById -Id $idUntyped

  Assert-True ([string]$keep.status -eq 'approved') 'representative should remain approved'
  foreach ($dup in @($dupA,$dupB)) {
    Assert-True ([string]$dup.status -eq 'rejected') 'duplicate should be rejected'
    Assert-True ([string]$dup.duplicate_of -eq [string]$idKeep) 'duplicate_of should point at representative'
    Assert-True ([string]$dup.resolved_reason -eq 'duplicate-of-root-cause') 'duplicate resolved_reason missing'
    Assert-True ([string]$dup.auto_curator.model -eq 'backlog-compactor') 'duplicate auto_curator model missing'
  }
  Assert-True ([string]$otherKind.status -eq 'approved') 'different finding type should survive'
  Assert-True ([string]$manual.status -eq 'approved') 'manual non-audit item should survive'
  Assert-True ([string]$running.status -eq 'running') 'running item should not be modified'
  Assert-True ([string]$untyped.status -eq 'approved') 'untyped broad audit item should survive'

  $logPath = Join-Path (Join-Path $script:TestBridgeRoot 'control') 'curator-decisions.jsonl'
  Assert-True (Test-Path -LiteralPath $logPath) 'expected compactor log'
  $logRaw = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
  Assert-True ($logRaw -match '"action":"backlog-duplicate-compact"') 'expected duplicate compact log action'

  $second = Invoke-BacklogDuplicateCompactor -Reason @('test-second')
  Assert-True ([int]$second.duplicates_rejected -eq 0) 'second compactor pass should be idempotent'

  Write-Host 'OK backlog duplicate compactor: root-cause audit duplicates rejected, unrelated tasks preserved'
} finally {
  try {
    $resolved = [System.IO.Path]::GetFullPath($script:TestBridgeRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
      Remove-Item -LiteralPath $resolved -Recurse -Force
    }
  } catch {}
}
