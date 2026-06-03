# 41-autopilot-contract.ps1 -- Project autopilot binding, plan signatures, and contract readiness.
# Mechanical split from lib/backlog.ps1; keep loaded through ../backlog.ps1.

function Get-ProjectAutopilotSlug {
  try {
    if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { return [string](Get-EffectiveChannel) }
  } catch {}
  if (-not [string]::IsNullOrWhiteSpace([string]$env:BRIDGE_CHANNEL)) { return [string]$env:BRIDGE_CHANNEL }
  return 'main'
}

function Get-ProjectAutopilotBinding {
  $slug = Get-ProjectAutopilotSlug
  if ([string]::IsNullOrWhiteSpace($slug) -or $slug -eq 'main') { return $null }
  try {
    if (Get-Command Get-ChannelProjectBinding -ErrorAction SilentlyContinue) {
      $b = Get-ChannelProjectBinding -Slug $slug
      if ($b -and [bool]$b.ok -and -not [string]::IsNullOrWhiteSpace([string]$b.project_root)) { return $b }
    }
  } catch {}
  return $null
}

function Get-ProjectAutopilotBacklogPressure {
  $items = @(Get-Backlog)
  $approved = 0; $running = 0; $new = 0; $held = 0; $autopilotOpen = 0
  foreach ($it in $items) {
    $st = [string](Get-BacklogPackObjectValue -Obj $it -Name 'status' -Default '')
    $tags = @()
    try { $tags = @($it.tags | ForEach-Object { [string]$_ }) } catch { $tags = @() }
    if ($st -eq 'approved') { $approved++ }
    elseif ($st -eq 'running') { $running++ }
    elseif ($st -eq 'new') { $new++ }
    elseif ($st -eq 'held') { $held++ }
    if (($st -eq 'approved' -or $st -eq 'running') -and ($tags -contains 'project-autopilot')) { $autopilotOpen++ }
  }
  return [pscustomobject]@{
    approved = $approved
    running = $running
    new = $new
    held = $held
    runnable = ($approved + $running)
    autopilot_open = $autopilotOpen
  }
}

function Test-ProjectAutopilotProjectClean {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { return $false }
  try {
    $git = 'git'
    try { if (Get-Command Get-GitExe -ErrorAction SilentlyContinue) { $git = Get-GitExe } } catch { $git = 'git' }
    $dirty = @(& $git -C $ProjectRoot status --porcelain 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    return ($dirty.Count -eq 0)
  } catch {
    return $false
  }
}

function Get-ProjectAutopilotPlanContractPath {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return '' }
  return (Join-Path (Join-Path $ProjectRoot '.bridge') 'project-contract.json')
}

function Get-ProjectAutopilotPlanningStageDefinitions {
  return @(
    [pscustomobject]@{ id='brief';       path='PROJECT_BRIEF.md';       min_chars=800;  label='project brief' },
    [pscustomobject]@{ id='product';     path='DISCUSS_PRODUCT.md';     min_chars=900;  label='product discussion' },
    [pscustomobject]@{ id='ux';          path='DISCUSS_UX.md';          min_chars=900;  label='UX discussion' },
    [pscustomobject]@{ id='ui';          path='DISCUSS_UI.md';          min_chars=800;  label='UI discussion' },
    [pscustomobject]@{ id='backend';     path='DISCUSS_BACKEND.md';     min_chars=900;  label='backend discussion' },
    [pscustomobject]@{ id='qa';          path='DISCUSS_QA.md';          min_chars=800;  label='QA/acceptance discussion' },
    [pscustomobject]@{ id='integration'; path='DISCUSS_INTEGRATION.md'; min_chars=800;  label='cross-stage integration review' }
  )
}

function Get-ProjectAutopilotPlanSignatureFiles {
  $files = New-Object 'System.Collections.Generic.List[string]'
  foreach ($stage in @(Get-ProjectAutopilotPlanningStageDefinitions)) {
    [void]$files.Add([string]$stage.path)
  }
  foreach ($rel in @('PROJECT_MAP.md','PROJECT_PLAN.md','.bridge\project-contract.json')) {
    [void]$files.Add([string]$rel)
  }
  return @($files.ToArray())
}

function Get-ProjectAutopilotFileText {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } catch { return '' }
}

function Get-ProjectAutopilotSha256 {
  param([string]$Text)
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
  } catch {
    return ''
  }
}

function Get-ProjectAutopilotPlanSignature {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return '' }
  $parts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($rel in @(Get-ProjectAutopilotPlanSignatureFiles)) {
    $path = Join-Path $ProjectRoot $rel
    [void]$parts.Add($rel.Replace('\','/') + "`n" + (Get-ProjectAutopilotFileText -Path $path))
  }
  return (Get-ProjectAutopilotSha256 -Text (($parts.ToArray()) -join "`n---bridge-plan-part---`n"))
}

function Get-ProjectAutopilotGitHead {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) { return '' }
  try {
    $head = (& git -C $ProjectRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { return '' }
    return ([string]$head).Trim()
  } catch {
    return ''
  }
}

function Test-ProjectAutopilotPlanFilesUnchangedSinceGitHead {
  param([string]$ProjectRoot, [string]$GitHead)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or [string]::IsNullOrWhiteSpace($GitHead)) {
    return [pscustomobject]@{ ok=$false; unchanged=$false; reason='missing-input' }
  }
  if (-not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    return [pscustomobject]@{ ok=$false; unchanged=$false; reason='project-root-missing' }
  }
  try {
    $verify = (& git -C $ProjectRoot rev-parse --verify ($GitHead + '^{commit}') 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$verify)) {
      return [pscustomobject]@{ ok=$false; unchanged=$false; reason='approval-git-head-not-found' }
    }
    $files = @(Get-ProjectAutopilotPlanSignatureFiles | ForEach-Object { ([string]$_).Replace('\','/') })
    if ($files.Count -eq 0) {
      return [pscustomobject]@{ ok=$false; unchanged=$false; reason='no-plan-files' }
    }
    $args = @('-C', $ProjectRoot, 'diff', '--quiet', $GitHead, '--') + $files
    & git @args 2>$null
    $exit = [int]$LASTEXITCODE
    if ($exit -eq 0) { return [pscustomobject]@{ ok=$true; unchanged=$true; reason='unchanged' } }
    if ($exit -eq 1) { return [pscustomobject]@{ ok=$true; unchanged=$false; reason='plan-files-changed' } }
    return [pscustomobject]@{ ok=$false; unchanged=$false; reason=('git-diff-exit-' + [string]$exit) }
  } catch {
    return [pscustomobject]@{ ok=$false; unchanged=$false; reason='git-diff-error' }
  }
}

function Get-ProjectAutopilotContractValue {
  param($Obj, [string[]]$Names = @(), $Default = $null)
  if (-not $Obj) { return $Default }
  foreach ($name in @($Names)) {
    try {
      if ($Obj.PSObject.Properties.Name -contains $name) {
        $v = $Obj.PSObject.Properties[$name].Value
        if ($null -ne $v) { return $v }
      }
    } catch {}
  }
  return $Default
}

function Get-ProjectAutopilotContractCount {
  param($Obj, [string[]]$Names = @())
  $v = Get-ProjectAutopilotContractValue -Obj $Obj -Names $Names -Default $null
  if ($null -eq $v) { return 0 }
  try {
    if ($v -is [string]) {
      if ([string]::IsNullOrWhiteSpace([string]$v)) { return 0 }
      return 1
    }
    if ($v -is [System.Collections.IDictionary]) { return [int]$v.Count }
    $arr = @($v | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($arr.Count -gt 0) { return [int]$arr.Count }
  } catch {}
  try {
    if ($v.PSObject.Properties.Count -gt 0) { return [int]$v.PSObject.Properties.Count }
  } catch {}
  return 0
}

function Get-ProjectAutopilotContractArray {
  param($Obj, [string[]]$Names = @())
  $v = Get-ProjectAutopilotContractValue -Obj $Obj -Names $Names -Default $null
  if ($null -eq $v) { return @() }
  try {
    if ($v -is [string]) {
      if ([string]::IsNullOrWhiteSpace([string]$v)) { return @() }
      return @([string]$v)
    }
    return @($v | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
  } catch {
    return @()
  }
}

function Get-ProjectAutopilotPlanningStageById {
  param($PlanningFlow)
  $map = @{}
  $stages = @(Get-ProjectAutopilotContractArray -Obj $PlanningFlow -Names @('stages','planning_stages','discussions'))
  foreach ($stage in @($stages)) {
    $id = ([string](Get-ProjectAutopilotContractValue -Obj $stage -Names @('id','stage','name') -Default '')).Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($id)) { $map[$id] = $stage }
  }
  return $map
}

function Test-ProjectPlanContractReady {
  param([string]$ProjectRoot)
  $issues = New-Object 'System.Collections.Generic.List[string]'
  $mapPath = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { '' } else { Join-Path $ProjectRoot 'PROJECT_MAP.md' }
  $planPath = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { '' } else { Join-Path $ProjectRoot 'PROJECT_PLAN.md' }
  $contractPath = Get-ProjectAutopilotPlanContractPath -ProjectRoot $ProjectRoot
  $mapText = Get-ProjectAutopilotFileText -Path $mapPath
  $planText = Get-ProjectAutopilotFileText -Path $planPath
  $contract = $null

  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    [void]$issues.Add('project_root is missing')
  }
  if ($mapText.Length -lt 1500) {
    [void]$issues.Add('PROJECT_MAP.md is missing or too shallow (<1500 chars)')
  }
  if ($planText.Length -lt 2000) {
    [void]$issues.Add('PROJECT_PLAN.md is missing or too shallow (<2000 chars)')
  }

  $stageDocLengths = [ordered]@{}
  foreach ($stageDef in @(Get-ProjectAutopilotPlanningStageDefinitions)) {
    $stagePath = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { '' } else { Join-Path $ProjectRoot ([string]$stageDef.path) }
    $stageText = Get-ProjectAutopilotFileText -Path $stagePath
    $stageDocLengths[[string]$stageDef.id] = [int]$stageText.Length
    if ($stageText.Length -lt [int]$stageDef.min_chars) {
      [void]$issues.Add(([string]$stageDef.path + ' is missing or too shallow (<' + [string]$stageDef.min_chars + ' chars)'))
    }
  }

  if ([string]::IsNullOrWhiteSpace($contractPath) -or -not (Test-Path -LiteralPath $contractPath -PathType Leaf)) {
    [void]$issues.Add('.bridge/project-contract.json is missing')
  } else {
    try {
      $contract = [System.IO.File]::ReadAllText($contractPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
      [void]$issues.Add('.bridge/project-contract.json is not valid JSON')
    }
  }

  $goalText = ''
  $reqCount = 0
  $surfaceCount = 0
  $journeyCount = 0
  $acceptanceCount = 0
  $interfaceCount = 0
  $planningStageCount = 0
  if ($contract) {
    $goalText = [string](Get-ProjectAutopilotContractValue -Obj $contract -Names @('project_goal','goal','mission','outcome') -Default '')
    $reqCount = [int](Get-ProjectAutopilotContractCount -Obj $contract -Names @('requirements','capabilities','features','functional_requirements'))
    $surfaceCount = [int](Get-ProjectAutopilotContractCount -Obj $contract -Names @('screens','routes','views','surfaces','pages','endpoints','modules'))
    $journeyCount = [int](Get-ProjectAutopilotContractCount -Obj $contract -Names @('user_journeys','journeys','flows','workflows','scenarios'))
    $acceptanceCount = [int](Get-ProjectAutopilotContractCount -Obj $contract -Names @('acceptance_scenarios','acceptance','done_criteria','checks','quality_gates'))
    $interfaceCount = [int](Get-ProjectAutopilotContractCount -Obj $contract -Names @('ux_contract','ux','interface_contract','experience_principles','interaction_model'))
    $planningFlow = Get-ProjectAutopilotContractValue -Obj $contract -Names @('planning_flow','planningFlow','discussion_flow') -Default $null
    $stageById = Get-ProjectAutopilotPlanningStageById -PlanningFlow $planningFlow
    $planningStageCount = [int]$stageById.Count
    if ($goalText.Trim().Length -lt 40) { [void]$issues.Add('project contract goal is missing or too short') }
    if ($reqCount -lt 3) { [void]$issues.Add('project contract needs at least 3 requirements/capabilities/features') }
    if ($surfaceCount -lt 2) { [void]$issues.Add('project contract needs at least 2 screens/routes/interfaces/modules') }
    if ($journeyCount -lt 2) { [void]$issues.Add('project contract needs at least 2 user journeys/workflows/scenarios') }
    if ($acceptanceCount -lt 3) { [void]$issues.Add('project contract needs at least 3 acceptance scenarios/checks') }
    if ($interfaceCount -lt 1) { [void]$issues.Add('project contract needs ux_contract or interface_contract') }
    if (-not $planningFlow) {
      [void]$issues.Add('project contract needs planning_flow with staged discussions')
    } else {
      foreach ($stageDef in @(Get-ProjectAutopilotPlanningStageDefinitions)) {
        $sid = [string]$stageDef.id
        if (-not $stageById.ContainsKey($sid)) {
          [void]$issues.Add('planning_flow missing stage: ' + $sid)
          continue
        }
        $stage = $stageById[$sid]
        $status = ([string](Get-ProjectAutopilotContractValue -Obj $stage -Names @('status','state') -Default '')).Trim().ToLowerInvariant()
        $summary = ([string](Get-ProjectAutopilotContractValue -Obj $stage -Names @('summary','outcome','decision_summary') -Default '')).Trim()
        if ($status -notin @('complete','approved','done')) { [void]$issues.Add('planning_flow stage not complete: ' + $sid) }
        if ($summary.Length -lt 40) { [void]$issues.Add('planning_flow stage summary too short: ' + $sid) }
      }
      $integration = $null
      try { if ($stageById.ContainsKey('integration')) { $integration = $stageById['integration'] } } catch {}
      $integrationDeps = @(Get-ProjectAutopilotContractArray -Obj $integration -Names @('depends_on','dependsOn','validated_stages'))
      if ($integrationDeps.Count -lt 5) { [void]$issues.Add('planning_flow integration stage must depend on/validate prior stages') }
    }
  }

  return [pscustomobject]@{
    ready = ($issues.Count -eq 0)
    issues = @($issues.ToArray())
    signature = (Get-ProjectAutopilotPlanSignature -ProjectRoot $ProjectRoot)
    map_path = $mapPath
    plan_path = $planPath
    contract_path = $contractPath
    counts = [pscustomobject]@{
      requirements = $reqCount
      surfaces = $surfaceCount
      journeys = $journeyCount
      acceptance = $acceptanceCount
      interface_contract = $interfaceCount
      planning_stages = $planningStageCount
      stage_doc_lengths = [pscustomobject]$stageDocLengths
    }
  }
}
