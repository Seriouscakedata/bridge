# test-decision-artifacts.ps1 -- unit test for lib/decision-artifacts.ps1
# For each of the 7 artifact types: one VALID sample (must PASS, no errors) and one INVALID sample
# (must be REJECTED with a reason). Plus Get-ChannelDecisionsDir must create the directory.
# Prints: ARTIFACTS_TEST PASS=N/14  (plus a directory check line).

$ErrorActionPreference = 'Stop'

$libDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'lib'
. (Join-Path $libDir 'common.ps1')
. (Join-Path $libDir 'decision-artifacts.ps1')

$pass = 0
$total = 0
$fails = @()

function Assert-Valid {
  param([string]$Name, [scriptblock]$Validator, $Obj)
  $script:total++
  $errs = [ref]$null
  $ok = & $Validator $Obj $errs
  if ($ok -and (@($errs.Value).Count -eq 0)) {
    $script:pass++
    Write-Host ("  [PASS] {0}: valid sample accepted" -f $Name)
  } else {
    $script:fails += "$Name valid-sample REJECTED: $(@($errs.Value) -join '; ')"
    Write-Host ("  [FAIL] {0}: valid sample REJECTED -> {1}" -f $Name, (@($errs.Value) -join '; '))
  }
}

function Assert-Invalid {
  param([string]$Name, [scriptblock]$Validator, $Obj, [string]$Expect)
  $script:total++
  $errs = [ref]$null
  $ok = & $Validator $Obj $errs
  if (-not $ok -and (@($errs.Value).Count -ge 1)) {
    $script:pass++
    Write-Host ("  [PASS] {0}: invalid sample rejected ({1}) -> {2}" -f $Name, $Expect, (@($errs.Value)[0]))
  } else {
    $script:fails += "$Name invalid-sample ACCEPTED (expected reject: $Expect)"
    Write-Host ("  [FAIL] {0}: invalid sample ACCEPTED (expected reject: {1})" -f $Name, $Expect)
  }
}

# ---- 1. TaskContract ----
$tcValid = @{
  task = 'Add retry to fetch'; goal = 'survive transient errors'
  constraints = @('no new deps'); known_context = @('runs on PS5.1')
  output_format = 'patch'; task_type = 'bugfix'; risk = 'medium'
  allowed_complexity = 'low'; success_tests = @('flaky test passes 10x')
}
$tcInvalid = @{
  task = 'x'; goal = 'y'; constraints = @(); known_context = @()
  output_format = 'patch'; task_type = 'bugfix'; risk = 'medium'
  allowed_complexity = 'low'; success_tests = @()  # empty -> must fail
}
Assert-Valid   'TaskContract' { param($o,$e) Test-TaskContract -Obj $o -Errors $e } $tcValid
Assert-Invalid 'TaskContract' { param($o,$e) Test-TaskContract -Obj $o -Errors $e } $tcInvalid 'empty success_tests'

# ---- 2. Proposal ----
$pValid = @{
  proposer = 'A'; understanding = 'we need X'; summary = 'do Y'
  decision_atoms = @( @{ statement = 'use queue'; reason = 'decouples'; tradeoff = 'more infra'; confidence = 0.8 } )
  assumptions = @('queue exists'); risks = @( @{ risk = 'queue down'; severity = 'medium'; mitigation = 'fallback' } )
  minimal_version = 'in-proc'; advanced_version = 'durable queue'
}
$pInvalid = @{
  proposer = 'Z'  # bad enum
  understanding = 'we need X'; summary = 'do Y'
  decision_atoms = @( @{ statement = 'use queue'; reason = 'decouples'; tradeoff = 'more infra'; confidence = 1.5 } )  # conf out of range
  assumptions = @(); risks = @(); minimal_version = 'a'; advanced_version = 'b'
}
Assert-Valid   'Proposal' { param($o,$e) Test-Proposal -Obj $o -Errors $e } $pValid
Assert-Invalid 'Proposal' { param($o,$e) Test-Proposal -Obj $o -Errors $e } $pInvalid 'bad proposer enum + confidence>1'

# ---- 3. DecisionAtoms ----
$daValid = @{
  atoms = @(
    @{ atom_id = 'AT1'; statement = 'use queue'; source_proposals = @('A','B'); category = 'infra'; test = 'msg delivered'; reversibility = 'medium'; implementation_cost = 'low' }
  )
}
$daInvalid = @{
  atoms = @(
    @{ atom_id = 'AT1'; statement = 'use queue'; source_proposals = @(); category = 'infra'; test = 'x'; reversibility = 'medium'; implementation_cost = 'low' }  # empty source -> hallucinated
  )
}
Assert-Valid   'DecisionAtoms' { param($o,$e) Test-DecisionAtoms -Obj $o -Errors $e } $daValid
Assert-Invalid 'DecisionAtoms' { param($o,$e) Test-DecisionAtoms -Obj $o -Errors $e } $daInvalid 'empty source_proposals (hallucinated)'

# ---- 4. ConflictMatrix ----
$cmValid = @{
  consensus_atoms = @('AT1','AT2')
  conflicts = @( @{ atom_ids = @('AT3','AT4'); axis = 'cost'; impact = 'high' } )
  reviews = @( @{ atom_id = 'AT3'; severity = 'major'; why = 'too costly'; fix = 'cheaper path'; cost = 'low' } )
}
$cmInvalid = @{
  consensus_atoms = @('AT1')
  conflicts = @( @{ atom_ids = @('AT3'); axis = 'cost'; impact = 'high' } )  # atom_ids len < 2
}
Assert-Valid   'ConflictMatrix' { param($o,$e) Test-ConflictMatrix -Obj $o -Errors $e } $cmValid
Assert-Invalid 'ConflictMatrix' { param($o,$e) Test-ConflictMatrix -Obj $o -Errors $e } $cmInvalid 'conflict atom_ids len < 2'

# ---- 5. JudgeSynthesis ----
$jsValid = @{
  atoms = @(
    @{ atom_id = 'AT1'; verdict = 'accept'
       scores = @{ correctness = 5; feasibility = 4; impact = 5; simplicity = 3; risk_reduction = 4; specificity = 5 }
       penalties = @(); total = 26; reason = 'strong' }
  )
}
$jsInvalid = @{
  atoms = @(
    @{ atom_id = 'AT1'; verdict = 'accept'; penalties = @(); total = 26; reason = 'strong' }  # scores missing
  )
}
Assert-Valid   'JudgeSynthesis' { param($o,$e) Test-JudgeSynthesis -Obj $o -Errors $e } $jsValid
Assert-Invalid 'JudgeSynthesis' { param($o,$e) Test-JudgeSynthesis -Obj $o -Errors $e } $jsInvalid 'missing scores'

# ---- 6. MicroDebate ----
$mdValid = @{ skipped = $false; topics = @( @{ atom_ids = @('AT1','AT2'); rounds = @('r1','r2') } ) }
$mdValidSkipped = @{ skipped = $true; topics = @() }
$mdInvalid = @{ skipped = 'nope'; topics = @() }  # skipped not a bool
Assert-Valid   'MicroDebate' { param($o,$e) Test-MicroDebate -Obj $o -Errors $e } $mdValid
Assert-Invalid 'MicroDebate' { param($o,$e) Test-MicroDebate -Obj $o -Errors $e } $mdInvalid 'skipped not bool'
# bonus sanity: skipped=true with empty topics is valid (not counted in the 14)
$tmpErrs = [ref]$null
if (-not (Test-MicroDebate -Obj $mdValidSkipped -Errors $tmpErrs)) {
  Write-Host ("  [WARN] MicroDebate skipped=true/empty topics unexpectedly rejected -> {0}" -f (@($tmpErrs.Value) -join '; '))
}

# ---- 7. FinalDecisionRecord ----
$fdValid = @{
  final_answer = 'ship durable queue'
  decisions = @( @{ decision = 'use queue'; rationale = 'decouples'; alternatives_considered = @('in-proc'); risk = 'infra'; test = 'msg delivered' } )
  rejected = @( @{ decision = 'no queue'; why = 'tight coupling' } )
  open_questions = @('which broker?'); implementation_plan = @('step1','step2'); next_step = 'spike broker'
}
$fdInvalid = @{
  final_answer = 'ship'
  decisions = @( @{ decision = 'use queue'; rationale = 'decouples'; alternatives_considered = @('in-proc'); risk = 'infra' } )  # test missing
  rejected = @(); open_questions = @(); implementation_plan = @(); next_step = 'go'
}
Assert-Valid   'FinalDecisionRecord' { param($o,$e) Test-FinalDecisionRecord -Obj $o -Errors $e } $fdValid
Assert-Invalid 'FinalDecisionRecord' { param($o,$e) Test-FinalDecisionRecord -Obj $o -Errors $e } $fdInvalid 'decision.test missing'

# ---- PSCustomObject (ConvertFrom-Json) tolerance sanity ----
$jsonObj = '{"task":"t","goal":"g","constraints":[],"known_context":[],"output_format":"p","task_type":"infra","risk":"low","allowed_complexity":"low","success_tests":["ok"]}' | ConvertFrom-Json
$jErrs = [ref]$null
if (-not (Test-TaskContract -Obj $jsonObj -Errors $jErrs)) {
  Write-Host ("  [WARN] TaskContract rejected a valid PSCustomObject -> {0}" -f (@($jErrs.Value) -join '; '))
} else {
  Write-Host '  [INFO] PSCustomObject (ConvertFrom-Json) input accepted'
}

# ---- Get-ChannelDecisionsDir creates the dir ----
$dirOk = $false
try {
  $did = 'test-decision-' + ([guid]::NewGuid().ToString('N').Substring(0,8))
  $dir = Get-ChannelDecisionsDir -Slug 'main' -DecisionId $did
  if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) {
    $dirOk = $true
    Write-Host ("  [INFO] Get-ChannelDecisionsDir created: {0}" -f $dir)
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
} catch {
  Write-Host ("  [FAIL] Get-ChannelDecisionsDir threw -> {0}" -f $_.Exception.Message)
}
if ($dirOk) { Write-Host '  DIR_CHECK PASS' } else { Write-Host '  DIR_CHECK FAIL'; $fails += 'Get-ChannelDecisionsDir did not create dir' }

# ---- Summary ----
Write-Host ''
if ($fails.Count -gt 0) {
  Write-Host 'FAILURES:'
  foreach ($f in $fails) { Write-Host ("  - {0}" -f $f) }
}
$dirSuffix = if ($dirOk) { 'DIR=ok' } else { 'DIR=FAIL' }
Write-Host ("ARTIFACTS_TEST PASS={0}/{1} {2}" -f $pass, $total, $dirSuffix)
if ($pass -eq $total -and $dirOk) { exit 0 } else { exit 1 }
