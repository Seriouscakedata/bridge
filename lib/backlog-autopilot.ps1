# backlog-autopilot.ps1 -- Project Autopilot planning and expansion helpers.
#region Project Autopilot planning and expansion
# 2026-06-30 (diffusion-trigger-schema-mismatch): load the discuss->autopilot adapter, which
# materializes PROJECT_PLAN.md/PROJECT_MAP.md/contract from the discuss plan board so the
# wide-diffusion contract gate can pass. Provides Convert-DiscussToAutopilotInputs +
# Initialize-ProjectAutopilotInputsFromDiscuss.
if (-not (Get-Command Convert-DiscussToAutopilotInputs -ErrorAction SilentlyContinue)) {
  $script:ProjectAutopilotAdapterPath = Join-Path $PSScriptRoot 'project-autopilot-adapter.ps1'
  if (Test-Path -LiteralPath $script:ProjectAutopilotAdapterPath) { . $script:ProjectAutopilotAdapterPath }
}
# 2026-06-30 (Ch1 diffusion): load the SHADOW wave planner. It projects all atoms into execution waves two
# ways (hard-only vs contract-soft) and emits PROJECT_WAVE_SCHEDULE.json + telemetry -- measurement only,
# NO execution change. Provides Invoke-ProjectAutopilotShadowPlanner; its functions resolve the unified
# graph builder defined below at call-time, so sourcing it here (before that definition) is fine.
if (-not (Get-Command Invoke-ProjectAutopilotShadowPlanner -ErrorAction SilentlyContinue)) {
  $script:ProjectAutopilotPlannerPath = Join-Path $PSScriptRoot 'diffusion-planner.ps1'
  if (Test-Path -LiteralPath $script:ProjectAutopilotPlannerPath) { . $script:ProjectAutopilotPlannerPath }
}
function Get-ProjectAutopilotConfig {
  $cfg = [ordered]@{
    enabled = $true
    cooldownMinutes = 5
    maxTasksPerBatch = 12
    emptyCoordinatorLimit = 3
    diffusionMode = 'off'
    diffusionMinIndependentAtoms = 2
    diffusionMaxWaveSize = 6
    decomposeAheadLimit = 1
    skipBuildOnDocsOnly = $false
    cleanFileOwnership = $false
  }
  $dotted = @{
    'projectAutopilot.enabled' = 'enabled'
    'projectAutopilot.cooldownMinutes' = 'cooldownMinutes'
    'projectAutopilot.maxTasksPerBatch' = 'maxTasksPerBatch'
    'projectAutopilot.emptyCoordinatorLimit' = 'emptyCoordinatorLimit'
    'projectAutopilot.diffusionMode' = 'diffusionMode'
    'projectAutopilot.diffusionMinIndependentAtoms' = 'diffusionMinIndependentAtoms'
    'projectAutopilot.diffusionMaxWaveSize' = 'diffusionMaxWaveSize'
    'projectAutopilot.decomposeAheadLimit' = 'decomposeAheadLimit'
    'projectAutopilot.skipBuildOnDocsOnly' = 'skipBuildOnDocsOnly'
    'projectAutopilot.cleanFileOwnership' = 'cleanFileOwnership'
  }
  $flat = @{
    projectAutopilotEnabled = 'enabled'
    projectAutopilotCooldownMinutes = 'cooldownMinutes'
    projectAutopilotMaxTasksPerBatch = 'maxTasksPerBatch'
    projectAutopilotEmptyCoordinatorLimit = 'emptyCoordinatorLimit'
    projectAutopilotDiffusionMode = 'diffusionMode'
    projectAutopilotDiffusionMinIndependentAtoms = 'diffusionMinIndependentAtoms'
    projectAutopilotDiffusionMaxWaveSize = 'diffusionMaxWaveSize'
    projectAutopilotDecomposeAheadLimit = 'decomposeAheadLimit'
    projectAutopilotSkipBuildOnDocsOnly = 'skipBuildOnDocsOnly'
    projectAutopilotCleanFileOwnership = 'cleanFileOwnership'
  }
  try {
    if (Get-Command Get-AutonomySettings -ErrorAction SilentlyContinue) {
      $auto = Get-AutonomySettings
      foreach ($k in $flat.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $auto -Name $k -Default $null
        if ($null -ne $v) { $cfg[$flat[$k]] = $v }
      }
    }
  } catch {}
  try {
    if (Get-Command Get-Settings -ErrorAction SilentlyContinue) {
      $settings = Get-Settings
      foreach ($k in $dotted.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $settings -Name $k -Default $null
        if ($null -ne $v) { $cfg[$dotted[$k]] = $v }
      }
      foreach ($k in $flat.Keys) {
        $v = Get-BacklogPackObjectValue -Obj $settings -Name $k -Default $null
        if ($null -ne $v) { $cfg[$flat[$k]] = $v }
      }
    }
  } catch {}

  $cfg.enabled = ConvertTo-BacklogPackBool -Value $cfg.enabled -Default $true
  $cfg.cooldownMinutes = ConvertTo-BacklogPackInt -Value $cfg.cooldownMinutes -Default 5 -Min 1 -Max 240
  $cfg.maxTasksPerBatch = ConvertTo-BacklogPackInt -Value $cfg.maxTasksPerBatch -Default 12 -Min 1 -Max 50
  $cfg.emptyCoordinatorLimit = ConvertTo-BacklogPackInt -Value $cfg.emptyCoordinatorLimit -Default 3 -Min 1 -Max 20
  $cfg.diffusionMode = ([string]$cfg.diffusionMode).Trim().ToLowerInvariant()
  if ($cfg.diffusionMode -notin @('off','shadow','diffusion','wide')) { $cfg.diffusionMode = 'off' }
  $cfg.diffusionMinIndependentAtoms = ConvertTo-BacklogPackInt -Value $cfg.diffusionMinIndependentAtoms -Default 2 -Min 1 -Max 50
  $cfg.diffusionMaxWaveSize = ConvertTo-BacklogPackInt -Value $cfg.diffusionMaxWaveSize -Default 6 -Min 1 -Max 50
  $cfg.decomposeAheadLimit = ConvertTo-BacklogPackInt -Value $cfg.decomposeAheadLimit -Default 1 -Min 1 -Max 8
  $cfg.skipBuildOnDocsOnly = ConvertTo-BacklogPackBool -Value $cfg.skipBuildOnDocsOnly -Default $false
  $cfg.cleanFileOwnership = ConvertTo-BacklogPackBool -Value $cfg.cleanFileOwnership -Default $false
  return [pscustomobject]$cfg
}

function Test-ProjectAutopilotAtomDocsOnly {
  # True iff EVERY path in the atom touch-set is documentation/text. Used (gated by skipBuildOnDocsOnly) to
  # strip the heavy per-atom project build/typecheck from a docs-only atom's checks — a markdown/text edit
  # cannot break the compile, and the full build still runs at chapter-close acceptance. Conservative:
  # empty/unknown touch-set -> $false (never strip when we don't know what the atom touches).
  param([string[]]$Paths)
  $list = @($Paths | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($list.Count -eq 0) { return $false }
  foreach ($p in $list) {
    $n = (($p -replace '\\','/').Trim()).TrimStart('.').TrimStart('/')
    $isDoc = ($n -match '^(?i:(docs|memory|decisions)/)') -or ($n -match '\.(?i:md|markdown|mdx|txt)$')
    if (-not $isDoc) { return $false }
  }
  return $true
}

function Get-ProjectAutopilotStatePath {
  $dir = ''
  try { $dir = Split-Path -Parent (Get-BacklogPath) } catch {}
  if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Get-BacklogFallbackBridgeRoot }
  return (Join-Path $dir 'project-autopilot.last.json')
}

function Read-ProjectAutopilotState {
  $p = Get-ProjectAutopilotStatePath
  if (-not (Test-Path -LiteralPath $p)) { return $null }
  try { return ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Write-ProjectAutopilotState {
  param($State)
  try {
    $json = ($State | ConvertTo-Json -Compress -Depth 6) + "`n"
    Write-BacklogAtomicFile -Path (Get-ProjectAutopilotStatePath) -Content $json
  } catch {}
}

function Test-ProjectAutopilotCoordinatorItem {
  param($Item)
  if (-not $Item) { return $false }
  $text = [string](Get-BacklogPackObjectValue -Obj $Item -Name 'text' -Default '')
  return (Test-ProjectAutopilotCoordinatorText -Text $text)
}

function Test-ProjectAutopilotCoordinatorText {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  return [bool]($Text -match '(?is)\[project-autopilot\s+[^\]]+\].*Project Autopilot coordinator for channel')
}

function Test-ProjectAutopilotCoordinatorHasChildren {
  param(
    [string]$CoordinatorId,
    [object[]]$Items
  )
  if ([string]::IsNullOrWhiteSpace($CoordinatorId)) { return $false }
  foreach ($it in @($Items)) {
    $src = [string](Get-BacklogPackObjectValue -Obj $it -Name 'autopilot_source_task' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($src) -and $src -eq $CoordinatorId) { return $true }
  }
  return $false
}

function Get-ProjectAutopilotInferredEmptyCoordinatorStreak {
  param([string]$ExcludeCoordinatorId = '')
  $items = @(Get-Backlog)
  # 2026-06-14 (operator root-fix): a plan re-approval baselines empty_streak_reset_ts. Coordinators
  # emitted BEFORE that baseline are NOT counted, so re-approving an expanded release scope clears the
  # empty-coordinator-streak pause and the autopilot resumes instead of staying deadlocked on an old
  # 'release done' streak.
  $resetTs = [datetime]::MinValue
  try {
    $apSt = Read-ProjectAutopilotState
    $rt = if ($apSt) { [string](Get-BacklogPackObjectValue -Obj $apSt -Name 'empty_streak_reset_ts' -Default '') } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($rt)) { $resetTs = [datetime]::Parse($rt).ToUniversalTime() }
  } catch {}
  $coordinators = @($items |
    Where-Object {
      (Test-ProjectAutopilotCoordinatorItem -Item $_) -and
      ([string](Get-BacklogPackObjectValue -Obj $_ -Name 'id' -Default '') -ne [string]$ExcludeCoordinatorId)
    } |
    Sort-Object {
      try { [datetime]::Parse([string](Get-BacklogPackObjectValue -Obj $_ -Name 'ts' -Default '')).ToUniversalTime() } catch { [datetime]::MinValue }
    } -Descending)

  $streak = 0
  foreach ($it in $coordinators) {
    $cts = [datetime]::MinValue
    try { $cts = [datetime]::Parse([string](Get-BacklogPackObjectValue -Obj $it -Name 'ts' -Default '')).ToUniversalTime() } catch {}
    if ($cts -lt $resetTs) { break }
    $status = [string](Get-BacklogPackObjectValue -Obj $it -Name 'status' -Default '')
    if ($status -in @('approved','running','new')) { continue }
    if ($status -ne 'done') { break }
    $id = [string](Get-BacklogPackObjectValue -Obj $it -Name 'id' -Default '')
    if (Test-ProjectAutopilotCoordinatorHasChildren -CoordinatorId $id -Items $items) { break }
    $streak++
  }
  return $streak
}

function Get-ProjectAutopilotStateInt {
  param($State, [string]$Name, [int]$Default = 0)
  if (-not $State) { return $Default }
  try {
    if ($State.PSObject.Properties.Name -contains $Name) {
      return [int]($State.$Name)
    }
  } catch {}
  return $Default
}

function Get-ProjectAutopilotRecentOutcomes {
  param($State)
  if (-not $State) { return @() }
  try { return @($State.recent_outcomes | Where-Object { $_ }) } catch { return @() }
}

function Record-ProjectAutopilotCoordinatorOutcome {
  param(
    [string]$Channel = '',
    [string]$ProjectRoot = '',
    [string]$CoordinatorId = '',
    [int]$Created = 0,
    [string]$Reason = 'coordinator-done'
  )
  $cfg = Get-ProjectAutopilotConfig
  $limit = [Math]::Max(1, [Math]::Min(20, [int]$cfg.emptyCoordinatorLimit))
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-ProjectAutopilotSlug }
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    try {
      $binding = Get-ProjectAutopilotBinding
      if ($binding) { $ProjectRoot = [string]$binding.project_root }
    } catch {}
  }

  $last = Read-ProjectAutopilotState
  if (-not $last) { $last = [pscustomobject]@{} }
  $recent = @(Get-ProjectAutopilotRecentOutcomes -State $last)
  if (-not [string]::IsNullOrWhiteSpace($CoordinatorId)) {
    foreach ($r in $recent) {
      if ([string](Get-BacklogPackObjectValue -Obj $r -Name 'id' -Default '') -eq $CoordinatorId) {
        return [pscustomobject]@{
          recorded = $false
          reason = 'already-recorded'
          paused = [bool](Get-BacklogPackObjectValue -Obj $last -Name 'paused' -Default $false)
          empty_coordinator_streak = (Get-ProjectAutopilotStateInt -State $last -Name 'empty_coordinator_streak' -Default 0)
          limit = $limit
        }
      }
    }
  }

  $createdCount = [Math]::Max(0, [int]$Created)
  $hasStateStreak = $false
  try { $hasStateStreak = ($last.PSObject.Properties.Name -contains 'empty_coordinator_streak') } catch {}
  $streak = 0
  if ($hasStateStreak) {
    $streak = Get-ProjectAutopilotStateInt -State $last -Name 'empty_coordinator_streak' -Default 0
    try {
      $inferredForState = [int](Get-ProjectAutopilotInferredEmptyCoordinatorStreak -ExcludeCoordinatorId $CoordinatorId)
      if ($inferredForState -gt $streak) { $streak = $inferredForState }
    } catch {}
  } else {
    try { $streak = [int](Get-ProjectAutopilotInferredEmptyCoordinatorStreak -ExcludeCoordinatorId $CoordinatorId) } catch { $streak = 0 }
  }

  $wasPaused = [bool](Get-BacklogPackObjectValue -Obj $last -Name 'paused' -Default $false)
  $paused = $wasPaused
  $pauseReason = [string](Get-BacklogPackObjectValue -Obj $last -Name 'pause_reason' -Default '')
  $pausedAt = [string](Get-BacklogPackObjectValue -Obj $last -Name 'paused_at' -Default '')
  $outcome = 'empty'

  if ($createdCount -gt 0) {
    $streak = 0
    $paused = $false
    $pauseReason = ''
    $pausedAt = ''
    $outcome = 'created'
  } else {
    $streak++
    if ($streak -ge $limit) {
      $paused = $true
      if ([string]::IsNullOrWhiteSpace($pausedAt)) { $pausedAt = (Get-Date).ToUniversalTime().ToString('o') }
      $pauseReason = "empty coordinator streak reached $streak/$limit without PROJECT_BACKLOG"
    }
  }

  $now = (Get-Date).ToUniversalTime().ToString('o')
  $recent += [pscustomobject]@{
    id = [string]$CoordinatorId
    ts = $now
    created = $createdCount
    outcome = $outcome
  }
  $recent = @($recent | Select-Object -Last 10)

  $last | Add-Member -NotePropertyName ts -NotePropertyValue $now -Force
  $last | Add-Member -NotePropertyName channel -NotePropertyValue ([string]$Channel) -Force
  if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) { $last | Add-Member -NotePropertyName project_root -NotePropertyValue ([string]$ProjectRoot) -Force }
  $last | Add-Member -NotePropertyName empty_coordinator_streak -NotePropertyValue ([int]$streak) -Force
  $last | Add-Member -NotePropertyName paused -NotePropertyValue ([bool]$paused) -Force
  $last | Add-Member -NotePropertyName paused_at -NotePropertyValue ([string]$pausedAt) -Force
  $last | Add-Member -NotePropertyName pause_reason -NotePropertyValue ([string]$pauseReason) -Force
  $last | Add-Member -NotePropertyName recent_outcomes -NotePropertyValue @($recent) -Force
  $last | Add-Member -NotePropertyName last_outcome_id -NotePropertyValue ([string]$CoordinatorId) -Force
  $last | Add-Member -NotePropertyName last_outcome_created -NotePropertyValue ([int]$createdCount) -Force
  $last | Add-Member -NotePropertyName last_outcome_reason -NotePropertyValue ([string]$Reason) -Force
  Write-ProjectAutopilotState $last

  try {
    Write-BacklogJsonLine ([ordered]@{
      ts = $now
      action = 'project-autopilot-outcome'
      channel = [string]$Channel
      item_id = [string]$CoordinatorId
      created = [int]$createdCount
      empty_coordinator_streak = [int]$streak
      paused = [bool]$paused
      limit = [int]$limit
    })
  } catch {}

  if ($paused -and -not $wasPaused) {
    try {
      Write-BacklogJsonLine ([ordered]@{ ts=$now; action='project-autopilot-paused'; channel=[string]$Channel; item_id=[string]$CoordinatorId; reason=$pauseReason })
    } catch {}
    try {
      Add-Message -From system -Text ("⏸ Project Autopilot: проектный backlog исчерпан; последние " + [int]$streak + " coordinator-задачи не создали PROJECT_BACKLOG. Автопилот канала " + [string]$Channel + " поставлен на паузу. Нужно расширить PROJECT_PLAN/scope или вручную добавить задачи.") -Kind event | Out-Null
    } catch {}
  }

  return [pscustomobject]@{
    recorded = $true
    reason = $outcome
    created = [int]$createdCount
    paused = [bool]$paused
    empty_coordinator_streak = [int]$streak
    limit = [int]$limit
  }
}

function Get-ProjectAutopilotSlug {
  try {
    if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { return [string](Get-EffectiveChannel) }
  } catch {}
  if (-not [string]::IsNullOrWhiteSpace([string]$env:BRIDGE_CHANNEL)) { return [string]$env:BRIDGE_CHANNEL }
  return 'main'
}

function Write-ProjectAutopilotCoordinatorCostMetric {
  param(
    [string]$Channel = '',
    [string]$ChapterHint = '',
    [double]$WallclockSec = 0,
    [object]$LlmCallsCount = $null,
    [int]$AtomsEmitted = 0
  )
  $root = ''
  try {
    if (Get-Command Get-BridgeRoot -ErrorAction SilentlyContinue) { $root = Get-BridgeRoot }
  } catch {}
  if ([string]::IsNullOrWhiteSpace($root)) { $root = Split-Path -Parent $PSScriptRoot }
  $path = Join-Path (Join-Path $root 'tmp') 'coordinator-cost.jsonl'
  $entry = [ordered]@{
    ts = (Get-Date).ToUniversalTime().ToString('o')
    channel = [string]$Channel
    chapter_hint = [string]$ChapterHint
    wallclock_sec = [Math]::Round([double]$WallclockSec, 3)
    llm_calls_count = $LlmCallsCount
    atoms_emitted = [int]$AtomsEmitted
  }
  $json = $entry | ConvertTo-Json -Compress -Depth 6
  if ([string]::IsNullOrWhiteSpace($json) -or $json -match "[`r`n]") { throw 'invalid coordinator cost metric json' }
  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::AppendAllText($path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
  return $path
}

function Get-ProjectAutopilotBinding {
  $slug = Get-ProjectAutopilotSlug
  if ([string]::IsNullOrWhiteSpace($slug) -or $slug -eq 'main') { return $null }
  try {
    if (Get-Command Get-ChannelProjectBinding -ErrorAction SilentlyContinue) {
      $b = Get-ChannelProjectBinding -Slug $slug
      if ($b -and [bool]$b.ok -and -not [string]::IsNullOrWhiteSpace([string]$b.project_root)) { return $b }
    }
  } catch {}
  return $null
}

function Get-ProjectAutopilotBacklogPressure {
  $items = @(Get-Backlog)
  $approved = 0; $running = 0; $new = 0; $held = 0; $autopilotOpen = 0
  foreach ($it in $items) {
    $st = [string](Get-BacklogPackObjectValue -Obj $it -Name 'status' -Default '')
    $tags = @()
    try { $tags = @($it.tags | ForEach-Object { [string]$_ }) } catch { $tags = @() }
    if ($st -eq 'approved') { $approved++ }
    elseif ($st -eq 'running') { $running++ }
    elseif ($st -eq 'new') { $new++ }
    elseif ($st -eq 'held') { $held++ }
    if (($st -eq 'approved' -or $st -eq 'running') -and ($tags -contains 'project-autopilot')) { $autopilotOpen++ }
  }
  return [pscustomobject]@{
    approved = $approved
    running = $running
    new = $new
    held = $held
    runnable = ($approved + $running)
    autopilot_open = $autopilotOpen
  }
}

function Test-ProjectAutopilotProjectClean {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { return $false }
  try {
    $git = 'git'
    try { if (Get-Command Get-GitExe -ErrorAction SilentlyContinue) { $git = Get-GitExe } } catch { $git = 'git' }
    $result = Invoke-BacklogProcess -FilePath $git -Arguments @('-c', "safe.directory=$ProjectRoot", '-C', $ProjectRoot, 'status', '--porcelain') -WorkingDirectory $ProjectRoot -TimeoutSec 30
    if ($result.TimedOut -or $result.ExitCode -ne 0) { return $false }
    $dirty = @($result.Output | ForEach-Object { [string]$_ -split "\r?\n" } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    return ($dirty.Count -eq 0)
  } catch {
    return $false
  }
}

function Get-ProjectAutopilotPlanContractPath {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return '' }
  return (Join-Path (Join-Path $ProjectRoot '.bridge') 'project-contract.json')
}

function Get-ProjectAutopilotInterfaceContractDir {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return '' }
  return (Join-Path (Join-Path (Join-Path $ProjectRoot '.bridge') 'specs') 'contracts')
}

function ConvertTo-ProjectAutopilotCanonicalValue {
  param($Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [string] -or $Value -is [bool] -or $Value -is [char]) { return $Value }
  if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) { return $Value }
  if ($Value -is [System.Collections.IDictionary]) {
    $map = [ordered]@{}
    foreach ($key in @($Value.Keys | ForEach-Object { [string]$_ } | Sort-Object)) {
      if ($key -in @('content_hash','computed_hash','frozen_hash','hash')) { continue }
      $map[$key] = ConvertTo-ProjectAutopilotCanonicalValue -Value $Value[$key]
    }
    return $map
  }
  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $arr = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @($Value)) { [void]$arr.Add((ConvertTo-ProjectAutopilotCanonicalValue -Value $item)) }
    return @($arr.ToArray())
  }
  $props = @()
  try { $props = @($Value.PSObject.Properties | Where-Object { $_.MemberType -match 'Property' } | Select-Object -ExpandProperty Name | Sort-Object) } catch { $props = @() }
  if ($props.Count -eq 0) { return [string]$Value }
  $obj = [ordered]@{}
  foreach ($name in $props) {
    if ($name -in @('content_hash','computed_hash','frozen_hash','hash')) { continue }
    $obj[$name] = ConvertTo-ProjectAutopilotCanonicalValue -Value $Value.$name
  }
  return $obj
}

function Get-ProjectAutopilotCanonicalJson {
  param($Value)
  return ((ConvertTo-ProjectAutopilotCanonicalValue -Value $Value) | ConvertTo-Json -Compress -Depth 10)
}

function Get-ProjectAutopilotInterfaceContractCanonicalPayload {
  param($Contract)
  return [ordered]@{
    signature = Get-ProjectAutopilotContractValue -Obj $Contract -Names @('signature') -Default $null
    behavior = Get-ProjectAutopilotContractValue -Obj $Contract -Names @('behavior') -Default $null
    invariants = Get-ProjectAutopilotContractValue -Obj $Contract -Names @('invariants') -Default $null
    errors = Get-ProjectAutopilotContractValue -Obj $Contract -Names @('errors','error_taxonomy','failure_taxonomy') -Default $null
    golden_examples = Get-ProjectAutopilotContractValue -Obj $Contract -Names @('golden_examples','goldenExamples','examples') -Default @()
    owned_files = @(ConvertTo-ProjectAutopilotPathArray (Get-ProjectAutopilotContractValue -Obj $Contract -Names @('owned_files','ownedFiles') -Default @()))
    owned_regions = @(Get-ProjectAutopilotContractValue -Obj $Contract -Names @('owned_regions','ownedRegions') -Default @())
  }
}

function Get-ProjectAutopilotInterfaceContractHash {
  param($Contract)
  try { return (Get-ProjectAutopilotSha256 (Get-ProjectAutopilotCanonicalJson -Value (Get-ProjectAutopilotInterfaceContractCanonicalPayload -Contract $Contract))) } catch { return '' }
}

function Get-ProjectAutopilotContractFreezeDir {
  param([string]$ProjectRoot, [string]$Channel = '')
  $slug = ([string]$Channel).Trim()
  if ([string]::IsNullOrWhiteSpace($slug)) {
    try { $slug = [string](Get-EffectiveChannel) } catch { $slug = 'main' }
  }
  $channelDir = ''
  try { $channelDir = [string](Get-ChannelDir -Slug $slug) } catch { $channelDir = '' }
  if ([string]::IsNullOrWhiteSpace($channelDir)) { return '' }
  $keySource = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { 'unknown-project' } else { ([string]$ProjectRoot).Trim().ToLowerInvariant() }
  $projectKey = (Get-ProjectAutopilotSha256 -Text $keySource)
  if ([string]::IsNullOrWhiteSpace($projectKey)) { $projectKey = 'unknown-project' }
  return (Join-Path (Join-Path $channelDir 'diffusion-contract-freezes') $projectKey)
}

function Get-ProjectAutopilotInterfaceContractLockPath {
  param([string]$ProjectRoot, [string]$Channel = '', [string]$ContractId)
  $dir = Get-ProjectAutopilotContractFreezeDir -ProjectRoot $ProjectRoot -Channel $Channel
  if ([string]::IsNullOrWhiteSpace($dir) -or [string]::IsNullOrWhiteSpace($ContractId)) { return '' }
  return (Join-Path $dir ((ConvertTo-ProjectAutopilotSlug $ContractId) + '.lock.json'))
}

function Read-ProjectAutopilotInterfaceContractLock {
  param([string]$ProjectRoot, [string]$Channel = '', [string]$ContractId)
  $path = Get-ProjectAutopilotInterfaceContractLockPath -ProjectRoot $ProjectRoot -Channel $Channel -ContractId $ContractId
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try {
    return ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Test-ProjectAutopilotGoldenExamplesWellFormed {
  param($Examples)
  foreach ($ex in @($Examples)) {
    if ($null -eq $ex) { continue }
    $input = Get-ProjectAutopilotContractValue -Obj $ex -Names @('input','inputs','given') -Default $null
    $output = Get-ProjectAutopilotContractValue -Obj $ex -Names @('output','outputs','result','expected') -Default $null
    $inputJson = if ($null -eq $input) { '' } else { [string]($input | ConvertTo-Json -Compress -Depth 8) }
    $outputJson = if ($null -eq $output) { '' } else { [string]($output | ConvertTo-Json -Compress -Depth 8) }
    if (-not [string]::IsNullOrWhiteSpace($inputJson) -and -not [string]::IsNullOrWhiteSpace($outputJson)) { return $true }
  }
  return $false
}

function Get-ProjectAutopilotOpenQuestionText {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { return '' }
  $parts = New-Object 'System.Collections.Generic.List[string]'
  $roots = @($ProjectRoot, (Join-Path $ProjectRoot '.bridge'))
  foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    try {
      foreach ($file in @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.md','.json') })) {
        $text = Get-ProjectAutopilotFileText -Path $file.FullName
        if ($text -match 'PROJECT_OPEN_QUESTION|open[-_ ]question|blocking question') { [void]$parts.Add($text) }
      }
    } catch {}
  }
  foreach ($sub in @('.bridge\changes','.bridge\specs')) {
    $dir = Join-Path $ProjectRoot $sub
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
    try {
      foreach ($file in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Include '*.md','*.json' -ErrorAction SilentlyContinue | Select-Object -First 200)) {
        $text = Get-ProjectAutopilotFileText -Path $file.FullName
        if ($text -match 'PROJECT_OPEN_QUESTION|open[-_ ]question|blocking question') { [void]$parts.Add($text) }
      }
    } catch {}
  }
  return (($parts.ToArray()) -join "`n")
}

function Test-ProjectAutopilotContractOpenQuestionBlocked {
  param([string]$ContractId, [string]$OpenQuestionText = '')
  if ([string]::IsNullOrWhiteSpace($ContractId) -or [string]::IsNullOrWhiteSpace($OpenQuestionText)) { return $false }
  $escaped = [regex]::Escape($ContractId)
  return ([regex]::IsMatch($OpenQuestionText, "(?is)(PROJECT_OPEN_QUESTION|open[-_ ]question|blocking question).{0,240}\b$escaped\b|\b$escaped\b.{0,240}(PROJECT_OPEN_QUESTION|open[-_ ]question|blocking question)"))
}

function Get-ProjectAutopilotInterfaceContractId {
  param($Contract, [string]$Path = '')
  $id = ''
  foreach ($name in @('id','contract_id','contractId','name')) {
    try {
      $v = Get-ProjectAutopilotContractValue -Obj $Contract -Names @($name) -Default $null
      if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { $id = [string]$v; break }
    } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($id) -and -not [string]::IsNullOrWhiteSpace($Path)) {
    try { $id = [System.IO.Path]::GetFileNameWithoutExtension($Path) } catch {}
  }
  return (ConvertTo-ProjectAutopilotSlug $id)
}

function Test-ProjectAutopilotInterfaceContract {
  param($Contract, [string]$Path = '', [string]$ProjectRoot = '', [string]$Channel = '', [string]$OpenQuestionText = '')
  $missing = New-Object 'System.Collections.Generic.List[string]'
  $reasons = New-Object 'System.Collections.Generic.List[string]'
  $id = Get-ProjectAutopilotInterfaceContractId -Contract $Contract -Path $Path
  if ([string]::IsNullOrWhiteSpace($id)) { [void]$missing.Add('id') }
  foreach ($field in @('version','signature','behavior','invariants','golden_examples','owned_files')) {
    $v = Get-ProjectAutopilotContractValue -Obj $Contract -Names @($field, ($field -replace '_','')) -Default $null
    if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]($v | ConvertTo-Json -Compress -Depth 8))) { [void]$missing.Add($field) }
  }
  $errors = Get-ProjectAutopilotContractValue -Obj $Contract -Names @('errors','error_taxonomy','failure_taxonomy') -Default $null
  if ($null -eq $errors -or [string]::IsNullOrWhiteSpace([string]($errors | ConvertTo-Json -Compress -Depth 8))) { [void]$missing.Add('errors') }
  $hash = Get-ProjectAutopilotInterfaceContractHash -Contract $Contract
  $version = [string](Get-ProjectAutopilotContractValue -Obj $Contract -Names @('version') -Default '')
  $examples = Get-ProjectAutopilotContractValue -Obj $Contract -Names @('golden_examples','goldenExamples','examples') -Default @()
  $hasGolden = Test-ProjectAutopilotGoldenExamplesWellFormed -Examples $examples
  $openQuestionBlocked = Test-ProjectAutopilotContractOpenQuestionBlocked -ContractId $id -OpenQuestionText $OpenQuestionText
  $lock = Read-ProjectAutopilotInterfaceContractLock -ProjectRoot $ProjectRoot -Channel $Channel -ContractId $id
  $lockStable = ($lock -and (Test-ProjectAutopilotTruthy (Get-ProjectAutopilotContractValue -Obj $lock -Names @('stable','frozen') -Default $false)))
  $lockHash = if ($lock) { [string](Get-ProjectAutopilotContractValue -Obj $lock -Names @('canonical_hash','content_hash','hash') -Default '') } else { '' }
  $lockVersion = if ($lock) { [string](Get-ProjectAutopilotContractValue -Obj $lock -Names @('version') -Default '') } else { '' }
  $hashMatches = (-not [string]::IsNullOrWhiteSpace($lockHash) -and $lockHash.Trim().ToLowerInvariant() -eq $hash)
  $versionMatches = (-not [string]::IsNullOrWhiteSpace($lockVersion) -and $lockVersion -eq $version)
  if ($missing.Count -gt 0) { [void]$reasons.Add('required-field-missing') }
  if (-not $hasGolden) { [void]$reasons.Add('golden-example-missing-or-malformed') }
  if ($openQuestionBlocked) { [void]$reasons.Add('open-question-blocks-contract') }
  if (-not $lockStable) { [void]$reasons.Add('freeze-lock-missing-or-not-stable') }
  if (-not $versionMatches) { [void]$reasons.Add('freeze-lock-version-mismatch') }
  if (-not $hashMatches) { [void]$reasons.Add('freeze-lock-hash-mismatch') }
  $valid = ($missing.Count -eq 0)
  $rawMature = ($valid -and $hasGolden -and -not $openQuestionBlocked)
  $stable = ($rawMature -and $lockStable -and $versionMatches -and $hashMatches)
  return [pscustomobject]@{
    id = $id
    path = [string]$Path
    version = $version
    valid = [bool]$valid
    raw_mature = [bool]$rawMature
    stable = [bool]$stable
    canonical_hash = $hash
    hash = $hash
    lock_path = (Get-ProjectAutopilotInterfaceContractLockPath -ProjectRoot $ProjectRoot -Channel $Channel -ContractId $id)
    lock_present = ($null -ne $lock)
    lock_stable = [bool]$lockStable
    lock_hash = $lockHash
    lock_version = $lockVersion
    hash_matches_lock = [bool]$hashMatches
    version_matches_lock = [bool]$versionMatches
    has_golden_example = [bool]$hasGolden
    open_question_blocked = [bool]$openQuestionBlocked
    missing = @($missing.ToArray())
    maturity_reasons = @($reasons.ToArray() | Sort-Object -Unique)
  }
}

function Get-ProjectAutopilotInterfaceContracts {
  param([string]$ProjectRoot, [string]$Channel = '')
  $dir = Get-ProjectAutopilotInterfaceContractDir -ProjectRoot $ProjectRoot
  if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
  $out = New-Object 'System.Collections.Generic.List[object]'
  # Ch0 hang fix: enumerate the REAL contract files first (excluding schema/lock/freeze/manifest). If there
  # are none, return early WITHOUT calling Get-ProjectAutopilotOpenQuestionText -- that recursive .bridge
  # file-walk (up to 200 .md/.json per dir, ReadAllText+regex each) was the operation that froze the driver
  # heartbeat on diffusion/shadow channels with a populated .bridge tree, even when zero contracts existed.
  $contractFiles = @(Get-ChildItem -LiteralPath $dir -File -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '\.schema\.json$' -and $_.Name -ne 'contract.schema.json' -and $_.Name -notmatch '\.(lock|freeze|manifest)\.json$' } | Sort-Object Name)
  if ($contractFiles.Count -eq 0) { return @() }
  $openQuestionText = Get-ProjectAutopilotOpenQuestionText -ProjectRoot $ProjectRoot
  foreach ($file in $contractFiles) {
    if ($file.Name -match '\.schema\.json$' -or $file.Name -eq 'contract.schema.json') { continue }
    if ($file.Name -match '\.(lock|freeze|manifest)\.json$') { continue }
    try {
      $obj = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      $check = Test-ProjectAutopilotInterfaceContract -Contract $obj -Path $file.FullName -ProjectRoot $ProjectRoot -Channel $Channel -OpenQuestionText $openQuestionText
      $payload = Get-ProjectAutopilotInterfaceContractCanonicalPayload -Contract $obj
      $out.Add([pscustomobject]@{
        id = [string]$check.id
        path = $file.FullName
        contract = $obj
        valid = [bool]$check.valid
        stable = [bool]$check.stable
        raw_mature = [bool]$check.raw_mature
        version = [string]$check.version
        canonical_hash = [string]$check.canonical_hash
        hash = [string]$check.hash
        lock_path = [string]$check.lock_path
        lock_present = [bool]$check.lock_present
        lock_stable = [bool]$check.lock_stable
        lock_hash = [string]$check.lock_hash
        lock_version = [string]$check.lock_version
        hash_matches_lock = [bool]$check.hash_matches_lock
        version_matches_lock = [bool]$check.version_matches_lock
        has_golden_example = [bool]$check.has_golden_example
        open_question_blocked = [bool]$check.open_question_blocked
        owned_files = @($payload.owned_files)
        owned_regions = @($payload.owned_regions)
        missing = @($check.missing)
        maturity_reasons = @($check.maturity_reasons)
      }) | Out-Null
    } catch {
      $out.Add([pscustomobject]@{
        id = ConvertTo-ProjectAutopilotSlug ([System.IO.Path]::GetFileNameWithoutExtension($file.Name))
        path = $file.FullName
        contract = $null
        valid = $false
        stable = $false
        hash = ''
        canonical_hash = ''
        raw_mature = $false
        missing = @('valid_json')
        maturity_reasons = @('valid-json-required')
      }) | Out-Null
    }
  }
  $arr = @($out.ToArray())
  for ($i = 0; $i -lt $arr.Count; $i++) {
    for ($j = $i + 1; $j -lt $arr.Count; $j++) {
      if (Test-ProjectAutopilotPathOverlap -Left @($arr[$i].owned_files) -Right @($arr[$j].owned_files)) {
        foreach ($idx in @($i,$j)) {
          $other = if ($idx -eq $i) { [string]$arr[$j].id } else { [string]$arr[$i].id }
          $reasons2 = @($arr[$idx].maturity_reasons) + @('owned-files-overlap:' + $other)
          $arr[$idx] | Add-Member -NotePropertyName maturity_reasons -NotePropertyValue @($reasons2 | Sort-Object -Unique) -Force
          $arr[$idx] | Add-Member -NotePropertyName stable -NotePropertyValue $false -Force
          $arr[$idx] | Add-Member -NotePropertyName raw_mature -NotePropertyValue $false -Force
        }
      }
    }
  }
  return @($arr)
}

function New-ProjectAutopilotContractFreezeManifest {
  param(
    [object[]]$Tasks = @(),
    [object[]]$Contracts = @(),
    [string]$ProjectRoot = '',
    [string]$Channel = '',
    [string]$Mode = 'shadow',
    [bool]$WriteLocks = $false
  )
  $now = (Get-Date).ToUniversalTime().ToString('o')
  $contractEntries = New-Object 'System.Collections.Generic.List[object]'
  $allOk = $true
  foreach ($contract in @($Contracts)) {
    $id = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $contract -Name 'id' -Default ''))
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $providerAtoms = @($Tasks | Where-Object { @(ConvertTo-ProjectAutopilotSlugArray (Get-BacklogPackObjectValue -Obj $_ -Name 'provides' -Default @())) -contains $id } | ForEach-Object { ConvertTo-ProjectAutopilotSlug (Get-ProjectAutopilotTaskStringField -Task $_ -Names @('slug','id','title')) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $consumerAtoms = @($Tasks | Where-Object { @(ConvertTo-ProjectAutopilotSlugArray (Get-BacklogPackObjectValue -Obj $_ -Name 'consumes' -Default @())) -contains $id } | ForEach-Object { ConvertTo-ProjectAutopilotSlug (Get-ProjectAutopilotTaskStringField -Task $_ -Names @('slug','id','title')) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $version = [string](Get-BacklogPackObjectValue -Obj $contract -Name 'version' -Default '')
    $hash = [string](Get-BacklogPackObjectValue -Obj $contract -Name 'canonical_hash' -Default (Get-BacklogPackObjectValue -Obj $contract -Name 'hash' -Default ''))
    # Ch2: generate the REAL deterministic interface stub a consumer builds against; the lock records the
    # hash of the ACTUAL stub source (not a placeholder constant), so post-freeze stub drift is detectable
    # and Ch3 can write the stub into a consumer-owned file. Falls back to the old placeholder hash if the
    # stub generator is unavailable.
    $stub = $null
    try { if (Get-Command New-ProjectAutopilotContractStub -ErrorAction SilentlyContinue) { $stub = New-ProjectAutopilotContractStub -Contract $contract } } catch { $stub = $null }
    $stubSource = if ($stub) { [string]$stub.source } else { '' }
    $stubLanguage = if ($stub) { [string]$stub.language } else { '' }
    $stubHash = if ($stub -and -not [string]::IsNullOrWhiteSpace([string]$stub.hash)) { [string]$stub.hash } else { Get-ProjectAutopilotSha256 -Text ("contract-stub-v1`n$id`n$version`n$hash") }
    $reasons = @($contract.maturity_reasons)
    $freezeBlockers = @($reasons | Where-Object { $_ -notin @('freeze-lock-missing-or-not-stable','freeze-lock-version-mismatch','freeze-lock-hash-mismatch') })
    $freezeReady = ([bool](Get-BacklogPackObjectValue -Obj $contract -Name 'raw_mature' -Default $false) -and $providerAtoms.Count -gt 0 -and $consumerAtoms.Count -gt 0 -and $freezeBlockers.Count -eq 0)
    if ($providerAtoms.Count -eq 0) { $reasons = @($reasons) + @('provider-atom-missing') }
    if ($consumerAtoms.Count -eq 0) { $reasons = @($reasons) + @('consumer-atom-missing') }
    $lockPath = [string](Get-BacklogPackObjectValue -Obj $contract -Name 'lock_path' -Default '')
    $lockWritten = $false
    $lockError = ''
    if ($WriteLocks -and $freezeReady) {
      try {
        if ([string]::IsNullOrWhiteSpace($lockPath)) { $lockPath = Get-ProjectAutopilotInterfaceContractLockPath -ProjectRoot $ProjectRoot -Channel $Channel -ContractId $id }
        $lockDir = Split-Path -Parent $lockPath
        if (-not (Test-Path -LiteralPath $lockDir -PathType Container)) { New-Item -ItemType Directory -Path $lockDir -Force | Out-Null }
        $lock = [ordered]@{
          lock_schema_version = 1
          contract_id = $id
          version = $version
          canonical_hash = $hash
          stable = $true
          source_path = [string](Get-BacklogPackObjectValue -Obj $contract -Name 'path' -Default '')
          generated_stub_hash = $stubHash
          frozen_at = $now
        }
        [System.IO.File]::WriteAllText($lockPath, (($lock | ConvertTo-Json -Depth 8) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
        $lockWritten = $true
      } catch {
        $lockError = $_.Exception.Message
        $allOk = $false
      }
    }
    if (-not $freezeReady) { $allOk = $false }
    $contractEntries.Add([pscustomobject]@{
      id = $id
      version = $version
      canonical_hash = $hash
      provider_atoms = @($providerAtoms)
      consumer_atoms = @($consumerAtoms)
      owned_files = @(Get-BacklogPackObjectValue -Obj $contract -Name 'owned_files' -Default @())
      owned_regions = @(Get-BacklogPackObjectValue -Obj $contract -Name 'owned_regions' -Default @())
      generated_stub_hash = $stubHash
      generated_stub_language = $stubLanguage
      generated_stub_source = $stubSource
      lock_path = $lockPath
      lock_written = [bool]$lockWritten
      freeze_ready = [bool]$freezeReady
      reasons = @($reasons | Sort-Object -Unique)
      error = $lockError
    }) | Out-Null
  }
  return [pscustomobject]@{
    schema_version = 1
    manifest_id = ('freeze-' + (Get-ProjectAutopilotSha256 -Text (($now + '|' + [string]$ProjectRoot + '|' + [string]$Channel) )))
    mode = ([string]$Mode).Trim().ToLowerInvariant()
    channel = [string]$Channel
    project_root = [string]$ProjectRoot
    frozen_at = $now
    write_locks = [bool]$WriteLocks
    ok = [bool]$allOk
    contracts = @($contractEntries.ToArray())
  }
}

function Test-ProjectAutopilotPathOverlap {
  param([string[]]$Left = @(), [string[]]$Right = @())
  foreach ($l in @(ConvertTo-ProjectAutopilotPathArray $Left)) {
    foreach ($r in @(ConvertTo-ProjectAutopilotPathArray $Right)) {
      if ($l -eq $r) { return $true }
      if ($l.StartsWith($r.TrimEnd('/') + '/') -or $r.StartsWith($l.TrimEnd('/') + '/')) { return $true }
    }
  }
  return $false
}

function Test-ProjectAutopilotGraphAcyclic {
  param([object[]]$Nodes = @(), [object[]]$Edges = @())
  $ids = @($Nodes | ForEach-Object { [string]$_.slug } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $indegree = @{}
  $out = @{}
  foreach ($id in $ids) { $indegree[$id] = 0; $out[$id] = New-Object 'System.Collections.Generic.List[string]' }
  foreach ($edge in @($Edges)) {
    $from = [string]$edge.from
    $to = [string]$edge.to
    if (-not $indegree.ContainsKey($from) -or -not $indegree.ContainsKey($to) -or $from -eq $to) { continue }
    [void]$out[$from].Add($to)
    $indegree[$to] = [int]$indegree[$to] + 1
  }
  $queue = New-Object 'System.Collections.Generic.Queue[string]'
  foreach ($id in $ids) { if ([int]$indegree[$id] -eq 0) { $queue.Enqueue($id) } }
  $visited = 0
  while ($queue.Count -gt 0) {
    $n = $queue.Dequeue()
    $visited++
    foreach ($m in @($out[$n].ToArray())) {
      $indegree[$m] = [int]$indegree[$m] - 1
      if ([int]$indegree[$m] -eq 0) { $queue.Enqueue($m) }
    }
  }
  return [pscustomobject]@{ acyclic = ($visited -eq $ids.Count); visited = $visited; total = $ids.Count }
}

function New-ProjectAutopilotUnifiedGraph {
  param(
    [object[]]$Tasks = @(),
    [object[]]$Contracts = @(),
    [bool]$AllowContractSoftEdges = $false
  )
  $nodes = New-Object 'System.Collections.Generic.List[object]'
  $edges = New-Object 'System.Collections.Generic.List[object]'
  $dangling = New-Object 'System.Collections.Generic.List[object]'
  $orphan = New-Object 'System.Collections.Generic.List[object]'
  $conflicts = New-Object 'System.Collections.Generic.List[object]'
  $contractsById = @{}
  foreach ($c in @($Contracts)) {
    $cid = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $c -Name 'id' -Default ''))
    if (-not [string]::IsNullOrWhiteSpace($cid)) { $contractsById[$cid] = $c }
  }
  foreach ($task in @($Tasks)) {
    $slug = ConvertTo-ProjectAutopilotSlug (Get-ProjectAutopilotTaskStringField -Task $task -Names @('slug','id','title'))
    $nodes.Add([pscustomobject]@{
      slug = $slug
      chapter = Get-ProjectAutopilotTaskStringField -Task $task -Names @('chapter','phase','area')
      kind = Normalize-ProjectAutopilotAtomKind (Get-ProjectAutopilotTaskStringField -Task $task -Names @('kind','atom_kind'))
      files = @(ConvertTo-ProjectAutopilotPathArray (Get-BacklogPackObjectValue -Obj $task -Name 'files' -Default @()))
      depends_on = @(ConvertTo-ProjectAutopilotSlugArray (Get-BacklogPackObjectValue -Obj $task -Name 'depends_on' -Default @()))
      provides = @(ConvertTo-ProjectAutopilotSlugArray (Get-BacklogPackObjectValue -Obj $task -Name 'provides' -Default @()))
      consumes = @(ConvertTo-ProjectAutopilotSlugArray (Get-BacklogPackObjectValue -Obj $task -Name 'consumes' -Default @()))
    }) | Out-Null
  }
  foreach ($node in @($nodes.ToArray())) {
    foreach ($dep in @($node.depends_on)) {
      $edges.Add([pscustomobject]@{ from=$dep; to=[string]$node.slug; contract=''; edge_type='hard'; provenance='declared'; confidence='declared' }) | Out-Null
    }
  }
  foreach ($consumer in @($nodes.ToArray())) {
    foreach ($contractId in @($consumer.consumes)) {
      $providers = @($nodes.ToArray() | Where-Object { @($_.provides) -contains $contractId })
      if ($providers.Count -eq 0) {
        $dangling.Add([pscustomobject]@{ atom=[string]$consumer.slug; contract=$contractId; reason='consume-without-provider' }) | Out-Null
        continue
      }
      $contract = if ($contractsById.ContainsKey($contractId)) { $contractsById[$contractId] } else { $null }
      $valid = ($contract -and [bool](Get-BacklogPackObjectValue -Obj $contract -Name 'valid' -Default $false))
      $stable = ($contract -and [bool](Get-BacklogPackObjectValue -Obj $contract -Name 'stable' -Default $false))
      $softAllowed = ($AllowContractSoftEdges -and $valid -and $stable)
      foreach ($provider in $providers) {
        if ([string]$provider.slug -eq [string]$consumer.slug) { continue }
        $edges.Add([pscustomobject]@{
          from = [string]$provider.slug
          to = [string]$consumer.slug
          contract = $contractId
          edge_type = if ($softAllowed) { 'soft' } else { 'hard' }
          provenance = 'contract'
          confidence = if ($softAllowed) { 'high' } else { 'uncertain' }
        }) | Out-Null
      }
    }
  }
  foreach ($provider in @($nodes.ToArray())) {
    foreach ($contractId in @($provider.provides)) {
      $consumers = @($nodes.ToArray() | Where-Object { @($_.consumes) -contains $contractId })
      if ($consumers.Count -eq 0) {
        $orphan.Add([pscustomobject]@{ atom=[string]$provider.slug; contract=$contractId; reason='provide-without-consumer' }) | Out-Null
      }
    }
  }
  $nodeArr = @($nodes.ToArray())
  for ($i = 0; $i -lt $nodeArr.Count; $i++) {
    for ($j = $i + 1; $j -lt $nodeArr.Count; $j++) {
      if (Test-ProjectAutopilotPathOverlap -Left @($nodeArr[$i].files) -Right @($nodeArr[$j].files)) {
        $conflicts.Add([pscustomobject]@{ left=[string]$nodeArr[$i].slug; right=[string]$nodeArr[$j].slug; reason='touch-overlap' }) | Out-Null
      }
    }
  }
  $cycle = Test-ProjectAutopilotGraphAcyclic -Nodes @($nodes.ToArray()) -Edges @($edges.ToArray())
  return [pscustomobject]@{
    nodes = @($nodes.ToArray())
    edges = @($edges.ToArray())
    dangling_consumes = @($dangling.ToArray())
    orphan_provides = @($orphan.ToArray())
    file_conflicts = @($conflicts.ToArray())
    acyclic = [bool]$cycle.acyclic
  }
}

function Test-ProjectAutopilotDiffusionGate {
  param(
    [object[]]$Tasks = @(),
    [object[]]$Contracts = @(),
    [string]$ProjectRoot = '',
    [bool]$OptIn = $false,
    [Nullable[bool]]$CleanKnownState = $null,
    [Nullable[bool]]$StitchingTestsPresent = $null,
    [int]$MinIndependentAtoms = 2,
    [int]$MaxWaveSize = 6
  )
  $reasons = New-Object 'System.Collections.Generic.List[string]'
  if (-not $OptIn) { [void]$reasons.Add('diffusion-opt-in-missing') }
  $clean = $true
  if ($null -ne $CleanKnownState) { $clean = [bool]$CleanKnownState }
  elseif (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) { $clean = [bool](Test-ProjectAutopilotProjectClean -ProjectRoot $ProjectRoot) }
  if (-not $clean) { [void]$reasons.Add('worktree-not-clean-or-unknown') }
  $graph = New-ProjectAutopilotUnifiedGraph -Tasks @($Tasks) -Contracts @($Contracts) -AllowContractSoftEdges:$OptIn
  $contractIds = @($Contracts | ForEach-Object { [string](Get-BacklogPackObjectValue -Obj $_ -Name 'id' -Default '') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $neededContracts = @($graph.nodes | ForEach-Object { @($_.consumes) + @($_.provides) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $missingContracts = @($neededContracts | Where-Object { $contractIds -notcontains $_ })
  if ($missingContracts.Count -gt 0 -or $graph.dangling_consumes.Count -gt 0) { [void]$reasons.Add('contract-coverage-incomplete') }
  $badContracts = @($Contracts | Where-Object { -not [bool](Get-BacklogPackObjectValue -Obj $_ -Name 'valid' -Default $false) })
  if ($badContracts.Count -gt 0) { [void]$reasons.Add('contract-invalid') }
  $unstableContracts = @($Contracts | Where-Object { -not [bool](Get-BacklogPackObjectValue -Obj $_ -Name 'stable' -Default $false) })
  if ($unstableContracts.Count -gt 0) { [void]$reasons.Add('contract-unstable') }
  $contractFilePaths = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($c in @($Contracts)) {
    $cp = ([string](Get-BacklogPackObjectValue -Obj $c -Name 'path' -Default '')).Replace('\','/').Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($cp)) { [void]$contractFilePaths.Add($cp) }
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot) -and -not [string]::IsNullOrWhiteSpace($cp)) {
      $rootNorm = ([string]$ProjectRoot).Replace('\','/').TrimEnd('/').ToLowerInvariant()
      if ($cp.StartsWith($rootNorm + '/')) { [void]$contractFilePaths.Add($cp.Substring($rootNorm.Length + 1)) }
    }
  }
  $contractFileOwned = $false
  foreach ($task in @($Tasks)) {
    foreach ($f in @(ConvertTo-ProjectAutopilotPathArray (Get-BacklogPackObjectValue -Obj $task -Name 'files' -Default @()))) {
      if ($contractFilePaths.Contains($f)) { $contractFileOwned = $true; break }
    }
    if ($contractFileOwned) { break }
  }
  if ($contractFileOwned) { [void]$reasons.Add('contract-file-owned-in-wave') }
  if (-not [bool]$graph.acyclic) { [void]$reasons.Add('graph-cyclic') }
  if (@($graph.file_conflicts).Count -gt 0) { [void]$reasons.Add('file-conflict-unresolved') }
  $hasStitch = $false
  if ($null -ne $StitchingTestsPresent) { $hasStitch = [bool]$StitchingTestsPresent }
  else {
    foreach ($task in @($Tasks)) {
      $kind = Normalize-ProjectAutopilotAtomKind (Get-ProjectAutopilotTaskStringField -Task $task -Names @('kind','atom_kind'))
      $checks = @(Get-ProjectAutopilotTaskStringArray -Task $task -Names @('checks','verify','verification'))
      if ($kind -eq 'consolidation' -and (@($checks | Where-Object { $_ -match '(?i)stitch|integration|contract' }).Count -gt 0)) { $hasStitch = $true; break }
    }
  }
  if (-not $hasStitch) { [void]$reasons.Add('stitching-tests-missing') }
  $hardTargets = @($graph.edges | Where-Object { [string]$_.edge_type -eq 'hard' } | ForEach-Object { [string]$_.to } | Sort-Object -Unique)
  $independent = @($graph.nodes | Where-Object { $hardTargets -notcontains [string]$_.slug })
  if ($independent.Count -lt [int]$MinIndependentAtoms) { [void]$reasons.Add('independent-atom-count-below-floor') }
  if ($Tasks.Count -gt [int]$MaxWaveSize) { [void]$reasons.Add('wave-size-over-cap') }
  return [pscustomobject]@{
    enabled = ($reasons.Count -eq 0)
    fallback = ($reasons.Count -gt 0)
    reasons = @($reasons.ToArray())
    graph = $graph
    independent_atom_count = [int]$independent.Count
    wave_size = [int]$Tasks.Count
  }
}

function Get-ProjectAutopilotEarliestChapterTaskSet {
  # Collapse a multi-chapter atom batch to just the EARLIEST chapter (the proven serial one-chapter
  # default). The safe fallback when a cross-chapter batch cannot be dispatched (diffusion executor
  # absent, or a wide/diffusion gate is red): no giant batch -> no bridge-lock storm -> no hang, and the
  # atoms are not stranded. Pure / no I/O. Returns @{ collapsed; chapter; tasks }.
  param([object[]]$Tasks = @())
  $result = [ordered]@{ collapsed = $false; chapter = ''; tasks = @($Tasks) }
  $chapterOf = { param($task) Get-ProjectAutopilotTaskStringField -Task $task -Names @('chapter','phase','area') }
  $present = @($Tasks | ForEach-Object { & $chapterOf $_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  if ($present.Count -le 1) { return [pscustomobject]$result }
  $rank = { param($c) $m=[regex]::Match([string]$c,'\d+'); if ($m.Success) { [int]$m.Value } else { 999999 } }
  $earliest = @($present | Sort-Object @{Expression={ & $rank $_ }}, @{Expression={ [string]$_ }} | Select-Object -First 1)[0]
  $result.tasks = @($Tasks | Where-Object { $cf=(& $chapterOf $_); [string]::IsNullOrWhiteSpace($cf) -or ($cf -eq $earliest) })
  $result.collapsed = $true
  $result.chapter = [string]$earliest
  return [pscustomobject]$result
}

function Test-ProjectAutopilotWideGate {
  # 2026-06-30 "cross-chapter wide" gate -- the first, simplest diffusion step. Wide parallelizes ONLY
  # INDEPENDENT atoms across chapters; DEPENDENT atoms serialize naturally via depends_on in the executor
  # frontier (Resolve-BacklogWorkpackFrontier selects waves by depends_on + touch-set, NOT by chapter).
  # So wide needs ONLY: an acyclic depends_on graph, disjoint file ownership among atoms, and at least K
  # independent atoms. It does NOT need frozen interface contracts / stubs / stitching tests (those exist
  # solely to parallelize DEPENDENT atoms, which wide never does), and it does NOT cap the total emit (the
  # frontier caps the runnable WAVE via workpackExec.maxItems; the emit may span all chapters).
  param([object[]]$Tasks = @(), [int]$MinIndependentAtoms = 2)
  $reasons = New-Object 'System.Collections.Generic.List[string]'
  $graph = New-ProjectAutopilotUnifiedGraph -Tasks @($Tasks) -Contracts @() -AllowContractSoftEdges:$false
  if (-not [bool]$graph.acyclic) { [void]$reasons.Add('graph-cyclic') }
  if (@($graph.file_conflicts).Count -gt 0) { [void]$reasons.Add('file-conflict-unresolved') }
  $hardTargets = @($graph.edges | Where-Object { [string]$_.edge_type -eq 'hard' } | ForEach-Object { [string]$_.to } | Sort-Object -Unique)
  $independent = @($graph.nodes | Where-Object { $hardTargets -notcontains [string]$_.slug })
  if ($independent.Count -lt [int]$MinIndependentAtoms) { [void]$reasons.Add('independent-atom-count-below-floor') }
  return [pscustomobject]@{
    enabled = ($reasons.Count -eq 0)
    fallback = ($reasons.Count -gt 0)
    reasons = @($reasons.ToArray())
    graph = $graph
    independent_atom_count = [int]$independent.Count
    wave_size = [int]$Tasks.Count
  }
}

function Get-ProjectAutopilotPlanningStageDefinitions {
  return @(
    [pscustomobject]@{ id='brief';       path='PROJECT_BRIEF.md';       min_chars=800;  label='project brief' },
    [pscustomobject]@{ id='product';     path='DISCUSS_PRODUCT.md';     min_chars=900;  label='product discussion' },
    [pscustomobject]@{ id='ux';          path='DISCUSS_UX.md';          min_chars=900;  label='UX discussion' },
    [pscustomobject]@{ id='ui';          path='DISCUSS_UI.md';          min_chars=800;  label='UI discussion' },
    [pscustomobject]@{ id='backend';     path='DISCUSS_BACKEND.md';     min_chars=900;  label='backend discussion' },
    [pscustomobject]@{ id='qa';          path='DISCUSS_QA.md';          min_chars=800;  label='QA/acceptance discussion' },
    [pscustomobject]@{ id='integration'; path='DISCUSS_INTEGRATION.md'; min_chars=800;  label='cross-stage integration review' }
  )
}

function Normalize-ProjectAutopilotSpecProfile {
  param([string]$Profile)
  $p = ([string]$Profile).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($p)) { return 'legacy' }
  if ($p -in @('tiny','small','simple','light','lite','minimal','mvp')) { return 'lite' }
  if ($p -in @('medium','normal','default','standard','regular')) { return 'standard' }
  if ($p -in @('large','big','complex','strict','full','production','enterprise')) { return 'full' }
  if ($p -in @('legacy','staged-v1')) { return 'legacy' }
  return 'standard'
}

function Get-ProjectAutopilotSpecProfile {
  param($Contract)
  if (-not $Contract) { return 'legacy' }
  $value = [string](Get-ProjectAutopilotContractValue -Obj $Contract -Names @('spec_profile','specProfile','project_size','projectSize','project_profile','projectProfile') -Default '')
  if (-not [string]::IsNullOrWhiteSpace($value)) { return (Normalize-ProjectAutopilotSpecProfile -Profile $value) }
  foreach ($containerName in @('bridge_spec','bridgeSpec','spec_layer','specLayer','project_spec','projectSpec')) {
    $container = Get-ProjectAutopilotContractValue -Obj $Contract -Names @($containerName) -Default $null
    if ($container) {
      $value = [string](Get-ProjectAutopilotContractValue -Obj $container -Names @('profile','spec_profile','project_size','size') -Default '')
      if (-not [string]::IsNullOrWhiteSpace($value)) { return (Normalize-ProjectAutopilotSpecProfile -Profile $value) }
    }
  }
  return 'legacy'
}

function Get-ProjectAutopilotPlanContractObject {
  param([string]$ProjectRoot)
  $path = Get-ProjectAutopilotPlanContractPath -ProjectRoot $ProjectRoot
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try { return ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Get-ProjectAutopilotSpecRules {
  param([string]$Profile = 'legacy')
  $profileName = Normalize-ProjectAutopilotSpecProfile -Profile $Profile
  switch ($profileName) {
    'lite' {
      return [pscustomobject]@{
        profile = 'lite'
        stage_ids = @('brief')
        stage_min_overrides = @{ brief = 500 }
        map_min_chars = 800
        plan_min_chars = 1000
        constitution_min_chars = 500
        spec_min_chars = 500
        required_specs = @('.bridge\specs\acceptance.md')
        requirements_min = 1
        surfaces_min = 1
        journeys_min = 1
        acceptance_min = 1
        interface_min = 0
        require_planning_flow = $false
        integration_dep_min = 0
      }
    }
    'standard' {
      return [pscustomobject]@{
        profile = 'standard'
        stage_ids = @('brief','product','ux','ui','backend','qa','integration')
        stage_min_overrides = @{}
        map_min_chars = 1500
        plan_min_chars = 2000
        constitution_min_chars = 700
        spec_min_chars = 700
        required_specs = @('.bridge\specs\product.md','.bridge\specs\acceptance.md')
        requirements_min = 3
        surfaces_min = 2
        journeys_min = 2
        acceptance_min = 3
        interface_min = 1
        require_planning_flow = $true
        integration_dep_min = 5
      }
    }
    'full' {
      return [pscustomobject]@{
        profile = 'full'
        stage_ids = @('brief','product','ux','ui','backend','qa','integration')
        stage_min_overrides = @{ brief = 1000; product = 1200; ux = 1200; ui = 1000; backend = 1200; qa = 1200; integration = 1200 }
        map_min_chars = 2500
        plan_min_chars = 3000
        constitution_min_chars = 900
        spec_min_chars = 900
        required_specs = @('.bridge\specs\product.md','.bridge\specs\ux.md','.bridge\specs\architecture.md','.bridge\specs\acceptance.md')
        requirements_min = 5
        surfaces_min = 3
        journeys_min = 3
        acceptance_min = 5
        interface_min = 1
        require_planning_flow = $true
        integration_dep_min = 5
      }
    }
    default {
      return [pscustomobject]@{
        profile = 'legacy'
        stage_ids = @('brief','product','ux','ui','backend','qa','integration')
        stage_min_overrides = @{}
        map_min_chars = 1500
        plan_min_chars = 2000
        constitution_min_chars = 0
        spec_min_chars = 0
        required_specs = @()
        requirements_min = 3
        surfaces_min = 2
        journeys_min = 2
        acceptance_min = 3
        interface_min = 1
        require_planning_flow = $true
        integration_dep_min = 5
      }
    }
  }
}

function Get-ProjectAutopilotPlanSignatureFiles {
  param([string]$ProjectRoot = '')
  $files = New-Object 'System.Collections.Generic.List[string]'
  $contract = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $null } else { Get-ProjectAutopilotPlanContractObject -ProjectRoot $ProjectRoot }
  $rules = Get-ProjectAutopilotSpecRules -Profile (Get-ProjectAutopilotSpecProfile -Contract $contract)
  $stageIds = @($rules.stage_ids | ForEach-Object { [string]$_ })
  foreach ($stage in @(Get-ProjectAutopilotPlanningStageDefinitions)) {
    if ($stageIds -notcontains [string]$stage.id) { continue }
    [void]$files.Add([string]$stage.path)
  }
  if ([int]$rules.constitution_min_chars -gt 0) { [void]$files.Add('.bridge\constitution.md') }
  foreach ($rel in @($rules.required_specs)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rel)) { [void]$files.Add([string]$rel) }
  }
  foreach ($rel in @('PROJECT_MAP.md','PROJECT_PLAN.md','.bridge\project-contract.json')) {
    [void]$files.Add([string]$rel)
  }
  return @($files.ToArray() | Select-Object -Unique)
}

function Get-ProjectAutopilotFileText {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } catch { return '' }
}

function Get-ProjectAutopilotSha256 {
  param([string]$Text)
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
  } catch {
    return ''
  }
}

function Get-ProjectAutopilotPlanSignature {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return '' }
  $parts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($rel in @(Get-ProjectAutopilotPlanSignatureFiles -ProjectRoot $ProjectRoot)) {
    $path = Join-Path $ProjectRoot $rel
    [void]$parts.Add($rel.Replace('\','/') + "`n" + (Get-ProjectAutopilotFileText -Path $path))
  }
  return (Get-ProjectAutopilotSha256 -Text (($parts.ToArray()) -join "`n---bridge-plan-part---`n"))
}

function Get-ProjectAutopilotGitHead {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { return '' }
  try {
    $git = if (Get-Command Get-GitExe -ErrorAction SilentlyContinue) { Get-GitExe } else { 'git' }
    $result = Invoke-BacklogProcess -FilePath $git -Arguments @('-c', "safe.directory=$ProjectRoot", '-C', $ProjectRoot, 'rev-parse', 'HEAD') -WorkingDirectory $ProjectRoot -TimeoutSec 30
    if ($result.TimedOut -or $result.ExitCode -ne 0) { return '' }
    return (($result.Output | Out-String).Trim())
  } catch {
    return ''
  }
}

function Test-ProjectAutopilotPlanFilesUnchangedSinceGitHead {
  param([string]$ProjectRoot, [string]$GitHead)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or [string]::IsNullOrWhiteSpace($GitHead)) {
    return [pscustomobject]@{ ok=$false; unchanged=$false; reason='missing-input' }
  }
  if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    return [pscustomobject]@{ ok=$false; unchanged=$false; reason='project-root-missing' }
  }
  try {
    $git = if (Get-Command Get-GitExe -ErrorAction SilentlyContinue) { Get-GitExe } else { 'git' }
    $verifyResult = Invoke-BacklogProcess -FilePath $git -Arguments @('-c', "safe.directory=$ProjectRoot", '-C', $ProjectRoot, 'rev-parse', '--verify', ($GitHead + '^{commit}')) -WorkingDirectory $ProjectRoot -TimeoutSec 30
    $verify = (($verifyResult.Output | Out-String).Trim())
    if ($verifyResult.TimedOut -or $verifyResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace([string]$verify)) {
      return [pscustomobject]@{ ok=$false; unchanged=$false; reason='approval-git-head-not-found' }
    }
    $files = @(Get-ProjectAutopilotPlanSignatureFiles -ProjectRoot $ProjectRoot | ForEach-Object { ([string]$_).Replace('\','/') })
    if ($files.Count -eq 0) {
      return [pscustomobject]@{ ok=$false; unchanged=$false; reason='no-plan-files' }
    }
    $args = @('-c', "safe.directory=$ProjectRoot", '-C', $ProjectRoot, 'diff', '--quiet', $GitHead, '--') + $files
    $diffResult = Invoke-BacklogProcess -FilePath $git -Arguments $args -WorkingDirectory $ProjectRoot -TimeoutSec 30
    $exit = [int]$diffResult.ExitCode
    if ($diffResult.TimedOut) { return [pscustomobject]@{ ok=$false; unchanged=$false; reason='git-diff-timeout' } }
    if ($exit -eq 0) { return [pscustomobject]@{ ok=$true; unchanged=$true; reason='unchanged' } }
    if ($exit -eq 1) { return [pscustomobject]@{ ok=$true; unchanged=$false; reason='plan-files-changed' } }
    return [pscustomobject]@{ ok=$false; unchanged=$false; reason=('git-diff-exit-' + [string]$exit) }
  } catch {
    return [pscustomobject]@{ ok=$false; unchanged=$false; reason='git-diff-error' }
  }
}

function Get-ProjectAutopilotContractValue {
  param($Obj, [string[]]$Names = @(), $Default = $null)
  if (-not $Obj) { return $Default }
  foreach ($name in @($Names)) {
    try {
      if ($Obj -is [hashtable] -and $Obj.ContainsKey($name)) {
        $v = $Obj[$name]
        if ($null -ne $v) { return $v }
      }
      if ($Obj -is [System.Collections.IDictionary] -and $Obj.Contains($name)) {
        $v = $Obj[$name]
        if ($null -ne $v) { return $v }
      }
      if ($Obj.PSObject.Properties.Name -contains $name) {
        $v = $Obj.PSObject.Properties[$name].Value
        if ($null -ne $v) { return $v }
      }
    } catch {}
  }
  return $Default
}

function Get-ProjectAutopilotContractCount {
  param($Obj, [string[]]$Names = @())
  $v = Get-ProjectAutopilotContractValue -Obj $Obj -Names $Names -Default $null
  if ($null -eq $v) { return 0 }
  try {
    if ($v -is [string]) {
      if ([string]::IsNullOrWhiteSpace([string]$v)) { return 0 }
      return 1
    }
    if ($v -is [System.Collections.IDictionary]) { return [int]$v.Count }
    $arr = @($v | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($arr.Count -gt 0) { return [int]$arr.Count }
  } catch {}
  try {
    if ($v.PSObject.Properties.Count -gt 0) { return [int]$v.PSObject.Properties.Count }
  } catch {}
  return 0
}

function Get-ProjectAutopilotContractArray {
  param($Obj, [string[]]$Names = @())
  $v = Get-ProjectAutopilotContractValue -Obj $Obj -Names $Names -Default $null
  if ($null -eq $v) { return @() }
  try {
    if ($v -is [string]) {
      if ([string]::IsNullOrWhiteSpace([string]$v)) { return @() }
      return @([string]$v)
    }
    return @($v | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
  } catch {
    return @()
  }
}

function Get-ProjectAutopilotPlanningStageById {
  param($PlanningFlow)
  $map = @{}
  $stages = @(Get-ProjectAutopilotContractArray -Obj $PlanningFlow -Names @('stages','planning_stages','discussions'))
  foreach ($stage in @($stages)) {
    $id = ([string](Get-ProjectAutopilotContractValue -Obj $stage -Names @('id','stage','name') -Default '')).Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($id)) { $map[$id] = $stage }
  }
  return $map
}

function Invoke-ProjectAutopilotDeliveryContractValidation {
  param($Contract, $Context = $null)
  if (Get-Command Test-DeliveryContract -ErrorAction SilentlyContinue) {
    return (Test-DeliveryContract -Contract $Contract -Context $Context)
  }

  $candidates = @()
  try {
    $root = Get-BacklogFallbackBridgeRoot
    if (-not [string]::IsNullOrWhiteSpace($root)) { $candidates += (Join-Path $root 'lib\delivery-contract.ps1') }
  } catch {}
  try {
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $candidates += (Join-Path $PSScriptRoot 'delivery-contract.ps1') }
  } catch {}
  try {
    $cwd = (Get-Location).Path
    if (-not [string]::IsNullOrWhiteSpace($cwd)) { $candidates += (Join-Path $cwd 'lib\delivery-contract.ps1') }
  } catch {}

  foreach ($candidate in @($candidates | Select-Object -Unique)) {
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    try {
      . $candidate
      if (Get-Command Test-DeliveryContract -ErrorAction SilentlyContinue) {
        return (Test-DeliveryContract -Contract $Contract -Context $Context)
      }
    } catch {
      throw
    }
  }

  throw 'delivery-contract validator unavailable'
}

function Get-ProjectAutopilotPlanStageDocLengths {
  param([string]$ProjectRoot, $Issues, $Rules = $null)
  if (-not $Rules) { $Rules = Get-ProjectAutopilotSpecRules -Profile 'legacy' }
  $stageDocLengths = [ordered]@{}
  $stageIds = @($Rules.stage_ids | ForEach-Object { [string]$_ })
  foreach ($stageDef in @(Get-ProjectAutopilotPlanningStageDefinitions)) {
    $sid = [string]$stageDef.id
    if ($stageIds -notcontains $sid) { continue }
    $stagePath = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { '' } else { Join-Path $ProjectRoot ([string]$stageDef.path) }
    $stageText = Get-ProjectAutopilotFileText -Path $stagePath
    $minChars = [int]$stageDef.min_chars
    try {
      if ($Rules.stage_min_overrides -and $Rules.stage_min_overrides.ContainsKey($sid)) {
        $minChars = [int]$Rules.stage_min_overrides[$sid]
      }
    } catch {}
    $stageDocLengths[$sid] = [int]$stageText.Length
    if ($stageText.Length -lt $minChars) {
      [void]$Issues.Add(([string]$stageDef.path + ' is missing or too shallow (<' + [string]$minChars + ' chars)'))
    }
  }
  return $stageDocLengths
}

function Add-ProjectAutopilotSpecLayerIssues {
  param([string]$ProjectRoot, $Rules, $Issues)
  if (-not $Rules -or [string]::IsNullOrWhiteSpace($ProjectRoot)) { return }
  if ([int]$Rules.constitution_min_chars -gt 0) {
    $constitutionRel = '.bridge\constitution.md'
    $constitutionText = Get-ProjectAutopilotFileText -Path (Join-Path $ProjectRoot $constitutionRel)
    if ($constitutionText.Length -lt [int]$Rules.constitution_min_chars) {
      [void]$Issues.Add($constitutionRel + ' is missing or too shallow (<' + [string]$Rules.constitution_min_chars + ' chars)')
    }
  }
  foreach ($rel in @($Rules.required_specs)) {
    if ([string]::IsNullOrWhiteSpace([string]$rel)) { continue }
    $specText = Get-ProjectAutopilotFileText -Path (Join-Path $ProjectRoot ([string]$rel))
    if ($specText.Length -lt [int]$Rules.spec_min_chars) {
      [void]$Issues.Add(([string]$rel + ' is missing or too shallow (<' + [string]$Rules.spec_min_chars + ' chars)'))
    }
  }
}

function Test-ProjectAutopilotDeliveryContractReady {
  param($Contract, $Issues)
  $result = [ordered]@{
    ok = $false
    score = $null
    missing = @()
    warnings = @()
    blockers = @()
    required_sections = @()
  }

  try {
    $requireExplicitProjectSections = Test-ProjectAutopilotExplicitProjectSectionsRequired -Contract $Contract
    $deliveryResult = Invoke-ProjectAutopilotDeliveryContractValidation -Contract $Contract -Context @{
      RequireParallelPolicy = $true
      RequireExplicitProjectSections = $requireExplicitProjectSections
    }
    $result.ok = [bool]$deliveryResult.ok
    $result.score = [int]$deliveryResult.score
    $result.missing = @($deliveryResult.missing)
    $result.warnings = @($deliveryResult.warnings)
    $result.blockers = @($deliveryResult.blockers)
    $result.required_sections = @($deliveryResult.required_sections)
    if (-not $result.ok) {
      [void]$Issues.Add('delivery-contract score=' + [string]$result.score)
      if ($result.missing.Count -gt 0) { [void]$Issues.Add('delivery-contract missing: ' + ($result.missing -join ', ')) }
      if ($result.blockers.Count -gt 0) { [void]$Issues.Add('delivery-contract blockers: ' + ($result.blockers -join ', ')) }
      if ($result.warnings.Count -gt 0) { [void]$Issues.Add('delivery-contract warnings: ' + ($result.warnings -join ', ')) }
    }
  } catch {
    $msg = [string]$_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = 'unavailable' }
    if ($msg -eq 'delivery-contract validator unavailable') {
      [void]$Issues.Add('delivery-contract validator unavailable')
    } else {
      [void]$Issues.Add('delivery-contract validator error: ' + $msg)
    }
  }

  return [pscustomobject]$result
}

function Test-ProjectAutopilotTruthy {
  param($Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [bool]) { return [bool]$Value }
  if ($Value -is [string]) {
    return (@('1','true','yes','y','on') -contains $Value.Trim().ToLowerInvariant())
  }
  if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
    return ([double]$Value -ne 0)
  }
  if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
    foreach ($item in $Value) {
      if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item)) { return $true }
    }
  }
  return $false
}

function Test-ProjectAutopilotExplicitProjectSectionsRequired {
  param($Contract)
  if (-not $Contract) { return $false }
  $explicit = Get-ProjectAutopilotContractValue -Obj $Contract -Names @(
    'require_explicit_project_sections',
    'RequireExplicitProjectSections',
    'explicit_project_sections_required',
    'explicitProjectSectionsRequired'
  ) -Default $null
  if ($null -ne $explicit) {
    return (Test-ProjectAutopilotTruthy -Value $explicit)
  }
  $schemaVersion = Get-ProjectAutopilotContractValue -Obj $Contract -Names @(
    'project_contract_schema_version',
    'contract_schema_version',
    'contractVersion',
    'version'
  ) -Default $null
  try {
    if ($null -ne $schemaVersion -and [double]$schemaVersion -ge 2) { return $true }
  } catch {}
  return $false
}

function Get-ProjectContractSchemaInstruction {
  # 2026-06-29 Option-A fix for the planner<->approval-gate mismatch. Single source
  # of truth for the .bridge/project-contract.json schema the deterministic
  # delivery-contract gate (Test-DeliveryContract) validates by EXACT snake_case
  # top-level keys. The selfie-styler build stalled because the planner invented its
  # own keys (scope/users/capabilities/interfaces/invariants/risks) instead of the
  # keys the gate string-matches -- so half the required sections read as missing and
  # approval was blocked. This teaches the planner the exact keys, the silent traps
  # (acceptance vs acceptance_scenarios, interfaces vs surfaces, mandatory
  # parallel_policy) and the spec_profile choice, without relaxing the gate.
  param([switch]$Concise)
  if ($Concise) {
    return @'
КОНТРАКТ .bridge/project-contract.json -- ТОЧНЫЕ ключи (gate проверяет строгим совпадением snake_case, синонимы НЕ засчитываются): goal, scope, non_goals, users, surfaces, backend (или data), acceptance_scenarios (именно так, НЕ "acceptance"), checks, risk, parallel_policy (ОБЯЗАТЕЛЕН). Каждая секция >= 12 непробельных символов реального содержания. acceptance_scenarios = массив объектов {id,given,when,then}; parallel_policy = объект {mode,rationale,barrier}; surfaces = массив типизированных объектов (kind/name/command|path|route), слово "interfaces" НЕ распознаётся. Заполняй значения, НЕ переименовывай ключи и НЕ выдумывай свои. Всегда ставь spec_profile: "lite" для малых (<= ~3 поверхности), "standard"/"full" крупнее. Эталон: bridge-projects/glass-interpreter/.bridge/project-contract.json.
'@
  }
  return @'
- .bridge/project-contract.json is the machine-readable contract the deterministic delivery-contract gate validates by EXACT snake_case top-level keys. FILL each value with real content; do NOT rename keys or invent your own -- a synonym like "acceptance" (instead of acceptance_scenarios) or "interfaces" (instead of surfaces) is NOT recognized and silently fails the gate. ALL nine sections are required, each with real content (>= 12 non-whitespace chars; empty/one-word is rejected as shallow):
    1. "goal"                  - one clear outcome statement (>= 40 chars).
    2. "scope" and "non_goals"  - explicit in-scope list AND explicit out-of-scope list.
    3. "users"                 - users/roles/personas/actors.
    4. "surfaces"              - app surfaces as typed objects, e.g. {"kind":"screen|cli|artifact|api","name":...,"command"|"path"|"route":...}. Use key "surfaces" (or "routes"/"screens"); "interfaces" is NOT recognized.
    5. "backend" (or "data")    - data/backend ownership: providers, models, storage, secrets.
    6. "acceptance_scenarios"  - MUST be this exact snake_case key (a key named just "acceptance" is NOT counted). Array of objects, each {"id","given","when","then"}.
    7. "checks"                - concrete verification commands, e.g. [{"name","command","expect"}].
    8. "risk"                  - risks + mitigations.
    9. "parallel_policy"       - REQUIRED (hard blocker if missing under autopilot). Object {"mode","rationale","barrier"}, not a bare sentence.
  Also include requirements (>=1), user_journeys (>=1) and ux_contract/interface_contract for the plan gate. The gate passes only with zero missing/shallow required sections (internal score >= 80). Mirror the proven shape of bridge-projects/glass-interpreter/.bridge/project-contract.json.
- Always set the top-level "spec_profile" field deliberately (when omitted the gate falls back to the heavy 'legacy' profile and blocks small work): "lite" for small/narrow work (roughly <= 3 surfaces / single-surface app -> avoids unnecessary DISCUSS_* bureaucracy), "standard" for normal multi-surface apps, "full" for large/complex/production (full requires deeper specs and DISCUSS_* stages before implementation).
'@
}

function Get-ProjectContractSchemaReminder {
  # Rides the project focus block on every project turn (driver Get-ProjectFocusPromptBlock).
  # Returns '' once the contract passes the delivery-contract gate; otherwise returns the
  # exact-key schema instruction PLUS the specific sections the gate still finds
  # missing/shallow, so the DISCUSS planner gets precise feedback WHILE it is authoring
  # the contract -- closing the loop that previously left the planner guessing.
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return '' }
  try {
    if (-not (Get-Command Get-ProjectAutopilotPlanContractPath -ErrorAction SilentlyContinue)) { return '' }
    $contractPath = Get-ProjectAutopilotPlanContractPath -ProjectRoot $ProjectRoot
    $concise = Get-ProjectContractSchemaInstruction -Concise
    if ([string]::IsNullOrWhiteSpace($contractPath) -or -not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
      return "`n`nКОНТРАКТ ещё не создан. " + $concise
    }
    $contract = $null
    try { $contract = [System.IO.File]::ReadAllText($contractPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch {
      return "`n`n" + $concise + "`n(контракт не парсится как JSON -- перезапиши валидным JSON)."
    }
    $sink = New-Object 'System.Collections.Generic.List[string]'
    $delivery = Test-ProjectAutopilotDeliveryContractReady -Contract $contract -Issues $sink
    if ([bool]$delivery.ok) { return '' }
    $gaps = @()
    if (@($delivery.missing).Count -gt 0) { $gaps += ('нет/мелко: ' + (@($delivery.missing) -join ', ')) }
    if (@($delivery.blockers).Count -gt 0) { $gaps += ('блокеры: ' + (@($delivery.blockers) -join ', ')) }
    $gapLine = if ($gaps.Count -gt 0) { "`nGate не пускает (score=$([string]$delivery.score)): " + ($gaps -join '; ') + '.' } else { '' }
    return "`n`n" + $concise + $gapLine
  } catch { return '' }
}

function Test-ProjectPlanContractReady {
  param([string]$ProjectRoot)
  $issues = New-Object 'System.Collections.Generic.List[string]'
  $mapPath = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { '' } else { Join-Path $ProjectRoot 'PROJECT_MAP.md' }
  $planPath = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { '' } else { Join-Path $ProjectRoot 'PROJECT_PLAN.md' }
  $contractPath = Get-ProjectAutopilotPlanContractPath -ProjectRoot $ProjectRoot
  $mapText = Get-ProjectAutopilotFileText -Path $mapPath
  $planText = Get-ProjectAutopilotFileText -Path $planPath
  $contract = $null
  $specRules = Get-ProjectAutopilotSpecRules -Profile 'legacy'
  $stageDocLengths = [ordered]@{}
  $deliveryContractOk = $false
  $deliveryContractScore = $null
  $deliveryContractMissing = @()
  $deliveryContractWarnings = @()
  $deliveryContractBlockers = @()
  $deliveryContractRequiredSections = @()

  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    [void]$issues.Add('project_root is missing')
  }

  if ([string]::IsNullOrWhiteSpace($contractPath) -or -not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    [void]$issues.Add('.bridge/project-contract.json is missing')
  } else {
    try {
      $contract = [System.IO.File]::ReadAllText($contractPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
      [void]$issues.Add('.bridge/project-contract.json is not valid JSON')
    }
  }

  if ($contract) {
    $specRules = Get-ProjectAutopilotSpecRules -Profile (Get-ProjectAutopilotSpecProfile -Contract $contract)
  }
  if ($mapText.Length -lt [int]$specRules.map_min_chars) {
    [void]$issues.Add('PROJECT_MAP.md is missing or too shallow (<' + [string]$specRules.map_min_chars + ' chars)')
  }
  if ($planText.Length -lt [int]$specRules.plan_min_chars) {
    [void]$issues.Add('PROJECT_PLAN.md is missing or too shallow (<' + [string]$specRules.plan_min_chars + ' chars)')
  }

  $stageDocLengths = Get-ProjectAutopilotPlanStageDocLengths -ProjectRoot $ProjectRoot -Issues $issues -Rules $specRules
  Add-ProjectAutopilotSpecLayerIssues -ProjectRoot $ProjectRoot -Rules $specRules -Issues $issues

  $goalText = ''
  $reqCount = 0
  $surfaceCount = 0
  $journeyCount = 0
  $acceptanceCount = 0
  $interfaceCount = 0
  $planningStageCount = 0
  if ($contract) {
    $deliveryContract = Test-ProjectAutopilotDeliveryContractReady -Contract $contract -Issues $issues
    $deliveryContractOk = [bool]$deliveryContract.ok
    $deliveryContractScore = $deliveryContract.score
    $deliveryContractMissing = @($deliveryContract.missing)
    $deliveryContractWarnings = @($deliveryContract.warnings)
    $deliveryContractBlockers = @($deliveryContract.blockers)
    $deliveryContractRequiredSections = @($deliveryContract.required_sections)

    $goalText = [string](Get-ProjectAutopilotContractValue -Obj $contract -Names @('project_goal','goal','mission','outcome') -Default '')
    $reqCount = [int](Get-ProjectAutopilotContractCount -Obj $contract -Names @('requirements','capabilities','features','functional_requirements'))
    $surfaceCount = [int](Get-ProjectAutopilotContractCount -Obj $contract -Names @('screens','routes','views','surfaces','pages','endpoints','modules'))
    $journeyCount = [int](Get-ProjectAutopilotContractCount -Obj $contract -Names @('user_journeys','journeys','flows','workflows','scenarios'))
    $acceptanceCount = [int](Get-ProjectAutopilotContractCount -Obj $contract -Names @('acceptance_scenarios','acceptance','done_criteria','checks','quality_gates'))
    $interfaceCount = [int](Get-ProjectAutopilotContractCount -Obj $contract -Names @('ux_contract','ux','interface_contract','experience_principles','interaction_model'))
    $planningFlow = Get-ProjectAutopilotContractValue -Obj $contract -Names @('planning_flow','planningFlow','discussion_flow') -Default $null
    $stageById = Get-ProjectAutopilotPlanningStageById -PlanningFlow $planningFlow
    $planningStageCount = [int]$stageById.Count
    if ($goalText.Trim().Length -lt 40) { [void]$issues.Add('project contract goal is missing or too short') }
    if ($reqCount -lt [int]$specRules.requirements_min) { [void]$issues.Add('project contract needs at least ' + [string]$specRules.requirements_min + ' requirements/capabilities/features') }
    if ($surfaceCount -lt [int]$specRules.surfaces_min) { [void]$issues.Add('project contract needs at least ' + [string]$specRules.surfaces_min + ' screens/routes/interfaces/modules') }
    if ($journeyCount -lt [int]$specRules.journeys_min) { [void]$issues.Add('project contract needs at least ' + [string]$specRules.journeys_min + ' user journeys/workflows/scenarios') }
    if ($acceptanceCount -lt [int]$specRules.acceptance_min) { [void]$issues.Add('project contract needs at least ' + [string]$specRules.acceptance_min + ' acceptance scenarios/checks') }
    if ($interfaceCount -lt [int]$specRules.interface_min) { [void]$issues.Add('project contract needs ux_contract or interface_contract') }
    if ([bool]$specRules.require_planning_flow -and -not $planningFlow) {
      [void]$issues.Add('project contract needs planning_flow with staged discussions')
    } elseif ($planningFlow) {
      $requiredStageIds = @($specRules.stage_ids | ForEach-Object { [string]$_ })
      foreach ($stageDef in @(Get-ProjectAutopilotPlanningStageDefinitions)) {
        $sid = [string]$stageDef.id
        if ($requiredStageIds -notcontains $sid) { continue }
        if (-not $stageById.ContainsKey($sid)) {
          [void]$issues.Add('planning_flow missing stage: ' + $sid)
          continue
        }
        $stage = $stageById[$sid]
        $status = ([string](Get-ProjectAutopilotContractValue -Obj $stage -Names @('status','state') -Default '')).Trim().ToLowerInvariant()
        $summary = ([string](Get-ProjectAutopilotContractValue -Obj $stage -Names @('summary','outcome','decision_summary') -Default '')).Trim()
        if ($status -notin @('complete','approved','done')) { [void]$issues.Add('planning_flow stage not complete: ' + $sid) }
        if ($summary.Length -lt 40) { [void]$issues.Add('planning_flow stage summary too short: ' + $sid) }
      }
      $integration = $null
      try { if ($stageById.ContainsKey('integration')) { $integration = $stageById['integration'] } } catch {}
      $integrationDeps = @(Get-ProjectAutopilotContractArray -Obj $integration -Names @('depends_on','dependsOn','validated_stages'))
      if ([int]$specRules.integration_dep_min -gt 0 -and $integrationDeps.Count -lt [int]$specRules.integration_dep_min) {
        [void]$issues.Add('planning_flow integration stage must depend on/validate prior stages')
      }
    }
  }

  return [pscustomobject]@{
    ready = ($issues.Count -eq 0)
    issues = @($issues.ToArray())
    spec_profile = [string]$specRules.profile
    signature = (Get-ProjectAutopilotPlanSignature -ProjectRoot $ProjectRoot)
    map_path = $mapPath
    plan_path = $planPath
    contract_path = $contractPath
    delivery_contract_ok = $deliveryContractOk
    delivery_contract_score = $deliveryContractScore
    delivery_contract_missing = @($deliveryContractMissing)
    delivery_contract_warnings = @($deliveryContractWarnings)
    delivery_contract_blockers = @($deliveryContractBlockers)
    delivery_contract_required_sections = @($deliveryContractRequiredSections)
    counts = [pscustomobject]@{
      requirements = $reqCount
      surfaces = $surfaceCount
      journeys = $journeyCount
      acceptance = $acceptanceCount
      interface_contract = $interfaceCount
      planning_stages = $planningStageCount
      stage_doc_lengths = [pscustomobject]$stageDocLengths
    }
  }
}

function New-ProjectAutopilotCoordinatorTaskText {
  param(
    [string]$Slug,
    [string]$ProjectRoot,
    [int]$MaxTasks = 12,
    [string]$DiffusionMode = 'off',
    [int]$DiffusionMinIndependentAtoms = 2,
    [int]$DiffusionMaxWaveSize = 6
  )
  $max = [Math]::Max(1, [Math]::Min(50, [int]$MaxTasks))
  $diffMode = ([string]$DiffusionMode).Trim().ToLowerInvariant()
  if ($diffMode -notin @('off','shadow','diffusion','wide')) { $diffMode = 'off' }
  $diffK = [Math]::Max(1, [Math]::Min(50, [int]$DiffusionMinIndependentAtoms))
  $diffN = [Math]::Max(1, [Math]::Min(50, [int]$DiffusionMaxWaveSize))
  # 2026-06-27 root-fix: deterministic plan-chapter progress injected into the coordinator prompt.
  # Root cause of premature autopilot pause: the coordinator was 100% LLM-judgment for "which chapter
  # is next / is the release complete". After decomposing a few chapters it conservatively judged the
  # release done, emitted no PROJECT_BACKLOG, and the empty-coordinator-streak paused it at 3/8 chapters.
  # We compute the next undecomposed chapter from PROJECT_PLAN.md and tell the coordinator explicitly,
  # so it advances through ALL approved chapters instead of guessing the release is finished early.
  $chapterProgressBlock = ''
  try {
    $planFileCP = Join-Path $ProjectRoot 'PROJECT_PLAN.md'
    if (Test-Path -LiteralPath $planFileCP -PathType Leaf) {
      $planTxtCP = [System.IO.File]::ReadAllText($planFileCP, [System.Text.Encoding]::UTF8)
      $chapMatchesCP = [regex]::Matches($planTxtCP, '(?m)^##\s+\S+\s+(\d+)\s*[—–:\-]\s*(.+?)\s*$')
      $totalChCP = $chapMatchesCP.Count
      if ($totalChCP -gt 0) {
        $planLinesCP = @()
        foreach ($mLineCP in $chapMatchesCP) { $planLinesCP += ('  ' + [string]$mLineCP.Groups[1].Value + ': ' + ([string]$mLineCP.Groups[2].Value).Trim()) }
        # decomposed chapters = distinct non-empty 'chapter' slugs among this channel's project-autopilot
        # atoms (reliable: every decomposed chapter has atoms; CHAPTER_N_ATOMS.md files are not always written).
        $doneChaptersCP = New-Object System.Collections.Generic.HashSet[string]
        try {
          foreach ($biCP in @(Get-Backlog)) {
            if ([string](Get-BacklogPackObjectValue -Obj $biCP -Name 'from' -Default '') -ne 'project-autopilot') { continue }
            $chpCP = ([string](Get-BacklogPackObjectValue -Obj $biCP -Name 'chapter' -Default '')).Trim()
            $chkCP = Get-ProjectAutopilotChapterKey -Chapter $chpCP
            if (-not [string]::IsNullOrWhiteSpace($chkCP)) { [void]$doneChaptersCP.Add($chkCP) }
          }
        } catch {}
        $decCountCP = $doneChaptersCP.Count
        $nextNCP = $decCountCP + 1
        $nextTitleCP = ''
        if ($nextNCP -ge 1 -and $nextNCP -le $totalChCP) { $nextTitleCP = ([string]$chapMatchesCP[$nextNCP-1].Groups[2].Value).Trim() }
        $doneSlugsCP = (@($doneChaptersCP) -join ', '); if ([string]::IsNullOrWhiteSpace($doneSlugsCP)) { $doneSlugsCP = '(none yet)' }
        $remainCP = $totalChCP - $decCountCP
        # 2026-06-30 cross-chapter WIDE: in wide mode the deterministic block tells the coordinator to
        # decompose ALL remaining chapters in one PROJECT_BACKLOG (the executor frontier then runs the
        # independent atoms across chapters in parallel; dependents serialize via depends_on). Any other
        # mode keeps the proven one-chapter-at-a-time default.
        $decomposeScopeLine = if ($diffMode -eq 'wide') {
          "Decompose ALL remaining approved chapters (Chapter $nextNCP through Chapter $totalChCP) into atoms in ONE PROJECT_BACKLOG this run (cross-chapter WIDE mode). Give INDEPENDENT atoms (different files, no real prerequisite) an EMPTY depends_on so they run in parallel across chapters; give DEPENDENT atoms an explicit depends_on on the prerequisite atom's slug (those serialize). Keep each atom's files to exactly ONE path so independent atoms never collide. No interface-contract/stub/stitching ceremony is required in wide mode. DECOMPOSE FINELY -- this is the single most important rule for wide mode: split EVERY chapter into its FULL set of small one-file atoms, the SAME fineness you would use if that chapter were the only one (do NOT emit a coarse 1-2 atoms per chapter -- that wastes the parallel team). MAXIMIZE THE FIRST WAVE of independent work: split each screen into separate screen / state / preview / formatting files, split the domain into one file per filter/model/mapper, give every leaf file (constants, theme, resources, helpers) its own atom. Aim for AT LEAST 12-20 atoms with EMPTY depends_on so 12-20 run concurrently in the first wave. Only put a depends_on when the file literally cannot be written before the prerequisite exists (a test needs the impl; an integration/nav-host needs the screens; the release/APK needs integration). More small independent atoms = wider parallelism; err on the side of MORE, smaller atoms."
        } else {
          "Decompose ONLY Chapter $nextNCP into atoms this run."
        }
        if ($nextNCP -le $totalChCP) {
          $chapterProgressBlock = "DETERMINISTIC PLAN PROGRESS (authoritative -- computed from PROJECT_PLAN.md + the live backlog; trust this over your own judgment about whether the release is finished):`n- The approved release IS the full plan: $totalChCP chapters total, ALL approved and in scope. Chapters you have not reached yet are NOT future/optional/out-of-scope work.`n- Full approved plan chapters:`n$($planLinesCP -join "`n")`n- Chapter areas already decomposed into the backlog ($decCountCP of $totalChCP done): $doneSlugsCP`n- NEXT chapter to decompose NOW: Chapter $nextNCP - $nextTitleCP`n- $decomposeScopeLine Do NOT conclude the release is complete -- $remainCP chapter(s) still remain. Do NOT emit a release-scope open-question for Chapter $nextNCP; it is already authorized by the approved plan.`n- Efficiency: the plan progress above is authoritative for scope/status, so you do NOT need to re-read PROJECT_MAP.md or re-scan the whole codebase to decide what is done. Read only the specific source files your Chapter $nextNCP atoms will create, touch, or depend on (check earlier CHAPTER_*_ATOMS.md only for file-ownership of prior chapters to avoid conflicts).`n`n"
        } else {
          $chapterProgressBlock = "DETERMINISTIC PLAN PROGRESS: all $totalChCP approved plan chapters are already decomposed into the backlog. Only if every chapter's atoms are done AND acceptance passes may you finish without PROJECT_BACKLOG; otherwise emit the remaining atoms.`n`n"
        }
      }
    }
  } catch {}
  return @"
[project-autopilot $Slug] [[NORMAL]]

Project Autopilot coordinator for channel '$Slug'.

Work only in $ProjectRoot.

Mission: keep this project moving without the operator manually feeding backlog items.

Coordinator mode:
- diffusion_mode: $diffMode
- diffusion_min_independent_atoms: $diffK
- diffusion_max_wave_size: $diffN

Plan gate status:
- This coordinator is queued only after the channel-level Discuss-First plan gate has approved the current PROJECT_PLAN signature.
- Treat channels/$Slug/channel.json plan_approved=true and its approved signature as the source of truth for execution permission.
- If PROJECT_PLAN.md, PROJECT_MAP.md, or .bridge/project-contract.json still contain pre-approval wording such as "not approved", "UNAPPROVED", or "planned, not approved", do not treat that wording as a blocker after this coordinator has been queued. Use those words as historical planning status unless the channel gate itself is not approved.

$chapterProgressBlock
Rules:
- Do NOT implement feature code in this coordinator task, except small durable planning docs such as CHAPTER_N_ATOMS.md.
- Read the Bridge spec layer first: .bridge/constitution.md, .bridge/specs/*.md, .bridge/changes/*, PROJECT_BRIEF.md, DISCUSS_*.md when present, PROJECT_MAP.md, PROJECT_PLAN.md, .bridge/project-contract.json, existing CHAPTER_*_ATOMS.md files, README, git log/status, and current code.
- Read the project memory/context supplied in the prompt. Preserve durable decisions, risks, invariants, tests, and open questions.
$(Get-ProjectContractSchemaInstruction)
- requirements/capabilities/features do NOT replace explicit scope plus non_goals. user_journeys/journeys/flows/workflows do NOT replace explicit users/roles/personas/actors.
- Treat planning as staged: brief -> product -> UX -> UI -> backend -> QA -> integration. Every later stage must explicitly use decisions from earlier stages. The integration stage resolves cross-stage conflicts before implementation.
- If the constitution, required .bridge/specs/*.md files, stage docs, map, plan, or contract are shallow/missing/stale for the selected spec_profile, do NOT emit implementation atoms. Emit durable memory about the gap and finish, or emit docs-only planning atoms that deepen the missing spec/planning files and .bridge/project-contract.json.
- Determine the next approved/incomplete chapter from the contract and plan, not from a guessed feature list.
- Treat the approved contract/plan as a bounded current release, not open-ended permission to invent future product areas.
- Before creating a new chapter after the previous chapter appears complete, check the current acceptance/report/check status. If the approved release can now be accepted, or only nice-to-have/future work remains, finish without PROJECT_BACKLOG and emit concise durable memory/operator-review notes.
- Do not expand into new surfaces such as dashboards, admin panels, regeneration tools, web UIs, APIs, analytics, or background services unless that surface is explicitly in the approved current-release contract. "Could be useful" is not enough.
- If the contract does not explicitly authorize the next chapter/wave, do not create atoms for it; emit [[PROJECT_OPEN_QUESTION: release scope needs approval before new chapter]] and finish without PROJECT_BACKLOG.
- For full/large projects and high-risk changes, create or update .bridge/changes/<change-id>/proposal.md, design.md, tasks.md, and acceptance.md before implementation atoms, and archive completed change packages under .bridge/archive/<change-id>. Do not force change-package ceremony on lite/small work.
- Default decomposition is still ONE next chapter/wave into small atomic implementation tasks. Prefer 3-$max tasks; fewer is OK if the chapter is small.
- If diffusion_mode is wide: the DETERMINISTIC PLAN PROGRESS above authorizes decomposing ALL remaining chapters in ONE PROJECT_BACKLOG. Emit every remaining chapter's atoms with correct cross-chapter depends_on -- INDEPENDENT atoms get an EMPTY depends_on (they run in parallel across chapters), DEPENDENT atoms list their prerequisite atom's slug (they serialize). No interface contracts / freeze / stitching are needed in wide mode (it parallelizes only independent atoms; dependents serialize via depends_on). Each atom's "files" must be exactly ONE path so independent atoms never collide.
- Diffusion/cross-chapter decomposition is opt-in only. If diffusion_mode is off, always use the one-chapter default. If diffusion_mode is shadow, compute and report the would-be cross-chapter graph/gate result as durable markers but still emit only the one-chapter default. If diffusion_mode is diffusion, do not emit a cross-chapter PROJECT_BACKLOG unless every deterministic gate is satisfied: complete and stable .bridge/specs/contracts/<contract-id>.json coverage for every cross-atom interface, no [[PROJECT_OPEN_QUESTION]] blocking scope/architecture, a validated acyclic depends_on graph, known non-overlapping file ownership or explicit serial_reason, stitching/integration tests, clean git worktree, independent atom count >= $diffK, and wave size <= $diffN. If any condition is missing, fall back to the one-chapter default and emit [[PROJECT_OPEN_QUESTION: diffusion gate blocked: ...]] or a concise [[PROJECT_RISK: ...]] marker instead of guessing.
- Interface contracts live in .bridge/specs/contracts/<contract-id>.json. A contract must cover signature, behavior/preconditions/postconditions/side-effects/idempotency, invariants, error taxonomy, golden input/output examples, owned files/regions, and version. A contract is stable only after the deterministic freeze step writes a channel-local freeze lock with stable:true plus canonical_hash matching the canonical payload; a bare stable:true in the contract file is not sufficient. Atoms may reference contracts through provides and consumes arrays; a lock-verified frozen contract may justify a soft edge, while missing/unstable contracts require hard depends_on serialization.
- Each atom must be a small verifiable change, with clear dependencies, files/touch-set, acceptance checks, and commit requirement.
- Keep each atom to a SINGLE focused concern with a SMALL diff (ideally one function/class/area). Do NOT bundle multiple changes into one atom (e.g., new implementation + a refactor + cross-file tests): a large diff makes the completion-critic find many issues per pass and iterate for many slow rounds. Tests for a module are their own atom, separate from the implementation atoms they cover; a bug fix is its own atom. Small single-concern diffs let the critic converge in 1-2 rounds even when atoms run batched in parallel.
- Order infra-first: shared modules, contracts, schemas, adapters, migrations, and test harnesses must be emitted before feature atoms that consume them. Feature atoms that depend on shared infra must list the infra atom slug in depends_on.
- Model the execution DAG explicitly: independent atoms have empty depends_on; dependent atoms reference prerequisite slugs.
- Prefer a ready frontier: several independent atoms in the same wave, then dependent atoms in later waves.
- Design for PARALLELISM at the file level: prefer small, focused files (one concern per file) so atoms in the same wave touch DIFFERENT files and run concurrently. Avoid mega-files (one file accumulating many concerns) -- they force same-file atoms to serialize and bottleneck the parallel team. When a module would grow large, split it into a package of focused sibling submodules (re-exported via the package init) so each atom owns its own file. Two atoms in the same wave must not write the same file; if they must share a file, mark serial_reason and put them in different waves.
- CRITICAL for parallel speed: each atom's "files" MUST list ONLY the file(s) THAT ATOM itself creates or edits -- exactly ONE file for most atoms. Do NOT list a directory, do NOT list a sibling atom's file, and do NOT list files you only READ for context (mention those in the task text instead, never in "files"). Over-listing "files" makes the scheduler think independent atoms collide, and it serializes them -- this is the single biggest cause of slow, narrow waves. WRONG: three atoms each listing ["app/src/main/.../MainUiState.kt", "app/src/main/.../ui/"]. RIGHT: atom-a files=["app/src/main/.../ui/LoginScreen.kt"], atom-b files=["app/src/main/.../ui/HomeScreen.kt"], atom-c files=["app/src/main/.../ui/SettingsScreen.kt"] -- three distinct files that build in parallel.
- Use chapter, wave, kind, parallel_group, files, depends_on, acceptance, checks, risk/severity, and serial_reason so the scheduler can run the team safely. Optional kind values are infra, feature, consolidation, and planning; omit kind only for default feature atoms.
- Project atoms operate ONLY inside the project root and never modify the bridge engine, so they require no special admission. Keep every files entry within the project tree.
- Every atom acceptance must trace back to a project-contract requirement, journey, surface, or acceptance scenario. Do not use generic "looks good" UX checks.
- COMPILES IS NOT LAUNCHES: a green build plus passing unit tests do NOT prove the program actually starts. For any runtime entry point the framework instantiates at launch -- an Android Activity/ViewModel created by the default no-arg ViewModel factory, a main()/CLI entry, a server or service startup, a dependency-injection graph -- there MUST be a test that exercises that exact launch path: e.g. construct the launcher ViewModel via its default no-arg path (MainViewModel::class.java.getDeclaredConstructor().newInstance() must succeed), run main() with --help, hit the server health route, build the DI graph. Treat "the app starts without crashing" as a REQUIRED acceptance criterion, not an assumption. Launch/wiring crashes (classic example: a ViewModel that declares constructor parameters -- even with default values -- and therefore has NO public no-arg JVM constructor, so Compose viewModel() throws "Cannot create an instance" at startup) compile cleanly and pass unrelated unit tests, then crash instantly on the device. Only a launch-path test catches them before delivery.
- Before PROJECT_BACKLOG, emit durable project memory markers when useful:
  [[PROJECT_DECISION: ...]]
  [[PROJECT_RISK: ...]]
  [[PROJECT_INVARIANT: ...]]
  [[PROJECT_TEST: ...]]
  [[PROJECT_OPEN_QUESTION: ...]]
  Keep memory concise and durable; do not store transient progress noise.
- If a product decision is truly blocking, do not invent it: emit [[PROJECT_OPEN_QUESTION: ...]] and finish without PROJECT_BACKLOG.
- Never commit real API keys, local DB files, uploads, .next, or node_modules to git.
- For Next.js/TypeScript work, each atom should normally require npm run typecheck and npm run build unless the atom is docs-only.

When you have the next atom batch, output it as STRICT JSON inside this exact marker:
[[PROJECT_BACKLOG]]
[
  {
    "slug": "short-stable-atom-id",
    "title": "Human readable atom title",
    "task": "Full task text for the worker. Include project path, dependencies, acceptance checks, and commit requirement.",
    "chapter": "Chapter <N> - <title>",
    "wave": "wave-1",
    "kind": "infra|feature|consolidation|planning",
    "parallel_group": "auth|gallery|chat|admin|docs|tests|...",
    "files": ["relative/path/or/directory"],
    "provides": ["contract-id-provided-by-this-atom"],
    "consumes": ["contract-id-consumed-by-this-atom"],
    "depends_on": ["slug-of-prerequisite-if-any"],
    "acceptance": ["observable acceptance criterion tied to the approved contract"],
    "checks": ["npm run typecheck", "npm run build"],
    "risk": "normal",
    "severity": "normal",
    "serial_reason": "",
    "workpack_touch_set": ["relative/path/or/directory"],
    "workpack_conflict_group": "file:relative/path/or/directory"
  }
]
[[/PROJECT_BACKLOG]]

depends_on may be []; kind may be omitted and then defaults to feature; serial_reason may be "" for parallel atoms. acceptance/checks must be concrete, not generic "looks good". files must be the real touch-set / scheduler-allowed paths. workpack_touch_set and workpack_conflict_group are optional explicit scheduler metadata; omit them unless files alone would be ambiguous. Incomplete atoms are rejected by the deterministic ingest gate. IMPORTANT: every atom's "chapter" MUST begin with the plan chapter NUMBER it belongs to (the leading integer from the matching PROJECT_PLAN.md "## ... N ..." heading), e.g. "Chapter 7 - Hardware triggers". Decomposed-chapter progress is keyed on that ordinal, so a missing/inconsistent number makes the planner miscount and can skip or repeat a chapter.

The driver will add those atoms to approved project backlog automatically. Do not use operator-delegate and do not edit backlog.jsonl manually.

Finish with STATUS: DONE after emitting the marker, or STATUS: DONE without the marker if no work remains.
"@
}

function Test-ProjectPlanApproved {
  # 2026-06-02: Discuss-First gate for Project Autopilot. Autopilot only EXPANDS a PROJECT_PLAN the
  # operator has explicitly APPROVED (flow phase Ф4). Without approval the bridge stays in discuss/
  # planning and does NOT auto-generate/execute atoms — this keeps autopilot UNDER Discuss-First, not
  # instead of it, and prevents it from scaling an un-vetted plan into a frankenstein (observed on
  # private-community: 246 files build-green but product-incoherent because the plan skipped Ф1–Ф4).
  # Reads channels/<ch>/channel.json -> plan_approved. Default $false = safe (no approval => no autopilot).
  param([string]$Channel, [string]$ProjectRoot = '')
  try {
    $cj = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel) 'channel.json'
    if (-not (Test-Path -LiteralPath $cj)) { return $false }
    $raw = [System.IO.File]::ReadAllText($cj, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not $raw -or -not ($raw.PSObject.Properties.Name -contains 'plan_approved') -or -not [bool]$raw.plan_approved) { return $false }
    $approvedSignature = ''
    try {
      if ($raw.PSObject.Properties.Name -contains 'plan_approved_signature') { $approvedSignature = [string]$raw.plan_approved_signature }
    } catch {}
    if (-not [string]::IsNullOrWhiteSpace($approvedSignature) -and -not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
      $currentSignature = Get-ProjectAutopilotPlanSignature -ProjectRoot $ProjectRoot
      if ([string]::IsNullOrWhiteSpace($currentSignature)) { return $false }
      if ($currentSignature -ne $approvedSignature) {
        $approvedGitHead = ''
        try {
          if ($raw.PSObject.Properties.Name -contains 'plan_approved_git_head') { $approvedGitHead = [string]$raw.plan_approved_git_head }
        } catch {}
        $unchanged = Test-ProjectAutopilotPlanFilesUnchangedSinceGitHead -ProjectRoot $ProjectRoot -GitHead $approvedGitHead
        if (-not ([bool]$unchanged.ok -and [bool]$unchanged.unchanged)) { return $false }
      }
    }
    return $true
  } catch {}
  return $false
}

function Set-ProjectPlanApproved {
  # Operator action at Discuss-First Ф4: mark a channel's PROJECT_PLAN approved so Project Autopilot may
  # begin executing it. Also stamps the approved time. To re-gate (force re-approval), pass -Approved:$false.
  param([string]$Channel, [bool]$Approved = $true)
  $cj = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel) 'channel.json'
  if (-not (Test-Path -LiteralPath $cj)) { throw "channel.json not found: $Channel" }
  $raw = [System.IO.File]::ReadAllText($cj, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  $projectRoot = ''
  try {
    if ($raw -and ($raw.PSObject.Properties.Name -contains 'project_root')) { $projectRoot = [string]$raw.project_root }
  } catch {}
  try {
    if ([string]::IsNullOrWhiteSpace($projectRoot) -and (Get-Command Get-ChannelProjectBinding -ErrorAction SilentlyContinue)) {
      $binding = Get-ChannelProjectBinding -Slug $Channel
      if ($binding -and [bool]$binding.ok) { $projectRoot = [string]$binding.project_root }
    }
  } catch {}
  $contractReady = $null
  if ($Approved) {
    $contractReady = Test-ProjectPlanContractReady -ProjectRoot $projectRoot
    if (-not [bool]$contractReady.ready) {
      throw ("project plan contract is not ready: " + ((@($contractReady.issues) | Select-Object -First 8) -join '; '))
    }
  }
  $raw | Add-Member -NotePropertyName plan_approved -NotePropertyValue $Approved -Force
  $raw | Add-Member -NotePropertyName plan_approved_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
  if ($Approved -and $contractReady) {
    $raw | Add-Member -NotePropertyName plan_approved_signature -NotePropertyValue ([string]$contractReady.signature) -Force
    $raw | Add-Member -NotePropertyName plan_approved_signature_version -NotePropertyValue 'bridge-spec-v1' -Force
    $raw | Add-Member -NotePropertyName plan_approved_files -NotePropertyValue @(Get-ProjectAutopilotPlanSignatureFiles -ProjectRoot $projectRoot) -Force
    $raw | Add-Member -NotePropertyName plan_spec_profile -NotePropertyValue ([string]$contractReady.spec_profile) -Force
    $raw | Add-Member -NotePropertyName plan_approved_git_head -NotePropertyValue (Get-ProjectAutopilotGitHead -ProjectRoot $projectRoot) -Force
    $raw | Add-Member -NotePropertyName plan_contract_path -NotePropertyValue ([string]$contractReady.contract_path) -Force
    $raw | Add-Member -NotePropertyName plan_contract_score -NotePropertyValue $contractReady.delivery_contract_score -Force
    $raw | Add-Member -NotePropertyName plan_contract_required_sections -NotePropertyValue @($contractReady.delivery_contract_required_sections) -Force
  } elseif (-not $Approved) {
    $raw | Add-Member -NotePropertyName plan_approved_signature -NotePropertyValue '' -Force
    $raw | Add-Member -NotePropertyName plan_approved_signature_version -NotePropertyValue '' -Force
    $raw | Add-Member -NotePropertyName plan_approved_files -NotePropertyValue @() -Force
    $raw | Add-Member -NotePropertyName plan_spec_profile -NotePropertyValue '' -Force
    $raw | Add-Member -NotePropertyName plan_approved_git_head -NotePropertyValue '' -Force
  }
  [System.IO.File]::WriteAllText($cj, (($raw | ConvertTo-Json -Depth 10) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  # clear the one-time gate-notified marker so a future re-gate (plan rewrite) notifies the operator again
  try { $gm = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel) '.plan-gate-notified'; if (Test-Path -LiteralPath $gm) { Remove-Item -LiteralPath $gm -Force -ErrorAction SilentlyContinue } } catch {}
  try { $cm = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel) '.plan-contract-gate-notified'; if (Test-Path -LiteralPath $cm) { Remove-Item -LiteralPath $cm -Force -ErrorAction SilentlyContinue } } catch {}
  # 2026-06-14 (operator root-fix): on (re-)approval, baseline the autopilot empty-coordinator-streak so an
  # expanded release scope RESUMES the autopilot instead of staying deadlocked on an old 'release done'
  # streak. Re-approval = fresh operator authorization to keep building -> clear the empty-streak pause.
  if ($Approved) {
    try {
      $apState = Read-ProjectAutopilotState
      if (-not $apState) { $apState = [pscustomobject]@{} }
      $apState | Add-Member -NotePropertyName empty_streak_reset_ts -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
      $apState | Add-Member -NotePropertyName empty_coordinator_streak -NotePropertyValue 0 -Force
      # Clear the sticky hard-pause flag too: the pause message says "до расширения PROJECT_PLAN/scope",
      # and a re-approval IS that scope expansion + fresh operator authorization. Without clearing this,
      # the gate at the top of Start-ProjectAutopilotIfNeeded short-circuits on paused=true before the
      # (now reset) streak is ever consulted -> permanent deadlock.
      $apState | Add-Member -NotePropertyName paused -NotePropertyValue $false -Force
      $apState | Add-Member -NotePropertyName paused_at -NotePropertyValue '' -Force
      $apState | Add-Member -NotePropertyName pause_reason -NotePropertyValue '' -Force
      Write-ProjectAutopilotState -State $apState
    } catch {}
  }
  return $Approved
}

function Invoke-ProjectAutopilotHeldDuplicateAutoHeal {
  # 2026-06-27 lever#4 (GENERAL logic, any approved project): auto-resolve atoms stuck in status='held'
  # with attempts=0 (held BEFORE any execution attempt -- e.g. dedup / touch-overlap) whose declared
  # deliverable files ALL already exist on disk AND are committed to git in the project repo. Such an
  # atom is a duplicate of work a sibling atom already delivered; it sits held forever and clutters the
  # queue. Strong guards prevent ever auto-passing genuinely-failed work: only attempts=0 (never ran),
  # only project scope, never operator-held / failure-flagged, and every file must be git-tracked.
  param([string]$ProjectRoot = '')
  $out = [pscustomobject]@{ checked = 0; resolved = 0; resolved_ids = @() }
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot)) { return $out }
  $resolved = New-Object System.Collections.Generic.List[string]
  $checked = 0
  foreach ($item in @(Get-Backlog)) {
    if ([string]$item.status -ne 'held') { continue }
    $att = 0; try { $att = [int]$item.attempts } catch {}
    if ($att -ne 0) { continue }
    $scope = ''; try { $scope = ([string]$item.scope).ToLowerInvariant() } catch {}
    $proj = ''; try { $proj = [string]$item.project } catch {}
    if ($scope -ne 'project' -and [string]::IsNullOrWhiteSpace($proj)) { continue }
    $heldBy = ''; try { $heldBy = ([string]$item.held_by).ToLowerInvariant() } catch {}
    if ($heldBy -eq 'operator') { continue }
    $rsn = ''; try { $rsn = ([string]$item.reason).ToLowerInvariant() } catch {}
    if ($rsn -match 'fail|error|critic|reject|operator') { continue }
    $checked++
    # Use the atom's declared DELIVERABLE files (the 'files' field), NOT workpack_touch_set —
    # touch_set is the expanded set that also lists reference files (contract, plan) the atom merely
    # reads, which are not deliverables and may live outside the project repo.
    $files = @()
    try { if (($item.PSObject.Properties.Name -contains 'files') -and $item.files) { $files = @(@($item.files) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } } catch {}
    if (@($files).Count -eq 0) { continue }
    $allCommitted = $true
    foreach ($rel in @($files)) {
      if ([string]::IsNullOrWhiteSpace([string]$rel)) { $allCommitted = $false; break }
      $abs = Join-Path $ProjectRoot ([string]$rel)
      if (-not (Test-Path -LiteralPath $abs)) { $allCommitted = $false; break }
      $tracked = $false
      try { $null = & git -C $ProjectRoot ls-files --error-unmatch -- ([string]$rel) 2>$null; $tracked = ($LASTEXITCODE -eq 0) } catch { $tracked = $false }
      if (-not $tracked) { $allCommitted = $false; break }
    }
    if (-not $allCommitted) { continue }
    try {
      Set-Idea -Id ([string]$item.id) -Status 'done' -Reason 'auto-resolved: deliverable already exists and is committed (held-duplicate auto-heal)' | Out-Null
      [void]$resolved.Add([string]$item.id)
    } catch {}
  }
  $out.checked = $checked
  $out.resolved = $resolved.Count
  $out.resolved_ids = @($resolved.ToArray())
  return $out
}

function Start-ProjectAutopilotIfNeeded {
  param([string]$Reason = 'idle-empty-backlog')
  # Driver idle hook enters here before autonomy claim; piggyback operator-batch
  # completion reporting on that existing hook so we do not touch the control plane.
  try {
    Publish-OperatorBatchCompletionSummariesIfNeeded | Out-Null
  } catch {
    Write-OperatorBatchReportError -Message ("Publish-OperatorBatchCompletionSummariesIfNeeded: " + $_.Exception.Message)
  }
  $cfg = Get-ProjectAutopilotConfig
  if (-not [bool]$cfg.enabled) { return [pscustomobject]@{ queued=$false; reason='disabled' } }
  $binding = Get-ProjectAutopilotBinding
  if (-not $binding) { return [pscustomobject]@{ queued=$false; reason='not-project-channel' } }
  $slug = [string]$binding.slug
  $root = [string]$binding.project_root
  # 2026-06-30 (diffusion-trigger-schema-mismatch): bridge the DISCUSS->autopilot handoff. If this
  # channel has a discuss plan board + contract but no durable PROJECT_PLAN.md yet, materialize the
  # autopilot's required spec artifacts from it (so the contract gate can pass) and surface a
  # "ready -- approve" message. This NEVER approves the plan: plan_approved stays the manual Ф4 gate below.
  try {
    if (Get-Command Initialize-ProjectAutopilotInputsFromDiscuss -ErrorAction SilentlyContinue) {
      Initialize-ProjectAutopilotInputsFromDiscuss -Channel $slug -ProjectRoot $root | Out-Null
    }
  } catch {}
  # B2 (diffusion orphan-stub sweep, detect-only): surface any .bridge/stubs/* left committed in the project
  # by a stitch that finished/vanished (a leaked frozen stub). Telemetry only -- reversible cleanup is not
  # auto-run here (it would dirty/commit the project worktree); B1 strand-hold already surfaces the root
  # cause to the operator. Cheap (returns before touching the backlog when the stub dir is absent -- the
  # common no-diffusion case); guarded so it never throws on the idle hot path.
  try {
    if (Get-Command Get-ProjectAutopilotOrphanStubs -ErrorAction SilentlyContinue) {
      $orphanScan = Get-ProjectAutopilotOrphanStubs -ProjectRoot $root -Action 'detect'
      if ($orphanScan -and @($orphanScan.orphans).Count -gt 0) {
        Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='project-autopilot-diffusion-orphan-stubs'; channel=$slug; orphan_count=[int]@($orphanScan.orphans).Count; orphans=@($orphanScan.orphans | Select-Object -First 12); scanned=[int]$orphanScan.scanned })
      }
    }
  } catch {}
  # 2026-06-02 DISCUSS-FIRST GATE: autopilot only executes an operator-APPROVED PROJECT_PLAN (Ф4).
  # Until the operator runs Set-ProjectPlanApproved for this channel, the bridge stays in discuss/
  # planning and autopilot does NOT auto-queue coordinator/atoms. This is the fix for autopilot
  # bypassing Ф1–Ф4 and scaling an un-vetted plan into a frankenstein.
  if (-not (Test-ProjectPlanApproved -Channel $slug -ProjectRoot $root)) {
    return [pscustomobject]@{ queued=$false; reason='plan-not-approved'; channel=$slug }
  }
  $planContract = Test-ProjectPlanContractReady -ProjectRoot $root
  if (-not [bool]$planContract.ready) {
    return [pscustomobject]@{
      queued = $false
      reason = 'plan-contract-not-ready'
      channel = $slug
      project_root = $root
      issues = @($planContract.issues)
      spec_profile = [string]$planContract.spec_profile
      contract_path = [string]$planContract.contract_path
      delivery_contract_ok = $planContract.delivery_contract_ok
      delivery_contract_score = $planContract.delivery_contract_score
      delivery_contract_missing = @($planContract.delivery_contract_missing)
      delivery_contract_warnings = @($planContract.delivery_contract_warnings)
      delivery_contract_blockers = @($planContract.delivery_contract_blockers)
      delivery_contract_required_sections = @($planContract.delivery_contract_required_sections)
    }
  }

  # 2026-06-27 lever#4: before any queue decision, auto-heal stuck held-duplicate atoms whose
  # deliverables already exist + are committed (general logic; runs for any approved project, even paused).
  try {
    $healRes = Invoke-ProjectAutopilotHeldDuplicateAutoHeal -ProjectRoot $root
    if ($healRes -and [int]$healRes.resolved -gt 0) {
      try { Add-Message -From system -Text ("🩹 Project Autopilot: авто-закрыто " + [int]$healRes.resolved + " зависших дубликат-задач (deliverable уже готов и закоммичен).") -Kind event | Out-Null } catch {}
    }
  } catch {}

  $pressure = Get-ProjectAutopilotBacklogPressure
  # 2026-06-28 fix (problem-hunt defect #2 — double-decompose): decompose-ahead is owned SOLELY by the
  # detached background worker (Invoke-BackgroundDecomposeAheadIfNeeded) when decomposeAheadLimit > 1.
  # The foreground path must NEVER decompose ahead: a foreground coordinator is a blocking ~15-min agent
  # turn that monopolizes the single channel slot (the reverted d2ffe2d wedge) AND would race the
  # background worker on the same next chapter, producing two concurrent planning turns + duplicate atoms.
  # So while the current chapter still has runnable atoms, yield and let the executor drain them; the
  # background worker plans the next chapter out-of-band. (No flag dependency here on purpose: foreground
  # is always one-chapter-at-a-time; concurrency comes from the background owner.)
  if ([int]$pressure.runnable -gt 0) {
    return [pscustomobject]@{ queued=$false; reason='backlog-not-empty'; pressure=$pressure }
  }
  # Defect #2 belt-and-suspenders: even on the idle-empty path, if a detached background decompose worker
  # is live for this channel it is already planning the next chapter — do not also queue a foreground
  # coordinator targeting the same chapter (avoids the double-decompose at chapter boundaries). Let the
  # background worker finish; the next idle tick re-evaluates.
  try {
    if ((Get-Command Test-BackgroundDecomposeRunning -ErrorAction SilentlyContinue) -and (Test-BackgroundDecomposeRunning -Channel $slug)) {
      return [pscustomobject]@{ queued=$false; reason='background-decompose-running'; pressure=$pressure }
    }
  } catch {}
  if ([int]$pressure.autopilot_open -gt 0) { return [pscustomobject]@{ queued=$false; reason='autopilot-already-open'; pressure=$pressure } }

  $last = Read-ProjectAutopilotState
  if ($last) {
    try {
      if ([bool](Get-BacklogPackObjectValue -Obj $last -Name 'paused' -Default $false)) {
        return [pscustomobject]@{
          queued = $false
          reason = 'paused-empty-scope'
          empty_coordinator_streak = (Get-ProjectAutopilotStateInt -State $last -Name 'empty_coordinator_streak' -Default 0)
          pause_reason = [string](Get-BacklogPackObjectValue -Obj $last -Name 'pause_reason' -Default '')
          pressure = $pressure
        }
      }
    } catch {}
    try {
      $stateStreakExisting = Get-ProjectAutopilotStateInt -State $last -Name 'empty_coordinator_streak' -Default 0
      $inferredEmptyExisting = [int](Get-ProjectAutopilotInferredEmptyCoordinatorStreak)
      if ($inferredEmptyExisting -gt $stateStreakExisting) {
        if ($inferredEmptyExisting -ge [int]$cfg.emptyCoordinatorLimit) {
          $nowPauseExisting = (Get-Date).ToUniversalTime().ToString('o')
          $last | Add-Member -NotePropertyName ts -NotePropertyValue $nowPauseExisting -Force
          $last | Add-Member -NotePropertyName channel -NotePropertyValue $slug -Force
          $last | Add-Member -NotePropertyName project_root -NotePropertyValue $root -Force
          $last | Add-Member -NotePropertyName empty_coordinator_streak -NotePropertyValue $inferredEmptyExisting -Force
          $last | Add-Member -NotePropertyName paused -NotePropertyValue $true -Force
          $last | Add-Member -NotePropertyName paused_at -NotePropertyValue $nowPauseExisting -Force
          $last | Add-Member -NotePropertyName pause_reason -NotePropertyValue ("legacy empty coordinator streak reached $inferredEmptyExisting/$([int]$cfg.emptyCoordinatorLimit) without PROJECT_BACKLOG") -Force
          if (-not ($last.PSObject.Properties.Name -contains 'recent_outcomes')) { $last | Add-Member -NotePropertyName recent_outcomes -NotePropertyValue @() -Force }
          Write-ProjectAutopilotState $last
          try {
            Add-Message -From system -Text ("⏸ Project Autopilot: найден старый пустой цикл coordinator-задач (" + $inferredEmptyExisting + "/" + [int]$cfg.emptyCoordinatorLimit + "). Автопилот канала " + $slug + " поставлен на паузу до расширения PROJECT_PLAN/scope.") -Kind event | Out-Null
          } catch {}
          return [pscustomobject]@{ queued=$false; reason='paused-empty-scope'; empty_coordinator_streak=$inferredEmptyExisting; pressure=$pressure }
        }
      }
    } catch {}
    try {
      $lastTs = [datetime]::Parse([string]$last.ts).ToUniversalTime()
      $ageMin = ((Get-Date).ToUniversalTime() - $lastTs).TotalMinutes
      if ($ageMin -lt [int]$cfg.cooldownMinutes) {
        return [pscustomobject]@{ queued=$false; reason='cooldown'; cooldown_remaining_minutes=[int]([int]$cfg.cooldownMinutes - [Math]::Floor($ageMin)); pressure=$pressure }
      }
    } catch {}
  } else {
    try {
      $inferredEmpty = [int](Get-ProjectAutopilotInferredEmptyCoordinatorStreak)
      if ($inferredEmpty -ge [int]$cfg.emptyCoordinatorLimit) {
        $nowPause = (Get-Date).ToUniversalTime().ToString('o')
        $pauseState = [pscustomobject]@{
          ts = $nowPause
          channel = $slug
          project_root = $root
          queued_id = ''
          reason = [string]$Reason
          empty_coordinator_streak = $inferredEmpty
          paused = $true
          paused_at = $nowPause
          pause_reason = "legacy empty coordinator streak reached $inferredEmpty/$([int]$cfg.emptyCoordinatorLimit) without PROJECT_BACKLOG"
          recent_outcomes = @()
        }
        Write-ProjectAutopilotState $pauseState
        try {
          Add-Message -From system -Text ("⏸ Project Autopilot: найден старый пустой цикл coordinator-задач (" + $inferredEmpty + "/" + [int]$cfg.emptyCoordinatorLimit + "). Автопилот канала " + $slug + " поставлен на паузу до расширения PROJECT_PLAN/scope.") -Kind event | Out-Null
        } catch {}
        return [pscustomobject]@{ queued=$false; reason='paused-empty-scope'; empty_coordinator_streak=$inferredEmpty; pressure=$pressure }
      }
    } catch {}
  }

  if (-not (Test-ProjectAutopilotProjectClean -ProjectRoot $root)) {
    return [pscustomobject]@{ queued=$false; reason='project-dirty-or-git-unavailable'; pressure=$pressure }
  }

  # 2026-06-28 (upfront-speed #2): retire the redundant FOREGROUND coordinator whenever decompose-ahead is
  # ON (decomposeAheadLimit > 1). A foreground coordinator is CLAIMED into the channel's single driver slot
  # and runs a ~10-25 min LLM decompose turn; while it runs, the driver takes the active-task branch
  # (driver/81-loop-idle-claim.ps1:1958) and NEVER reaches the atom-batch claim (81:704). So already-packed,
  # ready atoms sit at status=approved/running=0 and the parallel build cannot start -- observed live on
  # selfie-styler: 8 atoms workpack_id-ready (fix#1) but blocked 14+ min behind a foreground coordinator.
  # With decompose-ahead enabled, the DETACHED background worker (Test-ShouldBackgroundDecompose, which now
  # has a cold-start carve-out) is the SOLE decomposer and plans every chapter OFF the critical slot, so the
  # slot is only ever used to EXECUTE atoms -> ready atoms dispatch the instant they are packed. When the
  # flag is <=1 (default), this returns false and the foreground remains the sole decomposer (unchanged).
  $decomposeAheadLimit = 1
  try { $decomposeAheadLimit = [int]$cfg.decomposeAheadLimit } catch { $decomposeAheadLimit = 1 }
  if ($decomposeAheadLimit -gt 1) {
    return [pscustomobject]@{ queued=$false; reason='decompose-ahead-owns-decomposition'; pressure=$pressure }
  }

  $task = New-ProjectAutopilotCoordinatorTaskText -Slug $slug -ProjectRoot $root -MaxTasks ([int]$cfg.maxTasksPerBatch) -DiffusionMode ([string]$cfg.diffusionMode) -DiffusionMinIndependentAtoms ([int]$cfg.diffusionMinIndependentAtoms) -DiffusionMaxWaveSize ([int]$cfg.diffusionMaxWaveSize)
  $id = Add-Idea -Text $task -From 'project-autopilot' -Tags @('project-autopilot','auto-generated') -Status 'approved' -Severity 'critical' -Project $slug -Scope 'project' -SkipCurator
  if ([string]::IsNullOrWhiteSpace([string]$id)) { return [pscustomobject]@{ queued=$false; reason='add-idea-failed'; pressure=$pressure } }

  $st = [ordered]@{
    ts = (Get-Date).ToUniversalTime().ToString('o')
    channel = $slug
    project_root = $root
    queued_id = [string]$id
    reason = [string]$Reason
    empty_coordinator_streak = (Get-ProjectAutopilotStateInt -State $last -Name 'empty_coordinator_streak' -Default 0)
    paused = $false
    paused_at = ''
    pause_reason = ''
    recent_outcomes = @(Get-ProjectAutopilotRecentOutcomes -State $last)
  }
  Write-ProjectAutopilotState ([pscustomobject]$st)
  try {
    Write-BacklogJsonLine ([ordered]@{ ts=$st.ts; action='project-autopilot-queued'; channel=$slug; item_id=[string]$id; reason=[string]$Reason })
  } catch {}
  try {
    Add-Message -From system -Text ("🧭 Project Autopilot: backlog пуст, поставил coordinator-задачу " + [string]$id + " для следующей главы проекта.") -Kind event | Out-Null
  } catch {}
  return [pscustomobject]@{ queued=$true; id=[string]$id; reason=[string]$Reason; pressure=$pressure }
}

function ConvertTo-ProjectAutopilotSlug {
  param([string]$Text)
  $v = ([string]$Text).Trim().ToLowerInvariant()
  $v = $v -replace '[^a-z0-9а-яё._-]+','-'
  $v = $v.Trim([char[]]@('-','_','.'))
  if ($v.Length -gt 80) { $v = $v.Substring(0,80).Trim([char[]]@('-','_','.')) }
  if ([string]::IsNullOrWhiteSpace($v)) {
    try {
      $sha = [System.Security.Cryptography.SHA1]::Create()
      $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
      $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
      $v = 'atom-' + $hash.Substring(0,10)
    } catch { $v = 'atom-' + ([guid]::NewGuid().ToString('N').Substring(0,10)) }
  }
  return $v
}

function Get-ProjectAutopilotTaskArrayFromMarker {
  param([string]$Block)
  $raw = ([string]$Block).Trim()
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  $raw = ($raw -replace '```json','' -replace '```','').Trim()
  $json = ''
  $arrMatch = [regex]::Match($raw, '(?s)\[.*\]')
  if ($arrMatch.Success) { $json = $arrMatch.Value }
  else {
    $objMatch = [regex]::Match($raw, '(?s)\{.*\}')
    if ($objMatch.Success) { $json = $objMatch.Value }
  }
  if ([string]::IsNullOrWhiteSpace($json)) { return @() }
  try {
    $parsed = $json | ConvertFrom-Json
    if ($parsed -is [array]) { return @($parsed) }
    if ($parsed -and $parsed.PSObject.Properties.Name -contains 'tasks') { return @($parsed.tasks) }
    return @($parsed)
  } catch {
    return @()
  }
}

function Get-ProjectAutopilotTaskStringField {
  param($Task, [string[]]$Names = @())
  foreach ($name in @($Names)) {
    try {
      $v = Get-BacklogPackObjectValue -Obj $Task -Name $name -Default $null
      if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
    } catch {}
  }
  return ''
}

function Get-ProjectAutopilotTaskStringArray {
  param($Task, [string[]]$Names = @())
  $out = New-Object 'System.Collections.Generic.List[string]'
  foreach ($name in @($Names)) {
    $raw = $null
    try { $raw = Get-BacklogPackObjectValue -Obj $Task -Name $name -Default $null } catch { $raw = $null }
    if ($null -eq $raw) { continue }
    foreach ($v in @($raw)) {
      $s = ([string]$v).Trim()
      if (-not [string]::IsNullOrWhiteSpace($s)) { [void]$out.Add($s) }
    }
    if ($out.Count -gt 0) { break }
  }
  return @($out.ToArray() | Sort-Object -Unique)
}

function ConvertTo-ProjectAutopilotPathArray {
  param($Values)
  return @(@($Values) |
    ForEach-Object { ([string]$_).Replace('\','/').Trim().ToLowerInvariant() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique)
}

function ConvertTo-ProjectAutopilotSlugArray {
  param($Values)
  return @(@($Values) |
    Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
    ForEach-Object { ConvertTo-ProjectAutopilotSlug ([string]$_) } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object -Unique)
}

function Get-ProjectAutopilotTaskRisk {
  param($Task)
  $risk = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('risk')
  if ([string]::IsNullOrWhiteSpace($risk)) {
    $risk = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('severity')
  }
  switch (([string]$risk).Trim().ToLowerInvariant()) {
    'critical' { return 'critical' }
    'high' { return 'high' }
    'warning' { return 'high' }
    'medium' { return 'normal' }
    'normal' { return 'normal' }
    'low' { return 'low' }
    'info' { return 'low' }
    default { return 'normal' }
  }
}

function Normalize-ProjectAutopilotAtomKind {
  param([string]$Kind)
  $normalized = ([string]$Kind).Trim().ToLowerInvariant()
  switch ($normalized) {
    'infra' { return 'infra' }
    'infrastructure' { return 'infra' }
    'feature' { return 'feature' }
    'consolidation' { return 'consolidation' }
    'planning' { return 'planning' }
    default { return 'feature' }
  }
}

function Normalize-ProjectAutopilotLane {
  param([string]$Lane)
  if ([string]::IsNullOrWhiteSpace($Lane)) { return '' }
  $normalized = $Lane.Trim().ToLowerInvariant() -replace '_','-' -replace '\s+','-'
  switch ($normalized) {
    'project' { return 'project' }
    'bridge' { return 'bridge' }
    'control-plane' { return 'control-plane' }
    default { return '' }
  }
}

function Test-ProjectAutopilotControlPlanePath {
  param([string]$Path)
  if (Get-Command Test-BridgeControlPlanePath -ErrorAction SilentlyContinue) {
    return [bool](Test-BridgeControlPlanePath -Path $Path)
  }
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $p = $Path.Replace('\','/').Trim().TrimStart('./').ToLowerInvariant()
  if ($p -match '(^|/)driver[^/]*\.ps1$') { return $true }
  if ($p -match '(^|/)driver/[^/]+\.ps1$') { return $true }
  if ($p -match '(^|/)(server|supervisor|watchdog)\.ps1$') { return $true }
  if ($p -match '(^|/)lib/backlog[^/]*\.ps1$') { return $true }
  if ($p -match '(^|/)lib/(parallel|circuit-breaker)\.ps1$') { return $true }
  return $false
}

function Test-ProjectAutopilotControlPlaneTouch {
  param([string[]]$Paths = @())
  foreach ($path in @($Paths)) {
    if (Test-ProjectAutopilotControlPlanePath -Path $path) { return $true }
  }
  return $false
}

function Get-ProjectAutopilotTaskLane {
  param(
    $Task,
    [string]$Channel = '',
    [string[]]$Files = @(),
    [string[]]$TouchSet = @()
  )
  $channelSlug = ([string]$Channel).Trim().ToLowerInvariant()
  if ($channelSlug -ne '' -and $channelSlug -ne 'main') { return 'project' }

  $explicitLane = Normalize-ProjectAutopilotLane (Get-ProjectAutopilotTaskStringField -Task $Task -Names @('lane'))
  if ($explicitLane -eq 'control-plane') { return 'control-plane' }
  if (Test-ProjectAutopilotControlPlaneTouch -Paths (@($Files) + @($TouchSet))) { return 'control-plane' }
  return 'bridge'
}

function Test-ProjectAutopilotTaskMetadata {
  param($Task)
  $missing = New-Object 'System.Collections.Generic.List[string]'
  $slug = ConvertTo-ProjectAutopilotSlug (Get-ProjectAutopilotTaskStringField -Task $Task -Names @('slug'))
  $title = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('title')
  $body = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('task')
  $files = @(ConvertTo-ProjectAutopilotPathArray (Get-BacklogPackObjectValue -Obj $Task -Name 'files' -Default @()))
  $acceptance = @(Get-ProjectAutopilotTaskStringArray -Task $Task -Names @('acceptance','acceptance_checks','criteria'))
  $checks = @(Get-ProjectAutopilotTaskStringArray -Task $Task -Names @('checks','verify','verification'))
  $risk = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('risk','severity')

  if ([string]::IsNullOrWhiteSpace($slug)) { [void]$missing.Add('slug') }
  if ([string]::IsNullOrWhiteSpace($title)) { [void]$missing.Add('title') }
  if ([string]::IsNullOrWhiteSpace($body)) { [void]$missing.Add('task') }
  if ($files.Count -eq 0) { [void]$missing.Add('files') }
  if ($acceptance.Count -eq 0) { [void]$missing.Add('acceptance') }
  if ($checks.Count -eq 0) { [void]$missing.Add('checks') }
  if ([string]::IsNullOrWhiteSpace($risk)) { [void]$missing.Add('risk') }

  return [pscustomobject]@{
    ok      = ($missing.Count -eq 0)
    missing = @($missing.ToArray())
  }
}

function Set-ProjectAutopilotIdeaMetadata {
  param([string]$Id, $Task, [string]$SourceTaskId = '')
  if ([string]::IsNullOrWhiteSpace($Id) -or -not $Task) { return $false }
  return (Invoke-BacklogLocked ({
    $items = @(Get-Backlog)
    $found = $false
    foreach ($i in $items) {
      if ([string]$i.id -ne $Id) { continue }
      $found = $true
      $slug = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $Task -Name 'slug' -Default (Get-BacklogPackObjectValue -Obj $Task -Name 'title' -Default $Id)))
      $title = [string](Get-BacklogPackObjectValue -Obj $Task -Name 'title' -Default $slug)
      $body = [string](Get-BacklogPackObjectValue -Obj $Task -Name 'task' -Default '')
      if ([string]::IsNullOrWhiteSpace($body)) { $body = $title }
      $files = @(ConvertTo-ProjectAutopilotPathArray (Get-BacklogPackObjectValue -Obj $Task -Name 'files' -Default @()))
      $deps = @(ConvertTo-ProjectAutopilotSlugArray (Get-BacklogPackObjectValue -Obj $Task -Name 'depends_on' -Default @()))
      $provides = @(ConvertTo-ProjectAutopilotSlugArray (Get-BacklogPackObjectValue -Obj $Task -Name 'provides' -Default @()))
      $consumes = @(ConvertTo-ProjectAutopilotSlugArray (Get-BacklogPackObjectValue -Obj $Task -Name 'consumes' -Default @()))
      $chapter = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('chapter','phase','area')
      $wave = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('wave','milestone')
      $kind = Normalize-ProjectAutopilotAtomKind (Get-ProjectAutopilotTaskStringField -Task $Task -Names @('kind','atom_kind'))
      $parallelGroup = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('parallel_group','workstream')
      $acceptance = @(Get-ProjectAutopilotTaskStringArray -Task $Task -Names @('acceptance','acceptance_checks','criteria'))
      $checks = @(Get-ProjectAutopilotTaskStringArray -Task $Task -Names @('checks','verify','verification'))
      $risk = Get-ProjectAutopilotTaskRisk -Task $Task
      $serialReason = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('serial_reason')
      $explicitTouch = @(ConvertTo-ProjectAutopilotPathArray (Get-ProjectAutopilotTaskStringArray -Task $Task -Names @('workpack_touch_set','touch_set')))
      $explicitGroup = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('workpack_conflict_group')
      $touchSet = if ($explicitTouch.Count -gt 0) { @($explicitTouch) } else { @($files) }
      $metadataChannel = [string](Get-BacklogPackObjectValue -Obj $i -Name 'project' -Default (Get-EffectiveChannel))
      $lane = Get-ProjectAutopilotTaskLane -Task $Task -Channel $metadataChannel -Files @($files) -TouchSet @($touchSet)
      $bridgeSelfAdmission = Get-BacklogPackObjectValue -Obj $Task -Name 'bridge_self_admission' -Default $null
      # Lever skipBuildOnDocsOnly (default OFF): a docs-only atom cannot break the compile, so drop the heavy
      # per-atom project build/typecheck from its checks. The full project build still runs unconditionally at
      # chapter-close acceptance (Invoke-ProjectAcceptance), so coverage is preserved. Conservative: only strips
      # when the flag is on AND every touched path is docs AND the touch-set is actually known.
      if ($checks.Count -gt 0) {
        try {
          if ((Get-ProjectAutopilotConfig).skipBuildOnDocsOnly) {
            $atomPaths = @(@($touchSet) + @($files) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($atomPaths.Count -gt 0 -and (Test-ProjectAutopilotAtomDocsOnly -Paths $atomPaths)) {
              $checks = @($checks | Where-Object { [string]$_ -notmatch '(?i)(gradlew|gradle\s|assemble|:build|npm(\.cmd)?\s+run\s+(build|typecheck|tsc)|\btsc\b)' })
            }
          }
        } catch {}
      }
      $i | Add-Member -NotePropertyName slug -NotePropertyValue $slug -Force
      $i | Add-Member -NotePropertyName title -NotePropertyValue $title -Force
      $i | Add-Member -NotePropertyName task -NotePropertyValue $body -Force
      $i | Add-Member -NotePropertyName autopilot_generated -NotePropertyValue $true -Force
      $i | Add-Member -NotePropertyName autopilot_source_task -NotePropertyValue ([string]$SourceTaskId) -Force
      $i | Add-Member -NotePropertyName files -NotePropertyValue ([object[]]@($files)) -Force
      $i | Add-Member -NotePropertyName depends_on -NotePropertyValue ([object[]]@($deps)) -Force
      if ($provides.Count -gt 0) { $i | Add-Member -NotePropertyName provides -NotePropertyValue ([object[]]@($provides)) -Force }
      if ($consumes.Count -gt 0) { $i | Add-Member -NotePropertyName consumes -NotePropertyValue ([object[]]@($consumes)) -Force }
      $i | Add-Member -NotePropertyName risk -NotePropertyValue $risk -Force
      $i | Add-Member -NotePropertyName kind -NotePropertyValue $kind -Force
      $i | Add-Member -NotePropertyName serial_reason -NotePropertyValue $serialReason -Force
      $i | Add-Member -NotePropertyName lane -NotePropertyValue $lane -Force
      if (-not [string]::IsNullOrWhiteSpace($chapter)) { $i | Add-Member -NotePropertyName chapter -NotePropertyValue $chapter -Force }
      if (-not [string]::IsNullOrWhiteSpace($wave)) { $i | Add-Member -NotePropertyName wave -NotePropertyValue $wave -Force }
      if (-not [string]::IsNullOrWhiteSpace($parallelGroup)) { $i | Add-Member -NotePropertyName parallel_group -NotePropertyValue $parallelGroup -Force }
      if ($acceptance.Count -gt 0) { $i | Add-Member -NotePropertyName acceptance_checks -NotePropertyValue @($acceptance) -Force }
      if ($checks.Count -gt 0) { $i | Add-Member -NotePropertyName verification_checks -NotePropertyValue @($checks) -Force }
      if ($acceptance.Count -gt 0) { $i | Add-Member -NotePropertyName acceptance -NotePropertyValue @($acceptance) -Force }
      if ($checks.Count -gt 0) { $i | Add-Member -NotePropertyName checks -NotePropertyValue @($checks) -Force }
      if ($bridgeSelfAdmission) { $i | Add-Member -NotePropertyName bridge_self_admission -NotePropertyValue $bridgeSelfAdmission -Force }
      if ($touchSet.Count -gt 0) {
        $group = if (-not [string]::IsNullOrWhiteSpace($explicitGroup)) { [string]$explicitGroup } else { 'file:' + [string]$touchSet[0] }
        $i | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue ([object[]]@($touchSet)) -Force
        $i | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue $group -Force
        $i | Add-Member -NotePropertyName workpack_lane_hint -NotePropertyValue ('serial:' + $group) -Force
      }
      $meta = [ordered]@{}
      if (-not [string]::IsNullOrWhiteSpace($chapter)) { $meta.chapter = $chapter }
      if (-not [string]::IsNullOrWhiteSpace($wave)) { $meta.wave = $wave }
      $meta.kind = $kind
      if (-not [string]::IsNullOrWhiteSpace($parallelGroup)) { $meta.parallel_group = $parallelGroup }
      $meta.lane = $lane
      $meta.depends_on = @($deps)
      if ($provides.Count -gt 0) { $meta.provides = @($provides) }
      if ($consumes.Count -gt 0) { $meta.consumes = @($consumes) }
      if ($files.Count -gt 0) { $meta.files = @($files) }
      if ($acceptance.Count -gt 0) { $meta.acceptance = @($acceptance) }
      if ($checks.Count -gt 0) { $meta.checks = @($checks) }
      $meta.risk = $risk
      $meta.serial_reason = $serialReason
      if ($bridgeSelfAdmission) { $meta.bridge_self_admission = $bridgeSelfAdmission }
      if ($meta.Count -gt 0) { $i | Add-Member -NotePropertyName autopilot_meta -NotePropertyValue ([pscustomobject]$meta) -Force }
      break
    }
    if ($found) { Save-Backlog $items }
    return $found
  }.GetNewClosure()))
}

function Get-ProjectAutopilotGlobalParallelismReport {
  # 2026-06-27 Phase-1 diffusion (shadow measurement): the "designer sees ALL atoms" view. Collects
  # every project-autopilot atom across all chapters from the live backlog and computes the would-be
  # global parallelism: longest TRUE dependency chain (critical path), independent-atom count, topo
  # wave count, max/avg atoms per wave, and how many files are shared by >1 atom (false-conflict risk).
  # READ-ONLY telemetry — never changes behavior. Tells us honestly whether the win is wide independent
  # parallelism (short chains) or needs contract-stubs (long chains), per project.
  param([string]$Channel = '')
  $atoms = @()
  foreach ($it in @(Get-Backlog)) {
    if ([string](Get-BacklogPackObjectValue -Obj $it -Name 'from' -Default '') -ne 'project-autopilot') { continue }
    $st = [string](Get-BacklogPackObjectValue -Obj $it -Name 'status' -Default '')
    if ($st -in @('rejected','auto-dropped')) { continue }
    $slug = [string](Get-BacklogPackObjectValue -Obj $it -Name 'slug' -Default (Get-BacklogPackObjectValue -Obj $it -Name 'id' -Default ''))
    if ([string]::IsNullOrWhiteSpace($slug)) { continue }
    $deps = @(@(Get-BacklogPackObjectValue -Obj $it -Name 'depends_on' -Default @()) | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $files = @(@(Get-BacklogPackObjectValue -Obj $it -Name 'files' -Default @()) | ForEach-Object { ([string]$_).Replace('\','/') } | Where-Object { $_ })
    $atoms += [pscustomobject]@{ slug = $slug; deps = $deps; files = $files }
  }
  $n = @($atoms).Count
  if ($n -eq 0) { return [pscustomobject]@{ atoms = 0 } }
  $slugSet = @{}; foreach ($a in $atoms) { $slugSet[[string]$a.slug] = $true }
  $level = @{}; foreach ($a in $atoms) { $level[[string]$a.slug] = 1 }
  for ($iter = 0; $iter -lt $n; $iter++) {
    $changed = $false
    foreach ($a in $atoms) {
      foreach ($d in @($a.deps)) {
        if ($slugSet.ContainsKey([string]$d)) {
          $cand = [int]$level[[string]$d] + 1
          if ($cand -gt [int]$level[[string]$a.slug]) { $level[[string]$a.slug] = $cand; $changed = $true }
        }
      }
    }
    if (-not $changed) { break }
  }
  $chain = 0; foreach ($v in $level.Values) { if ([int]$v -gt $chain) { $chain = [int]$v } }
  $independent = @($atoms | Where-Object { @(@($_.deps) | Where-Object { $slugSet.ContainsKey([string]$_) }).Count -eq 0 }).Count
  $byLevel = @{}; foreach ($a in $atoms) { $L = [int]$level[[string]$a.slug]; if (-not $byLevel.ContainsKey($L)) { $byLevel[$L] = 0 }; $byLevel[$L] = [int]$byLevel[$L] + 1 }
  $waves = @($byLevel.Keys).Count
  $maxPar = 0; foreach ($c in $byLevel.Values) { if ([int]$c -gt $maxPar) { $maxPar = [int]$c } }
  $fileOwners = @{}
  foreach ($a in $atoms) { foreach ($f in @($a.files)) { if (-not $fileOwners.ContainsKey([string]$f)) { $fileOwners[[string]$f] = 0 }; $fileOwners[[string]$f] = [int]$fileOwners[[string]$f] + 1 } }
  $sharedFiles = @(@($fileOwners.Values) | Where-Object { [int]$_ -gt 1 }).Count
  return [pscustomobject]@{
    atoms = $n
    independent = $independent
    longest_chain = $chain
    waves = $waves
    max_parallel = $maxPar
    avg_parallel = [math]::Round($n / [math]::Max(1, $waves), 1)
    shared_files = $sharedFiles
    total_files = @($fileOwners.Keys).Count
  }
}

function Repair-ProjectAutopilotAtomFileOwnership {
  # 2026-06-27 Phase-1 diffusion (clean per-atom file ownership): the coordinator sometimes emits a
  # batch where MANY atoms over-declare `files` — each atom lists the SAME multi-file set (e.g. every
  # audio-chapter atom lists all 7 audio files) even though each atom really creates ONE file. The
  # file-conflict guard then serializes atoms that are actually independent, killing parallelism.
  # Detect that signature (>=2 atoms sharing an identical multi-file set) and re-derive each atom's
  # true owned file by matching its slug to the declared files' basenames. CONSERVATIVE: only acts on
  # the shared-identical-set signature, and only when EXACTLY ONE declared file's basename clearly
  # matches the slug; otherwise leaves `files` untouched (never guesses, never drops a genuine file).
  param([object[]]$Tasks)
  $tArr = @($Tasks)
  if ($tArr.Count -lt 2) { return $tArr }
  $withSig = @(foreach ($t in $tArr) {
    $f = @(); try { $f = @(@($t.files) | ForEach-Object { ([string]$_).Replace('\','/').Trim() } | Where-Object { $_ }) } catch {}
    $sig = ''
    if ($f.Count -ge 2) { $sig = (@($f | Sort-Object) -join '|').ToLowerInvariant() }
    [pscustomobject]@{ task = $t; sig = $sig }
  })
  $repaired = 0
  foreach ($grp in @($withSig | Where-Object { $_.sig -ne '' } | Group-Object -Property sig)) {
    if ([int]$grp.Count -lt 2) { continue }   # only the over-declaration signature: >=2 atoms, identical multi-file set
    foreach ($w in @($grp.Group)) {
      $t = $w.task
      $slug = ''
      try { $slug = (([string]$t.slug).ToLowerInvariant() -replace '[^a-z0-9]','') } catch {}
      if ([string]::IsNullOrWhiteSpace($slug)) { continue }
      $files = @(@($t.files) | ForEach-Object { [string]$_ })
      $hits = @()
      foreach ($file in $files) {
        $base = ''
        try { $base = ([System.IO.Path]::GetFileNameWithoutExtension($file)).ToLowerInvariant() -replace '[^a-z0-9]','' } catch {}
        if (-not [string]::IsNullOrWhiteSpace($base) -and $slug.Contains($base)) { $hits += $file }
      }
      if (@($hits).Count -eq 1) {
        $t | Add-Member -NotePropertyName files -NotePropertyValue @($hits) -Force
        $t | Add-Member -NotePropertyName files_ownership_repaired -NotePropertyValue $true -Force
        $repaired++
      }
    }
  }
  # 2026-06-28 cleanFileOwnership (flag-gated, default OFF): the identical-set signature above misses the
  # more common PARTIAL-overlap god-file case — many atoms each list a shared "god file" PLUS their own file
  # (e.g. all list MainUiState.kt + their own screen). That is not an identical set, so the loop above never
  # fires, yet the shared file still serializes the whole batch. When enabled, drop a shared god-file from an
  # atom's `files` IF the atom keeps its own slug-matched file and that god-file is owned by >=2 OTHER atoms.
  try {
    if ((Get-ProjectAutopilotConfig).cleanFileOwnership) {
      $ownerCount = @{}
      foreach ($t in $tArr) {
        $seen = @{}
        foreach ($file in @(@($t.files) | ForEach-Object { ([string]$_).Replace('\','/').Trim().ToLowerInvariant() } | Where-Object { $_ })) {
          if (-not $seen.ContainsKey($file)) { $seen[$file] = $true; if ($ownerCount.ContainsKey($file)) { $ownerCount[$file]++ } else { $ownerCount[$file] = 1 } }
        }
      }
      foreach ($t in $tArr) {
        $files = @(@($t.files) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($files.Count -lt 2) { continue }
        $slug = ''
        try { $slug = (([string]$t.slug).ToLowerInvariant() -replace '[^a-z0-9]','') } catch {}
        if ([string]::IsNullOrWhiteSpace($slug)) { continue }
        $owned = @()
        foreach ($file in $files) {
          $base = ''
          try { $base = ([System.IO.Path]::GetFileNameWithoutExtension($file)).ToLowerInvariant() -replace '[^a-z0-9]','' } catch {}
          if (-not [string]::IsNullOrWhiteSpace($base) -and $slug.Contains($base)) { $owned += $file }
        }
        if (@($owned).Count -lt 1) { continue }   # can't identify the atom's own file -> leave untouched
        $kept = @()
        foreach ($file in $files) {
          $norm = ($file.Replace('\','/').Trim().ToLowerInvariant())
          $others = 0; if ($ownerCount.ContainsKey($norm)) { $others = [int]$ownerCount[$norm] - 1 }
          if (($owned -contains $file) -or ($others -lt 2)) { $kept += $file }
        }
        $kept = @($kept | Select-Object -Unique)
        if (@($kept).Count -ge 1 -and @($kept).Count -lt $files.Count) {
          $t | Add-Member -NotePropertyName files -NotePropertyValue @($kept) -Force
          $t | Add-Member -NotePropertyName files_ownership_repaired -NotePropertyValue $true -Force
          $repaired++
        }
      }
    }
  } catch {}
  if ($repaired -gt 0) {
    try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='project-autopilot-file-ownership-repaired'; repaired=$repaired }) } catch {}
  }
  return $tArr
}

# ── Background decompose-ahead (concurrent planning) ────────────────────────────
# Problem this solves: the project coordinator (decomposition) and the executor
# share ONE channel slot. A foreground coordinator turn blocks execution for ~15 min
# every time the next chapter needs planning, so already-planned atoms sit idle. The
# fix is to run the NEXT chapter's decomposition OUT-OF-BAND in a detached worker
# (tools/decompose-worker.ps1) while the main loop keeps claiming + executing the
# current chapter's atoms. Flag-gated by projectAutopilot.decomposeAheadLimit
# (default 1 = OFF; the foreground path is unchanged when the flag is at its default).

function Get-BackgroundDecomposeLockPath {
  param([string]$Channel)
  $chDir = Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel
  return (Join-Path $chDir '.decompose-worker.lock')
}

function Test-BackgroundDecomposeRunning {
  param([string]$Channel)
  $lock = Get-BackgroundDecomposeLockPath -Channel $Channel
  if (-not (Test-Path -LiteralPath $lock)) { return $false }
  try {
    $data = ((Get-Content -LiteralPath $lock -Raw -Encoding UTF8) | Out-String).Trim()
    $parts = @($data -split '\|')
    $lpid = 0; $lticks = [long]0
    if ($parts.Count -gt 0) { [int]::TryParse([string]$parts[0], [ref]$lpid) | Out-Null }
    if ($parts.Count -gt 1) { [long]::TryParse([string]$parts[1], [ref]$lticks) | Out-Null }
    if ($lpid -gt 0) {
      $p = Get-Process -Id $lpid -ErrorAction SilentlyContinue
      if ($p) {
        # Liveness is the PRIMARY signal (problem-hunt defect #3): a worker's Add phase can run many
        # minutes, so we must NOT declare a still-running worker stale on age alone. Verify the SAME
        # process via StartTime ticks (guards against pid recycling), and use only a 45-min backstop
        # ceiling (> 25-min codex cap + bounded Add) to clear a genuinely wedged or dead-then-recycled pid.
        $sameProc = $true
        if ($lticks -gt 0) { try { $sameProc = ($p.StartTime.Ticks -eq $lticks) } catch { $sameProc = $true } }
        if ($sameProc) {
          $ageMin = 0
          try { $ageMin = ((Get-Date) - (Get-Item -LiteralPath $lock).LastWriteTime).TotalMinutes } catch {}
          if ($ageMin -lt 45) { return $true }
        }
      }
    }
  } catch {}
  # stale: dead pid, recycled pid (start-ticks mismatch), unreadable, or wedged beyond 45 min -> clear it
  try { Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue } catch {}
  return $false
}

function Start-BackgroundProjectDecompose {
  param([string]$Channel)
  if ([string]::IsNullOrWhiteSpace($Channel)) { return [pscustomobject]@{ started=$false; reason='no-channel' } }
  if (Test-BackgroundDecomposeRunning -Channel $Channel) { return [pscustomobject]@{ started=$false; reason='already-running' } }
  $root = Get-BridgeRoot
  $worker = Join-Path $root 'tools\decompose-worker.ps1'
  if (-not (Test-Path -LiteralPath $worker)) { return [pscustomobject]@{ started=$false; reason='worker-missing' } }
  try {
    $p = Start-Process -FilePath 'powershell.exe' `
      -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$worker,'-Channel',$Channel) `
      -WindowStyle Hidden -PassThru
    $lock = Get-BackgroundDecomposeLockPath -Channel $Channel
    $lockDir = Split-Path -Parent $lock
    if (-not (Test-Path -LiteralPath $lockDir)) { New-Item -ItemType Directory -Force -Path $lockDir | Out-Null }
    # Record pid|startTicks|spawn-ts: startTicks lets Test-BackgroundDecomposeRunning verify it is the
    # SAME process (not a recycled pid) before treating the lock as a live worker (defect #3).
    $startTicks = [long]0
    try { $startTicks = (Get-Process -Id $p.Id -ErrorAction Stop).StartTime.Ticks } catch { $startTicks = 0 }
    Set-Content -LiteralPath $lock -Value ("{0}|{1}|{2}" -f $p.Id, $startTicks, ((Get-Date).ToUniversalTime().ToString('o'))) -Encoding ASCII
    return [pscustomobject]@{ started=$true; pid=$p.Id }
  } catch {
    return [pscustomobject]@{ started=$false; reason=('spawn-error: ' + $_.Exception.Message) }
  }
}

function Get-ProjectAutopilotPlanChapterCount {
  # Single tolerant parser for PROJECT_PLAN.md chapter headings (problem-hunt defect #5: the count regex
  # was brittle '(?m)^##\s+\S+\s+(\d+)...' and triplicated across 3 sites). Accepts '## Chapter 7 - X',
  # '## Phase 7: X', '## Глава 7 — X', '## 7. X', '## 7) X' with -/:/. separators and en/em dashes.
  # Returns the count of DISTINCT chapter ordinals.
  param([string]$ProjectRoot)
  $ords = New-Object System.Collections.Generic.HashSet[int]
  try {
    $planFile = Join-Path $ProjectRoot 'PROJECT_PLAN.md'
    if (-not (Test-Path -LiteralPath $planFile -PathType Leaf)) { return 0 }
    $txt = [System.IO.File]::ReadAllText($planFile, [System.Text.Encoding]::UTF8)
    foreach ($line in ($txt -split "`r?`n")) {
      $m = [regex]::Match($line, '^\s{0,3}#{2,3}\s+(?:[^\d\r\n]*?\s)?(\d{1,3})\s*[\.\):—–\-]\s', 'IgnoreCase')
      if ($m.Success) {
        $ord = 0; [int]::TryParse($m.Groups[1].Value, [ref]$ord) | Out-Null
        if ($ord -gt 0) { [void]$ords.Add($ord) }
      }
    }
  } catch {}
  return $ords.Count
}

function Get-ProjectAutopilotChapterKey {
  # Canonicalize a free-text 'chapter' field to a stable key (problem-hunt defect #1: counting raw strings
  # let 'Chapter 4 - X' and a clean slug / mojibake variant inflate the decomposed count and silently skip
  # a chapter). Prefer the PLAN ORDINAL: a number near the start (optionally after Chapter/Phase/Глава/etc.)
  # -> 'n<N>', so numbered/mojibake/title variants of the same chapter collapse. Otherwise a stable ascii
  # slug. (Legacy atoms that used a bare English slug for a Russian-titled chapter can't be collapsed to the
  # numbered form without re-stamping; the coordinator prompt now requires a leading ordinal going forward.)
  param([string]$Chapter)
  $c = ([string]$Chapter).Trim()
  if ([string]::IsNullOrWhiteSpace($c)) { return '' }
  $m = [regex]::Match($c, '^(?:\s*(?:chapter|phase|глава|section|part|часть|глава)\s*)?#?\s*(\d{1,3})\b', 'IgnoreCase')
  if ($m.Success) { return ('n' + [int]$m.Groups[1].Value) }
  $s = $c.ToLowerInvariant()
  $s = ($s -replace '[^a-z0-9]+', '-').Trim('-')
  if ([string]::IsNullOrWhiteSpace($s)) { return $c.ToLowerInvariant() }
  return $s
}

function Test-ShouldBackgroundDecompose {
  param([string]$Channel)
  $result = [pscustomobject]@{
    should = $false; reason = ''; limit = 1; runnable = 0
    chapters_in_flight = 0; decomposed = 0; total_chapters = 0
  }
  try {
    $cfg = Get-ProjectAutopilotConfig
    $limit = 1
    try { $limit = [int]$cfg.decomposeAheadLimit } catch { $limit = 1 }
    if ($limit -lt 1) { $limit = 1 }
    $result.limit = $limit
    if ($limit -le 1) { $result.reason = 'flag-off'; return $result }

    # Must be a bound project channel.
    $projectRoot = ''
    try {
      $binding = Get-ChannelProjectBinding -Slug $Channel
      if ($binding -and [bool](Get-BacklogPackObjectValue -Obj $binding -Name 'ok' -Default $false)) {
        $projectRoot = [string](Get-BacklogPackObjectValue -Obj $binding -Name 'project_root' -Default '')
      }
    } catch {}
    if ([string]::IsNullOrWhiteSpace($projectRoot)) { $result.reason = 'not-project-channel'; return $result }

    # Walk this channel's project-autopilot atoms once: decomposed chapters + in-flight + runnable.
    $decomposedSet = New-Object System.Collections.Generic.HashSet[string]
    $inFlightSet   = New-Object System.Collections.Generic.HashSet[string]
    $runnable = 0
    $terminal = @('done','failed','rejected','dropped','archived','duplicate','cancelled','canceled')
    try {
      foreach ($bi in @(Get-Backlog)) {
        if ([string](Get-BacklogPackObjectValue -Obj $bi -Name 'from' -Default '') -ne 'project-autopilot') { continue }
        $chp = ([string](Get-BacklogPackObjectValue -Obj $bi -Name 'chapter' -Default '')).Trim()
        $chk = Get-ProjectAutopilotChapterKey -Chapter $chp
        $st  = ([string](Get-BacklogPackObjectValue -Obj $bi -Name 'status' -Default '')).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($chk)) { [void]$decomposedSet.Add($chk) }
        if ($terminal -notcontains $st) {
          if (-not [string]::IsNullOrWhiteSpace($chk)) { [void]$inFlightSet.Add($chk) }
          if ($st -eq 'approved' -or $st -eq 'working') { $runnable++ }
        }
      }
    } catch {}
    $result.decomposed = $decomposedSet.Count
    $result.chapters_in_flight = $inFlightSet.Count
    $result.runnable = $runnable

    # Decompose-ahead only makes sense while THIS channel is actively executing (has runnable work). A
    # dormant channel (runnable=0) returns here SILENTLY — this also keeps the plan-format warning below
    # from firing every idle tick for every idle project channel (the warning is reached only by an
    # actively-building channel, where an unparseable plan is a real, worth-knowing problem).
    # 2026-06-28 (upfront-speed #2): cold-start bootstrap carve-out. Decompose-ahead normally only fires
    # while the channel has runnable work to overlap. BUT once the foreground coordinator is retired
    # (decomposeAheadLimit>1, see Start-ProjectAutopilotIfNeeded), the background worker is the SOLE
    # decomposer, so it MUST also fire at true cold start or chapter 1 never gets planned (deadlock). Carve
    # out ONLY the genuine cold start -- nothing decomposed yet (decomposedSet empty). A dormant/finished
    # channel (atoms exist, none runnable) still returns silently as before, so idle channels don't spin up
    # workers. The chapter-count / in-flight-limit / all-decomposed / singleton gates below still apply, so a
    # no-plan or already-running channel still returns safely without spawning.
    if ($runnable -le 0 -and $decomposedSet.Count -gt 0) { $result.reason = 'no-runnable-atoms'; return $result }

    # Total approved chapters from the durable plan (centralized tolerant parser, defect #5).
    $totalCh = Get-ProjectAutopilotPlanChapterCount -ProjectRoot $projectRoot
    $result.total_chapters = $totalCh
    if ($totalCh -le 0) {
      # Reached only by an actively-executing channel whose PROJECT_PLAN.md exists but parsed to 0 chapters
      # (a real header-format problem). Throttled to once per 6h per channel via a marker FILE (a script-
      # scoped variable does not survive the driver's per-iteration module reloads, which caused log spam).
      try {
        if (Test-Path -LiteralPath (Join-Path $projectRoot 'PROJECT_PLAN.md') -PathType Leaf) {
          $warnMark = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel) '.bg-noplan-warned'
          $warnDue = $true
          try { if ((Test-Path -LiteralPath $warnMark) -and (((Get-Date) - (Get-Item -LiteralPath $warnMark).LastWriteTime).TotalHours -lt 6)) { $warnDue = $false } } catch {}
          if ($warnDue) {
            try { Set-Content -LiteralPath $warnMark -Value ((Get-Date).ToUniversalTime().ToString('o')) -Encoding ASCII } catch {}
            Add-Content -LiteralPath (Join-Path (Get-BridgeRoot) 'driver.out.log') -Value ((Get-Date).ToString('s') + " background-decompose: decomposeAheadLimit=$limit but PROJECT_PLAN.md yielded 0 chapters (unrecognized '## N' header format?) channel=$Channel root=$projectRoot") -Encoding UTF8
          }
        }
      } catch {}
      $result.reason = 'no-plan-chapters'; return $result
    }

    # Gate the decision:
    #  - bound how many chapters may be pending at once.
    if ($inFlightSet.Count -ge $limit) { $result.reason = 'in-flight-at-limit'; return $result }
    #  - there must still be an undecomposed chapter to plan.
    if ($decomposedSet.Count -ge $totalCh) { $result.reason = 'all-chapters-decomposed'; return $result }
    #  - singleton.
    if (Test-BackgroundDecomposeRunning -Channel $Channel) { $result.reason = 'already-running'; return $result }

    $result.should = $true
    $result.reason = 'ok'
    return $result
  } catch {
    $result.reason = ('error: ' + $_.Exception.Message)
    return $result
  }
}

function Invoke-BackgroundDecomposeAheadIfNeeded {
  param([string]$Channel)
  $decision = Test-ShouldBackgroundDecompose -Channel $Channel
  if (-not $decision.should) { return $decision }
  $spawn = Start-BackgroundProjectDecompose -Channel $Channel
  if ($spawn.started) {
    try {
      Add-Message -From system -Text ("Background planner: pre-decomposing the next chapter for '" + $Channel + "' (in-flight " + [int]$decision.chapters_in_flight + "/" + [int]$decision.limit + ", decomposed " + [int]$decision.decomposed + "/" + [int]$decision.total_chapters + ") while execution continues.") -Kind event | Out-Null
    } catch {}
    try {
      Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='background-decompose-spawned'; channel=$Channel; pid=$spawn.pid; in_flight=[int]$decision.chapters_in_flight; limit=[int]$decision.limit; decomposed=[int]$decision.decomposed; total=[int]$decision.total_chapters }) | Out-Null
    } catch {}
  }
  $decision | Add-Member -NotePropertyName spawn -NotePropertyValue $spawn -Force
  return $decision
}

function Add-ProjectBacklogFromMarker {
  param(
    [string]$Block,
    [string]$Channel = '',
    [string]$Source = 'agent',
    [string]$SourceTaskId = '',
    [int]$MaxTasks = 12
  )
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-ProjectAutopilotSlug }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }
  $isBridgeSelfBacklog = (([string]$Channel).Trim().ToLowerInvariant() -eq 'main')
  $max = [Math]::Max(1, [Math]::Min(50, [int]$MaxTasks))
  $tasks = @(Get-ProjectAutopilotTaskArrayFromMarker -Block $Block | Select-Object -First $max)
  if ($tasks.Count -eq 0) { return [pscustomobject]@{ created=0; skipped=0; errors=@('no valid JSON tasks found'); ids=@() } }
  # 2026-06-27 Phase-1 diffusion: clean over-declared per-atom file ownership BEFORE the diffusion gate
  # and backlog write, so independent atoms are not falsely serialized by a shared (over-declared) touch set.
  try { $tasks = @(Repair-ProjectAutopilotAtomFileOwnership -Tasks $tasks) } catch {}

  $diffusionMode = 'off'
  $diffusionGate = $null
  $freezeManifest = $null
  try {
    $cfg = Get-ProjectAutopilotConfig
    $diffusionMode = ([string]$cfg.diffusionMode).Trim().ToLowerInvariant()
    if ($diffusionMode -in @('shadow','diffusion')) {
      $projectRoot = ''
      try {
        if (Get-Command Get-ChannelProjectBinding -ErrorAction SilentlyContinue) {
          $binding = Get-ChannelProjectBinding -Slug $Channel
          if ($binding -and [bool](Get-BacklogPackObjectValue -Obj $binding -Name 'ok' -Default $false)) {
            $projectRoot = [string](Get-BacklogPackObjectValue -Obj $binding -Name 'project_root' -Default '')
          }
        }
      } catch {}
      if ([string]::IsNullOrWhiteSpace($projectRoot) -and (([string]$Channel).Trim().ToLowerInvariant() -eq 'main')) {
        try { $projectRoot = Get-BridgeRoot } catch {}
      }
      $contracts = @(Get-ProjectAutopilotInterfaceContracts -ProjectRoot $projectRoot -Channel $Channel)
      # $synthesizedContracts survives the post-freeze DISK RE-READ below so we can re-merge the in-memory
      # synthesized entries (the reader only returns on-disk contracts, and cold start has none on disk).
      $synthesizedContracts = @()
      # Step 8 (cold-start reliability floor): MERGE in-memory synthesized contracts. On cold start the
      # coordinator emits atoms carrying provides/consumes but NO contract files on disk, so the reader above
      # returns EMPTY -> the count==0 guard below would skip diffusion and the whole project builds serially.
      # New-ProjectAutopilotSynthesizedContracts is PURE (no disk write, no timestamp): it synthesizes a
      # minimal freezable contract for every id that has BOTH a provider atom and a consumer atom, so the
      # count==0 guard only fires when there is GENUINELY no cross-atom interface (correct serial). REAL disk
      # contracts always win: we only add a synthesized entry whose id is not already present. Guarded by
      # Get-Command + try/catch so a fault falls through to the serial default and never throws the tick.
      try {
        if (Get-Command New-ProjectAutopilotSynthesizedContracts -ErrorAction SilentlyContinue) {
          $syn = New-ProjectAutopilotSynthesizedContracts -Tasks $tasks -ExistingContracts $contracts
          $existingContractIds = New-Object 'System.Collections.Generic.HashSet[string]'
          foreach ($c in @($contracts)) {
            $cid = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $c -Name 'id' -Default ''))
            if (-not [string]::IsNullOrWhiteSpace($cid)) { [void]$existingContractIds.Add($cid) }
          }
          $mergedSynthIds = New-Object 'System.Collections.Generic.List[string]'
          $mergedContracts = New-Object 'System.Collections.Generic.List[object]'
          foreach ($c in @($contracts)) { $mergedContracts.Add($c) | Out-Null }
          foreach ($sc in @($syn.synthesized)) {
            $sid = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $sc -Name 'id' -Default ''))
            if ([string]::IsNullOrWhiteSpace($sid) -or $existingContractIds.Contains($sid)) { continue }
            [void]$existingContractIds.Add($sid)
            $mergedContracts.Add($sc) | Out-Null
            $mergedSynthIds.Add($sid) | Out-Null
          }
          $contracts = @($mergedContracts.ToArray())
          $synthesizedContracts = @($syn.synthesized)
          try {
            Write-BacklogJsonLine ([ordered]@{
              ts = (Get-Date).ToUniversalTime().ToString('o')
              action = 'project-autopilot-diffusion-contract-synthesis'
              channel = [string]$Channel
              mode = $diffusionMode
              synthesized_ids = @($mergedSynthIds.ToArray())
              skipped = @($syn.skipped | ForEach-Object { [ordered]@{ id = [string]$_.id; reason = [string]$_.reason } })
            })
          } catch {}
        }
      } catch {}
      # Ch1 shadow planner (measurement only): project ALL atoms into execution waves -- hard-only (today's
      # behaviour) vs contract-soft (the diffusion projection) -- and emit PROJECT_WAVE_SCHEDULE.json (into
      # the channel runtime dir, NOT the project worktree) + a telemetry marker. Pure in-memory graph work
      # on $tasks; never throws; changes NO execution (the collapse/dispatch logic below is untouched).
      try {
        if (Get-Command Invoke-ProjectAutopilotShadowPlanner -ErrorAction SilentlyContinue) {
          $planOutDir = Join-Path (Join-Path (Get-BridgeRoot) 'channels') ([string]$Channel)
          $planSummary = Invoke-ProjectAutopilotShadowPlanner -Tasks $tasks -Contracts $contracts -OutputDir $planOutDir -Channel $Channel
          if ($planSummary) {
            Write-BacklogJsonLine ([ordered]@{
              ts = (Get-Date).ToUniversalTime().ToString('o')
              action = 'project-autopilot-wave-schedule'
              channel = [string]$Channel
              mode = $diffusionMode
              summary = $planSummary
            })
          }
        }
      } catch {}
      # Ch0 hang fix: the freeze manifest + diffusion gate only do meaningful work when interface contracts
      # exist. With zero contracts the gate can never be green (no contract coverage), so running the heavy
      # freeze/gate machinery on the foreground driver tick just burns I/O for nothing -- this was the
      # ~1.5-min heartbeat freeze. Skip straight to the collapse path (shadow/diffusion already falls back
      # to the serial one-chapter default when the gate is not green).
      if ($contracts.Count -eq 0) {
        Write-BacklogJsonLine ([ordered]@{
          ts = (Get-Date).ToUniversalTime().ToString('o')
          action = 'project-autopilot-diffusion-skip'
          channel = [string]$Channel
          mode = $diffusionMode
          reason = 'no-interface-contracts'
        })
      } else {
        $freezeManifest = New-ProjectAutopilotContractFreezeManifest -Tasks $tasks -Contracts $contracts -ProjectRoot $projectRoot -Channel $Channel -Mode $diffusionMode -WriteLocks:($true)
        if ($freezeManifest) {
          Write-BacklogJsonLine ([ordered]@{
            ts = (Get-Date).ToUniversalTime().ToString('o')
            action = 'project-autopilot-diffusion-freeze-manifest'
            channel = [string]$Channel
            mode = $diffusionMode
            manifest = $freezeManifest
          })
          $contracts = @(Get-ProjectAutopilotInterfaceContracts -ProjectRoot $projectRoot -Channel $Channel)
          # Step 8 (disk re-read fix): the reader above returns ONLY on-disk contracts and DISCARDS the
          # in-memory synthesized ones, so on cold start $contracts would drop back to empty right before the
          # gate. RE-MERGE the synthesized entries (real disk contracts still win by id), then upgrade each
          # contract whose freeze manifest entry has lock_written==true to stable=$true: disk contracts get
          # stable from the re-read as before; synthesized contracts get it ONLY from the freeze manifest we
          # just wrote (their in-memory entries carry stable=$false). Without this the gate would redden on
          # 'contract-unstable' even after a successful freeze.
          try {
            $reIds = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($c in @($contracts)) {
              $rid = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $c -Name 'id' -Default ''))
              if (-not [string]::IsNullOrWhiteSpace($rid)) { [void]$reIds.Add($rid) }
            }
            $reMerged = New-Object 'System.Collections.Generic.List[object]'
            foreach ($c in @($contracts)) { $reMerged.Add($c) | Out-Null }
            foreach ($sc in @($synthesizedContracts)) {
              $sid = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $sc -Name 'id' -Default ''))
              if ([string]::IsNullOrWhiteSpace($sid) -or $reIds.Contains($sid)) { continue }
              [void]$reIds.Add($sid)
              $reMerged.Add($sc) | Out-Null
            }
            $contracts = @($reMerged.ToArray())
            $lockedIds = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($fmEntry in @($freezeManifest.contracts)) {
              if ([bool](Get-BacklogPackObjectValue -Obj $fmEntry -Name 'lock_written' -Default $false)) {
                $lid = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $fmEntry -Name 'id' -Default ''))
                if (-not [string]::IsNullOrWhiteSpace($lid)) { [void]$lockedIds.Add($lid) }
              }
            }
            foreach ($c in @($contracts)) {
              $cid = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $c -Name 'id' -Default ''))
              # AUTHORITATIVE: THIS tick's freeze is the sole source of stability at the gate. Force stable to
              # match the freeze manifest -- both SET (synthesized/frozen now) AND CLEAR (a disk contract that
              # arrived stable=true from a STALE prior-tick lock whose provider/consumer atoms are NOT in this
              # batch, so it was NOT re-frozen now). Without the CLEAR the gate could green on a contract this
              # batch never froze while shaping (keyed on freeze_ready+lock_written) ignores it -- a dishonest
              # gate/shaping divergence. Cost: a legitimately-frozen prior-decompose contract whose provider is
              # already built (not in this batch) also degrades that batch to serial -- SAFE (never worse than
              # serial), and cold start (all-synthesized, no disk contracts) is unaffected.
              $c | Add-Member -Force -NotePropertyName stable -NotePropertyValue ([bool]$lockedIds.Contains($cid))
            }
          } catch {}
        }
        # Step 9 (option B): the raw coordinator batch has NO consolidation/stitch atom, so the gate's
        # stitching-tests-present check reddens ('stitching-tests-missing') even with good frozen contracts.
        # New-ProjectAutopilotShapedBatch (invoked immediately below on a GREEN diffusion gate) DETERMINISTICALLY
        # appends exactly such a stitch atom right after this gate call, so assert StitchingTestsPresent here.
        $diffusionGate = Test-ProjectAutopilotDiffusionGate -Tasks $tasks -Contracts $contracts -ProjectRoot $projectRoot -OptIn:($true) -StitchingTestsPresent $true -MinIndependentAtoms ([int]$cfg.diffusionMinIndependentAtoms) -MaxWaveSize ([int]$cfg.diffusionMaxWaveSize)
        Write-BacklogJsonLine ([ordered]@{
          ts = (Get-Date).ToUniversalTime().ToString('o')
          action = 'project-autopilot-diffusion-gate'
          channel = [string]$Channel
          mode = $diffusionMode
          enabled = [bool]$diffusionGate.enabled
          fallback = ($diffusionMode -eq 'diffusion' -and -not [bool]$diffusionGate.enabled)
          reasons = @($diffusionGate.reasons)
          atoms = [int]$diffusionGate.wave_size
          independent_atoms = [int]$diffusionGate.independent_atom_count
          freeze_manifest_id = if ($freezeManifest) { [string]$freezeManifest.manifest_id } else { '' }
        })
      }
    }
  } catch {}
  # 2026-06-30: a non-off mode that emits a CROSS-CHAPTER batch must only let it through when it can
  # actually be DISPATCHED; otherwise collapse to the EARLIEST chapter (proven serial one-chapter default)
  # so it never strands atoms or starves the bridge lock. Two cases:
  #  - shadow/diffusion: the FULL diffusion executor (P2-P5: contract stubs + stitching) is NOT built, so a
  #    cross-chapter batch always collapses (the heavy gate is effectively never green here yet). This also
  #    closes the original hang: shadow used to let the full ~24-atom batch through, and writing it (one
  #    slow lock + full-file-verify Add-Idea per atom on a large/OneDrive backlog) held the global mutex
  #    long enough that the driver heartbeat timed out and the channel froze ~90s after start.
  #  - wide: the executor ALREADY EXISTS -- Resolve-BacklogWorkpackFrontier runs INDEPENDENT atoms across
  #    chapters in parallel and serializes DEPENDENT ones via depends_on, no chapter gating. So wide
  #    collapses ONLY when its LIGHT gate is red (cyclic depends_on, a same-wave file conflict, or too few
  #    independent atoms); a GREEN wide gate lets the whole cross-chapter batch through to the write loop.
  $collapseReason = ''
  if ($diffusionMode -eq 'shadow') {
    # shadow is measure-only and NEVER changes execution: always collapse to the proven serial one-chapter
    # default (the wave-schedule telemetry above already recorded the projected diffusion gain).
    $collapseReason = 'diffusion-shadow-measure-only'
  } elseif ($diffusionMode -eq 'diffusion') {
    if ($diffusionGate -and [bool]$diffusionGate.enabled) {
      # Ch3: GREEN diffusion gate -> RESHAPE the batch (additive emit-shaping) so contract-CONSUMERS run in
      # PARALLEL against frozen stubs: a freeze-marker atom per stable contract (writes the stub, independent
      # -> wave 1) + each consumer's depends_on rewritten from the real provider to the marker + a stitch
      # consolidation atom. The existing hard-depends_on frontier dispatches these without any scheduler
      # change; the fast marker unblocks the consumer while the slow provider is still building. If shaping is
      # unavailable or produces nothing, fall back to the serial one-chapter default (never strand the batch).
      $shaped = $null
      try { if (Get-Command New-ProjectAutopilotShapedBatch -ErrorAction SilentlyContinue) { $shaped = New-ProjectAutopilotShapedBatch -Tasks $tasks -Contracts $contracts -FreezeManifest $freezeManifest -ProjectRoot $projectRoot -Channel $Channel } } catch { $shaped = $null }
      if ($shaped -and [bool]$shaped.applied -and ([int]$shaped.markers_added -gt 0) -and (@($shaped.tasks).Count -ge $tasks.Count)) {
        $tasks = @($shaped.tasks)
        # A1 (drift-gate manifest): persist the frozen interface + provider file per stitched contract, keyed
        # on the stitch atom's slug, so the driver DONE-gate can deterministically re-verify the real provider
        # when the stitch completes (the false-green guard). Channel-local, additive, guarded; never blocks ingest.
        try {
          if (Get-Command Write-ProjectAutopilotStitchManifest -ErrorAction SilentlyContinue) {
            $stitchSlugForManifest = ''
            foreach ($stTask in @($shaped.tasks)) {
              if ([string](Get-BacklogPackObjectValue -Obj $stTask -Name 'kind' -Default '') -eq 'consolidation') { $stitchSlugForManifest = [string](Get-BacklogPackObjectValue -Obj $stTask -Name 'slug' -Default ''); break }
            }
            if (-not [string]::IsNullOrWhiteSpace($stitchSlugForManifest)) {
              $stitchManifestPath = Write-ProjectAutopilotStitchManifest -StitchSlug $stitchSlugForManifest -Contracts $contracts -FreezeManifest $freezeManifest -ProjectRoot $projectRoot -Channel $Channel
              Write-BacklogJsonLine ([ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); action = 'project-autopilot-diffusion-stitch-manifest'; channel = [string]$Channel; stitch_slug = $stitchSlugForManifest; manifest_path = [string]$stitchManifestPath })
            }
          }
        } catch {}
        try {
          Write-BacklogJsonLine ([ordered]@{
            ts = (Get-Date).ToUniversalTime().ToString('o')
            action = 'project-autopilot-diffusion-shaped'
            channel = [string]$Channel
            mode = $diffusionMode
            markers_added = [int]$shaped.markers_added
            consumers_rewritten = [int]$shaped.consumers_rewritten
            stitch_added = [int]$shaped.stitch_added
            stub_paths = @($shaped.stub_paths)
            atoms = [int]@($shaped.tasks).Count
          })
        } catch {}
      } else {
        $collapseReason = 'diffusion-shaping-unavailable'
      }
    } else {
      $collapseReason = 'diffusion-gate-red'
    }
  } elseif ($diffusionMode -eq 'wide') {
    $wideGate = $null
    $wideK = 2; try { $wideK = [int]$cfg.diffusionMinIndependentAtoms } catch {}
    try { $wideGate = Test-ProjectAutopilotWideGate -Tasks $tasks -MinIndependentAtoms $wideK } catch {}
    $wideReasons = if ($wideGate) { @($wideGate.reasons) } else { @('wide-gate-error') }
    $wideIndep = if ($wideGate) { [int]$wideGate.independent_atom_count } else { 0 }
    try {
      Write-BacklogJsonLine ([ordered]@{
        ts = (Get-Date).ToUniversalTime().ToString('o')
        action = 'project-autopilot-wide-gate'
        channel = [string]$Channel
        enabled = [bool]($wideGate -and $wideGate.enabled)
        reasons = @($wideReasons)
        atoms = [int]$tasks.Count
        independent_atoms = $wideIndep
      })
    } catch {}
    if (-not ($wideGate -and [bool]$wideGate.enabled)) { $collapseReason = 'wide-gate-red' }
    # GREEN wide gate -> no collapse: the full cross-chapter batch goes through to the write loop.
  }
  if (-not [string]::IsNullOrWhiteSpace($collapseReason)) {
    $collapse = Get-ProjectAutopilotEarliestChapterTaskSet -Tasks $tasks
    if ([bool]$collapse.collapsed) {
      $beforeCount = $tasks.Count
      $tasks = @($collapse.tasks)
      try {
        Write-BacklogJsonLine ([ordered]@{
          ts = (Get-Date).ToUniversalTime().ToString('o')
          action = 'project-autopilot-diffusion-collapse-to-chapter'
          channel = [string]$Channel
          mode = $diffusionMode
          chapter = [string]$collapse.chapter
          kept = $tasks.Count
          dropped = ($beforeCount - $tasks.Count)
          reason = $collapseReason
        })
      } catch {}
    }
  }

  $existing = @(Get-Backlog)
  $existingSlugs = @{}
  foreach ($it in $existing) {
    $st = [string](Get-BacklogPackObjectValue -Obj $it -Name 'status' -Default '')
    if ($st -in @('rejected','auto-dropped','failed')) { continue }
    $sl = [string](Get-BacklogPackObjectValue -Obj $it -Name 'slug' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($sl)) { $existingSlugs[$sl] = $true }
  }

  $created = New-Object 'System.Collections.Generic.List[string]'
  $createdSlugs = New-Object 'System.Collections.Generic.List[string]'
  $createdChapters = New-Object 'System.Collections.Generic.List[string]'
  $startedAt = Get-Date
  $errors = New-Object 'System.Collections.Generic.List[string]'
  $skipped = 0
  foreach ($t in $tasks) {
    $slug = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $t -Name 'slug' -Default (Get-BacklogPackObjectValue -Obj $t -Name 'title' -Default '')))
    $metadataCheck = Test-ProjectAutopilotTaskMetadata -Task $t
    if (-not [bool]$metadataCheck.ok) {
      $label = if ([string]::IsNullOrWhiteSpace($slug)) { '(missing-slug)' } else { $slug }
      [void]$errors.Add(("incomplete PROJECT_BACKLOG atom '{0}': missing {1}" -f $label, ((@($metadataCheck.missing) | Sort-Object -Unique) -join ', ')))
      $skipped++
      continue
    }
    if ($existingSlugs.ContainsKey($slug)) { $skipped++; continue }
    $title = [string](Get-BacklogPackObjectValue -Obj $t -Name 'title' -Default $slug)
    $body = [string](Get-BacklogPackObjectValue -Obj $t -Name 'task' -Default '')
    if ([string]::IsNullOrWhiteSpace($body)) { $body = $title }
    if ([string]::IsNullOrWhiteSpace($body) -or $body.Length -lt 40) { [void]$errors.Add("task '$slug' too short"); continue }
    $severity = ([string](Get-BacklogPackObjectValue -Obj $t -Name 'severity' -Default '')).ToLowerInvariant()
    if ($severity -eq 'normal') { $severity = '' }
    if ($severity -notin @('critical','warning','info','')) { $severity = '' }
    $files = @(ConvertTo-ProjectAutopilotPathArray (Get-BacklogPackObjectValue -Obj $t -Name 'files' -Default @()))
    $deps = @(ConvertTo-ProjectAutopilotSlugArray (Get-ProjectAutopilotTaskStringArray -Task $t -Names @('depends_on','dependencies')))
    $chapter = Get-ProjectAutopilotTaskStringField -Task $t -Names @('chapter','phase','area')
    $wave = Get-ProjectAutopilotTaskStringField -Task $t -Names @('wave','milestone')
    $kind = Normalize-ProjectAutopilotAtomKind (Get-ProjectAutopilotTaskStringField -Task $t -Names @('kind','atom_kind'))
    $parallelGroup = Get-ProjectAutopilotTaskStringField -Task $t -Names @('parallel_group','workstream')
    $lane = Get-ProjectAutopilotTaskLane -Task $t -Channel $Channel -Files @($files) -TouchSet @()
    $acceptance = @(Get-ProjectAutopilotTaskStringArray -Task $t -Names @('acceptance','acceptance_checks','criteria'))
    $checks = @(Get-ProjectAutopilotTaskStringArray -Task $t -Names @('checks','verify','verification'))
    $detailLines = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($chapter)) { [void]$detailLines.Add("Chapter: $chapter") }
    if (-not [string]::IsNullOrWhiteSpace($wave)) { [void]$detailLines.Add("Wave: $wave") }
    if (-not [string]::IsNullOrWhiteSpace($kind)) { [void]$detailLines.Add("Kind: $kind") }
    if (-not [string]::IsNullOrWhiteSpace($parallelGroup)) { [void]$detailLines.Add("Parallel group: $parallelGroup") }
    if (-not [string]::IsNullOrWhiteSpace($lane)) { [void]$detailLines.Add("Lane: $lane") }
    if ($deps.Count -gt 0) { [void]$detailLines.Add("Depends on: " + (($deps | Select-Object -First 12) -join ', ')) }
    if ($acceptance.Count -gt 0) { [void]$detailLines.Add("Acceptance: " + (($acceptance | Select-Object -First 6) -join ' ; ')) }
    if ($checks.Count -gt 0) { [void]$detailLines.Add("Checks: " + (($checks | Select-Object -First 6) -join ' ; ')) }
    $detailLine = if ($detailLines.Count -gt 0) { "`n`n" + (($detailLines.ToArray()) -join "`n") } else { '' }
    $fileLine = if ($files.Count -gt 0) { "`n`nFiles: " + (($files | Select-Object -First 12) -join ', ') } else { '' }
    $text = "[project-autopilot $slug] [[NORMAL]]`n`n$title`n`n$body$detailLine$fileLine"
    $ideaTags = @('project-autopilot','auto-generated','atom')
    $ideaProject = [string]$Channel
    $ideaScope = 'project'
    if ($isBridgeSelfBacklog) {
      $ideaTags = @('project-autopilot','auto-generated','atom','bridge-self')
      $ideaProject = 'main'
      $ideaScope = 'bridge'
    }
    $id = Add-Idea -Text $text -From 'project-autopilot' -Tags $ideaTags -Status 'approved' -Severity $severity -Project $ideaProject -Scope $ideaScope -SkipCurator
    if ([string]::IsNullOrWhiteSpace([string]$id)) { [void]$errors.Add("Add-Idea failed for '$slug'"); continue }
    try { Set-ProjectAutopilotIdeaMetadata -Id ([string]$id) -Task $t -SourceTaskId $SourceTaskId | Out-Null } catch {}
    $existingSlugs[$slug] = $true
    [void]$created.Add([string]$id)
    [void]$createdSlugs.Add($slug)
    if (-not [string]::IsNullOrWhiteSpace($chapter)) { [void]$createdChapters.Add($chapter) }
    try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='project-backlog-add'; channel=$Channel; item_id=[string]$id; slug=$slug; source=$Source }) } catch {}
  }

  # 2026-06-28 (upfront-speed #1): pack the freshly-emitted PROJECT atoms IMMEDIATELY instead of waiting
  # up to backlogPack.cooldownMinutes (30m) for Invoke-BacklogPackerIfDue. Without a workpack_id an approved
  # atom is NOT frontier-eligible (Get-BacklogWorkpackExecEligibility -> 'missing-workpack', backlog-workpack.ps1:1729),
  # so it can only be claimed one-at-a-time by the single-item path -> the parallel wave can't form until the
  # delayed packer fires. Invoke-BacklogPacker itself has NO cooldown (the cooldown lives only in ...IfDue),
  # reuses the exact same battle-tested file:<path> grouping the delayed packer would apply, and is idempotent
  # (already-packed items are skipped), so this changes only TIMING, not grouping — the proven 4-wide build
  # behaviour is preserved, just reached ~30m sooner. Scoped to project channels (not bridge-self/main) to keep
  # the blast radius on the user's actual concern (project build start-up) and leave main dynamics unchanged.
  if ($created.Count -gt 0 -and -not $isBridgeSelfBacklog) {
    try {
      $packCfg = Get-BacklogPackConfig
      try { $packCfg.minItems = 1 } catch {}  # a single-atom chapter must still pack (default minItems=2)
      Invoke-BacklogPacker -Reason @('project-autopilot-emit') -Config $packCfg | Out-Null
    } catch { try { Request-BacklogPackIfNeeded | Out-Null } catch {} }
  } else {
    try { Request-BacklogPackIfNeeded | Out-Null } catch {}
  }
  $chapterHint = ''
  try { $chapterHint = (@($createdChapters.ToArray() | Sort-Object -Unique) | Select-Object -First 1) -join ',' } catch {}
  try {
    Write-ProjectAutopilotCoordinatorCostMetric -Channel $Channel -ChapterHint $chapterHint -WallclockSec (((Get-Date) - $startedAt).TotalSeconds) -AtomsEmitted $created.Count | Out-Null
  } catch {}
  return [pscustomobject]@{ created=$created.Count; skipped=$skipped; errors=@($errors.ToArray()); ids=@($created.ToArray()); slugs=@($createdSlugs.ToArray()); chapters=@($createdChapters.ToArray() | Sort-Object -Unique) }
}

#endregion Project Autopilot planning and expansion
