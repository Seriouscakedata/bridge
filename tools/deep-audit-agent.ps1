[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [ValidateSet('security-model','functional-model','reliability-model','architecture-model','dependency-model')]
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
  if ($RoleName -eq 'architecture-model') { return 0.70 }
  if ($RoleName -eq 'dependency-model') { return 0.65 }
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
    [void]$sb.AppendLine('Role: dependency/config audit. Find orphaned config keys, orphaned tools/ scripts not called from anywhere, duplicate config keys, and missing required config keys.')
    [void]$sb.AppendLine('Context: config.json content and tools/*.ps1 list.')
    $configPath = Join-Path $BridgeRoot 'config.json'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
      $coverage.Add('config.json')
      [void]$sb.AppendLine('=== config.json ===')
      [void]$sb.AppendLine((Get-AgentFileContentCapped -Path $configPath -Cap 30000))
    }
    $tools = @(Get-ChildItem -LiteralPath (Join-Path $BridgeRoot 'tools') -Filter *.ps1 -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($t in $tools) { $coverage.Add((Get-AgentRelativePath -Root $BridgeRoot -Path $t.FullName)) }
    [void]$sb.AppendLine('=== tools/*.ps1 ===')
    [void]$sb.AppendLine((@($tools | ForEach-Object { Get-AgentRelativePath -Root $BridgeRoot -Path $_.FullName }) | ConvertTo-Json))
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
