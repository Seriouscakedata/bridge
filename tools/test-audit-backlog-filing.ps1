[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $Utf8NoBom } catch {}

$script:Failures = 0
function Assert-AuditBacklogFilingTest {
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
$bridgeRoot = Join-Path $tempBase ("bridge-audit-filing-" + [guid]::NewGuid().ToString('N'))
$projectRoot = Join-Path $tempBase ("bridge audit filing project " + [guid]::NewGuid().ToString('N'))
$oldScopeRoot = $env:AUDIT_SCOPE_TEST_ROOT

try {
  New-Item -ItemType Directory -Path (Join-Path $bridgeRoot 'lib') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $bridgeRoot 'channels\scopechan') -Force | Out-Null
  New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null
  $env:AUDIT_SCOPE_TEST_ROOT = $bridgeRoot

  $commonContent = @'
$script:AuditScopePinnedChannel = 'main'
function Set-PinnedChannel {
  param([string]$Slug)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = 'main' }
  $script:AuditScopePinnedChannel = $Slug
}
function Get-BacklogPath {
  $channelDir = Join-Path (Join-Path $env:AUDIT_SCOPE_TEST_ROOT 'channels') $script:AuditScopePinnedChannel
  if (-not (Test-Path -LiteralPath $channelDir)) { New-Item -ItemType Directory -Path $channelDir -Force | Out-Null }
  return (Join-Path $channelDir 'backlog.jsonl')
}
function Add-Idea {
  param(
    [string]$Text,
    [string]$From,
    [string[]]$Tags,
    [string]$Status,
    [string]$Severity,
    [string]$Project,
    [string]$Scope,
    [switch]$SkipCurator
  )
  $path = Get-BacklogPath
  $item = [ordered]@{
    id       = ('audit-scope-' + [guid]::NewGuid().ToString('N'))
    text     = $Text
    from     = $From
    tags     = @($Tags)
    status   = $Status
    severity = $Severity
    project  = $Project
    scope    = $Scope
  }
  [System.IO.File]::AppendAllText($path, (($item | ConvertTo-Json -Compress -Depth 6) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  return $item.id
}
'@
  [System.IO.File]::WriteAllText((Join-Path $bridgeRoot 'lib\common.ps1'), $commonContent, $Utf8NoBom)

  $helperErrors = New-Object 'System.Collections.Generic.List[string]'
  $helpersReady = Initialize-AuditBacklogHelpers -Root $bridgeRoot -ResolvedChannel 'scopechan' -Errors ([ref]$helperErrors)
  Assert-AuditBacklogFilingTest 'helpers-ready' ([bool]$helpersReady) (($helperErrors.ToArray()) -join '; ')
  Assert-AuditBacklogFilingTest 'add-idea-visible-after-helper' ([bool](Get-Command Add-Idea -ErrorAction SilentlyContinue))
  Assert-AuditBacklogFilingTest 'get-backlogpath-visible-after-helper' ([bool](Get-Command Get-BacklogPath -ErrorAction SilentlyContinue))

  $ctx = New-AuditContext -BridgePath $bridgeRoot -Channel 'scopechan' -ProjectRoot $projectRoot
  $finding = [pscustomobject]@{
    severity = 'critical'
    source   = 'functional'
    title    = 'Synthetic scope-loss regression'
    area     = 'tools/test-audit-backlog-filing.ps1:1'
    detail   = 'Add-Idea must remain callable inside Add-AuditCriticalsToBacklog closure.'
  }
  $added = Add-AuditCriticalsToBacklog -BridgePath $bridgeRoot -Findings @($finding) -AuditContext $ctx
  Assert-AuditBacklogFilingTest 'critical-filed-through-audit-helper' ([int]$added -eq 1) ("added={0}" -f $added)

  $backlogPath = Join-Path $bridgeRoot 'channels\scopechan\backlog.jsonl'
  $lines = @([System.IO.File]::ReadAllLines($backlogPath, $Utf8NoBom) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  Assert-AuditBacklogFilingTest 'temp-backlog-one-row' ($lines.Count -eq 1) ("count={0}" -f $lines.Count)
  if ($lines.Count -gt 0) {
    $item = $lines[0] | ConvertFrom-Json
    Assert-AuditBacklogFilingTest 'temp-backlog-project-channel' ([string]$item.project -eq 'scopechan') ("project={0}" -f $item.project)
    Assert-AuditBacklogFilingTest 'temp-backlog-held-project-scope' ([string]$item.status -eq 'held' -and [string]$item.scope -eq 'project') ("status={0}; scope={1}" -f $item.status,$item.scope)
  }

  $truth = Get-BridgeAuditDeepTruth -DeepResult ([pscustomobject]@{
    deepStatus = 'ok'
    deepRequiredSlices = @('security', 'functional')
    deepCoverageGap = @('security', 'functional')
    deepModelAgentResults = @(
      [pscustomobject]@{ role = 'security'; status = 'error'; errors = @('empty_llm_reply'); findings = @() },
      [pscustomobject]@{ role = 'functional'; status = 'error'; errors = @('missing_output_file'); findings = @() }
    )
  })
  Assert-AuditBacklogFilingTest 'deep-truth-final-partial' ([string]$truth.finalStatus -eq 'partial') ("status={0}" -f $truth.finalStatus)
  Assert-AuditBacklogFilingTest 'deep-truth-status-failed' ([string]$truth.deepStatus -eq 'deep_failed') ("deep={0}" -f $truth.deepStatus)
  Assert-AuditBacklogFilingTest 'deep-truth-required-failure-count' ([int]$truth.deepAgentRequiredFailures -eq 2) ("count={0}" -f $truth.deepAgentRequiredFailures)
  Assert-AuditBacklogFilingTest 'deep-truth-empty-reply-reason' ((@($truth.reasons) -join '; ') -match 'empty_llm_reply')

  $reportErrors = New-Object 'System.Collections.Generic.List[string]'
  $reportPath = Join-Path $bridgeRoot 'audit\truth-report.json'
  $complete = Complete-BridgeAuditReport `
    -Root $bridgeRoot `
    -AuditCtx $ctx `
    -Report ([pscustomobject]@{ runtime_sec = 0.1; metadata = @{} }) `
    -Paths ([pscustomobject]@{ json = $reportPath; md = (Join-Path $bridgeRoot 'audit\truth-report.md') }) `
    -StaticResult ([pscustomobject]@{
      secCounts = [pscustomobject]@{ critical = 0; warning = 0; info = 0 }
      fncCounts = [pscustomobject]@{ critical = 0; warning = 0; info = 0 }
    }) `
    -Filed 0 `
    -DeepResult ([pscustomobject]@{
      deepStatus = 'ok'
      deepCodexResult = $null
      deepClaudeResult = $null
      deepModelAgentResults = @(
        [pscustomobject]@{ role = 'security'; status = 'error'; errors = @('empty_llm_reply'); findings = @() },
        [pscustomobject]@{ role = 'functional'; status = 'error'; errors = @('missing_output_file'); findings = @() }
      )
      deepRequiredSlices = @('security', 'functional')
      deepCoverageGap = @('security', 'functional')
      deepRuntimeSec = 0.2
      deepWatchdogFired = $false
      deepModelAgentCount = 0
      deepCodexCount = 0
      deepClaudeCount = 0
      deepFiled = 0
    }) `
    -DeepAuditTimeoutSec 1 `
    -Errors ([ref]$reportErrors)
  Assert-AuditBacklogFilingTest 'complete-report-partial' ([string]$complete.status -eq 'partial') ("status={0}" -f $complete.status)
  Assert-AuditBacklogFilingTest 'complete-report-error-reason' ((@($complete.errors) -join '; ') -match 'required slices failed' -and (@($complete.errors) -join '; ') -match 'empty_llm_reply')
  $writtenReport = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-AuditBacklogFilingTest 'complete-report-json-deep-failed' ([string]$writtenReport.metadata.deep_status -eq 'deep_failed') ("deep={0}" -f $writtenReport.metadata.deep_status)
  Assert-AuditBacklogFilingTest 'complete-report-json-counters' ([int]$writtenReport.metadata.deep_agent_error_count -eq 2 -and [int]$writtenReport.metadata.deep_agent_required_failures -eq 2) ("errors={0}; failures={1}" -f $writtenReport.metadata.deep_agent_error_count,$writtenReport.metadata.deep_agent_required_failures)
} finally {
  if ($null -eq $oldScopeRoot) { Remove-Item Env:\AUDIT_SCOPE_TEST_ROOT -ErrorAction SilentlyContinue } else { $env:AUDIT_SCOPE_TEST_ROOT = $oldScopeRoot }
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
  Write-Host ("audit-backlog-filing tests failed: {0}" -f $script:Failures)
  exit 1
}
Write-Host 'audit-backlog-filing tests passed'
