[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('security-model','functional-model','reliability-model','architecture-model','dependency-model','runtime-incident-model','latency-speed-model','cost-burn-model')]
  [string]$Role,
  [string]$Model = '',
  [string]$BridgePath = '',
  [string]$ProjectRoot = '',
  [string]$OutputFile = '',
  [int]$TimeoutSec = 120,
  [switch]$RunLLM,
  [switch]$NoLLM
)

$startTime = [datetime]::UtcNow
$ErrorActionPreference = 'Continue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Resolve-AgentRoot {
  param([string]$Hint)
  if (-not [string]::IsNullOrWhiteSpace($Hint)) {
    try { return [System.IO.Path]::GetFullPath($Hint) } catch { return $Hint }
  }
  return [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}

function Get-AgentRelativePath {
  param([string]$Root, [string]$Path)
  try {
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if ($pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $pathFull.Substring($rootFull.Length).TrimStart('\','/')
    }
  } catch {}
  return $Path
}

function Test-AgentExcludedPath {
  param([string]$Root, [string]$FullPath)
  # Deterministic exclusions: generated/runtime/vendor dirs that are not source.
  $excludedSegments = @(
    '.git', 'node_modules', 'worktrees',
    'tmp', 'runtime',
    [System.IO.Path]::Combine('control', 'curator-launchers'),
    [System.IO.Path]::Combine('audit', 'tmp'),
    'memory', 'channels'
  )
  $rel = ''
  try {
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $pathFull = [System.IO.Path]::GetFullPath($FullPath)
    if ($pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      $rel = $pathFull.Substring($rootFull.Length).TrimStart('\','/')
    } else {
      $rel = $FullPath
    }
  } catch { $rel = $FullPath }
  foreach ($seg in $excludedSegments) {
    $segNorm = $seg.Replace('/', '\')
    if ($rel -eq $segNorm) { return $true }
    if ($rel.StartsWith($segNorm + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($rel.StartsWith($segNorm + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Get-AgentRiskRankedFiles {
  param([string]$Root, [int]$MaxFiles = 30)
  # Priority 1: high-risk core source files (server/driver/supervisor/watchdog/lib/tools/config)
  $priority1Globs = @('server.ps1','driver.ps1','supervisor.ps1','watchdog.ps1')
  $priority1 = New-Object 'System.Collections.Generic.List[string]'
  foreach ($g in $priority1Globs) {
    $p = Join-Path $Root $g
    if ((Test-Path -LiteralPath $p -PathType Leaf) -and -not (Test-AgentExcludedPath -Root $Root -FullPath $p)) {
      [void]$priority1.Add($p)
    }
  }
  foreach ($libF in @(Get-ChildItem -LiteralPath (Join-Path $Root 'lib') -Filter *.ps1 -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    if (-not (Test-AgentExcludedPath -Root $Root -FullPath $libF.FullName)) { [void]$priority1.Add($libF.FullName) }
  }
  foreach ($toolF in @(Get-ChildItem -LiteralPath (Join-Path $Root 'tools') -Filter *.ps1 -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
    if (-not (Test-AgentExcludedPath -Root $Root -FullPath $toolF.FullName)) { [void]$priority1.Add($toolF.FullName) }
  }
  $cfgPath = Join-Path $Root 'config.json'
  if (Test-Path -LiteralPath $cfgPath -PathType Leaf) { [void]$priority1.Add($cfgPath) }

  # Priority 2: recently git-changed files (last 20 commits, unique, not already included)
  $priority2 = New-Object 'System.Collections.Generic.List[string]'
  try {
    $gitFiles = @(& git -C $Root log --name-only --pretty=format: -20 2>$null | Where-Object { $_ -match '\.(ps1|json|html|js)$' } | Select-Object -Unique -First 20)
    foreach ($gf in $gitFiles) {
      $full = Join-Path $Root $gf
      if ((Test-Path -LiteralPath $full -PathType Leaf) -and
          -not (Test-AgentExcludedPath -Root $Root -FullPath $full) -and
          -not ($priority1 -contains $full)) {
        [void]$priority2.Add($full)
      }
    }
  } catch {}

  # Priority 3: remaining source files (capped)
  $priority3 = New-Object 'System.Collections.Generic.List[string]'
  $allSrc = @(Get-ChildItem -LiteralPath $Root -Recurse -Include *.ps1,*.json,*.html,*.js -File -ErrorAction SilentlyContinue | Sort-Object FullName)
  foreach ($f in $allSrc) {
    if (-not (Test-AgentExcludedPath -Root $Root -FullPath $f.FullName) -and
        -not ($priority1 -contains $f.FullName) -and
        -not ($priority2 -contains $f.FullName)) {
      [void]$priority3.Add($f.FullName)
    }
  }

  $result = New-Object 'System.Collections.Generic.List[string]'
  foreach ($f in $priority1) { if ($result.Count -lt $MaxFiles) { [void]$result.Add($f) } }
  foreach ($f in $priority2) { if ($result.Count -lt $MaxFiles) { [void]$result.Add($f) } }
  foreach ($f in $priority3) { if ($result.Count -lt $MaxFiles) { [void]$result.Add($f) } }

  return $result.ToArray()
}

function Get-AgentFileContentCapped {
  param([string]$Path, [int]$Cap = 20000)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try {
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ($text.Length -gt $Cap) { return $text.Substring(0, $Cap) + "`n...[truncated at $Cap chars]" }
    return $text
  } catch {
    return ''
  }
}

function Test-AgentContentTruncated {
  param([string]$Content)
  return ([bool]($Content -match '\.\.\.\[truncated'))
}

function Get-AgentConfidence {
  param([string]$RoleName)
  if ($RoleName -eq 'security-model') { return 0.85 }
  if ($RoleName -eq 'functional-model') { return 0.80 }
  if ($RoleName -eq 'reliability-model') { return 0.75 }
  if ($RoleName -eq 'runtime-incident-model') { return 0.80 }
  if ($RoleName -eq 'architecture-model') { return 0.70 }
  if ($RoleName -eq 'dependency-model') { return 0.65 }
  if ($RoleName -eq 'latency-speed-model') { return 0.80 }
  if ($RoleName -eq 'cost-burn-model') { return 0.75 }
  return 0.50
}

function Get-DefaultAgentModel {
  param($Cfg, [string]$RoleName)
  try {
    if ($Cfg -and $Cfg.audit) {
      $key = ($RoleName -replace '-model$','') + 'Model'
      if ($Cfg.audit.PSObject.Properties.Name -contains $key) { return [string]$Cfg.audit.$key }
      if ($Cfg.audit.PSObject.Properties.Name -contains 'agentModel') { return [string]$Cfg.audit.agentModel }
    }
    if ($Cfg -and $Cfg.llm -and $Cfg.llm.gate) { return [string]$Cfg.llm.gate }
  } catch {}
  return 'deepseek-v4-flash'
}

function Get-DeepAuditConfig {
  param([string]$Root)
  $cfgPath = Join-Path $Root 'config.json'
  if (-not (Test-Path -LiteralPath $cfgPath -PathType Leaf)) { return $null }
  try { return (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Get-AgentPs1Inventory {
  param([string]$Root)
  $items = @()
  try {
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter *.ps1 -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
      if (Test-AgentExcludedPath -Root $Root -FullPath $f.FullName) { continue }
      $lineCount = 0
      try { $lineCount = @([System.IO.File]::ReadAllLines($f.FullName)).Count } catch {}
      $items += [pscustomobject]@{
        path = (Get-AgentRelativePath -Root $Root -Path $f.FullName)
        lines = $lineCount
      }
    }
  } catch {}
  return @($items | Sort-Object path)
}

function Get-AgentFunctionInventory {
  param([string]$Root)
  $items = @()
  try {
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter *.ps1 -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
      if (Test-AgentExcludedPath -Root $Root -FullPath $f.FullName) { continue }
      $tokens = $null
      $errors = $null
      $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
      $funcs = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
      foreach ($fn in $funcs) {
        $items += [pscustomobject]@{
          file = (Get-AgentRelativePath -Root $Root -Path $f.FullName)
          name = $fn.Name
          lines = [Math]::Max(1, $fn.Extent.EndLineNumber - $fn.Extent.StartLineNumber + 1)
        }
      }
    }
  } catch {}
  return @($items | Sort-Object -Property @{ Expression = 'lines'; Descending = $true }, file, name)
}

function Extract-AgentJson {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $clean = ($Text -replace '```(?:json)?', '' -replace '```', '').Trim()
  $m = [regex]::Match($clean, '(?s)\[.*\]')
  if (-not $m.Success) { $m = [regex]::Match($clean, '(?s)\{.*\}') }
  if (-not $m.Success) { return $null }
  try { return ($m.Value | ConvertFrom-Json) } catch { return $null }
}

function New-AgentPromptSection {
  param(
    [string]$Header,
    [string]$Content,
    [switch]$BlankAfter
  )

  return [pscustomobject]@{
    header = $Header
    content = $Content
    blank_after = [bool]$BlankAfter
  }
}

function Get-AgentPromptTemplate {
  param([string]$Role)

  $lines = New-Object System.Collections.Generic.List[string]
  [void]$lines.Add('You are one specialist in a multi-agent deep audit. Return strict JSON only.')
  [void]$lines.Add('JSON schema: [{"severity":"critical|warning|info","category":"string","file":"path","line":N,"observation":"specific issue","recommendation":"specific fix"}]')
  [void]$lines.Add('Use [] when there are no concrete findings. Avoid speculative findings.')
  [void]$lines.Add('')

  if ($Role -eq 'security-model') {
    [void]$lines.Add('Role: security audit. Find exploitable command injection, path traversal, auth bypass, hardcoded secrets, and unsafe dynamic execution.')
  } elseif ($Role -eq 'functional-model') {
    [void]$lines.Add('Role: functional audit. Find registry drift, dormant declared features, undocumented implemented features, and missing user-facing scenarios.')
  } elseif ($Role -eq 'reliability-model') {
    [void]$lines.Add('Role: reliability audit. Find timeout bugs, missing cleanup, brittle process supervision, non-atomic writes, and retry loops without bounds.')
  } elseif ($Role -eq 'runtime-incident-model') {
    [void]$lines.Add('Role: runtime-incident model. Your job: analyse the attached incident-bundle and produce structured findings.')
    [void]$lines.Add('Tasks:')
    [void]$lines.Add('1. ATTRIBUTION: for every restart/CB event in incident-bundle, identify the nearest active task (by timestamp delta <= 5 min). If no task is within 5 min, flag as orphan-restart.')
    [void]$lines.Add('2. CB-LOOP: if two or more CB activations appear within any 30-minute window, or if a task appears in restarts with cause=task-survived-3x, flag as cb-loop with the task description and file diffs present.')
    [void]$lines.Add('3. DIFF-CORRELATION: for each CB event that has diff_files populated, list which files changed just before the CB. If diff_files is empty, note "no-diff-captured" as an attribution gap.')
    [void]$lines.Add('4. ATTRIBUTION-GAP: flag any restart where task_id is missing/unknown and no task turn is within 10 minutes.')
    [void]$lines.Add('Severity: critical=cb-loop or >=3 orphan-restarts; warning=single orphan-restart or attribution-gap; info=everything else.')
    [void]$lines.Add('')
  } elseif ($Role -eq 'latency-speed-model') {
    [void]$lines.Add('Role: latency-speed audit. Analyse p95 latency by phase (mode + fast_lane) for status=ok turns.')
    [void]$lines.Add('JSON schema: [{"severity":"critical|warning|info","category":"string","file":"path","line":0,"observation":"specific issue","recommendation":"specific fix"}]')
    [void]$lines.Add('Find ONLY concrete issues:')
    [void]$lines.Add('- slow_phase: any phase where p95_ok_sec > 600s (normal/discuss) or > 120s (fast+fast_lane). warning if p95>300s, critical if p95>900s.')
    [void]$lines.Add('- no_fast_lane: fast_lane turns count=0 while total_ok_turns>50 (feature deployed but never triggered).')
    [void]$lines.Add('- outlier: max_ok_sec > 3*p95_ok_sec for any phase (single outlier skewing distribution).')
    [void]$lines.Add('- high_failure: timeout_pct > 5% overall.')
    [void]$lines.Add('Use [] if no threshold is exceeded. Avoid speculative findings.')
    [void]$lines.Add('')
  } elseif ($Role -eq 'cost-burn-model') {
    [void]$lines.Add('Role: cost-burn audit. Find wasted spend in usage.jsonl: duplicate LLM calls (same purpose+model >=3 times in 5 min) and failed-token-burn (prompt cost paid, zero completion output on text-generation calls).')
    [void]$lines.Add('JSON schema: [{"severity":"critical|warning|info","category":"string","file":"path","line":0,"observation":"specific issue","recommendation":"specific fix"}]')
    [void]$lines.Add('Find ONLY concrete issues:')
    [void]$lines.Add('- duplicate_burst: same purpose+model called >=3 times within any 5-min window (audit/retry storm).')
    [void]$lines.Add('- failed_burn: text-gen calls (purpose not embed/codemem/embedding) where completion_tokens=0 AND cost_usd>0 AND count>2.')
    [void]$lines.Add('- expensive_purpose: single purpose with total cost_usd > $0.50 in window without proportional value.')
    [void]$lines.Add('Use [] if no concrete issue. Avoid speculative findings.')
    [void]$lines.Add('')
  } elseif ($Role -eq 'architecture-model') {
    [void]$lines.Add('Role: architecture audit. Find dead functions/unused exports, architecture antipatterns, layer violations such as driver->lib misuse or server->driver without API, and very long functions over 150 lines that need decomposition.')
    [void]$lines.Add('Context: all .ps1 files with line counts and the top 5 longest functions.')
  } elseif ($Role -eq 'dependency-model') {
    [void]$lines.Add('Role: dependency/config audit. Find orphaned config keys, duplicate config keys, missing required config keys, and TRULY orphaned tools.')
    [void]$lines.Add('CRITICAL orphaned-tool rule: a tool is orphaned ONLY if its filename appears NOWHERE else in the codebase. Tools are launched many ways -- Start-Process, the & call operator, a -File argument, dynamic path building, Task Scheduler -- NOT just dot-source/import. Each tool below is annotated with how many times its filename is referenced across driver/server/lib/tools (excluding itself). references>=1 => NOT orphaned: DO NOT flag it. Only consider references=0, and even then be cautious. NEVER flag audit*/deep-audit*/audit-runner -- that is the audit engine currently running you.')
  }

  return $lines.ToArray()
}

function Get-AgentPromptFileSections {
  param(
    [string]$Root,
    [string[]]$RelativePaths,
    [int]$Cap,
    $Coverage,
    [System.Collections.Generic.List[string]]$TruncatedSections = $null
  )

  $sections = New-Object System.Collections.Generic.List[object]
  foreach ($p in $RelativePaths) {
    $full = Join-Path $Root $p
    if (Test-Path -LiteralPath $full -PathType Leaf) {
      $Coverage.Add($p)
      $content = Get-AgentFileContentCapped -Path $full -Cap $Cap
      if ($null -ne $TruncatedSections -and (Test-AgentContentTruncated -Content $content)) {
        [void]$TruncatedSections.Add($p)
      }
      [void]$sections.Add((New-AgentPromptSection -Header "=== $p ===" -Content $content))
    }
  }
  return $sections.ToArray()
}

function Get-AgentRecentFileLinesSnippet {
  param([string]$Path, [int]$MaxLines)

  $snippet = ''
  try {
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
      $lines = [System.IO.File]::ReadAllLines($Path)
      $recent = if ($lines.Count -gt $MaxLines) { $lines[($lines.Count-$MaxLines)..($lines.Count-1)] } else { $lines }
      $snippet = ($recent -join "`n")
    }
  } catch {}
  return $snippet
}

function Get-AgentCircuitBreakerSnippet {
  param(
    [string]$RuntimeRoot,
    [int]$MaxItems = 5,
    [int]$MaxDiffFiles = 10
  )

  $cbSnippet = ''
  try {
    if (Test-Path -LiteralPath $RuntimeRoot -PathType Container) {
      $cbItems = @(Get-ChildItem -LiteralPath $RuntimeRoot -Filter 'circuit-breaker.*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First $MaxItems)
      $cbLines = New-Object System.Collections.Generic.List[string]
      foreach ($item in $cbItems) {
        $diffPath = $null
        if ($item.PSIsContainer) { $diffPath = Join-Path $item.FullName 'git-diff.patch' }
        else { $diffPath = $item.FullName }
        $diffFiles = @()
        if ($diffPath -and (Test-Path -LiteralPath $diffPath -PathType Leaf)) {
          foreach ($line in [System.IO.File]::ReadAllLines($diffPath)) {
            if ($line -match '^diff --git a/.+ b/(.+)$') { $diffFiles += $Matches[1] }
            if ($diffFiles.Count -ge $MaxDiffFiles) { break }
          }
        }
        [void]$cbLines.Add(("{0} | diff_files=[{1}]" -f $item.Name, ($diffFiles -join ',')))
      }
      $cbSnippet = ($cbLines -join "`n")
    }
  } catch {}
  return $cbSnippet
}

function Get-AgentLatencyPhaseStatsText {
  param([string]$TurnsPath)

  $phaseMap = @{}
  if (Test-Path -LiteralPath $TurnsPath -PathType Leaf) {
    try {
      $allTurnLines = [System.IO.File]::ReadAllLines($TurnsPath)
      $subsetTurns = if ($allTurnLines.Count -gt 500) { $allTurnLines[($allTurnLines.Count-500)..($allTurnLines.Count-1)] } else { $allTurnLines }
      foreach ($tl in $subsetTurns) {
        if ([string]::IsNullOrWhiteSpace($tl)) { continue }
        try {
          $tr = $tl | ConvertFrom-Json
          $tStatus = [string]$tr.status
          if ($tStatus -ne 'ok') { continue }
          $tMode = if ($tr.PSObject.Properties['mode'] -and $tr.mode) { [string]$tr.mode } else { 'unknown' }
          $tFast = $false
          if ($tr.PSObject.Properties['fast_lane'] -and $tr.fast_lane -eq $true) { $tFast = $true }
          $phase = if ($tFast) { "$tMode+fast_lane" } else { $tMode }
          $tSec = if ($tr.PSObject.Properties['sec']) { [double]$tr.sec } else { 0.0 }
          if (-not $phaseMap.ContainsKey($phase)) { $phaseMap[$phase] = New-Object 'System.Collections.Generic.List[double]' }
          [void]$phaseMap[$phase].Add($tSec)
        } catch {}
      }
    } catch {}
  }

  $phaseLines = New-Object System.Text.StringBuilder
  foreach ($phase in ($phaseMap.Keys | Sort-Object)) {
    $pSecs = [double[]]$phaseMap[$phase].ToArray()
    [Array]::Sort($pSecs)
    $pN = $pSecs.Count
    if ($pN -eq 0) { continue }
    $p95idx = [Math]::Max(0, [Math]::Ceiling($pN * 0.95) - 1)
    if ($p95idx -ge $pN) { $p95idx = $pN - 1 }
    $pP95 = [Math]::Round($pSecs[$p95idx], 1)
    $pAvg = [Math]::Round(($pSecs | Measure-Object -Average).Average, 1)
    $pMax = [Math]::Round($pSecs[$pN-1], 1)
    [void]$phaseLines.AppendLine("phase=$phase count=$pN avg=${pAvg}s p95=${pP95}s max=${pMax}s")
  }

  return $phaseLines.ToString().Trim()
}

function Get-AgentCostBurnContextSummary {
  param([string]$UsageRawPath)

  $purposeModelTs = @{}
  $failedBurnCount = 0
  $failedBurnCostUsd = 0.0
  $failedBurnExamples = New-Object 'System.Collections.Generic.List[string]'
  if (Test-Path -LiteralPath $UsageRawPath -PathType Leaf) {
    try {
      $allULines = [System.IO.File]::ReadAllLines($UsageRawPath)
      $subsetU = if ($allULines.Count -gt 1000) { $allULines[($allULines.Count-1000)..($allULines.Count-1)] } else { $allULines }
      foreach ($ul in $subsetU) {
        if ([string]::IsNullOrWhiteSpace($ul)) { continue }
        try {
          $ur = $ul | ConvertFrom-Json
          $uPurpose = [string]$ur.purpose
          $uModel = [string]$ur.model
          $uCost = [double]$ur.cost_usd
          $uCt = [long]$ur.completion_tokens
          $uPt = [long]$ur.prompt_tokens
          $uTs = $null
          try { $uTs = [datetime]::Parse([string]$ur.ts) } catch {}
          if (-not [string]::IsNullOrWhiteSpace($uPurpose) -and $uTs -ne $null) {
            $key = "$uPurpose|$uModel"
            if (-not $purposeModelTs.ContainsKey($key)) { $purposeModelTs[$key] = New-Object 'System.Collections.Generic.List[datetime]' }
            [void]$purposeModelTs[$key].Add($uTs)
          }
          $isEmbed = ($uPurpose -match '(?i)(embed|codemem|embedding)')
          if (-not $isEmbed -and $uCt -eq 0 -and $uCost -gt 0) {
            $failedBurnCount++
            $failedBurnCostUsd += $uCost
            if ($failedBurnExamples.Count -lt 5) { [void]$failedBurnExamples.Add("purpose=$uPurpose model=$uModel cost=$uCost prompt_tokens=$uPt") }
          }
        } catch {}
      }
    } catch {}
  }

  $dupBursts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($key in ($purposeModelTs.Keys | Sort-Object)) {
    $times = [datetime[]]($purposeModelTs[$key].ToArray() | Sort-Object)
    for ($bi = 0; $bi -lt ($times.Count - 2); $bi++) {
      $winEnd = $times[$bi].AddMinutes(5)
      $inWin = @($times[$bi..$times.Count] | Where-Object { $_ -le $winEnd })
      if ($inWin.Count -ge 3) {
        [void]$dupBursts.Add("$key : $($inWin.Count) calls within 5 min starting $($times[$bi].ToString('o'))")
        break
      }
    }
  }

  return [pscustomobject]@{
    failed_burn_count = $failedBurnCount
    failed_burn_cost_usd = $failedBurnCostUsd
    failed_burn_examples = $failedBurnExamples.ToArray()
    duplicate_bursts = $dupBursts.ToArray()
  }
}

function Get-AgentPromptContext {
  param([string]$Role, [string]$BridgeRoot, [string]$ProjRoot)

  $coverage = New-Object System.Collections.Generic.List[string]
  $sections = New-Object System.Collections.Generic.List[object]
  $truncatedSections = New-Object System.Collections.Generic.List[string]

  if ($Role -eq 'security-model') {
    $rankedFiles = @(Get-AgentRiskRankedFiles -Root $ProjRoot -MaxFiles 30)
    foreach ($fullPath in $rankedFiles) {
      $rel = Get-AgentRelativePath -Root $ProjRoot -Path $fullPath
      $coverage.Add($rel)
      $content = Get-AgentFileContentCapped -Path $fullPath -Cap 5000
      if (Test-AgentContentTruncated -Content $content) { [void]$truncatedSections.Add($rel) }
      [void]$sections.Add((New-AgentPromptSection -Header "=== $rel ===" -Content $content))
    }
  } elseif ($Role -eq 'functional-model') {
    foreach ($section in @(Get-AgentPromptFileSections -Root $BridgeRoot -RelativePaths @('features\registry.json','features\state.json','audit\audit.log','turns.jsonl') -Cap 20000 -Coverage $coverage -TruncatedSections $truncatedSections)) {
      [void]$sections.Add($section)
    }
  } elseif ($Role -eq 'reliability-model') {
    foreach ($section in @(Get-AgentPromptFileSections -Root $ProjRoot -RelativePaths @('driver.ps1','server.ps1','supervisor.ps1','watchdog.ps1','lib\jobs.ps1','lib\circuit-breaker.ps1') -Cap 10000 -Coverage $coverage -TruncatedSections $truncatedSections)) {
      [void]$sections.Add($section)
    }
  } elseif ($Role -eq 'runtime-incident-model') {
    $runtimeRoot = Join-Path $env:USERPROFILE '.bridge-runtime'
    $coverage.Add('restarts.jsonl')
    $coverage.Add('turns.jsonl')
    $coverage.Add('state.json')
    $restartsSnippet = Get-AgentRecentFileLinesSnippet -Path (Join-Path $runtimeRoot 'restarts.jsonl') -MaxLines 30
    [void]$sections.Add((New-AgentPromptSection -Header '=== incident-bundle/restarts (last 30) ===' -Content $(if ([string]::IsNullOrWhiteSpace($restartsSnippet)) { '(empty)' } else { $restartsSnippet }) -BlankAfter))
    $turnsSnippet = Get-AgentRecentFileLinesSnippet -Path (Join-Path $BridgeRoot 'turns.jsonl') -MaxLines 20
    [void]$sections.Add((New-AgentPromptSection -Header '=== incident-bundle/turns (last 20) ===' -Content $(if ([string]::IsNullOrWhiteSpace($turnsSnippet)) { '(empty)' } else { $turnsSnippet }) -BlankAfter))
    $statePath = Join-Path $BridgeRoot 'state.json'
    $stateSnippet = ''
    try {
      if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $stateSnippet = Get-AgentFileContentCapped -Path $statePath -Cap 2000
        if (Test-AgentContentTruncated -Content $stateSnippet) { [void]$truncatedSections.Add('state.json') }
      }
    } catch {}
    [void]$sections.Add((New-AgentPromptSection -Header '=== incident-bundle/state (current task) ===' -Content $(if ([string]::IsNullOrWhiteSpace($stateSnippet)) { '(empty)' } else { $stateSnippet }) -BlankAfter))
    $cbSnippet = Get-AgentCircuitBreakerSnippet -RuntimeRoot $runtimeRoot -MaxItems 5 -MaxDiffFiles 10
    [void]$sections.Add((New-AgentPromptSection -Header '=== incident-bundle/circuit-breaker (last 5) ===' -Content $(if ([string]::IsNullOrWhiteSpace($cbSnippet)) { '(empty)' } else { $cbSnippet }) -BlankAfter))
  } elseif ($Role -eq 'latency-speed-model') {
    $coverage.Add('turns.jsonl')
    $coverage.Add('audit/signals/speed.json')
    $signalsPath = Join-Path $BridgeRoot 'audit\signals\speed.json'
    if (Test-Path -LiteralPath $signalsPath -PathType Leaf) {
      try {
        $sigJson = [System.IO.File]::ReadAllText($signalsPath, [System.Text.Encoding]::UTF8)
        $sigCapped = if ($sigJson.Length -gt 4000) { $sigJson.Substring(0,4000) + '...[truncated]' } else { $sigJson }
        if (Test-AgentContentTruncated -Content $sigCapped) { [void]$truncatedSections.Add('audit/signals/speed.json') }
        [void]$sections.Add((New-AgentPromptSection -Header '=== audit/signals/speed.json (overall stats) ===' -Content $sigCapped -BlankAfter))
      } catch {}
    }
    $phaseStatsTxt = Get-AgentLatencyPhaseStatsText -TurnsPath (Join-Path $BridgeRoot 'turns.jsonl')
    [void]$sections.Add((New-AgentPromptSection -Header '=== per-phase latency (status=ok, last 500 turns) ===' -Content $(if ([string]::IsNullOrWhiteSpace($phaseStatsTxt)) { '(no status=ok turns found)' } else { $phaseStatsTxt }) -BlankAfter))
  } elseif ($Role -eq 'cost-burn-model') {
    $coverage.Add('usage.jsonl')
    $coverage.Add('audit/signals/cost.json')
    $costSignalPath = Join-Path $BridgeRoot 'audit\signals\cost.json'
    if (Test-Path -LiteralPath $costSignalPath -PathType Leaf) {
      try {
        $cJson = [System.IO.File]::ReadAllText($costSignalPath, [System.Text.Encoding]::UTF8)
        $cCapped = if ($cJson.Length -gt 4000) { $cJson.Substring(0,4000) + '...[truncated]' } else { $cJson }
        if (Test-AgentContentTruncated -Content $cCapped) { [void]$truncatedSections.Add('audit/signals/cost.json') }
        [void]$sections.Add((New-AgentPromptSection -Header '=== audit/signals/cost.json (pre-computed cost breakdown) ===' -Content $cCapped -BlankAfter))
      } catch {}
    }
    $costContext = Get-AgentCostBurnContextSummary -UsageRawPath (Join-Path $BridgeRoot 'usage.jsonl')
    $failedBurnLines = New-Object System.Collections.Generic.List[string]
    [void]$failedBurnLines.Add("count=$($costContext.failed_burn_count) total_cost_usd=$([Math]::Round([double]$costContext.failed_burn_cost_usd,6))")
    if ($costContext.failed_burn_examples.Count -gt 0) { [void]$failedBurnLines.Add('examples: ' + ($costContext.failed_burn_examples -join ' | ')) }
    [void]$sections.Add((New-AgentPromptSection -Header '=== failed-token-burn (text-gen: completion_tokens=0, cost_usd>0, last 1000 rows) ===' -Content ($failedBurnLines -join "`n") -BlankAfter))
    $dupBurstText = if ($costContext.duplicate_bursts.Count -eq 0) { '(none detected)' } else { $costContext.duplicate_bursts -join "`n" }
    [void]$sections.Add((New-AgentPromptSection -Header '=== duplicate-burst (same purpose+model >=3 calls within 5 min) ===' -Content $dupBurstText -BlankAfter))
  } elseif ($Role -eq 'architecture-model') {
    $ps1 = @(Get-AgentPs1Inventory -Root $ProjRoot)
    $funcs = @(Get-AgentFunctionInventory -Root $ProjRoot | Select-Object -First 5)
    foreach ($item in $ps1) { $coverage.Add($item.path) }
    [void]$sections.Add((New-AgentPromptSection -Header '=== PS1 LINE COUNTS ===' -Content ($ps1 | ConvertTo-Json -Depth 4)))
    [void]$sections.Add((New-AgentPromptSection -Header '=== TOP 5 LONGEST FUNCTIONS ===' -Content ($funcs | ConvertTo-Json -Depth 4)))
  } elseif ($Role -eq 'dependency-model') {
    $configPath = Join-Path $BridgeRoot 'config.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
      $coverage.Add('config.json')
      $configContent = Get-AgentFileContentCapped -Path $configPath -Cap 30000
      if (Test-AgentContentTruncated -Content $configContent) { [void]$truncatedSections.Add('config.json') }
      [void]$sections.Add((New-AgentPromptSection -Header '=== config.json ===' -Content $configContent))
    }
    $tools = @(Get-ChildItem -LiteralPath (Join-Path $BridgeRoot 'tools') -Filter *.ps1 -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($t in $tools) { $coverage.Add((Get-AgentRelativePath -Root $BridgeRoot -Path $t.FullName)) }
    $scanFiles = New-Object 'System.Collections.Generic.List[string]'
    foreach ($d in @($BridgeRoot, (Join-Path $BridgeRoot 'lib'), (Join-Path $BridgeRoot 'tools'))) {
      foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter *.ps1 -File -ErrorAction SilentlyContinue)) { [void]$scanFiles.Add($f.FullName) }
    }
    $scanText = @{}
    foreach ($sf in $scanFiles) { try { $scanText[$sf] = [System.IO.File]::ReadAllText($sf) } catch { $scanText[$sf] = '' } }
    $refLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($t in $tools) {
      $refs = 0
      foreach ($sf in $scanFiles) { if ($sf -eq $t.FullName) { continue }; if ($scanText[$sf] -match [regex]::Escape($t.Name)) { $refs++ } }
      [void]$refLines.Add(($t.Name + ' : referenced ' + $refs + 'x'))
    }
    [void]$sections.Add((New-AgentPromptSection -Header '=== tools/*.ps1 (with reference counts -- references>=1 means NOT orphaned, do not flag) ===' -Content ($refLines -join "`n")))
  }

  return [pscustomobject]@{
    coverage = $coverage.ToArray()
    sections = $sections.ToArray()
    truncated_sections = $truncatedSections.ToArray()
  }
}

function Format-AgentPrompt {
  param(
    [string[]]$TemplateLines,
    $Sections
  )

  $sb = New-Object System.Text.StringBuilder
  foreach ($line in $TemplateLines) {
    [void]$sb.AppendLine([string]$line)
  }
  foreach ($section in @($Sections)) {
    [void]$sb.AppendLine([string]$section.header)
    [void]$sb.AppendLine([string]$section.content)
    if ($section.blank_after) { [void]$sb.AppendLine('') }
  }
  return $sb.ToString()
}

function New-AgentPrompt {
  param([string]$Role, [string]$BridgeRoot, [string]$ProjRoot)

  $templateLines = @(Get-AgentPromptTemplate -Role $Role)
  $context = Get-AgentPromptContext -Role $Role -BridgeRoot $BridgeRoot -ProjRoot $ProjRoot
  $promptText = Format-AgentPrompt -TemplateLines $templateLines -Sections $context.sections
  $promptChars = $promptText.Length
  $promptTruncated = ($context.truncated_sections.Count -gt 0)
  $contextPolicy = 'default'
  if ($Role -eq 'security-model') { $contextPolicy = 'risk_ranked' }
  elseif ($Role -in @('architecture-model','dependency-model')) { $contextPolicy = 'source_only_excluded' }

  return [pscustomobject]@{
    prompt = $promptText
    coverage = @($context.coverage | Select-Object -Unique)
    prompt_chars = $promptChars
    prompt_truncated = $promptTruncated
    truncated_sections = @($context.truncated_sections | Select-Object -Unique)
    context_policy = $contextPolicy
  }
}

$bridgeRoot = Resolve-AgentRoot -Hint $BridgePath
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = $bridgeRoot }
try { $projRoot = [System.IO.Path]::GetFullPath($ProjectRoot) } catch { $projRoot = $ProjectRoot }
$cfg = Get-DeepAuditConfig -Root $bridgeRoot
if ([string]::IsNullOrWhiteSpace($Model)) { $Model = Get-DefaultAgentModel -Cfg $cfg -RoleName $Role }

$errors = New-Object System.Collections.Generic.List[string]
$findings = @()
$status = 'ok'
$promptContext = New-AgentPrompt -Role $Role -BridgeRoot $bridgeRoot -ProjRoot $projRoot

if ($NoLLM -or -not $RunLLM) {
  $status = 'prompt_ready'
} else {
  try {
    $commonLib = Join-Path $bridgeRoot 'lib\common.ps1'
    if (Test-Path -LiteralPath $commonLib -PathType Leaf) { . $commonLib 2>$null | Out-Null }
    if (-not (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)) {
      $status = 'error'
      $errors.Add('Invoke-LLM unavailable')
    } else {
      $reply = Invoke-LLM -Purpose ('audit-' + $Role) -Model $Model -Prompt $promptContext.prompt -TimeoutSec $TimeoutSec -Temperature 0.2
      if ([string]::IsNullOrWhiteSpace($reply)) {
        $status = 'error'
        $errors.Add("empty_llm_reply (prompt_chars=$($promptContext.prompt_chars))")
      } else {
        $parsed = Extract-AgentJson -Text $reply
        if ($parsed -is [Array]) { $findings = @($parsed) }
        elseif ($parsed -and $parsed.findings) { $findings = @($parsed.findings) }
        elseif ($parsed) { $findings = @($parsed) }
        else {
          $status = 'error'
          $errors.Add('json_parse_failed')
        }
      }
    }
  } catch {
    $status = 'error'
    $errors.Add($_.Exception.Message)
  }
}

$runtimeSec = (([datetime]::UtcNow) - $startTime).TotalSeconds
$result = [pscustomobject]@{
  role = $Role
  model = $Model
  status = $status
  runtime_sec = [Math]::Round([double]$runtimeSec, 3)
  findings = @($findings)
  errors = @($errors)
  coverage = @($promptContext.coverage)
  confidence = [double](Get-AgentConfidence -RoleName $Role)
  prompt_chars = [int]$promptContext.prompt_chars
  prompt_truncated = [bool]$promptContext.prompt_truncated
  truncated_sections = @($promptContext.truncated_sections)
  context_policy = [string]$promptContext.context_policy
}

$json = $result | ConvertTo-Json -Depth 10 -Compress
if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
  [System.IO.File]::WriteAllText($OutputFile, $json, $Utf8NoBom)
} else {
  $json
}
