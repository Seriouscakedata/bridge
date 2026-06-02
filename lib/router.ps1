function Get-RouterConfig {
  $defaults = @{
    minSuccess  = 0.5
    minSamples  = 5
    windowHours = 24
  }
  $r = $null
  try {
    $cfg = Get-BridgeConfig
    if ($cfg.PSObject.Properties.Name -contains 'router') { $r = $cfg.router }
  } catch {}
  $out = @{}
  foreach ($k in $defaults.Keys) {
    if ($r -and ($r.PSObject.Properties.Name -contains $k) -and $null -ne $r.$k) { $out[$k] = $r.$k }
    else { $out[$k] = $defaults[$k] }
  }
  return $out
}

function ConvertTo-RouterDateTimeUtc {
  param($Value)
  if ($null -eq $Value) { return $null }
  try {
    $dt = [DateTimeOffset]::Parse([string]$Value)
    return $dt.UtcDateTime
  } catch {
    return $null
  }
}

function Get-ModelStats {
  param([int]$WindowHours, [int]$Limit = 200)

  if ($WindowHours -le 0) { $WindowHours = 24 }
  if ($Limit -le 0) { $Limit = 200 }
  $path = Join-Path (Get-BridgeRoot) 'turns.jsonl'
  if (-not (Test-Path -LiteralPath $path)) { return @() }

  $cutoff = [DateTime]::UtcNow.AddHours(-1 * $WindowHours)
  $rows = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $rec = $line | ConvertFrom-Json } catch { continue }
    if ([string]$rec.speaker -ne 'claude') { continue }
    $ts = ConvertTo-RouterDateTimeUtc $rec.ts
    if ($null -eq $ts -or $ts -lt $cutoff) { continue }
    if ([string]::IsNullOrWhiteSpace([string]$rec.model)) { continue }
    [void]$rows.Add($rec)
  }

  $items = @($rows.ToArray())
  if ($items.Count -gt $Limit) { $items = @($items[($items.Count - $Limit)..($items.Count - 1)]) }
  if ($items.Count -eq 0) { return @() }

  $out = New-Object 'System.Collections.Generic.List[object]'
  foreach ($g in ($items | Group-Object -Property model)) {
    $group = @($g.Group)
    $n = $group.Count
    $ok = @($group | Where-Object { [string]$_.status -eq 'ok' }).Count
    $fail = @($group | Where-Object { @('timeout','empty','error') -contains ([string]$_.status) }).Count
    $success = if ($n -gt 0) { [Math]::Round($ok / $n, 4) } else { 0.0 }
    [void]$out.Add([pscustomobject]@{
      model       = [string]$g.Name
      n           = [int]$n
      ok          = [int]$ok
      fail        = [int]$fail
      success_pct = [double]$success
    })
  }
  return @($out.ToArray())
}

function Select-PlannerModel {
  param([string]$TaskText, [string]$Mode, [bool]$Escalate = $false)

  if ($Escalate) { return [string]$deepModel }

  $base = Get-PlannerModel -TaskText $TaskText -Mode $Mode
  if ([string]::IsNullOrWhiteSpace($base)) { return $base }
  if ($base -ne [string]$triageModel) { return $base }

  $rc = Get-RouterConfig
  $stats = @(Get-ModelStats -WindowHours ([int]$rc.windowHours) -Limit 200)
  $triageStats = $stats | Where-Object { [string]$_.model -eq [string]$triageModel } | Select-Object -First 1
  if ($triageStats -and [int]$triageStats.n -ge [int]$rc.minSamples -and [double]$triageStats.success_pct -lt [double]$rc.minSuccess) {
    return [string]$deepModel
  }

  return $base
}
