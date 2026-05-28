param(
  [Parameter(Position = 0)]
  [string]$TaskId,
  [switch]$List,
  [switch]$Full,
  [string]$Role,
  [int]$Turn = -1,
  [Alias('?')]
  [switch]$Help
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Show-Usage {
  Write-Host "Использование:"
  Write-Host "  bridge replay --list"
  Write-Host "  bridge replay <task_id> [--role planner] [--turn 1] [--full]"
  Write-Host ""
  Write-Host "Показывает сохраненные agent-вызовы из replay/<task_id>/."
  Write-Host "Фильтры: --role <role>, --turn <n>. Полный текст: --full."
}

function Limit-Text {
  param(
    [AllowNull()][object]$Value,
    [int]$Limit = 200
  )
  if ($null -eq $Value) { return '' }
  $text = [string]$Value
  $text = $text -replace "`r", '\r' -replace "`n", '\n'
  if ($text.Length -le $Limit) { return $text }
  $left = $text.Substring(0, $Limit)
  $extra = $text.Length - $Limit
  return "$left [...+$extra chars]"
}

function Limit-Cell {
  param(
    [AllowNull()][object]$Value,
    [int]$Limit
  )
  if ($null -eq $Value) { return '' }
  $text = [string]$Value
  $text = $text -replace "`r", ' ' -replace "`n", ' '
  if ($text.Length -le $Limit) { return $text }
  if ($Limit -le 3) { return $text.Substring(0, $Limit) }
  return ($text.Substring(0, $Limit - 3) + '...')
}

function Format-Cost {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return '-' }
  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text)) { return '-' }
  try {
    $decimalValue = [System.Convert]::ToDecimal($Value, $InvariantCulture)
    return ('$' + $decimalValue.ToString('0.######', $InvariantCulture))
  } catch {
    return ('$' + $text)
  }
}

function Read-JsonFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
  } catch {
    Write-Warning "Не удалось прочитать JSON: $Path"
    return $null
  }
}

function Get-ReplayTurnFromFileName {
  param([string]$Name)
  if ($Name -match '^(\d+)-') { return [int]$Matches[1] }
  return [int]::MaxValue
}

function Show-ReplayList {
  param([string]$Root)
  if (-not (Test-Path -LiteralPath $Root)) {
    Write-Host "Replay-папка не найдена: $Root"
    Write-Host "Total: 0 tasks"
    return
  }

  $dirs = @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
  Write-Host ("{0,-28} | {1,-20} | {2,-10} | {3,5} | {4,8} | {5}" -f 'TaskId', 'Started', 'Status', 'Turns', 'Cost', 'TaskText')
  Write-Host ("{0,-28}-+-{1,-20}-+-{2,-10}-+-{3,5}-+-{4,8}-+-{5}" -f ('-' * 28), ('-' * 20), ('-' * 10), ('-' * 5), ('-' * 8), ('-' * 40))

  $count = 0
  foreach ($dir in $dirs) {
    $meta = Read-JsonFile -Path (Join-Path $dir.FullName '_meta.json')
    if ($null -eq $meta) {
      $started = ''
      $status = '<no meta>'
      $turns = ''
      $cost = ''
      $taskText = ''
    } else {
      $started = Limit-Cell -Value $meta.started_at -Limit 20
      $status = Limit-Cell -Value $meta.status -Limit 10
      $turns = [string]$meta.turn_count
      $cost = if ($null -eq $meta.total_cost_usd) { '' } else { ([System.Convert]::ToDecimal($meta.total_cost_usd, $InvariantCulture)).ToString('0.######', $InvariantCulture) }
      $taskText = Limit-Cell -Value $meta.task_text -Limit 40
    }
    Write-Host ("{0,-28} | {1,-20} | {2,-10} | {3,5} | {4,8} | {5}" -f $dir.Name, $started, $status, $turns, $cost, $taskText)
    $count++
  }
  Write-Host "Total: $count tasks"
}

function Show-TaskReplay {
  param(
    [string]$Root,
    [string]$Id,
    [string]$RoleFilter,
    [int]$TurnFilter,
    [bool]$ShowFull
  )

  $taskDir = Join-Path $Root $Id
  if (-not (Test-Path -LiteralPath $taskDir)) {
    Write-Host "Task not found. Try: bridge replay --list" -ForegroundColor Red
    exit 1
  }

  $meta = Read-JsonFile -Path (Join-Path $taskDir '_meta.json')
  Write-Host "TaskId: $Id"
  if ($null -ne $meta) {
    Write-Host "channel: $($meta.channel)"
    Write-Host "started_at: $($meta.started_at)"
    Write-Host "finished_at: $($meta.finished_at)"
    Write-Host "status: $($meta.status)"
    Write-Host "turn_count: $($meta.turn_count)"
    Write-Host "total_cost_usd: $($meta.total_cost_usd)"
    Write-Host "task_text: $($meta.task_text)"
  } else {
    Write-Host "_meta.json: не найден или не читается" -ForegroundColor Yellow
  }
  Write-Host ""

  $files = @(Get-ChildItem -LiteralPath $taskDir -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
    Sort-Object @{ Expression = { Get-ReplayTurnFromFileName -Name $_.Name } }, @{ Expression = { $_.Name } })

  if ($files.Count -eq 0) {
    Write-Host "Нет записей turn'ов."
    return
  }

  $printed = 0
  foreach ($file in $files) {
    $lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -ErrorAction SilentlyContinue)
    foreach ($line in $lines) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try {
        $rec = $line | ConvertFrom-Json
      } catch {
        Write-Warning "Битая JSONL-строка: $($file.Name)"
        continue
      }

      if (-not [string]::IsNullOrWhiteSpace($RoleFilter)) {
        if ([string]$rec.role -ne $RoleFilter) { continue }
      }
      if ($TurnFilter -ge 0) {
        if ([int]$rec.turn -ne $TurnFilter) { continue }
      }

      $status = [string]$rec.status
      $lineText = "[t$($rec.turn)] $($rec.role) | $($rec.model) | $($rec.latency_ms)ms | cost=$(Format-Cost $rec.cost_usd) | $status"
      if ($status -match '^(ok|success|done)$') {
        Write-Host $lineText
      } elseif ($status -match '(?i)(error|fail|timeout|abort)') {
        Write-Host $lineText -ForegroundColor Red
      } else {
        Write-Host $lineText -ForegroundColor Yellow
      }

      if ($ShowFull) {
        Write-Host "--- PROMPT ---"
        Write-Host ([string]$rec.prompt)
        Write-Host ""
        Write-Host "--- RESPONSE ---"
        Write-Host ([string]$rec.response)
      } else {
        Write-Host ("prompt: " + (Limit-Text -Value $rec.prompt -Limit 200))
        Write-Host ("response: " + (Limit-Text -Value $rec.response -Limit 200))
      }
      Write-Host "---"
      $printed++
    }
  }

  if ($printed -eq 0) {
    Write-Host "Нет записей, подходящих под фильтры."
  }
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$replayRoot = Join-Path $repoRoot 'replay'

if ($Help -or (-not $List -and [string]::IsNullOrWhiteSpace($TaskId))) {
  Show-Usage
  exit 0
}

if ($List) {
  Show-ReplayList -Root $replayRoot
  exit 0
}

Show-TaskReplay -Root $replayRoot -Id $TaskId -RoleFilter $Role -TurnFilter $Turn -ShowFull ([bool]$Full)
