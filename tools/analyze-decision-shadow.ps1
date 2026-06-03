#Requires -Version 5.1
# analyze-decision-shadow.ps1 -- READ-ONLY evidence reader for the DecisionContract shadow logs.
#
# The shadow layer (slimming Atom 1/2) logs, per channel, what the model PROPOSED vs what the legacy
# heuristic ACTUALLY decided. Before we can promote the model decision out of shadow (and start deleting
# legacy heuristics), we need EVIDENCE: how often is the proposal even emitted, is it valid, and does its
# intent agree with the legacy intent? This tool turns the raw JSONL into that summary. It NEVER writes,
# never touches the running bridge, never changes behavior — pure analysis so promotion is data-driven.
#
# Usage:
#   tools/analyze-decision-shadow.ps1                 # all channels, human-readable
#   tools/analyze-decision-shadow.ps1 -Channel main   # one channel
#   tools/analyze-decision-shadow.ps1 -AsJson         # machine-readable summary
param(
  [string]$Channel = '',
  [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
$bridgeRoot = Split-Path -Parent $PSScriptRoot
$channelsDir = Join-Path $bridgeRoot 'channels'

# Collect target shadow logs (one channel or all).
$logs = @()
if (-not [string]::IsNullOrWhiteSpace($Channel)) {
  $p = Join-Path (Join-Path $channelsDir $Channel) 'decision-shadow.jsonl'
  if (Test-Path -LiteralPath $p) { $logs += [pscustomobject]@{ channel = $Channel; path = $p } }
} elseif (Test-Path -LiteralPath $channelsDir) {
  foreach ($d in (Get-ChildItem -LiteralPath $channelsDir -Directory -ErrorAction SilentlyContinue)) {
    $p = Join-Path $d.FullName 'decision-shadow.jsonl'
    if (Test-Path -LiteralPath $p) { $logs += [pscustomobject]@{ channel = $d.Name; path = $p } }
  }
}

# Aggregates.
$total = 0; $valid = 0; $invalid = 0
$intentMatch = 0; $intentMismatch = 0; $intentUncomparable = 0
$perChannel = [ordered]@{}
$divergences = @{}     # "model=X legacy=Y" -> count
$validatorErrs = @{}   # error string -> count
$parseErrors = 0

foreach ($log in $logs) {
  $cnt = 0
  foreach ($line in (Get-Content -LiteralPath $log.path -ErrorAction SilentlyContinue)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $rec = $null
    try { $rec = $line | ConvertFrom-Json } catch { $parseErrors++; continue }
    if ($null -eq $rec) { continue }
    $total++; $cnt++

    if ($rec.model_valid -eq $true) { $valid++ } else { $invalid++ }

    foreach ($e in @($rec.validator_errs)) {
      if (-not [string]::IsNullOrWhiteSpace([string]$e)) {
        $k = [string]$e
        if ($validatorErrs.ContainsKey($k)) { $validatorErrs[$k]++ } else { $validatorErrs[$k] = 1 }
      }
    }

    # intent agreement: parse model_decision JSON, compare its intent to the legacy intent string.
    $mIntent = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$rec.model_decision)) {
      try { $mo = ([string]$rec.model_decision | ConvertFrom-Json); if ($mo) { $mIntent = [string]$mo.intent } } catch {}
    }
    $lIntent = ''
    if ($rec.legacy -is [string]) { $lIntent = [string]$rec.legacy }
    elseif ($null -ne $rec.legacy -and $rec.legacy.PSObject.Properties['intent']) { $lIntent = [string]$rec.legacy.intent }

    if ([string]::IsNullOrWhiteSpace($mIntent) -or [string]::IsNullOrWhiteSpace($lIntent)) {
      $intentUncomparable++
    } elseif ($mIntent.ToLowerInvariant() -eq $lIntent.ToLowerInvariant()) {
      $intentMatch++
    } else {
      $intentMismatch++
      $dk = "model=$($mIntent.ToLowerInvariant()) legacy=$($lIntent.ToLowerInvariant())"
      if ($divergences.ContainsKey($dk)) { $divergences[$dk]++ } else { $divergences[$dk] = 1 }
    }
  }
  $perChannel[$log.channel] = $cnt
}

# Observability of the logger itself (Atom 2 signals): surface how often shadow logging FAILED.
$signalCount = 0; $signalByReason = @{}
try {
  $rt = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.bridge-runtime' } else { Join-Path $bridgeRoot 'control' }
  $sp = Join-Path $rt 'decision-shadow-errors.jsonl'
  if (Test-Path -LiteralPath $sp) {
    foreach ($line in (Get-Content -LiteralPath $sp -ErrorAction SilentlyContinue)) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try { $s = $line | ConvertFrom-Json; if ($s) { $signalCount++; $r = [string]$s.reason; if ($r) { if ($signalByReason.ContainsKey($r)) { $signalByReason[$r]++ } else { $signalByReason[$r] = 1 } } } } catch {}
    }
  }
} catch {}

$comparable = $intentMatch + $intentMismatch
$agreementPct = if ($comparable -gt 0) { [math]::Round(100.0 * $intentMatch / $comparable, 1) } else { $null }
$validPct = if ($total -gt 0) { [math]::Round(100.0 * $valid / $total, 1) } else { $null }

if ($AsJson) {
  $out = [ordered]@{
    total_records      = $total
    valid              = $valid
    invalid            = $invalid
    valid_pct          = $validPct
    intent_match       = $intentMatch
    intent_mismatch    = $intentMismatch
    intent_uncomparable= $intentUncomparable
    intent_agreement_pct = $agreementPct
    per_channel        = $perChannel
    top_divergences    = ($divergences.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10 | ForEach-Object { [ordered]@{ pair = $_.Key; count = $_.Value } })
    top_validator_errs = ($validatorErrs.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10 | ForEach-Object { [ordered]@{ err = $_.Key; count = $_.Value } })
    logger_failures    = $signalCount
    logger_failures_by_reason = $signalByReason
    parse_errors       = $parseErrors
  }
  Write-Output ($out | ConvertTo-Json -Depth 6)
  return
}

Write-Host "=== DecisionContract shadow evidence ===" -ForegroundColor Cyan
if ($total -eq 0) {
  Write-Host "No shadow records yet." -ForegroundColor Yellow
  Write-Host "  (Expected until planner-turns run WITH the shadow hint live and a model emits [[DECISION:...]].)"
} else {
  Write-Host ("records:        {0}  (valid {1} / invalid {2}{3})" -f $total, $valid, $invalid, $(if ($null -ne $validPct) { ", valid $validPct%" } else { '' }))
  Write-Host ("intent agree:   match {0} / mismatch {1} / uncomparable {2}{3}" -f $intentMatch, $intentMismatch, $intentUncomparable, $(if ($null -ne $agreementPct) { "  -> agreement $agreementPct%" } else { '' }))
  Write-Host "per channel:"
  foreach ($k in $perChannel.Keys) { Write-Host ("  {0,-24} {1}" -f $k, $perChannel[$k]) }
  if ($divergences.Count -gt 0) {
    Write-Host "top intent divergences (model vs legacy):"
    foreach ($d in ($divergences.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10)) { Write-Host ("  {0,-40} x{1}" -f $d.Key, $d.Value) }
  }
  if ($validatorErrs.Count -gt 0) {
    Write-Host "top validator errors (invalid proposals):"
    foreach ($e in ($validatorErrs.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10)) { Write-Host ("  {0,-50} x{1}" -f $e.Key, $e.Value) }
  }
}
Write-Host ("logger failures: {0}{1}" -f $signalCount, $(if ($signalCount -gt 0) { " (" + (($signalByReason.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ') + ")" } else { '' })) -ForegroundColor $(if ($signalCount -gt 0) { 'Yellow' } else { 'Gray' })
if ($parseErrors -gt 0) { Write-Host ("parse errors:    {0} (malformed JSONL lines skipped)" -f $parseErrors) -ForegroundColor Yellow }
