# test-decision-synthesis.ps1 -- mock-LLM unit test for the Decision Synthesis pipeline engine.
#
# Dot-sources common.ps1 + decision-artifacts.ps1 + decision-depth.ps1 + decision-synthesis.ps1, then
# OVERRIDES Invoke-Planner / Invoke-Coder / Invoke-LLM with mocks that return canned VALID JSON keyed
# by a stage keyword in the prompt. Runs Invoke-SynthesisPipeline for a Standard and a Deep task in a
# scratch channel, asserts each expected artifact file is written and passes its Test-* validator, and
# that the returned record passes Test-FinalDecisionRecord. Prints SYNTH_TEST PASS=N/M. Cleans up.

$ErrorActionPreference = 'Stop'
$root = 'C:\Users\rafie\OneDrive\Documents\bridge'
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\decision-artifacts.ps1')
. (Join-Path $root 'lib\decision-depth.ps1')
. (Join-Path $root 'lib\decision-synthesis.ps1')

# --- isolate: redirect Get-ChannelDecisionsDir to a scratch temp dir (no real channel touched) ---
$scratchRoot = Join-Path $env:TEMP ('synthtest_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null
function Get-ChannelDecisionsDir {
  param([string]$Slug = $null, [Parameter(Mandatory)][string]$DecisionId)
  $d = Join-Path (Join-Path $scratchRoot ([string]$Slug)) $DecisionId
  if (-not (Test-Path -LiteralPath $d)) { New-Item -Force -ItemType Directory -Path $d | Out-Null }
  return $d
}

# ---------------------------------------------------------------------------------------------------
# Canned VALID artifacts (as JSON text the mocks return wrapped in prose / fences)
# ---------------------------------------------------------------------------------------------------

$canned = @{
  task_contract = @'
{ "task": "Design a caching layer", "goal": "reduce DB load", "output_format": "design doc",
  "constraints": ["no new infra"], "known_context": ["read-heavy workload"],
  "task_type": "architecture", "risk": "medium", "allowed_complexity": "high",
  "success_tests": ["p95 latency under 50ms", "cache hit rate over 80%"] }
'@
  proposal_A = @'
{ "proposer": "A", "understanding": "cache reads", "summary": "in-process LRU",
  "decision_atoms": [ { "statement": "Use an in-process LRU cache", "reason": "low latency",
    "tradeoff": "per-node memory", "confidence": 0.8 } ],
  "assumptions": ["single region"], "risks": [ { "risk": "stale data", "severity": "medium",
    "mitigation": "short TTL" } ], "minimal_version": "LRU only", "advanced_version": "LRU plus pubsub invalidation" }
'@
  proposal_B = @'
{ "proposer": "B", "understanding": "cache reads", "summary": "shared redis",
  "decision_atoms": [ { "statement": "Use an in-process LRU cache", "reason": "simplest",
    "tradeoff": "memory", "confidence": 0.7 }, { "statement": "Add a write-through path", "reason": "consistency",
    "tradeoff": "write latency", "confidence": 0.6 } ],
  "assumptions": ["redis allowed"], "risks": [ { "risk": "redis outage", "severity": "high",
    "mitigation": "fallback to DB" } ], "minimal_version": "read cache", "advanced_version": "write-through plus read cache" }
'@
  proposal_C = @'
{ "proposer": "C", "understanding": "cache reads", "summary": "cdn edge",
  "decision_atoms": [ { "statement": "Use an in-process LRU cache", "reason": "no infra",
    "tradeoff": "cold start", "confidence": 0.75 } ],
  "assumptions": ["edge ok"], "risks": [ { "risk": "edge staleness", "severity": "low",
    "mitigation": "purge api" } ], "minimal_version": "edge cache", "advanced_version": "edge plus origin shield" }
'@
  decision_atoms = @'
{ "atoms": [
  { "atom_id": "a1", "statement": "Use an in-process LRU cache", "source_proposals": ["A","B","C"],
    "category": "storage", "test": "hit rate over 80%", "reversibility": "high", "implementation_cost": "low" },
  { "atom_id": "a2", "statement": "Add a write-through path", "source_proposals": ["B"],
    "category": "consistency", "test": "no stale reads after write", "reversibility": "medium", "implementation_cost": "medium" } ] }
'@
  conflict_matrix = @'
{ "consensus_atoms": ["a1"],
  "conflicts": [ { "atom_ids": ["a1","a2"], "axis": "consistency vs simplicity", "impact": "high" } ] }
'@
  reviews = @'
{ "reviews": [ { "atom_id": "a2", "severity": "major", "why": "adds write latency",
  "fix": "make write-through async", "cost": "medium" } ] }
'@
  judge = @'
{ "atoms": [
  { "atom_id": "a1", "verdict": "accept",
    "scores": { "correctness": 0.9, "feasibility": 0.9, "impact": 0.8, "simplicity": 0.9, "risk_reduction": 0.6, "specificity": 0.7 },
    "penalties": [], "total": 0.0, "reason": "solid baseline" },
  { "atom_id": "a2", "verdict": "modify",
    "scores": { "correctness": 0.7, "feasibility": 0.6, "impact": 0.7, "simplicity": 0.4, "risk_reduction": 0.5, "specificity": 0.6 },
    "penalties": [0.05], "total": 0.0, "reason": "needs async" } ] }
'@
  micro_debate = @'
{ "atom_ids": ["a1","a2"], "rounds": [ { "for": "consistency matters", "against": "adds latency",
  "resolution": "use async write-through" } ] }
'@
  final_record = @'
{ "final_answer": "Use an in-process LRU cache with an async write-through path.",
  "decisions": [ { "decision": "Adopt in-process LRU cache", "rationale": "lowest latency, no new infra",
    "alternatives_considered": ["redis","cdn edge"], "risk": "per-node memory", "test": "hit rate over 80%" } ],
  "rejected": [ { "decision": "Synchronous write-through", "why": "adds write latency" } ],
  "open_questions": ["regional failover"], "implementation_plan": ["add LRU","add async invalidation"],
  "next_step": "Prototype the LRU layer." }
'@
  red_team = @'
{ "findings": [ { "severity": "low", "what": "cold start misses", "why": "empty cache after deploy" } ] }
'@
}

# ---------------------------------------------------------------------------------------------------
# Stage detection + mock dispatch (shared by all 3 mocked invokers)
# ---------------------------------------------------------------------------------------------------

function script:Resolve-MockArtifact {
  param([string]$Prompt)
  $p = [string]$Prompt
  # Order matters: most specific keywords first.
  if ($p -match 'RED TEAM')                  { return $canned.red_team }
  if ($p -match 'FINAL DECISION RECORD')     { return $canned.final_record }   # FinalV2 builder
  if ($p -match 'Answer this task directly') { return $canned.final_record }   # Simple-depth record
  if ($p -match 'Micro-debate')              { return $canned.micro_debate }
  if ($p -match 'cross-reviewing')           { return $canned.reviews }
  if ($p -match 'SEMANTIC CONFLICTS')        { return $canned.conflict_matrix }
  if ($p -match 'You are the JUDGE')         { return $canned.judge }
  if ($p -match 'normalizing multiple')      { return $canned.decision_atoms }
  if ($p -match 'TaskContract for a multi-model') { return $canned.task_contract }
  if ($p -match 'independent solver') {
    if ($p -match 'MUST be exactly "A"') { return $canned.proposal_A }
    if ($p -match 'MUST be exactly "B"') { return $canned.proposal_B }
    if ($p -match 'MUST be exactly "C"') { return $canned.proposal_C }
  }
  return '{ "_unmatched": true }'   # invalid -> stage will retry then fail loudly
}

# Wrap the canned JSON in prose + a code fence to exercise ConvertFrom-SynthesisJson robustness.
function script:Wrap-MockReply {
  param([string]$Json)
  $fence = [char]0x60 + [char]0x60 + [char]0x60   # three backticks, built to avoid PS escape parsing
  return ("Sure, here is the result:`n" + $fence + "json`n" + $Json + "`n" + $fence)
}

# Override the 3 invokers. Planner/Coder return @{ text; status; ... }; Invoke-LLM returns a string.
function Invoke-Planner { param([string]$Prompt, [string]$Model = '', [string]$Mode = 'normal', [switch]$NoFallback)
  [pscustomobject]@{ text = (Wrap-MockReply (Resolve-MockArtifact $Prompt)); status = 'ok'; duration = 0; errorType = $null } }
function Invoke-Coder   { param([string]$Prompt, [string]$Mode = 'code', [switch]$NoFallback)
  [pscustomobject]@{ text = (Wrap-MockReply (Resolve-MockArtifact $Prompt)); status = 'ok'; duration = 0; errorType = $null } }
function Invoke-LLM     { param([string]$Purpose = '', [string]$Model = '', [string]$Prompt, [int]$TimeoutSec = 120, [double]$Temperature = 0.3, [switch]$Thinking)
  return (Wrap-MockReply (Resolve-MockArtifact $Prompt)) }

# ---------------------------------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------------------------------

$script:pass = 0
$script:total = 0
function Assert-True { param([string]$Name, [bool]$Cond)
  $script:total++
  if ($Cond) { $script:pass++; Write-Host ("  PASS  " + $Name) }
  else { Write-Host ("  FAIL  " + $Name) -ForegroundColor Red }
}
function Assert-Artifact {
  param([string]$Dir, [string]$Name, [scriptblock]$Validator)
  $path = Join-Path $Dir $Name
  $exists = Test-Path -LiteralPath $path
  Assert-True ("$Name written") $exists
  if ($exists) {
    $obj = Read-SynthesisArtifact -Dir $Dir -Name $Name
    $errsRef = [ref]@()
    $ok = & $Validator $obj $errsRef
    Assert-True ("$Name validates") $ok
    if (-not $ok) { Write-Host ("    errors: " + (($errsRef.Value) -join '; ')) -ForegroundColor Yellow }
  }
}

# ---------------------------------------------------------------------------------------------------
# RUN: Standard depth
# ---------------------------------------------------------------------------------------------------

Write-Host '=== Standard pipeline ==='
$stdRec = Invoke-SynthesisPipeline -Task 'Design a caching layer for the read path' -Channel 'scratch-std' -Depth 'Standard' -DecisionId 'std1'
$stdDir = Get-ChannelDecisionsDir -Slug 'scratch-std' -DecisionId 'std1'
Assert-Artifact -Dir $stdDir -Name 'task_contract.json'         -Validator { param($o,$e) Test-TaskContract $o $e }
Assert-Artifact -Dir $stdDir -Name 'proposal_A.json'            -Validator { param($o,$e) Test-Proposal $o $e }
Assert-Artifact -Dir $stdDir -Name 'proposal_B.json'            -Validator { param($o,$e) Test-Proposal $o $e }
Assert-Artifact -Dir $stdDir -Name 'proposal_C.json'            -Validator { param($o,$e) Test-Proposal $o $e }
Assert-Artifact -Dir $stdDir -Name 'decision_atoms.json'       -Validator { param($o,$e) Test-DecisionAtoms $o $e }
Assert-Artifact -Dir $stdDir -Name 'judge_synthesis.json'      -Validator { param($o,$e) Test-JudgeSynthesis $o $e }
Assert-Artifact -Dir $stdDir -Name 'final_decision_record.json' -Validator { param($o,$e) Test-FinalDecisionRecord $o $e }
Assert-True 'Standard: returned record passes Test-FinalDecisionRecord' (Test-FinalDecisionRecord $stdRec ([ref]@()))
# Standard must NOT run conflict/review/debate/redteam.
Assert-True 'Standard: no conflict_matrix.json' (-not (Test-Path -LiteralPath (Join-Path $stdDir 'conflict_matrix.json')))
Assert-True 'Standard: no micro_debate.json'    (-not (Test-Path -LiteralPath (Join-Path $stdDir 'micro_debate.json')))

# ---------------------------------------------------------------------------------------------------
# RUN: Deep depth
# ---------------------------------------------------------------------------------------------------

Write-Host '=== Deep pipeline ==='
$deepRec = Invoke-SynthesisPipeline -Task 'Design a caching layer for the read path' -Channel 'scratch-deep' -Depth 'Deep' -DecisionId 'deep1'
$deepDir = Get-ChannelDecisionsDir -Slug 'scratch-deep' -DecisionId 'deep1'
Assert-Artifact -Dir $deepDir -Name 'task_contract.json'         -Validator { param($o,$e) Test-TaskContract $o $e }
Assert-Artifact -Dir $deepDir -Name 'proposal_A.json'            -Validator { param($o,$e) Test-Proposal $o $e }
Assert-Artifact -Dir $deepDir -Name 'proposal_B.json'            -Validator { param($o,$e) Test-Proposal $o $e }
Assert-Artifact -Dir $deepDir -Name 'proposal_C.json'            -Validator { param($o,$e) Test-Proposal $o $e }
Assert-Artifact -Dir $deepDir -Name 'decision_atoms.json'       -Validator { param($o,$e) Test-DecisionAtoms $o $e }
Assert-Artifact -Dir $deepDir -Name 'conflict_matrix.json'      -Validator { param($o,$e) Test-ConflictMatrix $o $e }
Assert-Artifact -Dir $deepDir -Name 'judge_synthesis.json'      -Validator { param($o,$e) Test-JudgeSynthesis $o $e }
Assert-Artifact -Dir $deepDir -Name 'micro_debate.json'         -Validator { param($o,$e) Test-MicroDebate $o $e }
Assert-Artifact -Dir $deepDir -Name 'final_decision_record.json' -Validator { param($o,$e) Test-FinalDecisionRecord $o $e }
Assert-True 'Deep: returned record passes Test-FinalDecisionRecord' (Test-FinalDecisionRecord $deepRec ([ref]@()))
# Deep: conflict matrix must carry reviews[] (cross-review appended).
$cm = Read-SynthesisArtifact -Dir $deepDir -Name 'conflict_matrix.json'
Assert-True 'Deep: conflict_matrix has reviews[]' ($null -ne (Get-ArtifactField -Obj $cm -Name 'reviews'))
# Deep: micro_debate should NOT be skipped (we seeded a high-impact unresolved conflict).
$md = Read-SynthesisArtifact -Dir $deepDir -Name 'micro_debate.json'
Assert-True 'Deep: micro_debate ran (not skipped)' ((Get-ArtifactField -Obj $md -Name 'skipped') -eq $false)

# ---------------------------------------------------------------------------------------------------
# RUN: driver-facing wrapper
# ---------------------------------------------------------------------------------------------------

Write-Host '=== Driver wrapper ==='
$drvTurn = Invoke-SynthesisDriverTurn -Task 'обсуди и сделай caching layer' -Channel 'scratch-driver' -Depth 'Deep' -DecisionId 'driver1'
$drvDir = Get-ChannelDecisionsDir -Slug 'scratch-driver' -DecisionId 'driver1'
Assert-True 'Driver wrapper: returns ok' ([string]$drvTurn.status -eq 'ok')
Assert-True 'Driver wrapper: emits STATUS CONTINUE for implementation task' ([string]$drvTurn.text -match '(?im)^\s*STATUS:\s*CONTINUE\s*$')
Assert-Artifact -Dir $drvDir -Name 'final_decision_record.json' -Validator { param($o,$e) Test-FinalDecisionRecord $o $e }

# ---------------------------------------------------------------------------------------------------
# Cleanup + verdict
# ---------------------------------------------------------------------------------------------------

try { Remove-Item -Recurse -Force -LiteralPath $scratchRoot -ErrorAction Stop } catch {}

Write-Host ''
Write-Host ("SYNTH_TEST PASS=$($script:pass)/$($script:total)")
if ($script:pass -ne $script:total) { exit 1 }
