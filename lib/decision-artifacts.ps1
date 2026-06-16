# decision-artifacts.ps1 -- Multi-Model Decision Synthesis: artifact schemas + deterministic validators.
#
# Chapter 2 of the Decision Synthesis pipeline. This file defines the ON-DISK artifact contract for the
# 7 pipeline stages and a DETERMINISTIC validator per type. Same discipline as decision-contract.ps1:
# the model PROPOSES structured artifacts; these validators CHECK shape/type/enum/required-fields only.
# NO policy here -- only validity. Every Test-* returns $true/$false; on $false it appends human-readable
# reasons to the supplied [ref]$Errors. Validators tolerate hashtable OR PSCustomObject input (from
# ConvertFrom-Json) and are permissive about EXTRA/unknown fields.

# channels.ps1 supplies Get-ChannelDir. common.ps1 dot-sources it, but allow standalone loading too.
if (-not (Get-Command Get-ChannelDir -ErrorAction SilentlyContinue)) {
  try { . (Join-Path $PSScriptRoot 'channels.ps1') } catch {}
}

# ---------------------------------------------------------------------------------------------------
# Per-decision artifact directory
# ---------------------------------------------------------------------------------------------------

function Get-ChannelDecisionsDir {
  # Path to channels/<slug>/decisions/<DecisionId>/ ; creates it (and parents) if missing.
  param([string]$Slug = $null, [Parameter(Mandatory)][string]$DecisionId)
  $chanDir = Get-ChannelDir -Slug $Slug
  $dir = Join-Path (Join-Path $chanDir 'decisions') $DecisionId
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -Force -ItemType Directory -Path $dir | Out-Null
  }
  return $dir
}

# ---------------------------------------------------------------------------------------------------
# Validation helpers (tolerate hashtable OR PSCustomObject; permissive about extra fields)
# ---------------------------------------------------------------------------------------------------

function Get-ArtifactField {
  # Read a named field from either a hashtable or a PSCustomObject. Returns $null if absent.
  # IMPORTANT: emit with -NoEnumerate so a single-element array value (e.g. @('x')) is NOT unwrapped
  # to its scalar element by PowerShell's pipeline. Without this, @('x') would arrive as the string 'x'.
  param($Obj, [string]$Name)
  if ($null -eq $Obj) { return $null }
  $val = $null
  $found = $false
  if ($Obj -is [System.Collections.IDictionary]) {
    if ($Obj.Contains($Name)) { $val = $Obj[$Name]; $found = $true }
  } else {
    $prop = $Obj.PSObject.Properties[$Name]
    if ($null -ne $prop) { $val = $prop.Value; $found = $true }
  }
  if (-not $found) { return $null }
  Write-Output -NoEnumerate $val
}

function Test-ArtifactIsObject {
  # True if value behaves like a JSON object (hashtable/dictionary or PSCustomObject), not a scalar/array.
  param($Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [string]) { return $false }
  if ($Value -is [System.Collections.IDictionary]) { return $true }
  if ($Value -is [System.Collections.IEnumerable]) { return $false }  # arrays/lists are not objects
  if ($Value -is [psobject]) { return $true }
  return $false
}

function Test-ArtifactIsArray {
  # True if value is an array/list but not a string.
  param($Value)
  if ($null -eq $Value) { return $false }
  if ($Value -is [string]) { return $false }
  return ($Value -is [System.Collections.IEnumerable])
}

function Test-ArtifactIsNumber {
  param($Value)
  return ($Value -is [double] -or $Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [single])
}

function Add-ArtifactArrayCheck {
  # Validate that field $Name on $Obj is an array; append a reason to $errs if not. Returns the array
  # (always emitted -NoEnumerate so single-element arrays survive), or $null if it is a non-array scalar.
  # NOTE (PS5.1): an empty @() stored in a hashtable literal collapses to $null, indistinguishable from a
  # genuinely absent key. JSON [] (ConvertFrom-Json) preserves a real empty array. So a $null value is
  # treated as a present EMPTY array (key satisfied, count 0) rather than "missing" -- the non-empty
  # enforcement (success_tests / source_proposals) is what actually rejects empties where required.
  param($Obj, [string]$Name, $errs, [bool]$Required = $true)
  $v = Get-ArtifactField -Obj $Obj -Name $Name
  if ($null -eq $v) {
    Write-Output -NoEnumerate @()   # empty array; callers' non-empty checks still fire
    return
  }
  if (-not (Test-ArtifactIsArray $v)) { $errs.Add("$Name must be an array"); return }
  Write-Output -NoEnumerate $v
}

function Add-ArtifactStringCheck {
  # Validate that field $Name on $Obj is a non-empty string; append a reason if not.
  param($Obj, [string]$Name, $errs, [bool]$Required = $true)
  $v = Get-ArtifactField -Obj $Obj -Name $Name
  if ($null -eq $v) { if ($Required) { $errs.Add("$Name missing") }; return $null }
  if ($v -isnot [string]) { $errs.Add("$Name must be a string"); return $null }
  if ($Required -and [string]::IsNullOrWhiteSpace($v)) { $errs.Add("$Name must be a non-empty string") }
  return $v
}

function Add-ArtifactEnumCheck {
  # Validate that field $Name is a string in $Enum; append a reason if not.
  param($Obj, [string]$Name, [string[]]$Enum, $errs)
  $v = Get-ArtifactField -Obj $Obj -Name $Name
  if ($null -eq $v) { $errs.Add("$Name missing"); return }
  if ($v -isnot [string]) { $errs.Add("$Name must be a string enum"); return }
  if ($Enum -notcontains $v) { $errs.Add("$Name '$v' not in enum [$($Enum -join '|')]") }
}

function Set-ArtifactErrors {
  # Common tail: publish accumulated errors and return the pass/fail boolean.
  param($errs, [ref]$Errors)
  if ($Errors) { $Errors.Value = @($errs.ToArray()) }
  return ($errs.Count -eq 0)
}

# ---------------------------------------------------------------------------------------------------
# 1. TaskContract
# ---------------------------------------------------------------------------------------------------

$script:ArtifactTaskTypeEnum   = @('architecture','bugfix','refactor','infra','research','creative')
$script:ArtifactRiskEnum       = @('low','medium','high','critical')
$script:ArtifactComplexityEnum = @('low','medium','high')

function Get-TaskContractSchema {
  return [ordered]@{
    task             = 'string -- the task as stated'
    goal             = 'string -- the underlying goal'
    constraints      = 'string[] -- hard constraints'
    known_context    = 'string[] -- facts the solver should assume'
    output_format    = 'string -- expected shape of the answer'
    task_type        = "enum: $($script:ArtifactTaskTypeEnum -join '|')"
    risk             = "enum: $($script:ArtifactRiskEnum -join '|')"
    allowed_complexity = "enum: $($script:ArtifactComplexityEnum -join '|')"
    success_tests    = 'string[] -- NON-EMPTY; concrete checks proving success'
  }
}

function Test-TaskContract {
  param($Obj, [ref]$Errors)
  $errs = New-Object 'System.Collections.Generic.List[string]'
  if (-not (Test-ArtifactIsObject $Obj)) {
    $errs.Add('TaskContract must be an object')
    return (Set-ArtifactErrors $errs $Errors)
  }
  [void](Add-ArtifactStringCheck $Obj 'task' $errs)
  [void](Add-ArtifactStringCheck $Obj 'goal' $errs)
  [void](Add-ArtifactStringCheck $Obj 'output_format' $errs)
  [void](Add-ArtifactArrayCheck $Obj 'constraints' $errs)
  [void](Add-ArtifactArrayCheck $Obj 'known_context' $errs)
  Add-ArtifactEnumCheck $Obj 'task_type' $script:ArtifactTaskTypeEnum $errs
  Add-ArtifactEnumCheck $Obj 'risk' $script:ArtifactRiskEnum $errs
  Add-ArtifactEnumCheck $Obj 'allowed_complexity' $script:ArtifactComplexityEnum $errs
  $st = Add-ArtifactArrayCheck $Obj 'success_tests' $errs
  if ($null -ne $st -and @($st).Count -eq 0) { $errs.Add('success_tests must be non-empty') }
  return (Set-ArtifactErrors $errs $Errors)
}

# ---------------------------------------------------------------------------------------------------
# 2. Proposal
# ---------------------------------------------------------------------------------------------------

$script:ArtifactProposerEnum  = @('A','B','C')
$script:ArtifactSeverityEnum  = @('low','medium','high')

function Get-ProposalSchema {
  return [ordered]@{
    proposer        = "enum: $($script:ArtifactProposerEnum -join '|')"
    understanding   = 'string'
    summary         = 'string'
    decision_atoms  = 'array of { statement[string], reason[string], tradeoff[string], confidence[number 0..1] }'
    assumptions     = 'string[]'
    risks           = "array of { risk[string], severity[enum: $($script:ArtifactSeverityEnum -join '|')], mitigation[string] }"
    minimal_version = 'string'
    advanced_version = 'string'
  }
}

function Test-Proposal {
  param($Obj, [ref]$Errors)
  $errs = New-Object 'System.Collections.Generic.List[string]'
  if (-not (Test-ArtifactIsObject $Obj)) {
    $errs.Add('Proposal must be an object')
    return (Set-ArtifactErrors $errs $Errors)
  }
  Add-ArtifactEnumCheck $Obj 'proposer' $script:ArtifactProposerEnum $errs
  [void](Add-ArtifactStringCheck $Obj 'understanding' $errs)
  [void](Add-ArtifactStringCheck $Obj 'summary' $errs)
  [void](Add-ArtifactStringCheck $Obj 'minimal_version' $errs)
  [void](Add-ArtifactStringCheck $Obj 'advanced_version' $errs)
  [void](Add-ArtifactArrayCheck $Obj 'assumptions' $errs)

  $atoms = Add-ArtifactArrayCheck $Obj 'decision_atoms' $errs
  if ($null -ne $atoms) {
    $i = 0
    foreach ($a in $atoms) {
      if (-not (Test-ArtifactIsObject $a)) { $errs.Add("decision_atoms[$i] must be an object"); $i++; continue }
      [void](Add-ArtifactStringCheck $a 'statement' $errs)
      [void](Add-ArtifactStringCheck $a 'reason' $errs)
      [void](Add-ArtifactStringCheck $a 'tradeoff' $errs)
      $conf = Get-ArtifactField -Obj $a -Name 'confidence'
      if ($null -eq $conf) { $errs.Add("decision_atoms[$i].confidence missing") }
      elseif (-not (Test-ArtifactIsNumber $conf)) { $errs.Add("decision_atoms[$i].confidence must be a number") }
      elseif ([double]$conf -lt 0 -or [double]$conf -gt 1) { $errs.Add("decision_atoms[$i].confidence out of range 0..1") }
      $i++
    }
  }

  $risks = Add-ArtifactArrayCheck $Obj 'risks' $errs
  if ($null -ne $risks) {
    $i = 0
    foreach ($r in $risks) {
      if (-not (Test-ArtifactIsObject $r)) { $errs.Add("risks[$i] must be an object"); $i++; continue }
      [void](Add-ArtifactStringCheck $r 'risk' $errs)
      Add-ArtifactEnumCheck $r 'severity' $script:ArtifactSeverityEnum $errs
      [void](Add-ArtifactStringCheck $r 'mitigation' $errs)
      $i++
    }
  }
  return (Set-ArtifactErrors $errs $Errors)
}

# ---------------------------------------------------------------------------------------------------
# 3. DecisionAtoms
# ---------------------------------------------------------------------------------------------------

function Get-DecisionAtomsSchema {
  return [ordered]@{
    atoms = 'array of { atom_id[string], statement[string], source_proposals[array of A|B|C, NON-EMPTY], category[string], test[string non-empty], reversibility[enum: low|medium|high], implementation_cost[enum: low|medium|high] }'
  }
}

function Test-DecisionAtoms {
  param($Obj, [ref]$Errors)
  $errs = New-Object 'System.Collections.Generic.List[string]'
  if (-not (Test-ArtifactIsObject $Obj)) {
    $errs.Add('DecisionAtoms must be an object')
    return (Set-ArtifactErrors $errs $Errors)
  }
  $atoms = Add-ArtifactArrayCheck $Obj 'atoms' $errs
  if ($null -ne $atoms) {
    $i = 0
    foreach ($a in $atoms) {
      if (-not (Test-ArtifactIsObject $a)) { $errs.Add("atoms[$i] must be an object"); $i++; continue }
      [void](Add-ArtifactStringCheck $a 'atom_id' $errs)
      [void](Add-ArtifactStringCheck $a 'statement' $errs)
      [void](Add-ArtifactStringCheck $a 'category' $errs)
      [void](Add-ArtifactStringCheck $a 'test' $errs)
      Add-ArtifactEnumCheck $a 'reversibility' $script:ArtifactComplexityEnum $errs
      Add-ArtifactEnumCheck $a 'implementation_cost' $script:ArtifactComplexityEnum $errs
      $src = Add-ArtifactArrayCheck $a 'source_proposals' $errs
      if ($null -ne $src) {
        if (@($src).Count -eq 0) { $errs.Add("atoms[$i].source_proposals empty (hallucinated atom -- must cite >=1 proposal)") }
        foreach ($s in $src) {
          if ($s -isnot [string] -or $script:ArtifactProposerEnum -notcontains $s) {
            $errs.Add("atoms[$i].source_proposals must each be one of [$($script:ArtifactProposerEnum -join '|')]"); break
          }
        }
      }
      $i++
    }
  }
  return (Set-ArtifactErrors $errs $Errors)
}

# ---------------------------------------------------------------------------------------------------
# 4. ConflictMatrix
# ---------------------------------------------------------------------------------------------------

$script:ArtifactReviewSeverityEnum = @('minor','major','blocking')

function Get-ConflictMatrixSchema {
  return [ordered]@{
    consensus_atoms = 'string[] -- atom_id values agreed by all'
    conflicts       = "array of { atom_ids[array len>=2], axis[string], impact[enum: $($script:ArtifactSeverityEnum -join '|')] }"
    reviews         = "OPTIONAL array of { atom_id[string], severity[enum: $($script:ArtifactReviewSeverityEnum -join '|')], why[string], fix[string], cost[enum: $($script:ArtifactComplexityEnum -join '|')] }"
  }
}

function Test-ConflictMatrix {
  param($Obj, [ref]$Errors)
  $errs = New-Object 'System.Collections.Generic.List[string]'
  if (-not (Test-ArtifactIsObject $Obj)) {
    $errs.Add('ConflictMatrix must be an object')
    return (Set-ArtifactErrors $errs $Errors)
  }
  $cons = Add-ArtifactArrayCheck $Obj 'consensus_atoms' $errs
  if ($null -ne $cons) {
    $i = 0
    foreach ($c in $cons) {
      if ($c -isnot [string]) { $errs.Add("consensus_atoms[$i] must be an atom_id string"); break }
      $i++
    }
  }

  $conflicts = Add-ArtifactArrayCheck $Obj 'conflicts' $errs
  if ($null -ne $conflicts) {
    $i = 0
    foreach ($cf in $conflicts) {
      if (-not (Test-ArtifactIsObject $cf)) { $errs.Add("conflicts[$i] must be an object"); $i++; continue }
      $ids = Add-ArtifactArrayCheck $cf 'atom_ids' $errs
      if ($null -ne $ids -and @($ids).Count -lt 2) { $errs.Add("conflicts[$i].atom_ids must have length >= 2") }
      [void](Add-ArtifactStringCheck $cf 'axis' $errs)
      Add-ArtifactEnumCheck $cf 'impact' $script:ArtifactSeverityEnum $errs
      $i++
    }
  }

  # reviews is OPTIONAL; only validate shape if present.
  $reviews = Get-ArtifactField -Obj $Obj -Name 'reviews'
  if ($null -ne $reviews) {
    if (-not (Test-ArtifactIsArray $reviews)) { $errs.Add('reviews must be an array when present') }
    else {
      $i = 0
      foreach ($rv in $reviews) {
        if (-not (Test-ArtifactIsObject $rv)) { $errs.Add("reviews[$i] must be an object"); $i++; continue }
        [void](Add-ArtifactStringCheck $rv 'atom_id' $errs)
        Add-ArtifactEnumCheck $rv 'severity' $script:ArtifactReviewSeverityEnum $errs
        [void](Add-ArtifactStringCheck $rv 'why' $errs)
        [void](Add-ArtifactStringCheck $rv 'fix' $errs)
        Add-ArtifactEnumCheck $rv 'cost' $script:ArtifactComplexityEnum $errs
        $i++
      }
    }
  }
  return (Set-ArtifactErrors $errs $Errors)
}

# ---------------------------------------------------------------------------------------------------
# 5. JudgeSynthesis
# ---------------------------------------------------------------------------------------------------

$script:ArtifactVerdictEnum    = @('accept','modify','reject')
$script:ArtifactScoreSubfields = @('correctness','feasibility','impact','simplicity','risk_reduction','specificity')

function Get-JudgeSynthesisSchema {
  return [ordered]@{
    atoms = "array of { atom_id[string], verdict[enum: $($script:ArtifactVerdictEnum -join '|')], scores[object with numeric $($script:ArtifactScoreSubfields -join ',')], penalties[array], total[number], reason[string] }"
  }
}

function Test-JudgeSynthesis {
  param($Obj, [ref]$Errors)
  $errs = New-Object 'System.Collections.Generic.List[string]'
  if (-not (Test-ArtifactIsObject $Obj)) {
    $errs.Add('JudgeSynthesis must be an object')
    return (Set-ArtifactErrors $errs $Errors)
  }
  $atoms = Add-ArtifactArrayCheck $Obj 'atoms' $errs
  if ($null -ne $atoms) {
    $i = 0
    foreach ($a in $atoms) {
      if (-not (Test-ArtifactIsObject $a)) { $errs.Add("atoms[$i] must be an object"); $i++; continue }
      [void](Add-ArtifactStringCheck $a 'atom_id' $errs)
      [void](Add-ArtifactStringCheck $a 'reason' $errs)
      Add-ArtifactEnumCheck $a 'verdict' $script:ArtifactVerdictEnum $errs

      $scores = Get-ArtifactField -Obj $a -Name 'scores'
      if ($null -eq $scores) { $errs.Add("atoms[$i].scores missing") }
      elseif (-not (Test-ArtifactIsObject $scores)) { $errs.Add("atoms[$i].scores must be an object") }
      else {
        foreach ($sf in $script:ArtifactScoreSubfields) {
          $sv = Get-ArtifactField -Obj $scores -Name $sf
          if ($null -eq $sv) { $errs.Add("atoms[$i].scores.$sf missing") }
          elseif (-not (Test-ArtifactIsNumber $sv)) { $errs.Add("atoms[$i].scores.$sf must be numeric") }
        }
      }

      [void](Add-ArtifactArrayCheck $a 'penalties' $errs)
      $total = Get-ArtifactField -Obj $a -Name 'total'
      if ($null -eq $total) { $errs.Add("atoms[$i].total missing") }
      elseif (-not (Test-ArtifactIsNumber $total)) { $errs.Add("atoms[$i].total must be a number") }
      $i++
    }
  }
  return (Set-ArtifactErrors $errs $Errors)
}

# ---------------------------------------------------------------------------------------------------
# 6. MicroDebate
# ---------------------------------------------------------------------------------------------------

function Get-MicroDebateSchema {
  return [ordered]@{
    skipped = 'bool -- if true, topics may be empty'
    topics  = 'array of { atom_ids[array], rounds[array] }'
  }
}

function Test-MicroDebate {
  param($Obj, [ref]$Errors)
  $errs = New-Object 'System.Collections.Generic.List[string]'
  if (-not (Test-ArtifactIsObject $Obj)) {
    $errs.Add('MicroDebate must be an object')
    return (Set-ArtifactErrors $errs $Errors)
  }
  $skipped = Get-ArtifactField -Obj $Obj -Name 'skipped'
  if ($null -eq $skipped) { $errs.Add('skipped missing') }
  elseif ($skipped -isnot [bool]) { $errs.Add('skipped must be a JSON boolean true/false') }

  $topics = Add-ArtifactArrayCheck $Obj 'topics' $errs
  if ($null -ne $topics) {
    $i = 0
    foreach ($t in $topics) {
      if (-not (Test-ArtifactIsObject $t)) { $errs.Add("topics[$i] must be an object"); $i++; continue }
      [void](Add-ArtifactArrayCheck $t 'atom_ids' $errs)
      [void](Add-ArtifactArrayCheck $t 'rounds' $errs)
      $i++
    }
  }
  return (Set-ArtifactErrors $errs $Errors)
}

# ---------------------------------------------------------------------------------------------------
# 7. FinalDecisionRecord
# ---------------------------------------------------------------------------------------------------

function Get-FinalDecisionRecordSchema {
  return [ordered]@{
    final_answer        = 'string'
    decisions           = 'array of { decision[string], rationale[string], alternatives_considered[array], risk[string], test[string] }'
    rejected            = 'array of { decision[string], why[string] }'
    open_questions      = 'string[]'
    implementation_plan = 'array'
    next_step           = 'string'
  }
}

function Test-FinalDecisionRecord {
  param($Obj, [ref]$Errors)
  $errs = New-Object 'System.Collections.Generic.List[string]'
  if (-not (Test-ArtifactIsObject $Obj)) {
    $errs.Add('FinalDecisionRecord must be an object')
    return (Set-ArtifactErrors $errs $Errors)
  }
  [void](Add-ArtifactStringCheck $Obj 'final_answer' $errs)
  [void](Add-ArtifactStringCheck $Obj 'next_step' $errs)
  [void](Add-ArtifactArrayCheck $Obj 'open_questions' $errs)
  [void](Add-ArtifactArrayCheck $Obj 'implementation_plan' $errs)

  $decisions = Add-ArtifactArrayCheck $Obj 'decisions' $errs
  if ($null -ne $decisions) {
    $i = 0
    foreach ($d in $decisions) {
      if (-not (Test-ArtifactIsObject $d)) { $errs.Add("decisions[$i] must be an object"); $i++; continue }
      [void](Add-ArtifactStringCheck $d 'decision' $errs)
      [void](Add-ArtifactStringCheck $d 'rationale' $errs)
      [void](Add-ArtifactStringCheck $d 'risk' $errs)
      [void](Add-ArtifactStringCheck $d 'test' $errs)
      [void](Add-ArtifactArrayCheck $d 'alternatives_considered' $errs)
      $i++
    }
  }

  $rejected = Add-ArtifactArrayCheck $Obj 'rejected' $errs
  if ($null -ne $rejected) {
    $i = 0
    foreach ($r in $rejected) {
      if (-not (Test-ArtifactIsObject $r)) { $errs.Add("rejected[$i] must be an object"); $i++; continue }
      [void](Add-ArtifactStringCheck $r 'decision' $errs)
      [void](Add-ArtifactStringCheck $r 'why' $errs)
      $i++
    }
  }
  return (Set-ArtifactErrors $errs $Errors)
}
