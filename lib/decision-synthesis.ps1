# decision-synthesis.ps1 -- Multi-Model Decision Synthesis: the stateless pipeline ENGINE.
#
# Chapter 3 of the Decision Synthesis pipeline. Stages: each builds a STATELESS prompt, calls a model,
# extracts JSON from the (prose-wrapped) reply, validates with the matching Test-* from
# decision-artifacts.ps1 (retry the call ONCE on invalid), then writes the artifact to disk as a
# checkpoint. The sequencer Invoke-SynthesisPipeline runs the right subset per depth.
#
# Reuse (do NOT reinvent): the 7 validators + Get-ChannelDecisionsDir (decision-artifacts.ps1),
# Get-SynthesisDepthDecision (decision-depth.ps1), and the 3 proposer invokers:
#   Codex   = Invoke-Coder   (driver/40-agent-invoke.ps1) -> @{ text; status; ... }
#   Claude  = Invoke-Planner (driver/40-agent-invoke.ps1) -> @{ text; status; ... }
#   Gemini  = Invoke-LLM     (lib/llm.ps1, -Purpose)       -> string reply (or $null)
#
# MODEL POLICY (hard): the Gemini-tier proposer + cheap-tier calls map to gemini-2.5-flash. NEVER
# gemini-2.5-pro. gemini-3-flash is reserve only. We pass an explicit -Model 'gemini-2.5-flash' to
# Invoke-LLM so the policy holds regardless of the runtime LLMConfig.
#
# This file does NOT wire any driver. It only provides functions.

# Dependencies: tolerate standalone loading (tests dot-source explicitly; common.ps1 does not auto-load us).
if (-not (Get-Command Get-ChannelDecisionsDir -ErrorAction SilentlyContinue)) {
  try { . (Join-Path $PSScriptRoot 'decision-artifacts.ps1') } catch {}
}
if (-not (Get-Command Get-SynthesisDepthDecision -ErrorAction SilentlyContinue)) {
  try { . (Join-Path $PSScriptRoot 'decision-depth.ps1') } catch {}
}

# Model id for the Gemini-tier proposer + cheap-tier calls. Hard policy: flash, never pro.
$script:SynthGeminiModel = 'gemini-2.5-flash'

# ---------------------------------------------------------------------------------------------------
# JSON extraction + artifact I/O
# ---------------------------------------------------------------------------------------------------

function ConvertFrom-SynthesisJson {
  # Robustly pull a JSON object out of an LLM text reply. LLMs wrap JSON in prose / ```json fences /
  # leading apologies. Strategy: strip code fences, then take the OUTERMOST {...} (first '{' to last
  # '}') and ConvertFrom-Json. On any failure return $null (the caller decides what to do).
  param([string]$Reply)
  if ([string]::IsNullOrWhiteSpace($Reply)) { return $null }
  $t = [string]$Reply

  # 1. Strip ```json ... ``` (or plain ```) fences if present.
  $fence = [regex]::Match($t, '(?s)```(?:json)?\s*(\{.*\})\s*```')
  if ($fence.Success) { $t = $fence.Groups[1].Value }

  # 2. Take the outermost object: first '{' through last '}'.
  $first = $t.IndexOf('{')
  $last  = $t.LastIndexOf('}')
  if ($first -lt 0 -or $last -lt $first) { return $null }
  $candidate = $t.Substring($first, ($last - $first + 1))

  try { return ($candidate | ConvertFrom-Json) } catch { return $null }
}

function Get-SynthArrayField {
  # Read an array field and return a CLEAN flat array of its elements. Works around the interaction
  # between Get-ArtifactField's -NoEnumerate emit and PowerShell's @() capture, which can double-wrap
  # a single-element array (yielding @( @(elem) ) where each iterated item is itself a 1-elem array).
  param($Obj, [string]$Name)
  $v = Get-ArtifactField -Obj $Obj -Name $Name
  if ($null -eq $v) { return @() }
  $out = New-Object System.Collections.Generic.List[object]
  foreach ($e in @($v)) {
    if (($e -is [System.Collections.IEnumerable]) -and ($e -isnot [string]) -and ($e -isnot [System.Collections.IDictionary])) {
      foreach ($inner in $e) { $out.Add($inner) }   # unwrap one accidental nesting level
    } else {
      $out.Add($e)
    }
  }
  return @($out.ToArray())
}

function Write-SynthesisArtifact {
  # Serialize $Obj to <Dir>/<Name> as UTF-8 NO BOM (data file, parsed by ConvertFrom-Json).
  param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Obj)
  if (-not (Test-Path -LiteralPath $Dir)) { New-Item -Force -ItemType Directory -Path $Dir | Out-Null }
  $path = Join-Path $Dir $Name
  $json = $Obj | ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
  return $path
}

function Read-SynthesisArtifact {
  # Read <Dir>/<Name> and ConvertFrom-Json. Returns $null if missing/unparseable.
  param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string]$Name)
  $path = Join-Path $Dir $Name
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try {
    $raw = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false))
    return ($raw | ConvertFrom-Json)
  } catch { return $null }
}

# ---------------------------------------------------------------------------------------------------
# Model adapters -- normalize the 3 invokers to "give me the reply text or $null".
# ---------------------------------------------------------------------------------------------------

function Get-SynthReplyText {
  # Invoke-Planner / Invoke-Coder return @{ text; status; ... }; pull .text if status looks ok.
  param($Res)
  if ($null -eq $Res) { return $null }
  $status = $null
  try { $status = [string]$Res.status } catch {}
  if ($status -and $status -ne 'ok') { return $null }
  $text = $null
  try { $text = [string]$Res.text } catch {}
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }
  return $text
}

function Invoke-SynthClaude {
  # Claude / Planner proposer. Returns reply text or $null.
  param([string]$Prompt)
  try { return (Get-SynthReplyText (Invoke-Planner -Prompt $Prompt -Mode 'advisory' -NoFallback)) } catch { return $null }
}

function Invoke-SynthCoder {
  # Codex / Coder proposer. Returns reply text or $null.
  param([string]$Prompt)
  try { return (Get-SynthReplyText (Invoke-Coder -Prompt $Prompt -Mode 'code' -NoFallback)) } catch { return $null }
}

function Invoke-SynthGemini {
  # Gemini-tier / cheap-tier call. Invoke-LLM returns the reply STRING directly (or $null).
  # Hard model policy: explicit gemini-2.5-flash.
  param([string]$Prompt, [string]$Purpose = 'synthesis')
  try {
    $r = Invoke-LLM -Model $script:SynthGeminiModel -Purpose $Purpose -Prompt $Prompt -TimeoutSec 120 -Temperature 0.3
    if ([string]::IsNullOrWhiteSpace([string]$r)) { return $null }
    return [string]$r
  } catch { return $null }
}

# ---------------------------------------------------------------------------------------------------
# Generic stage runner: prompt -> model -> JSON -> validate (retry once) -> object (or $null)
# ---------------------------------------------------------------------------------------------------

function Invoke-SynthesisStage {
  # Calls $Invoker (scriptblock: param($prompt) -> reply text or $null) with $Prompt, extracts JSON,
  # validates with $Validator (scriptblock: param($obj,[ref]$errs) -> bool). On invalid/empty, retries
  # the call ONCE with a corrective suffix. Returns the validated object or $null.
  param(
    [Parameter(Mandatory)][scriptblock]$Invoker,
    [Parameter(Mandatory)][string]$Prompt,
    [Parameter(Mandatory)][scriptblock]$Validator
  )
  for ($attempt = 1; $attempt -le 2; $attempt++) {
    $p = if ($attempt -eq 1) { $Prompt } else {
      $Prompt + "`n`nIMPORTANT: your previous reply was missing or did not match the required JSON shape. " +
      "Return ONLY one valid JSON object, no prose, no markdown fences, conforming exactly to the schema above."
    }
    $reply = & $Invoker $p
    $obj = ConvertFrom-SynthesisJson -Reply ([string]$reply)
    if ($null -ne $obj) {
      $errsRef = [ref]@()
      $ok = & $Validator $obj $errsRef
      if ($ok) { return $obj }
    }
  }
  return $null
}

# ---------------------------------------------------------------------------------------------------
# Prompt builders (STATELESS -- everything the model needs goes in the prompt)
# ---------------------------------------------------------------------------------------------------

function Get-SynthSchemaText {
  param([Parameter(Mandatory)][string]$Which)
  $s = switch ($Which) {
    'task_contract'  { Get-TaskContractSchema }
    'proposal'       { Get-ProposalSchema }
    'decision_atoms' { Get-DecisionAtomsSchema }
    'conflict_matrix'{ Get-ConflictMatrixSchema }
    'judge'          { Get-JudgeSynthesisSchema }
    'micro_debate'   { Get-MicroDebateSchema }
    'final_record'   { Get-FinalDecisionRecordSchema }
    default          { @{} }
  }
  return ($s | ConvertTo-Json -Depth 8)
}

# ---------------------------------------------------------------------------------------------------
# STAGE 1: TaskContract
# ---------------------------------------------------------------------------------------------------

function Invoke-SynthesisTaskContract {
  param([Parameter(Mandatory)][string]$Task, [string]$Channel = $null, [Parameter(Mandatory)][string]$DecisionId)
  $dir = Get-ChannelDecisionsDir -Slug $Channel -DecisionId $DecisionId
  $schema = Get-SynthSchemaText -Which 'task_contract'
  $prompt = @"
You are formalizing a task into a TaskContract for a multi-model decision pipeline.
TASK (verbatim):
$Task

Produce a single JSON object matching this TaskContract schema (field -> description):
$schema

Rules:
- task_type is one of: architecture, bugfix, refactor, infra, research, creative.
- risk is one of: low, medium, high, critical. allowed_complexity is one of: low, medium, high.
- constraints and known_context are arrays of strings (may be empty).
- success_tests MUST be a NON-EMPTY array of concrete checks that prove the task is solved.
Return ONLY the JSON object.
"@
  $obj = Invoke-SynthesisStage -Invoker { param($p) Invoke-SynthGemini -Prompt $p -Purpose 'synthesis-contract' } `
    -Prompt $prompt -Validator { param($o, $e) Test-TaskContract $o $e }
  if ($null -eq $obj) { throw "Invoke-SynthesisTaskContract: model failed to produce a valid TaskContract" }
  [void](Write-SynthesisArtifact -Dir $dir -Name 'task_contract.json' -Obj $obj)
  return $obj
}

# ---------------------------------------------------------------------------------------------------
# STAGE 2: Proposals (3 BLIND proposers)
# ---------------------------------------------------------------------------------------------------

function Get-SynthProposalPrompt {
  param([Parameter(Mandatory)]$Contract, [Parameter(Mandatory)][string]$Proposer)
  $contractJson = $Contract | ConvertTo-Json -Depth 10
  $schema = Get-SynthSchemaText -Which 'proposal'
  return @"
You are an independent solver. Read the TaskContract and produce YOUR OWN proposal. You do NOT see any
other proposal and you have NO assigned role -- just solve the task on its merits.

TASK CONTRACT (JSON):
$contractJson

Produce a single JSON object matching this Proposal schema (field -> description):
$schema

Rules:
- proposer MUST be exactly "$Proposer".
- decision_atoms is an array; each atom = { statement, reason, tradeoff, confidence (number 0..1) }.
- risks is an array of { risk, severity (low|medium|high), mitigation }.
- assumptions is a string array. minimal_version and advanced_version are strings.
Return ONLY the JSON object.
"@
}

function Invoke-SynthesisProposals {
  param([string]$Channel = $null, [Parameter(Mandatory)][string]$DecisionId)
  $dir = Get-ChannelDecisionsDir -Slug $Channel -DecisionId $DecisionId
  $contract = Read-SynthesisArtifact -Dir $dir -Name 'task_contract.json'
  if ($null -eq $contract) { throw "Invoke-SynthesisProposals: task_contract.json missing" }

  # Proposer A = Coder (Codex), B = Planner (Claude), C = LLM proposer (Gemini-tier). All BLIND.
  $plan = @(
    @{ proposer = 'A'; file = 'proposal_A.json'; invoker = { param($p) Invoke-SynthCoder  -Prompt $p } },
    @{ proposer = 'B'; file = 'proposal_B.json'; invoker = { param($p) Invoke-SynthClaude -Prompt $p } },
    @{ proposer = 'C'; file = 'proposal_C.json'; invoker = { param($p) Invoke-SynthGemini -Prompt $p -Purpose 'synthesis-propose' } }
  )

  $ok = 0
  $results = @{}
  foreach ($pl in $plan) {
    $prompt = Get-SynthProposalPrompt -Contract $contract -Proposer $pl.proposer
    $obj = Invoke-SynthesisStage -Invoker $pl.invoker -Prompt $prompt -Validator { param($o, $e) Test-Proposal $o $e }
    if ($null -ne $obj) {
      [void](Write-SynthesisArtifact -Dir $dir -Name $pl.file -Obj $obj)
      $results[$pl.proposer] = $obj
      $ok++
    }
  }
  # DEGRADE: >=2 ok continue; <2 throw.
  if ($ok -lt 2) { throw "Invoke-SynthesisProposals: only $ok/3 proposers produced a valid proposal (need >=2)" }
  return $results
}

# ---------------------------------------------------------------------------------------------------
# STAGE 3: Normalize -> DecisionAtoms
# ---------------------------------------------------------------------------------------------------

function Get-SynthProposalsForPrompt {
  # Collect whatever proposals exist on disk (A/B/C) as a compact JSON blob for prompts.
  param([Parameter(Mandatory)][string]$Dir)
  $out = [ordered]@{}
  foreach ($p in @('A', 'B', 'C')) {
    $o = Read-SynthesisArtifact -Dir $Dir -Name ("proposal_$p.json")
    if ($null -ne $o) { $out[$p] = $o }
  }
  return ($out | ConvertTo-Json -Depth 10)
}

function Invoke-SynthesisNormalize {
  param([string]$Channel = $null, [Parameter(Mandatory)][string]$DecisionId)
  $dir = Get-ChannelDecisionsDir -Slug $Channel -DecisionId $DecisionId
  $proposalsJson = Get-SynthProposalsForPrompt -Dir $dir
  $schema = Get-SynthSchemaText -Which 'decision_atoms'
  $prompt = @"
You are normalizing multiple independent proposals (A/B/C) into a single de-duplicated set of
decision atoms. Merge atoms that say the same thing; keep a stable atom_id for each.

PROPOSALS (JSON, keyed by proposer):
$proposalsJson

Produce a single JSON object matching this DecisionAtoms schema:
$schema

Rules:
- Each atom = { atom_id, statement, source_proposals (NON-EMPTY array of the proposers A|B|C that
  proposed it), category, test (a concrete check), reversibility (low|medium|high),
  implementation_cost (low|medium|high) }.
- An atom shared by two proposers cites BOTH in source_proposals. Never invent an atom no proposer made.
Return ONLY the JSON object.
"@
  $obj = Invoke-SynthesisStage -Invoker { param($p) Invoke-SynthGemini -Prompt $p -Purpose 'synthesis-normalize' } `
    -Prompt $prompt -Validator { param($o, $e) Test-DecisionAtoms $o $e }
  if ($null -eq $obj) { throw "Invoke-SynthesisNormalize: model failed to produce valid DecisionAtoms" }
  [void](Write-SynthesisArtifact -Dir $dir -Name 'decision_atoms.json' -Obj $obj)
  return $obj
}

# ---------------------------------------------------------------------------------------------------
# STAGE 4: ConflictMatrix (deterministic consensus + one cheap call for semantic conflicts)
# ---------------------------------------------------------------------------------------------------

function Get-SynthAtomList {
  param($AtomsObj)
  return (Get-SynthArrayField -Obj $AtomsObj -Name 'atoms')
}

function Invoke-SynthesisConflictMatrix {
  param([string]$Channel = $null, [Parameter(Mandatory)][string]$DecisionId, [int]$ConsensusThreshold = 2)
  $dir = Get-ChannelDecisionsDir -Slug $Channel -DecisionId $DecisionId
  $atomsObj = Read-SynthesisArtifact -Dir $dir -Name 'decision_atoms.json'
  if ($null -eq $atomsObj) { throw "Invoke-SynthesisConflictMatrix: decision_atoms.json missing" }
  $atoms = Get-SynthAtomList $atomsObj

  # Deterministic consensus: atom is consensus if cited by >= threshold proposers.
  $consensus = New-Object System.Collections.Generic.List[string]
  foreach ($a in $atoms) {
    $src = Get-ArtifactField -Obj $a -Name 'source_proposals'
    $id  = [string](Get-ArtifactField -Obj $a -Name 'atom_id')
    if ($null -ne $src -and @($src).Count -ge $ConsensusThreshold -and $id) { $consensus.Add($id) }
  }

  # Cheap LLM call for SEMANTIC conflicts (atoms that contradict each other on some axis).
  $atomsJson = $atomsObj | ConvertTo-Json -Depth 10
  $schema = Get-SynthSchemaText -Which 'conflict_matrix'
  $prompt = @"
You are detecting SEMANTIC CONFLICTS between decision atoms: pairs (or groups) of atoms that
contradict each other or cannot both hold.

DECISION ATOMS (JSON):
$atomsJson

Produce a single JSON object matching this ConflictMatrix schema:
$schema

Rules:
- consensus_atoms: array of atom_id strings that are broadly agreed and non-conflicting.
- conflicts: array of { atom_ids (length >= 2), axis (what they disagree on), impact (low|medium|high) }.
- If there are no conflicts, return conflicts as an empty array.
- Do NOT include a reviews field (added by a later stage).
Return ONLY the JSON object.
"@
  $obj = Invoke-SynthesisStage -Invoker { param($p) Invoke-SynthGemini -Prompt $p -Purpose 'synthesis-conflicts' } `
    -Prompt $prompt -Validator { param($o, $e) Test-ConflictMatrix $o $e }

  if ($null -eq $obj) {
    # Degrade to a deterministic-only matrix (consensus computed locally, no semantic conflicts).
    $obj = [ordered]@{ consensus_atoms = @($consensus.ToArray()); conflicts = @() }
  } else {
    # Prefer the deterministic consensus list (authoritative by source_proposals count).
    $obj = Convert-ToOrderedHashtable $obj
    $obj['consensus_atoms'] = @($consensus.ToArray())
    if (-not $obj.Contains('conflicts') -or $null -eq $obj['conflicts']) { $obj['conflicts'] = @() }
  }
  [void](Write-SynthesisArtifact -Dir $dir -Name 'conflict_matrix.json' -Obj $obj)
  return $obj
}

function Convert-ToOrderedHashtable {
  # Shallow PSCustomObject/hashtable -> ordered hashtable so we can mutate/append fields safely.
  param($Obj)
  $h = [ordered]@{}
  if ($null -eq $Obj) { return $h }
  if ($Obj -is [System.Collections.IDictionary]) {
    foreach ($k in $Obj.Keys) { $h[[string]$k] = $Obj[$k] }
  } else {
    foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
  }
  return $h
}

# ---------------------------------------------------------------------------------------------------
# STAGE 5: CrossReview (review only conflicting/low-confidence atoms; append to conflict_matrix.reviews[])
# ---------------------------------------------------------------------------------------------------

function Invoke-SynthesisCrossReview {
  param([string]$Channel = $null, [Parameter(Mandatory)][string]$DecisionId)
  $dir = Get-ChannelDecisionsDir -Slug $Channel -DecisionId $DecisionId
  $matrix = Read-SynthesisArtifact -Dir $dir -Name 'conflict_matrix.json'
  if ($null -eq $matrix) { throw "Invoke-SynthesisCrossReview: conflict_matrix.json missing" }
  $atomsObj = Read-SynthesisArtifact -Dir $dir -Name 'decision_atoms.json'

  # Which atom_ids to review: any atom appearing in a conflict.
  $targetIds = New-Object System.Collections.Generic.HashSet[string]
  foreach ($cf in (Get-SynthArrayField -Obj $matrix -Name 'conflicts')) {
    foreach ($id in (Get-SynthArrayField -Obj $cf -Name 'atom_ids')) { if ($id) { [void]$targetIds.Add([string]$id) } }
  }

  $matrixH = Convert-ToOrderedHashtable $matrix
  if (-not $matrixH.Contains('reviews') -or $null -eq $matrixH['reviews']) { $matrixH['reviews'] = @() }

  if ($targetIds.Count -gt 0) {
    $atomsJson = $atomsObj | ConvertTo-Json -Depth 10
    $idsJson = (@($targetIds) | ConvertTo-Json -Depth 3)
    $schema = Get-SynthSchemaText -Which 'conflict_matrix'
    $prompt = @"
You are cross-reviewing ONLY the conflicting / low-confidence atoms below. For each real problem,
emit an objection. "No significant issues" is a VALID outcome (return an empty reviews array).

ALL DECISION ATOMS (JSON):
$atomsJson

ATOM IDs TO REVIEW:
$idsJson

Produce a single JSON object with a "reviews" array matching this schema's reviews shape:
$schema

Each review (objection) = { atom_id, severity (minor|major|blocking), why, fix, cost (low|medium|high) }.
Only include reviews for atoms with a genuine issue. Return ONLY the JSON object.
"@
    $reviewObj = Invoke-SynthesisStage -Invoker { param($p) Invoke-SynthGemini -Prompt $p -Purpose 'synthesis-review' } `
      -Prompt $prompt -Validator { param($o, $e) Test-ConflictMatrix $o $e }
    if ($null -ne $reviewObj) {
      $rv = Get-ArtifactField -Obj $reviewObj -Name 'reviews'
      if ($null -ne $rv) { $matrixH['reviews'] = @($rv) }
    }
  }

  [void](Write-SynthesisArtifact -Dir $dir -Name 'conflict_matrix.json' -Obj $matrixH)
  return $matrixH
}

# ---------------------------------------------------------------------------------------------------
# STAGE 6: Judge (model selected by task_type)
# ---------------------------------------------------------------------------------------------------

$script:SynthJudgeWeights = @{
  correctness    = 0.25
  feasibility    = 0.20
  impact         = 0.20
  simplicity     = 0.15
  risk_reduction = 0.10
  specificity    = 0.10
}

function Get-SynthJudgeInvoker {
  # architecture -> Planner (Claude); bugfix/refactor/infra -> Coder (Codex);
  # research/creative -> LLM (Gemini-tier).
  param([string]$TaskType)
  switch ($TaskType) {
    'architecture' { return { param($p) Invoke-SynthClaude -Prompt $p } }
    'bugfix'       { return { param($p) Invoke-SynthCoder  -Prompt $p } }
    'refactor'     { return { param($p) Invoke-SynthCoder  -Prompt $p } }
    'infra'        { return { param($p) Invoke-SynthCoder  -Prompt $p } }
    'research'     { return { param($p) Invoke-SynthGemini -Prompt $p -Purpose 'synthesis-judge' } }
    'creative'     { return { param($p) Invoke-SynthGemini -Prompt $p -Purpose 'synthesis-judge' } }
    default        { return { param($p) Invoke-SynthClaude -Prompt $p } }
  }
}

function Invoke-SynthesisJudge {
  param([string]$Channel = $null, [Parameter(Mandatory)][string]$DecisionId)
  $dir = Get-ChannelDecisionsDir -Slug $Channel -DecisionId $DecisionId
  $atomsObj = Read-SynthesisArtifact -Dir $dir -Name 'decision_atoms.json'
  if ($null -eq $atomsObj) { throw "Invoke-SynthesisJudge: decision_atoms.json missing" }
  $contract = Read-SynthesisArtifact -Dir $dir -Name 'task_contract.json'
  $matrix   = Read-SynthesisArtifact -Dir $dir -Name 'conflict_matrix.json'   # may be absent in Standard

  $taskType = [string](Get-ArtifactField -Obj $contract -Name 'task_type')
  if ([string]::IsNullOrWhiteSpace($taskType)) { $taskType = 'architecture' }
  $invoker = Get-SynthJudgeInvoker -TaskType $taskType

  $atomsJson = $atomsObj | ConvertTo-Json -Depth 10
  $matrixJson = if ($null -ne $matrix) { $matrix | ConvertTo-Json -Depth 10 } else { '(none)' }
  $schema = Get-SynthSchemaText -Which 'judge'
  $weightsJson = $script:SynthJudgeWeights | ConvertTo-Json -Compress
  $prompt = @"
You are the JUDGE. For each decision atom, give a verdict and per-criterion scores, then a weighted total.

DECISION ATOMS (JSON):
$atomsJson

CONFLICT MATRIX (JSON):
$matrixJson

Produce a single JSON object matching this JudgeSynthesis schema:
$schema

Rules per atom = { atom_id, verdict (accept|modify|reject),
  scores { correctness, feasibility, impact, simplicity, risk_reduction, specificity } (each 0..1),
  penalties (array, may be empty), total (number), reason (string) }.
total = weighted sum of scores with weights: $weightsJson (then subtract penalties).
Return ONLY the JSON object.
"@
  $obj = Invoke-SynthesisStage -Invoker $invoker -Prompt $prompt -Validator { param($o, $e) Test-JudgeSynthesis $o $e }
  if ($null -eq $obj) { throw "Invoke-SynthesisJudge: model failed to produce valid JudgeSynthesis" }

  # Deterministically recompute total from the model's scores (defense against arithmetic drift).
  $obj = Convert-ToOrderedHashtable $obj
  $jatoms = Get-SynthArrayField -Obj $obj -Name 'atoms'
  foreach ($ja in $jatoms) {
    $scores = Get-ArtifactField -Obj $ja -Name 'scores'
    if ($null -ne $scores) {
      $sum = 0.0
      foreach ($k in $script:SynthJudgeWeights.Keys) {
        $sv = Get-ArtifactField -Obj $scores -Name $k
        if (Test-ArtifactIsNumber $sv) { $sum += ([double]$sv * $script:SynthJudgeWeights[$k]) }
      }
      $pen = Get-SynthArrayField -Obj $ja -Name 'penalties'
      $penSum = 0.0
      foreach ($pp in $pen) { if (Test-ArtifactIsNumber $pp) { $penSum += [double]$pp } }
      try {
        if ($ja -is [System.Collections.IDictionary]) { $ja['total'] = [Math]::Round($sum - $penSum, 4) }
        else { $ja | Add-Member -NotePropertyName 'total' -NotePropertyValue ([Math]::Round($sum - $penSum, 4)) -Force }
      } catch {}
    }
  }
  [void](Write-SynthesisArtifact -Dir $dir -Name 'judge_synthesis.json' -Obj $obj)
  return $obj
}

# ---------------------------------------------------------------------------------------------------
# STAGE 7: MicroDebate (only for high-impact unresolved conflicts; capped)
# ---------------------------------------------------------------------------------------------------

function Test-SynthJudgeUnresolved {
  # An atom verdict is "unresolved" if it is 'modify' or 'reject' (not a clean accept).
  param($JudgeObj, [string[]]$AtomIds)
  if ($null -eq $JudgeObj) { return $true }
  foreach ($ja in (Get-SynthArrayField -Obj $JudgeObj -Name 'atoms')) {
    $id = [string](Get-ArtifactField -Obj $ja -Name 'atom_id')
    if ($AtomIds -contains $id) {
      $v = [string](Get-ArtifactField -Obj $ja -Name 'verdict')
      if ($v -ne 'accept') { return $true }
    }
  }
  return $false
}

function Invoke-SynthesisMicroDebate {
  param([string]$Channel = $null, [Parameter(Mandatory)][string]$DecisionId, [int]$MaxTopics = 3, [int]$MaxRounds = 2)
  $dir = Get-ChannelDecisionsDir -Slug $Channel -DecisionId $DecisionId
  $matrix = Read-SynthesisArtifact -Dir $dir -Name 'conflict_matrix.json'
  $judge  = Read-SynthesisArtifact -Dir $dir -Name 'judge_synthesis.json'

  # Eligible topics: conflicts with impact=high AND a still-unresolved judge verdict on an involved atom.
  $topics = New-Object System.Collections.Generic.List[object]
  foreach ($cf in (Get-SynthArrayField -Obj $matrix -Name 'conflicts')) {
    if ($topics.Count -ge $MaxTopics) { break }
    $impact = [string](Get-ArtifactField -Obj $cf -Name 'impact')
    if ($impact -ne 'high') { continue }
    $ids = @(Get-SynthArrayField -Obj $cf -Name 'atom_ids' | ForEach-Object { [string]$_ })
    if (-not (Test-SynthJudgeUnresolved -JudgeObj $judge -AtomIds $ids)) { continue }
    $topics.Add([ordered]@{ atom_ids = $ids; rounds = @() })
  }

  if ($topics.Count -eq 0) {
    $obj = [ordered]@{ skipped = $true; topics = @() }
    $errsRef = [ref]@(); [void](Test-MicroDebate $obj $errsRef)
    [void](Write-SynthesisArtifact -Dir $dir -Name 'micro_debate.json' -Obj $obj)
    return $obj
  }

  # Run capped debate via the cheap tier (a few short rounds per topic).
  $atomsObj = Read-SynthesisArtifact -Dir $dir -Name 'decision_atoms.json'
  $atomsJson = $atomsObj | ConvertTo-Json -Depth 10
  $debated = New-Object System.Collections.Generic.List[object]
  foreach ($t in $topics) {
    $idsJson = ($t.atom_ids | ConvertTo-Json -Depth 3)
    $prompt = @"
Micro-debate (max $MaxRounds short rounds) over these conflicting atoms. Each round: one argument FOR
and one AGAINST, then a one-line resolution.

ATOMS (JSON):
$atomsJson

ATOM IDs IN CONFLICT:
$idsJson

Return ONLY a JSON object: { "atom_ids": [...], "rounds": [ { "for": "...", "against": "...", "resolution": "..." } ] }
(at most $MaxRounds rounds).
"@
    $r = Invoke-SynthGemini -Prompt $prompt -Purpose 'synthesis-debate'
    $robj = ConvertFrom-SynthesisJson -Reply ([string]$r)
    $rounds = @()
    if ($null -ne $robj) {
      $rr = Get-SynthArrayField -Obj $robj -Name 'rounds'
      if (@($rr).Count -gt 0) { $rounds = @($rr); if ($rounds.Count -gt $MaxRounds) { $rounds = @($rounds[0..($MaxRounds - 1)]) } }
    }
    $debated.Add([ordered]@{ atom_ids = $t.atom_ids; rounds = $rounds })
  }

  $obj = [ordered]@{ skipped = $false; topics = @($debated.ToArray()) }
  $errsRef = [ref]@()
  if (-not (Test-MicroDebate $obj $errsRef)) {
    # Fall back to a valid skipped record rather than write an invalid artifact.
    $obj = [ordered]@{ skipped = $true; topics = @() }
  }
  [void](Write-SynthesisArtifact -Dir $dir -Name 'micro_debate.json' -Obj $obj)
  return $obj
}

# ---------------------------------------------------------------------------------------------------
# STAGE 8: FinalV2 (fold debate) + RedTeam (try to break) -> FinalDecisionRecord
# ---------------------------------------------------------------------------------------------------

function Invoke-SynthesisFinalV2 {
  param([string]$Channel = $null, [Parameter(Mandatory)][string]$DecisionId)
  $dir = Get-ChannelDecisionsDir -Slug $Channel -DecisionId $DecisionId
  $contract = Read-SynthesisArtifact -Dir $dir -Name 'task_contract.json'
  $atomsObj = Read-SynthesisArtifact -Dir $dir -Name 'decision_atoms.json'
  $judge    = Read-SynthesisArtifact -Dir $dir -Name 'judge_synthesis.json'
  $matrix   = Read-SynthesisArtifact -Dir $dir -Name 'conflict_matrix.json'
  $debate   = Read-SynthesisArtifact -Dir $dir -Name 'micro_debate.json'

  $contractJson = $contract | ConvertTo-Json -Depth 10
  $atomsJson    = $atomsObj | ConvertTo-Json -Depth 10
  $judgeJson    = if ($null -ne $judge)  { $judge  | ConvertTo-Json -Depth 10 } else { '(none)' }
  $matrixJson   = if ($null -ne $matrix) { $matrix | ConvertTo-Json -Depth 10 } else { '(none)' }
  $debateJson   = if ($null -ne $debate) { $debate | ConvertTo-Json -Depth 10 } else { '(none)' }
  $schema = Get-SynthSchemaText -Which 'final_record'
  $prompt = @"
You are writing the FINAL DECISION RECORD. Fold in the judge's verdicts and any micro-debate
resolutions. Accept the high-scoring atoms, reject the rest with a reason.

TASK CONTRACT:
$contractJson
DECISION ATOMS:
$atomsJson
JUDGE:
$judgeJson
CONFLICT MATRIX:
$matrixJson
MICRO DEBATE:
$debateJson

Produce a single JSON object matching this FinalDecisionRecord schema:
$schema

Rules:
- final_answer: a clear prose answer. next_step: the single next action.
- decisions: array of { decision, rationale, alternatives_considered (array), risk, test }.
- rejected: array of { decision, why }. open_questions: string array. implementation_plan: array.
Return ONLY the JSON object.
"@
  $obj = Invoke-SynthesisStage -Invoker { param($p) Invoke-SynthClaude -Prompt $p } `
    -Prompt $prompt -Validator { param($o, $e) Test-FinalDecisionRecord $o $e }
  if ($null -eq $obj) { throw "Invoke-SynthesisFinalV2: model failed to produce a valid FinalDecisionRecord" }
  [void](Write-SynthesisArtifact -Dir $dir -Name 'final_decision_record.json' -Obj $obj)
  return $obj
}

function Invoke-SynthesisRedTeam {
  param([string]$Channel = $null, [Parameter(Mandatory)][string]$DecisionId)
  $dir = Get-ChannelDecisionsDir -Slug $Channel -DecisionId $DecisionId
  $record = Read-SynthesisArtifact -Dir $dir -Name 'final_decision_record.json'
  if ($null -eq $record) { throw "Invoke-SynthesisRedTeam: final_decision_record.json missing" }
  $contract = Read-SynthesisArtifact -Dir $dir -Name 'task_contract.json'

  $recordJson = $record | ConvertTo-Json -Depth 10
  $contractJson = $contract | ConvertTo-Json -Depth 10
  $prompt = @"
You are a RED TEAM. Try to BREAK this final decision: find failure modes, violated constraints,
unhandled edge cases, or unmet success_tests.

TASK CONTRACT:
$contractJson
FINAL DECISION RECORD:
$recordJson

Return ONLY a JSON object: { "findings": [ { "severity": "low|medium|high", "what": "...", "why": "..." } ] }.
If the decision holds up, return an empty findings array.
"@
  $rtReply = Invoke-SynthClaude -Prompt $prompt
  $rtObj = ConvertFrom-SynthesisJson -Reply ([string]$rtReply)
  $findings = @()
  if ($null -ne $rtObj) { $findings = Get-SynthArrayField -Obj $rtObj -Name 'findings' }

  $hasHigh = $false
  foreach ($fd in $findings) {
    if ([string](Get-ArtifactField -Obj $fd -Name 'severity') -eq 'high') { $hasHigh = $true; break }
  }

  $recordH = Convert-ToOrderedHashtable $record
  $recordH['red_team_findings'] = @($findings)

  if ($hasHigh) {
    # One re-judge loop max, then re-fold; if it still breaks, hand to operator.
    try {
      [void](Invoke-SynthesisJudge -Channel $Channel -DecisionId $DecisionId)
      $rejudged = Invoke-SynthesisFinalV2 -Channel $Channel -DecisionId $DecisionId
      $recordH = Convert-ToOrderedHashtable $rejudged
      $recordH['red_team_findings'] = @($findings)
      $recordH['needs_operator'] = $true   # high-sev break surfaced -> human gate even after re-judge
      $recordH['red_team_rejudged'] = $true
    } catch {
      $recordH['needs_operator'] = $true
      $recordH['red_team_rejudged'] = $false
    }
  }

  [void](Write-SynthesisArtifact -Dir $dir -Name 'final_decision_record.json' -Obj $recordH)
  return $recordH
}

# ---------------------------------------------------------------------------------------------------
# Simple-depth: cheap single best-effort answer record
# ---------------------------------------------------------------------------------------------------

function Invoke-SynthesisSimpleRecord {
  param([string]$Channel = $null, [Parameter(Mandatory)][string]$DecisionId)
  $dir = Get-ChannelDecisionsDir -Slug $Channel -DecisionId $DecisionId
  $contract = Read-SynthesisArtifact -Dir $dir -Name 'task_contract.json'
  $contractJson = $contract | ConvertTo-Json -Depth 10
  $schema = Get-SynthSchemaText -Which 'final_record'
  $prompt = @"
Answer this task directly and concisely (it is low-complexity; no multi-model pipeline needed).

TASK CONTRACT:
$contractJson

Produce a single JSON object matching this FinalDecisionRecord schema:
$schema

Rules: final_answer and next_step are strings; decisions/rejected/open_questions/implementation_plan
are arrays (may be empty except provide at least the final_answer and next_step). Return ONLY the JSON.
"@
  $obj = Invoke-SynthesisStage -Invoker { param($p) Invoke-SynthGemini -Prompt $p -Purpose 'synthesis-simple' } `
    -Prompt $prompt -Validator { param($o, $e) Test-FinalDecisionRecord $o $e }
  if ($null -eq $obj) { throw "Invoke-SynthesisSimpleRecord: model failed to produce a valid record" }
  [void](Write-SynthesisArtifact -Dir $dir -Name 'final_decision_record.json' -Obj $obj)
  return $obj
}

# ---------------------------------------------------------------------------------------------------
# SEQUENCER
# ---------------------------------------------------------------------------------------------------

function New-SynthesisDecisionId {
  return ('dec-' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6)))
}

function Set-SynthRecordNeedsOperator {
  # Read the on-disk record, force needs_operator=$true, rewrite. Returns the mutated object.
  param([Parameter(Mandatory)][string]$Dir, $Record = $null)
  $rec = $Record
  if ($null -eq $rec) { $rec = Read-SynthesisArtifact -Dir $Dir -Name 'final_decision_record.json' }
  $h = Convert-ToOrderedHashtable $rec
  $h['needs_operator'] = $true
  [void](Write-SynthesisArtifact -Dir $Dir -Name 'final_decision_record.json' -Obj $h)
  return $h
}

function Invoke-SynthesisPipeline {
  # The sequencer. Computes depth (Get-SynthesisDepthDecision) if -Depth not given, then runs the
  # right subset. Each stage checkpoints its artifact to disk. A stage failure is logged and the
  # function returns a record with needs_operator=$true rather than throwing.
  param(
    [Parameter(Mandatory)][string]$Task,
    [string]$Channel = $null,
    [string]$Depth = '',
    [string]$DecisionId = ''
  )
  if ([string]::IsNullOrWhiteSpace($DecisionId)) { $DecisionId = New-SynthesisDecisionId }
  $dir = Get-ChannelDecisionsDir -Slug $Channel -DecisionId $DecisionId

  if ([string]::IsNullOrWhiteSpace($Depth)) {
    $d = Get-SynthesisDepthDecision -Text $Task
    $Depth = [string]$d.depth
  }

  try {
    # Stage 1 always: TaskContract.
    [void](Invoke-SynthesisTaskContract -Task $Task -Channel $Channel -DecisionId $DecisionId)

    switch ($Depth) {
      'Simple' {
        $rec = Invoke-SynthesisSimpleRecord -Channel $Channel -DecisionId $DecisionId
        return $rec
      }
      'Standard' {
        # contract -> proposals -> normalize -> judge -> record (NO conflict/review/debate/redteam).
        [void](Invoke-SynthesisProposals  -Channel $Channel -DecisionId $DecisionId)
        [void](Invoke-SynthesisNormalize  -Channel $Channel -DecisionId $DecisionId)
        [void](Invoke-SynthesisJudge      -Channel $Channel -DecisionId $DecisionId)
        $rec = Invoke-SynthesisFinalV2    -Channel $Channel -DecisionId $DecisionId
        return $rec
      }
      default {
        # Deep AND High-Stakes run ALL stages.
        [void](Invoke-SynthesisProposals      -Channel $Channel -DecisionId $DecisionId)
        [void](Invoke-SynthesisNormalize      -Channel $Channel -DecisionId $DecisionId)
        [void](Invoke-SynthesisConflictMatrix -Channel $Channel -DecisionId $DecisionId)
        [void](Invoke-SynthesisCrossReview    -Channel $Channel -DecisionId $DecisionId)
        [void](Invoke-SynthesisJudge          -Channel $Channel -DecisionId $DecisionId)
        [void](Invoke-SynthesisMicroDebate    -Channel $Channel -DecisionId $DecisionId)
        [void](Invoke-SynthesisFinalV2        -Channel $Channel -DecisionId $DecisionId)
        $rec = Invoke-SynthesisRedTeam        -Channel $Channel -DecisionId $DecisionId
        if ($Depth -eq 'High-Stakes') {
          # Human gate: always require operator sign-off on high-stakes decisions.
          $rec = Set-SynthRecordNeedsOperator -Dir $dir -Record $rec
        }
        return $rec
      }
    }
  } catch {
    $msg = $_.Exception.Message
    # Log + return a record flagged for the operator instead of throwing.
    try {
      if (Get-Command Write-DecisionShadowSignal -ErrorAction SilentlyContinue) {
        Write-DecisionShadowSignal -Reason 'synthesis-pipeline-failed' -Detail $msg -Channel ([string]$Channel) -Stage ('depth=' + $Depth)
      }
    } catch {}
    $existing = Read-SynthesisArtifact -Dir $dir -Name 'final_decision_record.json'
    $h = Convert-ToOrderedHashtable $existing
    if (-not $h.Contains('final_answer') -or [string]::IsNullOrWhiteSpace([string]$h['final_answer'])) {
      $h['final_answer'] = "Pipeline failed before producing a decision: $msg"
    }
    if (-not $h.Contains('next_step') -or [string]::IsNullOrWhiteSpace([string]$h['next_step'])) {
      $h['next_step'] = 'Operator review required (synthesis pipeline error).'
    }
    foreach ($arr in @('decisions', 'rejected', 'open_questions', 'implementation_plan')) {
      if (-not $h.Contains($arr) -or $null -eq $h[$arr]) { $h[$arr] = @() }
    }
    $h['needs_operator'] = $true
    $h['pipeline_error'] = $msg
    [void](Write-SynthesisArtifact -Dir $dir -Name 'final_decision_record.json' -Obj $h)
    return $h
  }
}
