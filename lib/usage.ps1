function Get-UsagePath { Join-Path (Get-BridgeRoot) 'usage.jsonl' }

function Get-UsageConfig {
  # Prices are approximate and intended for burn-rate trends, not billing.
  $defaults = @{
    prices = @{
      'deepseek-v4-flash' = @{ in = 0.07; out = 1.1 }
      'deepseek-v4-pro'   = @{ in = 0.55; out = 2.19 }
      'gemini-2.5-flash'  = @{ in = 0.3; out = 2.5 }
      'gemini-embedding-001' = @{ in = 0.15; out = 0.0 }
    }
    window_hours = @(1, 24)
  }
  try {
    $cfg = Get-BridgeConfig
    if (-not ($cfg.PSObject.Properties.Name -contains 'usage') -or $null -eq $cfg.usage) { return $defaults }
    $u = $cfg.usage
    $out = @{
      prices = $defaults.prices
      window_hours = $defaults.window_hours
    }
    if ($u.PSObject.Properties.Name -contains 'prices' -and $null -ne $u.prices) { $out.prices = $u.prices }
    if ($u.PSObject.Properties.Name -contains 'window_hours' -and $null -ne $u.window_hours) { $out.window_hours = @($u.window_hours) }
    return $out
  } catch {
    return $defaults
  }
}

function Get-UsagePriceNumber {
  param($Price, [string]$Name)
  if ($null -eq $Price) { return 0.0 }
  try {
    if ($Price -is [hashtable] -and $Price.ContainsKey($Name)) { return [double]$Price[$Name] }
    if ($Price.PSObject.Properties.Name -contains $Name) { return [double]$Price.PSObject.Properties[$Name].Value }
  } catch {}
  return 0.0
}

function Get-UsagePrice {
  param([string]$Model)
  $uc = Get-UsageConfig
  $prices = $uc.prices
  if ([string]::IsNullOrWhiteSpace($Model)) { return $null }
  try {
    if ($prices -is [hashtable] -and $prices.ContainsKey($Model)) { return $prices[$Model] }
    if ($prices.PSObject.Properties.Name -contains $Model) { return $prices.PSObject.Properties[$Model].Value }
  } catch {}
  return $null
}

function Get-UsageCostUsd {
  param(
    [string]$Model,
    $PromptTokens = 0,
    $CompletionTokens = 0
  )
  try {
    $pt = 0; $ct = 0
    try { $pt = [int]$PromptTokens } catch { $pt = 0 }
    try { $ct = [int]$CompletionTokens } catch { $ct = 0 }
    $pt = [Math]::Max(0, $pt)
    $ct = [Math]::Max(0, $ct)
    $price = Get-UsagePrice -Model $Model
    $inRate = Get-UsagePriceNumber -Price $price -Name 'in'
    $outRate = Get-UsagePriceNumber -Price $price -Name 'out'
    return [Math]::Round((($inRate * $pt) + ($outRate * $ct)) / 1000000.0, 8)
  } catch {
    return $null
  }
}

function Add-UsageRecord {
  param(
    [string]$Kind,
    [string]$Provider,
    [string]$Model,
    [string]$Purpose = '',
    $PromptTokens = 0,
    $CompletionTokens = 0,
    $Sec = 0,
    [string]$Status = ''
  )
  try {
    if ([string]::IsNullOrWhiteSpace($Kind)) { return $false }
    $Kind = $Kind.ToLowerInvariant()
    if ($Kind -ne 'prepaid' -and $Kind -ne 'paid') { return $false }
    $pt = 0; $ct = 0; $secNum = 0.0
    try { $pt = [int]$PromptTokens } catch { $pt = 0 }
    try { $ct = [int]$CompletionTokens } catch { $ct = 0 }
    try { $secNum = [double]$Sec } catch { $secNum = 0.0 }
    $pt = [Math]::Max(0, $pt)
    $ct = [Math]::Max(0, $ct)
    $cost = $null
    if ($Kind -eq 'paid') {
      $cost = Get-UsageCostUsd -Model $Model -PromptTokens $pt -CompletionTokens $ct
    }
    $rec = [ordered]@{
      ts                = [DateTime]::UtcNow.ToString('o')
      kind              = [string]$Kind
      provider          = [string]$Provider
      model             = [string]$Model
      purpose           = [string]$Purpose
      prompt_tokens     = [int]$pt
      completion_tokens = [int]$ct
      cost_usd          = $cost
      sec               = [Math]::Round($secNum, 3)
      status            = [string]$Status
    }
    $line = $rec | ConvertTo-Json -Compress -Depth 5
    Use-BridgeLock ({ Add-Content -LiteralPath (Get-UsagePath) -Value $line -Encoding UTF8 }.GetNewClosure())
    return $true
  } catch {
    return $false
  }
}

function ConvertTo-UsageDateTimeUtc {
  param($Value)
  if ($null -eq $Value) { return $null }
  try {
    $dt = [DateTimeOffset]::Parse([string]$Value)
    return $dt.UtcDateTime
  } catch {
    return $null
  }
}

function Read-UsageRecords {
  $path = Get-UsagePath
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  $items = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $rec = $line | ConvertFrom-Json
      if ($rec) { [void]$items.Add($rec) }
    } catch {}
  }
  return @($items.ToArray())
}

function Get-UsageCost {
  param($Record)
  if ($null -eq $Record -or $null -eq $Record.cost_usd) { return 0.0 }
  try { return [double]$Record.cost_usd } catch { return 0.0 }
}

function Get-UsageInt {
  param($Value)
  if ($null -eq $Value) { return 0 }
  try { return [int]$Value } catch { return 0 }
}

function Get-UsageSummary {
  $records = @(Read-UsageRecords)
  $totalCost = 0.0
  foreach ($r in $records) { $totalCost += Get-UsageCost $r }

  $providers = New-Object 'System.Collections.Generic.List[object]'
  foreach ($g in ($records | Group-Object -Property provider)) {
    $group = @($g.Group)
    $cost = 0.0
    $pt = 0
    $ct = 0
    foreach ($r in $group) {
      $cost += Get-UsageCost $r
      $pt += Get-UsageInt $r.prompt_tokens
      $ct += Get-UsageInt $r.completion_tokens
    }
    [void]$providers.Add([pscustomobject]@{
      provider          = [string]$g.Name
      calls             = [int]$group.Count
      cost_usd          = [Math]::Round($cost, 6)
      prompt_tokens     = [int]$pt
      completion_tokens = [int]$ct
    })
  }

  $uc = Get-UsageConfig
  $windows = New-Object 'System.Collections.Generic.List[object]'
  foreach ($rawH in @($uc.window_hours)) {
    $h = 0
    try { $h = [int]$rawH } catch { $h = 0 }
    if ($h -le 0) { continue }
    $cutoff = [DateTime]::UtcNow.AddHours(-1 * $h)
    $win = @($records | Where-Object {
      $ts = ConvertTo-UsageDateTimeUtc $_.ts
      $null -ne $ts -and $ts -ge $cutoff
    })
    $cost = 0.0
    $prepaidCalls = 0
    $prepaidSec = 0.0
    foreach ($r in $win) {
      $cost += Get-UsageCost $r
      if ([string]$r.kind -eq 'prepaid') {
        $prepaidCalls++
        try { $prepaidSec += [double]$r.sec } catch {}
      }
    }
    [void]$windows.Add([pscustomobject]@{
      hours           = [int]$h
      calls           = [int]$win.Count
      cost_usd        = [Math]::Round($cost, 6)
      prepaid_calls   = [int]$prepaidCalls
      prepaid_min     = [Math]::Round($prepaidSec / 60.0, 2)
      burn_usd_per_hr = [Math]::Round($cost / [double]$h, 6)
    })
  }

  return [pscustomobject]@{
    total_calls    = [int]$records.Count
    total_cost_usd = [Math]::Round($totalCost, 6)
    by_provider    = @($providers.ToArray())
    windows        = @($windows.ToArray())
  }
}
