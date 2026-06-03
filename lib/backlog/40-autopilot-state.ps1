# 40-autopilot-state.ps1 -- Project autopilot configuration, state, and outcome recording.
# Mechanical split from lib/backlog.ps1; keep loaded through ../backlog.ps1.

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
