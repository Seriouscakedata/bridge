# checkpoint.ps1 -- Reads, writes, and clears per-task checkpoint records under the bridge channel.
function Get-TaskCheckpointBridgeRoot {
  try {
    return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
  } catch {
    return (Split-Path -Parent $PSScriptRoot)
  }
}

function Get-TaskCheckpointChannel {
  param([string]$Channel)
  if (-not [string]::IsNullOrWhiteSpace($Channel)) { return $Channel }
  if (-not [string]::IsNullOrWhiteSpace($env:BRIDGE_CHANNEL)) { return [string]$env:BRIDGE_CHANNEL }
  return 'main'
}

function Get-TaskCheckpointPath {
  param(
    [string]$TaskId,
    [string]$Channel = ''
  )
  if ([string]::IsNullOrWhiteSpace($TaskId)) { return $null }
  $bridge = Get-TaskCheckpointBridgeRoot
  $channelName = Get-TaskCheckpointChannel -Channel $Channel
  $dir = Join-Path (Join-Path (Join-Path $bridge 'channels') $channelName) 'checkpoints'
  return (Join-Path $dir ([string]$TaskId + '.jsonl'))
}

function Protect-TaskCheckpointText {
  param(
    [AllowNull()][string]$Text,
    [int]$MaxLength = 4000
  )
  if ($null -eq $Text) { return '' }
  if ($MaxLength -le 0) { $MaxLength = 4000 }
  $out = [string]$Text
  $out = $out -replace '(?im)(Authorization\s*:\s*(?:Basic|Bearer)\s+)[A-Za-z0-9+/=._-]+', '$1<redacted>'
  $out = $out -replace '(?i)(password|passwd|pwd|token|secret|api[-_ ]?key|apikey|bearer)(["''\s:=]+)([^"''\s,;]+)', '$1$2<redacted>'
  $out = $out -replace '(?i)\b(sk-[A-Za-z0-9_-]{8,}|AIza[0-9A-Za-z_-]{20,}|gh[pousr]_[0-9A-Za-z_]{20,})\b', '<redacted-secret>'
  $out = $out -replace '(?i)(secrets\.json|auth\.json)[^\r\n]*', '$1 <redacted-path-context>'
  if ($out.Length -gt $MaxLength) { $out = $out.Substring(0, $MaxLength) }
  return $out
}

function Write-TaskCheckpointLog {
  param(
    [string]$BridgeRoot = '',
    [string]$Message = ''
  )
  try {
    $root = [string]$BridgeRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = Get-TaskCheckpointBridgeRoot }
    if ([string]::IsNullOrWhiteSpace($root)) { return }
    $path = Join-Path $root 'checkpoint.log'
    $safeMessage = Protect-TaskCheckpointText -Text $Message -MaxLength 800
    $line = (Get-Date).ToString('s') + '  ' + $safeMessage + "`n"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($path, $line, $utf8NoBom)
  } catch {}
}

function Limit-TaskCheckpointFile {
  param(
    [string]$Path,
    [int]$MaxRecords = 20
  )
  if ([string]::IsNullOrWhiteSpace($Path) -or $MaxRecords -le 0) { return }
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
  try {
    $lines = @([System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($lines.Count -le $MaxRecords) { return }
    $tail = @($lines | Select-Object -Last $MaxRecords)
    $content = ($tail -join "`n") + "`n"
    [System.IO.File]::WriteAllText($Path, $content, (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

function Get-TaskCheckpointRestoreKey {
  param([object]$Checkpoint)
  if ($null -eq $Checkpoint) { return '' }
  $parts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($name in @('ts','reason','step','head')) {
    try {
      if ($Checkpoint.PSObject.Properties.Name -contains $name -and $null -ne $Checkpoint.PSObject.Properties[$name].Value) {
        [void]$parts.Add([string]$Checkpoint.PSObject.Properties[$name].Value)
      }
    } catch {}
  }
  return [string]::Join('|', $parts.ToArray())
}

function Write-TaskCheckpoint {
  param(
    [string]$TaskId,
    [string]$TaskTitle = '',
    [int]$Step = 0,
    [string]$LastSummary = '',
    [string]$Channel = '',
    [string]$Reason = 'continue',
    [string]$Prompt = '',
    [string]$Context = '',
    [object]$Artifacts = $null,
    [string]$Head = ''
  )

  $path = Get-TaskCheckpointPath -TaskId $TaskId -Channel $Channel
  if ([string]::IsNullOrWhiteSpace($path)) { return }

  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $summary = Protect-TaskCheckpointText -Text ([string]$LastSummary) -MaxLength 500
  $promptText = Protect-TaskCheckpointText -Text ([string]$Prompt) -MaxLength 4000
  $contextText = Protect-TaskCheckpointText -Text ([string]$Context) -MaxLength 3000
  $artifactSnapshot = $Artifacts
  if ($null -eq $artifactSnapshot) { $artifactSnapshot = @{} }
  $row = [pscustomobject]@{
    ts          = (Get-Date).ToString('o')
    taskId      = [string]$TaskId
    taskTitle   = Protect-TaskCheckpointText -Text ([string]$TaskTitle) -MaxLength 500
    step        = [int]$Step
    lastSummary = $summary
    reason      = [string]$Reason
    prompt      = $promptText
    context     = $contextText
    artifacts   = $artifactSnapshot
    head        = [string]$Head
  }
  $line = ($row | ConvertTo-Json -Compress -Depth 8)
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::AppendAllText($path, $line + "`n", $utf8NoBom)
  Limit-TaskCheckpointFile -Path $path -MaxRecords 20
  return $row
}

function Read-TaskCheckpoint {
  param(
    [string]$TaskId,
    [string]$Channel = ''
  )

  $path = Get-TaskCheckpointPath -TaskId $TaskId -Channel $Channel
  if ([string]::IsNullOrWhiteSpace($path)) { return $null }
  if (-not (Test-Path -LiteralPath $path)) { return $null }

  try {
    $last = $null
    foreach ($line in [System.IO.File]::ReadLines($path)) {
      if (-not [string]::IsNullOrWhiteSpace($line)) { $last = $line }
    }
    if ([string]::IsNullOrWhiteSpace($last)) { return $null }
    return ($last | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Clear-TaskCheckpoint {
  param(
    [string]$TaskId,
    [string]$Channel = ''
  )

  if ([string]::IsNullOrWhiteSpace($TaskId)) {
    try {
      if (Get-Command Update-State -ErrorAction SilentlyContinue) {
        Update-State {
          param($s)
          $s | Add-Member -NotePropertyName task_checkpoints -NotePropertyValue @() -Force
          $s | Add-Member -NotePropertyName task_last_failure -NotePropertyValue $null -Force
        } | Out-Null
      }
    } catch {}
    return
  }

  $path = Get-TaskCheckpointPath -TaskId $TaskId -Channel $Channel
  if ([string]::IsNullOrWhiteSpace($path)) { return }
  try {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}

function Get-TaskCheckpointIdFromState {
  param([object]$State)
  if ($null -eq $State) { return '' }
  $taskId = ''
  try { $taskId = [string]$State.current_task_id } catch {}
  if ([string]::IsNullOrWhiteSpace($taskId)) { try { $taskId = [string]$State.current_backlog_id } catch {} }
  if ([string]::IsNullOrWhiteSpace($taskId)) {
    $seq = 0
    try { $seq = [int]$State.task_start_seq } catch {}
    if ($seq -gt 0) { $taskId = 'task-' + [string]$seq }
  }
  return $taskId
}

function Test-TaskCheckpointDue {
  param(
    [object]$State,
    [int]$IntervalMinutes = 5,
    [switch]$Force
  )
  if ($Force) { return $true }
  if ($null -eq $State) { return $false }
  if ($IntervalMinutes -le 0) { $IntervalMinutes = 5 }
  $last = ''
  try { $last = [string]$State.last_task_checkpoint_at } catch {}
  if ([string]::IsNullOrWhiteSpace($last)) { return $true }
  try {
    $lastDt = [datetime]$last
    return (((Get-Date) - $lastDt).TotalMinutes -ge $IntervalMinutes)
  } catch {
    return $true
  }
}

function Save-TaskCheckpointFromState {
  param(
    [object]$State,
    [string]$TaskTitle = '',
    [string]$Channel = '',
    [string]$Reason = 'periodic',
    [string]$Prompt = '',
    [string]$Context = ''
  )
  if ($null -eq $State) { return $null }
  $taskId = Get-TaskCheckpointIdFromState -State $State
  if ([string]::IsNullOrWhiteSpace($taskId)) { return $null }
  $step = 0
  try { $step = [int]$State.task_turn } catch {}
  $summary = [string]$Context
  if ([string]::IsNullOrWhiteSpace($summary)) {
    try {
      if (Get-Command Read-Summary -ErrorAction SilentlyContinue) { $summary = [string](Read-Summary) }
    } catch {}
  }
  $head = ''
  try {
    $root = Get-TaskCheckpointBridgeRoot
    $head = ((& git -C $root rev-parse HEAD 2>$null) | Select-Object -First 1).Trim()
  } catch {}
  $artifacts = [ordered]@{
    current_backlog_id = ''
    task_mode = ''
    active_agent = ''
    status_text = ''
    workpack_batch_ids = @()
    progress_fingerprints = @()
  }
  try { $artifacts.current_backlog_id = [string]$State.current_backlog_id } catch {}
  try { $artifacts.task_mode = [string]$State.task_mode } catch {}
  try { $artifacts.active_agent = [string]$State.active_agent } catch {}
  try { $artifacts.status_text = [string]$State.status_text } catch {}
  try { $artifacts.workpack_batch_ids = @($State.workpack_batch_ids | ForEach-Object { [string]$_ }) } catch {}
  try { $artifacts.progress_fingerprints = @($State.progress_fingerprints | ForEach-Object { [string]$_ }) } catch {}

  return Write-TaskCheckpoint -TaskId $taskId -TaskTitle $TaskTitle -Step $step -LastSummary $summary -Channel $Channel -Reason $Reason -Prompt $Prompt -Context $summary -Artifacts $artifacts -Head $head
}

function Format-TaskCheckpointRestoreText {
  param([object]$Checkpoint)
  if ($null -eq $Checkpoint) { return '' }
  $parts = New-Object 'System.Collections.Generic.List[string]'
  try { if ($Checkpoint.ts) { [void]$parts.Add('ts=' + [string]$Checkpoint.ts) } } catch {}
  try { if ($Checkpoint.reason) { [void]$parts.Add('reason=' + [string]$Checkpoint.reason) } } catch {}
  try { if ($Checkpoint.step -ne $null) { [void]$parts.Add('step=' + [string]$Checkpoint.step) } } catch {}
  try { if ($Checkpoint.head) { [void]$parts.Add('head=' + [string]$Checkpoint.head) } } catch {}
  $summary = ''
  try { $summary = [string]$Checkpoint.lastSummary } catch {}
  if ([string]::IsNullOrWhiteSpace($summary)) { try { $summary = [string]$Checkpoint.context } catch {} }
  if ($summary.Length -gt 900) { $summary = $summary.Substring(0, 900) }
  $artifactText = ''
  try {
    if ($Checkpoint.artifacts) {
      $artifactText = ($Checkpoint.artifacts | ConvertTo-Json -Compress -Depth 5)
      if ($artifactText.Length -gt 900) { $artifactText = $artifactText.Substring(0, 900) }
    }
  } catch {}
  return @"
=== TASK CHECKPOINT/RESTORE ===
Последний чекпоинт: $([string]::Join('; ', $parts.ToArray()))
Краткий контекст: $summary
Артефакты: $artifactText
Продолжай с этого состояния; не начинай задачу заново, если контекст применим.
=== END TASK CHECKPOINT/RESTORE ===
"@.Trim()
}
