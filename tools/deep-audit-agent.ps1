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

function New-AgentPrompt {
  param([string]$Role, [string]$BridgeRoot, [string]$ProjRoot)

  $coverage = New-Object System.Collections.Generic.List[string]
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('You are one specialist in a multi-agent deep audit. Return strict JSON only.')
  [void]$sb.AppendLine('JSON schema: [{"severity":"critical|warning|info","category":"string","file":"path","line":N,"observation":"specific issue","recommendation":"specific fix"}]')
  [void]$sb.AppendLine('Use [] when there are no concrete findings. Avoid speculative findings.')
  [void]$sb.AppendLine('')

  if ($Role -eq 'security-model') {
    [void]$sb.AppendLine('Role: security audit. Find exploitable command injection, path traversal, auth bypass, hardcoded secrets, and unsafe dynamic execution.')
    $files = @(Get-ChildItem -LiteralPath $ProjRoot -Recurse -Include *.ps1,*.json,*.html,*.js -File -ErrorAction SilentlyContinue | Select-Object -First 30)
    foreach ($f in $files) {
      $rel = Get-AgentRelativePath -Root $ProjRoot -Path $f.FullName
      $coverage.Add($rel)
      [void]$sb.AppendLine("=== $rel ===")
      [void]$sb.AppendLine((Get-AgentFileContentCapped -Path $f.FullName -Cap 5000))
    }
  } elseif ($Role -eq 'functional-model') {
    [void]$sb.AppendLine('Role: functional audit. Find registry drift, dormant declared features, undocumented implemented features, and missing user-facing scenarios.')
    $paths = @('features\registry.json','features\state.json','audit\audit.log','turns.jsonl')
    foreach ($p in $paths) {
      $full = Join-Path $BridgeRoot $p
      if (Test-Path -LiteralPath $full -PathType Leaf) {
        $coverage.Add($p)
        [void]$sb.AppendLine("=== $p ===")
        [void]$sb.AppendLine((Get-AgentFileContentCapped -Path $full -Cap 20000))
      }
    }
  } elseif ($Role -eq 'reliability-model') {
    [void]$sb.AppendLine('Role: reliability audit. Find timeout bugs, missing cleanup, brittle process supervision, non-atomic writes, and retry loops without bounds.')
    $paths = @('driver.ps1','server.ps1','supervisor.ps1','watchdog.ps1','lib\jobs.ps1','lib\circuit-breaker.ps1')
    foreach ($p in $paths) {
      $full = Join-Path $ProjRoot $p
      if (Test-Path -LiteralPath $full -PathType Leaf) {
        $coverage.Add($p)
        [void]$sb.AppendLine("=== $p ===")
        [void]$sb.AppendLine((Get-AgentFileContentCapped -Path $full -Cap 10000))
      }
    }
  } elseif ($Role -eq 'runtime-incident-model') {
    [void]$sb.AppendLine('Role: runtime-incident model. Your job: analyse the attached incident-bundle and produce structured findings.')
    [void]$sb.AppendLine('Tasks:')
    [void]$sb.AppendLine('1. ATTRIBUTION: for every restart/CB event in incident-bundle, identify the nearest active task (by timestamp delta <= 5 min). If no task is within 5 min, flag as orphan-restart.')
    [void]$sb.AppendLine('2. CB-LOOP: if two or more CB activations appear within any 30-minute window, or if a task appears in restarts with cause=task-survived-3x, flag as cb-loop with the task description and file diffs present.')
    [void]$sb.AppendLine('3. DIFF-CORRELATION: for each CB event that has diff_files populated, list which files changed just before the CB. If diff_files is empty, note "no-diff-captured" as an attribution gap.')
    [void]$sb.AppendLine('4. ATTRIBUTION-GAP: flag any restart where task_id is missing/unknown and no task turn is within 10 minutes.')
    [void]$sb.AppendLine('Severity: critical=cb-loop or >=3 orphan-restarts; warning=single orphan-restart or attribution-gap; info=everything else.')
    [void]$sb.AppendLine('')

    # --- build incident-bundle ---
    $runtimeRoot = Join-Path $env:USERPROFILE '.bridge-runtime'
    $coverage.Add('restarts.jsonl')
    $coverage.Add('turns.jsonl')
    $coverage.Add('state.json')

    # recent restarts (last 30 lines)
    $restartsPath = Join-Path $runtimeRoot 'restarts.jsonl'
    $restartsSnippet = ''
    try {
      if (Test-Path -LiteralPath $restartsPath -PathType Leaf) {
        $lines = [System.IO.File]::ReadAllLines($restartsPath)
        $recent = if ($lines.Count -gt 30) { $lines[($lines.Count-30)..($lines.Count-1)] } else { $lines }
        $restartsSnippet = ($recent -join "`n")
      }
    } catch {}

    # recent turns (last 20 lines of turns.jsonl)
    $turnsPath = Join-Path $BridgeRoot 'turns.jsonl'
    $turnsSnippet = ''
    try {
      if (Test-Path -LiteralPath $turnsPath -PathType Leaf) {
        $lines = [System.IO.File]::ReadAllLines($turnsPath)
        $recent = if ($lines.Count -gt 20) { $lines[($lines.Count-20)..($lines.Count-1)] } else { $lines }
        $turnsSnippet = ($recent -join "`n")
      }
    } catch {}

    # state.json current task
    $stateSnippet = ''
    try {
      $statePath = Join-Path $BridgeRoot 'state.json'
      if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $stateSnippet = Get-AgentFileContentCapped -Path $statePath -Cap 2000
      }
    } catch {}

    # circuit-breaker snapshots (last 5)
    $cbSnippet = ''
    try {
      if (Test-Path -LiteralPath $runtimeRoot -PathType Container) {
        $cbItems = @(Get-ChildItem -LiteralPath $runtimeRoot -Filter 'circuit-breaker.*' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 5)
        $cbLines = New-Object System.Collections.Generic.List[string]
        foreach ($item in $cbItems) {
          $diffPath = $null
          if ($item.PSIsContainer) { $diffPath = Join-Path $item.FullName 'git-diff.patch' }
          else { $diffPath = $item.FullName }
          $diffFiles = @()
          if ($diffPath -and (Test-Path -LiteralPath $diffPath -PathType Leaf)) {
            foreach ($line in [System.IO.File]::ReadAllLines($diffPath)) {
              if ($line -match '^diff --git a/.+ b/(.+)$') { $diffFiles += $Matches[1] }
              if ($diffFiles.Count -ge 10) { break }
            }
          }
          [void]$cbLines.Add(("{0} | diff_files=[{1}]" -f $item.Name, ($diffFiles -join ',')))
        }
        $cbSnippet = ($cbLines -join "`n")
      }
    } catch {}

    [void]$sb.AppendLine('=== incident-bundle/restarts (last 30) ===')
    [void]$sb.AppendLine($(if ([string]::IsNullOrWhiteSpace($restartsSnippet)) { '(empty)' } else { $restartsSnippet }))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('=== incident-bundle/turns (last 20) ===')
    [void]$sb.AppendLine($(if ([string]::IsNullOrWhiteSpace($turnsSnippet)) { '(empty)' } else { $turnsSnippet }))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('=== incident-bundle/state (current task) ===')
    [void]$sb.AppendLine($(if ([string]::IsNullOrWhiteSpace($stateSnippet)) { '(empty)' } else { $stateSnippet }))
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('=== incident-bundle/circuit-breaker (last 5) ===')
    [void]$sb.AppendLine($(if ([string]::IsNullOrWhiteSpace($cbSnippet)) { '(empty)' } else { $cbSnippet }))
    [void]$sb.AppendLine('')
  } elseif ($Role -eq 'latency-speed-model') {
    [void]$sb.AppendLine('Role: latency-speed audit. Analyse p95 latency by phase (mode + fast_lane) for status=ok turns.')
    [void]$sb.AppendLine('JSON schema: [{"severity":"critical|warning|info","category":"string","file":"path","line":0,"observation":"specific issue","recommendation":"specific fix"}]')
    [void]$sb.AppendLine('Find ONLY concrete issues:')
    [void]$sb.AppendLine('- slow_phase: any phase where p95_ok_sec > 600s (normal/discuss) or > 120s (fast+fast_lane). warning if p95>300s, critical if p95>900s.')
    [void]$sb.AppendLine('- no_fast_lane: fast_lane turns count=0 while total_ok_turns>50 (feature deployed but never triggered).')
    [void]$sb.AppendLine('- outlier: max_ok_sec > 3*p95_ok_sec for any phase (single outlier skewing distribution).')
    [void]$sb.AppendLine('- high_failure: timeout_pct > 5% overall.')
    [void]$sb.AppendLine('Use [] if no threshold is exceeded. Avoid speculative findings.')
    [void]$sb.AppendLine('')
    $coverage.Add('turns.jsonl')
    $coverage.Add('audit/signals/speed.json')
    # read pre-computed speed.json
    $signalsPath = Join-Path $BridgeRoot 'audit\signals\speed.json'
    if (Test-Path -LiteralPath $signalsPath -PathType Leaf) {
      try {
        $sigJson = [System.IO.File]::ReadAllText($signalsPath, [System.Text.Encoding]::UTF8)
        [void]$sb.AppendLine('=== audit/signals/speed.json (overall stats) ===')
        [void]$sb.AppendLine($(if ($sigJson.Length -gt 4000) { $sigJson.Substring(0,4000) + '...[truncated]' } else { $sigJson }))
        [void]$sb.AppendLine('')
      } catch {}
    }
    # compute per-phase p95 directly from turns.jsonl (status=ok only, last 500 rows)
    $turnsPath2 = Join-Path $BridgeRoot 'turns.jsonl'
    $phaseMap = @{}  # phase-key -> List[double]
    if (Test-Path -LiteralPath $turnsPath2 -PathType Leaf) {
      try {
        $allTurnLines = [System.IO.File]::ReadAllLines($turnsPath2)
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
    $phaseStatsTxt = $phaseLines.ToString().Trim()
    [void]$sb.AppendLine('=== per-phase latency (status=ok, last 500 turns) ===')
    [void]$sb.AppendLine($(if ([string]::IsNullOrWhiteSpace($phaseStatsTxt)) { '(no status=ok turns found)' } else { $phaseStatsTxt }))
    [void]$sb.AppendLine('')
  } elseif ($Role -eq 'cost-burn-model') {
    [void]$sb.AppendLine('Role: cost-burn audit. Find wasted spend in usage.jsonl: duplicate LLM calls (same purpose+model >=3 times in 5 min) and failed-token-burn (prompt cost paid, zero completion output on text-generation calls).')
    [void]$sb.AppendLine('JSON schema: [{"severity":"critical|warning|info","category":"string","file":"path","line":0,"observation":"specific issue","recommendation":"specific fix"}]')
    [void]$sb.AppendLine('Find ONLY concrete issues:')
    [void]$sb.AppendLine('- duplicate_burst: same purpose+model called >=3 times within any 5-min window (audit/retry storm).')
    [void]$sb.AppendLine('- failed_burn: text-gen calls (purpose not embed/codemem/embedding) where completion_tokens=0 AND cost_usd>0 AND count>2.')
    [void]$sb.AppendLine('- expensive_purpose: single purpose with total cost_usd > $0.50 in window without proportional value.')
    [void]$sb.AppendLine('Use [] if no concrete issue. Avoid speculative findings.')
    [void]$sb.AppendLine('')
    $coverage.Add('usage.jsonl')
    $coverage.Add('audit/signals/cost.json')
    # read pre-computed cost.json
    $costSignalPath = Join-Path $BridgeRoot 'audit\signals\cost.json'
    if (Test-Path -LiteralPath $costSignalPath -PathType Leaf) {
      try {
        $cJson = [System.IO.File]::ReadAllText($costSignalPath, [System.Text.Encoding]::UTF8)
        [void]$sb.AppendLine('=== audit/signals/cost.json (pre-computed cost breakdown) ===')
        [void]$sb.AppendLine($(if ($cJson.Length -gt 4000) { $cJson.Substring(0,4000) + '...[truncated]' } else { $cJson }))
        [void]$sb.AppendLine('')
      } catch {}
    }
    # read usage.jsonl for duplicate + failed-burn detection (last 1000 rows)
    $usageRawPath = Join-Path $BridgeRoot 'usage.jsonl'
    $purposeModelTs = @{}   # "$purpose|$model" -> List[datetime]
    $failedBurnCount = 0
    $failedBurnCostUsd = 0.0
    $failedBurnExamples = New-Object 'System.Collections.Generic.List[string]'
    $textGenPurposes = @{}  # purpose -> completion_tokens sum
    if (Test-Path -LiteralPath $usageRawPath -PathType Leaf) {
      try {
        $allULines = [System.IO.File]::ReadAllLines($usageRawPath)
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
            # duplicate detection
            if (-not [string]::IsNullOrWhiteSpace($uPurpose) -and $uTs -ne $null) {
              $key = "$uPurpose|$uModel"
              if (-not $purposeModelTs.ContainsKey($key)) { $purposeModelTs[$key] = New-Object 'System.Collections.Generic.List[datetime]' }
              [void]$purposeModelTs[$key].Add($uTs)
            }
            # failed-token-burn: text-gen only (exclude embed/codemem)
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
    # burst detection
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
    [void]$sb.AppendLine('=== failed-token-burn (text-gen: completion_tokens=0, cost_usd>0, last 1000 rows) ===')
    [void]$sb.AppendLine("count=$failedBurnCount total_cost_usd=$([Math]::Round($failedBurnCostUsd,6))")
    if ($failedBurnExamples.Count -gt 0) { [void]$sb.AppendLine('examples: ' + ($failedBurnExamples -join ' | ')) }
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('=== duplicate-burst (same purpose+model >=3 calls within 5 min) ===')
    if ($dupBursts.Count -eq 0) {
      [void]$sb.AppendLine('(none detected)')
    } else {
      foreach ($burst in $dupBursts) { [void]$sb.AppendLine($burst) }
    }
    [void]$sb.AppendLine('')
  } elseif ($Role -eq 'architecture-model') {
    [void]$sb.AppendLine('Role: architecture audit. Find dead functions/unused exports, architecture antipatterns, layer violations such as driver->lib misuse or server->driver without API, and very long functions over 150 lines that need decomposition.')
    [void]$sb.AppendLine('Context: all .ps1 files with line counts and the top 5 longest functions.')
    $ps1 = @(Get-AgentPs1Inventory -Root $ProjRoot)
    $funcs = @(Get-AgentFunctionInventory -Root $ProjRoot | Select-Object -First 5)
    foreach ($item in $ps1) { $coverage.Add($item.path) }
    [void]$sb.AppendLine('=== PS1 LINE COUNTS ===')
    [void]$sb.AppendLine(($ps1 | ConvertTo-Json -Depth 4))
    [void]$sb.AppendLine('=== TOP 5 LONGEST FUNCTIONS ===')
    [void]$sb.AppendLine(($funcs | ConvertTo-Json -Depth 4))
  } elseif ($Role -eq 'dependency-model') {
    [void]$sb.AppendLine('Role: dependency/config audit. Find orphaned config keys, duplicate config keys, missing required config keys, and TRULY orphaned tools.')
    # 2026-05-30: this prompt previously gave only a bare filename list, and the model
    # mislabeled Start-Process-launched tools as orphaned -- the resulting tasks nearly
    # deleted the ENTIRE audit pipeline (audit.ps1, deep-audit*.ps1, ...). Hard rule below.
    [void]$sb.AppendLine('CRITICAL orphaned-tool rule: a tool is orphaned ONLY if its filename appears NOWHERE else in the codebase. Tools are launched many ways -- Start-Process, the & call operator, a -File argument, dynamic path building, Task Scheduler -- NOT just dot-source/import. Each tool below is annotated with how many times its filename is referenced across driver/server/lib/tools (excluding itself). references>=1 => NOT orphaned: DO NOT flag it. Only consider references=0, and even then be cautious. NEVER flag audit*/deep-audit*/audit-runner -- that is the audit engine currently running you.')
    $configPath = Join-Path $BridgeRoot 'config.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
      $coverage.Add('config.json')
      [void]$sb.AppendLine('=== config.json ===')
      [void]$sb.AppendLine((Get-AgentFileContentCapped -Path $configPath -Cap 30000))
    }
    $tools = @(Get-ChildItem -LiteralPath (Join-Path $BridgeRoot 'tools') -Filter *.ps1 -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($t in $tools) { $coverage.Add((Get-AgentRelativePath -Root $BridgeRoot -Path $t.FullName)) }
    # Build a reference index across core code so each tool gets a real usage count.
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
    [void]$sb.AppendLine('=== tools/*.ps1 (with reference counts -- references>=1 means NOT orphaned, do not flag) ===')
    [void]$sb.AppendLine(($refLines -join "`n"))
  }

  return [pscustomobject]@{
    prompt = $sb.ToString()
    coverage = @($coverage | Select-Object -Unique)
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
        $errors.Add('empty_llm_reply')
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
}

$json = $result | ConvertTo-Json -Depth 10 -Compress
if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
  [System.IO.File]::WriteAllText($OutputFile, $json, $Utf8NoBom)
} else {
  $json
}
