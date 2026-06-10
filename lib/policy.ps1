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
  return [pscustomobject]@{ blocked=$true; risk=[string]$danger.risk; reason=[string]$danger.reason; authorization=$auth; exempt='' }
}
