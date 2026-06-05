# backlog-autopilot.ps1 -- Project Autopilot planning and expansion helpers.
#region Project Autopilot planning and expansion
function Get-ProjectAutopilotConfig {
  $cfg = [ordered]@{
    enabled = $true
    cooldownMinutes = 5
    maxTasksPerBatch = 12
    emptyCoordinatorLimit = 3
  }
  $dotted = @{
    'projectAutopilot.enabled' = 'enabled'
    'projectAutopilot.cooldownMinutes' = 'cooldownMinutes'
    'projectAutopilot.maxTasksPerBatch' = 'maxTasksPerBatch'
    'projectAutopilot.emptyCoordinatorLimit' = 'emptyCoordinatorLimit'
  }
  $flat = @{
    projectAutopilotEnabled = 'enabled'
    projectAutopilotCooldownMinutes = 'cooldownMinutes'
    projectAutopilotMaxTasksPerBatch = 'maxTasksPerBatch'
    projectAutopilotEmptyCoordinatorLimit = 'emptyCoordinatorLimit'
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

function Get-ProjectAutopilotPlanSignatureFiles {
  $files = New-Object 'System.Collections.Generic.List[string]'
  foreach ($stage in @(Get-ProjectAutopilotPlanningStageDefinitions)) {
    [void]$files.Add([string]$stage.path)
  }
  foreach ($rel in @('PROJECT_MAP.md','PROJECT_PLAN.md','.bridge\project-contract.json')) {
    [void]$files.Add([string]$rel)
  }
  return @($files.ToArray())
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
  foreach ($rel in @(Get-ProjectAutopilotPlanSignatureFiles)) {
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
    $files = @(Get-ProjectAutopilotPlanSignatureFiles | ForEach-Object { ([string]$_).Replace('\','/') })
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
  param([string]$ProjectRoot, $Issues)
  $stageDocLengths = [ordered]@{}
  foreach ($stageDef in @(Get-ProjectAutopilotPlanningStageDefinitions)) {
    $stagePath = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { '' } else { Join-Path $ProjectRoot ([string]$stageDef.path) }
    $stageText = Get-ProjectAutopilotFileText -Path $stagePath
    $stageDocLengths[[string]$stageDef.id] = [int]$stageText.Length
    if ($stageText.Length -lt [int]$stageDef.min_chars) {
      [void]$Issues.Add(([string]$stageDef.path + ' is missing or too shallow (<' + [string]$stageDef.min_chars + ' chars)'))
    }
  }
  return $stageDocLengths
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
  $deliveryContractOk = $false
  $deliveryContractScore = $null
  $deliveryContractMissing = @()
  $deliveryContractWarnings = @()
  $deliveryContractBlockers = @()
  $deliveryContractRequiredSections = @()

  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    [void]$issues.Add('project_root is missing')
  }
  if ($mapText.Length -lt 1500) {
    [void]$issues.Add('PROJECT_MAP.md is missing or too shallow (<1500 chars)')
  }
  if ($planText.Length -lt 2000) {
    [void]$issues.Add('PROJECT_PLAN.md is missing or too shallow (<2000 chars)')
  }

  $stageDocLengths = Get-ProjectAutopilotPlanStageDocLengths -ProjectRoot $ProjectRoot -Issues $issues

  if ([string]::IsNullOrWhiteSpace($contractPath) -or -not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    [void]$issues.Add('.bridge/project-contract.json is missing')
  } else {
    try {
      $contract = [System.IO.File]::ReadAllText($contractPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
      [void]$issues.Add('.bridge/project-contract.json is not valid JSON')
    }
  }

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
    if ($reqCount -lt 3) { [void]$issues.Add('project contract needs at least 3 requirements/capabilities/features') }
    if ($surfaceCount -lt 2) { [void]$issues.Add('project contract needs at least 2 screens/routes/interfaces/modules') }
    if ($journeyCount -lt 2) { [void]$issues.Add('project contract needs at least 2 user journeys/workflows/scenarios') }
    if ($acceptanceCount -lt 3) { [void]$issues.Add('project contract needs at least 3 acceptance scenarios/checks') }
    if ($interfaceCount -lt 1) { [void]$issues.Add('project contract needs ux_contract or interface_contract') }
    if (-not $planningFlow) {
      [void]$issues.Add('project contract needs planning_flow with staged discussions')
    } else {
      foreach ($stageDef in @(Get-ProjectAutopilotPlanningStageDefinitions)) {
        $sid = [string]$stageDef.id
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
      if ($integrationDeps.Count -lt 5) { [void]$issues.Add('planning_flow integration stage must depend on/validate prior stages') }
    }
  }

  return [pscustomobject]@{
    ready = ($issues.Count -eq 0)
    issues = @($issues.ToArray())
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
  param([string]$Slug, [string]$ProjectRoot, [int]$MaxTasks = 12)
  $max = [Math]::Max(1, [Math]::Min(50, [int]$MaxTasks))
  return @"
[project-autopilot $Slug] [[NORMAL]]

Project Autopilot coordinator for channel '$Slug'.

Work only in $ProjectRoot.

Mission: keep this project moving without the operator manually feeding backlog items.

Plan gate status:
- This coordinator is queued only after the channel-level Discuss-First plan gate has approved the current PROJECT_PLAN signature.
- Treat channels/$Slug/channel.json plan_approved=true and its approved signature as the source of truth for execution permission.
- If PROJECT_PLAN.md, PROJECT_MAP.md, or .bridge/project-contract.json still contain pre-approval wording such as "not approved", "UNAPPROVED", or "planned, not approved", do not treat that wording as a blocker after this coordinator has been queued. Use those words as historical planning status unless the channel gate itself is not approved.

Rules:
- Do NOT implement feature code in this coordinator task, except small durable planning docs such as CHAPTER_N_ATOMS.md.
- Read PROJECT_BRIEF.md, DISCUSS_PRODUCT.md, DISCUSS_UX.md, DISCUSS_UI.md, DISCUSS_BACKEND.md, DISCUSS_QA.md, DISCUSS_INTEGRATION.md, PROJECT_MAP.md, PROJECT_PLAN.md, .bridge/project-contract.json, existing CHAPTER_*_ATOMS.md files, README, git log/status, and current code.
- Read the project memory/context supplied in the prompt. Preserve durable decisions, risks, invariants, tests, and open questions.
- Treat .bridge/project-contract.json as the machine-readable product/UX/acceptance contract. It must describe explicit scope plus explicit non_goals, explicit users/roles/personas, data/backend ownership, checks, risk, parallel_policy, requirements/capabilities, screens/routes/interfaces/modules, user journeys/workflows, ux_contract/interface_contract, and acceptance scenarios.
- requirements/capabilities/features do NOT replace explicit scope plus non_goals. user_journeys/journeys/flows/workflows do NOT replace explicit users/roles/personas/actors.
- Treat planning as staged: brief -> product -> UX -> UI -> backend -> QA -> integration. Every later stage must explicitly use decisions from earlier stages. The integration stage resolves cross-stage conflicts before implementation.
- If the stage docs, map, plan, or contract are shallow/missing/stale, do NOT emit implementation atoms. Emit durable memory about the gap and finish, or emit docs-only planning atoms that deepen PROJECT_BRIEF.md, DISCUSS_*.md, PROJECT_MAP.md, PROJECT_PLAN.md, and .bridge/project-contract.json.
- Determine the next approved/incomplete chapter from the contract and plan, not from a guessed feature list.
- Decompose only ONE next chapter/wave into small atomic implementation tasks. Prefer 3-$max tasks; fewer is OK if the chapter is small.
- Each atom must be a small verifiable change, with clear dependencies, files/touch-set, acceptance checks, and commit requirement.
- Model the execution DAG explicitly: independent atoms have empty depends_on; dependent atoms reference prerequisite slugs.
- Prefer a ready frontier: several independent atoms in the same wave, then dependent atoms in later waves.
- Use chapter, wave, parallel_group, files, depends_on, acceptance, checks, risk/severity, and serial_reason so the scheduler can run the team safely.
- For main/bridge-self atoms touching control-plane files (`driver.ps1`, `supervisor.ps1`, `watchdog.ps1`, `server.ps1`, `lib/circuit-breaker.ps1`, `lib/backlog*.ps1`, `lib/parallel.ps1`), include `bridge_self_admission` with `admitted:true`, `mode:"bridge_self_canary"`, `canary_required:true`, checks including driver self-test, smoke, canary, and a non-empty rollback_plan. Without this, the deterministic claim gate will keep the atom blocked.
- Every atom acceptance must trace back to a project-contract requirement, journey, surface, or acceptance scenario. Do not use generic "looks good" UX checks.
- Before PROJECT_BACKLOG, emit durable project memory markers when useful:
  [[PROJECT_DECISION: ...]]
  [[PROJECT_RISK: ...]]
  [[PROJECT_INVARIANT: ...]]
  [[PROJECT_TEST: ...]]
  [[PROJECT_OPEN_QUESTION: ...]]
  Keep memory concise and durable; do not store transient progress noise.
- If a product decision is truly blocking, do not invent it: emit [[PROJECT_OPEN_QUESTION: ...]] and finish without PROJECT_BACKLOG.
- Never put real secrets, local DB files, uploads, .next, or node_modules in git.
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
    "parallel_group": "auth|gallery|chat|admin|docs|tests|...",
    "files": ["relative/path/or/directory"],
    "depends_on": ["slug-of-prerequisite-if-any"],
    "acceptance": ["observable acceptance criterion tied to the approved contract"],
    "checks": ["npm run typecheck", "npm run build"],
    "risk": "normal",
    "severity": "normal",
    "serial_reason": "",
    "bridge_self_admission": {
      "admitted": true,
      "mode": "bridge_self_canary",
      "canary_required": true,
      "checks": ["powershell -NoProfile -ExecutionPolicy Bypass -File .\\driver.ps1 -SelfTest", "powershell -NoProfile -ExecutionPolicy Bypass -File .\\smoke.ps1", "Invoke-CanaryCycle"],
      "rollback_plan": "If smoke/canary/live health fails, rely on stable ref + watchdog rollback and stop further bridge-self claims."
    },
    "workpack_touch_set": ["relative/path/or/directory"],
    "workpack_conflict_group": "file:relative/path/or/directory"
  }
]
[[/PROJECT_BACKLOG]]

depends_on may be []; serial_reason may be "" for parallel atoms. acceptance/checks must be concrete, not generic "looks good". files must be the real touch-set / scheduler-allowed paths. workpack_touch_set and workpack_conflict_group are optional explicit scheduler metadata; omit them unless files alone would be ambiguous. `bridge_self_admission` is required only for main/bridge-self control-plane atoms and ignored for ordinary external project atoms. Incomplete atoms are rejected by the deterministic ingest gate.

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
    $raw | Add-Member -NotePropertyName plan_approved_signature_version -NotePropertyValue 'staged-v1' -Force
    $raw | Add-Member -NotePropertyName plan_approved_files -NotePropertyValue @(Get-ProjectAutopilotPlanSignatureFiles) -Force
    $raw | Add-Member -NotePropertyName plan_approved_git_head -NotePropertyValue (Get-ProjectAutopilotGitHead -ProjectRoot $projectRoot) -Force
    $raw | Add-Member -NotePropertyName plan_contract_path -NotePropertyValue ([string]$contractReady.contract_path) -Force
    $raw | Add-Member -NotePropertyName plan_contract_score -NotePropertyValue $contractReady.delivery_contract_score -Force
    $raw | Add-Member -NotePropertyName plan_contract_required_sections -NotePropertyValue @($contractReady.delivery_contract_required_sections) -Force
  } elseif (-not $Approved) {
    $raw | Add-Member -NotePropertyName plan_approved_signature -NotePropertyValue '' -Force
    $raw | Add-Member -NotePropertyName plan_approved_signature_version -NotePropertyValue '' -Force
    $raw | Add-Member -NotePropertyName plan_approved_files -NotePropertyValue @() -Force
    $raw | Add-Member -NotePropertyName plan_approved_git_head -NotePropertyValue '' -Force
  }
  [System.IO.File]::WriteAllText($cj, (($raw | ConvertTo-Json -Depth 10) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  # clear the one-time gate-notified marker so a future re-gate (plan rewrite) notifies the operator again
  try { $gm = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel) '.plan-gate-notified'; if (Test-Path -LiteralPath $gm) { Remove-Item -LiteralPath $gm -Force -ErrorAction SilentlyContinue } } catch {}
  try { $cm = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel) '.plan-contract-gate-notified'; if (Test-Path -LiteralPath $cm) { Remove-Item -LiteralPath $cm -Force -ErrorAction SilentlyContinue } } catch {}
  return $Approved
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
      contract_path = [string]$planContract.contract_path
      delivery_contract_ok = $planContract.delivery_contract_ok
      delivery_contract_score = $planContract.delivery_contract_score
      delivery_contract_missing = @($planContract.delivery_contract_missing)
      delivery_contract_warnings = @($planContract.delivery_contract_warnings)
      delivery_contract_blockers = @($planContract.delivery_contract_blockers)
      delivery_contract_required_sections = @($planContract.delivery_contract_required_sections)
    }
  }

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

  $task = New-ProjectAutopilotCoordinatorTaskText -Slug $slug -ProjectRoot $root -MaxTasks ([int]$cfg.maxTasksPerBatch)
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
      $chapter = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('chapter','phase','area')
      $wave = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('wave','milestone')
      $parallelGroup = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('parallel_group','lane','workstream')
      $acceptance = @(Get-ProjectAutopilotTaskStringArray -Task $Task -Names @('acceptance','acceptance_checks','criteria'))
      $checks = @(Get-ProjectAutopilotTaskStringArray -Task $Task -Names @('checks','verify','verification'))
      $risk = Get-ProjectAutopilotTaskRisk -Task $Task
      $serialReason = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('serial_reason')
      $explicitTouch = @(ConvertTo-ProjectAutopilotPathArray (Get-ProjectAutopilotTaskStringArray -Task $Task -Names @('workpack_touch_set','touch_set')))
      $explicitGroup = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('workpack_conflict_group')
      $bridgeSelfAdmission = Get-BacklogPackObjectValue -Obj $Task -Name 'bridge_self_admission' -Default $null
      $i | Add-Member -NotePropertyName slug -NotePropertyValue $slug -Force
      $i | Add-Member -NotePropertyName title -NotePropertyValue $title -Force
      $i | Add-Member -NotePropertyName task -NotePropertyValue $body -Force
      $i | Add-Member -NotePropertyName autopilot_generated -NotePropertyValue $true -Force
      $i | Add-Member -NotePropertyName autopilot_source_task -NotePropertyValue ([string]$SourceTaskId) -Force
      $i | Add-Member -NotePropertyName files -NotePropertyValue ([object[]]@($files)) -Force
      $i | Add-Member -NotePropertyName depends_on -NotePropertyValue ([object[]]@($deps)) -Force
      $i | Add-Member -NotePropertyName risk -NotePropertyValue $risk -Force
      $i | Add-Member -NotePropertyName serial_reason -NotePropertyValue $serialReason -Force
      if (-not [string]::IsNullOrWhiteSpace($chapter)) { $i | Add-Member -NotePropertyName chapter -NotePropertyValue $chapter -Force }
      if (-not [string]::IsNullOrWhiteSpace($wave)) { $i | Add-Member -NotePropertyName wave -NotePropertyValue $wave -Force }
      if (-not [string]::IsNullOrWhiteSpace($parallelGroup)) { $i | Add-Member -NotePropertyName parallel_group -NotePropertyValue $parallelGroup -Force }
      if ($acceptance.Count -gt 0) { $i | Add-Member -NotePropertyName acceptance_checks -NotePropertyValue @($acceptance) -Force }
      if ($checks.Count -gt 0) { $i | Add-Member -NotePropertyName verification_checks -NotePropertyValue @($checks) -Force }
      if ($acceptance.Count -gt 0) { $i | Add-Member -NotePropertyName acceptance -NotePropertyValue @($acceptance) -Force }
      if ($checks.Count -gt 0) { $i | Add-Member -NotePropertyName checks -NotePropertyValue @($checks) -Force }
      if ($bridgeSelfAdmission) { $i | Add-Member -NotePropertyName bridge_self_admission -NotePropertyValue $bridgeSelfAdmission -Force }
      $touchSet = if ($explicitTouch.Count -gt 0) { @($explicitTouch) } else { @($files) }
      if ($touchSet.Count -gt 0) {
        $group = if (-not [string]::IsNullOrWhiteSpace($explicitGroup)) { [string]$explicitGroup } else { 'file:' + [string]$touchSet[0] }
        $i | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue ([object[]]@($touchSet)) -Force
        $i | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue $group -Force
        $i | Add-Member -NotePropertyName workpack_lane_hint -NotePropertyValue ('serial:' + $group) -Force
      }
      $meta = [ordered]@{}
      if (-not [string]::IsNullOrWhiteSpace($chapter)) { $meta.chapter = $chapter }
      if (-not [string]::IsNullOrWhiteSpace($wave)) { $meta.wave = $wave }
      if (-not [string]::IsNullOrWhiteSpace($parallelGroup)) { $meta.parallel_group = $parallelGroup }
      $meta.depends_on = @($deps)
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
    $parallelGroup = Get-ProjectAutopilotTaskStringField -Task $t -Names @('parallel_group','lane','workstream')
    $acceptance = @(Get-ProjectAutopilotTaskStringArray -Task $t -Names @('acceptance','acceptance_checks','criteria'))
    $checks = @(Get-ProjectAutopilotTaskStringArray -Task $t -Names @('checks','verify','verification'))
    $detailLines = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($chapter)) { [void]$detailLines.Add("Chapter: $chapter") }
    if (-not [string]::IsNullOrWhiteSpace($wave)) { [void]$detailLines.Add("Wave: $wave") }
    if (-not [string]::IsNullOrWhiteSpace($parallelGroup)) { [void]$detailLines.Add("Parallel group: $parallelGroup") }
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
  return [pscustomobject]@{ created=$created.Count; skipped=$skipped; errors=@($errors.ToArray()); ids=@($created.ToArray()); slugs=@($createdSlugs.ToArray()); chapters=@($createdChapters.ToArray() | Sort-Object -Unique) }
}

#endregion Project Autopilot planning and expansion
