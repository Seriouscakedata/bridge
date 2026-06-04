#Requires -Version 5.1
param(
  [ValidateRange(1, 8760)][int]$WindowHours = 24,
  [string]$BridgeRoot = '',
  [switch]$Full
)

$ErrorActionPreference = 'Stop'

function Resolve-BridgeRoot {
  param([string]$Value)

  if (-not [string]::IsNullOrWhiteSpace($Value)) {
    return [System.IO.Path]::GetFullPath($Value)
  }
  if (-not [string]::IsNullOrWhiteSpace($env:BRIDGE_ROOT)) {
    return [System.IO.Path]::GetFullPath($env:BRIDGE_ROOT)
  }
  if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
    $scriptDir = Split-Path -Parent $PSCommandPath
    if (-not [string]::IsNullOrWhiteSpace($scriptDir)) {
      return [System.IO.Path]::GetFullPath((Join-Path $scriptDir '..'))
    }
  }
  return 'C:\Users\rafie\OneDrive\Documents\bridge'
}

function Get-JsonProp {
  param(
    [object]$Object,
    [string]$Name,
    [object]$Default = $null
  )

  if ($null -eq $Object) { return $Default }
  try {
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -ne $prop -and $null -ne $prop.Value) { return $prop.Value }
  } catch {}
  return $Default
}

function Get-RecordDateUtc {
  param([object]$Value)

  try {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return ([datetimeoffset]::Parse([string]$Value)).UtcDateTime
  } catch {
    return $null
  }
}

function Get-RecordSec {
  param([object]$Value)

  try {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    $n = [double]$Value
    if ([double]::IsNaN($n) -or [double]::IsInfinity($n) -or $n -lt 0) { return $null }
    return $n
  } catch {
    return $null
  }
}

function New-Bucket {
  return [pscustomobject]@{
    Total = 0
    Timeout = 0
    Seconds = New-Object System.Collections.Generic.List[double]
    Status = @{}
  }
}

function Add-BucketRecord {
  param(
    [hashtable]$Buckets,
    [string]$Window,
    [string]$Model,
    [string]$Status,
    [Nullable[double]]$Sec
  )

  $key = "$Window|$Model"
  if (-not $Buckets.ContainsKey($key)) {
    $Buckets[$key] = New-Bucket
  }

  $bucket = $Buckets[$key]
  $bucket.Total++
  if ($Status -eq 'timeout') { $bucket.Timeout++ }
  if ($null -ne $Sec) { [void]$bucket.Seconds.Add([double]$Sec) }
  if (-not $bucket.Status.ContainsKey($Status)) { $bucket.Status[$Status] = 0 }
  $bucket.Status[$Status]++
}

function Get-Average {
  param([System.Collections.Generic.List[double]]$Values)

  if ($null -eq $Values -or $Values.Count -eq 0) { return 0.0 }
  $sum = 0.0
  foreach ($value in $Values) { $sum += $value }
  return ($sum / [double]$Values.Count)
}

function Get-Percentile {
  param(
    [System.Collections.Generic.List[double]]$Values,
    [double]$Percentile = 95.0
  )

  if ($null -eq $Values -or $Values.Count -eq 0) { return 0.0 }
  $items = @($Values | Sort-Object)
  if ($items.Count -eq 1) { return [double]$items[0] }
  $rank = [Math]::Ceiling(($Percentile / 100.0) * [double]$items.Count) - 1
  if ($rank -lt 0) { $rank = 0 }
  if ($rank -ge $items.Count) { $rank = $items.Count - 1 }
  return [double]$items[$rank]
}

function Get-WindowSpecs {
  param(
    [int]$Hours,
    [bool]$IncludeAll
  )

  $specs = New-Object System.Collections.Generic.List[object]
  if ($IncludeAll) {
    [void]$specs.Add([pscustomobject]@{ Name = '1h'; Hours = 1 })
    [void]$specs.Add([pscustomobject]@{ Name = '6h'; Hours = 6 })
    [void]$specs.Add([pscustomobject]@{ Name = '24h'; Hours = 24 })
    [void]$specs.Add([pscustomobject]@{ Name = 'all'; Hours = 0 })
    return $specs
  }

  [void]$specs.Add([pscustomobject]@{ Name = ("{0}h" -f $Hours); Hours = $Hours })
  return $specs
}

function Get-Recommendation {
  param([double]$Rate)

  if ($Rate -ge 40.0) {
    return [pscustomobject]@{
      Action = 'BACKOFF'
      Detail = 'raise retry delay; compatible ladder 3/7/15/31s, consider starting at 30s for this model'
    }
  }
  if ($Rate -ge 20.0) {
    return [pscustomobject]@{
      Action = 'RETRY'
      Detail = 'retry transient failures; keep current backoff ladder 3/7/15/31s'
    }
  }
  return [pscustomobject]@{
    Action = 'OK'
    Detail = 'no timeout-specific action'
  }
}

function Format-Percent {
  param([double]$Value)
  return ('{0:N1}%' -f $Value)
}

function Write-ReportTable {
  param(
    [string]$Title,
    [array]$Rows,
    [string[]]$Columns
  )

  Write-Output ''
  Write-Output $Title
  if ($null -eq $Rows -or $Rows.Count -eq 0) {
    Write-Output '  no data'
    return
  }
  $Rows | Format-Table -Property $Columns -AutoSize | Out-String -Width 240 | Write-Output
}

try {
  $root = Resolve-BridgeRoot -Value $BridgeRoot
  $turnsPath = Join-Path $root 'turns.jsonl'
  $windows = Get-WindowSpecs -Hours $WindowHours -IncludeAll ([bool]$Full)
  $nowUtc = (Get-Date).ToUniversalTime()
  $buckets = @{}
  $lineCount = 0
  $parsedCount = 0
  $badCount = 0

  Write-Output ('TIMEOUT TREND REPORT')
  Write-Output ('bridge_root: {0}' -f $root)
  Write-Output ('turns_path : {0}' -f $turnsPath)
  Write-Output ('generated  : {0:o}' -f $nowUtc)

  if (-not (Test-Path -LiteralPath $turnsPath)) {
    Write-Output ''
    Write-Output 'No turns.jsonl found; no data.'
    exit 0
  }

  foreach ($line in [System.IO.File]::ReadLines($turnsPath, [System.Text.Encoding]::UTF8)) {
    $lineCount++
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    try {
      $record = $line | ConvertFrom-Json
    } catch {
      $badCount++
      continue
    }

    $ts = Get-RecordDateUtc (Get-JsonProp -Object $record -Name 'ts')
    if ($null -eq $ts) {
      $badCount++
      continue
    }

    $parsedCount++
    $model = [string](Get-JsonProp -Object $record -Name 'model' -Default 'unknown')
    if ([string]::IsNullOrWhiteSpace($model)) { $model = 'unknown' }
    $status = ([string](Get-JsonProp -Object $record -Name 'status' -Default 'unknown')).ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($status)) { $status = 'unknown' }
    $sec = Get-RecordSec (Get-JsonProp -Object $record -Name 'sec')

    foreach ($window in $windows) {
      if ([int]$window.Hours -gt 0) {
        $cutoff = $nowUtc.AddHours(-1 * [int]$window.Hours)
        if ($ts -lt $cutoff) { continue }
      }
      Add-BucketRecord -Buckets $buckets -Window ([string]$window.Name) -Model $model -Status $status -Sec $sec
    }
  }

  Write-Output ('lines      : {0}' -f $lineCount)
  Write-Output ('parsed     : {0}' -f $parsedCount)
  Write-Output ('bad        : {0}' -f $badCount)

  if ($buckets.Count -eq 0) {
    Write-Output ''
    Write-Output 'No turns matched selected window(s).'
    exit 0
  }

  $summary = New-Object System.Collections.Generic.List[object]
  $statusRows = New-Object System.Collections.Generic.List[object]
  $recommendations = New-Object System.Collections.Generic.List[object]

  foreach ($key in ($buckets.Keys | Sort-Object)) {
    $parts = $key.Split([char[]]@('|'), 2)
    $windowName = $parts[0]
    $modelName = $parts[1]
    $bucket = $buckets[$key]
    $rate = if ($bucket.Total -gt 0) { ([double]$bucket.Timeout / [double]$bucket.Total) * 100.0 } else { 0.0 }
    $avg = Get-Average -Values $bucket.Seconds
    $p95 = Get-Percentile -Values $bucket.Seconds

    [void]$summary.Add([pscustomobject]@{
      window = $windowName
      model = $modelName
      total = $bucket.Total
      timeouts = $bucket.Timeout
      timeout_rate = Format-Percent $rate
      avg_sec = ('{0:N1}' -f $avg)
      p95_sec = ('{0:N1}' -f $p95)
    })

    foreach ($statusName in ($bucket.Status.Keys | Sort-Object)) {
      [void]$statusRows.Add([pscustomobject]@{
        window = $windowName
        model = $modelName
        status = $statusName
        count = $bucket.Status[$statusName]
      })
    }

    $rec = Get-Recommendation -Rate $rate
    [void]$recommendations.Add([pscustomobject]@{
      window = $windowName
      model = $modelName
      timeout_rate = Format-Percent $rate
      action = $rec.Action
      recommendation = $rec.Detail
    })
  }

  Write-ReportTable -Title 'SUMMARY' -Rows $summary.ToArray() -Columns @('window', 'model', 'total', 'timeouts', 'timeout_rate', 'avg_sec', 'p95_sec')
  Write-ReportTable -Title 'STATUS BREAKDOWN' -Rows $statusRows.ToArray() -Columns @('window', 'model', 'status', 'count')
  Write-ReportTable -Title 'RECOMMENDATIONS' -Rows $recommendations.ToArray() -Columns @('window', 'model', 'timeout_rate', 'action', 'recommendation')
} catch {
  Write-Output ('timeout trend report failed: {0}' -f $_.Exception.Message)
  if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
    Write-Output $_.InvocationInfo.PositionMessage
  }
  exit 1
}
