# policy.ps1 -- SINGLE SOURCE OF TRUTH for the bridge protection policy (2026-06-09).
#
# WHY THIS EXISTS (operator decision, root-cause fix):
# "Is this control-plane / dangerous?" used to be answered by 6-7 DIFFERENT detectors that each
# kept their own regex and drifted apart:
#   backlog-core.ps1:870  Test-BridgeControlPlanePath        (paths, no canary/control)
#   backlog-core.ps1:1807 Test-IdeaTouchesControlPlane       (broad TEXT regex - the epidemic root)
#   backlog-core.ps1:1847 Get-IdeaRiskTier $redPat           (another text regex)
#   backlog-autopilot.ps1 Test-ProjectAutopilotControlPlanePath (copy-paste of :870)
#   backlog-workpack.ps1  Test-BacklogWorkpackTouchesBridgeControlPlane (own list + text probe)
#   driver/20-context.ps1 Test-AutonomousTaskSafe $coreRe    (fifth list)
# Two of them matched FREE TEXT, so a task that merely MENTIONED driver.ps1/supervisor/secret
# (a unit test, a docs task, a DISCUSS about the gates themselves) was classified control-plane
# and blocked. Operator-approved work kept wedging; the operator kept un-sticking it by hand.
#
# THE POLICY MODEL (three questions, one place):
#   1. PATHS:        Test-PolicyControlPlanePath        - ONE declarative protected-path set.
#   2. WHAT IT EDITS: Test-PolicyItemTouchesControlPlane - keyed on declared EDIT TARGETS
#      (files -> workpack edit touches -> touch sets). Text is consulted ONLY when the item
#      declares no paths at all, and then requires an EDIT VERB near a component name --
#      mentioning a component is not editing it. [[DISCUSS]] analysis tasks are never edits.
#   3. WHO AUTHORIZED IT: Get-PolicyItemAuthorization    - operator | admitted | autonomous.
#      Gates must treat 'operator' as a human decision: advise (log), don't veto.
# Test-PolicyAutotaskExecutionBlocked combines 2+3 with the action-class danger scan
# (Test-AutonomousTaskSafe) into the ONE pre-flight verdict all claim sites use.
#
# This file is itself control-plane (see path list below): editing it requires operator authority.
# Keep it dependency-free: it loads FIRST in lib/backlog.ps1 and must not require other lib files.

function Get-PolicyStringArray {
  # Local coercion helper so this module stays dependency-free (the shared-primitives layer
  # will own a canonical ConvertTo-StringArray later; this is intentionally tiny).
  param($Value)
  $out = New-Object 'System.Collections.Generic.List[string]'
  if ($null -ne $Value) {
    foreach ($v in @($Value)) {
      $s = [string]$v
      if (-not [string]::IsNullOrWhiteSpace($s)) { [void]$out.Add($s.Trim()) }
    }
  }
  return @($out.ToArray())
}

function Test-PolicyConcreteEditTarget {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $p = ([string]$Path).Trim()
  if ($p -match '^(?i:general|misc|unknown|other|none)$') { return $false }
  return $true
}

function Test-PolicyControlPlanePath {
  # ONE definition of the protected (control-plane) path set. Union of every prior list:
  # driver entry + driver modules, server, supervisor, watchdog, canary, the backlog libs,
  # parallel dispatch, circuit-breaker, the control/ flags dir -- and this policy file itself.
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $p = ($Path -replace '\\','/').Trim().TrimStart('./').ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($p)) { return $false }
  if ($p -match '(^|/)driver[^/]*\.ps1$') { return $true }
  if ($p -match '(^|/)driver/[^/]+\.ps1$') { return $true }
  if ($p -match '(^|/)(server|supervisor|watchdog|canary)\.ps1$') { return $true }
  if ($p -match '(^|/)lib/backlog[^/]*\.ps1$') { return $true }
  if ($p -match '(^|/)lib/(parallel|circuit-breaker|policy)\.ps1$') { return $true }
  if ($p -match '^control(/|$)') { return $true }
  return $false
}

function Get-PolicyItemDeclaredEditTargets {
  # The paths a task will WRITE. Tiered: the first non-empty tier wins, because lower tiers
  # mix verify-dependencies into the set (e.g. touch_set carries "driver.ps1" for the
  # acceptance check `driver.ps1 -SelfTest` on a task whose only edit is a test file --
  # that exact case false-flagged operator work as control-plane).
  #   tier 1: files                      (explicit edit targets; autopilot atoms always set this)
  #   tier 2: workpack edit touches      (edit-only view, when the workpack module is loaded)
  #   tier 3: workpack_touch_set / touch_set (legacy mixed view -- better than text, worse than 1/2)
  param($Item)
  if (-not $Item) { return @() }
  $files = @()
  try { $files = @(Get-PolicyStringArray ($Item.files) | Where-Object { Test-PolicyConcreteEditTarget -Path ([string]$_) }) } catch { $files = @() }
  if ($files.Count -gt 0) { return $files }
  try {
    if (Get-Command Get-BacklogWorkpackItemEditTouches -ErrorAction SilentlyContinue) {
      $edits = @(Get-PolicyStringArray (Get-BacklogWorkpackItemEditTouches -Item $Item) | Where-Object { Test-PolicyConcreteEditTarget -Path ([string]$_) })
      if ($edits.Count -gt 0) { return $edits }
    }
  } catch {}
  $touches = New-Object 'System.Collections.Generic.List[string]'
  foreach ($name in @('workpack_touch_set','touch_set')) {
    try {
      $val = $null
      if ($Item.PSObject -and ($Item.PSObject.Properties.Name -contains $name)) { $val = $Item.$name }
      foreach ($t in @(Get-PolicyStringArray $val)) {
        if ((Test-PolicyConcreteEditTarget -Path $t) -and -not $touches.Contains($t)) { [void]$touches.Add($t) }
      }
    } catch {}
  }
  return @($touches.ToArray())
}

function Test-PolicyTextSignalsControlPlaneEdit {
  # Fallback for items that declare NO paths (free-text generator ideas). Control-plane only
  # when the text indicates MODIFYING a protected component: an edit-verb AND a component name.
  # A bare mention (tests, docs, reports, discussions ABOUT a component) is NOT an edit.
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  if ($Text -match '\[\[DISCUSS\]\]') { return $false }   # analysis-only: produces a plan, edits nothing
  $t = $Text.ToLowerInvariant()
  $editVerb = '(добав|внедр|встро|измен|правк|редактир|перепис|перепиш|удал|отключ|обойт|обход|сним|снят|замен|вынес|перенес|почин|укреп|захарден|bypass|disable|remove|delete|rewrite|edit|modif|patch|refactor|implement|wire|integrat|harden|fix|add)'
  $component = '(driver[^/\s\\]*\.ps1|driver[\\/][^\s,;:]+\.ps1|\bserver\.ps1|supervisor|watchdog|circuit.?break|kill.?bridge|kill.?switch|restart.?limit|script.?integrit|control.?plane|process[_ -]?supervision|lib[\\/]backlog[^/\s\\]*\.ps1|lib[\\/](parallel|circuit-breaker|policy)\.ps1|\bcanary\.ps1)'
  return [bool](($t -match $editVerb) -and ($t -match $component))
}

function Test-PolicyItemTouchesControlPlane {
  # THE control-plane question, answered once: does this item EDIT the protected surface?
  param($Item)
  if (-not $Item) { return $false }
  $targets = @()
  try { $targets = @(Get-PolicyItemDeclaredEditTargets -Item $Item) } catch { $targets = @() }
  if ($targets.Count -gt 0) {
    foreach ($t in $targets) { if (Test-PolicyControlPlanePath -Path $t) { return $true } }
    return $false   # explicit edit targets, none protected => NOT control-plane (whatever the text says)
  }
  $txt = ''
  try { $txt = ([string]$Item.title + ' ' + [string]$Item.text) } catch {}
  return [bool](Test-PolicyTextSignalsControlPlaneEdit -Text $txt)
}

function Get-PolicyObjectValue {
  param($Object, [string]$Name, $Default = $null)
  if (-not $Object -or [string]::IsNullOrWhiteSpace($Name)) { return $Default }
  try {
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
  } catch {}
  try {
    if ($Object.PSObject -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
  } catch {}
  return $Default
}

function Get-PolicyIdeaApprovalRisk {
  # Deterministic fail-closed classifier for backlog idea APPROVAL.
  # It is intentionally separate from Test-PolicyAutotaskExecutionBlocked:
  # approval happens before a concrete implementation exists, so high-risk
  # ideas are routed to the operator instead of being auto-approved.
  param($Item)
  try {
    if (-not $Item) {
      return [pscustomobject]@{
        operator_required = $true
        auto_approve_allowed = $false
        risk = 'unknown'
        category = 'missing_item'
        reason = 'idea approval risk classifier received no item'
        evidence = @()
      }
    }

    $text = ([string](Get-PolicyObjectValue -Object $Item -Name 'title' -Default '') + ' ' + [string](Get-PolicyObjectValue -Object $Item -Name 'text' -Default '')).Trim()
    $lower = $text.ToLowerInvariant()
    $evidence = New-Object 'System.Collections.Generic.List[string]'

    if (Test-PolicyItemTouchesControlPlane -Item $Item) {
      [void]$evidence.Add('control-plane edit signal')
      return [pscustomobject]@{
        operator_required = $true
        auto_approve_allowed = $false
        risk = 'high'
        category = 'control-plane'
        reason = 'idea appears to edit the bridge control plane; operator approval required'
        evidence = @($evidence.ToArray())
      }
    }

    $metaSafety = '(?i)(approval|curator|auto[-_ ]?approve|auto[-_ ]?approval|intake gate|backlog curator|policy\.ps1|goals\.md|threshold|deny[-_ ]?list|risk classifier|selfexecute|self[-_ ]?execute|operator[-_ ]?required)'
    $metaVerb = '(?i)(relax|loosen|raise|lower|change|modify|edit|bypass|disable|remove|delete|rewrite|refactor|implement|wire|integrat|tune|настро|измен|ослаб|отключ|обойт|обход|удал|перепис|внедр|добав)'
    if (($lower -match $metaSafety) -and ($lower -match $metaVerb)) {
      [void]$evidence.Add('approval/safety machinery change signal')
      return [pscustomobject]@{
        operator_required = $true
        auto_approve_allowed = $false
        risk = 'high'
        category = 'approval-safety-meta'
        reason = 'idea changes approval, policy, goals, thresholds, or safety machinery; operator approval required'
        evidence = @($evidence.ToArray())
      }
    }

    $security = '(?i)(secret|credential|api[-_ ]?key|auth\.json|password|пароль|token\b(?![-\s]?(?:burn|usage|count|budget|spent|cost|drain|throughput|per\b|/))|permission|sandbox|security|auth bypass|encrypt|decrypt|шифр|разрешени|безопасност)'
    if ($lower -match $security) {
      [void]$evidence.Add('security-sensitive keyword')
      return [pscustomobject]@{
        operator_required = $true
        auto_approve_allowed = $false
        risk = 'high'
        category = 'security'
        reason = 'idea is security-sensitive; operator approval required'
        evidence = @($evidence.ToArray())
      }
    }

    $irreversible = '(?i)(force[-_ ]?push|reset --hard|rm\s+-rf|drop\s+table|permanent|irreversible|delete\s+.+(history|data|repo|backlog)|удалить\s+.+(истори|данн|репозитор|бэклог)|необрат)'
    if ($lower -match $irreversible) {
      [void]$evidence.Add('irreversible/destructive operation signal')
      return [pscustomobject]@{
        operator_required = $true
        auto_approve_allowed = $false
        risk = 'high'
        category = 'irreversible'
        reason = 'idea proposes destructive or irreversible work; operator approval required'
        evidence = @($evidence.ToArray())
      }
    }

    # 2026-06-19 (operator-confirmed boundary): irreversible EXTERNAL actions — a message to a real
    # human or spending money — cannot be undone by Doctor/rollback (the action already happened), so
    # they always go to the operator. Deliberately narrow patterns to avoid flagging system logs/notes.
    $externalAction = '(?i)(telegram[-_ ]?send|send\s+.{0,25}(message|msg|email|sms|dm)\b.{0,20}(to\s+)?(a\s+)?(human|person|user|contact|client|оператор|человек)|отправ\w*\s+.{0,30}(человек|пользовател|оператор|клиент|в\s+телеграм|сообщени\w*\s+(в\s+)?(телеграм|человек|люд))|\bpayment\b|\bpurchase\b|\bcheckout\b|потрат\w*\s+.{0,15}(деньг|средств|рубл|доллар)|оплат\w+|перевод\w*\s+.{0,15}(деньг|средств|funds)|spend\s+(money|деньг)|charge\s+(the\s+)?card|купи\w+|оплати\w+)'
    if ($lower -match $externalAction) {
      [void]$evidence.Add('irreversible external action (message-to-human / payment) signal')
      return [pscustomobject]@{
        operator_required = $true
        auto_approve_allowed = $false
        risk = 'high'
        category = 'irreversible-external'
        reason = 'idea proposes an irreversible external action (message to a human / spending money); operator approval required'
        evidence = @($evidence.ToArray())
      }
    }

    $archPivot = '(?i)(rewrite architecture|replace architecture|architectural pivot|new gate|parallel mechanism|new daemon|new service|новый гейт|параллельн\w+ механизм|архитектурн\w+ разворот|перепис\w+ архитектур|замен\w+ архитектур)'
    if ($lower -match $archPivot) {
      [void]$evidence.Add('architecture-pivot/gate-clutter signal')
      return [pscustomobject]@{
        operator_required = $true
        auto_approve_allowed = $false
        risk = 'high'
        category = 'architecture-pivot'
        reason = 'idea proposes an architectural pivot or a new competing gate; operator approval required'
        evidence = @($evidence.ToArray())
      }
    }

    return [pscustomobject]@{
      operator_required = $false
      auto_approve_allowed = $true
      risk = 'low'
      category = 'ordinary'
      reason = 'no deterministic high-risk approval signals'
      evidence = @()
    }
  } catch {
    return [pscustomobject]@{
      operator_required = $true
      auto_approve_allowed = $false
      risk = 'unknown'
      category = 'classifier-error'
      reason = 'idea approval risk classifier failed closed: ' + [string]$_.Exception.Message
      evidence = @()
    }
  }
}

function Get-PolicyItemAuthorization {
  # ONE trust model for every gate:
  #   operator   - human-authorized (from=operator or tag 'operator'); gates advise, never veto
  #   admitted   - carries a valid bridge_self_admission (canary path, checked elsewhere)
  #   autonomous - everything else; full gating applies
  param($Item)
  if (-not $Item) { return 'autonomous' }
  try {
    $from = ''
    try { $from = ([string]$Item.from).Trim().ToLowerInvariant() } catch {}
    if ($from -eq 'operator') { return 'operator' }
    foreach ($tag in @(Get-PolicyStringArray ($Item.tags))) {
      if ($tag.ToLowerInvariant() -eq 'operator') { return 'operator' }
    }
  } catch {}
  try {
    if (Get-Command Test-IdeaBridgeSelfAdmitted -ErrorAction SilentlyContinue) {
      $adm = Test-IdeaBridgeSelfAdmitted -Idea $Item
      if ($adm -and [bool]$adm.ok) { return 'admitted' }
    }
  } catch {}
  return 'autonomous'
}

function Test-PolicyAutotaskExecutionBlocked {
  # The ONE pre-flight verdict for all autonomous-claim sites. Combines the action-class danger
  # scan (Test-AutonomousTaskSafe: irreversible ops, disabling protection, destructive ops on
  # core/used files) with the authorization model:
  #   - task text safe                  -> not blocked
  #   - unsafe but [[DISCUSS]]          -> not blocked (analysis executes nothing), exempt='discuss'
  #   - unsafe but operator-authorized  -> not blocked (human decision; the gate exists to catch
  #                                        AUTONOMOUS mistakes, not to veto the operator), exempt='operator'
  #   - unsafe otherwise                -> blocked (the caller holds the item for operator review)
  # NOTE: the energy-saving sabotage was from=project-autopilot (autonomous) -- it would still block.
  param($Item, [string]$TaskText = '', [string]$BridgeRoot = '')
  $text = $TaskText
  if ([string]::IsNullOrWhiteSpace($text)) { try { $text = [string]$Item.text } catch { $text = '' } }
  $auth = 'autonomous'
  try { $auth = [string](Get-PolicyItemAuthorization -Item $Item) } catch {}
  $danger = $null
  try {
    if (Get-Command Test-AutonomousTaskSafe -ErrorAction SilentlyContinue) {
      $danger = Test-AutonomousTaskSafe -TaskText $text -BridgeRoot $BridgeRoot
    }
  } catch { $danger = $null }
  if (-not $danger) { $danger = [pscustomobject]@{ safe = $true; risk = 'unknown'; reason = 'danger scan unavailable (fail-open)' } }
  if ([bool]$danger.safe) {
    return [pscustomobject]@{ blocked=$false; risk=[string]$danger.risk; reason=[string]$danger.reason; authorization=$auth; exempt='' }
  }
  if ($text -match '\[\[DISCUSS\]\]') {
    return [pscustomobject]@{ blocked=$false; risk=[string]$danger.risk; reason=[string]$danger.reason; authorization=$auth; exempt='discuss' }
  }
  if ($auth -eq 'operator') {
    return [pscustomobject]@{ blocked=$false; risk=[string]$danger.risk; reason=[string]$danger.reason; authorization=$auth; exempt='operator' }
  }
  # 2026-06-28 (operator root-fix, authorized): the project-autopilot COORDINATOR is a bridge-generated
  # planner -- it emits NO feature code, only durable planning docs + a [[PROJECT_BACKLOG]] list of atoms,
  # and runs read-mostly in the project sandbox. Each emitted atom is re-vetted by THIS gate at its own
  # claim time. Its prompt is a teaching template that legitimately contains safety/DAG vocabulary
  # (e.g. "do not skip a chapter", a JSON schema example value "auth|gallery|chat|...") as instructions
  # for the worker, never as an action the coordinator performs. The danger scan AND-rule false-positives
  # on that boilerplate (verb 'skip' + noun 'auth') and parked EVERY coordinator to 'held' attempts=0,
  # deadlocking project autopilot (a chapter never decomposes). Treat the coordinator like [[DISCUSS]]:
  # the gate still runs and warns, but does not auto-hold a trusted planner.
  $isAutopilotCoordinator = $false
  try {
    if (Get-Command Test-ProjectAutopilotCoordinatorText -ErrorAction SilentlyContinue) {
      $isAutopilotCoordinator = [bool](Test-ProjectAutopilotCoordinatorText -Text $text)
    } else {
      $isAutopilotCoordinator = [bool]($text -match '(?is)\[project-autopilot\s+[^\]]+\].*Project Autopilot coordinator for channel')
    }
  } catch {}
  if ($isAutopilotCoordinator) {
    return [pscustomobject]@{ blocked=$false; risk=[string]$danger.risk; reason=[string]$danger.reason; authorization=$auth; exempt='autopilot-coordinator' }
  }
  # 2026-06-28 (operator root-fix, authorized; sibling of the coordinator wedge one level down):
  # project-autopilot ATOMS are bridge-generated single-file code tasks the (trusted) coordinator
  # decomposed from an approved plan. They hit the SAME danger-scan false-positive -- teaching/example
  # vocabulary inside the atom's own description (verb 'disabled/skip/удалить' + noun 'secret/проверк')
  # trips the AND-rule and parked the atom to 'held', so a wave that has only that atom ready claims 0 and
  # project autopilot stalls (the coordinator deadlock, one level down). Exempt ONLY project-scope autopilot
  # atoms that do NOT touch the control plane (those still block) and are NOT bridge-self. Safety preserved:
  # such atoms are sandboxed to the PROJECT tree (cannot edit bridge control-plane), and each still passes
  # its per-atom critic + QA + acceptance. The strong action-class rules (irreversible/destructive on core
  # files) and the control-plane guard remain in force.
  $isAutopilotAtom = $false
  try {
    $itFrom = [string]$Item.from
    $itScope = [string]$Item.scope
    $itTags = @($Item.tags | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $touchesCP = $false
    try { if (Get-Command Test-PolicyItemTouchesControlPlane -ErrorAction SilentlyContinue) { $touchesCP = [bool](Test-PolicyItemTouchesControlPlane -Item $Item) } } catch { $touchesCP = $true }
    $isAutopilotAtom = (
      ($itFrom -eq 'project-autopilot') -and
      ($itScope -eq 'project') -and
      (@($itTags) -contains 'atom') -and
      (-not (@($itTags) -contains 'bridge-self')) -and
      (-not $touchesCP)
    )
  } catch { $isAutopilotAtom = $false }
  if ($isAutopilotAtom) {
    return [pscustomobject]@{ blocked=$false; risk=[string]$danger.risk; reason=[string]$danger.reason; authorization=$auth; exempt='autopilot-atom' }
  }
  return [pscustomobject]@{ blocked=$true; risk=[string]$danger.risk; reason=[string]$danger.reason; authorization=$auth; exempt='' }
}
