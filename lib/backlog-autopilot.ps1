# backlog-autopilot.ps1 -- Project Autopilot planning and expansion helpers.
#region Project Autopilot planning and expansion
function Get-ProjectAutopilotConfig {
  $cfg = [ordered]@{
    enabled = $true
    cooldownMinutes = 5
    maxTasksPerBatch = 12
    emptyCoordinatorLimit = 3
    diffusionMode = 'off'
    diffusionMinIndependentAtoms = 2
    diffusionMaxWaveSize = 6
  }
  $dotted = @{
    'projectAutopilot.enabled' = 'enabled'
    'projectAutopilot.cooldownMinutes' = 'cooldownMinutes'
    'projectAutopilot.maxTasksPerBatch' = 'maxTasksPerBatch'
    'projectAutopilot.emptyCoordinatorLimit' = 'emptyCoordinatorLimit'
    'projectAutopilot.diffusionMode' = 'diffusionMode'
    'projectAutopilot.diffusionMinIndependentAtoms' = 'diffusionMinIndependentAtoms'
    'projectAutopilot.diffusionMaxWaveSize' = 'diffusionMaxWaveSize'
  }
  $flat = @{
    projectAutopilotEnabled = 'enabled'
    projectAutopilotCooldownMinutes = 'cooldownMinutes'
    projectAutopilotMaxTasksPerBatch = 'maxTasksPerBatch'
    projectAutopilotEmptyCoordinatorLimit = 'emptyCoordinatorLimit'
    projectAutopilotDiffusionMode = 'diffusionMode'
    projectAutopilotDiffusionMinIndependentAtoms = 'diffusionMinIndependentAtoms'
    projectAutopilotDiffusionMaxWaveSize = 'diffusionMaxWaveSize'
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
  if ($cfg.diffusionMode -notin @('off','shadow','diffusion')) { $cfg.diffusionMode = 'off' }
  $cfg.diffusionMinIndependentAtoms = ConvertTo-BacklogPackInt -Value $cfg.diffusionMinIndependentAtoms -Default 2 -Min 1 -Max 50
  $cfg.diffusionMaxWaveSize = ConvertTo-BacklogPackInt -Value $cfg.diffusionMaxWaveSize -Default 6 -Min 1 -Max 50
  return [pscustomobject]$cfg
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

function Get-ProjectAutopilotInterfaceContractHash {
  param($Contract)
  try { return (Get-ProjectAutopilotSha256 (Get-ProjectAutopilotCanonicalJson -Value $Contract)) } catch { return '' }
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
  param($Contract, [string]$Path = '')
  $missing = New-Object 'System.Collections.Generic.List[string]'
  $id = Get-ProjectAutopilotInterfaceContractId -Contract $Contract -Path $Path
  if ([string]::IsNullOrWhiteSpace($id)) { [void]$missing.Add('id') }
  foreach ($field in @('version','signature','behavior','invariants','golden_examples','owned_files')) {
    $v = Get-ProjectAutopilotContractValue -Obj $Contract -Names @($field, ($field -replace '_','')) -Default $null
    if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]($v | ConvertTo-Json -Compress -Depth 8))) { [void]$missing.Add($field) }
  }
  $errors = Get-ProjectAutopilotContractValue -Obj $Contract -Names @('errors','error_taxonomy','failure_taxonomy') -Default $null
  if ($null -eq $errors -or [string]::IsNullOrWhiteSpace([string]($errors | ConvertTo-Json -Compress -Depth 8))) { [void]$missing.Add('errors') }
  $hash = Get-ProjectAutopilotInterfaceContractHash -Contract $Contract
  $declaredHash = [string](Get-ProjectAutopilotContractValue -Obj $Contract -Names @('content_hash','hash','frozen_hash') -Default '')
  $stableFlag = Test-ProjectAutopilotTruthy (Get-ProjectAutopilotContractValue -Obj $Contract -Names @('stable','frozen') -Default $false)
  $stable = ($stableFlag -or (-not [string]::IsNullOrWhiteSpace($declaredHash) -and $declaredHash.Trim().ToLowerInvariant() -eq $hash))
  return [pscustomobject]@{
    id = $id
    path = [string]$Path
    valid = ($missing.Count -eq 0)
    stable = [bool]$stable
    hash = $hash
    missing = @($missing.ToArray())
  }
}

function Get-ProjectAutopilotInterfaceContracts {
  param([string]$ProjectRoot)
  $dir = Get-ProjectAutopilotInterfaceContractDir -ProjectRoot $ProjectRoot
  if ([string]::IsNullOrWhiteSpace($dir) -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
  $out = New-Object 'System.Collections.Generic.List[object]'
  foreach ($file in @(Get-ChildItem -LiteralPath $dir -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)) {
    if ($file.Name -match '\.schema\.json$' -or $file.Name -eq 'contract.schema.json') { continue }
    try {
      $obj = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      $check = Test-ProjectAutopilotInterfaceContract -Contract $obj -Path $file.FullName
      $out.Add([pscustomobject]@{
        id = [string]$check.id
        path = $file.FullName
        contract = $obj
        valid = [bool]$check.valid
        stable = [bool]$check.stable
        hash = [string]$check.hash
        missing = @($check.missing)
      }) | Out-Null
    } catch {
      $out.Add([pscustomobject]@{
        id = ConvertTo-ProjectAutopilotSlug ([System.IO.Path]::GetFileNameWithoutExtension($file.Name))
        path = $file.FullName
        contract = $null
        valid = $false
        stable = $false
        hash = ''
        missing = @('valid_json')
      }) | Out-Null
    }
  }
  return @($out.ToArray())
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
    [object[]]$Contracts = @()
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
      foreach ($provider in $providers) {
        if ([string]$provider.slug -eq [string]$consumer.slug) { continue }
        $edges.Add([pscustomobject]@{
          from = [string]$provider.slug
          to = [string]$consumer.slug
          contract = $contractId
          edge_type = if ($valid -and $stable) { 'soft' } else { 'hard' }
          provenance = 'contract'
          confidence = if ($valid -and $stable) { 'high' } else { 'uncertain' }
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
  $graph = New-ProjectAutopilotUnifiedGraph -Tasks @($Tasks) -Contracts @($Contracts)
  $contractIds = @($Contracts | ForEach-Object { [string](Get-BacklogPackObjectValue -Obj $_ -Name 'id' -Default '') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $neededContracts = @($graph.nodes | ForEach-Object { @($_.consumes) + @($_.provides) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $missingContracts = @($neededContracts | Where-Object { $contractIds -notcontains $_ })
  if ($missingContracts.Count -gt 0 -or $graph.dangling_consumes.Count -gt 0) { [void]$reasons.Add('contract-coverage-incomplete') }
  $badContracts = @($Contracts | Where-Object { -not [bool](Get-BacklogPackObjectValue -Obj $_ -Name 'valid' -Default $false) })
  if ($badContracts.Count -gt 0) { [void]$reasons.Add('contract-invalid') }
  $unstableContracts = @($Contracts | Where-Object { -not [bool](Get-BacklogPackObjectValue -Obj $_ -Name 'stable' -Default $false) })
  if ($unstableContracts.Count -gt 0) { [void]$reasons.Add('contract-unstable') }
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
  if ($diffMode -notin @('off','shadow','diffusion')) { $diffMode = 'off' }
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
            if (-not [string]::IsNullOrWhiteSpace($chpCP)) { [void]$doneChaptersCP.Add($chpCP) }
          }
        } catch {}
        $decCountCP = $doneChaptersCP.Count
        $nextNCP = $decCountCP + 1
        $nextTitleCP = ''
        if ($nextNCP -ge 1 -and $nextNCP -le $totalChCP) { $nextTitleCP = ([string]$chapMatchesCP[$nextNCP-1].Groups[2].Value).Trim() }
        $doneSlugsCP = (@($doneChaptersCP) -join ', '); if ([string]::IsNullOrWhiteSpace($doneSlugsCP)) { $doneSlugsCP = '(none yet)' }
        $remainCP = $totalChCP - $decCountCP
        if ($nextNCP -le $totalChCP) {
          $chapterProgressBlock = "DETERMINISTIC PLAN PROGRESS (authoritative -- computed from PROJECT_PLAN.md + the live backlog; trust this over your own judgment about whether the release is finished):`n- The approved release IS the full plan: $totalChCP chapters total, ALL approved and in scope. Chapters you have not reached yet are NOT future/optional/out-of-scope work.`n- Full approved plan chapters:`n$($planLinesCP -join "`n")`n- Chapter areas already decomposed into the backlog ($decCountCP of $totalChCP done): $doneSlugsCP`n- NEXT chapter to decompose NOW: Chapter $nextNCP - $nextTitleCP`n- Decompose ONLY Chapter $nextNCP into atoms this run. Do NOT conclude the release is complete -- $remainCP chapter(s) still remain. Do NOT emit a release-scope open-question for Chapter $nextNCP; it is already authorized by the approved plan.`n- Efficiency: the plan progress above is authoritative for scope/status, so you do NOT need to re-read PROJECT_MAP.md or re-scan the whole codebase to decide what is done. Read only the specific source files your Chapter $nextNCP atoms will create, touch, or depend on (check earlier CHAPTER_*_ATOMS.md only for file-ownership of prior chapters to avoid conflicts).`n`n"
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
- Treat .bridge/project-contract.json as the machine-readable product/UX/acceptance contract. It must include spec_profile/project_size plus explicit scope plus explicit non_goals, explicit users/roles/personas, data/backend ownership, checks, risk, parallel_policy, requirements/capabilities, screens/routes/interfaces/modules, user journeys/workflows, ux_contract/interface_contract, and acceptance scenarios.
- Choose the lightest valid spec_profile: lite for small/narrow projects, standard for normal multi-surface apps, full for large/complex/production projects. Lite avoids unnecessary DISCUSS_* bureaucracy; full requires deeper specs before implementation.
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
- Diffusion/cross-chapter decomposition is opt-in only. If diffusion_mode is off, always use the one-chapter default. If diffusion_mode is shadow, compute and report the would-be cross-chapter graph/gate result as durable markers but still emit only the one-chapter default. If diffusion_mode is diffusion, do not emit a cross-chapter PROJECT_BACKLOG unless every deterministic gate is satisfied: complete and stable .bridge/specs/contracts/<contract-id>.json coverage for every cross-atom interface, no [[PROJECT_OPEN_QUESTION]] blocking scope/architecture, a validated acyclic depends_on graph, known non-overlapping file ownership or explicit serial_reason, stitching/integration tests, clean git worktree, independent atom count >= $diffK, and wave size <= $diffN. If any condition is missing, fall back to the one-chapter default and emit [[PROJECT_OPEN_QUESTION: diffusion gate blocked: ...]] or a concise [[PROJECT_RISK: ...]] marker instead of guessing.
- Interface contracts live in .bridge/specs/contracts/<contract-id>.json. A contract must cover signature, behavior/preconditions/postconditions/side-effects/idempotency, invariants, error taxonomy, golden input/output examples, owned files/regions, version, content hash or stable:true. Atoms may reference them through provides and consumes arrays; a stable frozen contract may justify a soft edge, while missing/unstable contracts require hard depends_on serialization.
- Each atom must be a small verifiable change, with clear dependencies, files/touch-set, acceptance checks, and commit requirement.
- Keep each atom to a SINGLE focused concern with a SMALL diff (ideally one function/class/area). Do NOT bundle multiple changes into one atom (e.g., new implementation + a refactor + cross-file tests): a large diff makes the completion-critic find many issues per pass and iterate for many slow rounds. Tests for a module are their own atom, separate from the implementation atoms they cover; a bug fix is its own atom. Small single-concern diffs let the critic converge in 1-2 rounds even when atoms run batched in parallel.
- Order infra-first: shared modules, contracts, schemas, adapters, migrations, and test harnesses must be emitted before feature atoms that consume them. Feature atoms that depend on shared infra must list the infra atom slug in depends_on.
- Model the execution DAG explicitly: independent atoms have empty depends_on; dependent atoms reference prerequisite slugs.
- Prefer a ready frontier: several independent atoms in the same wave, then dependent atoms in later waves.
- Design for PARALLELISM at the file level: prefer small, focused files (one concern per file) so atoms in the same wave touch DIFFERENT files and run concurrently. Avoid mega-files (one file accumulating many concerns) -- they force same-file atoms to serialize and bottleneck the parallel team. When a module would grow large, split it into a package of focused sibling submodules (re-exported via the package init) so each atom owns its own file. Two atoms in the same wave must not write the same file; if they must share a file, mark serial_reason and put them in different waves.
- Use chapter, wave, kind, parallel_group, files, depends_on, acceptance, checks, risk/severity, and serial_reason so the scheduler can run the team safely. Optional kind values are infra, feature, consolidation, and planning; omit kind only for default feature atoms.
- Project atoms operate ONLY inside the project root and never modify the bridge engine, so they require no special admission. Keep every files entry within the project tree.
- Every atom acceptance must trace back to a project-contract requirement, journey, surface, or acceptance scenario. Do not use generic "looks good" UX checks.
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
    "chapter": "approved chapter / project area",
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

depends_on may be []; kind may be omitted and then defaults to feature; serial_reason may be "" for parallel atoms. acceptance/checks must be concrete, not generic "looks good". files must be the real touch-set / scheduler-allowed paths. workpack_touch_set and workpack_conflict_group are optional explicit scheduler metadata; omit them unless files alone would be ambiguous. Incomplete atoms are rejected by the deterministic ingest gate.

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
  if ([int]$pressure.runnable -gt 0) { return [pscustomobject]@{ queued=$false; reason='backlog-not-empty'; pressure=$pressure } }
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

  $diffusionMode = 'off'
  $diffusionGate = $null
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
      $contracts = @(Get-ProjectAutopilotInterfaceContracts -ProjectRoot $projectRoot)
      $diffusionGate = Test-ProjectAutopilotDiffusionGate -Tasks $tasks -Contracts $contracts -ProjectRoot $projectRoot -OptIn:($true) -MinIndependentAtoms ([int]$cfg.diffusionMinIndependentAtoms) -MaxWaveSize ([int]$cfg.diffusionMaxWaveSize)
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
      })
    }
  } catch {}
  if ($diffusionMode -eq 'diffusion' -and $diffusionGate -and -not [bool]$diffusionGate.enabled) {
    $chaptersForGate = @($tasks | ForEach-Object { Get-ProjectAutopilotTaskStringField -Task $_ -Names @('chapter','phase','area') } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    if ($chaptersForGate.Count -gt 1) {
      return [pscustomobject]@{
        created = 0
        skipped = $tasks.Count
        errors = @('diffusion gate blocked cross-chapter PROJECT_BACKLOG: ' + ((@($diffusionGate.reasons) | Sort-Object -Unique) -join ', '))
        ids = @()
      }
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

  try { Request-BacklogPackIfNeeded | Out-Null } catch {}
  $chapterHint = ''
  try { $chapterHint = (@($createdChapters.ToArray() | Sort-Object -Unique) | Select-Object -First 1) -join ',' } catch {}
  try {
    Write-ProjectAutopilotCoordinatorCostMetric -Channel $Channel -ChapterHint $chapterHint -WallclockSec (((Get-Date) - $startedAt).TotalSeconds) -AtomsEmitted $created.Count | Out-Null
  } catch {}
  return [pscustomobject]@{ created=$created.Count; skipped=$skipped; errors=@($errors.ToArray()); ids=@($created.ToArray()); slugs=@($createdSlugs.ToArray()); chapters=@($createdChapters.ToArray() | Sort-Object -Unique) }
}

#endregion Project Autopilot planning and expansion
