param()

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-backlog-intake-test-' + [guid]::NewGuid().ToString('N'))
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

function Get-TestItemById {
  param([string]$Id)
  return @(Get-Backlog | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)[0]
}

function Write-TestFile {
  param([string]$RelativePath, [string]$Content)
  $path = Join-Path $script:TestBridgeRoot ($RelativePath -replace '/', '\')
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::WriteAllText($path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

try {
  $mainDir = Get-ChannelDir -Slug 'main'
  New-Item -ItemType Directory -Path $mainDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug 'main'), '', (New-Object System.Text.UTF8Encoding($false)))

  Write-TestFile -RelativePath 'lib/circuit-breaker.ps1' -Content "function Invoke-CircuitBreaker { 'ok' }`n"
  Write-TestFile -RelativePath 'lib/dynamic-text.ps1' -Content "`$pattern = 'iex'`n"
  Write-TestFile -RelativePath 'lib/comment-secret.ps1' -Content "# password = 'supersecret'`n"
  Write-TestFile -RelativePath 'lib/real-dynamic.ps1' -Content "Invoke-Expression `$cmd`n"
  Write-TestFile -RelativePath 'lib/weak-security.ps1' -Content "function Test-Auth { return `$true }`n"

  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\backlog.ps1')

  $manualId = Add-Idea -Text '[deep-agent/security] unsafe_dynamic (lib/dynamic-text.ps1:1) -- operator-approved manual task should not be gated.' -From 'operator' -Tags @('manual') -Status 'approved' -Severity 'critical' -SkipCurator
  $manual = Get-TestItemById -Id $manualId
  Assert-True ([string]$manual.status -eq 'approved') 'manual item should remain approved'
  Assert-True (-not ($manual.PSObject.Properties.Name -contains 'intake_gate')) 'manual item should not receive intake_gate metadata'

  $keepId = Add-Idea -Text '[deep-agent/runtime-incident-model/deepseek-v4-flash] orphan-restart -- Restart attribution has a real target. files: lib/circuit-breaker.ps1' -From 'audit-deep-agent' -Tags @('audit','deep-audit') -Status 'approved' -Severity 'critical' -SkipCurator
  $keep = Get-TestItemById -Id $keepId
  Assert-True ([string]$keep.status -eq 'approved') 'audit finding with code target should remain approved'
  Assert-True ([string]$keep.intake_gate.action -eq 'allow') 'expected intake allow metadata'

  $dupId = Add-Idea -Text '[deep-agent/runtime-incident-model/claude-opus] orphan_restart -- Same restart attribution finding from another model. files: lib/circuit-breaker.ps1' -From 'audit-deep-agent' -Tags @('audit','deep-audit') -Status 'approved' -Severity 'warning' -SkipCurator
  Assert-True ([string]$dupId -eq [string]$keepId) 'duplicate audit finding should return existing id'
  $afterDup = @(Get-Backlog | Where-Object { [string]$_.text -match 'orphan[-_]restart' })
  Assert-True ($afterDup.Count -eq 1) ("duplicate audit finding should not append a second row, got {0}" -f $afterDup.Count)

  $falseDynamicId = Add-Idea -Text '[deep-codex/security] unsafe_dynamic (lib/dynamic-text.ps1:1) -- Audit matched text iex but this is not dynamic execution.' -From 'audit-deep-codex' -Tags @('audit','deep-audit','security') -Status 'approved' -Severity 'critical' -SkipCurator
  $falseDynamic = Get-TestItemById -Id $falseDynamicId
  Assert-True ([string]$falseDynamic.status -eq 'auto-dropped') 'false dynamic execution should be auto-dropped'
  Assert-True ([string]$falseDynamic.auto_curator.model -eq 'deterministic-intake-v1') 'false dynamic drop should be attributed to intake gate'
  Assert-True ([string]$falseDynamic.intake_gate.evidence.security_detail -eq 'no-dynamic-exec') 'false dynamic evidence detail missing'

  $commentSecretId = Add-Idea -Text '[deep-codex/security] hardcoded-credentials (lib/comment-secret.ps1:1) -- Comment mentions password.' -From 'audit-deep-codex' -Tags @('audit','deep-audit','security') -Status 'approved' -Severity 'critical' -SkipCurator
  $commentSecret = Get-TestItemById -Id $commentSecretId
  Assert-True ([string]$commentSecret.status -eq 'auto-dropped') 'comment-only secret should be auto-dropped'
  Assert-True ([string]$commentSecret.intake_gate.evidence.security_detail -eq 'comment-only-secret') 'comment-only secret detail missing'

  $weakSecurityId = Add-Idea -Text '[deep-codex/security] auth_bypass (lib/weak-security.ps1:1) -- Auth bypass needs stronger evidence.' -From 'audit-deep-codex' -Tags @('audit','deep-audit','security') -Status 'approved' -Severity 'critical' -SkipCurator
  $weakSecurity = Get-TestItemById -Id $weakSecurityId
  Assert-True ([string]$weakSecurity.status -eq 'held') 'generic security finding should be held for stronger verification'
  Assert-True ([string]$weakSecurity.held_reason -match 'stronger verifier') 'weak security hold reason missing'

  $noTargetId = Add-Idea -Text '[deep-agent/reliability-model/model] retry-loop -- Finding has no readable code target.' -From 'audit-deep-agent' -Tags @('audit','deep-audit') -Status 'approved' -Severity 'warning' -SkipCurator
  $noTarget = Get-TestItemById -Id $noTargetId
  Assert-True ([string]$noTarget.status -eq 'held') 'audit finding without target should be held'
  Assert-True ([string]$noTarget.held_reason -match 'lacks readable code target') 'no-target hold reason missing'

  $dynamicNoEvidenceId = Add-Idea -Text '[deep-codex/security] unsafe_dynamic -- Audit claims iex but provides no readable code target.' -From 'audit-deep-codex' -Tags @('audit','deep-audit','security') -Status 'approved' -Severity 'critical' -SkipCurator
  $dynamicNoEvidence = Get-TestItemById -Id $dynamicNoEvidenceId
  Assert-True ([string]$dynamicNoEvidence.status -eq 'held') 'dynamic security finding without readable evidence should be held, not dropped'
  Assert-True ([string]$dynamicNoEvidence.intake_gate.evidence.security_detail -eq 'no-dynamic-lines') 'dynamic no-evidence detail missing'

  $realDynamicId = Add-Idea -Text '[deep-codex/security] unsafe_dynamic (lib/real-dynamic.ps1:1) -- Invoke-Expression is present.' -From 'audit-deep-codex' -Tags @('audit','deep-audit','security') -Status 'approved' -Severity 'critical' -SkipCurator
  $realDynamic = Get-TestItemById -Id $realDynamicId
  Assert-True ([string]$realDynamic.status -eq 'approved') 'real dynamic execution evidence should remain approved'
  Assert-True ([string]$realDynamic.intake_gate.evidence.security_detail -eq 'dynamic-exec') 'real dynamic evidence detail missing'

  $projectAuditId = Add-Idea -Text '[deep-agent/security] unsafe_dynamic (lib/dynamic-text.ps1:1) -- Project audit should stay held and outside bridge intake.' -From 'audit-deep-agent' -Tags @('audit','project-audit') -Status 'held' -Severity 'critical' -Project 'sample-project' -Scope 'project' -SkipCurator
  $projectAudit = Get-TestItemById -Id $projectAuditId
  Assert-True ([string]$projectAudit.status -eq 'held') 'project audit held item should remain held'
  Assert-True (-not ($projectAudit.PSObject.Properties.Name -contains 'intake_gate')) 'project held item should not receive bridge intake metadata'

  $logPath = Join-Path (Join-Path $script:TestBridgeRoot 'control') 'curator-decisions.jsonl'
  Assert-True (Test-Path -LiteralPath $logPath) 'expected intake decision log'
  $logRaw = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
  Assert-True ($logRaw -match '"action":"intake-dedup"') 'expected intake-dedup log action'

  Write-Host 'OK backlog intake gate: audit duplicates, false security, obsolete-looking no-target findings filtered before approved backlog'
} finally {
  try {
    $resolved = [System.IO.Path]::GetFullPath($script:TestBridgeRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
      Remove-Item -LiteralPath $resolved -Recurse -Force
    }
  } catch {}
}
