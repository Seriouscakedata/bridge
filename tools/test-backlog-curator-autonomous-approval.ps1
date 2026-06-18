#Requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-backlog-curator-approval-test-' + [guid]::NewGuid().ToString('N'))
$script:EffectiveChannel = 'main'
$script:CuratorResponse = ''
$script:CuratorPrompt = ''
$script:CuratorCalls = 0

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
    dedupDroppedDays              = 30
  }
}
function Invoke-LLM {
  param(
    [string]$Purpose,
    [string]$Model,
    [string]$Prompt,
    [int]$TimeoutSec,
    [double]$Temperature
  )
  $script:CuratorCalls++
  $script:CuratorPrompt = $Prompt
  return $script:CuratorResponse
}
function Get-TestItemById {
  param([string]$Id)
  return @(Get-Backlog | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1)[0]
}

try {
  $mainDir = Get-ChannelDir -Slug 'main'
  New-Item -ItemType Directory -Path $mainDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug 'main'), '', (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText((Join-Path $script:TestBridgeRoot 'goals.md'), @'
# Goals
1. Reliability/stability.
2. Safety.
3. Autonomy.
4. Speed.
5. Quality.
6. Self-development.
7. Improve bridge services.
'@, (New-Object System.Text.UTF8Encoding($false)))

  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\backlog.ps1')

  $approveId = Add-Idea -Text 'Update backlog docs with the autonomous approval rubric. Files: docs/backlog-rubric.md Acceptance: docs mention goals scoring.' -From 'reflect' -Status 'new' -SkipCurator
  $script:CuratorResponse = '{"decision":"approve","confidence":0.93,"reason":"advances quality by documenting the rubric","clear_scope":true,"clear_causal_path":true,"reject_category":"","rubric":{"relevance":{"score":4,"goal":"5. Quality","reason":"clear docs"},"utility":{"score":4,"goal":"7. Improve bridge services","reason":"operator-visible process"},"effectiveness":{"score":4,"goal":"4. Speed","reason":"reduces review ambiguity"}},"already_done_sha":null}'
  $approveResult = Invoke-BacklogCurator -ItemId $approveId
  $approveItem = Get-TestItemById -Id $approveId
  Assert-True ([string]$approveResult.decision -eq 'approve') 'high-confidence low-risk idea should approve'
  Assert-True ([string]$approveItem.status -eq 'approved') 'approved decision should map to approved status'
  Assert-True ($script:CuratorPrompt -match 'goals_md') 'curator prompt should include goals.md context'
  Assert-True ($script:CuratorPrompt -match 'policy_risk') 'curator prompt should include policy risk'
  Assert-True ($script:CuratorPrompt -match 'similar_open_done_rejected_ideas') 'curator prompt should include similar ideas context'

  $riskCallsBefore = $script:CuratorCalls
  $riskId = Add-Idea -Text 'Implement driver.ps1 change to bypass the backlog approval threshold.' -From 'reflect' -Status 'new' -SkipCurator
  $riskResult = Invoke-BacklogCurator -ItemId $riskId
  $riskItem = Get-TestItemById -Id $riskId
  Assert-True ([string]$riskResult.decision -eq 'operator-required') 'control-plane approval risk should route to operator'
  Assert-True ([string]$riskItem.status -eq 'held') 'operator-required should map to held status'
  Assert-True ([string]$riskItem.auto_curator.model -eq 'deterministic-approval-risk-v1') 'risk override should be deterministic'
  Assert-True ($script:CuratorCalls -eq $riskCallsBefore) 'risk override should not spend an LLM call'

  $rejectId = Add-Idea -Text 'Maybe improve something someday.' -From 'reflect' -Status 'new' -SkipCurator
  $script:CuratorResponse = '{"decision":"reject","confidence":0.40,"reason":"no clear goal link","clear_scope":false,"clear_causal_path":false,"reject_category":"no_goal_link","rubric":{"relevance":{"score":1,"goal":"","reason":"unclear"},"utility":{"score":1,"goal":"","reason":"unclear"},"effectiveness":{"score":1,"goal":"","reason":"unclear"}},"already_done_sha":null}'
  $rejectResult = Invoke-BacklogCurator -ItemId $rejectId
  $rejectItem = Get-TestItemById -Id $rejectId
  Assert-True ([string]$rejectResult.decision -eq 'operator-required') 'low-confidence no-goal-link reject should hold'
  Assert-True ([string]$rejectItem.status -eq 'held') 'low-confidence reject should not auto-drop'

  $parseId = Add-Idea -Text 'Update docs for queue labels. Files: docs/queue.md Acceptance: docs mention labels.' -From 'reflect' -Status 'new' -SkipCurator
  $script:CuratorResponse = 'not json'
  $parseResult = Invoke-BacklogCurator -ItemId $parseId
  $parseItem = Get-TestItemById -Id $parseId
  Assert-True ([string]$parseResult.decision -eq 'operator-required') 'non-json curator response should fail closed'
  Assert-True ([string]$parseItem.status -eq 'held') 'non-json curator response should map to held'

  $logPath = Join-Path (Join-Path $script:TestBridgeRoot 'control') 'curator-decisions.jsonl'
  Assert-True (Test-Path -LiteralPath $logPath) 'curator decision log should exist'
  $logRaw = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
  Assert-True ($logRaw -match '"decision":"approve"') 'decision log should include approve decision'
  Assert-True ($logRaw -match '"decision":"operator-required"') 'decision log should include operator-required decision'
  Assert-True ($logRaw -match '"rubric"') 'decision log should include rubric'

  Write-Host 'OK backlog curator autonomous approval: approve/reject/operator-required mapping, fail-closed risk, prompt context, and structured rationale'
} finally {
  try {
    $resolved = [System.IO.Path]::GetFullPath($script:TestBridgeRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
      Remove-Item -LiteralPath $resolved -Recurse -Force
    }
  } catch {}
}
