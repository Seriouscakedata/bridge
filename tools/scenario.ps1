[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Name,
  [string]$Url = 'http://localhost:8787',
  [int]$Width = 1280,
  [int]$Height = 900,
  [int]$TimeoutSec = 60,
  [int]$KeepBrowserMs = 0,  # extra time to keep browser alive after scenario for screenshots
  [string]$OutDir = ''
)

# tools\scenario.ps1 -- functional verifier runner.
# Spawns headless Edge against $Url?scenario=$Name. The page-side hook in
# web/index.html detects the query param, fetches /tools/scenarios/$Name.js,
# runs it, and POSTs the result to /api/scenario/result. This script then
# polls /api/scenario/result?name=$Name&since=<startTs> until the result
# arrives or $TimeoutSec elapses, prints JSON, and exits with 0 on success
# (result.ok = true) or 1 on failure.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\scenario.ps1 -Name channel-switch
#
# Add new scenarios by dropping <name>.js into tools\scenarios\.

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

function Get-BrowserPath {
  # 2026-05-28: prefer Chrome over Edge. Edge's headless mode aggressively
  # spawns "first-run" / sync-confirmation / extension background pages that
  # steal focus from our target tab; even with --no-first-run + --disable-sync
  # the actual page's JS does not execute consistently. Chrome headless is
  # leaner and runs the page's JS reliably. Edge stays as fallback.
  $candidates = @(
    'C:\Program Files\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
  )
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c -PathType Leaf) { return $c } }
  return ''
}

function Get-LocalAuthUrl {
  param([string]$Original)
  try { $uri = [Uri]$Original } catch { return $Original }
  if ($uri.Scheme -notin @('http','https')) { return $Original }
  if (-not ($uri.IsLoopback -or $uri.Host -in @('localhost','127.0.0.1'))) { return $Original }
  $authPath = Join-Path $root 'auth.json'
  if (-not (Test-Path -LiteralPath $authPath)) { return $Original }
  try {
    $auth = Get-Content -LiteralPath $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$auth.user) -or [string]::IsNullOrWhiteSpace([string]$auth.password)) { return $Original }
    $b = [UriBuilder]$uri
    $b.UserName = [string]$auth.user; $b.Password = [string]$auth.password
    return $b.Uri.AbsoluteUri
  } catch { return $Original }
}

function Get-AuthHeaders {
  $authPath = Join-Path $root 'auth.json'
  if (-not (Test-Path -LiteralPath $authPath)) { return @{} }
  try {
    $auth = Get-Content -LiteralPath $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $auth.user) { return @{} }
    $pair = "$($auth.user):$($auth.password)"
    return @{ Authorization = ('Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pair))) }
  } catch { return @{} }
}

if (-not ($Name -match '^[a-z0-9_-]+$')) {
  Write-Error "Bad scenario name '$Name' (allowed: a-z 0-9 _ -)"
  exit 2
}

$scenarioPath = Join-Path $root ('tools\scenarios\' + $Name + '.js')
if (-not (Test-Path -LiteralPath $scenarioPath -PathType Leaf)) {
  Write-Error "Scenario file not found: $scenarioPath"
  exit 2
}

$browser = Get-BrowserPath
if (-not $browser) { Write-Error 'No Edge/Chrome browser found'; exit 2 }

# Append ?scenario=$Name (preserving auth in URL for headless basic-auth).
$loadUrl = Get-LocalAuthUrl -Original $Url
$sep = if ($loadUrl.Contains('?')) { '&' } else { '?' }
$loadUrl = $loadUrl + $sep + 'scenario=' + [Uri]::EscapeDataString($Name)

# Mark start time so we can ignore older results in the JSONL log.
$startTs = (Get-Date).ToUniversalTime().ToString('o')

# Temp profile dir so Edge doesn't fight a real session.
$profileDir = Join-Path $env:TEMP ('scenario_' + [guid]::NewGuid().ToString('N').Substring(0,8))
[void](New-Item -ItemType Directory -Path $profileDir -Force)

$argsList = @(
  '--headless=new',
  ('--window-size=' + $Width + ',' + $Height),
  '--hide-scrollbars',
  '--no-sandbox',
  '--disable-gpu',
  # 2026-05-28: fresh --user-data-dir triggers Edge first-run welcome
  # AND sync-confirmation dialog AND VPN extension auto-install. Without
  # ALL these flags, Edge spawns multiple background pages and the real
  # tab's JS never gets executed (CDP /json/list confirms the target URL
  # loads correctly, but bootScenario IIFE never runs to completion).
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-extensions',
  '--disable-default-apps',
  '--disable-component-extensions-with-background-pages',
  '--disable-sync',                      # kills the sync-confirmation tab
  '--disable-background-networking',
  '--disable-background-mode',
  '--disable-features=Translate,OptimizationHints,InterestFeed,AcceptCHFrame,FirstRunExperience,EdgeSplashScreenStandalone',
  # 2026-05-28: --virtual-time-budget is THE flag that makes headless actually
  # execute pending JS callbacks (setTimeout/fetch) instead of idling.
  # visit.ps1 uses it for screenshots; we use it to give the scenario time
  # to run. Budget is TimeoutSec*1000, so browser exits after that even if
  # scenario hangs.
  ('--virtual-time-budget=' + ([int]($TimeoutSec * 1000))),
  ('--user-data-dir=' + $profileDir),
  $loadUrl
)

$proc = $null
try {
  $proc = Start-Process -FilePath $browser -ArgumentList $argsList -PassThru -WindowStyle Hidden
} catch {
  Write-Error ('Failed to launch browser: ' + $_.Exception.Message)
  exit 2
}

$headers = Get-AuthHeaders
$resultUrl = ($Url.TrimEnd('/')) + '/api/scenario/result?name=' + [Uri]::EscapeDataString($Name) + '&since=' + [Uri]::EscapeDataString($startTs)
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$result = $null

while ((Get-Date) -lt $deadline) {
  Start-Sleep -Milliseconds 500
  try {
    $resp = Invoke-RestMethod -Uri $resultUrl -Headers $headers -TimeoutSec 5
    if ($resp.ok -and $resp.result) { $result = $resp.result; break }
  } catch {
    # Server may be transiently slow; keep polling.
  }
}

# Optional: keep browser alive for a bit (useful when chained with visit.ps1 for screenshots).
if ($KeepBrowserMs -gt 0) { Start-Sleep -Milliseconds $KeepBrowserMs }

# Teardown.
try { if ($proc -and -not $proc.HasExited) { $proc.Kill() | Out-Null } } catch {}
try { Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}

if (-not $result) {
  $err = [ordered]@{ ok = $false; name = $Name; error = 'timeout: no scenario result after ' + $TimeoutSec + 's' }
  $err | ConvertTo-Json -Compress -Depth 4
  exit 1
}

# Print result as JSON to stdout, exit with code that reflects ok.
$result | ConvertTo-Json -Compress -Depth 6
if ([bool]$result.ok) { exit 0 } else { exit 1 }
