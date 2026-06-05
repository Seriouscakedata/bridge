# task-action-evidence.ps1 -- deterministic evidence that a coder turn changed repository state.

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
  return $true
}

function Test-TaskActionEvidenceBypassMarker {
  param([string]$Reply)
  if ([string]::IsNullOrWhiteSpace($Reply)) { return $false }
  return [bool]([regex]::IsMatch([string]$Reply, '(?im)^\s*COVERED:\s*'))
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

function Get-TaskDoneEvidenceGateDecision {
  param(
    [bool]$HasBacklogId = $false,
    [bool]$HasEvidence = $false,
    [bool]$HasCoveredMarker = $false,
    [bool]$IsProjectAutopilot = $false,
    [int]$ProjectBacklogCreated = 0
  )

  $allowed = (-not $HasBacklogId) -or $HasEvidence -or $HasCoveredMarker -or $IsProjectAutopilot -or ($ProjectBacklogCreated -gt 0)
  $reason = if ($allowed) {
    if (-not $HasBacklogId) { 'not_backlog_task' }
    elseif ($HasEvidence) { 'action_evidence' }
    elseif ($HasCoveredMarker) { 'covered_marker' }
    elseif ($IsProjectAutopilot) { 'project_autopilot' }
    else { 'project_backlog_created' }
  } else {
    'missing_action_evidence'
  }

  return [pscustomobject]@{
    allowed = [bool]$allowed
    reason  = [string]$reason
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
