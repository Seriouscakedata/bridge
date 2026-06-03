#Requires -Version 5.1
# test-analyze-decision-shadow.ps1 -- tests the shadow-evidence analyzer against the LIVE log format.
# Codex review (Atom 3): legacy is task_intent serialized to a JSON STRING (primary_mode/mode/...), and
# the model/legacy vocabularies only partly overlap. These tests prove the analyzer extracts the legacy
# mode from that serialized object AND canonicalizes vocabs, so model=code vs legacy=normal counts as a
# match (same coarse "work" canon), not a false mismatch. Creates a throwaway channel, never touches prod.

$ErrorActionPreference = 'Stop'
$bridgeRoot = Split-Path -Parent $PSScriptRoot
$analyzer = Join-Path $PSScriptRoot 'analyze-decision-shadow.ps1'
$pass = 0; $fail = 0
function Check([string]$name, [bool]$cond) {
  if ($cond) { $script:pass++; Write-Host ("PASS " + $name) -ForegroundColor Green }
  else { $script:fail++; Write-Host ("FAIL " + $name) -ForegroundColor Red }
}

# Build a throwaway channel with rows in the EXACT shape Write-DecisionShadow emits: model_decision and
# legacy are each JSON strings; legacy is a serialized task_intent object.
$ch = '__test_analyze_shadow__'
$dir = Join-Path (Join-Path $bridgeRoot 'channels') $ch
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$path = Join-Path $dir 'decision-shadow.jsonl'

function Row($modelIntent, $legacy) {
  # $legacy may be a hashtable (-> serialized object, the live format) or a bare string (legacy/plain).
  $legacyField = if ($legacy -is [hashtable]) { ($legacy | ConvertTo-Json -Compress) } else { [string]$legacy }
  $rec = [ordered]@{
    ts='t'; channel=$ch; stage='planner-turn'
    model_decision = ('{"intent":"' + $modelIntent + '","risk":"low"}')
    model_valid = $true; validator_errs = @()
    legacy = $legacyField; note=''
  }
  return ($rec | ConvertTo-Json -Compress -Depth 8)
}

$rows = @(
  (Row 'code'    @{ primary_mode='normal'; mode='normal' }),   # A: work==work  -> MATCH (the false-mismatch Codex caught)
  (Row 'discuss' @{ primary_mode='discuss' }),                 # B: discuss==discuss -> MATCH
  (Row 'discuss' @{ primary_mode='normal' }),                  # C: discuss vs work -> MISMATCH (real divergence)
  (Row 'study'   'study'),                                     # D: bare-string legacy (old format) -> MATCH
  (Row 'code'    @{ primary_mode='code'; mode='code' })        # E: Codex's literal example primary_mode=code -> work==work MATCH
)
$u8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($path, (($rows -join "`n") + "`n"), $u8)

try {
  $json = & $analyzer -Channel $ch -AsJson
  $r = $json | ConvertFrom-Json

  Check 'total records = 5'                 ($r.total_records -eq 5)
  Check 'intent_match = 4 (A,B,D,E)'        ($r.intent_match -eq 4)
  Check 'intent_mismatch = 1 (C)'           ($r.intent_mismatch -eq 1)
  Check 'intent_uncomparable = 0'           ($r.intent_uncomparable -eq 0)
  Check 'agreement = 80%'                   ([math]::Abs([double]$r.intent_agreement_pct - 80.0) -lt 0.01)
  # the one divergence must be the real discuss-vs-work one, surfaced with canon annotation
  $div = @($r.top_divergences)
  Check 'divergence is discuss vs work'     ($div.Count -eq 1 -and $div[0].pair -match 'model=discuss\(discuss\)' -and $div[0].pair -match 'legacy=normal\(work\)')
  # regression guard: serialized-object legacy must NOT be swallowed whole as the intent
  Check 'serialized legacy not taken whole' ($div[0].pair -notmatch 'primary_mode')
}
finally {
  Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("RESULT: " + $pass + " passed, " + $fail + " failed")
exit $(if ($fail -gt 0) { 1 } else { 0 })
