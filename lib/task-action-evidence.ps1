# task-action-evidence.ps1 -- deterministic evidence that a coder turn changed repository state.

if (-not (Get-Command Test-ProjectGeneratedArtifactPath -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot 'project-artifact-policy.ps1')
}

function Normalize-TaskActionEvidencePath {
  param([string]$StatusLine)
  if ([string]::IsNullOrWhiteSpace($StatusLine)) { return '' }
  $line = ([string]$StatusLine).TrimEnd()
  if ($line.Length -le 3) { return '' }
  $path = $line.Substring(3).Trim()
  if ($path -match '\s+->\s+(.+)$') { $path = $Matches[1].Trim() }
  return ($path -replace '\\','/')
}

function Test-TaskActionEvidencePathWorth {
  param([string]$Path, [string]$RepoRoot = '', [string]$BridgeRoot = '')
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $isBridge = $false
  try {
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot) -and -not [string]::IsNullOrWhiteSpace($BridgeRoot)) {
      $rr = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\','/')
      $br = [System.IO.Path]::GetFullPath($BridgeRoot).TrimEnd('\','/')
      $isBridge = $rr.Equals($br, [System.StringComparison]::OrdinalIgnoreCase)
    }
  } catch {}
  if ($isBridge -and (Get-Command Test-BridgeAutoCommitWorthPath -ErrorAction SilentlyContinue)) {
    return [bool](Test-BridgeAutoCommitWorthPath -Path $Path)
  }
  if (-not $isBridge -and (Get-Command Test-ProjectGeneratedArtifactPath -ErrorAction SilentlyContinue)) {
    if (Test-ProjectGeneratedArtifactPath -Path $Path) { return $false }
  }
  return $true
}

function Get-CodexEvidenceRetryPlan {
  param(
    [int]$CurrentRetryCount = 0,
    [int]$MaxAttempts = 3,
    [int]$BaseDelaySec = 5,
    [int]$MaxDelaySec = 20
  )
  if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
  if ($BaseDelaySec -lt 0) { $BaseDelaySec = 0 }
  if ($MaxDelaySec -lt 0) { $MaxDelaySec = 0 }
  if ($CurrentRetryCount -lt 0) { $CurrentRetryCount = 0 }

  $attempt = $CurrentRetryCount + 1
  $shouldRetry = ($attempt -lt $MaxAttempts)
  $delay = 0
  if ($shouldRetry -and $BaseDelaySec -gt 0 -and $MaxDelaySec -gt 0) {
    $multiplier = [Math]::Pow(2, [Math]::Max(0, $attempt - 1))
    $delay = [int][Math]::Min([double]$MaxDelaySec, [double]($BaseDelaySec * $multiplier))
  }

  return [pscustomobject]@{
    attempt      = [int]$attempt
    max_attempts = [int]$MaxAttempts
    should_retry = [bool]$shouldRetry
    exhausted    = [bool](-not $shouldRetry)
    delay_sec    = [int]$delay
  }
}

function Get-TaskActionEvidenceBacklogTextById {
  param(
    [string]$BridgeRoot = '',
    [string]$BacklogId = ''
  )
  if ([string]::IsNullOrWhiteSpace($BridgeRoot) -or [string]::IsNullOrWhiteSpace($BacklogId)) { return '' }
  $root = ''
  try { $root = [System.IO.Path]::GetFullPath($BridgeRoot) } catch { return '' }
  $channelsDir = Join-Path $root 'channels'
  if (-not (Test-Path -LiteralPath $channelsDir -PathType Container)) { return '' }

  foreach ($backlogPath in @(Get-ChildItem -LiteralPath $channelsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'backlog.jsonl' })) {
    if (-not (Test-Path -LiteralPath $backlogPath -PathType Leaf)) { continue }
    try {
      foreach ($line in @([System.IO.File]::ReadLines($backlogPath, [System.Text.Encoding]::UTF8))) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.IndexOf($BacklogId, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $item = $line | ConvertFrom-Json
        $id = ''
        try { $id = [string]$item.id } catch {}
        if (-not $id.Equals($BacklogId, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        foreach ($name in @('text','task','title')) {
          try {
            if ($item.PSObject.Properties.Name -contains $name) {
              $value = [string]$item.$name
              if (-not [string]::IsNullOrWhiteSpace($value)) { return $value }
            }
          } catch {}
        }
      }
    } catch {}
  }
  return ''
}

function Test-TaskBridgeSideActionEvidenceTask {
  param(
    [object]$State = $null,
    [string]$TaskText = '',
    [string]$BridgeRoot = ''
  )
  $texts = New-Object 'System.Collections.Generic.List[string]'
  if (-not [string]::IsNullOrWhiteSpace($TaskText)) { [void]$texts.Add([string]$TaskText) }
  try {
    if ($State -and ($State.PSObject.Properties.Name -contains 'current_task')) {
      $stTask = [string]$State.current_task
      if (-not [string]::IsNullOrWhiteSpace($stTask)) { [void]$texts.Add($stTask) }
    }
  } catch {}
  try {
    if ($State -and ($State.PSObject.Properties.Name -contains 'current_backlog_id')) {
      $backlogId = [string]$State.current_backlog_id
      $backlogText = Get-TaskActionEvidenceBacklogTextById -BridgeRoot $BridgeRoot -BacklogId $backlogId
      if (-not [string]::IsNullOrWhiteSpace($backlogText)) { [void]$texts.Add($backlogText) }
    }
  } catch {}

  foreach ($text in @($texts.ToArray())) {
    if ([string]$text -match '(?i)\[project-acceptance-fix\]') { return $true }
  }
  return $false
}

function Get-TaskActionEvidenceContext {
  param(
    [object]$State,
    [string]$DefaultRepoRoot,
    [string]$BridgeRoot
  )

  $repoRoot = [string]$DefaultRepoRoot
  $baseCommit = ''
  $baseDirty = @()
  try {
    if ($State -and ($State.PSObject.Properties.Name -contains 'task_base_commit')) {
      $baseCommit = [string]$State.task_base_commit
    }
  } catch { $baseCommit = '' }
  try {
    if ($State -and ($State.PSObject.Properties.Name -contains 'task_base_dirty')) {
      $baseDirty = @($State.task_base_dirty | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
  } catch { $baseDirty = @() }

  $bridgeSide = Test-TaskBridgeSideActionEvidenceTask -State $State -BridgeRoot $BridgeRoot
  if ($bridgeSide -and -not [string]::IsNullOrWhiteSpace($BridgeRoot)) {
    $repoRoot = [string]$BridgeRoot
    try {
      if ($State -and ($State.PSObject.Properties.Name -contains 'task_bridge_base_commit')) {
        $bridgeBase = [string]$State.task_bridge_base_commit
        if (-not [string]::IsNullOrWhiteSpace($bridgeBase)) { $baseCommit = $bridgeBase }
      }
    } catch {}
    try {
      if ($State -and ($State.PSObject.Properties.Name -contains 'task_bridge_base_dirty')) {
        $bridgeDirty = @($State.task_bridge_base_dirty | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $baseDirty = @($bridgeDirty)
      }
    } catch {}
  }

  return [pscustomobject]@{
    repo_root        = [string]$repoRoot
    base_commit      = [string]$baseCommit
    base_dirty_paths = @($baseDirty)
    bridge_side      = [bool]$bridgeSide
  }
}

function Get-TaskActionEvidence {
  param(
    [string]$RepoRoot,
    [string]$BaseCommit = '',
    [string]$BridgeRoot = '',
    [string[]]$BaseDirtyPaths = @()
  )
  $head = ''
  $headChanged = $false
  $commitWorth = New-Object 'System.Collections.Generic.List[string]'
  $dirtyWorth = New-Object 'System.Collections.Generic.List[string]'
  $dirtyAll = New-Object 'System.Collections.Generic.List[string]'
  $baseDirty = @{}
  foreach ($bd in @($BaseDirtyPaths)) {
    $bp = ([string]$bd).Trim() -replace '\\','/'
    while ($bp.StartsWith('./')) { $bp = $bp.Substring(2) }
    if (-not [string]::IsNullOrWhiteSpace($bp)) { $baseDirty[$bp] = $true }
  }

  if ([string]::IsNullOrWhiteSpace($RepoRoot) -or -not (Test-Path -LiteralPath $RepoRoot)) {
    return [pscustomobject]@{ has_actions=$false; head_changed=$false; committed_worthy=@(); dirty_worthy=@(); dirty_all=@(); head='' }
  }

  try { $head = ((& git -C $RepoRoot rev-parse HEAD 2>$null) | Select-Object -First 1).Trim() } catch { $head = '' }
  if (-not [string]::IsNullOrWhiteSpace($BaseCommit) -and -not [string]::IsNullOrWhiteSpace($head) -and $head -ne $BaseCommit) {
    $headChanged = $true
  }
  if ($headChanged) {
    try {
      $baseOk = $false
      try {
        $baseType = (& git -C $RepoRoot cat-file -t $BaseCommit 2>$null | Select-Object -First 1)
        if ([string]$baseType -eq 'commit') { $baseOk = $true }
      } catch {}
      if ($baseOk) {
        foreach ($path in @(& git -C $RepoRoot diff --name-only $BaseCommit HEAD -- 2>$null)) {
          $p = ([string]$path).Trim() -replace '\\','/'
          if ([string]::IsNullOrWhiteSpace($p)) { continue }
          if (Test-TaskActionEvidencePathWorth -Path $p -RepoRoot $RepoRoot -BridgeRoot $BridgeRoot) {
            [void]$commitWorth.Add($p)
          }
        }
      } else {
        [void]$commitWorth.Add('__unknown_head_change__')
      }
    } catch {}
  }

  try {
    foreach ($line in @(& git -C $RepoRoot status --porcelain -uall 2>$null)) {
      $path = Normalize-TaskActionEvidencePath -StatusLine ([string]$line)
      if ([string]::IsNullOrWhiteSpace($path)) { continue }
      [void]$dirtyAll.Add($path)
      if ($baseDirty.ContainsKey($path)) { continue }
      if (Test-TaskActionEvidencePathWorth -Path $path -RepoRoot $RepoRoot -BridgeRoot $BridgeRoot) {
        [void]$dirtyWorth.Add($path)
      }
    }
  } catch {}

  return [pscustomobject]@{
    has_actions      = [bool]($commitWorth.Count -gt 0 -or $dirtyWorth.Count -gt 0)
    head_changed     = [bool]$headChanged
    committed_worthy = @($commitWorth.ToArray())
    dirty_worthy     = @($dirtyWorth.ToArray())
    dirty_all        = @($dirtyAll.ToArray())
    head             = [string]$head
  }
}
