# 42-autopilot-run.ps1 -- Project autopilot approval, coordinator, and project backlog marker handling.
# Mechanical split from lib/backlog.ps1; keep loaded through ../backlog.ps1.

function New-ProjectAutopilotCoordinatorTaskText {
  param([string]$Slug, [string]$ProjectRoot, [int]$MaxTasks = 12)
  $max = [Math]::Max(1, [Math]::Min(50, [int]$MaxTasks))
  return @"
[project-autopilot $Slug] [[NORMAL]]

Project Autopilot coordinator for channel '$Slug'.

Work only in $ProjectRoot.

Mission: keep this project moving without the operator manually feeding backlog items.

Plan gate status:
- This coordinator is queued only after the channel-level Discuss-First plan gate has approved the current PROJECT_PLAN signature.
- Treat channels/$Slug/channel.json plan_approved=true and its approved signature as the source of truth for execution permission.
- If PROJECT_PLAN.md, PROJECT_MAP.md, or .bridge/project-contract.json still contain pre-approval wording such as "not approved", "UNAPPROVED", or "planned, not approved", do not treat that wording as a blocker after this coordinator has been queued. Use those words as historical planning status unless the channel gate itself is not approved.

Rules:
- Do NOT implement feature code in this coordinator task, except small durable planning docs such as CHAPTER_N_ATOMS.md.
- Read PROJECT_BRIEF.md, DISCUSS_PRODUCT.md, DISCUSS_UX.md, DISCUSS_UI.md, DISCUSS_BACKEND.md, DISCUSS_QA.md, DISCUSS_INTEGRATION.md, PROJECT_MAP.md, PROJECT_PLAN.md, .bridge/project-contract.json, existing CHAPTER_*_ATOMS.md files, README, git log/status, and current code.
- Read the project memory/context supplied in the prompt. Preserve durable decisions, risks, invariants, tests, and open questions.
- Treat .bridge/project-contract.json as the machine-readable product/UX/acceptance contract. It must describe goal, requirements/capabilities, screens/routes/interfaces/modules, user journeys/workflows, ux_contract/interface_contract, and acceptance scenarios.
- Treat planning as staged: brief -> product -> UX -> UI -> backend -> QA -> integration. Every later stage must explicitly use decisions from earlier stages. The integration stage resolves cross-stage conflicts before implementation.
- If the stage docs, map, plan, or contract are shallow/missing/stale, do NOT emit implementation atoms. Emit durable memory about the gap and finish, or emit docs-only planning atoms that deepen PROJECT_BRIEF.md, DISCUSS_*.md, PROJECT_MAP.md, PROJECT_PLAN.md, and .bridge/project-contract.json.
- Determine the next approved/incomplete chapter from the contract and plan, not from a guessed feature list.
- Decompose only ONE next chapter/wave into small atomic implementation tasks. Prefer 3-$max tasks; fewer is OK if the chapter is small.
- Each atom must be a small verifiable change, with clear dependencies, files/touch-set, acceptance checks, and commit requirement.
- Model the execution DAG explicitly: independent atoms have empty depends_on; dependent atoms reference prerequisite slugs.
- Prefer a ready frontier: several independent atoms in the same wave, then dependent atoms in later waves.
- Use chapter, wave, parallel_group, files, depends_on, acceptance, and checks so the scheduler can run the team safely.
- Every atom acceptance must trace back to a project-contract requirement, journey, surface, or acceptance scenario. Do not use generic "looks good" UX checks.
- Before PROJECT_BACKLOG, emit durable project memory markers when useful:
  [[PROJECT_DECISION: ...]]
  [[PROJECT_RISK: ...]]
  [[PROJECT_INVARIANT: ...]]
  [[PROJECT_TEST: ...]]
  [[PROJECT_OPEN_QUESTION: ...]]
  Keep memory concise and durable; do not store transient progress noise.
- If a product decision is truly blocking, do not invent it: emit [[PROJECT_OPEN_QUESTION: ...]] and finish without PROJECT_BACKLOG.
- Never put real secrets, local DB files, uploads, .next, or node_modules in git.
- For Next.js/TypeScript work, each atom should normally require npm run typecheck and npm run build unless the atom is docs-only.

When you have the next atom batch, output it as STRICT JSON inside this exact marker:
[[PROJECT_BACKLOG]]
[
  {
    "slug": "short-stable-atom-id",
    "title": "Human readable atom title",
    "task": "Full task text for the worker. Include project path, dependencies, acceptance checks, and commit requirement.",
    "chapter": "approved chapter / project area",
    "wave": "wave-1",
    "parallel_group": "auth|gallery|chat|admin|docs|tests|...",
    "files": ["relative/path/or/directory"],
    "depends_on": ["slug-of-prerequisite-if-any"],
    "acceptance": ["observable acceptance criterion"],
    "checks": ["npm run typecheck", "npm run build"],
    "severity": "normal"
  }
]
[[/PROJECT_BACKLOG]]

The driver will add those atoms to approved project backlog automatically. Do not use operator-delegate and do not edit backlog.jsonl manually.

Finish with STATUS: DONE after emitting the marker, or STATUS: DONE without the marker if no work remains.
"@
}

function Test-ProjectPlanApproved {
  # 2026-06-02: Discuss-First gate for Project Autopilot. Autopilot only EXPANDS a PROJECT_PLAN the
  # operator has explicitly APPROVED (flow phase Ф4). Without approval the bridge stays in discuss/
  # planning and does NOT auto-generate/execute atoms — this keeps autopilot UNDER Discuss-First, not
  # instead of it, and prevents it from scaling an un-vetted plan into a frankenstein (observed on
  # sample-project: many files build-green but product-incoherent because the plan skipped Ф1–Ф4).
  # Reads channels/<ch>/channel.json -> plan_approved. Default $false = safe (no approval => no autopilot).
  param([string]$Channel, [string]$ProjectRoot = '')
  try {
    $cj = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel) 'channel.json'
    if (-not (Test-Path -LiteralPath $cj)) { return $false }
    $raw = [System.IO.File]::ReadAllText($cj, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not $raw -or -not ($raw.PSObject.Properties.Name -contains 'plan_approved') -or -not [bool]$raw.plan_approved) { return $false }
    $approvedSignature = ''
    try {
      if ($raw.PSObject.Properties.Name -contains 'plan_approved_signature') { $approvedSignature = [string]$raw.plan_approved_signature }
    } catch {}
    if (-not [string]::IsNullOrWhiteSpace($approvedSignature) -and -not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
      $currentSignature = Get-ProjectAutopilotPlanSignature -ProjectRoot $ProjectRoot
      if ([string]::IsNullOrWhiteSpace($currentSignature)) { return $false }
      if ($currentSignature -ne $approvedSignature) {
        $approvedGitHead = ''
        try {
          if ($raw.PSObject.Properties.Name -contains 'plan_approved_git_head') { $approvedGitHead = [string]$raw.plan_approved_git_head }
        } catch {}
        $unchanged = Test-ProjectAutopilotPlanFilesUnchangedSinceGitHead -ProjectRoot $ProjectRoot -GitHead $approvedGitHead
        if (-not ([bool]$unchanged.ok -and [bool]$unchanged.unchanged)) { return $false }
      }
    }
    return $true
  } catch {}
  return $false
}

function Set-ProjectPlanApproved {
  # Operator action at Discuss-First Ф4: mark a channel's PROJECT_PLAN approved so Project Autopilot may
  # begin executing it. Also stamps the approved time. To re-gate (force re-approval), pass -Approved:$false.
  param([string]$Channel, [bool]$Approved = $true)
  $cj = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel) 'channel.json'
  if (-not (Test-Path -LiteralPath $cj)) { throw "channel.json not found: $Channel" }
  $raw = [System.IO.File]::ReadAllText($cj, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
  $projectRoot = ''
  try {
    if ($raw -and ($raw.PSObject.Properties.Name -contains 'project_root')) { $projectRoot = [string]$raw.project_root }
  } catch {}
  try {
    if ([string]::IsNullOrWhiteSpace($projectRoot) -and (Get-Command Get-ChannelProjectBinding -ErrorAction SilentlyContinue)) {
      $binding = Get-ChannelProjectBinding -Slug $Channel
      if ($binding -and [bool]$binding.ok) { $projectRoot = [string]$binding.project_root }
    }
  } catch {}
  $contractReady = $null
  if ($Approved) {
    $contractReady = Test-ProjectPlanContractReady -ProjectRoot $projectRoot
    if (-not [bool]$contractReady.ready) {
      throw ("project plan contract is not ready: " + ((@($contractReady.issues) | Select-Object -First 8) -join '; '))
    }
  }
  $raw | Add-Member -NotePropertyName plan_approved -NotePropertyValue $Approved -Force
  $raw | Add-Member -NotePropertyName plan_approved_at -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
  if ($Approved -and $contractReady) {
    $raw | Add-Member -NotePropertyName plan_approved_signature -NotePropertyValue ([string]$contractReady.signature) -Force
    $raw | Add-Member -NotePropertyName plan_approved_signature_version -NotePropertyValue 'staged-v1' -Force
    $raw | Add-Member -NotePropertyName plan_approved_files -NotePropertyValue @(Get-ProjectAutopilotPlanSignatureFiles) -Force
    $raw | Add-Member -NotePropertyName plan_approved_git_head -NotePropertyValue (Get-ProjectAutopilotGitHead -ProjectRoot $projectRoot) -Force
    $raw | Add-Member -NotePropertyName plan_contract_path -NotePropertyValue ([string]$contractReady.contract_path) -Force
  } elseif (-not $Approved) {
    $raw | Add-Member -NotePropertyName plan_approved_signature -NotePropertyValue '' -Force
    $raw | Add-Member -NotePropertyName plan_approved_signature_version -NotePropertyValue '' -Force
    $raw | Add-Member -NotePropertyName plan_approved_files -NotePropertyValue @() -Force
    $raw | Add-Member -NotePropertyName plan_approved_git_head -NotePropertyValue '' -Force
  }
  [System.IO.File]::WriteAllText($cj, (($raw | ConvertTo-Json -Depth 10) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  # clear the one-time gate-notified marker so a future re-gate (plan rewrite) notifies the operator again
  try { $gm = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel) '.plan-gate-notified'; if (Test-Path -LiteralPath $gm) { Remove-Item -LiteralPath $gm -Force -ErrorAction SilentlyContinue } } catch {}
  try { $cm = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Channel) '.plan-contract-gate-notified'; if (Test-Path -LiteralPath $cm) { Remove-Item -LiteralPath $cm -Force -ErrorAction SilentlyContinue } } catch {}
  return $Approved
}

function Start-ProjectAutopilotIfNeeded {
  param([string]$Reason = 'idle-empty-backlog')
  $cfg = Get-ProjectAutopilotConfig
  if (-not [bool]$cfg.enabled) { return [pscustomobject]@{ queued=$false; reason='disabled' } }
  $binding = Get-ProjectAutopilotBinding
  if (-not $binding) { return [pscustomobject]@{ queued=$false; reason='not-project-channel' } }
  $slug = [string]$binding.slug
  $root = [string]$binding.project_root
  # 2026-06-02 DISCUSS-FIRST GATE: autopilot only executes an operator-APPROVED PROJECT_PLAN (Ф4).
  # Until the operator runs Set-ProjectPlanApproved for this channel, the bridge stays in discuss/
  # planning and autopilot does NOT auto-queue coordinator/atoms. This is the fix for autopilot
  # bypassing Ф1–Ф4 and scaling an un-vetted plan into a frankenstein.
  if (-not (Test-ProjectPlanApproved -Channel $slug -ProjectRoot $root)) {
    return [pscustomobject]@{ queued=$false; reason='plan-not-approved'; channel=$slug }
  }
  $planContract = Test-ProjectPlanContractReady -ProjectRoot $root
  if (-not [bool]$planContract.ready) {
    return [pscustomobject]@{
      queued = $false
      reason = 'plan-contract-not-ready'
      channel = $slug
      project_root = $root
      issues = @($planContract.issues)
      contract_path = [string]$planContract.contract_path
    }
  }

  $pressure = Get-ProjectAutopilotBacklogPressure
  if ([int]$pressure.runnable -gt 0) { return [pscustomobject]@{ queued=$false; reason='backlog-not-empty'; pressure=$pressure } }
  if ([int]$pressure.autopilot_open -gt 0) { return [pscustomobject]@{ queued=$false; reason='autopilot-already-open'; pressure=$pressure } }

  $last = Read-ProjectAutopilotState
  if ($last) {
    try {
      if ([bool](Get-BacklogPackObjectValue -Obj $last -Name 'paused' -Default $false)) {
        return [pscustomobject]@{
          queued = $false
          reason = 'paused-empty-scope'
          empty_coordinator_streak = (Get-ProjectAutopilotStateInt -State $last -Name 'empty_coordinator_streak' -Default 0)
          pause_reason = [string](Get-BacklogPackObjectValue -Obj $last -Name 'pause_reason' -Default '')
          pressure = $pressure
        }
      }
    } catch {}
    try {
      $stateStreakExisting = Get-ProjectAutopilotStateInt -State $last -Name 'empty_coordinator_streak' -Default 0
      $inferredEmptyExisting = [int](Get-ProjectAutopilotInferredEmptyCoordinatorStreak)
      if ($inferredEmptyExisting -gt $stateStreakExisting) {
        if ($inferredEmptyExisting -ge [int]$cfg.emptyCoordinatorLimit) {
          $nowPauseExisting = (Get-Date).ToUniversalTime().ToString('o')
          $last | Add-Member -NotePropertyName ts -NotePropertyValue $nowPauseExisting -Force
          $last | Add-Member -NotePropertyName channel -NotePropertyValue $slug -Force
          $last | Add-Member -NotePropertyName project_root -NotePropertyValue $root -Force
          $last | Add-Member -NotePropertyName empty_coordinator_streak -NotePropertyValue $inferredEmptyExisting -Force
          $last | Add-Member -NotePropertyName paused -NotePropertyValue $true -Force
          $last | Add-Member -NotePropertyName paused_at -NotePropertyValue $nowPauseExisting -Force
          $last | Add-Member -NotePropertyName pause_reason -NotePropertyValue ("legacy empty coordinator streak reached $inferredEmptyExisting/$([int]$cfg.emptyCoordinatorLimit) without PROJECT_BACKLOG") -Force
          if (-not ($last.PSObject.Properties.Name -contains 'recent_outcomes')) { $last | Add-Member -NotePropertyName recent_outcomes -NotePropertyValue @() -Force }
          Write-ProjectAutopilotState $last
          try {
            Add-Message -From system -Text ("⏸ Project Autopilot: найден старый пустой цикл coordinator-задач (" + $inferredEmptyExisting + "/" + [int]$cfg.emptyCoordinatorLimit + "). Автопилот канала " + $slug + " поставлен на паузу до расширения PROJECT_PLAN/scope.") -Kind event | Out-Null
          } catch {}
          return [pscustomobject]@{ queued=$false; reason='paused-empty-scope'; empty_coordinator_streak=$inferredEmptyExisting; pressure=$pressure }
        }
      }
    } catch {}
    try {
      $lastTs = [datetime]::Parse([string]$last.ts).ToUniversalTime()
      $ageMin = ((Get-Date).ToUniversalTime() - $lastTs).TotalMinutes
      if ($ageMin -lt [int]$cfg.cooldownMinutes) {
        return [pscustomobject]@{ queued=$false; reason='cooldown'; cooldown_remaining_minutes=[int]([int]$cfg.cooldownMinutes - [Math]::Floor($ageMin)); pressure=$pressure }
      }
    } catch {}
  } else {
    try {
      $inferredEmpty = [int](Get-ProjectAutopilotInferredEmptyCoordinatorStreak)
      if ($inferredEmpty -ge [int]$cfg.emptyCoordinatorLimit) {
        $nowPause = (Get-Date).ToUniversalTime().ToString('o')
        $pauseState = [pscustomobject]@{
          ts = $nowPause
          channel = $slug
          project_root = $root
          queued_id = ''
          reason = [string]$Reason
          empty_coordinator_streak = $inferredEmpty
          paused = $true
          paused_at = $nowPause
          pause_reason = "legacy empty coordinator streak reached $inferredEmpty/$([int]$cfg.emptyCoordinatorLimit) without PROJECT_BACKLOG"
          recent_outcomes = @()
        }
        Write-ProjectAutopilotState $pauseState
        try {
          Add-Message -From system -Text ("⏸ Project Autopilot: найден старый пустой цикл coordinator-задач (" + $inferredEmpty + "/" + [int]$cfg.emptyCoordinatorLimit + "). Автопилот канала " + $slug + " поставлен на паузу до расширения PROJECT_PLAN/scope.") -Kind event | Out-Null
        } catch {}
        return [pscustomobject]@{ queued=$false; reason='paused-empty-scope'; empty_coordinator_streak=$inferredEmpty; pressure=$pressure }
      }
    } catch {}
  }

  if (-not (Test-ProjectAutopilotProjectClean -ProjectRoot $root)) {
    return [pscustomobject]@{ queued=$false; reason='project-dirty-or-git-unavailable'; pressure=$pressure }
  }

  $task = New-ProjectAutopilotCoordinatorTaskText -Slug $slug -ProjectRoot $root -MaxTasks ([int]$cfg.maxTasksPerBatch)
  $id = Add-Idea -Text $task -From 'project-autopilot' -Tags @('project-autopilot','auto-generated') -Status 'approved' -Severity 'critical' -Project $slug -Scope 'project' -SkipCurator
  if ([string]::IsNullOrWhiteSpace([string]$id)) { return [pscustomobject]@{ queued=$false; reason='add-idea-failed'; pressure=$pressure } }

  $st = [ordered]@{
    ts = (Get-Date).ToUniversalTime().ToString('o')
    channel = $slug
    project_root = $root
    queued_id = [string]$id
    reason = [string]$Reason
    empty_coordinator_streak = (Get-ProjectAutopilotStateInt -State $last -Name 'empty_coordinator_streak' -Default 0)
    paused = $false
    paused_at = ''
    pause_reason = ''
    recent_outcomes = @(Get-ProjectAutopilotRecentOutcomes -State $last)
  }
  Write-ProjectAutopilotState ([pscustomobject]$st)
  try {
    Write-BacklogJsonLine ([ordered]@{ ts=$st.ts; action='project-autopilot-queued'; channel=$slug; item_id=[string]$id; reason=[string]$Reason })
  } catch {}
  try {
    Add-Message -From system -Text ("🧭 Project Autopilot: backlog пуст, поставил coordinator-задачу " + [string]$id + " для следующей главы проекта.") -Kind event | Out-Null
  } catch {}
  return [pscustomobject]@{ queued=$true; id=[string]$id; reason=[string]$Reason; pressure=$pressure }
}

function ConvertTo-ProjectAutopilotSlug {
  param([string]$Text)
  $v = ([string]$Text).Trim().ToLowerInvariant()
  $v = $v -replace '[^a-z0-9а-яё._-]+','-'
  $v = $v.Trim([char[]]@('-','_','.'))
  if ($v.Length -gt 80) { $v = $v.Substring(0,80).Trim([char[]]@('-','_','.')) }
  if ([string]::IsNullOrWhiteSpace($v)) {
    try {
      $sha = [System.Security.Cryptography.SHA1]::Create()
      $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
      $hash = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
      $v = 'atom-' + $hash.Substring(0,10)
    } catch { $v = 'atom-' + ([guid]::NewGuid().ToString('N').Substring(0,10)) }
  }
  return $v
}

function Get-ProjectAutopilotTaskArrayFromMarker {
  param([string]$Block)
  $raw = ([string]$Block).Trim()
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  $raw = ($raw -replace '```json','' -replace '```','').Trim()
  $json = ''
  $arrMatch = [regex]::Match($raw, '(?s)\[.*\]')
  if ($arrMatch.Success) { $json = $arrMatch.Value }
  else {
    $objMatch = [regex]::Match($raw, '(?s)\{.*\}')
    if ($objMatch.Success) { $json = $objMatch.Value }
  }
  if ([string]::IsNullOrWhiteSpace($json)) { return @() }
  try {
    $parsed = $json | ConvertFrom-Json
    if ($parsed -is [array]) { return @($parsed) }
    if ($parsed -and $parsed.PSObject.Properties.Name -contains 'tasks') { return @($parsed.tasks) }
    return @($parsed)
  } catch {
    return @()
  }
}

function Get-ProjectAutopilotTaskStringField {
  param($Task, [string[]]$Names = @())
  foreach ($name in @($Names)) {
    try {
      $v = Get-BacklogPackObjectValue -Obj $Task -Name $name -Default $null
      if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
    } catch {}
  }
  return ''
}

function Get-ProjectAutopilotTaskStringArray {
  param($Task, [string[]]$Names = @())
  $out = New-Object 'System.Collections.Generic.List[string]'
  foreach ($name in @($Names)) {
    $raw = $null
    try { $raw = Get-BacklogPackObjectValue -Obj $Task -Name $name -Default $null } catch { $raw = $null }
    if ($null -eq $raw) { continue }
    foreach ($v in @($raw)) {
      $s = ([string]$v).Trim()
      if (-not [string]::IsNullOrWhiteSpace($s)) { [void]$out.Add($s) }
    }
    if ($out.Count -gt 0) { break }
  }
  return @($out.ToArray() | Sort-Object -Unique)
}

function Set-ProjectAutopilotIdeaMetadata {
  param([string]$Id, $Task, [string]$SourceTaskId = '')
  if ([string]::IsNullOrWhiteSpace($Id) -or -not $Task) { return $false }
  return (Invoke-BacklogLocked ({
    $items = @(Get-Backlog)
    $found = $false
    foreach ($i in $items) {
      if ([string]$i.id -ne $Id) { continue }
      $found = $true
      $slug = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $Task -Name 'slug' -Default (Get-BacklogPackObjectValue -Obj $Task -Name 'title' -Default $Id)))
      $title = [string](Get-BacklogPackObjectValue -Obj $Task -Name 'title' -Default $slug)
      $files = @()
      try { $files = @((Get-BacklogPackObjectValue -Obj $Task -Name 'files' -Default @()) | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } catch { $files = @() }
      $deps = @()
      try { $deps = @((Get-BacklogPackObjectValue -Obj $Task -Name 'depends_on' -Default @()) | ForEach-Object { ConvertTo-ProjectAutopilotSlug ([string]$_) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } catch { $deps = @() }
      $chapter = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('chapter','phase','area')
      $wave = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('wave','milestone')
      $parallelGroup = Get-ProjectAutopilotTaskStringField -Task $Task -Names @('parallel_group','lane','workstream')
      $acceptance = @(Get-ProjectAutopilotTaskStringArray -Task $Task -Names @('acceptance','acceptance_checks','criteria'))
      $checks = @(Get-ProjectAutopilotTaskStringArray -Task $Task -Names @('checks','verify','verification'))
      $i | Add-Member -NotePropertyName slug -NotePropertyValue $slug -Force
      $i | Add-Member -NotePropertyName title -NotePropertyValue $title -Force
      $i | Add-Member -NotePropertyName autopilot_generated -NotePropertyValue $true -Force
      $i | Add-Member -NotePropertyName autopilot_source_task -NotePropertyValue ([string]$SourceTaskId) -Force
      if ($deps.Count -gt 0) { $i | Add-Member -NotePropertyName depends_on -NotePropertyValue @($deps) -Force }
      if (-not [string]::IsNullOrWhiteSpace($chapter)) { $i | Add-Member -NotePropertyName chapter -NotePropertyValue $chapter -Force }
      if (-not [string]::IsNullOrWhiteSpace($wave)) { $i | Add-Member -NotePropertyName wave -NotePropertyValue $wave -Force }
      if (-not [string]::IsNullOrWhiteSpace($parallelGroup)) { $i | Add-Member -NotePropertyName parallel_group -NotePropertyValue $parallelGroup -Force }
      if ($acceptance.Count -gt 0) { $i | Add-Member -NotePropertyName acceptance_checks -NotePropertyValue @($acceptance) -Force }
      if ($checks.Count -gt 0) { $i | Add-Member -NotePropertyName verification_checks -NotePropertyValue @($checks) -Force }
      if ($files.Count -gt 0) {
        $normFiles = @($files | ForEach-Object { ([string]$_).Replace('\','/').Trim().ToLowerInvariant() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
        if ($normFiles.Count -gt 0) {
          $i | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @($normFiles) -Force
          $i | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue ('file:' + [string]$normFiles[0]) -Force
          $i | Add-Member -NotePropertyName workpack_lane_hint -NotePropertyValue ('serial:file:' + [string]$normFiles[0]) -Force
        }
      }
      $meta = [ordered]@{}
      if (-not [string]::IsNullOrWhiteSpace($chapter)) { $meta.chapter = $chapter }
      if (-not [string]::IsNullOrWhiteSpace($wave)) { $meta.wave = $wave }
      if (-not [string]::IsNullOrWhiteSpace($parallelGroup)) { $meta.parallel_group = $parallelGroup }
      if ($deps.Count -gt 0) { $meta.depends_on = @($deps) }
      if ($files.Count -gt 0) { $meta.files = @($files) }
      if ($acceptance.Count -gt 0) { $meta.acceptance = @($acceptance) }
      if ($checks.Count -gt 0) { $meta.checks = @($checks) }
      if ($meta.Count -gt 0) { $i | Add-Member -NotePropertyName autopilot_meta -NotePropertyValue ([pscustomobject]$meta) -Force }
      break
    }
    if ($found) { Save-Backlog $items }
    return $found
  }.GetNewClosure()))
}

function Add-ProjectBacklogFromMarker {
  param(
    [string]$Block,
    [string]$Channel = '',
    [string]$Source = 'agent',
    [string]$SourceTaskId = '',
    [int]$MaxTasks = 12
  )
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-ProjectAutopilotSlug }
  if ([string]::IsNullOrWhiteSpace($Channel) -or $Channel -eq 'main') {
    return [pscustomobject]@{ created=0; skipped=0; errors=@('project backlog marker ignored outside project channel'); ids=@() }
  }
  $max = [Math]::Max(1, [Math]::Min(50, [int]$MaxTasks))
  $tasks = @(Get-ProjectAutopilotTaskArrayFromMarker -Block $Block | Select-Object -First $max)
  if ($tasks.Count -eq 0) { return [pscustomobject]@{ created=0; skipped=0; errors=@('no valid JSON tasks found'); ids=@() } }

  $existing = @(Get-Backlog)
  $existingSlugs = @{}
  foreach ($it in $existing) {
    $st = [string](Get-BacklogPackObjectValue -Obj $it -Name 'status' -Default '')
    if ($st -in @('rejected','auto-dropped','failed')) { continue }
    $sl = [string](Get-BacklogPackObjectValue -Obj $it -Name 'slug' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($sl)) { $existingSlugs[$sl] = $true }
  }

  $created = New-Object 'System.Collections.Generic.List[string]'
  $createdSlugs = New-Object 'System.Collections.Generic.List[string]'
  $createdChapters = New-Object 'System.Collections.Generic.List[string]'
  $errors = New-Object 'System.Collections.Generic.List[string]'
  $skipped = 0
  foreach ($t in $tasks) {
    $slug = ConvertTo-ProjectAutopilotSlug ([string](Get-BacklogPackObjectValue -Obj $t -Name 'slug' -Default (Get-BacklogPackObjectValue -Obj $t -Name 'title' -Default '')))
    if ($existingSlugs.ContainsKey($slug)) { $skipped++; continue }
    $title = [string](Get-BacklogPackObjectValue -Obj $t -Name 'title' -Default $slug)
    $body = [string](Get-BacklogPackObjectValue -Obj $t -Name 'task' -Default '')
    if ([string]::IsNullOrWhiteSpace($body)) { $body = $title }
    if ([string]::IsNullOrWhiteSpace($body) -or $body.Length -lt 40) { [void]$errors.Add("task '$slug' too short"); continue }
    $severity = ([string](Get-BacklogPackObjectValue -Obj $t -Name 'severity' -Default '')).ToLowerInvariant()
    if ($severity -eq 'normal') { $severity = '' }
    if ($severity -notin @('critical','warning','info','')) { $severity = '' }
    $files = @()
    try { $files = @((Get-BacklogPackObjectValue -Obj $t -Name 'files' -Default @()) | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } catch { $files = @() }
    $deps = @(Get-ProjectAutopilotTaskStringArray -Task $t -Names @('depends_on','dependencies'))
    $chapter = Get-ProjectAutopilotTaskStringField -Task $t -Names @('chapter','phase','area')
    $wave = Get-ProjectAutopilotTaskStringField -Task $t -Names @('wave','milestone')
    $parallelGroup = Get-ProjectAutopilotTaskStringField -Task $t -Names @('parallel_group','lane','workstream')
    $acceptance = @(Get-ProjectAutopilotTaskStringArray -Task $t -Names @('acceptance','acceptance_checks','criteria'))
    $checks = @(Get-ProjectAutopilotTaskStringArray -Task $t -Names @('checks','verify','verification'))
    $detailLines = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($chapter)) { [void]$detailLines.Add("Chapter: $chapter") }
    if (-not [string]::IsNullOrWhiteSpace($wave)) { [void]$detailLines.Add("Wave: $wave") }
    if (-not [string]::IsNullOrWhiteSpace($parallelGroup)) { [void]$detailLines.Add("Parallel group: $parallelGroup") }
    if ($deps.Count -gt 0) { [void]$detailLines.Add("Depends on: " + (($deps | Select-Object -First 12) -join ', ')) }
    if ($acceptance.Count -gt 0) { [void]$detailLines.Add("Acceptance: " + (($acceptance | Select-Object -First 6) -join ' ; ')) }
    if ($checks.Count -gt 0) { [void]$detailLines.Add("Checks: " + (($checks | Select-Object -First 6) -join ' ; ')) }
    $detailLine = if ($detailLines.Count -gt 0) { "`n`n" + (($detailLines.ToArray()) -join "`n") } else { '' }
    $fileLine = if ($files.Count -gt 0) { "`n`nFiles: " + (($files | Select-Object -First 12) -join ', ') } else { '' }
    $text = "[project-autopilot $slug] [[NORMAL]]`n`n$title`n`n$body$detailLine$fileLine"
    $id = Add-Idea -Text $text -From 'project-autopilot' -Tags @('project-autopilot','auto-generated','atom') -Status 'approved' -Severity $severity -Project $Channel -Scope 'project' -SkipCurator
    if ([string]::IsNullOrWhiteSpace([string]$id)) { [void]$errors.Add("Add-Idea failed for '$slug'"); continue }
    try { Set-ProjectAutopilotIdeaMetadata -Id ([string]$id) -Task $t -SourceTaskId $SourceTaskId | Out-Null } catch {}
    $existingSlugs[$slug] = $true
    [void]$created.Add([string]$id)
    [void]$createdSlugs.Add($slug)
    if (-not [string]::IsNullOrWhiteSpace($chapter)) { [void]$createdChapters.Add($chapter) }
    try { Write-BacklogJsonLine ([ordered]@{ ts=(Get-Date).ToUniversalTime().ToString('o'); action='project-backlog-add'; channel=$Channel; item_id=[string]$id; slug=$slug; source=$Source }) } catch {}
  }

  try { Request-BacklogPackIfNeeded | Out-Null } catch {}
  return [pscustomobject]@{ created=$created.Count; skipped=$skipped; errors=@($errors.ToArray()); ids=@($created.ToArray()); slugs=@($createdSlugs.ToArray()); chapters=@($createdChapters.ToArray() | Sort-Object -Unique) }
}
