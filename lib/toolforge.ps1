# toolforge.ps1 -- Tool Foundry (Фаза 1): registry + loader for tools the bridge
# synthesizes ON THE FLY. An "auto-tool" is a standalone PowerShell script at
# tools/auto/<name>.ps1 with an explicit contract (inputs/outputs), born when the
# planner emits [[NEED-TOOL: ...]] and a sandboxed coder builds + tests it.
#
# THIS FILE is the SAFE foundation only: registry persistence, name validation
# (path-traversal-proof), and a loader that dot-sources ONLY green (status=active)
# tools after a parse-check. The risky build pipeline (Build-AutoTool) and the
# [[NEED-TOOL]] marker wiring layer on top of these primitives.
#
# Invariants: never throws (best-effort); a broken tool is skipped, never blocks the
# engine; registry writes go through Write-AtomicFile (UTF-8 no-BOM, OneDrive-safe).

function Get-ToolForgeRoot {
  $root = $null
  try { $root = Get-BridgeRoot } catch {}
  if ([string]::IsNullOrWhiteSpace($root)) { return $null }
  return (Join-Path $root 'tools\auto')
}

function Get-ToolRegistryPath {
  $tf = Get-ToolForgeRoot
  if ([string]::IsNullOrWhiteSpace($tf)) { return $null }
  return (Join-Path $tf 'registry.json')
}

function Test-AutoToolName {
  # Return a sanitized safe leaf name, or $null if invalid. Defeats path traversal:
  # no separators, no '..', must start with a letter, identifier-ish, <=64 chars.
  param([string]$Name)
  if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
  $n = ([string]$Name).Trim()
  if ($n.ToLowerInvariant().EndsWith('.ps1')) { $n = $n.Substring(0, $n.Length - 4) }
  if ($n -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$') { return $null }
  return $n
}

function New-ToolRegistry {
  [pscustomobject]@{ version = 1; tools = @() }
}

function Read-ToolRegistry {
  $p = Get-ToolRegistryPath
  if ([string]::IsNullOrWhiteSpace($p) -or -not (Test-Path -LiteralPath $p)) { return (New-ToolRegistry) }
  try {
    $obj = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $obj) { return (New-ToolRegistry) }
    if (-not ($obj.PSObject.Properties.Name -contains 'tools') -or $null -eq $obj.tools) {
      $obj | Add-Member -NotePropertyName tools -NotePropertyValue @() -Force
    }
    return $obj
  } catch { return (New-ToolRegistry) }
}

function Write-ToolRegistry {
  param($Registry)
  $p = Get-ToolRegistryPath
  if ([string]::IsNullOrWhiteSpace($p)) { return $false }
  $dir = Split-Path -Parent $p
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  try {
    $json = $Registry | ConvertTo-Json -Depth 8
    if (Get-Command Write-AtomicFile -ErrorAction SilentlyContinue) { Write-AtomicFile -Path $p -Content $json }
    else { [System.IO.File]::WriteAllText($p, $json, (New-Object System.Text.UTF8Encoding($false))) }
    return $true
  } catch { return $false }
}

function Get-AutoTool {
  param([string]$Name)
  $n = Test-AutoToolName -Name $Name
  if (-not $n) { return $null }
  $reg = Read-ToolRegistry
  foreach ($t in @($reg.tools)) { if ([string]$t.name -eq $n) { return $t } }
  return $null
}

function Register-AutoTool {
  # Upsert a tool entry. Status: 'active' (green, usable) | 'quarantined' (failed
  # tests/critic) | 'building'. Preserves created_at/use_count across re-registration.
  # Returns the entry or $null on invalid name / write failure.
  param(
    [string]$Name,
    [string]$Contract,
    [string]$File,
    [string]$Status = 'active',
    [string]$SmokeTest = '',
    [string]$Provenance = '',
    [string]$Critic = ''
  )
  $n = Test-AutoToolName -Name $Name
  if (-not $n) { return $null }
  $reg = Read-ToolRegistry
  $now = (Get-Date).ToUniversalTime().ToString('o')
  $tools = New-Object System.Collections.Generic.List[object]
  $existing = $null
  foreach ($t in @($reg.tools)) {
    if ([string]$t.name -eq $n) { $existing = $t } else { [void]$tools.Add($t) }
  }
  $createdAt = if ($existing -and $existing.created_at) { [string]$existing.created_at } else { $now }
  $lastUsed  = if ($existing -and $existing.last_used) { [string]$existing.last_used } else { $null }
  $useCount  = if ($existing -and $existing.use_count) { [int]$existing.use_count } else { 0 }
  $fileRel   = if ([string]::IsNullOrWhiteSpace($File)) { "tools/auto/$n.ps1" } else { [string]$File }
  $entry = [pscustomobject]@{
    name       = $n
    contract   = [string]$Contract
    file       = $fileRel
    status     = [string]$Status
    smoke_test = [string]$SmokeTest
    provenance = [string]$Provenance
    critic     = [string]$Critic
    created_at = $createdAt
    updated_at = $now
    last_used  = $lastUsed
    use_count  = $useCount
  }
  [void]$tools.Add($entry)
  $reg.tools = @($tools.ToArray())
  if (Write-ToolRegistry -Registry $reg) { return $entry }
  return $null
}

function Set-AutoToolUsed {
  # Mark a tool as used (bump use_count + last_used). Best-effort.
  param([string]$Name)
  $n = Test-AutoToolName -Name $Name
  if (-not $n) { return }
  $reg = Read-ToolRegistry
  $changed = $false
  foreach ($t in @($reg.tools)) {
    if ([string]$t.name -eq $n) {
      $t | Add-Member -NotePropertyName last_used -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
      $t | Add-Member -NotePropertyName use_count -NotePropertyValue (([int]$t.use_count) + 1) -Force
      $changed = $true
    }
  }
  if ($changed) { Write-ToolRegistry -Registry $reg | Out-Null }
}

function Get-ActiveAutoToolPaths {
  # Return absolute paths of ACTIVE auto-tools whose file exists and parses cleanly.
  # PURE (no side effects): the CALLER dot-sources these AT TOP-LEVEL so the tool
  # functions land in the engine's script scope (dot-sourcing inside a function would
  # trap them in that function's scope). A broken/missing tool is silently dropped, so
  # it can never block the engine. Names are re-validated to defeat path traversal.
  $tf = Get-ToolForgeRoot
  $paths = New-Object System.Collections.Generic.List[string]
  if ([string]::IsNullOrWhiteSpace($tf) -or -not (Test-Path -LiteralPath $tf)) { return @() }
  $reg = Read-ToolRegistry
  foreach ($t in @($reg.tools)) {
    if ([string]$t.status -ne 'active') { continue }
    $n = Test-AutoToolName -Name ([string]$t.name)
    if (-not $n) { continue }
    $path = Join-Path $tf "$n.ps1"
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $pt = $null; $pe = $null
    try { [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$pt, [ref]$pe) } catch { $pe = $null }
    if ($pe -and $pe.Count -gt 0) { continue }
    [void]$paths.Add($path)
  }
  return @($paths.ToArray())
}

function Get-AutoToolsPromptBlock {
  # Render the ACTIVE tool registry as a compact prompt snippet so planner/coder know
  # which synthesized tools already exist (reuse before rebuild). '' if none. Bounded.
  param([int]$MaxChars = 1200)
  $reg = Read-ToolRegistry
  $active = @($reg.tools | Where-Object { [string]$_.status -eq 'active' })
  if ($active.Count -eq 0) { return '' }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('Само-построенные инструменты (tools/auto/, переиспользуй вместо повторной постройки):')
  foreach ($t in $active) {
    [void]$sb.AppendLine("- $($t.name): $($t.contract)")
    if ($sb.Length -ge $MaxChars) { break }
  }
  $out = $sb.ToString().TrimEnd()
  if ($out.Length -gt $MaxChars) { $out = $out.Substring(0, $MaxChars) }
  return $out
}
