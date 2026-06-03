# decision-contract.ps1 -- Model Decision Layer (SHADOW mode).
#
# Consensus (Claude audit + Codex review, 2026-06-03): the model PROPOSES a structured decision;
# DETERMINISTIC validators (here) CHECK it; the driver APPLIES only what passes. The model's JSON
# never authorizes itself. This file is the contract + validator + shadow logger ONLY.
#
# SHADOW-FIRST: nothing here changes execution behavior. Legacy heuristics still decide. The model
# decision is validated + logged + compared so we can promote it out of shadow only after real-run
# evidence. Never put safety/verify/git/rollback/locks/state authority in the model JSON — those stay
# in the deterministic Guard layer.
#
# Minimal schema (intentionally small): intent, risk, files, dependencies, parallel_groups,
# acceptance, needs_operator, confidence, rationale_short.

$script:DecisionIntentEnum = @('discuss','plan','code','audit','study','chat','fix','fast')
$script:DecisionRiskEnum    = @('low','medium','high','critical')

function Get-DecisionContractSchema {
  # Human/tool-readable description of the minimal contract (for prompts + docs).
  return [ordered]@{
    intent          = "one of: $($script:DecisionIntentEnum -join '|')"
    risk            = "one of: $($script:DecisionRiskEnum -join '|')"
    files           = 'string[] — repo-relative paths the work will touch'
    dependencies    = 'string[] — ids/areas that must exist first'
    parallel_groups = 'string[][] — groups of files safe to run concurrently'
    acceptance      = 'string[] — concrete checks that prove done'
    needs_operator  = 'bool — model is unsure or this crosses an approval/risk boundary'
    confidence      = 'number 0..1'
    rationale_short = 'string — one short sentence why'
  }
}

function Test-DecisionContract {
  # Deterministic shape/type/enum validator. Returns $true/$false; on $false fills -Errors with reasons.
  # This is the contract gate — it does NOT decide policy (that's the Guard layer), only validity.
  param([Parameter(Mandatory)][string]$Json, [ref]$Errors)
  $errs = New-Object 'System.Collections.Generic.List[string]'
  $obj = $null
  try { $obj = $Json | ConvertFrom-Json } catch { $errs.Add('not valid JSON: ' + $_.Exception.Message) }
  if ($null -ne $obj) {
    # required scalar: intent (enum)
    $intent = [string]$obj.intent
    if ([string]::IsNullOrWhiteSpace($intent)) { $errs.Add('intent missing') }
    elseif ($script:DecisionIntentEnum -notcontains $intent.ToLowerInvariant()) { $errs.Add("intent '$intent' not in enum") }
    # required scalar: risk (enum)
    $risk = [string]$obj.risk
    if ([string]::IsNullOrWhiteSpace($risk)) { $errs.Add('risk missing') }
    elseif ($script:DecisionRiskEnum -notcontains $risk.ToLowerInvariant()) { $errs.Add("risk '$risk' not in enum") }
    # arrays of STRINGS: files, dependencies, acceptance ([] allowed; reject string / non-string elements)
    foreach ($arr in @('files','dependencies','acceptance')) {
      $v = $obj.$arr
      if ($null -eq $v) { $errs.Add("$arr missing (use [] if none)"); continue }
      if ($v -is [string]) { $errs.Add("$arr must be an array, got string"); continue }
      if (-not ($v -is [System.Collections.IEnumerable])) { $errs.Add("$arr must be an array"); continue }
      foreach ($el in $v) { if ($el -isnot [string]) { $errs.Add("$arr must contain only strings"); break } }
    }
    # parallel_groups: ARRAY OF ARRAYS (each group an array of strings); empty [] allowed
    $pg = $obj.parallel_groups
    if ($null -eq $pg) { $errs.Add('parallel_groups missing (use [] if none)') }
    elseif ($pg -is [string] -or -not ($pg -is [System.Collections.IEnumerable])) { $errs.Add('parallel_groups must be an array of arrays') }
    else {
      foreach ($grp in $pg) {
        if ($grp -is [string] -or -not ($grp -is [System.Collections.IEnumerable])) { $errs.Add('parallel_groups must be an array of arrays (each group is an array)'); break }
        foreach ($gel in $grp) { if ($gel -isnot [string]) { $errs.Add('parallel_groups inner arrays must contain only strings'); break } }
      }
    }
    # needs_operator: STRICT JSON boolean — reject "false"/"true" strings (they parse loosely otherwise)
    if ($null -eq $obj.needs_operator) { $errs.Add('needs_operator missing') }
    elseif ($obj.needs_operator -isnot [bool]) { $errs.Add('needs_operator must be a JSON boolean true/false (not a string)') }
    # confidence: must be an actual JSON number in 0..1 (reject string "0.8")
    if ($null -eq $obj.confidence) { $errs.Add('confidence missing') }
    elseif (-not ($obj.confidence -is [double] -or $obj.confidence -is [int] -or $obj.confidence -is [long] -or $obj.confidence -is [decimal])) { $errs.Add('confidence must be a JSON number (not a string)') }
    elseif ([double]$obj.confidence -lt 0 -or [double]$obj.confidence -gt 1) { $errs.Add('confidence out of range 0..1') }
    # rationale_short: non-empty string
    if ([string]::IsNullOrWhiteSpace([string]$obj.rationale_short)) { $errs.Add('rationale_short missing') }
  }
  if ($Errors) { $Errors.Value = @($errs.ToArray()) }
  return ($errs.Count -eq 0)
}

function Get-DecisionShadowPromptHint {
  # Optional planner-prompt addendum: invites the model to emit a DecisionContract block. SHADOW —
  # explicitly tells the model it does NOT affect execution, so behavior is unchanged while we collect
  # model-vs-legacy comparisons. Kept tiny; removed once we promote out of shadow.
  return @'

[SHADOW — НЕ влияет на исполнение, только наблюдение] В самом конце ответа можешь добавить одну строку:
[[DECISION: {"intent":"code|plan|discuss|audit|study|fix|fast|chat","risk":"low|medium|high|critical","files":[],"dependencies":[],"parallel_groups":[],"acceptance":[],"needs_operator":false,"confidence":0.0,"rationale_short":""}]]
'@
}

function Read-DecisionFromReply {
  # Extract a [[DECISION: {json}]] block from a model reply, if present. Returns the JSON string or $null.
  param([string]$Reply)
  if ([string]::IsNullOrWhiteSpace($Reply)) { return $null }
  $m = [regex]::Match($Reply, '(?s)\[\[DECISION:\s*(\{.*?\})\s*\]\]')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return $null
}

function Remove-DecisionMarker {
  # Strip the [[DECISION:{...}]] block from a reply so the technical JSON never reaches the visible
  # chat / memory. Mirror of how other service markers are removed from $visibleReply.
  param([string]$Reply)
  if ([string]::IsNullOrWhiteSpace($Reply)) { return $Reply }
  return ([regex]::Replace($Reply, '(?s)\s*\[\[DECISION:\s*\{.*?\}\s*\]\]\s*', "`n")).Trim()
}

function Write-DecisionShadow {
  # Append a shadow record: what the model PROPOSED vs what the legacy heuristic ACTUALLY decided,
  # plus whether the proposal passed the validator. For later "where did the model match/err" analysis.
  # Behavior-neutral: pure logging. Stored per-channel so promotion decisions are channel-aware.
  param(
    [string]$Channel = '',
    [Parameter(Mandatory)][string]$Stage,        # capture point, e.g. 'planner-turn' (whole-turn proposal).
                                                  # Per-point 'intent'/'routing'/'workpack' captures land in Atom 2/3
                                                  # when the contract is wired into those exact decision sites.
    $ModelDecision = $null,                       # object or JSON string (the proposal)
    $LegacyDecision = $null,                      # whatever the old heuristic chose
    [string]$Note = ''
  )
  try {
    $ch = $Channel
    if ([string]::IsNullOrWhiteSpace($ch)) { try { if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { $ch = [string](Get-EffectiveChannel) } } catch {} }
    if ([string]::IsNullOrWhiteSpace($ch)) { $ch = 'main' }
    $root = $null
    try { $root = Get-BridgeRoot } catch { $root = 'C:\Users\rafie\OneDrive\Documents\bridge' }
    $dir = Join-Path (Join-Path $root 'channels') $ch
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $path = Join-Path $dir 'decision-shadow.jsonl'

    $modelJson = ''
    if ($ModelDecision -is [string]) { $modelJson = $ModelDecision }
    elseif ($null -ne $ModelDecision) { try { $modelJson = ($ModelDecision | ConvertTo-Json -Compress -Depth 8) } catch {} }
    $valid = $false; $verrs = @()
    if (-not [string]::IsNullOrWhiteSpace($modelJson)) { $ref = [ref]$null; $valid = (Test-DecisionContract -Json $modelJson -Errors $ref); $verrs = @($ref.Value) }

    $rec = [ordered]@{
      ts             = (Get-Date).ToUniversalTime().ToString('o')
      channel        = $ch
      stage          = $Stage
      model_decision = $modelJson
      model_valid    = $valid
      validator_errs = $verrs
      legacy         = $(if ($LegacyDecision -is [string]) { $LegacyDecision } else { try { ($LegacyDecision | ConvertTo-Json -Compress -Depth 6) } catch { '' } })
      note           = $Note
    }
    $line = ($rec | ConvertTo-Json -Compress -Depth 8)
    $u8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($path, $line + "`n", $u8)
  } catch {}
}
