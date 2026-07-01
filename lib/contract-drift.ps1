# ==============================================================================
# lib/contract-drift.ps1
#   Гл4 diffusion hardening: deterministic post-stitch contract-drift gate +
#   orphan-stub detection. All comparison logic is PURE (no I/O, no timestamps,
#   never throws) so it is fully unit-testable; the two -Stitch/-ProjectRoot
#   entry points add the thin file/backlog I/O the driver wiring calls.
#
# WHY: on the diffusion path a CONSUMER atom builds against a FROZEN interface
# stub while its PROVIDER is built in parallel; the STITCH atom then wires the
# real provider and must re-verify. Without a machine check, "re-verify" is only
# prose in the stitch task -- a provider that quietly dropped/renamed an interface
# method could ship consumers against a stale stub (false-green). This gate makes
# the check deterministic: every interface method the frozen contract DECLARED
# must be DEFINED in the real provider file, else the stitch is drifted -> rejected.
# Method-NAME presence (not full signature) is asserted on purpose: name removal/
# rename is the meaningful contract break; parameter/type drift is caught by the
# integration build the stitch already runs. Empty-method (synthesized/minimal)
# contracts assert nothing here -- the build stays their backstop.
# ==============================================================================

function Test-ProjectAutopilotContractSymbolPresent {
  # PURE. Is interface symbol $Symbol DEFINED in provider source $Content for $Language?
  # Presence-only, definition-shaped (not a mere substring) to avoid matching a comment/call.
  param([string]$Symbol, [string]$Content, [string]$Language = 'generic')
  if ([string]::IsNullOrWhiteSpace($Symbol) -or [string]::IsNullOrEmpty($Content)) { return $false }
  $name = ([string]$Symbol).Trim()
  # if the manifest carried a full signature (e.g. "apply(self, text)"), reduce to the leading identifier
  $m = [regex]::Match($name, '^[A-Za-z_][A-Za-z0-9_]*')
  if ($m.Success) { $name = $m.Value }
  if ([string]::IsNullOrWhiteSpace($name)) { return $false }
  $e = [regex]::Escape($name)
  $lang = ([string]$Language).Trim().ToLowerInvariant()
  try {
    switch ($lang) {
      'python'     { return [bool]([regex]::IsMatch($Content, '(?m)^\s*(async\s+)?def\s+' + $e + '\s*\(')) }
      'kotlin'     { return [bool]([regex]::IsMatch($Content, '(?m)\b(fun(\s*<[^>]*>)?|val|var)\s+' + $e + '\b')) }
      'typescript' { return [bool]([regex]::IsMatch($Content, '(?m)(\b' + $e + '\s*\??\s*[\(:=<]|\bfunction\s+' + $e + '\b)')) }
      default      { return [bool]([regex]::IsMatch($Content, '\b' + $e + '\b')) }
    }
  } catch { return $false }
}

function Test-ProjectAutopilotContractDrift {
  # PURE. Given the interface method names a contract FROZE and the real provider source, decide drift.
  # Returns @{ drifted; missing=@(); checked=@(); reason }. NEVER throws. No declared methods -> not
  # drifted (nothing machine-checkable; the integration build is the backstop for such thin contracts).
  param([string[]]$Methods = @(), [string]$ProviderContent = '', [string]$Language = 'generic')
  $checked = New-Object 'System.Collections.Generic.List[string]'
  $missing = New-Object 'System.Collections.Generic.List[string]'
  foreach ($m in @($Methods)) {
    $name = ([string]$m).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    [void]$checked.Add($name)
    if (-not (Test-ProjectAutopilotContractSymbolPresent -Symbol $name -Content $ProviderContent -Language $Language)) {
      [void]$missing.Add($name)
    }
  }
  $drifted = ($missing.Count -gt 0)
  $reason = if ($drifted) { 'missing interface methods in real provider: ' + (($missing.ToArray()) -join ', ') } else { '' }
  return [pscustomobject]@{ drifted = [bool]$drifted; missing = @($missing.ToArray()); checked = @($checked.ToArray()); reason = $reason }
}

function Test-ProjectAutopilotStitchManifestDrift {
  # I/O wrapper called from the driver DONE-gate for a stitch atom. Reads the stitch manifest that shaping
  # persisted ({contracts:[{id, provider_file, language, methods}]}), loads each real provider file, and
  # runs the pure drift core. A MISSING provider file is itself a drift (the stitch did not produce the
  # real provider -> consumers would ship against the stub). Returns @{ ok; drifts=@(); checked_contracts;
  # reason }. NEVER throws; a fault degrades to ok=$true (fail-open) so a manifest/read glitch can never
  # wedge a real stitch -- the driver's 2-strike cap + integration build remain the outer guards.
  param([string]$ManifestPath, [string]$ProjectRoot)
  $drifts = New-Object 'System.Collections.Generic.List[object]'
  $checkedContracts = 0
  try {
    if ([string]::IsNullOrWhiteSpace($ManifestPath) -or -not (Test-Path -LiteralPath $ManifestPath)) {
      return [pscustomobject]@{ ok = $true; drifts = @(); checked_contracts = 0; reason = 'no-manifest' }
    }
    $manifest = $null
    try { $manifest = Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { return [pscustomobject]@{ ok = $true; drifts = @(); checked_contracts = 0; reason = 'manifest-unreadable' } }
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { try { $ProjectRoot = [string]$manifest.project_root } catch {} }
    # Without a project root we cannot resolve provider files -> every one would look 'missing' and fail the
    # stitch closed. Fail-OPEN instead (the integration build the stitch already runs remains the backstop).
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return [pscustomobject]@{ ok = $true; drifts = @(); checked_contracts = 0; reason = 'no-project-root' } }
    $contracts = @()
    try { $contracts = @($manifest.contracts) } catch { $contracts = @() }
    foreach ($c in @($contracts)) {
      $id = ''
      $providerRel = ''
      $language = 'generic'
      $methods = @()
      try { $id = [string]$c.id } catch {}
      try { $providerRel = [string]$c.provider_file } catch {}
      try { $language = [string]$c.language } catch {}
      try { $methods = @($c.methods | ForEach-Object { [string]$_ }) } catch { $methods = @() }
      if ([string]::IsNullOrWhiteSpace($providerRel)) { continue }
      $checkedContracts++
      $full = $providerRel
      try { if (-not [System.IO.Path]::IsPathRooted($providerRel)) { $full = Join-Path $ProjectRoot ($providerRel -replace '/', [System.IO.Path]::DirectorySeparatorChar) } } catch {}
      if (-not (Test-Path -LiteralPath $full)) {
        [void]$drifts.Add([pscustomobject]@{ id = $id; provider_file = $providerRel; reason = 'provider-file-missing'; missing = @($methods) })
        continue
      }
      $content = ''
      try { $content = Get-Content -LiteralPath $full -Raw -ErrorAction Stop } catch { $content = '' }
      $d = Test-ProjectAutopilotContractDrift -Methods $methods -ProviderContent $content -Language $language
      if ([bool]$d.drifted) {
        [void]$drifts.Add([pscustomobject]@{ id = $id; provider_file = $providerRel; reason = [string]$d.reason; missing = @($d.missing) })
      }
    }
  } catch {
    return [pscustomobject]@{ ok = $true; drifts = @(); checked_contracts = 0; reason = 'drift-check-fault-failopen' }
  }
  return [pscustomobject]@{ ok = ($drifts.Count -eq 0); drifts = @($drifts.ToArray()); checked_contracts = [int]$checkedContracts; reason = $(if ($drifts.Count -gt 0) { 'contract-drift' } else { 'ok' }) }
}

function Get-ProjectAutopilotOrphanStubResult {
  # PURE. Given the relative stub paths on disk and the current backlog, classify which stubs are ORPHANS.
  # A stub is orphan iff NO ACTIVE atom (status NOT terminal) still owns it in its 'files'. Terminal =
  # {done, auto-resolved, failed, rejected, dropped}. 'held' is treated as ACTIVE (conservative -- a
  # recovering held marker/stitch may still need its stub; never remove a stub a live atom might use).
  # Returns @{ orphans=@(); active_owned=@() }. Never throws.
  param([string[]]$StubRelPaths = @(), $Backlog = @())
  $terminal = @{ 'done'=$true; 'auto-resolved'=$true; 'failed'=$true; 'rejected'=$true; 'dropped'=$true }
  $activeOwned = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($item in @($Backlog)) {
    $st = ''
    try { $st = ([string](Get-BacklogPackObjectValue -Obj $item -Name 'status' -Default '')).Trim().ToLowerInvariant() } catch { $st = '' }
    if ($terminal.ContainsKey($st)) { continue }
    $files = @()
    try { $files = @(Get-BacklogPackObjectValue -Obj $item -Name 'files' -Default @()) } catch { $files = @() }
    foreach ($f in @($files)) {
      $fn = ((([string]$f).Trim() -replace '\\','/') -replace '^\./','')
      if ([string]::IsNullOrWhiteSpace($fn)) { continue }
      [void]$activeOwned.Add($fn)
    }
  }
  $orphans = New-Object 'System.Collections.Generic.List[string]'
  foreach ($p in @($StubRelPaths)) {
    $pn = ((([string]$p).Trim() -replace '\\','/') -replace '^\./','')
    if ([string]::IsNullOrWhiteSpace($pn)) { continue }
    if (-not $activeOwned.Contains($pn)) { [void]$orphans.Add($pn) }
  }
  return [pscustomobject]@{ orphans = @($orphans.ToArray()); active_owned = @($activeOwned) }
}

function Get-ProjectAutopilotOrphanStubs {
  # I/O wrapper: enumerate <ProjectRoot>/.bridge/stubs/** and classify orphans against the live backlog.
  # -Action 'detect' (default) only reports; 'cleanup' additionally REMOVES orphan files (leaked stubs
  # whose owning stitch is done/absent -- safe because no active atom references them). Cleanup is NOT
  # auto-wired yet (the live path commits/dirties the project worktree); detect-mode surfaces telemetry
  # while B1 strand-hold surfaces the root cause to the operator. NEVER throws.
  param([string]$ProjectRoot, $Backlog = $null, [string]$Action = 'detect')
  try {
    if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return [pscustomobject]@{ orphans=@(); removed=@(); scanned=0; action=$Action } }
    $stubDir = Join-Path $ProjectRoot '.bridge/stubs'
    if (-not (Test-Path -LiteralPath $stubDir)) { return [pscustomobject]@{ orphans=@(); removed=@(); scanned=0; action=$Action } }
    if ($null -eq $Backlog) { try { $Backlog = @(Get-Backlog) } catch { $Backlog = @() } }
    $files = @()
    try { $files = @(Get-ChildItem -LiteralPath $stubDir -Recurse -File -ErrorAction SilentlyContinue) } catch { $files = @() }
    $rootFull = ''
    try { $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot) } catch { $rootFull = $ProjectRoot }
    $relPaths = New-Object 'System.Collections.Generic.List[string]'
    $relToFull = @{}
    foreach ($f in @($files)) {
      $rel = $f.FullName
      try { if ($f.FullName.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { $rel = $f.FullName.Substring($rootFull.Length).TrimStart('\','/') } } catch {}
      $rel = ($rel -replace '\\','/')
      [void]$relPaths.Add($rel)
      $relToFull[$rel] = $f.FullName
    }
    $res = Get-ProjectAutopilotOrphanStubResult -StubRelPaths @($relPaths.ToArray()) -Backlog $Backlog
    $orphans = @($res.orphans)
    $removed = New-Object 'System.Collections.Generic.List[string]'
    if (([string]$Action).Trim().ToLowerInvariant() -eq 'cleanup') {
      foreach ($o in @($orphans)) {
        if ($relToFull.ContainsKey($o)) {
          try { Remove-Item -LiteralPath $relToFull[$o] -Force -ErrorAction Stop; [void]$removed.Add($o) } catch {}
        }
      }
    }
    return [pscustomobject]@{ orphans = @($orphans); removed = @($removed.ToArray()); scanned = [int]$relPaths.Count; action = $Action }
  } catch {
    return [pscustomobject]@{ orphans=@(); removed=@(); scanned=0; action=$Action }
  }
}

function Get-ProjectAutopilotStitchManifestDir {
  # Channel-local runtime dir for stitch manifests -- NOT the project worktree, so the drift-gate metadata
  # never dirties/pollutes the project git tree (same rationale as the Гл1 wave-schedule sidecar).
  param([string]$Channel)
  try {
    $bridgeRoot = ''
    if (Get-Command Get-BridgeRoot -ErrorAction SilentlyContinue) { $bridgeRoot = [string](Get-BridgeRoot) }
    if ([string]::IsNullOrWhiteSpace($bridgeRoot)) { return '' }
    return (Join-Path (Join-Path (Join-Path $bridgeRoot 'channels') ([string]$Channel)) 'stitch-manifest')
  } catch { return '' }
}

function Get-ProjectAutopilotStitchManifestPath {
  # Resolve an existing stitch manifest by the stitch atom's slug; '' when absent.
  param([string]$StitchSlug, [string]$Channel)
  try {
    if ([string]::IsNullOrWhiteSpace($StitchSlug)) { return '' }
    $dir = Get-ProjectAutopilotStitchManifestDir -Channel $Channel
    if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
    $path = Join-Path $dir ($StitchSlug + '.json')
    if (Test-Path -LiteralPath $path) { return $path }
    return ''
  } catch { return '' }
}

function Write-ProjectAutopilotStitchManifest {
  # Persist the stitch manifest the driver DONE-gate reads: for each STABLE (frozen-this-tick) contract,
  # record { id, provider_file, language, methods } so the gate can deterministically re-verify the real
  # provider against the frozen interface. Written to the channel-local dir (see above). project_root is
  # stored inside so the drift reader can resolve provider files. NEVER throws; returns the path or ''.
  param([string]$StitchSlug, $Contracts = @(), $FreezeManifest = $null, [string]$ProjectRoot, [string]$Channel)
  try {
    if ([string]::IsNullOrWhiteSpace($StitchSlug)) { return '' }
    $dir = Get-ProjectAutopilotStitchManifestDir -Channel $Channel
    if ([string]::IsNullOrWhiteSpace($dir)) { return '' }
    # language by freeze-manifest entry (authoritative) else provider-file extension
    $langById = @{}
    try {
      foreach ($fc in @($FreezeManifest.contracts)) {
        $fid = [string](Get-BacklogPackObjectValue -Obj $fc -Name 'id' -Default '')
        $flang = [string](Get-BacklogPackObjectValue -Obj $fc -Name 'generated_stub_language' -Default '')
        if (-not [string]::IsNullOrWhiteSpace($fid) -and -not [string]::IsNullOrWhiteSpace($flang)) { $langById[$fid.ToLowerInvariant()] = $flang }
      }
    } catch {}
    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in @($Contracts)) {
      $stable = $false
      try { $stable = [bool](Get-BacklogPackObjectValue -Obj $c -Name 'stable' -Default $false) } catch { $stable = $false }
      if (-not $stable) { continue }
      $id = [string](Get-BacklogPackObjectValue -Obj $c -Name 'id' -Default '')
      if ([string]::IsNullOrWhiteSpace($id)) { continue }
      $ownedFiles = @()
      try { $ownedFiles = @(Get-BacklogPackObjectValue -Obj $c -Name 'owned_files' -Default @()) } catch { $ownedFiles = @() }
      $provider = if (@($ownedFiles).Count -gt 0) { [string]@($ownedFiles)[0] } else { '' }
      if ([string]::IsNullOrWhiteSpace($provider)) { continue }
      $lang = ''
      if ($langById.ContainsKey($id.ToLowerInvariant())) { $lang = $langById[$id.ToLowerInvariant()] }
      if ([string]::IsNullOrWhiteSpace($lang)) {
        $ext = ''
        try { $ext = [System.IO.Path]::GetExtension($provider).ToLowerInvariant() } catch { $ext = '' }
        $lang = switch ($ext) { '.py' {'python'} '.kt' {'kotlin'} '.kts' {'kotlin'} '.ts' {'typescript'} '.tsx' {'typescript'} default {'generic'} }
      }
      # The processed interface-contract object (Get-ProjectAutopilotInterfaceContracts) does NOT carry a
      # top-level 'signature' -- the raw contract (with signature.abstract_methods) is nested under '.contract'
      # (backlog-autopilot.ps1:658). Read top-level first (synthesized/flat shapes), then fall back to the
      # nested raw. Without this the manifest records methods:[] and the A2 drift gate is inert.
      $sig = $null
      try { $sig = Get-BacklogPackObjectValue -Obj $c -Name 'signature' -Default $null } catch { $sig = $null }
      if ($null -eq $sig) {
        try {
          $innerContract = Get-BacklogPackObjectValue -Obj $c -Name 'contract' -Default $null
          if ($null -ne $innerContract) { $sig = Get-BacklogPackObjectValue -Obj $innerContract -Name 'signature' -Default $null }
        } catch {}
      }
      $rawMethods = @()
      try { $rawMethods = @(Get-BacklogPackObjectValue -Obj $sig -Name 'abstract_methods' -Default @()) } catch { $rawMethods = @() }
      if (@($rawMethods).Count -eq 0) { try { $rawMethods = @(Get-BacklogPackObjectValue -Obj $sig -Name 'methods' -Default @()) } catch { $rawMethods = @() } }
      $methodNames = New-Object 'System.Collections.Generic.List[string]'
      foreach ($mm in @($rawMethods)) {
        $mn = ''
        if ($mm -is [string]) { $mn = [string]$mm }
        else {
          try { $mn = [string](Get-BacklogPackObjectValue -Obj $mm -Name 'name' -Default '') } catch { $mn = '' }
          if ([string]::IsNullOrWhiteSpace($mn)) { try { $mn = [string](Get-BacklogPackObjectValue -Obj $mm -Name 'signature' -Default '') } catch { $mn = '' } }
        }
        $mn = ([string]$mn).Trim()
        if (-not [string]::IsNullOrWhiteSpace($mn)) { [void]$methodNames.Add($mn) }
      }
      [void]$entries.Add([ordered]@{ id = $id; provider_file = $provider; language = $lang; methods = @($methodNames.ToArray()) })
    }
    $manifest = [ordered]@{ schema_version = 1; stitch_slug = $StitchSlug; project_root = [string]$ProjectRoot; channel = [string]$Channel; contracts = @($entries.ToArray()) }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $path = Join-Path $dir ($StitchSlug + '.json')
    [System.IO.File]::WriteAllText($path, ($manifest | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    return $path
  } catch { return '' }
}
