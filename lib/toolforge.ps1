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

function Get-AutoToolFileHash {
  # SHA-256 of file bytes as lowercase hex. $null on error.
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      $bytes = [System.IO.File]::ReadAllBytes($Path)
      $hash = $sha.ComputeHash($bytes)
      return [BitConverter]::ToString($hash).Replace('-', '').ToLowerInvariant()
    } finally {
      if ($sha) { $sha.Dispose() }
    }
  } catch {
    return $null
  }
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
    [string]$Critic = '',
    [string]$Sha256 = ''
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
    sha256     = [string]$Sha256
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
    # Integrity check: if a hash was stored at approval time, verify it now.
    $storedHash = [string]$t.sha256
    if (-not [string]::IsNullOrWhiteSpace($storedHash)) {
      $actualHash = Get-AutoToolFileHash -Path $path
      if ($actualHash -ne $storedHash) { continue }
    }
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
    [void]$sb.AppendLine("- $($t.name) (вызов: Invoke-$($t.name)): $($t.contract)")
    if ($sb.Length -ge $MaxChars) { break }
  }
  $out = $sb.ToString().TrimEnd()
  if ($out.Length -gt $MaxChars) { $out = $out.Substring(0, $MaxChars) }
  return $out
}

# ---------------------------------------------------------------------------
# Build pipeline (Фаза 1, increment 2): synthesize -> parse -> sandbox-smoke ->
# critic (different model) -> register. The RISKY layer, built on the safe
# primitives above. Untrusted generated code is NEVER dot-sourced into the engine;
# it only ever runs in an isolated child process with a timeout + throwaway cwd, and
# only files that pass parse+smoke+critic are promoted to the live tools/auto/ path
# (where the top-level loader in driver.ps1 will dot-source them next boot/turn).
# Build-AutoTool is best-effort: it never throws; failures end as 'quarantined'.
# ---------------------------------------------------------------------------

function Get-AutoToolEntryPoint {
  # Deterministic public entry function name for a tool: Invoke-<Name>. $null if bad name.
  param([string]$Name)
  $n = Test-AutoToolName -Name $Name
  if (-not $n) { return $null }
  return "Invoke-$n"
}

function Split-ForgeOutput {
  # Parse a generator reply into @{ tool; smoke }. Strips one ```...``` fence if present,
  # then splits on '# === TOOL ===' / '# === SMOKE ===' sentinels. No sentinels -> whole
  # body is the tool, smoke=''. Pure; never throws.
  param([string]$Raw)
  if ([string]::IsNullOrWhiteSpace($Raw)) { return @{ tool=''; smoke='' } }
  $body = [string]$Raw
  try {
    $m = [regex]::Match($body, '(?s)```[A-Za-z0-9_-]*\r?\n(.*?)\r?\n```')
    if ($m.Success) { $body = $m.Groups[1].Value }
  } catch {}
  $t = $body.Trim(); $s = ''
  try {
    $mt = [regex]::Match($body, '(?is)#\s*=+\s*TOOL\s*=+\s*\r?\n(.*?)(?=#\s*=+\s*SMOKE\s*=+|$)')
    $ms = [regex]::Match($body, '(?is)#\s*=+\s*SMOKE\s*=+\s*\r?\n(.*)$')
    if ($mt.Success) { $t = $mt.Groups[1].Value.Trim() }
    if ($ms.Success) { $s = $ms.Groups[1].Value.Trim() }
  } catch {}
  return @{ tool = $t; smoke = $s }
}

function Invoke-AutoToolSmoke {
  # Run a tool's smoke test in an ISOLATED child Windows-PowerShell process, with a timeout
  # and a throwaway working directory (so casual relative-path writes land in scratch, not
  # the repo). NEVER dot-sources untrusted code into the engine. Green iff the child exits 0
  # AND prints the SMOKE_OK sentinel. Returns @{ ok; output; timedOut }. Never throws.
  param([string]$ToolFile, [string]$SmokeCode, [int]$TimeoutSec = 20)
  if ([string]::IsNullOrWhiteSpace($ToolFile) -or -not (Test-Path -LiteralPath $ToolFile)) { return @{ ok=$false; output='tool file missing'; timedOut=$false } }
  if ([string]::IsNullOrWhiteSpace($SmokeCode)) { return @{ ok=$false; output='no smoke test'; timedOut=$false } }
  $enc = New-Object System.Text.UTF8Encoding($false)
  $g   = [guid]::NewGuid().ToString('N').Substring(0,8)
  $sbx = Join-Path $env:TEMP "forge_smoke_$g"
  try { New-Item -ItemType Directory -Path $sbx -Force | Out-Null } catch { return @{ ok=$false; output='cannot create sandbox dir'; timedOut=$false } }
  $runner = Join-Path $sbx 'runner.ps1'
  $outF   = Join-Path $sbx 'out.txt'
  $errF   = Join-Path $sbx 'err.txt'
  $runnerCode = @"
`$ErrorActionPreference = 'Stop'
try {
  . '$ToolFile'
$SmokeCode
  'SMOKE_OK'
} catch {
  Write-Output ('SMOKE_FAIL: ' + `$_.Exception.Message)
  exit 1
}
"@
  try { [System.IO.File]::WriteAllText($runner, $runnerCode, $enc) } catch { try { Remove-Item -LiteralPath $sbx -Recurse -Force -ErrorAction SilentlyContinue } catch {}; return @{ ok=$false; output='cannot write runner'; timedOut=$false } }
  $psExe = $null
  try { $psExe = (Get-Process -Id $PID).Path } catch {}
  if ([string]::IsNullOrWhiteSpace($psExe) -or $psExe -match 'pwsh') { $psExe = 'powershell.exe' }
  $timedOut = $false; $output = ''
  try {
    $p = Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner) `
         -WorkingDirectory $sbx -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
      $timedOut = $true
      try { $p.Kill() } catch {}
      try { $p.WaitForExit(3000) | Out-Null } catch {}
    }
    $exit = if ($timedOut) { -1 } else { try { [int]$p.ExitCode } catch { -1 } }
    try { $output = [string](Get-Content -LiteralPath $outF -Raw -ErrorAction SilentlyContinue) } catch {}
    try { $errTxt = [string](Get-Content -LiteralPath $errF -Raw -ErrorAction SilentlyContinue); if (-not [string]::IsNullOrWhiteSpace($errTxt)) { $output += "`n[stderr] $errTxt" } } catch {}
    $ok = (-not $timedOut) -and ($exit -eq 0) -and ($output -match 'SMOKE_OK')
    return @{ ok=[bool]$ok; output=([string]$output).Trim(); timedOut=$timedOut }
  } catch {
    return @{ ok=$false; output=("smoke harness error: " + $_.Exception.Message); timedOut=$false }
  } finally {
    try { Remove-Item -LiteralPath $sbx -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Get-ForgeBuildPrompt {
  # Build the generation prompt. English on purpose (better code reasoning); the
  # planner-facing registry block stays Russian. $PriorError feeds the retry loop.
  param([string]$Name, [string]$Contract, [string]$EntryPoint, [string]$PriorError = '')
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("Build ONE self-contained Windows PowerShell 5.1 tool.")
  [void]$sb.AppendLine("Tool name: $Name")
  [void]$sb.AppendLine("Public entry function MUST be named exactly: $EntryPoint")
  [void]$sb.AppendLine("Contract (what it must do): $Contract")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("HARD RULES:")
  [void]$sb.AppendLine("- Windows PowerShell 5.1 only: no ternary (a?b:c), no ?? / ?. operators.")
  [void]$sb.AppendLine("- Self-contained: define functions only; NO top-level side effects at load.")
  [void]$sb.AppendLine("- SAFE: no network unless the contract demands it; never Remove-Item / write outside the current directory; no registry, no process kills, no credential access.")
  [void]$sb.AppendLine("- The entry function RETURNS its result (so callers and the smoke test can assert).")
  [void]$sb.AppendLine("- Fail by 'throw', not Write-Error.")
  [void]$sb.AppendLine("")
  [void]$sb.AppendLine("OUTPUT: exactly one ``````powershell block containing BOTH sentinels:")
  [void]$sb.AppendLine('```powershell')
  [void]$sb.AppendLine("# === TOOL ===")
  [void]$sb.AppendLine("function $EntryPoint { param() <# ... #> }")
  [void]$sb.AppendLine("# === SMOKE ===")
  [void]$sb.AppendLine("# assertions that CALL $EntryPoint and 'throw' on any mismatch")
  [void]$sb.AppendLine('```')
  if (-not [string]::IsNullOrWhiteSpace($PriorError)) {
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Your previous attempt FAILED -- fix it. Failure detail:")
    [void]$sb.AppendLine([string]$PriorError)
  }
  return $sb.ToString().TrimEnd()
}

function Get-ForgeCriticPrompt {
  param([string]$Name, [string]$Contract, [string]$ToolCode, [string]$SmokeCode, [string]$SmokeOutput)
  return @"
You are a strict code critic for an autonomous agent that synthesizes PowerShell tools.
The smoke test already PASSED in a sandbox. Your job is to catch what tests miss: destructive
or dangerous operations (deleting/encrypting/moving files outside the current dir, registry
writes, network exfiltration, process kills, credential/secret access), clear contract
mismatch, and obvious correctness bugs.

TOOL NAME: $Name
CONTRACT: $Contract

CODE:
$ToolCode

SMOKE TEST:
$SmokeCode

SMOKE OUTPUT (passed):
$SmokeOutput

Answer on the FIRST line exactly 'VERDICT: APPROVE' or 'VERDICT: REJECT', then one short reason line.
"@
}

function Build-AutoTool {
  # Synthesize + sandbox-test + critique + register a tool. Best-effort; never throws.
  # Returns @{ ok; status; name; entry; reason; attempts; file }.
  #   $Generator (prompt)->raw code text   default: Invoke-LLM with $GenModel
  #   $Critic    (prompt)->verdict text     default: Invoke-LLM critic model (forced != gen)
  # Injecting the callbacks keeps this layer testable offline and lets the driver plug in
  # Codex as the real generator without coupling toolforge.ps1 to driver scope.
  param(
    [string]$Name,
    [string]$Contract,
    [scriptblock]$Generator = $null,
    [scriptblock]$Critic = $null,
    [int]$MaxAttempts = 2,
    [int]$SmokeTimeoutSec = 20,
    [string]$GenModel = 'deepseek-v4-pro'
  )
  $result = @{ ok=$false; status='quarantined'; name=$Name; entry=$null; reason=''; attempts=0; file=$null }
  $n = Test-AutoToolName -Name $Name
  if (-not $n) { $result.reason = 'invalid tool name'; return $result }
  if ([string]::IsNullOrWhiteSpace($Contract)) { $result.reason = 'empty contract'; return $result }
  $entry = "Invoke-$n"
  $result.name = $n; $result.entry = $entry
  $tf = Get-ToolForgeRoot
  if ([string]::IsNullOrWhiteSpace($tf)) { $result.reason = 'no toolforge root'; return $result }
  if (-not (Test-Path -LiteralPath $tf)) { try { New-Item -ItemType Directory -Path $tf -Force | Out-Null } catch {} }
  $finalFile = Join-Path $tf "$n.ps1"
  $enc = New-Object System.Text.UTF8Encoding($false)

  # Default generator/critic via the cheap LLM router. Critic is FORCED onto a different
  # model than the generator (independent review), falling back to the router's fallback.
  if (-not $Generator) {
    $Generator = { param($p) Invoke-LLM -Model $GenModel -Prompt $p -TimeoutSec 180 -Temperature 0.2 }.GetNewClosure()
  }
  if (-not $Critic) {
    $criticModel = $GenModel
    try {
      $cfg = Get-LLMConfig
      $criticModel = [string]$cfg['critic']
      if ([string]::IsNullOrWhiteSpace($criticModel) -or $criticModel -eq $GenModel) { $criticModel = [string]$cfg['fallback'] }
    } catch {}
    $Critic = { param($p) Invoke-LLM -Model $criticModel -Prompt $p -TimeoutSec 120 -Temperature 0.0 }.GetNewClosure()
  }

  Register-AutoTool -Name $n -Contract $Contract -Status 'building' | Out-Null

  $priorErr = ''
  $lastReason = 'build did not start'
  $attempts = [Math]::Max(1, $MaxAttempts)
  for ($i = 1; $i -le $attempts; $i++) {
    $result.attempts = $i
    $prompt = Get-ForgeBuildPrompt -Name $n -Contract $Contract -EntryPoint $entry -PriorError $priorErr
    $raw = $null
    try { $raw = & $Generator $prompt } catch { $raw = $null }
    if ([string]::IsNullOrWhiteSpace($raw)) { $lastReason = 'generator returned empty'; $priorErr = $lastReason; continue }
    $parts = Split-ForgeOutput -Raw ([string]$raw)
    $toolCode  = [string]$parts.tool
    $smokeCode = [string]$parts.smoke
    if ([string]::IsNullOrWhiteSpace($toolCode)) { $lastReason = 'no tool code parsed'; $priorErr = $lastReason; continue }

    $staging = Join-Path $env:TEMP ("forge_stage_" + [guid]::NewGuid().ToString('N').Substring(0,8) + ".ps1")
    try { [System.IO.File]::WriteAllText($staging, $toolCode, $enc) } catch { $lastReason = 'cannot stage tool'; $priorErr = $lastReason; continue }

    # parse-check the staged file
    $pt=$null;$pe=$null
    try { [void][System.Management.Automation.Language.Parser]::ParseFile($staging,[ref]$pt,[ref]$pe) } catch { $pe=$null }
    if ($pe -and $pe.Count -gt 0) {
      $lastReason = 'parse error: ' + ((@($pe) | Select-Object -First 2 | ForEach-Object { $_.Message }) -join '; ')
      $priorErr = $lastReason
      try { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue } catch {}
      continue
    }
    # entry function must actually be defined
    $defsOk = $false
    try { $defsOk = ($toolCode -match ('(?im)^\s*function\s+' + [regex]::Escape($entry) + '\b')) } catch {}
    if (-not $defsOk) {
      $lastReason = "entry function $entry not defined"; $priorErr = $lastReason
      try { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue } catch {}
      continue
    }

    # sandbox smoke (isolated child process + timeout + throwaway cwd)
    $smoke = Invoke-AutoToolSmoke -ToolFile $staging -SmokeCode $smokeCode -TimeoutSec $SmokeTimeoutSec
    if (-not $smoke.ok) {
      $lastReason = if ($smoke.timedOut) { "smoke timed out after ${SmokeTimeoutSec}s" } else { 'smoke red: ' + ([string]$smoke.output) }
      $priorErr = $lastReason
      try { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue } catch {}
      continue
    }

    # critic review (different model). null/empty/non-APPROVE -> fail-closed (quarantine).
    $verdict = $null
    try { $verdict = & $Critic (Get-ForgeCriticPrompt -Name $n -Contract $Contract -ToolCode $toolCode -SmokeCode $smokeCode -SmokeOutput ([string]$smoke.output)) } catch { $verdict = $null }
    $approved = (-not [string]::IsNullOrWhiteSpace($verdict)) -and ([string]$verdict -match '(?im)VERDICT:\s*APPROVE')
    if (-not $approved) {
      $lastReason = 'critic rejected/unavailable: ' + (([string]$verdict).Trim())
      # green-but-unapproved: persist the artifact quarantined for later inspection/promotion
      try {
        [System.IO.File]::WriteAllText($finalFile, $toolCode, $enc)
        Register-AutoTool -Name $n -Contract $Contract -File "tools/auto/$n.ps1" -Status 'quarantined' -SmokeTest $smokeCode -Provenance "gen=$GenModel; attempt=$i" -Critic ([string]$verdict) | Out-Null
      } catch {}
      try { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue } catch {}
      $result.status='quarantined'; $result.reason=$lastReason; $result.file="tools/auto/$n.ps1"
      return $result
    }

    # GREEN + APPROVED -> promote to the live path + register active
    try { [System.IO.File]::WriteAllText($finalFile, $toolCode, $enc) }
    catch { $lastReason = 'failed to write tool file: ' + $_.Exception.Message; try { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue } catch {}; $result.reason=$lastReason; return $result }
    $toolHash = Get-AutoToolFileHash -Path $finalFile
    try { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue } catch {}
    $rec = Register-AutoTool -Name $n -Contract $Contract -File "tools/auto/$n.ps1" -Status 'active' -SmokeTest $smokeCode -Provenance "gen=$GenModel; attempt=$i" -Critic ([string]$verdict) -Sha256 ([string]$toolHash)
    if ($rec) { $result.ok=$true; $result.status='active'; $result.reason='built+smoked+approved'; $result.file="tools/auto/$n.ps1"; return $result }
    $result.reason='register failed'; return $result
  }
  # exhausted attempts -> quarantine record, no live file
  Register-AutoTool -Name $n -Contract $Contract -Status 'quarantined' -Provenance "gen=$GenModel; attempts=$($result.attempts)" -Critic '' | Out-Null
  $result.status='quarantined'; $result.reason=$lastReason
  return $result
}
