[CmdletBinding()]
param(
  [string]$Url = 'http://localhost:8787'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$scenarioName = 'features-registry'

function New-Result {
  param(
    [bool]$Ok,
    [object[]]$Checks,
    [string[]]$Errors
  )

  $result = [ordered]@{
    ok = $Ok
    name = $scenarioName
    checks = @($Checks)
  }
  if ($Errors -and $Errors.Count -gt 0) {
    $result.errors = @($Errors)
    $result.error = ($Errors -join '; ')
  }
  return $result
}

function Get-AuthHeaders {
  $privAuth = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.bridge-private\auth.json' } else { '' }
  $authPath = if ($privAuth -and (Test-Path -LiteralPath $privAuth)) { $privAuth } else { Join-Path $root 'auth.json' }
  if (-not (Test-Path -LiteralPath $authPath)) { return @{} }

  try {
    $auth = Get-Content -LiteralPath $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $auth.user) { return @{} }
    $pair = "$($auth.user):$($auth.password)"
    return @{ Authorization = ('Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pair))) }
  } catch {
    return @{}
  }
}

function Invoke-RegistryGetJson {
  param(
    [string]$Path,
    [hashtable]$Headers
  )

  $uri = $Url.TrimEnd('/') + $Path
  $item = [ordered]@{
    path = $Path
    status = $null
    ok = $false
  }

  try {
    $resp = Invoke-WebRequest -Uri $uri -Headers $Headers -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    $item.status = [int]$resp.StatusCode
    $json = $resp.Content | ConvertFrom-Json
    $item.ok = ($item.status -eq 200)
    return [pscustomobject]@{ Check = $item; Json = $json }
  } catch {
    $status = $null
    try {
      if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    } catch {}
    $item.status = $status
    $item.error = $_.Exception.Message
    return [pscustomobject]@{ Check = $item; Json = $null }
  }
}

function Test-RegistryPlaceholderFunction {
  # Honest placeholders (not bare function names) are intentionally not validated
  # against live code: e.g. '(critic block)', '(task_mode=discuss)',
  # '/api/health handler', 'boot resume block', '(CONTINUE-CHUNK)', 'meta',
  # '(GET /api/runbook)', 'Update-State (session_mission init on task-start)'.
  param([string]$OwnerFunction)
  $fn = ([string]$OwnerFunction).Trim()
  if (-not $fn) { return $true }
  if ($fn -eq 'meta') { return $true }
  # Anything containing whitespace, parentheses or a slash is a descriptive
  # placeholder rather than a bare callable identifier.
  if ($fn -match '[\s()/]') { return $true }
  return $false
}

function Get-RegistrySourceFiles {
  # One-time list of the bridge's own PowerShell source files (top-level scripts
  # + lib/ + driver/ + tools/). Scoped deliberately: a repo-wide -Recurse over
  # the whole tree is slow on OneDrive and would also match stale copies inside
  # sibling worktrees (bridge-canary-worktree). Used as the fallback corpus when
  # a function lives in a file other than its cited owner_files.
  param([string]$Root)
  $files = New-Object 'System.Collections.Generic.List[string]'
  try {
    Get-ChildItem -LiteralPath $Root -File -Filter '*.ps1' -ErrorAction SilentlyContinue |
      ForEach-Object { $files.Add($_.FullName) }
  } catch {}
  foreach ($sub in @('lib','driver','tools')) {
    $subDir = Join-Path $Root $sub
    if (-not (Test-Path -LiteralPath $subDir -PathType Container)) { continue }
    try {
      Get-ChildItem -LiteralPath $subDir -Recurse -File -Include '*.ps1','*.psm1' -ErrorAction SilentlyContinue |
        ForEach-Object { $files.Add($_.FullName) }
    } catch {}
  }
  return $files.ToArray()
}

function Test-RegistryFunctionDefined {
  # A citation is LIVE if the owner_function is grep-findable as a
  # 'function <Name>' definition in the bridge source, OR (to tolerate
  # non-PowerShell symbols such as JS consts cited from web/index.html) the
  # bare symbol appears at all inside one of its own owner_files.
  param(
    [string]$Root,
    [string]$OwnerFunction,
    [string[]]$OwnerFiles,
    [string[]]$SourceFiles
  )
  $fn = ([string]$OwnerFunction).Trim()
  if (-not $fn) { return $false }
  $escaped = [regex]::Escape($fn)
  $defPattern = '(?m)^\s*function\s+' + $escaped + '\b'
  $symPattern = '\b' + $escaped + '\b'

  foreach ($rel in @($OwnerFiles)) {
    if (-not $rel) { continue }
    $full = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    try {
      $content = Get-Content -LiteralPath $full -Raw -Encoding UTF8 -ErrorAction Stop
    } catch { continue }
    if ($content -match $defPattern) { return $true }
    if ($content -match $symPattern) { return $true }
  }

  # Fall back to a scoped search for a real 'function <Name>' definition
  # (function may live in a source file other than the cited owner_files).
  foreach ($src in @($SourceFiles)) {
    if (-not $src) { continue }
    try {
      $content = Get-Content -LiteralPath $src -Raw -Encoding UTF8 -ErrorAction Stop
    } catch { continue }
    if ($content -match $defPattern) { return $true }
  }

  return $false
}

$checks = New-Object 'System.Collections.Generic.List[object]'
$errors = New-Object 'System.Collections.Generic.List[string]'
$headers = Get-AuthHeaders

$featuresCall = Invoke-RegistryGetJson -Path '/api/features' -Headers $headers
$checks.Add($featuresCall.Check)

if ($featuresCall.Check.status -ne 200) {
  $errors.Add("GET /api/features returned status $($featuresCall.Check.status)")
} elseif (-not $featuresCall.Json.ok) {
  $errors.Add('GET /api/features returned ok != true')
}

$features = @()
if ($featuresCall.Json -and $featuresCall.Json.PSObject.Properties.Name -contains 'features') {
  $features = @($featuresCall.Json.features)
}

$featuresCheck = [ordered]@{
  path = '/api/features'
  assertion = 'features count >= 20'
  count = $features.Count
  ok = ($features.Count -ge 20)
}
$checks.Add($featuresCheck)
if (-not $featuresCheck.ok) {
  $errors.Add("GET /api/features returned $($features.Count) features, expected at least 20")
}

$requiredKeys = @('id','name','description','owner_files','layer','status')
$schemaMissing = New-Object 'System.Collections.Generic.List[object]'
foreach ($feature in $features) {
  $props = @()
  if ($feature -and $feature.PSObject) { $props = @($feature.PSObject.Properties.Name) }
  $missing = @($requiredKeys | Where-Object { $props -notcontains $_ })
  if ($missing.Count -gt 0) {
    $schemaMissing.Add([ordered]@{ id = [string]$feature.id; missing = @($missing) })
  }
}
$schemaCheck = [ordered]@{
  path = '/api/features'
  assertion = 'schema keys present'
  required_keys = @($requiredKeys)
  missing = @($schemaMissing.ToArray())
  ok = ($schemaMissing.Count -eq 0)
}
$checks.Add($schemaCheck)
if (-not $schemaCheck.ok) {
  $errors.Add('GET /api/features has features missing required schema keys')
}

$ids = @($features | ForEach-Object { [string]$_.id })
$expectedIds = @('auditor','doctor','intent-classifier','scenario-runner','channel-switch')
$missingIds = @($expectedIds | Where-Object { $ids -notcontains $_ })
$idsCheck = [ordered]@{
  path = '/api/features'
  assertion = 'expected feature ids present'
  expected_ids = @($expectedIds)
  missing_ids = @($missingIds)
  ok = ($missingIds.Count -eq 0)
}
$checks.Add($idsCheck)
if (-not $idsCheck.ok) {
  $errors.Add('GET /api/features is missing expected ids: ' + ($missingIds -join ', '))
}

$auditorCall = Invoke-RegistryGetJson -Path '/api/features/auditor' -Headers $headers
$checks.Add($auditorCall.Check)
if ($auditorCall.Check.status -ne 200) {
  $errors.Add("GET /api/features/auditor returned status $($auditorCall.Check.status)")
} elseif ([string]$auditorCall.Json.id -ne 'auditor') {
  $errors.Add("GET /api/features/auditor returned id '$($auditorCall.Json.id)', expected 'auditor'")
}

# --- Dead-citation validation ---------------------------------------------
# Structural root check: the registry can drift GREEN while owner_function /
# owner_files point at code that no longer exists. Validate each non-placeholder
# entry against the on-disk repo so the verdict goes RED when the registry rots.
$registryPath = Join-Path $root 'features/registry.json'
$registryEntries = @()
$registrySource = 'file'
if (Test-Path -LiteralPath $registryPath -PathType Leaf) {
  try {
    # PS5.1 gotcha: `@(ConvertFrom-Json ...)` of a top-level JSON array yields a
    # 1-element array whose single element is the nested Object[]. Assign to a
    # plain variable FIRST (which unrolls it), then wrap with @() on a separate
    # statement so we iterate real entries.
    $registryRaw = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8
    $registryParsed = ConvertFrom-Json -InputObject $registryRaw
    $registryEntries = @($registryParsed)
  } catch {
    $registryEntries = @()
  }
}
if ($registryEntries.Count -eq 0 -and $features.Count -gt 0) {
  # Fall back to the served features when the on-disk file is unreadable.
  $registryEntries = @($features)
  $registrySource = 'api'
}

$sourceFiles = @(Get-RegistrySourceFiles -Root $root)
$missingFiles = New-Object 'System.Collections.Generic.List[object]'
$deadFunctions = New-Object 'System.Collections.Generic.List[object]'
foreach ($entry in $registryEntries) {
  if (-not $entry -or -not $entry.PSObject) { continue }
  $entryId = [string]$entry.id
  $ownerFiles = @()
  if ($entry.PSObject.Properties.Name -contains 'owner_files') {
    $ownerFiles = @($entry.owner_files | ForEach-Object { [string]$_ } | Where-Object { $_ })
  }
  $ownerFn = ''
  if ($entry.PSObject.Properties.Name -contains 'owner_function') {
    $ownerFn = [string]$entry.owner_function
  }

  # (a) every owner_files path must exist on disk
  foreach ($rel in $ownerFiles) {
    $full = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $full)) {
      $missingFiles.Add([ordered]@{ id = $entryId; owner_file = $rel })
    }
  }

  # (b) non-placeholder owner_function must be grep-findable in live code
  if (-not (Test-RegistryPlaceholderFunction -OwnerFunction $ownerFn)) {
    if (-not (Test-RegistryFunctionDefined -Root $root -OwnerFunction $ownerFn -OwnerFiles $ownerFiles -SourceFiles $sourceFiles)) {
      $deadFunctions.Add([ordered]@{ id = $entryId; owner_function = $ownerFn.Trim(); owner_files = @($ownerFiles) })
    }
  }
}

$citationCheck = [ordered]@{
  path = $registryPath
  assertion = 'registry owner_files exist and owner_function is defined in live code'
  source = $registrySource
  entries_scanned = $registryEntries.Count
  missing_owner_files = @($missingFiles.ToArray())
  dead_owner_functions = @($deadFunctions.ToArray())
  ok = (($missingFiles.Count -eq 0) -and ($deadFunctions.Count -eq 0))
}
$checks.Add($citationCheck)
if (-not $citationCheck.ok) {
  if ($missingFiles.Count -gt 0) {
    $errors.Add("registry has $($missingFiles.Count) owner_files path(s) missing on disk: " + (($missingFiles | ForEach-Object { "$($_.id)->$($_.owner_file)" }) -join ', '))
  }
  if ($deadFunctions.Count -gt 0) {
    $errors.Add("registry has $($deadFunctions.Count) dead owner_function citation(s) not found in live code: " + (($deadFunctions | ForEach-Object { "$($_.id)->$($_.owner_function)" }) -join ', '))
  }
}

$ok = ($errors.Count -eq 0)
$result = New-Result -Ok $ok -Checks @($checks.ToArray()) -Errors @($errors.ToArray())
$result | ConvertTo-Json -Depth 8 -Compress
if ($ok) { exit 0 }
exit 1
