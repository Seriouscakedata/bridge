param()

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-workpack-batch-test-' + [guid]::NewGuid().ToString('N'))
$script:TestChannel = 'main'

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
    'claim_available',
    'batch_available',
    'parallel_required',
    'serial_required',
    'serial_reason',
    'workpack_batch_mode',
    'reason',
    'selected_ids',
    'selected_groups',
    'candidate_count',
    'blocked_count',
    'blocked_ids',
    'selected_lanes',
    'selected_parallel_groups',
    'reason_detail',
    'reason_details',
    'candidates',
    'frontier_candidates'
  )
  foreach ($field in $required) {
    Assert-True ($Report.PSObject.Properties.Name -contains $field) ("{0} missing frontier field {1}" -f $Name, $field)
  }
}

function Get-FrontierCandidateById {
  param($Report, [string]$Id)
  $match = @(@($Report.frontier_candidates) | Where-Object { [string]$_.id -eq [string]$Id } | Select-Object -First 1)
  if ($match.Count -eq 0) { return $null }
  return $match[0]
}

function Get-BridgeRoot { return $script:TestBridgeRoot }
function Get-EffectiveChannel { return $script:TestChannel }
function Get-ChannelDir {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = $script:TestChannel }
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
function Get-EffectiveScope {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = $script:TestChannel }
  if ($Slug -eq 'main') {
    return [pscustomobject]@{ is_bridge=$true; bridge_root=$script:TestBridgeRoot; project_root='' }
  }
  return [pscustomobject]@{ is_bridge=$false; bridge_root=$script:TestBridgeRoot; project_root=(Join-Path $script:TestBridgeRoot ('project-' + $Slug)) }
}
function Get-AutonomySettings {
  return [pscustomobject]@{
    workpackExecEnabled = $true
    workpackExecMinItems = 2
    workpackExecMaxItems = 3
    workpackExecIncludeProtected = $false
    workpackExecSerialProtectedEnabled = $true
    workpackExecSerialProtectedMinItems = 3
    workpackExecSerialProtectedMaxItems = 5
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
  Assert-True ([bool]$report.claim_available) 'expected frontier report claim_available=true'
  Assert-True ([bool]$report.parallel_required) 'expected frontier report parallel_required=true'
  Assert-True (-not [bool]$report.serial_required) 'expected independent frontier serial_required=false'
  Assert-True ([bool]$report.auto_parallel) 'expected frontier report auto_parallel=true'
  Assert-True ([int]$report.per_task_timeout_sec -eq 600) ("expected frontier per_task_timeout_sec=600, got {0}" -f [int]$report.per_task_timeout_sec)
  Assert-True ([int]$report.parallel_timeout_min -eq 10) ("expected frontier parallel_timeout_min=10, got {0}" -f [int]$report.parallel_timeout_min)
  Assert-True ([int]$report.timeout_min -eq 10) ("expected frontier timeout_min=10 for parallel batch, got {0}" -f [int]$report.timeout_min)
  Assert-True ([string]$report.workpack_batch_mode -ne 'serial') 'expected independent frontier not to use serial mode'
  Assert-True ([int]$report.selected_count -ge 2) 'expected frontier report selected_count>=2'
  Assert-True ([string]$report.reason -eq 'batch-available') ("expected batch-available frontier reason, got {0}" -f [string]$report.reason)
  Assert-True (@($report.selected_ids) -contains [string]$idAudit) 'expected frontier report audit id'
  Assert-True (@($report.selected_groups) -contains 'audit') 'expected frontier report audit group'
  Assert-True ($batch.PSObject.Properties.Name -contains 'frontier_report') 'expected batch to expose frontier_report'

  $taskText = New-BacklogWorkpackBatchTaskText -Items @($batch.items)
  Assert-True ($taskText -match '\[\[PARALLEL:wp1\]\]') 'expected parallel template wp1'
  Assert-True ($taskText -match '\[\[PARALLEL:wp2\]\]') 'expected parallel template wp2'
  Assert-True ($taskText -match 'auto_parallel:\s*true') 'expected task text auto_parallel=true metadata'
  Assert-True ($taskText -match 'per_task_timeout_sec:\s*600') 'expected task text per_task_timeout_sec=600 metadata'
  Assert-True ($taskText -match 'timeout_min:\s*10') 'expected task text timeout_min=10 metadata'
  Assert-True ($taskText -match 'timeout_sec:\s*600') 'expected each parallel block to carry timeout_sec=600'
  Assert-True ($taskText -match 'STATUS:\s*CONTINUE') 'expected planner status hint'

  $items = @(Get-Backlog)
  foreach ($item in $items) { $item | Add-Member -NotePropertyName status -NotePropertyValue 'done' -Force }
  Save-Backlog $items

  $idOneReady = Add-Idea -Text 'update one ready workpack in tools/one-ready.ps1' -From 'test' -Status 'approved' -SkipCurator
  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idOneReady) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-one-ready' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'one-ready' -Force
      $item | Add-Member -NotePropertyName edit_touches -NotePropertyValue @('tools/one-ready.ps1') -Force
      $item | Add-Member -NotePropertyName files -NotePropertyValue @('tools/one-ready.ps1') -Force
    }
  }
  Save-Backlog $items
  $oneReadyReport = Get-BacklogWorkpackFrontierReport
  $oneReadyBatch = Get-NextBacklogWorkpackBatch
  Assert-FrontierReportShape -Report $oneReadyReport -Name 'one-ready'
  Assert-True ($oneReadyBatch -ne $null) 'expected one-ready serial fallback claim'
  Assert-True ([int]$oneReadyBatch.count -eq 1) ("expected one-ready count=1, got {0}" -f [int]$oneReadyBatch.count)
  Assert-True (-not [bool]$oneReadyReport.batch_available) 'one-ready should not be a parallel batch'
  Assert-True ([bool]$oneReadyReport.claim_available) 'one-ready should be claimable'
  Assert-True (-not [bool]$oneReadyReport.parallel_required) 'one-ready should not require parallel'
  Assert-True ([bool]$oneReadyReport.serial_required) 'one-ready should require serial fallback'
  Assert-True ([string]$oneReadyReport.serial_reason -eq 'serial-single-fallback') ("one-ready serial_reason mismatch: {0}" -f [string]$oneReadyReport.serial_reason)
  Assert-True ([string]$oneReadyReport.workpack_batch_mode -eq 'serial') 'one-ready should reuse serial batch mode'
  Assert-True ([string]$oneReadyBatch.serial_reason -eq 'serial-single-fallback') 'one-ready batch should carry serial reason'
  Assert-True ([string]$oneReadyBatch.workpack_batch_mode -eq 'serial') 'one-ready batch should carry serial mode'

  $items = @(Get-Backlog)
  foreach ($item in $items) { $item | Add-Member -NotePropertyName status -NotePropertyValue 'done' -Force }
  Save-Backlog $items

  $idProtectedA = Add-Idea -Text 'change watchdog restart gate in watchdog.ps1' -From 'test' -Tags @('operator') -Status 'approved' -SkipCurator
  $idProtectedB = Add-Idea -Text 'change supervisor safety loop in supervisor.ps1' -From 'test' -Tags @('operator') -Status 'approved' -SkipCurator
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
  Assert-True ($protectedBatch -ne $null) 'expected protected-only operator batch to be claimable'
  Assert-True ([bool]$protectedReport.claim_available) 'protected-only operator work should be claimable'
  Assert-True ([int]$protectedReport.selected_count -ge 1) 'protected-only operator frontier should select authorized work'
  Assert-True (@($protectedReport.selected_ids) -contains [string]$idProtectedA -or @($protectedReport.selected_ids) -contains [string]$idProtectedB) 'protected-only operator frontier should select an operator-authorized item'
  Assert-True (@('batch-available','conflicts-or-touch-overlap','not-enough-eligible') -contains [string]$protectedReport.reason) ("expected operator protected frontier reason, got {0}" -f [string]$protectedReport.reason)

  $idProtectedC = Add-Idea -Text 'fix supervisor handle cleanup in supervisor.ps1' -From 'test' -Tags @('operator') -Status 'approved' -SkipCurator
  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -in @([string]$idProtectedA, [string]$idProtectedB, [string]$idProtectedC)) {
      $item | Add-Member -NotePropertyName workpack_root_cause_key -NotePropertyValue 'file:supervisor.ps1' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'safety' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('supervisor.ps1') -Force
      if ([string]::IsNullOrWhiteSpace([string]$item.workpack_id)) {
        $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-protected-supervisor' -Force
      }
    }
  }
  Save-Backlog $items
  $serialReport = Get-BacklogProtectedSerialFrontierReport
  $serialBatch = Get-NextBacklogProtectedSerialBatch
  Assert-FrontierReportShape -Report $serialReport -Name 'protected-serial'
  Assert-True ($serialReport.PSObject.Properties.Name -contains 'serial_required') 'protected serial report should expose serial_required'
  Assert-True ([bool]$serialReport.batch_available) 'expected protected serial batch_available=true'
  Assert-True ([bool]$serialReport.serial_required) 'expected protected serial_required=true'
  Assert-True (-not [bool]$serialReport.parallel_required) 'protected serial must not require parallel'
  Assert-True ([string]$serialReport.reason -eq 'serial-batch-available') ("expected serial-batch-available reason, got {0}" -f [string]$serialReport.reason)
  Assert-True ([string]$serialReport.selected_root -eq 'file:supervisor.ps1') ("expected supervisor serial root, got {0}" -f [string]$serialReport.selected_root)
  Assert-True ($serialBatch -ne $null) 'expected protected serial batch'
  Assert-True ([int]$serialBatch.count -eq 3) ("expected 3 protected serial items, got {0}" -f [int]$serialBatch.count)
  $serialText = New-BacklogProtectedSerialBatchTaskText -Items @($serialBatch.items) -Root ([string]$serialBatch.selected_root)
  Assert-True ($serialText -match 'protected-serial-workpack') 'serial task text should identify protected serial mode'
  Assert-True ($serialText -match 'НЕ эмить \[\[PARALLEL') 'serial task text should explicitly forbid parallel markers'
  Assert-True ($serialText -notmatch '\[\[PARALLEL:[A-Za-z0-9_.-]+\]\]') 'serial task text must not contain executable parallel blocks'

  $items = @(Get-Backlog)
  foreach ($item in $items) { $item | Add-Member -NotePropertyName status -NotePropertyValue 'done' -Force }
  Save-Backlog $items

  $idNormalWithProtected = Add-Idea -Text 'update normal residue in tools/normal-residue.ps1' -From 'test' -Status 'approved' -SkipCurator
  $idProtectedResidue = Add-Idea -Text 'change watchdog residue behavior in watchdog.ps1' -From 'test' -Tags @('operator') -Status 'approved' -SkipCurator
  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idNormalWithProtected) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-normal-residue' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'normal-residue' -Force
      $item | Add-Member -NotePropertyName edit_touches -NotePropertyValue @('tools/normal-residue.ps1') -Force
      $item | Add-Member -NotePropertyName files -NotePropertyValue @('tools/normal-residue.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idProtectedResidue) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-protected-residue' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'safety' -Force
      $item | Add-Member -NotePropertyName edit_touches -NotePropertyValue @('watchdog.ps1') -Force
      $item | Add-Member -NotePropertyName files -NotePropertyValue @('watchdog.ps1') -Force
    }
  }
  Save-Backlog $items
  $protectedMixedReport = Get-BacklogWorkpackFrontierReport
  $protectedMixedBatch = Get-NextBacklogWorkpackBatch
  Assert-FrontierReportShape -Report $protectedMixedReport -Name 'protected-plus-normal'
  Assert-True ($protectedMixedBatch -ne $null) 'expected protected+normal to claim normal residue'
  Assert-True ([int]$protectedMixedBatch.count -eq 2) ("expected protected+normal count=2, got {0}" -f [int]$protectedMixedBatch.count)
  Assert-True (@($protectedMixedBatch.ids) -contains [string]$idNormalWithProtected) 'expected normal residue selected'
  Assert-True (@($protectedMixedBatch.ids) -contains [string]$idProtectedResidue) 'operator protected residue should be selectable'
  Assert-True ([bool]$protectedMixedReport.claim_available) 'protected+normal should be claimable'

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

  $idAuditModelA = Add-Idea -Text '[deep-agent/runtime-incident-model/deepseek-v4-flash] attribution-gap -- Restart has no task_id and no task turn within 10 minutes. Add task attribution to restart events.' -From 'test' -Tags @('operator') -Status 'approved' -SkipCurator
  $idAuditModelB = Add-Idea -Text "[deep-agent/functional-model/gemini-2.5-flash] Data Structure / Registry Drift -- The 'features\state.json' file contains stale feature activation data." -From 'test' -Status 'approved' -SkipCurator
  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idAuditModelA) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-audit-model-a' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'state' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('state') -Force
    } elseif ([string]$item.id -eq [string]$idAuditModelB) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-audit-model-b' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'audit' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('features/state.js') -Force
    }
  }
  Save-Backlog $items
  Assert-True ([string](Get-BacklogTaskDepSignal -Text '[deep-agent/runtime-incident-model/deepseek-v4-flash] attribution-gap -- Restart has no task_id and no task turn within 10 minutes.') -eq 'neutral') 'source tag runtime-incident-model must not become foundation'
  Assert-True ([string](Get-BacklogTaskDepSignal -Text "[deep-agent/functional-model/gemini-2.5-flash] Data Structure / Registry Drift -- The 'features\state.json' file contains stale feature activation data.") -eq 'neutral') 'source tag functional-model must not become foundation'
  Assert-True ([string](Get-BacklogTaskDepSignal -Text 'create User model and database schema in prisma/schema.prisma') -eq 'foundation') 'explicit model/schema creation should remain foundation'
  $auditModelBatch = Get-NextBacklogWorkpackBatch
  Assert-True ($auditModelBatch -ne $null) 'audit source model tags should not freeze workpack frontier'
  Assert-FrontierReportShape -Report $auditModelBatch.frontier_report -Name 'audit-model'
  Assert-True ([string]$auditModelBatch.frontier_report.reason -eq 'batch-available') ("expected audit-model batch-available, got {0}" -f [string]$auditModelBatch.frontier_report.reason)
  Assert-True ([int]$auditModelBatch.frontier_report.structural_wait_count -eq 0) 'audit source model tags should not count as structural barriers'

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

  $items = @(Get-Backlog)
  foreach ($item in $items) { $item | Add-Member -NotePropertyName status -NotePropertyValue 'done' -Force }
  Save-Backlog $items

  $idMixA = Add-Idea -Text 'update account settings copy in app/settings/page.tsx' -From 'test' -Status 'approved' -SkipCurator
  $idMixB = Add-Idea -Text 'update billing empty state in app/billing/page.tsx' -From 'test' -Status 'approved' -SkipCurator
  $idOverlapGroup = Add-Idea -Text 'second billing tweak in app/billing/summary.tsx' -From 'test' -Status 'approved' -SkipCurator
  $idOverlapTouch = Add-Idea -Text 'touch same settings page again in app/settings/page.tsx' -From 'test' -Status 'approved' -SkipCurator
  $idMixC = Add-Idea -Text 'document release checklist in docs/release.md' -From 'test' -Status 'approved' -SkipCurator
  $idWaitDep = Add-Idea -Text 'wire reports page after reports-api exists in app/reports/page.tsx' -From 'test' -Status 'approved' -SkipCurator
  $idBridgeControl = Add-Idea -Text 'adjust driver.ps1 control-plane loop without admission' -From 'test' -Status 'approved' -SkipCurator
  $idProtectedMixed = Add-Idea -Text 'change safety watchdog behavior in watchdog.ps1' -From 'test' -Status 'approved' -SkipCurator
  $idProjectMain = Add-Idea -Text 'project scoped task in app/project/page.tsx' -From 'test' -Status 'approved' -Scope 'project' -Project 'fixture-project' -SkipCurator
  $idObsolete = Add-Idea -Text 'obsolete done workpack should not affect batch in old/file.ts' -From 'test' -Status 'done' -SkipCurator
  $idDuplicate = Add-Idea -Text 'duplicate rejected workpack should not affect batch in old/dup.ts' -From 'test' -Status 'rejected' -SkipCurator

  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idMixA) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'settings-copy' -Force
      $item | Add-Member -NotePropertyName parallel_group -NotePropertyValue 'ui-settings' -Force
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-mix-settings' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:app/settings/page.tsx' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('app/settings/page.tsx') -Force
      $item | Add-Member -NotePropertyName files -NotePropertyValue @('app/settings/page.tsx') -Force
    } elseif ([string]$item.id -eq [string]$idMixB) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'billing-empty' -Force
      $item | Add-Member -NotePropertyName parallel_group -NotePropertyValue 'ui-billing' -Force
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-mix-billing' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:app/billing/page.tsx' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('app/billing/page.tsx') -Force
      $item | Add-Member -NotePropertyName files -NotePropertyValue @('app/billing/page.tsx') -Force
    } elseif ([string]$item.id -eq [string]$idMixC) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'release-docs' -Force
      $item | Add-Member -NotePropertyName parallel_group -NotePropertyValue 'docs-release' -Force
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-mix-release' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:docs/release.md' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('docs/release.md') -Force
      $item | Add-Member -NotePropertyName files -NotePropertyValue @('docs/release.md') -Force
    } elseif ([string]$item.id -eq [string]$idOverlapGroup) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'billing-second' -Force
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-mix-billing-2' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:app/billing/page.tsx' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('app/billing/summary.tsx') -Force
      $item | Add-Member -NotePropertyName files -NotePropertyValue @('app/billing/summary.tsx') -Force
    } elseif ([string]$item.id -eq [string]$idOverlapTouch) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'settings-second' -Force
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-mix-settings-2' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:app/settings/other.tsx' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('app/settings/page.tsx') -Force
      $item | Add-Member -NotePropertyName files -NotePropertyValue @('app/settings/page.tsx') -Force
    } elseif ([string]$item.id -eq [string]$idWaitDep) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'reports-page' -Force
      $item | Add-Member -NotePropertyName depends_on -NotePropertyValue @('reports-api') -Force
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-mix-reports' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:app/reports/page.tsx' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('app/reports/page.tsx') -Force
    } elseif ([string]$item.id -eq [string]$idBridgeControl) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'driver-control' -Force
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-mix-driver' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:driver.ps1' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('driver.ps1') -Force
      $item | Add-Member -NotePropertyName files -NotePropertyValue @('driver.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idProtectedMixed) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'watchdog-safety' -Force
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-mix-watchdog' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'safety' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('watchdog.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idProjectMain) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'project-main-scope' -Force
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-mix-project-main' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:app/project/page.tsx' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('app/project/page.tsx') -Force
    } elseif ([string]$item.id -eq [string]$idObsolete) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-obsolete' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:old/file.ts' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('old/file.ts') -Force
    } elseif ([string]$item.id -eq [string]$idDuplicate) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-duplicate' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:old/dup.ts' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('old/dup.ts') -Force
    }
  }
  Save-Backlog $items

  $mixedBatch = Get-NextBacklogWorkpackBatch
  Assert-True ($mixedBatch -ne $null) 'expected mixed fixture to produce a batch'
  Assert-FrontierReportShape -Report $mixedBatch.frontier_report -Name 'mixed'
  Assert-True ([int]$mixedBatch.count -eq 3) ("expected 3 mixed selected items, got {0}" -f [int]$mixedBatch.count)
  Assert-True (@($mixedBatch.ids) -contains [string]$idMixA) 'expected mixed settings item'
  Assert-True (@($mixedBatch.ids) -contains [string]$idMixB) 'expected mixed billing item'
  Assert-True (@($mixedBatch.ids) -contains [string]$idMixC) 'expected mixed docs item'
  Assert-True (@($mixedBatch.frontier_report.selected_lanes) -contains 'ui-settings') 'expected selected lane ui-settings'
  Assert-True (@($mixedBatch.frontier_report.selected_parallel_groups) -contains 'ui-billing') 'expected selected parallel group ui-billing'
  $overlapGroupCandidate = Get-FrontierCandidateById -Report $mixedBatch.frontier_report -Id $idOverlapGroup
  $overlapTouchCandidate = Get-FrontierCandidateById -Report $mixedBatch.frontier_report -Id $idOverlapTouch
  $depCandidate = Get-FrontierCandidateById -Report $mixedBatch.frontier_report -Id $idWaitDep
  $controlCandidate = Get-FrontierCandidateById -Report $mixedBatch.frontier_report -Id $idBridgeControl
  $protectedCandidate = Get-FrontierCandidateById -Report $mixedBatch.frontier_report -Id $idProtectedMixed
  $projectMainCandidate = Get-FrontierCandidateById -Report $mixedBatch.frontier_report -Id $idProjectMain
  Assert-True ($overlapGroupCandidate -and [string]$overlapGroupCandidate.block_reason -eq 'conflicts-or-touch-overlap') 'expected conflict-group overlap detail'
  Assert-True ($overlapTouchCandidate -and [string]$overlapTouchCandidate.block_reason -eq 'conflicts-or-touch-overlap') 'expected touch overlap detail'
  Assert-True (@($overlapTouchCandidate.conflict_with_touches) -contains 'app/settings/page.tsx') 'expected overlap touch path detail'
  Assert-True ($depCandidate -and [string]$depCandidate.block_reason -eq 'dependency-wait') 'expected dependency wait candidate'
  Assert-True (@($depCandidate.unmet_deps) -contains 'reports-api(missing)') 'expected unmet dependency detail'
  Assert-True ($controlCandidate -and [string]$controlCandidate.block_reason -eq 'control-plane-admission-required') 'expected bridge control-plane admission block'
  Assert-True ($protectedCandidate -and [string]$protectedCandidate.block_reason -eq 'control-plane-admission-required') 'expected protected control-plane admission block'
  Assert-True ($projectMainCandidate -and [string]$projectMainCandidate.block_reason -eq 'project-scope-blocked') 'expected main-channel project-scope block'
  Assert-True (-not (@($mixedBatch.frontier_report.frontier_candidates | ForEach-Object { [string]$_.id }) -contains [string]$idObsolete)) 'obsolete done item should not be frontier candidate'
  Assert-True (-not (@($mixedBatch.frontier_report.frontier_candidates | ForEach-Object { [string]$_.id }) -contains [string]$idDuplicate)) 'rejected duplicate item should not be frontier candidate'
  Assert-True ([string]$mixedBatch.frontier_report.reason_detail -match 'selected:') 'expected readable mixed reason detail'

  $items = @(Get-Backlog)
  foreach ($item in $items) { $item | Add-Member -NotePropertyName status -NotePropertyValue 'done' -Force }
  Save-Backlog $items

  $idOnlyA = Add-Idea -Text 'update first overlapping panel in app/same/a.tsx' -From 'test' -Status 'approved' -SkipCurator
  $idOnlyB = Add-Idea -Text 'update second overlapping panel in app/same/b.tsx' -From 'test' -Status 'approved' -SkipCurator
  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idOnlyA) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-overlap-a' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'same-lane' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('app/same/a.tsx') -Force
    } elseif ([string]$item.id -eq [string]$idOnlyB) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-overlap-b' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'same-lane' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('app/same/b.tsx') -Force
    }
  }
  Save-Backlog $items
  $overlapOnlyReport = Get-BacklogWorkpackFrontierReport
  $overlapOnlyBatch = Get-NextBacklogWorkpackBatch
  Assert-FrontierReportShape -Report $overlapOnlyReport -Name 'overlap-only'
  Assert-True ($overlapOnlyBatch -ne $null) 'expected overlap-only serial fallback batch'
  Assert-True ([int]$overlapOnlyBatch.count -eq 1) ("expected overlap-only serial count=1, got {0}" -f [int]$overlapOnlyBatch.count)
  Assert-True (-not [bool]$overlapOnlyReport.batch_available) 'expected overlap-only no parallel batch'
  Assert-True ([bool]$overlapOnlyReport.claim_available) 'expected overlap-only claimable via serial fallback'
  Assert-True (-not [bool]$overlapOnlyReport.parallel_required) 'expected overlap-only no parallel requirement'
  Assert-True ([bool]$overlapOnlyReport.serial_required) 'expected overlap-only serial fallback required'
  Assert-True ([string]$overlapOnlyReport.serial_reason -eq 'serial-single-fallback') ("expected serial-single-fallback, got {0}" -f [string]$overlapOnlyReport.serial_reason)
  Assert-True ([string]$overlapOnlyReport.workpack_batch_mode -eq 'serial') 'expected overlap-only to reuse serial mode'
  Assert-True ([int]$overlapOnlyReport.selected_count -eq 1) ("expected 1 overlap-only selected item, got {0}" -f [int]$overlapOnlyReport.selected_count)
  Assert-True ([string]$overlapOnlyReport.reason -eq 'conflicts-or-touch-overlap') ("expected conflicts-or-touch-overlap, got {0}" -f [string]$overlapOnlyReport.reason)
  Assert-True ([string]$overlapOnlyReport.reason_detail -match 'skipped:') 'expected overlap-only skipped detail'

  $items = @(Get-Backlog)
  foreach ($item in $items) { $item | Add-Member -NotePropertyName status -NotePropertyValue 'done' -Force }
  Save-Backlog $items

  $idReportOnlyA = Add-Idea -Text 'update report-only alpha in app/alpha/page.tsx' -From 'test' -Status 'approved' -SkipCurator
  $idReportOnlyB = Add-Idea -Text 'update report-only beta in app/beta/page.tsx' -From 'test' -Status 'approved' -SkipCurator
  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idReportOnlyA) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-report-alpha' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:app/alpha/page.tsx' -Force
      $item | Add-Member -NotePropertyName edit_touches -NotePropertyValue @('app/alpha/page.tsx') -Force
      $item | Add-Member -NotePropertyName files -NotePropertyValue @('app/alpha/page.tsx') -Force
      $item | Add-Member -NotePropertyName verify -NotePropertyValue @('tools/shared-smoke.ps1') -Force
      $item | Add-Member -NotePropertyName read -NotePropertyValue @('docs/shared-context.md') -Force
      $item | Add-Member -NotePropertyName acceptance -NotePropertyValue @('docs/shared-acceptance.md') -Force
    } elseif ([string]$item.id -eq [string]$idReportOnlyB) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-report-beta' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:app/beta/page.tsx' -Force
      $item | Add-Member -NotePropertyName edit_touches -NotePropertyValue @('app/beta/page.tsx') -Force
      $item | Add-Member -NotePropertyName files -NotePropertyValue @('app/beta/page.tsx') -Force
      $item | Add-Member -NotePropertyName verify -NotePropertyValue @('tools/shared-smoke.ps1') -Force
      $item | Add-Member -NotePropertyName read -NotePropertyValue @('docs/shared-context.md') -Force
      $item | Add-Member -NotePropertyName acceptance -NotePropertyValue @('docs/shared-acceptance.md') -Force
    }
  }
  Save-Backlog $items
  $reportOnlyBatch = Get-NextBacklogWorkpackBatch
  Assert-True ($reportOnlyBatch -ne $null) 'expected report-only path overlap not to block batch'
  Assert-True ([int]$reportOnlyBatch.count -eq 2) ("expected report-only batch count=2, got {0}" -f [int]$reportOnlyBatch.count)
  Assert-True (@($reportOnlyBatch.ids) -contains [string]$idReportOnlyA) 'expected report-only alpha selected'
  Assert-True (@($reportOnlyBatch.ids) -contains [string]$idReportOnlyB) 'expected report-only beta selected'

  $items = @(Get-Backlog)
  foreach ($item in $items) { $item | Add-Member -NotePropertyName status -NotePropertyValue 'done' -Force }
  Save-Backlog $items

  $idDeclaredOverlapA = Add-Idea -Text 'stage atom updates delivery facts helper in lib/delivery-gate-facts-a.ps1' -From 'test' -Status 'approved' -SkipCurator
  $idDeclaredOverlapB = Add-Idea -Text 'stage atom updates delivery facts helper in lib/delivery-gate-facts-b.ps1' -From 'test' -Status 'approved' -SkipCurator
  $idDeclaredIndependent = Add-Idea -Text 'stage atom updates delivery mode helper in lib/delivery-mode.ps1' -From 'test' -Status 'approved' -SkipCurator
  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idDeclaredOverlapA) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-declared-overlap-a' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:lib/delivery-gate-facts-a.ps1' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('lib/delivery-gate-facts.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idDeclaredOverlapB) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-declared-overlap-b' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:lib/delivery-gate-facts-b.ps1' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('lib/delivery-gate-facts.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idDeclaredIndependent) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-declared-independent' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:lib/delivery-mode.ps1' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('lib/delivery-mode.ps1') -Force
    }
  }
  Save-Backlog $items
  $declaredOverlapBatch = Get-NextBacklogWorkpackBatch
  Assert-True ($declaredOverlapBatch -ne $null) 'expected declared-overlap fixture to produce a batch'
  Assert-FrontierReportShape -Report $declaredOverlapBatch.frontier_report -Name 'declared-overlap'
  Assert-True ([int]$declaredOverlapBatch.count -eq 2) ("expected declared-overlap batch count=2, got {0}" -f [int]$declaredOverlapBatch.count)
  Assert-True (@($declaredOverlapBatch.ids) -contains [string]$idDeclaredIndependent) 'expected declared independent selected'
  Assert-True ((@($declaredOverlapBatch.ids) -contains [string]$idDeclaredOverlapA) -xor (@($declaredOverlapBatch.ids) -contains [string]$idDeclaredOverlapB)) 'expected exactly one declared-overlap item selected'
  Assert-True (-not ((@($declaredOverlapBatch.ids) -contains [string]$idDeclaredOverlapA) -and (@($declaredOverlapBatch.ids) -contains [string]$idDeclaredOverlapB))) 'declared-overlap items must not share a parallel batch'
  $declaredBlockedId = if (@($declaredOverlapBatch.ids) -contains [string]$idDeclaredOverlapA) { [string]$idDeclaredOverlapB } else { [string]$idDeclaredOverlapA }
  $declaredBlocked = Get-FrontierCandidateById -Report $declaredOverlapBatch.frontier_report -Id $declaredBlockedId
  Assert-True ($declaredBlocked -and [string]$declaredBlocked.block_reason -eq 'conflicts-or-touch-overlap') 'expected declared-overlap skipped by touch conflict'
  Assert-True (@($declaredBlocked.conflict_with_touches) -contains 'lib/delivery-gate-facts.ps1') 'expected declared overlap touch path detail'

  $items = @(Get-Backlog)
  foreach ($item in $items) { $item | Add-Member -NotePropertyName status -NotePropertyValue 'done' -Force }
  Save-Backlog $items

  $idLegacyFilesA = Add-Idea -Text 'update legacy files alpha in app/legacy-a.tsx' -From 'test' -Status 'approved' -SkipCurator
  $idLegacyFilesB = Add-Idea -Text 'update legacy files beta in app/legacy-b.tsx' -From 'test' -Status 'approved' -SkipCurator
  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idLegacyFilesA) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-legacy-alpha' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:app/legacy-a.tsx' -Force
      $item | Add-Member -NotePropertyName files -NotePropertyValue @('app/legacy-a.tsx') -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('docs/shared-reference.md') -Force
    } elseif ([string]$item.id -eq [string]$idLegacyFilesB) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-legacy-beta' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:app/legacy-b.tsx' -Force
      $item | Add-Member -NotePropertyName files -NotePropertyValue @('app/legacy-b.tsx') -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('docs/shared-reference.md') -Force
    }
  }
  Save-Backlog $items
  $legacyFilesBatch = Get-NextBacklogWorkpackBatch
  Assert-True ($legacyFilesBatch -ne $null) 'expected legacy files fallback batch'
  Assert-True ([int]$legacyFilesBatch.count -eq 2) ("expected legacy files fallback count=2, got {0}" -f [int]$legacyFilesBatch.count)
  Assert-True (@($legacyFilesBatch.ids) -contains [string]$idLegacyFilesA) 'expected legacy files alpha selected'
  Assert-True (@($legacyFilesBatch.ids) -contains [string]$idLegacyFilesB) 'expected legacy files beta selected'

  $items = @(Get-Backlog)
  foreach ($item in $items) { $item | Add-Member -NotePropertyName status -NotePropertyValue 'done' -Force }
  Save-Backlog $items

  $script:TestChannel = 'project-x'
  $projectDir = Get-ChannelDir -Slug 'project-x'
  New-Item -ItemType Directory -Path $projectDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug 'project-x'), '', (New-Object System.Text.UTF8Encoding($false)))
  $idProjectDriver = Add-Idea -Text 'project task updates its own driver.ps1 adapter' -From 'test' -Status 'approved' -Scope 'project' -Project 'project-x' -SkipCurator
  $idProjectUi = Add-Idea -Text 'project task updates ui panel in src/panel.tsx' -From 'test' -Status 'approved' -Scope 'project' -Project 'project-x' -SkipCurator
  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idProjectDriver) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'project-driver' -Force
      $item | Add-Member -NotePropertyName parallel_group -NotePropertyValue 'project-runtime' -Force
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-project-driver' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:driver.ps1' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('driver.ps1') -Force
      $item | Add-Member -NotePropertyName files -NotePropertyValue @('driver.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idProjectUi) {
      $item | Add-Member -NotePropertyName slug -NotePropertyValue 'project-panel' -Force
      $item | Add-Member -NotePropertyName parallel_group -NotePropertyValue 'project-ui' -Force
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-project-ui' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'file:src/panel.tsx' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('src/panel.tsx') -Force
      $item | Add-Member -NotePropertyName files -NotePropertyValue @('src/panel.tsx') -Force
    }
  }
  Save-Backlog $items
  $projectBatch = Get-NextBacklogWorkpackBatch
  Assert-True ($projectBatch -ne $null) 'expected external project channel batch'
  Assert-FrontierReportShape -Report $projectBatch.frontier_report -Name 'external-project'
  Assert-True (@($projectBatch.ids) -contains [string]$idProjectDriver) 'external project driver.ps1 task should be selectable'
  $projectDriverCandidate = Get-FrontierCandidateById -Report $projectBatch.frontier_report -Id $idProjectDriver
  Assert-True ($projectDriverCandidate -and [bool]$projectDriverCandidate.selected) 'expected project driver candidate selected'
  Assert-True ([string]$projectDriverCandidate.block_reason -ne 'control-plane-admission-required') 'external project channel must not receive bridge control-plane block'
  $script:TestChannel = 'main'

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
