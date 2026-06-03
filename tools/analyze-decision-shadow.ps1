#Requires -Version 5.1
# analyze-decision-shadow.ps1 -- READ-ONLY evidence reader for the DecisionContract shadow logs.
#
# The shadow layer (slimming Atom 1/2) logs, per channel, what the model PROPOSED vs what the legacy
# heuristic ACTUALLY decided. Before we can promote the model decision out of shadow (and start deleting
# legacy heuristics), we need EVIDENCE: how many proposals were emitted, are they valid, and does their
# intent agree with the legacy intent? This tool turns the raw JSONL into that summary. It NEVER writes,
# never touches the running bridge, never changes behavior — pure analysis so promotion is data-driven.
#
# NOTE on counts: `records` is a COUNT, not an emit-rate — the denominator (how many planner-turns ran)
# is not tracked in this log, so we deliberately do not claim a rate.
# NOTE on intent agreement: the model intent vocab (DecisionContract: code|plan|audit|fix|discuss|study|
# chat|fast) and the legacy task_intent.primary_mode vocab (normal|discuss|study|fast|chat) only partly
# overlap. We map BOTH onto a shared coarse canon (ConvertTo-IntentCanon, in lib/decision-contract.ps1)
# so "agreement" reflects real alignment, not a vocabulary gap. Legacy is stored as a JSON-serialized
# object, so we extract the mode from primary_mode/mode/intent (see Get-LegacyMode), not the whole string.
#
# TWO record kinds are summarized SEPARATELY (Codex TZ — do not mix):
#   - stage='planner-turn'  : full DecisionContract proposal (model emits [[DECISION]] — currently unused).
#   - stage='intent-claim'  : Intent Decision Shadow (Atom 4) — model intent (Test-TaskIntent) vs the mode
#                             the guard actually applied at the driver/81 decision site. THIS is the
#                             channel that fills today; it has its own metrics block.
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

function Get-LegacyMode($legacy) {
  # The legacy decision in the shadow log is task_intent, an OBJECT that Write-DecisionShadow serialized
  # to a JSON string (fields: primary_mode/mode/...). Older or hand-written rows may be a bare intent
  # string. Extract the mode from primary_mode -> mode -> intent; fall back to the bare string.
  if ($null -eq $legacy) { return '' }
  $obj = $null
  if ($legacy -is [string]) {
    $s = ([string]$legacy).Trim()
    if ($s.StartsWith('{')) { try { $obj = $s | ConvertFrom-Json } catch { $obj = $null } }
    if ($null -eq $obj) { return $s }   # bare intent string (legacy/plain)
  } else { $obj = $legacy }
  foreach ($f in @('primary_mode','mode','intent')) {
    if ($obj.PSObject.Properties[$f] -and -not [string]::IsNullOrWhiteSpace([string]$obj.$f)) { return [string]$obj.$f }
  }
  return ''
}

# Canon = single source of truth in lib/decision-contract.ps1 (shared with the driver-side
# Write-IntentShadow, Atom 4a). Dot-source it for ConvertTo-IntentCanon. The lib is safe to dot-source
# standalone: its Write-* helpers need common.ps1, but we only call the pure ConvertTo-IntentCanon here.
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\decision-contract.ps1')

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

# Intent Decision Shadow (stage='intent-claim') aggregates — kept SEPARATE from the full-contract
# planner-turn metrics above (Codex TZ: do not mix the two).
$icTotal = 0; $icMatch = 0; $icMismatch = 0; $icUncomparable = 0; $icConsulted = 0
$icPerChannel = [ordered]@{}
$icReasons = @{}        # effective_reason -> count
$icOverrides = @{}      # guard_override key -> count of times it fired (true)
$icDivergences = @{}    # "model=X(canon) eff=Y(canon)" -> count

foreach ($log in $logs) {
  $cnt = 0
  foreach ($line in (Get-Content -LiteralPath $log.path -ErrorAction SilentlyContinue)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $rec = $null
    try { $rec = $line | ConvertFrom-Json } catch { $parseErrors++; continue }
    if ($null -eq $rec) { continue }

    # Dispatch by stage: intent-claim (Atom 4) is a DIFFERENT record shape than the full-contract
    # planner-turn rows. Keep their metrics SEPARATE (Codex TZ) and skip the contract logic below.
    if (([string]$rec.stage) -eq 'intent-claim') {
      $icTotal++
      if ($icPerChannel.Contains($log.channel)) { $icPerChannel[$log.channel]++ } else { $icPerChannel[$log.channel] = 1 }
      if ($rec.model_consulted -eq $true) { $icConsulted++ }
      $rsn = [string]$rec.effective_reason
      if ($rsn) { if ($icReasons.ContainsKey($rsn)) { $icReasons[$rsn]++ } else { $icReasons[$rsn] = 1 } }
      if ($null -ne $rec.guard_overrides) {
        foreach ($gp in $rec.guard_overrides.PSObject.Properties) {
          if ($gp.Value -eq $true) { if ($icOverrides.ContainsKey($gp.Name)) { $icOverrides[$gp.Name]++ } else { $icOverrides[$gp.Name] = 1 } }
        }
      }
      # Recompute canon from the raw modes (don't trust the stored canon) so this tool independently
      # validates the model-vs-effective mapping.
      $mcRaw = [string]$rec.model_primary_mode
      $ecRaw = [string]$rec.effective_mode
      $mc = ConvertTo-IntentCanon -Mode $mcRaw
      $ec = ConvertTo-IntentCanon -Mode $ecRaw
      if ([string]::IsNullOrWhiteSpace($mc) -or [string]::IsNullOrWhiteSpace($ec)) { $icUncomparable++ }
      elseif ($mc -eq $ec) { $icMatch++ }
      else {
        $icMismatch++
        $idk = "model=$($mcRaw.ToLowerInvariant())($mc) eff=$($ecRaw.ToLowerInvariant())($ec)"
        if ($icDivergences.ContainsKey($idk)) { $icDivergences[$idk]++ } else { $icDivergences[$idk] = 1 }
      }
      continue
    }

    $total++; $cnt++

    if ($rec.model_valid -eq $true) { $valid++ } else { $invalid++ }

    foreach ($e in @($rec.validator_errs)) {
      if (-not [string]::IsNullOrWhiteSpace([string]$e)) {
        $k = [string]$e
        if ($validatorErrs.ContainsKey($k)) { $validatorErrs[$k]++ } else { $validatorErrs[$k] = 1 }
      }
    }

    # intent agreement: extract the model intent + the legacy mode (from its serialized object), then
    # canonicalize BOTH vocabs before comparing so a vocabulary gap (e.g. model=code vs legacy=normal)
    # isn't miscounted as a real divergence.
    $mIntent = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$rec.model_decision)) {
      try { $mo = ([string]$rec.model_decision | ConvertFrom-Json); if ($mo) { $mIntent = [string]$mo.intent } } catch {}
    }
    $lIntent = Get-LegacyMode $rec.legacy
    $mCanon = ConvertTo-IntentCanon -Mode $mIntent
    $lCanon = ConvertTo-IntentCanon -Mode $lIntent

    if ([string]::IsNullOrWhiteSpace($mCanon) -or [string]::IsNullOrWhiteSpace($lCanon)) {
      $intentUncomparable++
    } elseif ($mCanon -eq $lCanon) {
      $intentMatch++
    } else {
      $intentMismatch++
      $dk = "model=$($mIntent.ToLowerInvariant())($mCanon) legacy=$($lIntent.ToLowerInvariant())($lCanon)"
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
$icComparable = $icMatch + $icMismatch
$icAgreementPct = if ($icComparable -gt 0) { [math]::Round(100.0 * $icMatch / $icComparable, 1) } else { $null }

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
    intent_claim       = [ordered]@{
      total           = $icTotal
      match           = $icMatch
      mismatch        = $icMismatch
      uncomparable    = $icUncomparable
      agreement_pct   = $icAgreementPct
      model_consulted = $icConsulted
      per_channel     = $icPerChannel
      effective_reasons = ($icReasons.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [ordered]@{ reason = $_.Key; count = $_.Value } })
      guard_overrides   = ($icOverrides.GetEnumerator() | Sort-Object Value -Descending | ForEach-Object { [ordered]@{ guard = $_.Key; count = $_.Value } })
      top_divergences   = ($icDivergences.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10 | ForEach-Object { [ordered]@{ pair = $_.Key; count = $_.Value } })
    }
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

Write-Host ""
Write-Host "=== Intent Decision Shadow (stage=intent-claim) ===" -ForegroundColor Cyan
if ($icTotal -eq 0) {
  Write-Host "No intent-claim records yet." -ForegroundColor Yellow
  Write-Host "  (Expected until the driver claims a task after a restart picks up Atom 4b.)"
} else {
  Write-Host ("records:        {0}  (model consulted {1})" -f $icTotal, $icConsulted)
  Write-Host ("agreement:      match {0} / mismatch {1} / uncomparable {2}{3}" -f $icMatch, $icMismatch, $icUncomparable, $(if ($null -ne $icAgreementPct) { "  -> $icAgreementPct%" } else { '' }))
  Write-Host "per channel:"
  foreach ($k in $icPerChannel.Keys) { Write-Host ("  {0,-24} {1}" -f $k, $icPerChannel[$k]) }
  if ($icReasons.Count -gt 0) {
    Write-Host "effective_reason distribution:"
    foreach ($r in ($icReasons.GetEnumerator() | Sort-Object Value -Descending)) { Write-Host ("  {0,-24} x{1}" -f $r.Key, $r.Value) }
  }
  if ($icOverrides.Count -gt 0) {
    Write-Host "guard overrides fired (times true):"
    foreach ($g in ($icOverrides.GetEnumerator() | Sort-Object Value -Descending)) { Write-Host ("  {0,-24} x{1}" -f $g.Key, $g.Value) }
  }
  if ($icDivergences.Count -gt 0) {
    Write-Host "top model-vs-effective divergences:"
    foreach ($d in ($icDivergences.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 10)) { Write-Host ("  {0,-44} x{1}" -f $d.Key, $d.Value) }
  }
}
Write-Host ("logger failures: {0}{1}" -f $signalCount, $(if ($signalCount -gt 0) { " (" + (($signalByReason.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ') + ")" } else { '' })) -ForegroundColor $(if ($signalCount -gt 0) { 'Yellow' } else { 'Gray' })
if ($parseErrors -gt 0) { Write-Host ("parse errors:    {0} (malformed JSONL lines skipped)" -f $parseErrors) -ForegroundColor Yellow }
