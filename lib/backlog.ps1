# backlog.ps1 -- compatibility aggregator for the bridge self-improvement backlog.
# Dot-source this file to load the domain modules that preserve the historical API.

$script:BacklogCuratorModel = 'gemini-2.5-flash-lite'
$script:BacklogLibraryDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { Split-Path -Parent $PSCommandPath }

$script:BacklogModuleDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } elseif (-not [string]::IsNullOrWhiteSpace($script:BacklogLibraryDir)) { $script:BacklogLibraryDir } else { Split-Path -Parent $PSCommandPath }

foreach ($script:BacklogModuleName in @(
  'primitives.ps1',
  'policy.ps1',
  'backlog-io.ps1',
  'backlog-governor.ps1',
  'backlog-crud.ps1',
  'backlog-dedup.ps1',
  'backlog-core.ps1',
  'backlog-autopilot.ps1',
  'backlog-workpack.ps1',
  'backlog-state-reaper.ps1'
)) {
  $script:BacklogModulePath = Join-Path $script:BacklogModuleDir $script:BacklogModuleName
  . $script:BacklogModulePath
}

# Wrap workpack batch helpers here so execution metadata can evolve without
# editing the larger backlog-workpack module in every stream.
if (-not $script:BacklogOriginalGetBacklogWorkpackFrontierReport) {
  try { $script:BacklogOriginalGetBacklogWorkpackFrontierReport = (Get-Command Get-BacklogWorkpackFrontierReport -CommandType Function -ErrorAction Stop).ScriptBlock } catch {}
}
if (-not $script:BacklogOriginalGetNextBacklogWorkpackBatch) {
  try { $script:BacklogOriginalGetNextBacklogWorkpackBatch = (Get-Command Get-NextBacklogWorkpackBatch -CommandType Function -ErrorAction Stop).ScriptBlock } catch {}
}
if (-not $script:BacklogOriginalNewBacklogWorkpackBatchTaskText) {
  try { $script:BacklogOriginalNewBacklogWorkpackBatchTaskText = (Get-Command New-BacklogWorkpackBatchTaskText -CommandType Function -ErrorAction Stop).ScriptBlock } catch {}
}

function Get-BacklogWorkpackPerTaskTimeoutSec {
  return 600
}

function Get-BacklogWorkpackDispatchTimeoutMin {
  param(
    [int]$TaskCount = 1,
    [int]$PerTaskTimeoutSec = 600,
    [bool]$Parallel = $true
  )

  $safeTaskCount = [Math]::Max(1, [int]$TaskCount)
  $safePerTaskTimeoutSec = [Math]::Max(1, [int]$PerTaskTimeoutSec)
  if ($Parallel) { return [int][Math]::Ceiling($safePerTaskTimeoutSec / 60.0) }
  return [int][Math]::Ceiling(($safeTaskCount * $safePerTaskTimeoutSec) / 60.0)
}

function Set-BacklogWorkpackMetadataValue {
  param(
    $Target,
    [string]$Name,
    $Value
  )

  if ($null -eq $Target -or [string]::IsNullOrWhiteSpace($Name)) { return }
  if ($Target -is [System.Collections.IDictionary]) {
    $Target[$Name] = $Value
    return
  }
  try { $Target | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force } catch {}
}

function Add-BacklogWorkpackBatchExecutionMetadata {
  param($Target)

  if ($null -eq $Target) { return $null }

  $items = @()
  try { $items = @((Get-BacklogPackObjectValue -Obj $Target -Name 'items' -Default @()) | Where-Object { $_ }) } catch { $items = @() }

  $count = 0
  try { $count = [int](Get-BacklogPackObjectValue -Obj $Target -Name 'count' -Default 0) } catch { $count = 0 }
  if ($count -lt 1) {
    try { $count = [int](Get-BacklogPackObjectValue -Obj $Target -Name 'selected_count' -Default 0) } catch { $count = 0 }
  }
  if ($count -lt 1) { $count = $items.Count }

  $frontierReport = $null
  try { $frontierReport = Get-BacklogPackObjectValue -Obj $Target -Name 'frontier_report' -Default $null } catch { $frontierReport = $null }
  if ($count -lt 1 -and $frontierReport) {
    try { $count = [int](Get-BacklogPackObjectValue -Obj $frontierReport -Name 'selected_count' -Default 0) } catch { $count = 0 }
  }
  if ($count -lt 1) { $count = 1 }

  $mode = ''
  try { $mode = [string](Get-BacklogPackObjectValue -Obj $Target -Name 'workpack_batch_mode' -Default '') } catch { $mode = '' }
  if ([string]::IsNullOrWhiteSpace($mode) -and $frontierReport) {
    try { $mode = [string](Get-BacklogPackObjectValue -Obj $frontierReport -Name 'workpack_batch_mode' -Default '') } catch { $mode = '' }
  }

  $serialRequired = $false
  try { $serialRequired = [bool](Get-BacklogPackObjectValue -Obj $Target -Name 'serial_required' -Default $false) } catch { $serialRequired = $false }
  if ((-not $serialRequired) -and $frontierReport) {
    try { $serialRequired = [bool](Get-BacklogPackObjectValue -Obj $frontierReport -Name 'serial_required' -Default $false) } catch { $serialRequired = $false }
  }

  $perTaskTimeoutSec = Get-BacklogWorkpackPerTaskTimeoutSec
  $autoParallel = (($mode -eq 'parallel') -and (-not $serialRequired) -and ($count -gt 1))
  $parallelTimeoutMin = Get-BacklogWorkpackDispatchTimeoutMin -TaskCount $count -PerTaskTimeoutSec $perTaskTimeoutSec -Parallel $true
  $serialTimeoutMin = Get-BacklogWorkpackDispatchTimeoutMin -TaskCount $count -PerTaskTimeoutSec $perTaskTimeoutSec -Parallel $false
  $timeoutMin = if ($autoParallel) { $parallelTimeoutMin } else { $serialTimeoutMin }

  foreach ($metaTarget in @($Target, $frontierReport)) {
    if ($null -eq $metaTarget) { continue }
    Set-BacklogWorkpackMetadataValue -Target $metaTarget -Name 'per_task_timeout_sec' -Value $perTaskTimeoutSec
    Set-BacklogWorkpackMetadataValue -Target $metaTarget -Name 'timeout_min' -Value $timeoutMin
    Set-BacklogWorkpackMetadataValue -Target $metaTarget -Name 'parallel_timeout_min' -Value $parallelTimeoutMin
    Set-BacklogWorkpackMetadataValue -Target $metaTarget -Name 'serial_timeout_min' -Value $serialTimeoutMin
    Set-BacklogWorkpackMetadataValue -Target $metaTarget -Name 'auto_parallel' -Value $autoParallel
  }

  return $Target
}

function Get-BacklogWorkpackFrontierReport {
  param($Config = $null)
  if (-not $script:BacklogOriginalGetBacklogWorkpackFrontierReport) { return $null }
  $report = & $script:BacklogOriginalGetBacklogWorkpackFrontierReport -Config $Config
  return (Add-BacklogWorkpackBatchExecutionMetadata -Target $report)
}

function Get-NextBacklogWorkpackBatch {
  param($Config = $null)
  if (-not $script:BacklogOriginalGetNextBacklogWorkpackBatch) { return $null }
  $batch = & $script:BacklogOriginalGetNextBacklogWorkpackBatch -Config $Config
  return (Add-BacklogWorkpackBatchExecutionMetadata -Target $batch)
}

function New-BacklogWorkpackBatchTaskText {
  param([object[]]$Items)

  if (-not $script:BacklogOriginalNewBacklogWorkpackBatchTaskText) { return '' }
  $taskText = & $script:BacklogOriginalNewBacklogWorkpackBatchTaskText -Items $Items
  $itemsArr = @($Items | Where-Object { $_ })
  $perTaskTimeoutSec = Get-BacklogWorkpackPerTaskTimeoutSec
  $autoParallel = ($itemsArr.Count -gt 1)
  $timeoutMin = Get-BacklogWorkpackDispatchTimeoutMin -TaskCount $itemsArr.Count -PerTaskTimeoutSec $perTaskTimeoutSec -Parallel $autoParallel

  $lines = @($taskText -split "\r?\n")
  $header = @(
    ('auto_parallel: ' + ($(if ($autoParallel) { 'true' } else { 'false' }))),
    ('per_task_timeout_sec: ' + $perTaskTimeoutSec),
    ('timeout_min: ' + $timeoutMin),
    ''
  )

  if ($lines.Count -ge 2) {
    $lines = @($lines[0], $lines[1]) + $header + @($lines[2..($lines.Count - 1)])
  } else {
    $lines = @($lines) + $header
  }

  $rendered = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in $lines) {
    [void]$rendered.Add([string]$line)
    if ($line -match '^[Cc]omplexity:\s+') {
      [void]$rendered.Add(('timeout_sec: ' + $perTaskTimeoutSec))
    }
  }

  return (($rendered.ToArray()) -join [Environment]::NewLine).Trim()
}

if (-not $script:BacklogOriginalTestIdeaBridgeSelfAdmitted) {
  try { $script:BacklogOriginalTestIdeaBridgeSelfAdmitted = (Get-Command Test-IdeaBridgeSelfAdmitted -CommandType Function -ErrorAction Stop).ScriptBlock } catch {}
}

function Test-BridgeSelfAdmissionEvidence {
  param(
    $Idea,
    $Admission
  )

  $missing = New-Object 'System.Collections.Generic.List[string]'
  if (-not $Admission) { return [pscustomobject]@{ ok=$false; missing=@('bridge_self_admission') } }

  $mode = ([string](Get-BacklogPackObjectValue -Obj $Admission -Name 'mode' -Default '')).Trim().ToLowerInvariant()
  if ($mode -ne 'bridge_self_canary') { [void]$missing.Add('mode=bridge_self_canary') }

  $canaryRequired = $false
  try { $canaryRequired = [bool](Test-BacklogClaimTruthy (Get-BacklogPackObjectValue -Obj $Admission -Name 'canary_required' -Default $false)) } catch { $canaryRequired = $false }
  if (-not $canaryRequired) { [void]$missing.Add('canary_required=true') }

  $checks = New-Object 'System.Collections.Generic.List[string]'
  foreach ($source in @(
      (Get-BacklogPackObjectValue -Obj $Admission -Name 'checks' -Default @()),
      (Get-BacklogPackObjectValue -Obj $Idea -Name 'checks' -Default @()),
      (Get-BacklogPackObjectValue -Obj $Idea -Name 'verification_checks' -Default @())
    )) {
    foreach ($check in @(ConvertTo-BacklogClaimStringArray $source)) {
      if (-not [string]::IsNullOrWhiteSpace([string]$check) -and -not $checks.Contains([string]$check)) { [void]$checks.Add([string]$check) }
    }
  }
  $checksArr = @($checks.ToArray())
  if (-not (Test-BacklogClaimTextMatch -Values $checksArr -Pattern '(?i)driver\.ps1.*-SelfTest|self[- ]?test')) { [void]$missing.Add('driver_selftest_check') }
  if (-not (Test-BacklogClaimTextMatch -Values $checksArr -Pattern '(?i)smoke\.ps1|smoke')) { [void]$missing.Add('smoke_check') }
  if (-not (Test-BacklogClaimTextMatch -Values $checksArr -Pattern '(?i)canary|Invoke-CanaryCycle')) { [void]$missing.Add('canary_evidence') }

  $rollback = [string](Get-BacklogPackObjectValue -Obj $Admission -Name 'rollback_plan' -Default '')
  if ([string]::IsNullOrWhiteSpace($rollback)) { $rollback = [string](Get-BacklogPackObjectValue -Obj $Admission -Name 'rollback' -Default '') }
  if ([string]::IsNullOrWhiteSpace($rollback)) { [void]$missing.Add('rollback_plan') }

  return [pscustomobject]@{
    ok = ($missing.Count -eq 0)
    missing = @($missing.ToArray())
    checks = @($checksArr)
    rollback_plan = $rollback
  }
}

function Test-IdeaBridgeSelfAdmitted {
  param($Idea)

  if (-not $script:BacklogOriginalTestIdeaBridgeSelfAdmitted) {
    return [pscustomobject]@{ ok=$false; reason='bridge_self_admission checker unavailable'; missing=@('bridge_self_admission_checker') }
  }
  $base = & $script:BacklogOriginalTestIdeaBridgeSelfAdmitted -Idea $Idea
  if (-not ($base -and [bool]$base.ok)) { return $base }

  $admission = $null
  try { $admission = Get-IdeaBridgeSelfAdmission -Idea $Idea } catch { $admission = $null }
  $evidence = Test-BridgeSelfAdmissionEvidence -Idea $Idea -Admission $admission
  if (-not [bool]$evidence.ok) {
    return [pscustomobject]@{
      ok = $false
      reason = 'bridge_self_admission incomplete: ' + ((@($evidence.missing) | Sort-Object -Unique) -join ', ')
      missing = @($evidence.missing)
      checks = @($evidence.checks)
      rollback_plan = [string]$evidence.rollback_plan
    }
  }
  try {
    $base | Add-Member -NotePropertyName canary_evidence -NotePropertyValue $true -Force
    $base | Add-Member -NotePropertyName checks -NotePropertyValue @($evidence.checks) -Force
    $base | Add-Member -NotePropertyName rollback_plan -NotePropertyValue ([string]$evidence.rollback_plan) -Force
  } catch {}
  return $base
}

function Get-FeatureVerifierLatestDigestPath {
  param([string]$BridgeRoot = '')
  if ([string]::IsNullOrWhiteSpace($BridgeRoot)) { $BridgeRoot = Get-BacklogFallbackBridgeRoot }
  $auditDir = Join-Path $BridgeRoot 'audit'
  try {
    $latest = Get-ChildItem -LiteralPath $auditDir -Filter 'feature-verifier-*.md' -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1
    if ($latest) { return [string]$latest.FullName }
  } catch {}
  return ''
}

function Get-FeatureVerifierBrokenEntries {
  param([string]$StatePath)

  $out = New-Object 'System.Collections.Generic.List[object]'
  if ([string]::IsNullOrWhiteSpace($StatePath) -or -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return @() }
  $state = $null
  try {
    $raw = [System.IO.File]::ReadAllText($StatePath, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $state = $raw | ConvertFrom-Json
  } catch { return @() }

  foreach ($prop in @($state.PSObject.Properties)) {
    $entry = $prop.Value
    $health = ''
    try { $health = ([string](Get-BacklogPackObjectValue -Obj $entry -Name 'last_health' -Default '')).Trim().ToLowerInvariant() } catch { $health = '' }
    if ($health -ne 'broken') { continue }
    $scenarioNames = New-Object 'System.Collections.Generic.List[string]'
    try {
      foreach ($sr in @(Get-BacklogPackObjectValue -Obj $entry -Name 'scenario_results' -Default @())) {
        $name = [string](Get-BacklogPackObjectValue -Obj $sr -Name 'scenario' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($name)) { [void]$scenarioNames.Add($name) }
      }
    } catch {}
    $verifiedAt = ''
    try { $verifiedAt = [string](Get-BacklogPackObjectValue -Obj $entry -Name 'last_verified_at' -Default '') } catch { $verifiedAt = '' }
    [void]$out.Add([pscustomobject]@{
      id = [string]$prop.Name
      health = $health
      last_verified_at = $verifiedAt
      scenarios = @($scenarioNames.ToArray())
      raw = $entry
    })
  }
  return @($out.ToArray())
}

function New-FeatureVerifierBugfixTaskRecord {
  param(
    $BrokenEntry,
    [string]$DigestPath = ''
  )

  $featureId = [string](Get-BacklogPackObjectValue -Obj $BrokenEntry -Name 'id' -Default '')
  if ([string]::IsNullOrWhiteSpace($featureId)) { return $null }
  $scenarioText = ''
  try { $scenarioText = (@(Get-BacklogPackObjectValue -Obj $BrokenEntry -Name 'scenarios' -Default @()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ', ' } catch { $scenarioText = '' }
  if ([string]::IsNullOrWhiteSpace($scenarioText)) { $scenarioText = 'linked scenario' }
  $signature = 'feature-verifier-broken:' + $featureId.ToLowerInvariant()
  $reportText = if ([string]::IsNullOrWhiteSpace($DigestPath)) { 'feature verifier digest unavailable' } else { $DigestPath }
  $text = "BUGFIX: Feature verifier reported BROKEN feature '$featureId' ($scenarioText). Diagnose and fix the broken behavior. Report: $reportText"
  return [pscustomobject]@{
    text = $text
    tags = @('bugfix','feature-verifier','auto-diagnostic')
    type = 'bugfix'
    severity = 'critical'
    status = 'approved'
    scope = 'bridge'
    dedupe_signature = $signature
    root_cause_key = $signature
    feature_verifier_report = $DigestPath
    feature_verifier_feature = $featureId
    feature_verifier_health = 'broken'
  }
}

function Test-FeatureVerifierBugfixAlreadyFiled {
  param(
    [object[]]$Items,
    [string]$Signature
  )
  if ([string]::IsNullOrWhiteSpace($Signature)) { return $false }
  foreach ($item in @($Items)) {
    if (-not $item) { continue }
    $status = ([string](Get-BacklogPackObjectValue -Obj $item -Name 'status' -Default '')).Trim().ToLowerInvariant()
    if ($status -in @('done','auto-resolved','rejected','auto-dropped','deduped')) { continue }
    foreach ($field in @('dedupe_signature','root_cause_key','feature_verifier_signature')) {
      $value = [string](Get-BacklogPackObjectValue -Obj $item -Name $field -Default '')
      if ($value -eq $Signature) { return $true }
    }
  }
  return $false
}

function Add-FeatureVerifierBrokenBugfixBacklogItems {
  param(
    [string]$BridgeRoot = '',
    [string]$StatePath = '',
    [string]$DigestPath = '',
    [object[]]$ExistingItems = $null,
    [switch]$DryRun
  )

  if ([string]::IsNullOrWhiteSpace($BridgeRoot)) { $BridgeRoot = Get-BacklogFallbackBridgeRoot }
  if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = Join-Path $BridgeRoot 'features\state.json' }
  if ([string]::IsNullOrWhiteSpace($DigestPath)) { $DigestPath = Get-FeatureVerifierLatestDigestPath -BridgeRoot $BridgeRoot }

  $items = @()
  if ($null -ne $ExistingItems) { $items = @($ExistingItems) }
  elseif (-not $DryRun) { try { $items = @(Get-Backlog) } catch { $items = @() } }

  $created = New-Object 'System.Collections.Generic.List[string]'
  $wouldCreate = New-Object 'System.Collections.Generic.List[object]'
  $existing = New-Object 'System.Collections.Generic.List[string]'

  foreach ($broken in @(Get-FeatureVerifierBrokenEntries -StatePath $StatePath)) {
    $record = New-FeatureVerifierBugfixTaskRecord -BrokenEntry $broken -DigestPath $DigestPath
    if (-not $record) { continue }
    if (Test-FeatureVerifierBugfixAlreadyFiled -Items $items -Signature ([string]$record.dedupe_signature)) {
      [void]$existing.Add([string]$record.dedupe_signature)
      continue
    }
    if ($DryRun) {
      [void]$wouldCreate.Add($record)
      continue
    }
    $id = Add-Idea -Text ([string]$record.text) -From 'feature-verifier' -Tags @($record.tags) -Status 'approved' -Scope 'bridge' -Severity 'critical' -SkipCurator
    if ([string]::IsNullOrWhiteSpace([string]$id)) { continue }
    $latest = @(Get-Backlog)
    foreach ($item in $latest) {
      if ([string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '') -ne [string]$id) { continue }
      foreach ($name in @('type','dedupe_signature','root_cause_key','feature_verifier_report','feature_verifier_feature','feature_verifier_health')) {
        $value = Get-BacklogPackObjectValue -Obj $record -Name $name -Default $null
        Set-BacklogObjectProperty -Item $item -Name $name -Value $value
      }
      break
    }
    Save-Backlog $latest
    $items = $latest
    [void]$created.Add([string]$id)
  }

  return [pscustomobject]@{
    created_count = [int]$created.Count
    created_ids = @($created.ToArray())
    existing_count = [int]$existing.Count
    existing_signatures = @($existing.ToArray())
    would_create_count = [int]$wouldCreate.Count
    would_create = @($wouldCreate.ToArray())
  }
}

Remove-Variable -Name BacklogModuleName -Scope Script -ErrorAction SilentlyContinue
Remove-Variable -Name BacklogModulePath -Scope Script -ErrorAction SilentlyContinue
