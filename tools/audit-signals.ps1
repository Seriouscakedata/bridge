param(
  [string]$BridgePath = $null,
  [int]$WindowHours = 24
)

function Get-Prop {
  param(
    [object]$Object,
    [string]$Name,
    [object]$Default = $null
  )

  if ($null -eq $Object) { return $Default }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop -or $null -eq $prop.Value) { return $Default }
  return $prop.Value
}

function Get-StringValue {
  param(
    [object]$Object,
    [string]$Name,
    [string]$Default = "unknown"
  )

  $value = Get-Prop -Object $Object -Name $Name -Default $Default
  if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
    return $Default
  }
  return [string]$value
}

function Get-DoubleValue {
  param(
    [object]$Object,
    [string]$Name,
    [double]$Default = 0
  )

  $value = Get-Prop -Object $Object -Name $Name -Default $Default
  if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
    return $Default
  }

  try {
    return [double]$value
  } catch {
    return $Default
  }
}

function Get-Int64Value {
  param(
    [object]$Object,
    [string]$Name,
    [Int64]$Default = 0
  )

  $value = Get-Prop -Object $Object -Name $Name -Default $Default
  if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
    return $Default
  }

  try {
    return [Int64]$value
  } catch {
    return $Default
  }
}

function ConvertTo-UtcDateTime {
  param([object]$Value)

  if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
    return $null
  }

  try {
    $styles = [System.Globalization.DateTimeStyles]::AssumeLocal
    return ([System.DateTimeOffset]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles)).UtcDateTime
  } catch {
    try {
      return ([datetime]$Value).ToUniversalTime()
    } catch {
      return $null
    }
  }
}

function ConvertFrom-CircuitBreakerStamp {
  param([string]$Stamp)

  try {
    $styles = [System.Globalization.DateTimeStyles]::AssumeLocal
    return ([datetime]::ParseExact($Stamp, "yyyyMMdd_HHmmss", [System.Globalization.CultureInfo]::InvariantCulture, $styles)).ToUniversalTime()
  } catch {
    return $null
  }
}

function Test-InWindow {
  param([Nullable[datetime]]$Timestamp)

  if ($null -eq $Timestamp) { return $false }
  return $Timestamp -ge $script:WindowFrom
}

function Read-JsonLines {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "source not found: $Path"
  }

  $rows = New-Object System.Collections.Generic.List[object]
  $lineNo = 0
  Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop | ForEach-Object {
    $lineNo++
    $line = [string]$_
    if ([string]::IsNullOrWhiteSpace($line)) {
      return
    }

    try {
      $rows.Add(($line | ConvertFrom-Json -ErrorAction Stop)) | Out-Null
    } catch {
      throw "invalid json in $Path at line ${lineNo}: $($_.Exception.Message)"
    }
  }

  return @($rows.ToArray())
}

function Add-Count {
  param(
    [hashtable]$Map,
    [string]$Key
  )

  if ([string]::IsNullOrWhiteSpace($Key)) {
    $Key = "unknown"
  }

  if (-not $Map.ContainsKey($Key)) {
    $Map[$Key] = 0
  }
  $Map[$Key] = [int]$Map[$Key] + 1
}

function Add-Sum {
  param(
    [hashtable]$Map,
    [string]$Key,
    [double]$Value
  )

  if ([string]::IsNullOrWhiteSpace($Key)) {
    $Key = "unknown"
  }

  if (-not $Map.ContainsKey($Key)) {
    $Map[$Key] = 0.0
  }
  $Map[$Key] = [double]$Map[$Key] + $Value
}

function Convert-CountMapToOrdered {
  param([hashtable]$Map)

  $ordered = [ordered]@{}
  $keys = [string[]]@($Map.Keys)
  [array]::Sort($keys, [System.StringComparer]::Ordinal)
  foreach ($key in $keys) {
    $ordered[$key] = [int]$Map[$key]
  }
  return $ordered
}

function Convert-SumMapToOrdered {
  param(
    [hashtable]$Map,
    [int]$Digits = 6
  )

  $ordered = [ordered]@{}
  $keys = [string[]]@($Map.Keys)
  [array]::Sort($keys, [System.StringComparer]::Ordinal)
  foreach ($key in $keys) {
    $ordered[$key] = [Math]::Round([double]$Map[$key], $Digits)
  }
  return $ordered
}

function Get-DominantKey {
  param([hashtable]$Map)

  if ($Map.Count -eq 0) {
    return $null
  }

  $bestKey = $null
  $bestCount = -1
  $keys = [string[]]@($Map.Keys)
  [array]::Sort($keys, [System.StringComparer]::Ordinal)
  foreach ($key in $keys) {
    $count = [int]$Map[$key]
    if ($count -gt $bestCount) {
      $bestKey = $key
      $bestCount = $count
    }
  }
  return $bestKey
}

function Join-Reasons {
  param([string[]]$Reasons)

  $filtered = @($Reasons | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($filtered.Count -eq 0) {
    return $null
  }
  return ($filtered -join "; ")
}

function New-SignalDocument {
  param(
    [string]$Quality,
    [AllowNull()][object]$Reason,
    [object]$Signals
  )

  return [ordered]@{
    generated_at = $script:WindowTo.ToString("o")
    window_from = $script:WindowFrom.ToString("o")
    window_to = $script:WindowTo.ToString("o")
    data_quality = $Quality
    degraded_reason = $Reason
    signals = $Signals
  }
}

function Write-JsonAtomic {
  param(
    [string]$Path,
    [object]$Payload
  )

  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }

  $tmp = Join-Path $dir (".{0}.{1}.tmp" -f ([System.IO.Path]::GetFileName($Path)), ([guid]::NewGuid().ToString("N")))
  $json = $Payload | ConvertTo-Json -Depth 20
  [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Build-IncidentSignals {
  $restartsPath = Join-Path $script:RuntimeRoot "restarts.jsonl"
  $restartRows = @()
  $restartCounts = @{}
  $cbActivations = 0
  $restartsReadable = $false
  $cbReadable = $false
  $reasons = @()

  try {
    foreach ($row in (Read-JsonLines -Path $restartsPath)) {
      $ts = ConvertTo-UtcDateTime (Get-Prop -Object $row -Name "ts")
      if (Test-InWindow -Timestamp $ts) {
        $cause = Get-StringValue -Object $row -Name "cause"
        Add-Count -Map $restartCounts -Key $cause
        $restartRows += [pscustomobject]@{
          ts = $ts
          cause = $cause
          detail = [string](Get-Prop -Object $row -Name "detail" -Default "")
        }
      }
    }
    $restartsReadable = $true
  } catch {
    $reasons += "restarts.jsonl unreadable: $($_.Exception.Message)"
  }

  try {
    if (-not (Test-Path -LiteralPath $script:RuntimeRoot -PathType Container)) {
      throw "runtime root not found: $script:RuntimeRoot"
    }

    $cbFiles = Get-ChildItem -LiteralPath $script:RuntimeRoot -Filter "circuit-breaker.*" -File -ErrorAction Stop
    foreach ($file in $cbFiles) {
      $parts = $file.Name -split "\.", 2
      if ($parts.Count -lt 2) {
        continue
      }

      $ts = ConvertFrom-CircuitBreakerStamp -Stamp $parts[1]
      if (Test-InWindow -Timestamp $ts) {
        $cbActivations++
      }
    }
    $cbReadable = $true
  } catch {
    $reasons += "circuit-breaker files unreadable: $($_.Exception.Message)"
  }

  if ($restartsReadable -and $cbReadable) {
    $quality = "full"
    $reason = $null
  } elseif ($restartsReadable -or $cbReadable) {
    $quality = "partial"
    $reason = Join-Reasons -Reasons $reasons
  } else {
    $quality = "degraded"
    $reason = Join-Reasons -Reasons $reasons
  }

  $recentRestarts = @(
    $restartRows |
      Sort-Object @{ Expression = "ts"; Descending = $true }, @{ Expression = "cause"; Ascending = $true } |
      Select-Object -First 10 |
      ForEach-Object {
        [ordered]@{
          ts = $_.ts.ToString("o")
          cause = $_.cause
          detail = $_.detail
        }
      }
  )

  $signals = [ordered]@{
    total_restarts = [int]$restartRows.Count
    restarts_by_cause = Convert-CountMapToOrdered -Map $restartCounts
    dominant_cause = Get-DominantKey -Map $restartCounts
    cb_activations = [int]$cbActivations
    recent_restarts = $recentRestarts
  }

  return New-SignalDocument -Quality $quality -Reason $reason -Signals $signals
}

function Build-SpeedSignals {
  $turnsPath = Join-Path $script:BridgeRoot "turns.jsonl"
  $metricsPath = Join-Path $script:BridgeRoot "metrics.jsonl"
  $probePath = Join-Path $script:RuntimeRoot "probe-durations.jsonl"

  $turnRows = @()
  $turnsByMode = @{}
  $turnsBySpeaker = @{}
  $turnsReadable = $false
  $metricsReadable = $false
  $latestSnapshotAvgSec = $null
  $latestSnapshotTimeoutPct = $null
  $probeComputedMs = $null
  $probeActualMs = $null
  $reasons = @()

  try {
    foreach ($row in (Read-JsonLines -Path $turnsPath)) {
      $ts = ConvertTo-UtcDateTime (Get-Prop -Object $row -Name "ts")
      if (Test-InWindow -Timestamp $ts) {
        $mode = Get-StringValue -Object $row -Name "mode"
        $speaker = Get-StringValue -Object $row -Name "speaker"
        Add-Count -Map $turnsByMode -Key $mode
        Add-Count -Map $turnsBySpeaker -Key $speaker
        $turnRows += [pscustomobject]@{
          ts = $ts
          speaker = $speaker
          mode = $mode
          sec = Get-DoubleValue -Object $row -Name "sec"
          status = Get-StringValue -Object $row -Name "status"
        }
      }
    }
    $turnsReadable = $true
  } catch {
    $reasons += "turns.jsonl unreadable: $($_.Exception.Message)"
  }

  try {
    $snapshots = @()
    foreach ($row in (Read-JsonLines -Path $metricsPath)) {
      if ((Get-StringValue -Object $row -Name "type" -Default "") -ne "snapshot") {
        continue
      }

      $ts = ConvertTo-UtcDateTime (Get-Prop -Object $row -Name "ts")
      if (Test-InWindow -Timestamp $ts) {
        $snapshots += [pscustomobject]@{
          ts = $ts
          avg_sec = Get-DoubleValue -Object $row -Name "avg_sec"
          timeout_pct = Get-DoubleValue -Object $row -Name "timeout_pct"
        }
      }
    }

    $latest = @($snapshots | Sort-Object @{ Expression = "ts"; Descending = $true } | Select-Object -First 1)
    if ($latest.Count -gt 0) {
      $latestSnapshotAvgSec = [Math]::Round([double]$latest[0].avg_sec, 2)
      $latestSnapshotTimeoutPct = [Math]::Round([double]$latest[0].timeout_pct, 2)
    }
    $metricsReadable = $true
  } catch {
    $reasons += "metrics.jsonl unreadable: $($_.Exception.Message)"
  }

  try {
    $probes = @()
    foreach ($row in (Read-JsonLines -Path $probePath)) {
      $ts = ConvertTo-UtcDateTime (Get-Prop -Object $row -Name "ts")
      if (Test-InWindow -Timestamp $ts) {
        $probes += [pscustomobject]@{
          ts = $ts
          computed_timeout_ms = Get-Int64Value -Object $row -Name "computed_timeout_ms"
          actual_duration_ms = Get-Int64Value -Object $row -Name "actual_duration_ms"
        }
      }
    }

    $latestProbe = @($probes | Sort-Object @{ Expression = "ts"; Descending = $true } | Select-Object -First 1)
    if ($latestProbe.Count -gt 0) {
      $probeComputedMs = [Int64]$latestProbe[0].computed_timeout_ms
      $probeActualMs = [Int64]$latestProbe[0].actual_duration_ms
    }
  } catch {
    $reasons += "probe-durations.jsonl unreadable: $($_.Exception.Message)"
  }

  if ($turnsReadable -and $metricsReadable) {
    $quality = "full"
    $reason = $null
  } elseif ($turnsReadable -or $metricsReadable) {
    $quality = "partial"
    $reason = Join-Reasons -Reasons $reasons
  } else {
    $quality = "degraded"
    $reason = Join-Reasons -Reasons $reasons
  }

  $totalTurns = [int]$turnRows.Count
  $avgSec = 0
  $p95Sec = 0
  $timeoutPct = 0
  $successPct = 0
  $fastLanePct = 0

  if ($totalTurns -gt 0) {
    $secs = [double[]]@($turnRows | ForEach-Object { [double]$_.sec })
    $avgSec = [Math]::Round((($secs | Measure-Object -Average).Average), 2)
    $sortedSecs = [double[]]@($secs | Sort-Object)
    $p95Index = [Math]::Ceiling($totalTurns * 0.95) - 1
    if ($p95Index -lt 0) { $p95Index = 0 }
    if ($p95Index -ge $totalTurns) { $p95Index = $totalTurns - 1 }
    $p95Sec = [Math]::Round($sortedSecs[$p95Index], 2)

    $timeoutCount = @($turnRows | Where-Object { $_.status -ne "ok" }).Count
    $successCount = @($turnRows | Where-Object { $_.status -eq "ok" }).Count
    $fastCount = @($turnRows | Where-Object { $_.mode -eq "fast" }).Count
    $timeoutPct = [Math]::Round(($timeoutCount / $totalTurns) * 100, 2)
    $successPct = [Math]::Round(($successCount / $totalTurns) * 100, 2)
    $fastLanePct = [Math]::Round(($fastCount / $totalTurns) * 100, 2)
  }

  $signals = [ordered]@{
    total_turns = $totalTurns
    avg_sec = $avgSec
    p95_sec = $p95Sec
    timeout_pct = $timeoutPct
    success_pct = $successPct
    fast_lane_pct = $fastLanePct
    turns_by_mode = Convert-CountMapToOrdered -Map $turnsByMode
    turns_by_speaker = Convert-CountMapToOrdered -Map $turnsBySpeaker
    latest_snapshot_avg_sec = $latestSnapshotAvgSec
    latest_snapshot_timeout_pct = $latestSnapshotTimeoutPct
    probe_computed_ms = $probeComputedMs
    probe_actual_ms = $probeActualMs
  }

  return New-SignalDocument -Quality $quality -Reason $reason -Signals $signals
}

function Build-CostSignals {
  $usagePath = Join-Path $script:BridgeRoot "usage.jsonl"
  $usageRows = @()
  $costByProvider = @{}
  $costByPurpose = @{}
  $modelMap = @{}
  $usageReadable = $false
  $reasons = @()

  try {
    foreach ($row in (Read-JsonLines -Path $usagePath)) {
      $ts = ConvertTo-UtcDateTime (Get-Prop -Object $row -Name "ts")
      if (Test-InWindow -Timestamp $ts) {
        $cost = Get-DoubleValue -Object $row -Name "cost_usd"
        $provider = Get-StringValue -Object $row -Name "provider"
        $purpose = Get-StringValue -Object $row -Name "purpose"
        $model = Get-StringValue -Object $row -Name "model"
        Add-Sum -Map $costByProvider -Key $provider -Value $cost
        Add-Sum -Map $costByPurpose -Key $purpose -Value $cost

        if (-not $modelMap.ContainsKey($model)) {
          $modelMap[$model] = [pscustomobject]@{
            model = $model
            cost = 0.0
            calls = 0
          }
        }
        $modelMap[$model].cost = [double]$modelMap[$model].cost + $cost
        $modelMap[$model].calls = [int]$modelMap[$model].calls + 1

        $usageRows += [pscustomobject]@{
          prompt_tokens = Get-Int64Value -Object $row -Name "prompt_tokens"
          completion_tokens = Get-Int64Value -Object $row -Name "completion_tokens"
          cost_usd = $cost
          kind = Get-StringValue -Object $row -Name "kind"
        }
      }
    }
    $usageReadable = $true
  } catch {
    $reasons += "usage.jsonl unreadable: $($_.Exception.Message)"
  }

  if (-not $usageReadable) {
    $quality = "degraded"
    $reason = Join-Reasons -Reasons $reasons
  } elseif ($usageRows.Count -eq 0) {
    $quality = "partial"
    $reason = "usage.jsonl readable but no rows in window"
  } else {
    $quality = "full"
    $reason = $null
  }

  $totalCost = 0.0
  $totalPromptTokens = [Int64]0
  $totalCompletionTokens = [Int64]0
  $paidCalls = 0
  $prepaidCalls = 0

  foreach ($row in $usageRows) {
    $totalCost += [double]$row.cost_usd
    $totalPromptTokens += [Int64]$row.prompt_tokens
    $totalCompletionTokens += [Int64]$row.completion_tokens
    if ($row.kind -eq "paid") { $paidCalls++ }
    if ($row.kind -eq "prepaid") { $prepaidCalls++ }
  }

  $topModels = @(
    $modelMap.Values |
      Sort-Object @{ Expression = "cost"; Descending = $true }, @{ Expression = "model"; Ascending = $true } |
      Select-Object -First 5 |
      ForEach-Object {
        [ordered]@{
          model = $_.model
          cost_usd = [Math]::Round([double]$_.cost, 6)
          calls = [int]$_.calls
        }
      }
  )

  $signals = [ordered]@{
    total_cost_usd = [Math]::Round($totalCost, 6)
    total_prompt_tokens = $totalPromptTokens
    total_completion_tokens = $totalCompletionTokens
    paid_calls = [int]$paidCalls
    prepaid_calls = [int]$prepaidCalls
    cost_by_provider = Convert-SumMapToOrdered -Map $costByProvider -Digits 6
    cost_by_purpose = Convert-SumMapToOrdered -Map $costByPurpose -Digits 6
    top_models = $topModels
  }

  return New-SignalDocument -Quality $quality -Reason $reason -Signals $signals
}

if ($BridgePath -and (Test-Path -LiteralPath $BridgePath)) {
  $script:BridgeRoot = (Resolve-Path -LiteralPath $BridgePath).Path
} else {
  $script:BridgeRoot = Split-Path -Parent $PSScriptRoot
}

$script:RuntimeRoot = Join-Path $env:USERPROFILE ".bridge-runtime"
$now = Get-Date
$script:WindowTo = $now.ToUniversalTime()
$script:WindowFrom = $now.AddHours(-$WindowHours).ToUniversalTime()
$signalsDir = Join-Path $script:BridgeRoot "audit\signals"
New-Item -ItemType Directory -Force -Path $signalsDir | Out-Null

$incident = Build-IncidentSignals
$speed = Build-SpeedSignals
$cost = Build-CostSignals

Write-JsonAtomic -Path (Join-Path $signalsDir "incident.json") -Payload $incident
Write-JsonAtomic -Path (Join-Path $signalsDir "speed.json") -Payload $speed
Write-JsonAtomic -Path (Join-Path $signalsDir "cost.json") -Payload $cost

Write-Output ("[signals] incident: {0} | speed: {1} | cost: {2}" -f $incident.data_quality, $speed.data_quality, $cost.data_quality)
exit 0
