# lib/decision-depth.ps1 — Decision Synthesis depth-mode router (Chapter 1, SHADOW).
# Part of replacing the role-based DISCUSS with Multi-Model Decision Synthesis (see DECISION_SYNTHESIS_PLAN.md).
# Pure deterministic classifier (NO LLM, never gemini) + a shadow logger. SHADOW ONLY in Ch1:
# it RECORDS the chosen depth; it does NOT change task_mode or any live behavior.

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
  $riskVal = if ($Risk) { $Risk.ToLowerInvariant() } else { (& $getIntent 'risk').ToLowerInvariant() }
  $highStakesKw = ($low -match 'secret|watchdog|supervisor|circuit.?breaker|control.?plane|медицин|medical|финанс|finance|деньг|payment|безопасн|security|необратим|irreversible')
  if ($riskVal -in @('high', 'critical') -or $highStakesKw) {
    $why = if ($riskVal -in @('high', 'critical')) { "risk=$riskVal" } else { 'high-stakes domain' }
    return @{ depth = 'High-Stakes'; judge_task_type = $taskType; rationale = $why }
  }

  # 3. Explicit design/architecture discussion -> Deep. Takes precedence over the short-length
  #    heuristic: "обсуди X" is a discussion request even when short, and must not become Simple.
  if ($low -match 'обсуди|обсужден|обсуждать|обсуждени|\bdiscuss\b|архитектур|architect|\bdesign\b|redesign|подход|approach|страте|strategy|как лучше|whether to|следует ли|стоит ли') {
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
