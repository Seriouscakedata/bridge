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
  $paths = @(Get-BrowserPaths)
  if ($paths.Count -gt 0) { return [string]$paths[0] }
  return ''
}

function Get-BrowserPaths {
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
  $found = @()
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c -PathType Leaf) { $found += $c } }
  return $found
}

function Get-LocalAuthUrl {
  param([string]$Original)
  try { $uri = [Uri]$Original } catch { return $Original }
  if ($uri.Scheme -notin @('http','https')) { return $Original }
  if (-not ($uri.IsLoopback -or $uri.Host -in @('localhost','127.0.0.1'))) { return $Original }
  $privAuth = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.bridge-private\auth.json' } else { '' }
  $authPath = if ($privAuth -and (Test-Path $privAuth)) { $privAuth } else { Join-Path $root 'auth.json' }
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
  # auth.json lives in the protected store outside the bridge (Ф0.4); fall back to legacy in-bridge path.
  $privAuth = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.bridge-private\auth.json' } else { '' }
  $authPath = if ($privAuth -and (Test-Path $privAuth)) { $privAuth } else { Join-Path $root 'auth.json' }
  if (-not (Test-Path -LiteralPath $authPath)) { return @{} }
  try {
    $auth = Get-Content -LiteralPath $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $auth.user) { return @{} }
    $pair = "$($auth.user):$($auth.password)"
    return @{ Authorization = ('Basic ' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($pair))) }
  } catch { return @{} }
}

function Get-RedactedUrl {
  param([string]$Original)
  try {
    $u = [UriBuilder]$Original
    if (-not [string]::IsNullOrEmpty($u.UserName) -or -not [string]::IsNullOrEmpty($u.Password)) {
      $u.UserName = ''
      $u.Password = ''
    }
    return $u.Uri.AbsoluteUri
  } catch {
    return $Original
  }
}

function ConvertTo-RedactedArgument {
  param([string]$Arg)
  if ($Arg -match '^https?://') { return (Get-RedactedUrl -Original $Arg) }
  return $Arg
}

function Write-ScenarioDiagnostics {
  param(
    [string]$Path,
    [hashtable]$Data
  )
  try {
    $Data.updated_at = (Get-Date).ToUniversalTime().ToString('o')
    $json = $Data | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
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
$browserPaths = @(Get-BrowserPaths)

# Append ?scenario=$Name (preserving auth in URL for headless basic-auth).
$loadUrl = Get-LocalAuthUrl -Original $Url
$sep = if ($loadUrl.Contains('?')) { '&' } else { '?' }
$loadUrl = $loadUrl + $sep + 'scenario=' + [Uri]::EscapeDataString($Name)

# Mark start time so we can ignore older results in the JSONL log.
$startTs = (Get-Date).ToUniversalTime().ToString('o')

# Temp profile dir so Edge/Chrome doesn't fight a real session.
# Keep it under the bridge runtime tree: sandboxed runs may not have a usable
# Crashpad/profile location under LocalAppData or %TEMP%.
$scenarioRuntimeDir = Join-Path $root 'runtime\scenario'
[void](New-Item -ItemType Directory -Path $scenarioRuntimeDir -Force)
$scenarioProfileRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'bridge-scenario-runtime'
try {
  [void](New-Item -ItemType Directory -Path $scenarioProfileRoot -Force)
} catch {
  $scenarioProfileRoot = $scenarioRuntimeDir
}
$logDir = Join-Path $scenarioRuntimeDir 'logs'
[void](New-Item -ItemType Directory -Path $logDir -Force)
$runId = ($Name + '_' + (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '_' + [guid]::NewGuid().ToString('N').Substring(0,6))
$diagPath = Join-Path $logDir ($runId + '.diagnostics.json')
$diag = @{
  run_id = $runId
  name = $Name
  browser_path = $browser
  browser_paths = @($browserPaths)
  load_url = (Get-RedactedUrl -Original $loadUrl)
  result_url = (Get-RedactedUrl -Original (($Url.TrimEnd('/')) + '/api/scenario/result?name=' + [Uri]::EscapeDataString($Name)))
  attempts = @()
}

$headers = Get-AuthHeaders
$resultUrl = ($Url.TrimEnd('/')) + '/api/scenario/result?name=' + [Uri]::EscapeDataString($Name) + '&since=' + [Uri]::EscapeDataString($startTs)
$debugName = 'debug-boot-' + $Name
$debugUrl = ($Url.TrimEnd('/')) + '/api/scenario/result?name=' + [Uri]::EscapeDataString($debugName) + '&since=' + [Uri]::EscapeDataString($startTs)
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$result = $null
$debugMarker = $null
$lastProc = $null
$lastProfileDir = ''

$modes = @('headless', 'headed-offscreen')
foreach ($browserCandidate in $browserPaths) {
foreach ($mode in $modes) {
  if ((Get-Date) -ge $deadline) { break }
  if ($mode -eq 'headed-offscreen' -and $debugMarker) { break }

  $browserTag = ([IO.Path]::GetFileNameWithoutExtension($browserCandidate) -replace '[^a-zA-Z0-9_-]', '_')
  $attemptId = $runId + '_' + $browserTag + '_' + $mode
  $profileDir = Join-Path $scenarioProfileRoot ('scenario_' + [guid]::NewGuid().ToString('N').Substring(0,8))
  [void](New-Item -ItemType Directory -Path $profileDir -Force)
  $crashDir = Join-Path $profileDir 'crash'
  [void](New-Item -ItemType Directory -Path $crashDir -Force)
  $stdoutPath = Join-Path $logDir ($attemptId + '.browser.stdout.log')
  $stderrPath = Join-Path $logDir ($attemptId + '.browser.stderr.log')

  $argsList = @()
  if ($mode -eq 'headless') { $argsList += '--headless=new' } else { $argsList += '--window-position=-32000,-32000' }
  $argsList += @(
    ('--window-size=' + $Width + ',' + $Height),
    '--hide-scrollbars',
    '--no-sandbox',
    '--disable-gpu',
    # 2026-05-28: fresh --user-data-dir triggers Edge first-run welcome
    # AND sync-confirmation dialog AND VPN extension auto-install. Without
    # ALL these flags, Edge spawns multiple background pages and the real
    # tab's JS does not execute consistently.
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-extensions',
    '--disable-default-apps',
    '--disable-component-extensions-with-background-pages',
    '--disable-sync',
    '--disable-background-networking',
    '--disable-background-mode',
    '--disable-breakpad',
    '--disable-crash-reporter',
    '--disable-crashpad',
    ('--crash-dumps-dir=' + $crashDir),
    '--disable-features=Translate,OptimizationHints,InterestFeed,AcceptCHFrame,FirstRunExperience,EdgeSplashScreenStandalone,MojoIpcz,RendererCodeIntegrity'
  )
  if ($mode -eq 'headless') {
    $argsList += ('--virtual-time-budget=' + ([int]($TimeoutSec * 1000)))
  }
  $argsList += @(
    ('--user-data-dir=' + $profileDir),
    $loadUrl
  )

  $attempt = @{
    mode = $mode
    browser_path = $browserCandidate
    profile_dir = $profileDir
    crash_dir = $crashDir
    stdout = $stdoutPath
    stderr = $stderrPath
    args = @($argsList | ForEach-Object { ConvertTo-RedactedArgument ([string]$_) })
    started_at = (Get-Date).ToUniversalTime().ToString('o')
    launch_elapsed_ms = $null
    exit_code = $null
    elapsed_ms = $null
    debug_marker_seen = $false
    result_seen = $false
  }
  $diag.attempts += $attempt
  Write-ScenarioDiagnostics -Path $diagPath -Data $diag

  $proc = $null
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    [System.IO.File]::WriteAllText($stdoutPath, '', (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($stderrPath, '', (New-Object System.Text.UTF8Encoding($false)))
    $proc = Start-Process -FilePath $browserCandidate -ArgumentList $argsList -PassThru -WindowStyle Hidden
    $attempt.launch_elapsed_ms = [int]$sw.ElapsedMilliseconds
  } catch {
    $attempt.launch_error = $_.Exception.Message
    Write-ScenarioDiagnostics -Path $diagPath -Data $diag
    if ($mode -eq 'headless') { continue }
    Write-Error ('Failed to launch browser: ' + $_.Exception.Message)
    exit 2
  }

  $lastProc = $proc
  $lastProfileDir = $profileDir
  $exitSeenAt = $null
  $exitGraceUntil = $null
  while ((Get-Date) -lt $deadline) {
    try {
      $resp = Invoke-RestMethod -Uri $resultUrl -Headers $headers -TimeoutSec 5
      if ($resp.ok -and $resp.result) {
        $result = $resp.result
        $attempt.result_seen = $true
        break
      }
    } catch {
      # Server may be transiently slow; keep polling.
    }
    if (-not $debugMarker) {
      try {
        $dresp = Invoke-RestMethod -Uri $debugUrl -Headers $headers -TimeoutSec 5
        if ($dresp.ok -and $dresp.result) {
          $debugMarker = $dresp.result
          $attempt.debug_marker_seen = $true
        }
      } catch {}
    }
    if ($proc -and $proc.HasExited) {
      if (-not $exitSeenAt) {
        $exitSeenAt = Get-Date
        $exitGraceUntil = $exitSeenAt.AddSeconds(3)
        $attempt.exit_code = $proc.ExitCode
      }
      # Headless with --virtual-time-budget can exit immediately after sendBeacon.
      # Keep polling briefly so a real page-side result is not misreported as
      # "browser exited before scenario result".
      if ((Get-Date) -ge $exitGraceUntil) { break }
    }
    Start-Sleep -Milliseconds 500
  }

  $sw.Stop()
  if ($proc -and $proc.HasExited -and $null -eq $attempt.exit_code) { $attempt.exit_code = $proc.ExitCode }
  $attempt.elapsed_ms = [int]$sw.ElapsedMilliseconds
  $attempt.completed_at = (Get-Date).ToUniversalTime().ToString('o')
  Write-ScenarioDiagnostics -Path $diagPath -Data $diag

  if ($result) { break }

  try { if ($proc -and -not $proc.HasExited) { $proc.Kill() | Out-Null } } catch {}
  if ($debugMarker) { break }
}
if ($result -or $debugMarker) { break }
}

# Optional: keep browser alive for a bit (useful when chained with visit.ps1 for screenshots).
if ($KeepBrowserMs -gt 0) { Start-Sleep -Milliseconds $KeepBrowserMs }

# Teardown.
try { if ($lastProc -and -not $lastProc.HasExited) { $lastProc.Kill() | Out-Null } } catch {}
if ($result -and $lastProfileDir) {
  try { Remove-Item -LiteralPath $lastProfileDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
Write-ScenarioDiagnostics -Path $diagPath -Data $diag

if (-not $result) {
  $detail = ''
  if ($lastProc -and $lastProc.HasExited) {
    $detail = 'browser exited before scenario result (exit ' + $lastProc.ExitCode + ')'
  } else {
    $detail = 'timeout: no scenario result after ' + $TimeoutSec + 's'
  }
  $err = [ordered]@{
    ok = $false
    name = $Name
    error = $detail
    debug_marker_seen = [bool]$debugMarker
    diagnostics = $diagPath
  }
  $err | ConvertTo-Json -Compress -Depth 4
  exit 1
}

# Print result as JSON to stdout, exit with code that reflects ok.
$result | ConvertTo-Json -Compress -Depth 6
if ([bool]$result.ok) { exit 0 } else { exit 1 }
