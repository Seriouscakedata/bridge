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

function Write-TaskCheckpoint {
  param(
    [string]$TaskId,
    [string]$TaskTitle = '',
    [int]$Step = 0,
    [string]$LastSummary = '',
    [string]$Channel = ''
  )

  $path = Get-TaskCheckpointPath -TaskId $TaskId -Channel $Channel
  if ([string]::IsNullOrWhiteSpace($path)) { return }

  $dir = Split-Path -Parent $path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $summary = [string]$LastSummary
  if ($summary.Length -gt 500) { $summary = $summary.Substring(0, 500) }
  $row = [pscustomobject]@{
    ts          = (Get-Date).ToString('o')
    taskId      = [string]$TaskId
    taskTitle   = [string]$TaskTitle
    step        = [int]$Step
    lastSummary = $summary
  }
  $line = ($row | ConvertTo-Json -Compress -Depth 5)
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::AppendAllText($path, $line + "`n", $utf8NoBom)
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
    return ($last | ConvertFrom-Json -Depth 5)
  } catch {
    return $null
  }
}

function Clear-TaskCheckpoint {
  param(
    [string]$TaskId,
    [string]$Channel = ''
  )

  $path = Get-TaskCheckpointPath -TaskId $TaskId -Channel $Channel
  if ([string]::IsNullOrWhiteSpace($path)) { return }
  try {
    if (Test-Path -LiteralPath $path) {
      Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
  } catch {}
}
