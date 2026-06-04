[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $Utf8NoBom } catch {}

$script:Failures = 0
function Assert-AuditTest {
  param([string]$Name, [bool]$Condition, [string]$Detail = '')
  if ($Condition) {
    Write-Host ("PASS {0}" -f $Name)
  } else {
    $script:Failures++
    Write-Host ("FAIL {0}{1}" -f $Name, $(if ($Detail) { ': ' + $Detail } else { '' }))
  }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$auditScript = Join-Path $repoRoot 'tools\audit.ps1'
. $auditScript

$tempBase = [System.IO.Path]::GetTempPath()
$bridgeRoot = Join-Path $tempBase ("bridge-audit-context-" + [guid]::NewGuid().ToString('N'))
$projectRoot = Join-Path $tempBase ("bridge project target " + [guid]::NewGuid().ToString('N'))

try {
  New-Item -ItemType Directory -Path $bridgeRoot -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $bridgeRoot 'channels\main') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $bridgeRoot 'channels\travel') -Force | Out-Null
  New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $bridgeRoot 'channels\travel\backlog.jsonl'), '', $Utf8NoBom)

  $script:AuditTestBridgeRoot = $bridgeRoot
  $script:AuditTestPinnedChannel = 'main'
  function Get-BridgeRoot { return $script:AuditTestBridgeRoot }
  function Get-EffectiveChannel { return $script:AuditTestPinnedChannel }
  function Set-PinnedChannel {
    param([string]$Slug)
    if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = 'main' }
    $script:AuditTestPinnedChannel = $Slug
  }
  function Get-ChannelDir {
    param([string]$Slug = $null)
    if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = Get-EffectiveChannel }
    return (Join-Path (Join-Path $script:AuditTestBridgeRoot 'channels') $Slug)
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
      backlogPackDedupeEnabled      = $true
      backlogPackDedupeMinGroupSize = 2
    }
  }
  . (Join-Path $repoRoot 'lib\backlog.ps1')

  $mainCtx = New-AuditContext -BridgePath $bridgeRoot -Channel 'main' -ProjectRoot $bridgeRoot
  Assert-AuditTest 'main-kind-bridge' ([string]$mainCtx.kind -eq 'bridge')
  Assert-AuditTest 'main-report-root' (([string]$mainCtx.report_root) -eq (Join-Path $bridgeRoot 'audit'))
  Assert-AuditTest 'main-backlog-channel' ([string]$mainCtx.backlog_channel -eq 'main')

  $projectCtx = New-AuditContext -BridgePath $bridgeRoot -Channel 'travel' -ProjectRoot $projectRoot
  Assert-AuditTest 'project-kind' ([string]$projectCtx.kind -eq 'project')
  Assert-AuditTest 'project-report-root' (([string]$projectCtx.report_root) -eq (Join-Path $bridgeRoot 'channels\travel\audit'))
  Assert-AuditTest 'project-target-root-space-safe' (([string]$projectCtx.target_root) -eq ([System.IO.Path]::GetFullPath($projectRoot)))

  $quoted = Format-AuditNativeArg -Value $projectRoot
  Assert-AuditTest 'native-arg-quotes-space-path' ($quoted.StartsWith('"') -and $quoted.EndsWith('"') -and $quoted.Contains(' '))

  $finding = [pscustomobject]@{
    severity = 'critical'
    source   = 'functional'
    title    = 'Synthetic project issue'
    area     = 'tests'
    detail   = 'Synthetic detail for backlog routing.'
  }
  $added = Add-AuditCriticalsToBacklog -BridgePath $bridgeRoot -Findings @($finding) -AuditContext $projectCtx
  Assert-AuditTest 'project-critical-added' ([int]$added -eq 1)
  $backlogPath = Join-Path $bridgeRoot 'channels\travel\backlog.jsonl'
  $line = @([System.IO.File]::ReadAllLines($backlogPath, $Utf8NoBom) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })[0]
  $item = $line | ConvertFrom-Json
  Assert-AuditTest 'project-critical-held' ([string]$item.status -eq 'held')
  Assert-AuditTest 'project-critical-project' ([string]$item.project -eq 'travel')
  Assert-AuditTest 'project-critical-scope' ([string]$item.scope -eq 'project')
  $addedAgain = Add-AuditCriticalsToBacklog -BridgePath $bridgeRoot -Findings @($finding) -AuditContext $projectCtx
  Assert-AuditTest 'project-critical-exact-dedup' ([int]$addedAgain -eq 0)
  $projectCriticalLines = @([System.IO.File]::ReadAllLines($backlogPath, $Utf8NoBom) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  Assert-AuditTest 'project-critical-exact-dedup-count' ($projectCriticalLines.Count -eq 1) ("count={0}" -f $projectCriticalLines.Count)

  $report = [pscustomobject]@{
    generated_at = (Get-Date).ToUniversalTime().ToString('o')
    security_counts = [pscustomobject]@{ critical = 0; warning = 0; info = 0 }
    functional_counts = [pscustomobject]@{ critical = 0; warning = 1; info = 0 }
    runtime_sec = 0.1
    audit_kind = 'project'
    channel = 'travel'
    target_root = $projectRoot
    report_root = [string]$projectCtx.report_root
    audit_context = $projectCtx
    findings = @([pscustomobject]@{ severity = 'warning'; title = 'Synthetic warning'; source = 'functional'; area = 'project'; detail = 'ok' })
    errors = @()
  }
  $paths = Write-AuditReports -BridgePath $bridgeRoot -Report $report -AuditContext $projectCtx
  Assert-AuditTest 'project-report-json-path' ([string]$paths.json -like (Join-Path $bridgeRoot 'channels\travel\audit\*.json'))
  Assert-AuditTest 'project-report-md-exists' (Test-Path -LiteralPath ([string]$paths.md) -PathType Leaf)
} finally {
  foreach ($p in @($bridgeRoot, $projectRoot)) {
    try {
      $full = [System.IO.Path]::GetFullPath($p)
      if ($full.StartsWith($tempBase, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full)) {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
      }
    } catch {}
  }
}

if ($script:Failures -gt 0) {
  Write-Host ("audit-context tests failed: {0}" -f $script:Failures)
  exit 1
}
Write-Host 'audit-context tests passed'
