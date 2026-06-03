# 50-selfexec.ps1 -- Operator batch progress, self-exec selection, risk tiering, safety reflex.
# Mechanical split from lib/backlog.ps1; keep loaded through ../backlog.ps1.

function Get-OperatorBatchProgress {
  # Progress of operator-delegated batches for the pulse: per batch id, how many done/total.
  $items = @(Get-Backlog | Where-Object { @($_.tags) -contains 'operator' })
  $byBatch = @{}
  foreach ($it in $items) {
    $bid = @($it.tags | Where-Object { $_ -like 'batch:*' } | Select-Object -First 1)
    $bid = if ($bid.Count) { [string]$bid[0] } else { 'batch:?' }
    if (-not $byBatch.ContainsKey($bid)) { $byBatch[$bid] = [pscustomobject]@{ total = 0; done = 0; failed = 0; running = 0 } }
    $byBatch[$bid].total++
    switch ([string]$it.status) {
      'done'         { $byBatch[$bid].done++ }
      'auto-resolved'{ $byBatch[$bid].done++ }
      'failed'       { $byBatch[$bid].failed++ }
      'running'      { $byBatch[$bid].running++ }
    }
  }
  return $byBatch
}

function Get-NextSelfExecIdea {
  # Increment B selection (graduated self-development). Returns the next UNapproved 'new' idea whose
  # heuristic risk tier is WITHIN the operator's selfExecuteTier dial -- so a 'green' dial never
  # auto-runs a 'yellow' idea, AND the queue never wedges on an out-of-dial item sitting ahead of
  # runnable ones (we scan past it to the first in-dial idea). External/radar are excluded
  # (anti-backdoor), and project-scoped ideas are skipped unless autonomy scope is 'projects' --
  # mirroring Get-NextApprovedIdea. red-tier is never returned at any dial. Deterministic, no LLM.
  #   Dial 'green'  -> first new idea classified green
  #   Dial 'yellow' -> first new idea classified green OR yellow
  param([string]$Dial)
  $d = ([string]$Dial).ToLowerInvariant()
  if ($d -ne 'green' -and $d -ne 'yellow') { return $null }
  $cands = @(Get-Backlog | Where-Object {
      ([string]$_.status -eq 'new') -and -not (Test-IdeaExternal $_)
    } |
    Sort-Object @{Expression={ Get-IdeaSeverityRank -Idea $_ }},
                @{Expression={ $s=0.0; try{$s=[double]$_.score}catch{}; -$s }},
                @{Expression={[string]$_.ts}})
  try {
    $sc = Get-AutonomySettings
    if ([string]$sc.scope -ne 'projects') {
      $cands = @($cands | Where-Object { -not ($_.PSObject.Properties.Name -contains 'scope') -or ([string]$_.scope -ne 'project') })
    }
  } catch {}
  foreach ($it in $cands) {
    $t = ([string](Get-IdeaRiskTier -Idea $it).tier)
    $ok = ($d -eq 'green' -and $t -eq 'green') -or ($d -eq 'yellow' -and ($t -eq 'green' -or $t -eq 'yellow'))
    if ($ok) { return $it }
  }
  return $null
}

function Test-IdeaTouchesControlPlane {
  # TRUE if the task edits the bridge's own control/safety plane (supervisor, watchdog, circuit-
  # breaker, the driver core loop, restart-limit, script-integrity). Autonomously editing these is
  # what repeatedly deadlocked the bridge on 2026-05-31 (a cascade of conflicting over-protections
  # the bridge generated for itself). Used to (1) classify such ideas as red, and (2) HARD-BLOCK
  # auto-claim of them unless the OPERATOR explicitly delegated (tag 'operator'). Deterministic.
  param($Idea)
  $t = ''
  try { $t = ([string]$Idea.text).ToLowerInvariant() } catch {}
  if ([string]::IsNullOrWhiteSpace($t)) { return $false }
  $cpPat = '(watchdog|supervisor|process[_ -]?supervision|runtime[_ -]?incident|circuit[_ -]?break|restart[_ -]?limit|script[_ -]?integrit|concurrent.{0,4}driver|control[_ -]?plane|driver\.ps1|server\.ps1|supervisor\.ps1|watchdog\.ps1|circuit-breaker\.ps1|kill-bridge|self[_ -]?edit)'
  return [bool]($t -match $cpPat)
}

function Get-IdeaRiskTier {
  # Heuristic risk classifier for graduated self-execution. CONSERVATIVE by design:
  #   red    = never auto-executes — externally-sourced (anti-backdoor) OR touches the
  #            safety/security/irreversible surface (watchdog, .git, secrets, delete, sandbox...)
  #   green  = explicitly low-blast-radius & reversible (docs/comments/typos/lint/log wording)
  #   yellow = everything else (a real code change) — never auto-green; caution by default
  # Deterministic, no LLM (cheap enough to run every idle tick). Returns @{ tier; reason }.
  # Patterns are bilingual (RU+EN) because ideas are authored in both.
  param($Idea)
  $text = ''
  try { $text = ([string]$Idea.text).ToLowerInvariant() } catch {}
  if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{ tier = 'red'; reason = 'пустой текст идеи' } }
  try { if (Test-IdeaExternal $Idea) { return [pscustomobject]@{ tier = 'red'; reason = 'внешний источник (radar/web) — только ручное одобрение' } } } catch {}
  # 2026-05-30: 'token' was a bare alternative -> it red-flagged COST telemetry like
  # "failed-token-burn"/"token usage"/"tokens spent" (LLM-token metrics, NOT auth). A real
  # task (split SPEED/COST slices in deep-audit) sat unapproved 18h on that false red. Narrow
  # 'token' to auth-context via negative-lookahead that excludes the cost vocabulary; auth/API
  # tokens still match (secret|credential|api-key|auth.json also cover the security cases).
  # 2026-05-31: the bridge's own CONTROL PLANE is now red = operator-only. A cascade of
  # autonomously-generated 'process_supervision' / 'runtime-incident' tasks edited supervisor /
  # watchdog / circuit-breaker / restart-limit / script-integrity and repeatedly DEADLOCKED the
  # bridge ("we keep raising it from the dead"). Self-editing the safety/control surface autonomously
  # is the single highest-risk class -- it must go through the operator, never auto-exec.
  if (Test-IdeaTouchesControlPlane -Idea $Idea) { return [pscustomobject]@{ tier = 'red'; reason = 'правка собственного контура моста (supervisor/watchdog/circuit-breaker) — только оператор' } }
  $redPat = '(watchdog|supervisor|kill[- ]?switch|\.git|force[- ]?push|reset --hard|secret|credential|пароль|password|auth\.json|tokens?\b(?![-\s]?(?:burn|usage|count|budget|spent|cost|drain|throughput|per\b|/))|api[- ]?key|sandbox|permission|разрешени|удал|delete|drop\s+table|rm\s+-rf|encrypt|шифр|биллинг|billing|оплат|payment)'
  if ($text -match $redPat) { return [pscustomobject]@{ tier = 'red'; reason = 'затрагивает безопасность/необратимое/деньги' } }
  $greenPat = '(коммент|comment|документац|\bdocs?\b|readme|typo|опечат|орфограф|wording|форматир|\bformat\b|\blint\b|мёртв\w* код|dead code|unused|неиспольз|лог[- ]?сообщен|log message|whitespace|пробел|отступ|переименован\w* переменн|rename \w+ variable)'
  if ($text -match $greenPat) { return [pscustomobject]@{ tier = 'green'; reason = 'узкий обратимый скоуп (доки/комменты/линт/тексты)' } }
  return [pscustomobject]@{ tier = 'yellow'; reason = 'реальное изменение кода — нужна осторожность' }
}

function Set-IdeaRiskTier {
  # Persist a classified risk tier on the backlog item (UI visibility + audit trail).
  param([string]$Id, [string]$Tier, [string]$Reason = '')
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $items = @(Get-Backlog)
  $hit = $false
  foreach ($i in $items) {
    if ([string]$i.id -eq $Id) {
      $i | Add-Member -NotePropertyName risk_tier   -NotePropertyValue ([string]$Tier)   -Force
      $i | Add-Member -NotePropertyName risk_reason -NotePropertyValue ([string]$Reason) -Force
      $i | Add-Member -NotePropertyName risk_ts     -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
      $hit = $true; break
    }
  }
  if ($hit) { Save-Backlog $items }
  return $hit
}

function Set-IdeaSelfExec {
  # Mark a backlog item as auto-claimed by graduated self-development (Increment B). At claim time
  # call with -Dial; at task completion call again with -Commit to stamp the resulting SHA so the
  # safety-reflex can correlate it to the 24h verdict. Additive; never removes existing fields.
  param([string]$Id, [string]$Dial = '', [string]$Commit = '')
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $items = @(Get-Backlog); $hit = $false
  foreach ($i in $items) {
    if ([string]$i.id -ne $Id) { continue }
    $i | Add-Member -NotePropertyName self_exec -NotePropertyValue $true -Force
    if (-not [string]::IsNullOrWhiteSpace($Dial)) { $i | Add-Member -NotePropertyName self_exec_dial -NotePropertyValue ([string]$Dial) -Force }
    if (-not ($i.PSObject.Properties.Name -contains 'self_exec_ts')) {
      $i | Add-Member -NotePropertyName self_exec_ts -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    }
    if (-not [string]::IsNullOrWhiteSpace($Commit)) { $i | Add-Member -NotePropertyName self_exec_commit -NotePropertyValue ([string]$Commit) -Force }
    $hit = $true; break
  }
  if ($hit) { Save-Backlog $items }
  return $hit
}

function Test-SelfDevSafetyReflex {
  # Graduated-autonomy safety reflex: if recent self-executed commits were judged 'worse' by the
  # 24h verdict cycle, recommend dialing selfExecuteTier DOWN one notch (yellow->green->shadow) so
  # the system throttles its OWN autonomy after regressions -- the system learning caution. This is
  # the SECOND line of defence; smoke+critic gates (pre-commit) and verdict auto-revert (per-commit)
  # are the first. Read-only here -- the caller applies the change. CONSERVATIVE: fires only on
  # >=WorseThreshold settled 'worse' verdicts among self-exec commits within the lookback window.
  # Returns @{ shouldDampen; fromDial; newDial; worseCount }.
  param([string]$CurrentDial, [int]$WorseThreshold = 2, [int]$LookbackDays = 14)
  $cur = ([string]$CurrentDial).ToLowerInvariant()
  $out = [pscustomobject]@{ shouldDampen = $false; fromDial = $cur; newDial = $cur; worseCount = 0 }
  if ($cur -ne 'green' -and $cur -ne 'yellow') { return $out }   # shadow/off: nothing to dampen
  $cutoff = (Get-Date).ToUniversalTime().AddDays(-[Math]::Abs($LookbackDays))
  $selfCommits = @{}
  foreach ($i in @(Get-Backlog)) {
    if (-not ([bool]$i.self_exec)) { continue }
    $c = [string]$i.self_exec_commit
    if ([string]::IsNullOrWhiteSpace($c)) { continue }
    $ts = $null; try { $ts = ([datetime]$i.self_exec_ts).ToUniversalTime() } catch {}
    if ($ts -and $ts -lt $cutoff) { continue }
    $selfCommits[$c] = $true
    if ($c.Length -ge 7) { $selfCommits[$c.Substring(0, 7)] = $true }
  }
  if ($selfCommits.Count -eq 0) { return $out }
  $worse = 0
  try {
    foreach ($r in @(Read-MetricsJsonl)) {
      if ([string]$r.type -ne 'verdict' -or [string]$r.verdict -ne 'worse') { continue }
      $vc = [string]$r.commit
      if ([string]::IsNullOrWhiteSpace($vc)) { continue }
      if ($selfCommits.ContainsKey($vc) -or ($vc.Length -ge 7 -and $selfCommits.ContainsKey($vc.Substring(0, 7)))) { $worse++ }
    }
  } catch {}
  $out.worseCount = $worse
  if ($worse -ge $WorseThreshold) {
    $out.shouldDampen = $true
    $out.newDial = if ($cur -eq 'yellow') { 'green' } else { 'shadow' }
  }
  return $out
}

function Get-IdeaById {
  param([string]$Id)
  foreach ($i in @(Get-Backlog)) { if ([string]$i.id -eq $Id) { return $i } }
  return $null
}
