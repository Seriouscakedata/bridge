param()

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-workpack-batch-test-' + [guid]::NewGuid().ToString('N'))

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Assert-FrontierReportShape {
  param($Report, [string]$Name)
  $required = @(
    'enabled',
    'approved_count',
    'with_workpack_count',
    'without_workpack_count',
    'eligible_count',
    'protected_count',
    'ready_count',
    'selected_count',
    'min_items',
    'max_items',
    'dependency_wait_count',
    'structural_wait_count',
    'conflict_skip_count',
    'touch_skip_count',
    'batch_available',
    'parallel_required',
    'reason',
    'selected_ids',
    'selected_groups'
  )
  foreach ($field in $required) {
    Assert-True ($Report.PSObject.Properties.Name -contains $field) ("{0} missing frontier field {1}" -f $Name, $field)
  }
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
    workpackExecEnabled = $true
    workpackExecMinItems = 2
    workpackExecMaxItems = 3
    workpackExecIncludeProtected = $false
    backlogPackEnabled = $true
    backlogPackBurstCount = 5
    backlogPackWindowMinutes = 60
    backlogPackUnpackedOpenCount = 8
    backlogPackAuditBurstCount = 3
    backlogPackAuditWindowMinutes = 30
    backlogPackCooldownMinutes = 30
    backlogPackMinItems = 2
  }
}

try {
  $mainDir = Get-ChannelDir -Slug 'main'
  New-Item -ItemType Directory -Path $mainDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug 'main'), '', (New-Object System.Text.UTF8Encoding($false)))

  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\backlog.ps1')

  $idAudit = Add-Idea -Text 'fix audit scenario stale warning in tools/audit-functional.ps1' -From 'test' -Status 'approved' -SkipCurator
  $idMemory = Add-Idea -Text 'tighten memory recall guard in lib/memory.ps1' -From 'test' -Status 'approved' -SkipCurator
  $idAudit2 = Add-Idea -Text 'another audit-only tweak in tools/audit.ps1' -From 'test' -Status 'approved' -SkipCurator
  $idSafety = Add-Idea -Text 'change watchdog safety behavior in watchdog.ps1' -From 'test' -Status 'approved' -SkipCurator

  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idAudit) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-audit' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'audit' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('tools/audit-functional.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idMemory) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-memory' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'memory' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('lib/memory.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idAudit2) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-audit-2' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'audit' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('tools/audit.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idSafety) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-safety' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'safety' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('watchdog.ps1') -Force
    }
  }
  Save-Backlog $items

  $batch = Get-NextBacklogWorkpackBatch
  Assert-True ($batch -ne $null) 'expected a workpack batch'
  Assert-True ([int]$batch.count -eq 2) ("expected 2 selected items, got {0}" -f [int]$batch.count)
  Assert-True (@($batch.ids) -contains [string]$idAudit) 'expected audit item'
  Assert-True (@($batch.ids) -contains [string]$idMemory) 'expected memory item'
  Assert-True (-not (@($batch.ids) -contains [string]$idAudit2)) 'same conflict group should be skipped'
  Assert-True (-not (@($batch.ids) -contains [string]$idSafety)) 'protected safety group should be skipped by default'

  $report = Get-BacklogWorkpackFrontierReport
  Assert-FrontierReportShape -Report $report -Name 'independent'
  Assert-True ([bool]$report.batch_available) 'expected frontier report batch_available=true'
  Assert-True ([int]$report.selected_count -ge 2) 'expected frontier report selected_count>=2'
  Assert-True ([string]$report.reason -eq 'batch-available') ("expected batch-available frontier reason, got {0}" -f [string]$report.reason)
  Assert-True (@($report.selected_ids) -contains [string]$idAudit) 'expected frontier report audit id'
  Assert-True (@($report.selected_groups) -contains 'audit') 'expected frontier report audit group'
  Assert-True ($batch.PSObject.Properties.Name -contains 'frontier_report') 'expected batch to expose frontier_report'

  $taskText = New-BacklogWorkpackBatchTaskText -Items @($batch.items)
  Assert-True ($taskText -match '\[\[PARALLEL:wp1\]\]') 'expected parallel template wp1'
  Assert-True ($taskText -match '\[\[PARALLEL:wp2\]\]') 'expected parallel template wp2'
  Assert-True ($taskText -match 'STATUS:\s*CONTINUE') 'expected planner status hint'

  $items = @(Get-Backlog)
  foreach ($item in $items) { $item | Add-Member -NotePropertyName status -NotePropertyValue 'done' -Force }
  Save-Backlog $items

  $idProtectedA = Add-Idea -Text 'change watchdog restart gate in watchdog.ps1' -From 'test' -Status 'approved' -SkipCurator
  $idProtectedB = Add-Idea -Text 'change supervisor safety loop in supervisor.ps1' -From 'test' -Status 'approved' -SkipCurator
  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idProtectedA) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-protected-a' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'safety' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('watchdog.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idProtectedB) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-protected-b' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'core' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('supervisor.ps1') -Force
    }
  }
  Save-Backlog $items
  $protectedReport = Get-BacklogWorkpackFrontierReport
  $protectedBatch = Get-NextBacklogWorkpackBatch
  Assert-FrontierReportShape -Report $protectedReport -Name 'protected-only'
  Assert-True ($null -eq $protectedBatch) 'expected protected-only batch to be null'
  Assert-True (-not [bool]$protectedReport.batch_available) 'expected protected-only report batch_available=false'
  Assert-True ([int]$protectedReport.protected_count -gt 0) 'expected protected-only report protected_count>0'
  Assert-True (@('protected-dominant','not-enough-eligible') -contains [string]$protectedReport.reason) ("expected protected-only reason, got {0}" -f [string]$protectedReport.reason)

  $items = @(Get-Backlog)
  foreach ($item in $items) { $item | Add-Member -NotePropertyName status -NotePropertyValue 'done' -Force }
  Save-Backlog $items

  $idNoPackA = Add-Idea -Text 'update docs one without workpack metadata in docs/a.md' -From 'test' -Status 'approved' -SkipCurator
  $idNoPackB = Add-Idea -Text 'update docs two without workpack metadata in docs/b.md' -From 'test' -Status 'approved' -SkipCurator
  $noPackReport = Get-BacklogWorkpackFrontierReport
  $noPackBatch = Get-NextBacklogWorkpackBatch
  Assert-FrontierReportShape -Report $noPackReport -Name 'no-workpack'
  Assert-True ($null -eq $noPackBatch) 'expected no-workpack batch to be null'
  Assert-True (-not [bool]$noPackReport.batch_available) 'expected no-workpack report batch_available=false'
  Assert-True ([int]$noPackReport.without_workpack_count -ge 2) 'expected no-workpack report without_workpack_count>=2'
  Assert-True (@('not-enough-workpack','not-enough-eligible') -contains [string]$noPackReport.reason) ("expected no-workpack reason, got {0}" -f [string]$noPackReport.reason)
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$idNoPackA)) 'expected no-workpack fixture id A'
  Assert-True (-not [string]::IsNullOrWhiteSpace([string]$idNoPackB)) 'expected no-workpack fixture id B'

  $items = @(Get-Backlog)
  foreach ($item in $items) { $item | Add-Member -NotePropertyName status -NotePropertyValue 'done' -Force }
  Save-Backlog $items

  $idFoundation = Add-Idea -Text 'scaffold database schema foundation in prisma/schema.prisma' -From 'test' -Status 'approved' -SkipCurator
  $idAfterBarrier = Add-Idea -Text 'update independent docs after barrier in RUNBOOK.md' -From 'test' -Status 'approved' -SkipCurator
  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idFoundation) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-foundation' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:prisma/schema.prisma' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('prisma/schema.prisma') -Force
    } elseif ([string]$item.id -eq [string]$idAfterBarrier) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-after-barrier' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:RUNBOOK.md' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('RUNBOOK.md') -Force
    }
  }
  Save-Backlog $items
  $structuralReport = Get-BacklogWorkpackFrontierReport
  Assert-FrontierReportShape -Report $structuralReport -Name 'structural'
  Assert-True (-not [bool]$structuralReport.batch_available) 'expected structural barrier report batch_available=false'
  Assert-True ([int]$structuralReport.structural_wait_count -ge 1) 'expected structural barrier count'
  Assert-True ([string]$structuralReport.reason -eq 'structural-barrier') ("expected structural-barrier reason, got {0}" -f [string]$structuralReport.reason)

  $items = @(Get-Backlog)
  foreach ($item in $items) { $item | Add-Member -NotePropertyName status -NotePropertyValue 'done' -Force }
  Save-Backlog $items

  $idBase = Add-Idea -Text 'base layout atom already completed' -From 'test' -Status 'done' -SkipCurator
  $idReadyA = Add-Idea -Text 'update profile page display copy in app/profile/page.tsx' -From 'test' -Status 'approved' -SkipCurator
  $idReadyB = Add-Idea -Text 'add gallery empty state copy in app/gallery/page.tsx' -From 'test' -Status 'approved' -SkipCurator
  $idReadyC = Add-Idea -Text 'document launch checklist in RUNBOOK.md' -From 'test' -Status 'approved' -SkipCurator
  $idWaiting = Add-Idea -Text 'wire admin dashboard after admin-api atom exists in app/admin/page.tsx' -From 'test' -Status 'approved' -SkipCurator

  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idBase) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'base-layout' -Force
    } elseif ([string]$item.id -eq [string]$idReadyA) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'profile-copy' -Force
      $item | Add-Member -NotePropertyName depends_on -NotePropertyValue @('base-layout') -Force
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-profile' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:app/profile/page.tsx' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('app/profile/page.tsx') -Force
    } elseif ([string]$item.id -eq [string]$idReadyB) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'gallery-empty' -Force
      $item | Add-Member -NotePropertyName depends_on -NotePropertyValue @('base-layout') -Force
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-gallery' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:app/gallery/page.tsx' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('app/gallery/page.tsx') -Force
    } elseif ([string]$item.id -eq [string]$idReadyC) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'runbook-checklist' -Force
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-runbook' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:RUNBOOK.md' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('RUNBOOK.md') -Force
    } elseif ([string]$item.id -eq [string]$idWaiting) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'admin-dashboard' -Force
      $item | Add-Member -NotePropertyName depends_on -NotePropertyValue @('admin-api') -Force
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-admin' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:app/admin/page.tsx' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('app/admin/page.tsx') -Force
    }
  }
  Save-Backlog $items

  $frontierBatch = Get-NextBacklogWorkpackBatch
  Assert-True ($frontierBatch -ne $null) 'expected dependency-aware ready frontier batch'
  Assert-FrontierReportShape -Report $frontierBatch.frontier_report -Name 'dependency-ready'
  Assert-True ([int]$frontierBatch.count -eq 3) ("expected 3 ready frontier items, got {0}" -f [int]$frontierBatch.count)
  Assert-True (@($frontierBatch.ids) -contains [string]$idReadyA) 'expected ready profile atom'
  Assert-True (@($frontierBatch.ids) -contains [string]$idReadyB) 'expected ready gallery atom'
  Assert-True (@($frontierBatch.ids) -contains [string]$idReadyC) 'expected ready docs atom'
  Assert-True (-not (@($frontierBatch.ids) -contains [string]$idWaiting)) 'waiting dependency atom should not block or join frontier'
  Assert-True ([int]$frontierBatch.dependency_wait_count -ge 1) 'expected dependency wait telemetry'
  Assert-True ([string]$frontierBatch.frontier_report.reason -eq 'batch-available') ("expected dependency-ready reason, got {0}" -f [string]$frontierBatch.frontier_report.reason)

  $startSrvText = '[deep-agent/reliability-model/deepseek-v4-flash] process_supervision -- Start-Srv and Start-Drv use Start-Process with -NoNewWindow but redirect stdout/stderr to files. If the log file path is unavailable, supervisor can fail silently.'
  $reapText = '[deep-agent/reliability-model/deepseek-v4-flash] process_supervision -- Reap-Bloated kills tracked processes with private memory > 8GB. The threshold is hardcoded.'
  $auditText = '[deep-claude/Functional Bug] : The deep-audit phase of audit-self-diag is encountering Get-BacklogPath exceptions during drift analysis.'
  $orphanRestartText = '[deep-agent/runtime-incident-model/deepseek-v4-flash] orphan-restart -- Multiple orphan restarts detected with no associated task turn within 5 minutes. Consider adding task attribution to restart events.'
  $featureStateText = "[deep-claude/Data Structure / Registry Drift] : The 'features\state.json' file contains a single, very long key that concatenates multiple feature IDs and scenario_results."
  $commandInjectionText = '[deep-agent/security-model/deepseek-v4-pro] command_injection -- The script passes user-supplied arguments directly to powershell.exe via -File; sub-scripts tools\replay-cli.ps1 and tools\live-status.ps1 receive unsanitized input.'
  $taskkillText = '[deep-agent/security-model/deepseek-v4-pro] command_injection -- The script constructs and executes ''taskkill /PID $_.ProcessId /F /T'' using string interpolation.'
  $configSecretText = '[deep-codex/security] hardcoded_secrets (config.json:1) -- Recommend: Use environment variables or relative paths instead of hardcoded absolute paths.'
  $toolPathSecretText = "[deep-agent/security-model/deepseek-v4-pro] hardcoded_secrets -- The configuration file contains hardcoded paths: 'C:/Users/rafie/AppData/Local/OpenAI/Codex/bin/codex.exe', 'C:/Users/rafie/AppData/Roaming/Claude/claude-code/*/claude.exe', 'C:/Users/rafie/OneDrive/Documents/bridge-canary-worktree'."
  $unsafeDynamicText = '[deep-codex/security] unsafe_dynamic_execution (canary.ps1:1) -- Recommend: If channels.ps1 is optional, make this explicit rather than silently continuing.'
  $intentClassifierText = 'для bridge — при аудит-задачах с явным «без дебатов / заверши STATUS: DONE» классификатор намерений не должен форсить discuss-режим'
  $codexExecText = "deep-think discuss-mode не получает ответ Codex — codex exec падает с unexpected argument '-' found; проверить, как driver передаёт discuss-промпт в codex"
  $startClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $startSrvText })
  $reapClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $reapText })
  $auditClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $auditText })
  $orphanClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $orphanRestartText })
  $featureStateClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $featureStateText })
  $commandInjectionClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $commandInjectionText })
  $taskkillClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $taskkillText })
  $configSecretClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $configSecretText })
  $toolPathSecretClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $toolPathSecretText })
  $unsafeDynamicClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $unsafeDynamicText })
  $intentClassifierClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $intentClassifierText })
  $codexExecClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $codexExecText })
  Assert-True (@($startClass.touch_set) -contains 'supervisor.ps1') 'Start-Srv/Start-Drv should infer supervisor.ps1'
  Assert-True (@($reapClass.touch_set) -contains 'supervisor.ps1') 'Reap-Bloated should infer supervisor.ps1'
  Assert-True ([string]$startClass.key -eq 'file:supervisor.ps1') ("expected supervisor key for Start-Srv, got {0}" -f [string]$startClass.key)
  Assert-True ([string]$reapClass.key -eq 'file:supervisor.ps1') ("expected supervisor key for Reap-Bloated, got {0}" -f [string]$reapClass.key)
  Assert-True ([string]$startClass.conflict_group -eq 'safety') 'supervisor Start-Srv should be safety conflict'
  Assert-True ([string]$reapClass.conflict_group -eq 'safety') 'supervisor Reap-Bloated should be safety conflict'
  Assert-True (@($auditClass.touch_set) -contains 'tools/audit.ps1') 'deep-audit Get-BacklogPath should infer tools/audit.ps1'
  Assert-True (@($auditClass.touch_set) -contains 'lib/backlog.ps1') 'deep-audit Get-BacklogPath should infer lib/backlog.ps1'
  Assert-True (@($orphanClass.touch_set) -contains 'lib/circuit-breaker.ps1') 'orphan-restart should infer circuit breaker'
  Assert-True (-not (@($orphanClass.touch_set) -contains 'llm')) 'orphan-restart source model should not become llm touch'
  Assert-True ([string]$orphanClass.conflict_group -eq 'safety') 'orphan-restart should be safety conflict'
  Assert-True ([string]$featureStateClass.key -eq 'file:features/state.js') ("expected feature state key, got {0}" -f [string]$featureStateClass.key)
  Assert-True ([string]$featureStateClass.conflict_group -eq 'state') 'feature state drift should be state conflict'
  Assert-True ([string]$commandInjectionClass.conflict_group -eq 'safety') 'command injection should be safety conflict'
  Assert-True (-not ([string]$taskkillClass.key -eq 'module:ui')) 'taskkill text should not be misread as ui'
  Assert-True (@($taskkillClass.touch_set) -contains 'supervisor.ps1') 'taskkill ProcessId text should infer supervisor.ps1'
  Assert-True ([string]$taskkillClass.conflict_group -eq 'safety') 'taskkill text should be safety conflict'
  Assert-True ([string]$configSecretClass.key -eq 'file:config.json') ("expected config.json key, got {0}" -f [string]$configSecretClass.key)
  Assert-True ([string]$configSecretClass.conflict_group -eq 'safety') 'hardcoded secrets should be safety conflict'
  Assert-True ([string]$toolPathSecretClass.key -eq 'file:config.json') ("expected tool path hardcoded secret to map to config.json, got {0}" -f [string]$toolPathSecretClass.key)
  Assert-True (-not (@($toolPathSecretClass.touch_set) -contains 'lib/parallel.ps1')) 'worktree path alone should not infer lib/parallel.ps1'
  Assert-True (@($unsafeDynamicClass.touch_set) -contains 'lib/channels.ps1') 'bare channels.ps1 should infer lib/channels.ps1'
  Assert-True (@('core','safety') -contains [string]$unsafeDynamicClass.conflict_group) 'unsafe dynamic execution should be protected'
  Assert-True ([string]$intentClassifierClass.key -eq 'file:driver.ps1') 'Russian intent classifier task should infer driver.ps1'
  Assert-True ([string]$codexExecClass.key -eq 'file:driver.ps1') 'codex exec discuss-mode task should infer driver.ps1'

  $idStale = Add-Idea -Text $startSrvText -From 'test' -Status 'approved' -SkipCurator
  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idStale) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-stale-supervisor' -Force
      $item | Add-Member -NotePropertyName workpack_root_cause_key -NotePropertyValue 'module:llm' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'llm' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('llm') -Force
    }
  }
  Save-Backlog $items
  $updated = Update-BacklogWorkpackClassifications
  Assert-True ([int]$updated -ge 1) 'expected stale workpack classification to be refreshed'
  $stale = @(Get-Backlog | Where-Object { [string]$_.id -eq [string]$idStale })[0]
  Assert-True ([string]$stale.workpack_root_cause_key -eq 'file:supervisor.ps1') 'expected stale supervisor task key to be refreshed'
  Assert-True ([string]$stale.workpack_conflict_group -eq 'safety') 'expected stale supervisor task conflict group to be refreshed'
  Assert-True (@($stale.workpack_touch_set) -contains 'supervisor.ps1') 'expected stale supervisor task touch set to be refreshed'

  Write-Host ('OK workpack batch: selected {0} independent items' -f [int]$batch.count)
} finally {
  try {
    $resolved = [System.IO.Path]::GetFullPath($script:TestBridgeRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
      Remove-Item -LiteralPath $resolved -Recurse -Force
    }
  } catch {}
}
