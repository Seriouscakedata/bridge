# lib/decision-depth.ps1 — Decision Synthesis depth-mode router (Chapter 1, SHADOW).
# Part of replacing the role-based DISCUSS with Multi-Model Decision Synthesis (see DECISION_SYNTHESIS_PLAN.md).
# Pure deterministic classifier (NO LLM, never gemini) + a shadow logger. SHADOW ONLY in Ch1:
# it RECORDS the chosen depth; it DOES NOT change task_mode by itself. The driver uses the
# route helper below only when synthesisMode.enabled=true.

function Get-SynthesisModeConfig {
  try {
    if (Get-Command Get-BridgeConfig -ErrorAction SilentlyContinue) {
      $cfg = Get-BridgeConfig
      if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'synthesisMode') -and $cfg.synthesisMode) {
        return $cfg.synthesisMode
      }
    }
  } catch {}
  return $null
}

function Test-SynthesisModeEnabled {
  $sm = Get-SynthesisModeConfig
  if (-not $sm) { return $false }
  try {
    return (($sm.PSObject.Properties.Name -contains 'enabled') -and [bool]$sm.enabled)
  } catch {
    return $false
  }
}

function Get-SynthesisTaskType {
  # Deterministic keyword classifier -> the task_type later used to pick the judge model.
  param([string]$Text)
  $t = ([string]$Text).ToLowerInvariant()
  if ($t -match 'багфикс|bug ?fix|\bbug\b|\bfix\b|почини|сломал|ошибк|regression|traceback|exception|segfault') { return 'bugfix' }
  if ($t -match 'рефактор|refactor|переименов|\brename\b|cleanup|extract ') { return 'refactor' }
  if ($t -match 'инфра|infra|deploy|\bci\b|supervisor|watchdog|driver\.ps1|circuit') { return 'infra' }
  if ($t -match 'исследов|research|investigat|изуч|сравни|\bcompare\b|analy[sz]e|анализ') { return 'research' }
  if ($t -match 'creative|креатив|brainstorm|придумай|naming|copy ?writing|текст для') { return 'creative' }
  if ($t -match 'архитектур|architect|\bdesign\b|redesign|пайплайн|pipeline|подсистем|structure|схему|схема|систем') { return 'architecture' }
  return 'architecture'
}

function Get-SynthesisDepthDecision {
  # Pure depth classifier: Simple | Standard | Deep | High-Stakes. Deterministic only.
  # -Text: task text. -Intent: optional Test-TaskIntent output (hashtable/obj with .complexity/.risk).
  # -Risk: optional explicit risk (low|medium|high|critical).
  param(
    [string]$Text,
    $Intent = $null,
    [string]$Risk = ''
  )
  $t = [string]$Text
  $low = $t.ToLowerInvariant()
  $taskType = Get-SynthesisTaskType -Text $t

  $getIntent = {
    param($key)
    if ($null -eq $Intent) { return '' }
    try {
      if ($Intent -is [hashtable]) { if ($Intent.ContainsKey($key)) { return [string]$Intent[$key] } return '' }
      if ($Intent.PSObject.Properties.Name -contains $key) { return [string]$Intent.$key }
    } catch {}
    return ''
  }

  # 1. Explicit High-Stakes marker always wins.
  if ($t -match '\[\[HIGH-STAKES\]\]') {
    return @{ depth = 'High-Stakes'; judge_task_type = $taskType; rationale = 'explicit [[HIGH-STAKES]] marker' }
  }

  # 2. High risk (explicit -Risk, intent.risk, or high-stakes domain) -> High-Stakes.
  # 2026-06-19 FIX: the high-stakes DOMAIN keyword match fired on any task merely MENTIONING
  # control-plane/secret/watchdog/etc., forcing the heaviest pipeline onto SMALL procedural tasks.
  # Real case: the "Bridge-self canary gate/admission for ... control-plane ..." task is mode=small
  # yet was routed depth=High-Stakes, then churned through synthesis and FAILED on the restart cap,
  # wedging the main channel. Explicit risk=high/critical still ALWAYS wins; but a keyword-only
  # "high-stakes domain" hit no longer forces High-Stakes when the task is small/short (the safety
  # gates -- claim-gate, approval classifier, critic, rollback -- are independent of synthesis depth).
  $riskVal = if ($Risk) { $Risk.ToLowerInvariant() } else { (& $getIntent 'risk').ToLowerInvariant() }
  $complexityHint = (& $getIntent 'complexity').ToLowerInvariant()
  $isSmallTask = ($complexityHint -in @('trivial','simple')) -or ($t.Trim().Length -lt 160)
  $isPlanRefinementDiscussTask = (
    ($low -match '(?<![a-z0-9а-яё])(plan[- _]?refin(?:e|ement|ing)?|refin(?:e|ement|ing)?|уточн\w*|доработ\w*)(?![a-z0-9а-яё])') -and
    ($low -match '(?<![a-z0-9а-яё])(atom(?:[_ -]?\d+)?|backlog|plan|план|spec|self[- _]?improve(?:ment)?)(?![a-z0-9а-яё])')
  )
  $highStakesKw = ($low -match 'secret|watchdog|supervisor|circuit.?breaker|control.?plane|медицин|medical|финанс|finance|деньг|payment|безопасн|security|необратим|irreversible')
  if ($riskVal -in @('high', 'critical') -or ($highStakesKw -and -not $isSmallTask -and -not $isPlanRefinementDiscussTask)) {
    $why = if ($riskVal -in @('high', 'critical')) { "risk=$riskVal" } else { 'high-stakes domain' }
    return @{ depth = 'High-Stakes'; judge_task_type = $taskType; rationale = $why }
  }

  # FAST PATH (2026-06-21): if the LLM intent classifier confidently identified a 'normal' mode
  # task (straightforward implementation), skip the Deep/discussion synthesis overhead even when
  # the task text name-drops architecture/design context. High-Stakes (marker + explicit risk +
  # domain, handled above) still wins. Route by complexity only: trivial/simple -> Simple, else Standard.
  $intentMode = (& $getIntent 'primary_mode').ToLowerInvariant()
  $intentConf = 0.0
  try { $intentConf = [double](& $getIntent 'confidence') } catch {}
  if ($intentMode -eq 'normal' -and $intentConf -ge 0.7) {
    if ($complexityHint -in @('trivial','simple')) {
      return @{ depth = 'Simple'; judge_task_type = $taskType; rationale = "fast-path: intent=normal conf=$intentConf complexity=$complexityHint" }
    }
    return @{ depth = 'Standard'; judge_task_type = $taskType; rationale = "fast-path: intent=normal conf=$intentConf complexity=$complexityHint" }
  }

  # #2 BACKSTOP (2026-06-21): an explicit implementation task the LLM intent mis-rated (not
  # normal / low-confidence). A clear code VERB (реализуй/напиши/коммить/...) with NO discussion
  # VERB (обсуди/выбери между/...) is a do-it task, not a design debate -> Standard, even when the
  # text name-drops architecture/design NOUNS. Genuine "обсуди/выбери" still falls to Deep below.
  $hasCodeVerb = ($low -match '(?<![а-яёa-z])(реализу|напиш|допиш|собери|закоммить|коммить|внедри|почини|исправь|добавь|подключи|implement|build|write|commit|wire|integrate|fix)')
  $hasDiscussVerb = ($low -match 'обсуди|обсужден|обсуждать|обсуждени|\bdiscuss\b|выбери между|какой подход|следует ли|стоит ли|за и против|trade.?off|как лучше|whether to')
  if ($hasCodeVerb -and -not $hasDiscussVerb) {
    return @{ depth = 'Standard'; judge_task_type = $taskType; rationale = 'imperative code task (verb backstop) -> Standard' }
  }

  # 3. Explicit design/architecture discussion -> Deep. Takes precedence over the short-length
  #    heuristic: "обсуди X" is a discussion request even when short, and must not become Simple.
  if (($low -match 'обсуди|обсужден|обсуждать|обсуждени|\bdiscuss\b|архитектур|architect|\bdesign\b|redesign|подход|approach|страте|strategy|как лучше|whether to|следует ли|стоит ли') -and -not $isPlanRefinementDiscussTask) {
    return @{ depth = 'Deep'; judge_task_type = $taskType; rationale = 'design/architecture discussion' }
  }

  # 4. Low complexity / very short / screenshot -> Simple (skip the heavy pipeline).
  $complexity = (& $getIntent 'complexity').ToLowerInvariant()
  if ($complexity -in @('trivial', 'simple') -or $t.Trim().Length -lt 40 -or $low -match 'screenshot|скрин|снимок экрана|one ?liner') {
    return @{ depth = 'Simple'; judge_task_type = $taskType; rationale = 'low complexity / short / screenshot' }
  }

  # 5. Default.
  return @{ depth = 'Standard'; judge_task_type = $taskType; rationale = 'default (no Simple/Deep/High-Stakes signal)' }
}

function Write-DepthShadow {
  # SHADOW logger -> channels/<slug>/depth-shadow.jsonl. Never throws; UTF-8 no BOM atomic append.
  # Mirrors Write-IntentShadow (lib/decision-contract.ps1).
  param(
    [string]$Channel = '',
    [string]$Text = '',
    $Decision = $null
  )
  try {
    $dir = $null
    try { if ($Channel) { $dir = Get-ChannelDir -Slug $Channel } else { $dir = Get-ChannelDir } } catch {}
    if (-not $dir -or -not (Test-Path $dir)) {
      if (Get-Command Write-DecisionShadowSignal -ErrorAction SilentlyContinue) {
        Write-DecisionShadowSignal -Reason 'no-channel-dir' -Detail ([string]$Channel) -Channel ([string]$Channel) -Stage 'depth-router'
      }
      return
    }
    $path = Join-Path $dir 'depth-shadow.jsonl'
    $excerpt = [string]$Text
    if ($excerpt.Length -gt 160) { $excerpt = $excerpt.Substring(0, 160) }
    $depth = ''; $jtt = ''; $rat = ''
    if ($Decision) {
      try {
        if ($Decision -is [hashtable]) { $depth = [string]$Decision['depth']; $jtt = [string]$Decision['judge_task_type']; $rat = [string]$Decision['rationale'] }
        else { $depth = [string]$Decision.depth; $jtt = [string]$Decision.judge_task_type; $rat = [string]$Decision.rationale }
      } catch {}
    }
    $rec = [ordered]@{
      ts              = (Get-Date).ToUniversalTime().ToString('o')
      channel         = [string]$Channel
      task_excerpt    = $excerpt
      depth           = $depth
      judge_task_type = $jtt
      rationale       = $rat
    }
    $line = ($rec | ConvertTo-Json -Compress -Depth 5)
    $u8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::AppendAllText($path, $line + "`n", $u8)
  } catch {
    if (Get-Command Write-DecisionShadowSignal -ErrorAction SilentlyContinue) {
      Write-DecisionShadowSignal -Reason 'write-failed' -Detail $_.Exception.Message -Channel ([string]$Channel) -Stage 'depth-router'
    }
  }
}

function Get-SynthesisRouteDecision {
  # Decide whether the live driver should replace role-based DISCUSS with Decision Synthesis.
  # FAST/NORMAL/computer-action/study guards still win; explicit discussion and Deep/High-Stakes
  # smart-router decisions enter synthesis when config.synthesisMode.enabled=true.
  param(
    [string]$Text = '',
    $Intent = $null,
    [bool]$ExplicitDiscuss = $false,
    [bool]$ExplicitDeepThink = $false,
    [bool]$LowComplexity = $false,
    [bool]$FastLane = $false,
    [bool]$NormalOverride = $false,
    [bool]$StudyMode = $false,
    [bool]$ComputerAction = $false
  )

  $depthDecision = Get-SynthesisDepthDecision -Text $Text -Intent $Intent
  $depth = ''
  $judgeTaskType = ''
  $rationale = ''
  try {
    if ($depthDecision -is [hashtable]) {
      $depth = [string]$depthDecision['depth']
      $judgeTaskType = [string]$depthDecision['judge_task_type']
      $rationale = [string]$depthDecision['rationale']
    } else {
      $depth = [string]$depthDecision.depth
      $judgeTaskType = [string]$depthDecision.judge_task_type
      $rationale = [string]$depthDecision.rationale
    }
  } catch {}

  $low = ([string]$Text).ToLowerInvariant()
  $isPlanRefinementDiscussTask = (
    ($low -match '(?<![a-z0-9а-яё])(plan[- _]?refin(?:e|ement|ing)?|refin(?:e|ement|ing)?|уточн\w*|доработ\w*)(?![a-z0-9а-яё])') -and
    ($low -match '(?<![a-z0-9а-яё])(atom(?:[_ -]?\d+)?|backlog|plan|план|spec|self[- _]?improve(?:ment)?)(?![a-z0-9а-яё])')
  )

  $enabled = Test-SynthesisModeEnabled
  $route = $false
  $reason = ''
  if (-not $enabled) { $reason = 'synthesis disabled' }
  elseif ($FastLane) { $reason = 'fast-lane guard' }
  elseif ($NormalOverride) { $reason = 'normal override' }
  elseif ($ComputerAction) { $reason = 'computer-action fast lane' }
  elseif ($StudyMode -and -not ($ExplicitDiscuss -or $ExplicitDeepThink)) { $reason = 'study mode owns this task' }
  elseif ($LowComplexity) { $reason = 'low complexity guard' }
  elseif ($ExplicitDeepThink) { $route = $true; $reason = 'deep-think marker' }
  elseif ($ExplicitDiscuss -and $isPlanRefinementDiscussTask -and $depth -eq 'Standard') { $reason = 'plan-refinement discuss stays standard' }
  elseif ($ExplicitDiscuss) { $route = $true; $reason = 'explicit discuss request' }
  elseif ($depth -in @('Deep','High-Stakes')) { $route = $true; $reason = 'smart-router depth=' + $depth }
  else { $reason = 'standard task stays on normal path' }

  return [pscustomobject][ordered]@{
    route           = [bool]$route
    enabled         = [bool]$enabled
    depth           = [string]$depth
    judge_task_type = [string]$judgeTaskType
    rationale       = [string]$rationale
    reason          = [string]$reason
  }
}
