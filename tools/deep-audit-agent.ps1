[CmdletBinding()]
param(
  [string]$BridgePath = '',
  [string]$ProjectRoot = '',
  [ValidateSet('security-model','functional-model','reliability-model')]
  [string]$Role = 'functional-model',
  [string]$Model = 'deepseek-v4-flash',
  [string]$OutputFile = '',
  [int]$TimeoutSec = 120
)

$ErrorActionPreference = 'Continue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $Utf8NoBom } catch {}

function Get-AgentBridgeRoot {
  if ($BridgePath -and (Test-Path -LiteralPath $BridgePath)) {
    return [System.IO.Path]::GetFullPath($BridgePath)
  }
  return [System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}

function Get-AgentFileContentCapped {
  param([string]$Path, [int]$Cap = 12000)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try {
    $txt = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ($txt.Length -gt $Cap) { return $txt.Substring(0, $Cap) + "`n...[truncated at $Cap chars]" }
    return $txt
  } catch { return '' }
}

function Get-AgentJson {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $clean = ($Text -replace '```(?:json)?', '' -replace '```', '').Trim()
  $m = [regex]::Match($clean, '(?s)\[.*\]')
  if (-not $m.Success) { $m = [regex]::Match($clean, '(?s)\{.*\}') }
  if (-not $m.Success) { return $null }
  try { return ($m.Value | ConvertFrom-Json) } catch { return $null }
}

function Get-AgentTail {
  param([string]$Path, [int]$Tail = 80)
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { return (Get-Content -LiteralPath $Path -Tail $Tail -Encoding UTF8 | Out-String).Trim() } catch { return '' }
}

function Get-AgentRecentCodeContext {
  param([string]$Root)
  $sb = New-Object System.Text.StringBuilder
  try {
    $log = (& git -C $Root log --since='72 hours ago' --pretty=format:'%h %cI %s' 2>$null | Out-String).Trim()
    [void]$sb.AppendLine("=== RECENT GIT LOG 72H ===")
    [void]$sb.AppendLine($log)
  } catch {}

  $files = @()
  try {
    $files = @(& git -C $Root log --since='72 hours ago' --name-only --pretty=format: 2>$null |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Sort-Object -Unique |
      Where-Object { $_ -match '\.(ps1|psm1|html|js|json)$' } |
      Select-Object -First 18)
  } catch { $files = @() }

  [void]$sb.AppendLine('')
  [void]$sb.AppendLine("=== RECENT FILE SAMPLES ===")
  $total = 0
  foreach ($f in $files) {
    $full = Join-Path $Root $f
    $content = Get-AgentFileContentCapped -Path $full -Cap 5000
    if ([string]::IsNullOrWhiteSpace($content)) { continue }
    $total += $content.Length
    if ($total -gt 65000) { [void]$sb.AppendLine('...[global cap reached]'); break }
    [void]$sb.AppendLine("--- $f ---")
    [void]$sb.AppendLine($content)
  }
  return $sb.ToString()
}

function Convert-AgentFindings {
  param($Parsed)
  $items = @()
  if ($null -eq $Parsed) { return @() }
  if ($Parsed -is [Array]) { $items = @($Parsed) }
  elseif ($Parsed.PSObject -and $Parsed.PSObject.Properties.Name -contains 'findings') { $items = @($Parsed.findings) }
  else { $items = @($Parsed) }

  $out = New-Object 'System.Collections.Generic.List[object]'
  foreach ($f in @($items)) {
    if (-not $f) { continue }
    $sev = 'info'
    try { $sev = ([string]$f.severity).ToLowerInvariant() } catch {}
    if ($sev -notin @('critical','warning','info')) {
      switch ($sev) {
        'high' { $sev = 'critical' }
        'medium' { $sev = 'warning' }
        default { $sev = 'info' }
      }
    }
    $category = ''
    $area = ''
    $observation = ''
    $recommendation = ''
    try { $category = [string]$f.category } catch {}
    try { $area = [string]$f.area } catch {}
    if ([string]::IsNullOrWhiteSpace($area)) { try { $area = [string]$f.file } catch {} }
    if ([string]::IsNullOrWhiteSpace($area)) { try { $area = [string]$f.component } catch {} }
    try { $observation = [string]$f.observation } catch {}
    if ([string]::IsNullOrWhiteSpace($observation)) { try { $observation = [string]$f.finding } catch {} }
    if ([string]::IsNullOrWhiteSpace($observation)) { try { $observation = [string]$f.message } catch {} }
    try { $recommendation = [string]$f.recommendation } catch {}
    if ([string]::IsNullOrWhiteSpace($category)) { $category = $Role }
    if ([string]::IsNullOrWhiteSpace($area)) { $area = 'bridge' }
    if ([string]::IsNullOrWhiteSpace($observation)) { continue }
    [void]$out.Add([pscustomobject]@{
      severity = $sev
      category = $category
      area = $area
      observation = $observation
      recommendation = $recommendation
    })
  }
  return @($out.ToArray())
}

function New-AgentPrompt {
  param([string]$Role, [string]$BridgeRoot, [string]$ProjRoot)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("You are an independent deep-audit agent for the bridge automation system.")
  [void]$sb.AppendLine("Find concrete defects only. Do not report generic advice or issues that are already described as test fixtures.")
  [void]$sb.AppendLine("Return strictly a JSON array, or [] when there are no findings.")
  [void]$sb.AppendLine('Schema: [{"severity":"critical|warning|info","category":"short-category","area":"file/function/subsystem","observation":"specific defect and evidence","recommendation":"specific fix"}]')
  [void]$sb.AppendLine('')

  if ($Role -eq 'security-model') {
    [void]$sb.AppendLine("FOCUS: security. Look for command injection, path traversal, auth bypass, secret leakage, unsafe process launch, unsafe JSON/API behavior, and lock misuse that can corrupt security-sensitive state.")
    [void]$sb.AppendLine("Ignore detector strings in audit scripts and test-only code unless they are executed by production paths.")
    [void]$sb.AppendLine((Get-AgentRecentCodeContext -Root $ProjRoot))
  } elseif ($Role -eq 'functional-model') {
    [void]$sb.AppendLine("FOCUS: feature behavior and drift. Compare registry/state/docs/logs with code behavior. Find dormant features, broken flows, mismatched registry claims, and reporting defects.")
    [void]$sb.AppendLine("=== FEATURES REGISTRY ===")
    [void]$sb.AppendLine((Get-AgentFileContentCapped -Path (Join-Path $BridgeRoot 'features\registry.json') -Cap 35000))
    [void]$sb.AppendLine("=== FEATURES STATE ===")
    [void]$sb.AppendLine((Get-AgentFileContentCapped -Path (Join-Path $BridgeRoot 'features\state.json') -Cap 10000))
    [void]$sb.AppendLine("=== RECENT GIT LOG 7D ===")
    try { [void]$sb.AppendLine((& git -C $ProjRoot log --since='7 days ago' --pretty=format:'%h %cI %s' 2>$null | Out-String).Trim()) } catch {}
    [void]$sb.AppendLine("=== AUDIT LOG TAIL ===")
    [void]$sb.AppendLine((Get-AgentTail -Path (Join-Path $BridgeRoot 'audit\audit.log') -Tail 80))
  } else {
    [void]$sb.AppendLine("FOCUS: reliability and runtime failures. Look for restart loops, timeouts, state corruption, lock/mutex bugs, false-green health checks, zombie jobs, and audit blind spots.")
    [void]$sb.AppendLine("=== AUDIT LOG TAIL ===")
    [void]$sb.AppendLine((Get-AgentTail -Path (Join-Path $BridgeRoot 'audit\audit.log') -Tail 120))
    [void]$sb.AppendLine("=== SUPERVISOR LOG TAIL ===")
    [void]$sb.AppendLine((Get-AgentTail -Path (Join-Path $BridgeRoot 'control\supervisor.log') -Tail 120))
    [void]$sb.AppendLine("=== CIRCUIT BREAKER RESTARTS TAIL ===")
    $runtimeRoot = Join-Path $env:USERPROFILE '.bridge-runtime'
    [void]$sb.AppendLine((Get-AgentTail -Path (Join-Path $runtimeRoot 'restarts.jsonl') -Tail 120))
    [void]$sb.AppendLine("=== RECENT TURNS TAIL ===")
    [void]$sb.AppendLine((Get-AgentTail -Path (Join-Path $BridgeRoot 'turns.jsonl') -Tail 80))
  }
  return $sb.ToString()
}

$bridgeRoot = Get-AgentBridgeRoot
$projRoot = if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot } else { $bridgeRoot }
try { $projRoot = [System.IO.Path]::GetFullPath($projRoot) } catch {}

$result = [ordered]@{
  role = $Role
  model = $Model
  skipped = $false
  error = $null
  findings = @()
  tokens = 0
}

try {
  $commonLib = Join-Path $bridgeRoot 'lib\common.ps1'
  if (Test-Path -LiteralPath $commonLib -PathType Leaf) { . $commonLib 2>$null | Out-Null }
  if (-not (Get-Command Invoke-LLM -ErrorAction SilentlyContinue)) {
    $result.error = 'invoke_llm_unavailable'
  } else {
    $prompt = New-AgentPrompt -Role $Role -BridgeRoot $bridgeRoot -ProjRoot $projRoot
    $reply = Invoke-LLM -Purpose 'deep-audit-agent' -Model $Model -Prompt $prompt -TimeoutSec $TimeoutSec -Temperature 0.2
    $result.tokens = [int]([string]$reply).Length
    if ([string]::IsNullOrWhiteSpace($reply)) {
      $result.error = 'empty_reply'
    } else {
      $parsed = Get-AgentJson -Text $reply
      if ($parsed) { $result.findings = @(Convert-AgentFindings -Parsed $parsed) }
      else { $result.error = 'json_parse_failed' }
    }
  }
} catch {
  $result.error = $_.Exception.Message
}

$json = ([pscustomobject]$result) | ConvertTo-Json -Depth 8 -Compress
if (-not [string]::IsNullOrWhiteSpace($OutputFile)) {
  try { [System.IO.File]::WriteAllText($OutputFile, $json, $Utf8NoBom) } catch { $json }
} else {
  $json
}
