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
  Assert-AuditBacklogFilingTest 'deep-truth-bucket-empty-reply' ([string]$truth.deepRequiredRoleFailureReasons['security'] -eq 'empty_llm_reply') ("bucket={0}" -f $truth.deepRequiredRoleFailureReasons['security'])
  Assert-AuditBacklogFilingTest 'deep-truth-bucket-missing-output' ([string]$truth.deepRequiredRoleFailureReasons['functional'] -eq 'missing_output_file') ("bucket={0}" -f $truth.deepRequiredRoleFailureReasons['functional'])

  $truthBuckets = Get-BridgeAuditDeepTruth -DeepResult ([pscustomobject]@{
    deepStatus = 'ok'
    deepRequiredSlices = @('security-model','functional-model','runtime-incident-model')
    deepCoverageGap = @('security-model','functional-model','runtime-incident-model')
    deepModelAgentResults = @(
      [pscustomobject]@{ role = 'security-model'; status = 'error'; errors = @('timeout'); findings = @() },
      [pscustomobject]@{ role = 'functional-model'; status = 'error'; errors = @('empty_llm_reply'); findings = @() },
      [pscustomobject]@{ role = 'runtime-incident-model'; status = 'error'; errors = @('aborted_by_quorum'); findings = @() }
    )
  })
  Assert-AuditBacklogFilingTest 'reason-bucket-timeout' ([string]$truthBuckets.deepRequiredRoleFailureReasons['security-model'] -eq 'timeout') ("bucket={0}" -f $truthBuckets.deepRequiredRoleFailureReasons['security-model'])
  Assert-AuditBacklogFilingTest 'reason-bucket-empty-reply' ([string]$truthBuckets.deepRequiredRoleFailureReasons['functional-model'] -eq 'empty_llm_reply') ("bucket={0}" -f $truthBuckets.deepRequiredRoleFailureReasons['functional-model'])
  Assert-AuditBacklogFilingTest 'reason-bucket-aborted' ([string]$truthBuckets.deepRequiredRoleFailureReasons['runtime-incident-model'] -eq 'aborted_by_quorum') ("bucket={0}" -f $truthBuckets.deepRequiredRoleFailureReasons['runtime-incident-model'])

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
  Assert-AuditBacklogFilingTest 'complete-report-json-bucket-empty-reply' ([string]$writtenReport.metadata.deep_required_role_failure_reasons.security -eq 'empty_llm_reply') ("bucket={0}" -f $writtenReport.metadata.deep_required_role_failure_reasons.security)
  Assert-AuditBacklogFilingTest 'complete-report-json-bucket-missing-output' ([string]$writtenReport.metadata.deep_required_role_failure_reasons.functional -eq 'missing_output_file') ("bucket={0}" -f $writtenReport.metadata.deep_required_role_failure_reasons.functional)

  $reportPathBuckets = Join-Path $bridgeRoot 'audit\truth-report-buckets.json'
  $completeBuckets = Complete-BridgeAuditReport `
    -Root $bridgeRoot `
    -AuditCtx $ctx `
    -Report ([pscustomobject]@{ runtime_sec = 0.1; metadata = @{} }) `
    -Paths ([pscustomobject]@{ json = $reportPathBuckets; md = (Join-Path $bridgeRoot 'audit\truth-report-buckets.md') }) `
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
        [pscustomobject]@{ role = 'security-model'; status = 'error'; errors = @('json_parse_failed'); findings = @() },
        [pscustomobject]@{ role = 'functional-model'; status = 'error'; errors = @('missing_output_file'); findings = @() }
      )
      deepRequiredSlices = @('security-model','functional-model')
      deepCoverageGap = @('security-model','functional-model')
      deepRuntimeSec = 0.2
      deepWatchdogFired = $false
      deepModelAgentCount = 0
      deepCodexCount = 0
      deepClaudeCount = 0
      deepFiled = 0
    }) `
    -DeepAuditTimeoutSec 1 `
    -Errors ([ref](New-Object 'System.Collections.Generic.List[string]'))
  Assert-AuditBacklogFilingTest 'complete-report-buckets-partial' ([string]$completeBuckets.status -eq 'partial') ("status={0}" -f $completeBuckets.status)
  $writtenBuckets = Get-Content -LiteralPath $reportPathBuckets -Raw -Encoding UTF8 | ConvertFrom-Json
  Assert-AuditBacklogFilingTest 'report-metadata-json-parse-failed' ([string]$writtenBuckets.metadata.deep_required_role_failure_reasons.'security-model' -eq 'json_parse_failed') ("bucket={0}" -f $writtenBuckets.metadata.deep_required_role_failure_reasons.'security-model')
  Assert-AuditBacklogFilingTest 'report-metadata-missing-output' ([string]$writtenBuckets.metadata.deep_required_role_failure_reasons.'functional-model' -eq 'missing_output_file') ("bucket={0}" -f $writtenBuckets.metadata.deep_required_role_failure_reasons.'functional-model')

  $mdPathBuckets = Join-Path $bridgeRoot 'audit\truth-report-buckets-md.md'
  [System.IO.File]::WriteAllText($mdPathBuckets, "# Report`r`n", (New-Object System.Text.UTF8Encoding($false)))
  $mdErrors = New-Object 'System.Collections.Generic.List[string]'
  Add-DeepAuditSectionsToMarkdown `
    -Paths ([pscustomobject]@{ md = $mdPathBuckets }) `
    -DeepStatus 'deep_failed' `
    -DeepRuntimeSec 0.2 `
    -DeepAuditTimeoutSec 1 `
    -DeepWatchdogFired $false `
    -DeepModelAgentResults @([pscustomobject]@{ role = 'security-model'; model = 'test'; status = 'error'; errors = @('timeout'); findings = @() }) `
    -DeepCodexResult $null `
    -DeepClaudeResult $null `
    -DeepCodexCount 0 `
    -DeepClaudeCount 0 `
    -DeepRequiredRoleFailureReasons @{ 'security-model' = 'timeout' } `
    -Errors ([ref]$mdErrors)
  $mdTextBuckets = Get-Content -LiteralPath $mdPathBuckets -Raw -Encoding UTF8
  Assert-AuditBacklogFilingTest 'markdown-required-role-reasons' ($mdTextBuckets -match 'Required role failure reasons: `security-model`=timeout') $mdTextBuckets
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
