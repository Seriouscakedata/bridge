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

function Test-TaskCoveredVerifiedDoneEvidence {
  param([AllowNull()][string]$Reply)

  if ([string]::IsNullOrWhiteSpace($Reply)) { return $false }

  if ($Reply -notmatch '(?im)^\s*STATUS:\s*DONE\b') { return $false }

  $coveredMatches = [regex]::Matches($Reply, '(?im)^\s*COVERED:\s*(.+?)\s*$')
  if ($coveredMatches.Count -eq 0) { return $false }

  $verifiedMatches = [regex]::Matches($Reply, '(?is)\[\[VERIFIED:\s*(.*?)\]\]')
  if ($verifiedMatches.Count -eq 0) { return $false }

  $coveredText = (($coveredMatches | ForEach-Object { [string]$_.Groups[1].Value }) -join "`n")
  $verifiedText = (($verifiedMatches | ForEach-Object { [string]$_.Groups[1].Value }) -join "`n")
  $allEvidence = ($coveredText + "`n" + $verifiedText)

  $hasCommitSha = ($allEvidence -imatch '\b(commit|HEAD|sha)\b.{0,80}\b[0-9a-f]{7,40}\b') -or
                  ($allEvidence -imatch '\b[0-9a-f]{7,40}\b.{0,80}\b(commit|HEAD|sha)\b')
  if (-not $hasCommitSha) { return $false }

  $hasVerification = ($verifiedText -imatch '\b(smoke(\.ps1)?|selftest|test|verify|verification|провер\w*)\b') -and
                     ($verifiedText -imatch '\b(PASS|OK|passed|success|успеш|прош[её]л|пройден)\b')
  if (-not $hasVerification) { return $false }

  return $true
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

function Resolve-BacklogItemRepoRoots {
  # Returns ordered list of git repo paths to try when verifying a SHA for a backlog item.
  # Priority: done_qa_pass_repo -> declared_repo -> infer from abs files paths -> $BridgeRoot.
  param(
    [object]$Item,
    [string]$BridgeRoot
  )
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $candidates = [System.Collections.Generic.List[string]]::new()
  $addRepo = {
    param([string]$p)
    if ([string]::IsNullOrWhiteSpace($p)) { return }
    try { $p = [System.IO.Path]::GetFullPath($p) } catch { return }
    if (-not $seen.Add($p)) { return }
    if (Test-Path -LiteralPath (Join-Path $p '.git')) { [void]$candidates.Add($p) }
  }
  try {
    foreach ($field in @('done_qa_pass_repo', 'declared_repo')) {
      if ($Item -and ($Item.PSObject.Properties.Name -contains $field)) {
        & $addRepo ([string]($Item.PSObject.Properties[$field].Value)).Trim()
      }
    }
    if ($Item -and ($Item.PSObject.Properties.Name -contains 'files')) {
      foreach ($f in @($Item.files)) {
        $fs = ([string]$f).Trim()
        if ([string]::IsNullOrWhiteSpace($fs) -or -not [System.IO.Path]::IsPathRooted($fs)) { continue }
        $dir = [System.IO.Path]::GetDirectoryName($fs)
        while (-not [string]::IsNullOrWhiteSpace($dir)) {
          if (Test-Path -LiteralPath (Join-Path $dir '.git')) { & $addRepo $dir; break }
          $parent = [System.IO.Path]::GetDirectoryName($dir)
          if ($parent -eq $dir) { break }
          $dir = $parent
        }
      }
    }
  } catch {}
  & $addRepo $BridgeRoot
  return @($candidates)
}

function Test-TaskDoneQaPassCommitEvidence {
  # Read-only. Returns $true when the backlog item identified by $BacklogId carries a
  # done_qa_pass_commit SHA that resolves to a real commit in one of the item's repo roots.
  # Mirrors the post-restart fast-path in driver/86-loop-completion-checks.ps1 so the
  # mode-transition DONE evidence gate (driver/85) does not raise a false
  # missing_action_evidence when task_base_commit was reset to HEAD after a restart
  # (head_changed=false -> has_actions=false) yet a confirmed QA-passed commit already
  # exists for the task. Fail-closed: any error / missing field / bad SHA returns $false.
  param(
    [AllowNull()][string]$BacklogId = '',
    [string]$BridgeRoot = ''
  )
  if ([string]::IsNullOrWhiteSpace($BacklogId)) { return $false }
  if ([string]::IsNullOrWhiteSpace($BridgeRoot)) { return $false }
  try {
    $item = @(Get-Backlog) | Where-Object { [string]$_.id -eq $BacklogId } | Select-Object -First 1
    if (-not $item) { return $false }
    if (-not ($item.PSObject.Properties.Name -contains 'done_qa_pass_commit')) { return $false }
    $sha = ([string]$item.done_qa_pass_commit).Trim()
    if ([string]::IsNullOrWhiteSpace($sha)) { return $false }
    $repos = Resolve-BacklogItemRepoRoots -Item $item -BridgeRoot $BridgeRoot
    foreach ($repo in $repos) {
      try {
        $out = ([string](& git -C $repo rev-parse --verify ($sha + '^{commit}') 2>$null | Out-String)).Trim()
        if (-not [string]::IsNullOrWhiteSpace($out)) { return $true }
      } catch {}
    }
    return $false
  } catch {
    return $false
  }
}

function Get-TaskCompletionRecoverableValue {
  param(
    [object]$Object,
    [string]$Name
  )
  if ($null -eq $Object -or [string]::IsNullOrWhiteSpace($Name)) { return $null }
  if ($Object -is [hashtable]) {
    if ($Object.ContainsKey($Name)) { return $Object[$Name] }
    return $null
  }
  try {
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
  } catch {}
  return $null
}

function ConvertTo-TaskCompletionRecoverableEpoch {
  param([object]$Value)
  if ($null -eq $Value) { return $null }
  $text = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  $longValue = 0L
  if ([Int64]::TryParse($text, [ref]$longValue)) { return $longValue }
  try {
    return [datetimeoffset]::Parse($text).ToUniversalTime().ToUnixTimeSeconds()
  } catch {
    return $null
  }
}

function Get-TaskCompletionRecoverableStartedAt {
  param(
    [object]$State,
    [string]$BacklogId
  )
  if ($null -eq $State -or [string]::IsNullOrWhiteSpace($BacklogId)) { return '' }
  $started = Get-TaskCompletionRecoverableValue -Object $State -Name 'task_started_at'
  if ($null -eq $started) { return '' }
  if ($started -is [string]) {
    $activeId = [string](Get-TaskCompletionRecoverableValue -Object $State -Name 'current_backlog_id')
    if ($activeId.Equals($BacklogId, [System.StringComparison]::OrdinalIgnoreCase)) { return ([string]$started).Trim() }
    return ''
  }
  if ($started -is [System.Collections.IDictionary]) {
    if ($started.Contains($BacklogId)) { return ([string]$started[$BacklogId]).Trim() }
    return ''
  }
  try {
    $prop = $started.PSObject.Properties[$BacklogId]
    if ($null -ne $prop) { return ([string]$prop.Value).Trim() }
  } catch {}
  return ''
}

function New-TaskCompletionRecoverableResult {
  param(
    [string]$Verdict,
    [string]$Reason,
    [string]$TaskId = '',
    [string]$Head = '',
    [string]$QaHead = '',
    [Nullable[Int64]]$CommitTs = $null,
    [Nullable[Int64]]$CriticTs = $null,
    [string]$Repo = ''
  )
  return [pscustomobject]@{
    verdict   = [string]$Verdict
    reason    = [string]$Reason
    task_id   = [string]$TaskId
    head      = [string]$Head
    qa_head   = [string]$QaHead
    commit_ts = $CommitTs
    critic_ts = $CriticTs
    repo      = [string]$Repo
  }
}

function Test-TaskCompletionRecoverable {
  # Pure/read-only. Fail-closed restart recovery evidence:
  # exact [task:<id>] HEAD commit, clean tree, worthy changed path, QA PASS on HEAD,
  # and critic OK/none at or after the commit timestamp.
  param(
    [object]$State,
    [string]$BacklogId,
    [string]$BridgeRoot = '',
    [string[]]$RepoRoots = @()
  )

  if ([string]::IsNullOrWhiteSpace($BacklogId)) {
    return (New-TaskCompletionRecoverableResult -Verdict 'INSUFFICIENT_EVIDENCE' -Reason 'missing_task_id')
  }
  if ([string]::IsNullOrWhiteSpace($BridgeRoot)) {
    return (New-TaskCompletionRecoverableResult -Verdict 'INSUFFICIENT_EVIDENCE' -Reason 'missing_bridge_root' -TaskId $BacklogId)
  }

  $applyRestarts = 0
  $hardRestarts = 0
  try { $applyRestarts = [int](Get-TaskCompletionRecoverableValue -Object $State -Name 'task_apply_restart_count') } catch { $applyRestarts = 0 }
  try { $hardRestarts = [int](Get-TaskCompletionRecoverableValue -Object $State -Name 'task_hard_restart_count') } catch { $hardRestarts = 0 }
  if (($applyRestarts + $hardRestarts) -le 0) {
    return (New-TaskCompletionRecoverableResult -Verdict 'NOT_RECOVERABLE' -Reason 'no_restart' -TaskId $BacklogId)
  }

  $startedAt = Get-TaskCompletionRecoverableStartedAt -State $State -BacklogId $BacklogId
  $startedEpoch = ConvertTo-TaskCompletionRecoverableEpoch -Value $startedAt
  if ($null -eq $startedEpoch) {
    return (New-TaskCompletionRecoverableResult -Verdict 'INSUFFICIENT_EVIDENCE' -Reason 'missing_task_started_at' -TaskId $BacklogId)
  }

  $qa = Get-TaskCompletionRecoverableValue -Object $State -Name 'qa_verdict_cache'
  $qaVerdict = [string](Get-TaskCompletionRecoverableValue -Object $qa -Name 'verdict')
  $qaHead = ([string](Get-TaskCompletionRecoverableValue -Object $qa -Name 'head')).Trim()
  if ($qaVerdict -ne 'PASS' -or [string]::IsNullOrWhiteSpace($qaHead)) {
    return (New-TaskCompletionRecoverableResult -Verdict 'INSUFFICIENT_EVIDENCE' -Reason 'missing_qa_pass' -TaskId $BacklogId -QaHead $qaHead)
  }

  $critic = Get-TaskCompletionRecoverableValue -Object $State -Name 'critic_verdict_cache'
  $criticVerdict = [string](Get-TaskCompletionRecoverableValue -Object $critic -Name 'verdict')
  $criticSeverity = [string](Get-TaskCompletionRecoverableValue -Object $critic -Name 'severity')
  $criticTs = ConvertTo-TaskCompletionRecoverableEpoch -Value (Get-TaskCompletionRecoverableValue -Object $critic -Name 'ts')
  if ($criticVerdict -ne 'OK' -or $criticSeverity -ne 'none' -or $null -eq $criticTs) {
    return (New-TaskCompletionRecoverableResult -Verdict 'INSUFFICIENT_EVIDENCE' -Reason 'missing_fresh_critic' -TaskId $BacklogId -QaHead $qaHead -CriticTs $criticTs)
  }

  $repoList = New-Object 'System.Collections.Generic.List[string]'
  $seen = @{}
  foreach ($candidate in @($RepoRoots + @($BridgeRoot))) {
    $repo = ([string]$candidate).Trim()
    if ([string]::IsNullOrWhiteSpace($repo)) { continue }
    try { $repo = [System.IO.Path]::GetFullPath($repo).TrimEnd('\','/') } catch { continue }
    $key = $repo.ToLowerInvariant()
    if (-not $seen.ContainsKey($key)) {
      $seen[$key] = $true
      [void]$repoList.Add($repo)
    }
  }
  if ($repoList.Count -eq 0) {
    return (New-TaskCompletionRecoverableResult -Verdict 'INSUFFICIENT_EVIDENCE' -Reason 'missing_repo' -TaskId $BacklogId -QaHead $qaHead -CriticTs $criticTs)
  }

  $marker = '[task:' + $BacklogId + ']'
  foreach ($repo in @($repoList.ToArray())) {
    if (-not (Test-Path -LiteralPath $repo -PathType Container)) { continue }
    $head = ''
    try { $head = ((& git -C $repo rev-parse HEAD 2>$null) | Select-Object -First 1).Trim() } catch { $head = '' }
    if ([string]::IsNullOrWhiteSpace($head)) { continue }

    $dirty = ''
    try { $dirty = ([string]((& git -C $repo status --porcelain -uall 2>$null) | Out-String)).Trim() } catch { return (New-TaskCompletionRecoverableResult -Verdict 'INSUFFICIENT_EVIDENCE' -Reason 'status_failed' -TaskId $BacklogId -Head $head -QaHead $qaHead -CriticTs $criticTs -Repo $repo) }
    if ($dirty -ne '') {
      return (New-TaskCompletionRecoverableResult -Verdict 'NOT_RECOVERABLE' -Reason 'dirty_tree' -TaskId $BacklogId -Head $head -QaHead $qaHead -CriticTs $criticTs -Repo $repo)
    }

    $subject = ''
    $commitTs = $null
    try {
      $subject = ([string]((& git -C $repo log -1 --format=%s HEAD 2>$null) | Out-String)).Trim()
      $commitTsText = ([string]((& git -C $repo log -1 --format=%ct HEAD 2>$null) | Out-String)).Trim()
      $commitTs = ConvertTo-TaskCompletionRecoverableEpoch -Value $commitTsText
    } catch {
      return (New-TaskCompletionRecoverableResult -Verdict 'INSUFFICIENT_EVIDENCE' -Reason 'head_log_failed' -TaskId $BacklogId -Head $head -QaHead $qaHead -CriticTs $criticTs -Repo $repo)
    }
    if ($null -eq $commitTs) {
      return (New-TaskCompletionRecoverableResult -Verdict 'INSUFFICIENT_EVIDENCE' -Reason 'missing_commit_ts' -TaskId $BacklogId -Head $head -QaHead $qaHead -CriticTs $criticTs -Repo $repo)
    }
    if ($commitTs -lt $startedEpoch) { continue }
    if ($subject.IndexOf($marker, [System.StringComparison]::Ordinal) -lt 0) { continue }

    if (-not $qaHead.Equals($head, [System.StringComparison]::OrdinalIgnoreCase)) {
      return (New-TaskCompletionRecoverableResult -Verdict 'NOT_RECOVERABLE' -Reason 'qa_head_mismatch' -TaskId $BacklogId -Head $head -QaHead $qaHead -CommitTs $commitTs -CriticTs $criticTs -Repo $repo)
    }
    if ($criticTs -lt $commitTs) {
      return (New-TaskCompletionRecoverableResult -Verdict 'NOT_RECOVERABLE' -Reason 'critic_before_commit' -TaskId $BacklogId -Head $head -QaHead $qaHead -CommitTs $commitTs -CriticTs $criticTs -Repo $repo)
    }

    $worthyCount = 0
    try {
      foreach ($path in @(& git -C $repo diff-tree --no-commit-id --name-only -r --root HEAD 2>$null)) {
        $p = ([string]$path).Trim() -replace '\\','/'
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (Test-TaskActionEvidencePathWorth -Path $p -RepoRoot $repo -BridgeRoot $BridgeRoot) { $worthyCount++ }
      }
    } catch {
      return (New-TaskCompletionRecoverableResult -Verdict 'INSUFFICIENT_EVIDENCE' -Reason 'changed_paths_failed' -TaskId $BacklogId -Head $head -QaHead $qaHead -CommitTs $commitTs -CriticTs $criticTs -Repo $repo)
    }
    if ($worthyCount -le 0) {
      return (New-TaskCompletionRecoverableResult -Verdict 'NOT_RECOVERABLE' -Reason 'no_worthy_paths' -TaskId $BacklogId -Head $head -QaHead $qaHead -CommitTs $commitTs -CriticTs $criticTs -Repo $repo)
    }

    return (New-TaskCompletionRecoverableResult -Verdict 'RECOVER_DONE' -Reason 'exact_task_head_qa_critic' -TaskId $BacklogId -Head $head -QaHead $qaHead -CommitTs $commitTs -CriticTs $criticTs -Repo $repo)
  }

  return (New-TaskCompletionRecoverableResult -Verdict 'NOT_RECOVERABLE' -Reason 'no_exact_task_head_commit' -TaskId $BacklogId -QaHead $qaHead -CriticTs $criticTs)
}

function Write-TaskCompletionRecoveryAudit {
  param(
    [string]$BridgeRoot = '',
    [string]$TaskId = '',
    [string]$Decision = '',
    [object]$Verdict = $null,
    [bool]$FlagState = $false,
    [string]$Site = ''
  )
  if ([string]::IsNullOrWhiteSpace($BridgeRoot)) { return }
  try {
    $logDir = Join-Path $BridgeRoot 'logs'
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $record = [ordered]@{
      ts         = (Get-Date).ToUniversalTime().ToString('o')
      site       = [string]$Site
      task_id    = [string]$TaskId
      decision   = [string]$Decision
      verdict    = if ($null -ne $Verdict) { [string]$Verdict.verdict } else { '' }
      reason     = if ($null -ne $Verdict) { [string]$Verdict.reason } else { '' }
      head       = if ($null -ne $Verdict) { [string]$Verdict.head } else { '' }
      qa_head    = if ($null -ne $Verdict) { [string]$Verdict.qa_head } else { '' }
      commit_ts  = if ($null -ne $Verdict -and $null -ne $Verdict.commit_ts) { [Int64]$Verdict.commit_ts } else { $null }
      critic_ts  = if ($null -ne $Verdict -and $null -ne $Verdict.critic_ts) { [Int64]$Verdict.critic_ts } else { $null }
      flag_state = [bool]$FlagState
    }
    Add-Content -LiteralPath (Join-Path $logDir 'task-completion-recovery.jsonl') -Value ($record | ConvertTo-Json -Compress -Depth 5) -Encoding UTF8
  } catch {}
}

function Get-TaskDoneEvidenceDecision {
  # Pure, deterministic decision for the driver/85 mode-transition DONE evidence gate.
  # Returns { allow; reason } describing whether a planner DONE may pass without fresh
  # commit/diff evidence and why. Order is significant and mirrors the original inline
  # chain: non-backlog / autopilot / backlog-created bypasses first, then the fail-closed
  # evidence_check_failed guard, then positive evidence signals (action -> covered-verified
  # -> done_qa_pass_commit). Default is fail-closed: allow=$false, reason=missing_action_evidence.
  param(
    [bool]$HasBacklogId,
    [bool]$ProjectAutopilot,
    [int]$ProjectBacklogCreated = 0,
    [bool]$EvidenceChecked,
    [bool]$HasEvidence,
    [bool]$HasCoveredVerifiedEvidence,
    [bool]$HasDoneQaPassCommit
  )
  $allow = $false
  $reason = 'missing_action_evidence'
  if (-not $HasBacklogId) {
    $allow = $true; $reason = 'not_backlog_task'
  } elseif ($ProjectAutopilot) {
    $allow = $true; $reason = 'project_autopilot'
  } elseif ($ProjectBacklogCreated -gt 0) {
    $allow = $true; $reason = 'project_backlog_created'
  } elseif (-not $EvidenceChecked) {
    $reason = 'evidence_check_failed'
  } elseif ($HasEvidence) {
    $allow = $true; $reason = 'action_evidence'
  } elseif ($HasCoveredVerifiedEvidence) {
    $allow = $true; $reason = 'covered_verified_evidence'
  } elseif ($HasDoneQaPassCommit) {
    $allow = $true; $reason = 'done_qa_pass_commit_evidence'
  }
  return [pscustomobject]@{ allow = [bool]$allow; reason = [string]$reason }
}

function Write-DiffIntegrityDecision {
  # Writes decisions/diff-integrity-<ts>.json for DONE-gate commit-to-diff integrity check.
  param(
    [string]$CommitSha,
    [string]$BridgeRoot,
    [object]$CheckResult,
    [string[]]$DeclaredFiles = @(),
    [string]$BacklogId = ''
  )
  try {
    $ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss_fff')
    $decDir = Join-Path $BridgeRoot 'decisions'
    if (-not (Test-Path $decDir -PathType Container)) { New-Item -ItemType Directory -Path $decDir -Force | Out-Null }
    $decPath = Join-Path $decDir "diff-integrity-$ts.json"
    $record = [ordered]@{
      ts             = (Get-Date).ToUniversalTime().ToString('o')
      commit_sha     = [string]$CommitSha
      backlog_id     = [string]$BacklogId
      declared_files = @($DeclaredFiles)
      changed_files  = @(if ($null -ne $CheckResult -and $null -ne $CheckResult.changedFiles) { $CheckResult.changedFiles } else { @() })
      overlap        = @(if ($null -ne $CheckResult -and $null -ne $CheckResult.overlap) { $CheckResult.overlap } else { @() })
      result         = if ($null -ne $CheckResult -and [bool]$CheckResult.ok) { 'ok' } else { 'failed' }
      reason         = if ($null -ne $CheckResult) { [string]$CheckResult.reason } else { 'unknown' }
    }
    [System.IO.File]::WriteAllText($decPath, ($record | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($true)))
    return $decPath
  } catch {
    return $null
  }
}
