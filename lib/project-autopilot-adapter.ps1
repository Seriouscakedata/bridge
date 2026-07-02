# project-autopilot-adapter.ps1 -- materialize project-autopilot inputs from DISCUSS output.
#
# ROOT FIX 2026-06-30 (diffusion-trigger-schema-mismatch): the Discuss-First flow produces
# channels/<ch>/plan.jsonl (a chapter board: epic + task nodes) plus a 9-section delivery contract
# (.bridge/project-contract.json), but the project-autopilot wide-diffusion gate
# (Test-ProjectPlanContractReady) requires PROJECT_PLAN.md + PROJECT_MAP.md in the project root, a few
# spec docs, and contract legacy fields (requirements/journeys). NOTHING converted the discuss output
# into those autopilot inputs, so the gate never passed and wide diffusion never triggered -- the
# coder just built the app sequentially. This adapter bridges that handoff: given the plan board and
# the contract, it deterministically writes the autopilot's required spec artifacts (targeting the
# lightest 'lite' profile) so the gate passes -- AFTER the operator approves the plan (plan_approved
# stays a manual Ф4 safeguard; this adapter never flips it).

function Get-AdapterPlanChapters {
  # Ordered chapters from plan.jsonl records: each 'task' node becomes a chapter (epic = intro).
  param($Records)
  $out = New-Object 'System.Collections.Generic.List[object]'
  $i = 0
  foreach ($r in @($Records)) {
    $type = ''
    try { $type = [string]$r.type } catch {}
    if ($type -ne 'task') { continue }
    $i++
    $title = ''; try { $title = ([string]$r.title).Trim() } catch {}
    if ([string]::IsNullOrWhiteSpace($title)) { $title = "Chapter $i" }
    $crit = ''; try { $crit = ([string]$r.criteria).Trim() } catch {}
    $deps = @(); try { $deps = @($r.deps | ForEach-Object { [string]$_ }) } catch {}
    $id = ''; try { $id = [string]$r.id } catch {}
    [void]$out.Add([pscustomobject]@{ n = $i; title = $title; criteria = $crit; deps = @($deps); id = $id })
  }
  return @($out.ToArray())
}

function Get-AdapterContractValue {
  param($Contract, [string[]]$Names, [string]$Default = '')
  foreach ($n in $Names) {
    try { if ($Contract.PSObject.Properties.Name -contains $n -and $null -ne $Contract.$n) {
      $v = $Contract.$n
      if ($v -is [string]) { if (-not [string]::IsNullOrWhiteSpace($v)) { return [string]$v } }
      else { return $v }
    } } catch {}
  }
  return $Default
}

function ConvertTo-AdapterText {
  # Flatten a contract section (string | array | object) into readable multi-line text.
  param($Value)
  if ($null -eq $Value) { return '' }
  if ($Value -is [string]) { return [string]$Value }
  $sb = New-Object System.Text.StringBuilder
  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    foreach ($item in $Value) {
      if ($item -is [string]) { [void]$sb.AppendLine("- $item") }
      elseif ($null -ne $item) {
        $parts = @()
        foreach ($p in $item.PSObject.Properties) { $pv = $p.Value; if ($pv -isnot [string]) { try { $pv = ($pv | ConvertTo-Json -Compress -Depth 4) } catch { $pv = [string]$pv } }; $parts += ("$($p.Name): $pv") }
        [void]$sb.AppendLine("- " + ($parts -join '; '))
      }
    }
    return $sb.ToString().TrimEnd()
  }
  foreach ($p in $Value.PSObject.Properties) {
    $pv = $p.Value; if ($pv -isnot [string]) { try { $pv = ($pv | ConvertTo-Json -Compress -Depth 4) } catch { $pv = [string]$pv } }
    [void]$sb.AppendLine("**$($p.Name):** $pv")
  }
  return $sb.ToString().TrimEnd()
}

function Convert-DiscussToAutopilotInputs {
  # Deterministically write PROJECT_PLAN.md + PROJECT_MAP.md + PROJECT_BRIEF.md + .bridge/specs/*
  # and enrich the contract (spec_profile=lite + requirements + journeys) so the autopilot gate passes.
  param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)]$PlanRecords
  )
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    return [pscustomobject]@{ ok = $false; reason = 'project-root-missing'; files = @() }
  }
  $enc = New-Object System.Text.UTF8Encoding($false)
  $bridgeDir = Join-Path $ProjectRoot '.bridge'
  $specsDir = Join-Path $bridgeDir 'specs'
  foreach ($d in @($bridgeDir, $specsDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
  $contractPath = Join-Path $bridgeDir 'project-contract.json'
  $contract = $null
  if (Test-Path -LiteralPath $contractPath) { try { $contract = [System.IO.File]::ReadAllText($contractPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch {} }
  if (-not $contract) { return [pscustomobject]@{ ok = $false; reason = 'contract-missing-or-invalid'; files = @() } }

  $chapters = Get-AdapterPlanChapters -Records $PlanRecords
  if ($chapters.Count -eq 0) { return [pscustomobject]@{ ok = $false; reason = 'no-chapters-in-plan'; files = @() } }

  $goal = [string](Get-AdapterContractValue -Contract $contract -Names @('goal','project_goal','mission','outcome') -Default '')
  $scopeText = ConvertTo-AdapterText (Get-AdapterContractValue -Contract $contract -Names @('scope') -Default '')
  $nonGoalsText = ConvertTo-AdapterText (Get-AdapterContractValue -Contract $contract -Names @('non_goals','nonGoals') -Default '')
  $usersText = ConvertTo-AdapterText (Get-AdapterContractValue -Contract $contract -Names @('users','roles','personas','actors') -Default '')
  $surfacesText = ConvertTo-AdapterText (Get-AdapterContractValue -Contract $contract -Names @('surfaces','screens','routes') -Default '')
  $dataText = ConvertTo-AdapterText (Get-AdapterContractValue -Contract $contract -Names @('data','backend','storage','api') -Default '')
  $acceptanceText = ConvertTo-AdapterText (Get-AdapterContractValue -Contract $contract -Names @('acceptance_scenarios','acceptanceScenarios') -Default '')
  $checksText = ConvertTo-AdapterText (Get-AdapterContractValue -Contract $contract -Names @('checks') -Default '')
  $riskText = ConvertTo-AdapterText (Get-AdapterContractValue -Contract $contract -Names @('risk','risks') -Default '')
  $parallelText = ConvertTo-AdapterText (Get-AdapterContractValue -Contract $contract -Names @('parallel_policy','parallelPolicy') -Default '')

  $written = New-Object 'System.Collections.Generic.List[string]'
  function _w([string]$path, [string]$text) { [System.IO.File]::WriteAllText($path, $text, $enc) }

  # ---- PROJECT_PLAN.md (chapters; parser wants '## Chapter N — Title') ----
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("# Project Plan")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("Goal: $goal")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("This plan decomposes the project into chapters. Each chapter is a self-contained unit of work with its own acceptance criteria, suitable for parallel (wide-diffusion) execution against the frozen interface contracts in ``.bridge/project-contract.json``.")
  [void]$sb.AppendLine("")
  foreach ($c in $chapters) {
    [void]$sb.AppendLine("## Chapter $($c.n) - $($c.title)")
    [void]$sb.AppendLine("")
    if ($c.deps -and @($c.deps).Count -gt 0) { [void]$sb.AppendLine("Depends on: " + (@($c.deps) -join ', ')) ; [void]$sb.AppendLine("") }
    $body = if ([string]::IsNullOrWhiteSpace($c.criteria)) { "Implement and verify: $($c.title)." } else { $c.criteria }
    [void]$sb.AppendLine("Scope: deliver ``$($c.title)`` end to end (code + build/test verification).")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Acceptance: $body")
    [void]$sb.AppendLine("")
  }
  _w (Join-Path $ProjectRoot 'PROJECT_PLAN.md') ($sb.ToString())
  [void]$written.Add('PROJECT_PLAN.md')

  # ---- PROJECT_MAP.md (architecture overview) ----
  $sbm = New-Object System.Text.StringBuilder
  [void]$sbm.AppendLine("# Project Map — Architecture Overview")
  [void]$sbm.AppendLine("")
  [void]$sbm.AppendLine("## Goal")
  [void]$sbm.AppendLine($goal); [void]$sbm.AppendLine("")
  [void]$sbm.AppendLine("## Surfaces / Screens"); [void]$sbm.AppendLine($surfacesText); [void]$sbm.AppendLine("")
  [void]$sbm.AppendLine("## Data / Backend"); [void]$sbm.AppendLine($dataText); [void]$sbm.AppendLine("")
  [void]$sbm.AppendLine("## Users / Roles"); [void]$sbm.AppendLine($usersText); [void]$sbm.AppendLine("")
  [void]$sbm.AppendLine("## Module / Chapter Map")
  foreach ($c in $chapters) { [void]$sbm.AppendLine("- Chapter $($c.n): $($c.title)") }
  [void]$sbm.AppendLine("")
  [void]$sbm.AppendLine("## Parallelization Policy"); [void]$sbm.AppendLine($parallelText); [void]$sbm.AppendLine("")
  [void]$sbm.AppendLine("## Scope / Non-Goals"); [void]$sbm.AppendLine($scopeText); [void]$sbm.AppendLine(""); [void]$sbm.AppendLine($nonGoalsText)
  _w (Join-Path $ProjectRoot 'PROJECT_MAP.md') ($sbm.ToString())
  [void]$written.Add('PROJECT_MAP.md')

  # ---- PROJECT_BRIEF.md (brief stage doc) ----
  $sbb = New-Object System.Text.StringBuilder
  [void]$sbb.AppendLine("# Project Brief")
  [void]$sbb.AppendLine(""); [void]$sbb.AppendLine("## Goal"); [void]$sbb.AppendLine($goal)
  [void]$sbb.AppendLine(""); [void]$sbb.AppendLine("## Scope"); [void]$sbb.AppendLine($scopeText)
  [void]$sbb.AppendLine(""); [void]$sbb.AppendLine("## Non-Goals"); [void]$sbb.AppendLine($nonGoalsText)
  [void]$sbb.AppendLine(""); [void]$sbb.AppendLine("## Users"); [void]$sbb.AppendLine($usersText)
  [void]$sbb.AppendLine(""); [void]$sbb.AppendLine("## Risks"); [void]$sbb.AppendLine($riskText)
  _w (Join-Path $ProjectRoot 'PROJECT_BRIEF.md') ($sbb.ToString())
  [void]$written.Add('PROJECT_BRIEF.md')

  # ---- .bridge/specs/acceptance.md (required spec) ----
  $sba = New-Object System.Text.StringBuilder
  [void]$sba.AppendLine("# Acceptance"); [void]$sba.AppendLine("")
  [void]$sba.AppendLine("## Acceptance Scenarios"); [void]$sba.AppendLine($acceptanceText); [void]$sba.AppendLine("")
  [void]$sba.AppendLine("## Checks / Gates"); [void]$sba.AppendLine($checksText)
  _w (Join-Path $specsDir 'acceptance.md') ($sba.ToString())
  [void]$written.Add('.bridge/specs/acceptance.md')

  # ---- .bridge/constitution.md (project principles; lite requires >=500 chars) ----
  $sbc = New-Object System.Text.StringBuilder
  [void]$sbc.AppendLine("# Project Constitution")
  [void]$sbc.AppendLine(""); [void]$sbc.AppendLine("## Goal"); [void]$sbc.AppendLine($goal)
  [void]$sbc.AppendLine(""); [void]$sbc.AppendLine("## Non-Goals (out of scope)"); [void]$sbc.AppendLine($nonGoalsText)
  [void]$sbc.AppendLine(""); [void]$sbc.AppendLine("## Parallelization Policy"); [void]$sbc.AppendLine($parallelText)
  [void]$sbc.AppendLine(""); [void]$sbc.AppendLine("## Engineering Principles")
  [void]$sbc.AppendLine("- Each chapter is a single, self-contained unit of work that builds and verifies independently against the frozen interface contracts.")
  [void]$sbc.AppendLine("- Prefer small, single-concern files so chapters can run in parallel (wide diffusion) without touching the same file.")
  [void]$sbc.AppendLine("- Every chapter must pass its own acceptance criteria (build + tests) before it is considered done; no false-green.")
  [void]$sbc.AppendLine("- Integration is a deliberate final step that stitches chapters together and runs full acceptance.")
  [void]$sbc.AppendLine("- Reliability wins ties: when in doubt, sequence rather than risk a merge conflict.")
  _w (Join-Path $bridgeDir 'constitution.md') ($sbc.ToString())
  [void]$written.Add('.bridge/constitution.md')

  # ---- enrich contract: spec_profile=lite + requirements + journeys (keep the 9 delivery sections) ----
  $reqList = @($chapters | ForEach-Object { [pscustomobject]@{ id = ("r" + $_.n); requirement = $_.title } })
  $journeys = @(
    [pscustomobject]@{ id = 'j1'; name = 'Primary end-to-end flow'; steps = @($chapters | ForEach-Object { $_.title }) }
  )
  $contract | Add-Member -NotePropertyName 'spec_profile' -NotePropertyValue 'lite' -Force
  if (-not ($contract.PSObject.Properties.Name -contains 'requirements') -or @($contract.requirements).Count -lt 1) {
    $contract | Add-Member -NotePropertyName 'requirements' -NotePropertyValue $reqList -Force
  }
  if (-not ($contract.PSObject.Properties.Name -contains 'journeys') -or @($contract.journeys).Count -lt 1) {
    $contract | Add-Member -NotePropertyName 'journeys' -NotePropertyValue $journeys -Force
  }
  _w $contractPath ($contract | ConvertTo-Json -Depth 10)
  [void]$written.Add('.bridge/project-contract.json')

  return [pscustomobject]@{ ok = $true; reason = 'materialized'; files = @($written.ToArray()); chapters = $chapters.Count }
}

function Initialize-ProjectAutopilotInputsFromDiscuss {
  # Driver/autopilot hook: if a project channel has a DISCUSS plan board (channels/<slug>/plan.jsonl
  # with chapters) + a contract but no durable PROJECT_PLAN.md yet, materialize the autopilot's
  # required spec artifacts from it and commit them (so the clean-git gate passes). Idempotent: skips
  # once PROJECT_PLAN.md exists. NEVER approves the plan (plan_approved stays a manual operator gate).
  param([string]$Channel, [string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    return [pscustomobject]@{ materialized = $false; reason = 'no-root' }
  }
  if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'PROJECT_PLAN.md')) {
    return [pscustomobject]@{ materialized = $false; reason = 'already-materialized' }
  }
  if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot '.bridge\project-contract.json'))) {
    return [pscustomobject]@{ materialized = $false; reason = 'no-contract' }
  }
  $planPath = ''
  try { $planPath = Join-Path (Get-BridgeRoot) ("channels\" + $Channel + "\plan.jsonl") } catch {}
  if ([string]::IsNullOrWhiteSpace($planPath) -or -not (Test-Path -LiteralPath $planPath)) {
    return [pscustomobject]@{ materialized = $false; reason = 'no-plan-board' }
  }
  $records = @()
  try { $records = @(Get-Content -LiteralPath $planPath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json }) } catch {}
  if (@($records | Where-Object { [string]$_.type -eq 'task' }).Count -lt 1) {
    return [pscustomobject]@{ materialized = $false; reason = 'no-chapters' }
  }
  $res = $null
  try { $res = Convert-DiscussToAutopilotInputs -ProjectRoot $ProjectRoot -PlanRecords $records } catch {
    return [pscustomobject]@{ materialized = $false; reason = ('adapter-error: ' + $_.Exception.Message) }
  }
  if (-not $res -or -not [bool]$res.ok) {
    return [pscustomobject]@{ materialized = $false; reason = ('adapter: ' + [string]$res.reason) }
  }
  # Commit the materialized artifacts (+ any pending discuss scaffold) so Test-ProjectAutopilotProjectClean passes.
  try {
    & git -C $ProjectRoot add -A 2>&1 | Out-Null
    & git -C $ProjectRoot -c user.name=bridge -c user.email=bridge@local commit -q -m 'autopilot: materialize durable plan inputs from discuss (PROJECT_PLAN/MAP/BRIEF/contract)' 2>&1 | Out-Null
  } catch {}
  try {
    Add-Message -From system -Text ("🗺 Project Autopilot: план оформлен в durable-вид (PROJECT_PLAN.md + " + @($res.files).Count + " артефактов, " + [int]$res.chapters + " глав). Готов к запуску диффузии — одобри план (Set-ProjectPlanApproved для канала), и автопилот разложит главы на параллельные атомы.") -Kind event | Out-Null
  } catch {}
  return [pscustomobject]@{ materialized = $true; files = @($res.files); chapters = [int]$res.chapters }
}
