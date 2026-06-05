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

$ok = ($errors.Count -eq 0)
$result = New-Result -Ok $ok -Checks @($checks.ToArray()) -Errors @($errors.ToArray())
$result | ConvertTo-Json -Depth 8 -Compress
if ($ok) { exit 0 }
exit 1
