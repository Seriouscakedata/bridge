param(
  [AllowNull()][string]$BridgePath = $null,
  [ValidateRange(1, 8760)][int]$WindowHours = 24
)

$ErrorActionPreference = "Stop"

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

  $rows = New-Object 'System.Collections.Generic.List[object]'
  $errors = New-Object 'System.Collections.Generic.List[string]'
  $lineNo = 0
  $stream = $null
  $reader = $null

  try {
    $share = [System.IO.FileShare]([int][System.IO.FileShare]::ReadWrite -bor [int][System.IO.FileShare]::Delete)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
    $utf8 = New-Object System.Text.UTF8Encoding($false, $false)
    $reader = New-Object System.IO.StreamReader($stream, $utf8, $true)

    while ($true) {
      $line = $reader.ReadLine()
      if ($null -eq $line) { break }
      $lineNo++
      if ([string]::IsNullOrWhiteSpace($line)) {
        continue
      }

      try {
        [void]$rows.Add(($line | ConvertFrom-Json -ErrorAction Stop))
      } catch {
        [void]$errors.Add("line ${lineNo}: $($_.Exception.Message)")
      }
    }
  } catch {
    throw "read failed for ${Path}: $($_.Exception.Message)"
  } finally {
    if ($null -ne $reader) { $reader.Close() }
    elseif ($null -ne $stream) { $stream.Close() }
  }

  return [pscustomobject]@{
    Rows = @($rows.ToArray())
    Errors = @($errors.ToArray())
  }
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

function Add-ReadWarnings {
  param(
    [System.Collections.Generic.List[string]]$Reasons,
    [object]$ReadResult,
    [string]$SourceName
  )

  $count = @($ReadResult.Errors).Count
  if ($count -gt 0) {
    [void]$Reasons.Add("${SourceName} partial: $count malformed jsonl line(s)")
  }
}

function Join-Reasons {
  param([object]$Reasons)

  $filtered = @($Reasons | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($filtered.Count -eq 0) {
    return $null
  }
  return ($filtered -join "; ")
}

function ConvertTo-SignalJson {
  param([object]$Payload)

  $jsonOutput = $Payload | ConvertTo-Json -Depth 20 -ErrorAction Stop
  if ($jsonOutput -is [array]) {
    $jsonText = [string]($jsonOutput -join [Environment]::NewLine)
  } else {
    $jsonText = [string]$jsonOutput
  }
  if ([string]::IsNullOrWhiteSpace($jsonText)) {
    throw "ConvertTo-Json produced empty output"
  }

  [void]($jsonText | ConvertFrom-Json -ErrorAction Stop)
  return ($jsonText.TrimEnd() + [Environment]::NewLine)
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
  try {
    $jsonText = ConvertTo-SignalJson -Payload $Payload
    [System.IO.File]::WriteAllText($tmp, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
  } catch {
    try { if (Test-Path -LiteralPath $tmp -PathType Leaf) { Remove-Item -LiteralPath $tmp -Force } } catch {}
    throw
  }
}

function Build-IncidentSignals {
  $restartsPath = Join-Path $script:RuntimeRoot "restarts.jsonl"
  $restartRows = New-Object 'System.Collections.Generic.List[object]'
  $restartCounts = @{}
  $cbActivations = 0
  $restartsReadable = $false
  $cbReadable = $false
  $hasPartialData = $false
  $reasons = New-Object 'System.Collections.Generic.List[string]'

  try {
    $readResult = Read-JsonLines -Path $restartsPath
    if (@($readResult.Errors).Count -gt 0) {
      $hasPartialData = $true
      Add-ReadWarnings -Reasons $reasons -ReadResult $readResult -SourceName "restarts.jsonl"
    }

    foreach ($row in $readResult.Rows) {
      $ts = ConvertTo-UtcDateTime (Get-Prop -Object $row -Name "ts")
      if (Test-InWindow -Timestamp $ts) {
        $cause = Get-StringValue -Object $row -Name "cause"
        Add-Count -Map $restartCounts -Key $cause
        [void]$restartRows.Add([pscustomobject]@{
          ts = $ts
          cause = $cause
          detail = [string](Get-Prop -Object $row -Name "detail" -Default "")
        })
      }
    }
    $restartsReadable = $true
  } catch {
    [void]$reasons.Add("restarts.jsonl unreadable: $($_.Exception.Message)")
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
    [void]$reasons.Add("circuit-breaker files unreadable: $($_.Exception.Message)")
  }

  if ($restartsReadable -and $cbReadable -and -not $hasPartialData) {
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
    $restartRows.ToArray() |
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

  $turnRows = New-Object 'System.Collections.Generic.List[object]'
  $turnsByMode = @{}
  $turnsBySpeaker = @{}
  $turnsReadable = $false
  $metricsReadable = $false
  $hasPrimaryPartialData = $false
  $latestSnapshotAvgSec = $null
  $latestSnapshotTimeoutPct = $null
  $probeComputedMs = $null
  $probeActualMs = $null
  $reasons = New-Object 'System.Collections.Generic.List[string]'

  try {
    $readResult = Read-JsonLines -Path $turnsPath
    if (@($readResult.Errors).Count -gt 0) {
      $hasPrimaryPartialData = $true
      Add-ReadWarnings -Reasons $reasons -ReadResult $readResult -SourceName "turns.jsonl"
    }

    foreach ($row in $readResult.Rows) {
      $ts = ConvertTo-UtcDateTime (Get-Prop -Object $row -Name "ts")
      if (Test-InWindow -Timestamp $ts) {
        $mode = Get-StringValue -Object $row -Name "mode"
        $speaker = Get-StringValue -Object $row -Name "speaker"
        Add-Count -Map $turnsByMode -Key $mode
        Add-Count -Map $turnsBySpeaker -Key $speaker
        [void]$turnRows.Add([pscustomobject]@{
          ts = $ts
          speaker = $speaker
          mode = $mode
          sec = Get-DoubleValue -Object $row -Name "sec"
          status = Get-StringValue -Object $row -Name "status"
        })
      }
    }
    $turnsReadable = $true
  } catch {
    [void]$reasons.Add("turns.jsonl unreadable: $($_.Exception.Message)")
  }

  try {
    $snapshots = New-Object 'System.Collections.Generic.List[object]'
    $readResult = Read-JsonLines -Path $metricsPath
    if (@($readResult.Errors).Count -gt 0) {
      $hasPrimaryPartialData = $true
      Add-ReadWarnings -Reasons $reasons -ReadResult $readResult -SourceName "metrics.jsonl"
    }

    foreach ($row in $readResult.Rows) {
      if ((Get-StringValue -Object $row -Name "type" -Default "") -ne "snapshot") {
        continue
      }

      $ts = ConvertTo-UtcDateTime (Get-Prop -Object $row -Name "ts")
      if (Test-InWindow -Timestamp $ts) {
        [void]$snapshots.Add([pscustomobject]@{
          ts = $ts
          avg_sec = Get-DoubleValue -Object $row -Name "avg_sec"
          timeout_pct = Get-DoubleValue -Object $row -Name "timeout_pct"
        })
      }
    }

    $latest = @($snapshots.ToArray() | Sort-Object @{ Expression = "ts"; Descending = $true } | Select-Object -First 1)
    if ($latest.Count -gt 0) {
      $latestSnapshotAvgSec = [Math]::Round([double]$latest[0].avg_sec, 2)
      $latestSnapshotTimeoutPct = [Math]::Round([double]$latest[0].timeout_pct, 2)
    }
    $metricsReadable = $true
  } catch {
    [void]$reasons.Add("metrics.jsonl unreadable: $($_.Exception.Message)")
  }

  try {
    $probes = New-Object 'System.Collections.Generic.List[object]'
    $readResult = Read-JsonLines -Path $probePath
    if (@($readResult.Errors).Count -gt 0) {
      Add-ReadWarnings -Reasons $reasons -ReadResult $readResult -SourceName "probe-durations.jsonl"
    }

    foreach ($row in $readResult.Rows) {
      $ts = ConvertTo-UtcDateTime (Get-Prop -Object $row -Name "ts")
      if (Test-InWindow -Timestamp $ts) {
        [void]$probes.Add([pscustomobject]@{
          ts = $ts
          computed_timeout_ms = Get-Int64Value -Object $row -Name "computed_timeout_ms"
          actual_duration_ms = Get-Int64Value -Object $row -Name "actual_duration_ms"
        })
      }
    }

    $latestProbe = @($probes.ToArray() | Sort-Object @{ Expression = "ts"; Descending = $true } | Select-Object -First 1)
    if ($latestProbe.Count -gt 0) {
      $probeComputedMs = [Int64]$latestProbe[0].computed_timeout_ms
      $probeActualMs = [Int64]$latestProbe[0].actual_duration_ms
    }
  } catch {
    [void]$reasons.Add("probe-durations.jsonl unreadable: $($_.Exception.Message)")
  }

  if ($turnsReadable -and $metricsReadable -and -not $hasPrimaryPartialData) {
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
    $turnArray = @($turnRows.ToArray())
    $secs = [double[]]@($turnArray | ForEach-Object { [double]$_.sec })
    $avgSec = [Math]::Round((($secs | Measure-Object -Average).Average), 2)
    $sortedSecs = [double[]]@($secs | Sort-Object)
    $p95Index = [Math]::Ceiling($totalTurns * 0.95) - 1
    if ($p95Index -lt 0) { $p95Index = 0 }
    if ($p95Index -ge $totalTurns) { $p95Index = $totalTurns - 1 }
    $p95Sec = [Math]::Round($sortedSecs[$p95Index], 2)

    $timeoutCount = @($turnArray | Where-Object { $_.status -ne "ok" }).Count
    $successCount = @($turnArray | Where-Object { $_.status -eq "ok" }).Count
    $fastCount = @($turnArray | Where-Object { $_.mode -eq "fast" }).Count
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
  $usageRows = New-Object 'System.Collections.Generic.List[object]'
  $costByProvider = @{}
  $costByPurpose = @{}
  $modelMap = @{}
  $usageReadable = $false
  $hasPartialData = $false
  $reasons = New-Object 'System.Collections.Generic.List[string]'

  try {
    $readResult = Read-JsonLines -Path $usagePath
    if (@($readResult.Errors).Count -gt 0) {
      $hasPartialData = $true
      Add-ReadWarnings -Reasons $reasons -ReadResult $readResult -SourceName "usage.jsonl"
    }

    foreach ($row in $readResult.Rows) {
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

        [void]$usageRows.Add([pscustomobject]@{
          prompt_tokens = Get-Int64Value -Object $row -Name "prompt_tokens"
          completion_tokens = Get-Int64Value -Object $row -Name "completion_tokens"
          cost_usd = $cost
          kind = Get-StringValue -Object $row -Name "kind"
        })
      }
    }
    $usageReadable = $true
  } catch {
    [void]$reasons.Add("usage.jsonl unreadable: $($_.Exception.Message)")
  }

  if (-not $usageReadable) {
    $quality = "degraded"
    $reason = Join-Reasons -Reasons $reasons
  } elseif ($usageRows.Count -eq 0) {
    $quality = "partial"
    $existingReason = Join-Reasons -Reasons $reasons
    if ($existingReason) {
      $reason = "${existingReason}; usage.jsonl readable but no rows in window"
    } else {
      $reason = "usage.jsonl readable but no rows in window"
    }
  } elseif ($hasPartialData) {
    $quality = "partial"
    $reason = Join-Reasons -Reasons $reasons
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

if (-not [string]::IsNullOrWhiteSpace($BridgePath)) {
  if (-not (Test-Path -LiteralPath $BridgePath -PathType Container)) {
    throw "BridgePath not found or not a directory: $BridgePath"
  }
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
