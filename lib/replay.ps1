# Replay capture for agent turns. JSONL files are intentionally UTF-8 without BOM.

function Write-ReplayInternalError {
  param([string]$Message)
  try {
    $root = Get-BridgeRoot
    $ctl = Join-Path $root 'control'
    if (-not (Test-Path -LiteralPath $ctl)) { New-Item -ItemType Directory -Path $ctl -Force | Out-Null }
    $line = ((Get-Date).ToString('o') + " " + $Message)
    Add-Content -LiteralPath (Join-Path $ctl 'replay-errors.log') -Value $line -Encoding UTF8
  } catch {}
}

function Get-ReplayTaskHash {
  param([string]$TaskText)
  try {
    if ($null -eq $TaskText) { $TaskText = '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$TaskText)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      $hashBytes = $sha.ComputeHash($bytes)
      $hex = [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
      return $hex.Substring(0, 8)
    } finally {
      if ($sha) { $sha.Dispose() }
    }
  } catch {
    Write-ReplayInternalError ("Get-ReplayTaskHash: " + $_.Exception.Message)
    return '00000000'
  }
}

function New-ReplayTaskId {
  param([string]$TaskText)
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
  $hash = Get-ReplayTaskHash -TaskText $TaskText
  return ($stamp + '-' + $hash)
}

function Get-ReplayTaskDir {
  param([string]$TaskId)
  if ([string]::IsNullOrWhiteSpace($TaskId)) { return $null }
  try {
    $safeTaskId = ([string]$TaskId) -replace '[^A-Za-z0-9_.-]', '_'
    $dir = Join-Path (Join-Path (Get-BridgeRoot) 'replay') $safeTaskId
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
  } catch {
    Write-ReplayInternalError ("Get-ReplayTaskDir: " + $_.Exception.Message)
    return $null
  }
}

function ConvertTo-ReplaySafeText {
  param([AllowNull()][object]$Value)
  try {
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    $patterns = @(
      '(?i)(authorization|api[_-]?key|token|secret)\s*[:=]\s*[''"]?[A-Za-z0-9._:/+=-]{8,}',
      '(?i)\bBearer\s+[A-Za-z0-9._/+=-]{8,}',
      '\bsk-[A-Za-z0-9._-]{8,}'
    )
    foreach ($pat in $patterns) {
      $text = [regex]::Replace($text, $pat, '***REDACTED***')
    }
    return $text
  } catch {
    Write-ReplayInternalError ("ConvertTo-ReplaySafeText: " + $_.Exception.Message)
    return ''
  }
}

function Get-ReplayTaskMeta {
  param([string]$TaskId)
  if ([string]::IsNullOrWhiteSpace($TaskId)) { return $null }
  try {
    $dir = Get-ReplayTaskDir -TaskId $TaskId
    if ([string]::IsNullOrWhiteSpace($dir)) { return $null }
    $path = Join-Path $dir '_meta.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
  } catch {
    Write-ReplayInternalError ("Get-ReplayTaskMeta: " + $_.Exception.Message)
    return $null
  }
}

function Save-ReplayTaskMeta {
  param(
    [string]$TaskId,
    [hashtable]$Meta
  )
  if ([string]::IsNullOrWhiteSpace($TaskId)) { return }
  try {
    $dir = Get-ReplayTaskDir -TaskId $TaskId
    if ([string]::IsNullOrWhiteSpace($dir)) { return }
    $existing = Get-ReplayTaskMeta -TaskId $TaskId
    $merged = [ordered]@{
      task_id        = $TaskId
      task_text      = ''
      started_at     = $null
      finished_at    = $null
      status         = 'in_progress'
      turn_count     = 0
      total_cost_usd = 0
      channel        = ''
    }
    if ($existing) {
      foreach ($p in $existing.PSObject.Properties) {
        if ($merged.Contains($p.Name)) { $merged[$p.Name] = $p.Value }
        else { $merged[$p.Name] = $p.Value }
      }
    }
    if ($Meta) {
      foreach ($key in $Meta.Keys) {
        $merged[[string]$key] = $Meta[$key]
      }
    }
    $merged['task_id'] = $TaskId
    $json = $merged | ConvertTo-Json -Depth 6
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $dir '_meta.json'), $json + "`n", $utf8NoBom)
  } catch {
    Write-ReplayInternalError ("Save-ReplayTaskMeta: " + $_.Exception.Message)
  }
}

function Add-ReplayRecord {
  param(
    [string]$TaskId,
    [int]$Turn,
    [string]$Role,
    [string]$Model,
    [AllowNull()][string]$Mode,
    [AllowNull()][object]$Prompt,
    [AllowNull()][object]$Response,
    [int]$LatencyMs,
    [AllowNull()][object]$CostUsd,
    [string]$Status,
    [AllowNull()][string]$ErrorType,
    [string]$Provider
  )
  if ([string]::IsNullOrWhiteSpace($TaskId)) { return }
  try {
    $dir = Get-ReplayTaskDir -TaskId $TaskId
    if ([string]::IsNullOrWhiteSpace($dir)) { return }
    $safeRole = if ([string]::IsNullOrWhiteSpace($Role)) { 'agent' } else { ([string]$Role) -replace '[^A-Za-z0-9_.-]', '_' }
    $baseName = ([string]$Turn + '-' + $safeRole)
    $path = Join-Path $dir ($baseName + '.jsonl')
    $suffix = 2
    while (Test-Path -LiteralPath $path) {
      $path = Join-Path $dir ($baseName + '-' + $suffix + '.jsonl')
      $suffix++
    }

    $costValue = $null
    if ($null -ne $CostUsd -and -not [string]::IsNullOrWhiteSpace([string]$CostUsd)) {
      try { $costValue = [decimal]$CostUsd } catch { $costValue = $null }
    }

    $record = [ordered]@{
      ts         = (Get-Date).ToString('o')
      task_id    = $TaskId
      turn       = $Turn
      role       = [string]$Role
      model      = [string]$Model
      mode       = if ($null -eq $Mode) { $null } else { [string]$Mode }
      prompt     = ConvertTo-ReplaySafeText -Value $Prompt
      response   = ConvertTo-ReplaySafeText -Value $Response
      latency_ms = $LatencyMs
      cost_usd   = $costValue
      status     = [string]$Status
      error_type = if ($null -eq $ErrorType) { $null } else { [string]$ErrorType }
      provider   = [string]$Provider
    }
    $jsonLine = $record | ConvertTo-Json -Compress -Depth 6
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $jsonLine + "`n", $utf8NoBom)

    $meta = Get-ReplayTaskMeta -TaskId $TaskId
    $metaPatch = @{}
    $currentTurnCount = 0
    if ($meta -and $null -ne $meta.turn_count) {
      try { $currentTurnCount = [int]$meta.turn_count } catch { $currentTurnCount = 0 }
    }
    if ($Turn -gt $currentTurnCount) {
      $metaPatch['turn_count'] = $Turn
    }
    if ($null -ne $costValue) {
      $total = [decimal]0
      if ($meta -and $null -ne $meta.total_cost_usd) {
        try { $total = [decimal]$meta.total_cost_usd } catch { $total = [decimal]0 }
      }
      $metaPatch['total_cost_usd'] = ($total + $costValue)
    }
    if ($metaPatch.Count -gt 0) {
      Save-ReplayTaskMeta -TaskId $TaskId -Meta $metaPatch
    }
  } catch {
    Write-ReplayInternalError ("Add-ReplayRecord: " + $_.Exception.Message)
  }
}

function Add-ReplayRecordForCurrentTask {
  param(
    [string]$Role,
    [string]$Model,
    [AllowNull()][string]$Mode,
    [AllowNull()][object]$Prompt,
    [AllowNull()][object]$Response,
    [int]$LatencyMs,
    [AllowNull()][object]$CostUsd,
    [string]$Status,
    [AllowNull()][string]$ErrorType,
    [string]$Provider
  )
  try {
    $state = Read-State
    if (-not $state) { return }
    $taskId = [string]$state.current_task_id
    if ([string]::IsNullOrWhiteSpace($taskId)) { return }
    $turn = 0
    try { $turn = [int]$state.task_turn } catch { $turn = 0 }
    Add-ReplayRecord -TaskId $taskId -Turn $turn -Role $Role -Model $Model -Mode $Mode `
      -Prompt $Prompt -Response $Response -LatencyMs $LatencyMs -CostUsd $CostUsd `
      -Status $Status -ErrorType $ErrorType -Provider $Provider
  } catch {
    Write-ReplayInternalError ("Add-ReplayRecordForCurrentTask: " + $_.Exception.Message)
  }
}
