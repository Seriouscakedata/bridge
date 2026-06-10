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

function ConvertTo-RedactedLogText {
  param([string]$Text)
  if ($null -eq $Text) { return '' }
  $out = [string]$Text
  $out = $out -replace '(https?://)([^/\s:@]+):([^@\s/]+)@', '$1<redacted>@'
  $out = $out -replace '(?i)(Authorization:\s*Basic\s+)[A-Za-z0-9+/=]+', '$1<redacted>'
  $out = $out -replace '(?i)(password|token|secret|bearer)(["''\s:=]+)[^"''\s,;]+', '$1$2<redacted>'
  return $out
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

function Get-ScenarioDiagnosticLogLine {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  $patterns = @(
    'Access is denied',
    'Отказано в доступе',
    'Crashpad',
    'crashpad',
    'Mojo',
    'mojo',
    'sandbox access',
    'FATAL',
    'ERROR'
  )
  try {
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
      foreach ($pattern in $patterns) {
        if ($line.IndexOf($pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
          $safe = ConvertTo-RedactedLogText -Text ([string]$line)
          if ($safe.Length -gt 500) { return $safe.Substring(0, 500) }
          return $safe
        }
      }
    }
  } catch {}
  return ''
}

function Get-ScenarioFailureDiagnostic {
  param(
    [hashtable]$Diagnostics,
    [bool]$DebugMarkerSeen
  )
  $failures = @()
  try { $attempts = @($Diagnostics.attempts) } catch { $attempts = @() }
  foreach ($attempt in $attempts) {
    if (-not $attempt) { continue }
    $stderrLine = Get-ScenarioDiagnosticLogLine -Path ([string]$attempt.stderr)
    $browserName = ''
    try { $browserName = [IO.Path]::GetFileName([string]$attempt.browser_path) } catch { $browserName = [string]$attempt.browser_path }
    $failures += [pscustomobject][ordered]@{
      phase = [string]$attempt.phase
      scenario_name = [string]$attempt.scenario_name
      browser = $browserName
      browser_path = [string]$attempt.browser_path
      mode = [string]$attempt.mode
      exit_code = $attempt.exit_code
      debug_marker_seen = [bool]$attempt.debug_marker_seen
      result_seen = [bool]$attempt.result_seen
      stderr = [string]$attempt.stderr
      stderr_reason = $stderrLine
    }
  }

  $primary = $null
  foreach ($failure in $failures) {
    if ($failure.stderr_reason -match '(?i)access is denied|отказано в доступе|crashpad|mojo|sandbox access|fatal') {
      $primary = $failure
      break
    }
  }
  if (-not $primary -and $failures.Count -gt 0) { $primary = $failures[0] }
  if (-not $primary) {
    return @{ summary = ''; failures = @() }
  }

  $prefix = if (-not $DebugMarkerSeen) { 'browser failed before DOM/debug marker' } else { 'no scenario result' }
  $exitPart = ''
  if ($null -ne $primary.exit_code) { $exitPart = (' exit ' + $primary.exit_code) }
  $stderrPart = ''
  if (-not [string]::IsNullOrWhiteSpace([string]$primary.stderr_reason)) { $stderrPart = ('; stderr: ' + [string]$primary.stderr_reason) }
  return @{
    summary = ($prefix + ': ' + $primary.browser + ' ' + $primary.mode + $exitPart + $stderrPart)
    failures = @($failures)
  }
}

function Join-ProcessArguments {
  param([string[]]$Arguments)
  $parts = @()
  foreach ($arg in $Arguments) {
    $s = [string]$arg
    if ($s -notmatch '[\s"]') {
      $parts += $s
      continue
    }
    $escaped = $s -replace '"', '\"'
    if ($escaped.EndsWith('\')) { $escaped = $escaped + '\' }
    $parts += ('"' + $escaped + '"')
  }
  return ($parts -join ' ')
}

function Start-ScenarioBrowserProcess {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$StdoutPath,
    [string]$StderrPath,
    [string]$ProfileDir
  )

  [System.IO.File]::WriteAllText($StdoutPath, '', (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText($StderrPath, '', (New-Object System.Text.UTF8Encoding($false)))

  $envRoot = Join-Path $ProfileDir 'env'
  $tempDir = Join-Path $envRoot 'temp'
  $localAppDataDir = Join-Path $envRoot 'localappdata'
  $homeDir = Join-Path $envRoot 'home'
  foreach ($dir in @($tempDir, $localAppDataDir, $homeDir)) {
    [void](New-Item -ItemType Directory -Path $dir -Force)
  }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = Join-ProcessArguments -Arguments $Arguments
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = Split-Path -Parent $FilePath
  try {
    if ($null -ne $psi.EnvironmentVariables) {
      $psi.EnvironmentVariables.Set_Item('TMP', $tempDir)
      $psi.EnvironmentVariables.Set_Item('TEMP', $tempDir)
      $psi.EnvironmentVariables.Set_Item('LOCALAPPDATA', $localAppDataDir)
      $psi.EnvironmentVariables.Set_Item('USERPROFILE', $homeDir)
    } elseif ($null -ne $psi.Environment) {
      $psi.Environment.Set_Item('TMP', $tempDir)
      $psi.Environment.Set_Item('TEMP', $tempDir)
      $psi.Environment.Set_Item('LOCALAPPDATA', $localAppDataDir)
      $psi.Environment.Set_Item('USERPROFILE', $homeDir)
    }
  } catch {}

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  [void]$proc.Start()
  $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
  $stderrTask = $proc.StandardError.ReadToEndAsync()

  return @{
    Process = $proc
    StdoutTask = $stdoutTask
    StderrTask = $stderrTask
    StdoutPath = $StdoutPath
    StderrPath = $StderrPath
  }
}

function Complete-ScenarioBrowserProcess {
  param(
    [hashtable]$Handle,
    [switch]$Kill
  )
  if (-not $Handle) { return }
  $proc = $Handle.Process
  try {
    if ($proc -and -not $proc.HasExited -and $Kill) {
      $proc.Kill() | Out-Null
    }
  } catch {}
  try {
    if ($proc) { [void]$proc.WaitForExit(3000) }
  } catch {}
  try {
    $stdout = ConvertTo-RedactedLogText -Text ([string]$Handle.StdoutTask.Result)
    [System.IO.File]::WriteAllText([string]$Handle.StdoutPath, $stdout, (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
  try {
    $stderr = ConvertTo-RedactedLogText -Text ([string]$Handle.StderrTask.Result)
    [System.IO.File]::WriteAllText([string]$Handle.StderrPath, $stderr, (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

function Add-ScenarioQueryParam {
  param(
    [string]$Original,
    [string]$ScenarioName
  )
  $sep = if ($Original.Contains('?')) { '&' } else { '?' }
  return ($Original + $sep + 'scenario=' + [Uri]::EscapeDataString($ScenarioName))
}

function Add-ScenarioChannelQueryParam {
  param(
    [string]$Original,
    [string]$Channel
  )
  if ([string]::IsNullOrWhiteSpace($Channel)) { return $Original }
  $sep = if ($Original.Contains('?')) { '&' } else { '?' }
  return ($Original + $sep + 'channel=' + [Uri]::EscapeDataString($Channel))
}

function Get-ScenarioChannel {
  if (-not [string]::IsNullOrWhiteSpace([string]$env:BRIDGE_CHANNEL)) { return [string]$env:BRIDGE_CHANNEL }
  return 'main'
}

function New-BrowserArguments {
  param(
    [string]$Mode,
    [string]$LoadUrl,
    [string]$ProfileDir,
    [string]$CrashDir,
    [string]$CacheDir
  )
  $argsList = @()
  if ($Mode -like 'headless*') { $argsList += '--headless=new' } else { $argsList += '--window-position=-32000,-32000' }
  $argsList += @(
    ('--window-size=' + $Width + ',' + $Height),
    '--hide-scrollbars',
    '--no-sandbox',
    '--disable-gpu',
    '--disable-dev-shm-usage',
    '--no-zygote',
    '--noerrdialogs',
    '--enable-logging=stderr',
    '--v=1',
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
    ('--crash-dumps-dir=' + $CrashDir),
    ('--disk-cache-dir=' + $CacheDir),
    '--disable-features=Translate,OptimizationHints,InterestFeed,AcceptCHFrame,FirstRunExperience,EdgeSplashScreenStandalone,MojoIpcz,RendererCodeIntegrity'
  )
  if ($Mode -like '*single-process') {
    $argsList += @('--single-process', '--in-process-gpu')
  }
  if ($Mode -like 'headless*') {
    $argsList += ('--virtual-time-budget=' + ([int]($TimeoutSec * 1000)))
  }
  $argsList += @(
    ('--user-data-dir=' + $ProfileDir),
    $LoadUrl
  )
  return $argsList
}

function Test-ScenarioHttpEndpoint {
  param(
    [string]$CheckUrl,
    [hashtable]$Headers
  )
  $item = @{
    url = (Get-RedactedUrl -Original $CheckUrl)
    ok = $false
    status = $null
    error = ''
  }
  try {
    $resp = Invoke-WebRequest -Uri $CheckUrl -Headers $Headers -UseBasicParsing -TimeoutSec 5
    $item.status = [int]$resp.StatusCode
    $item.ok = ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400)
  } catch {
    $item.error = $_.Exception.Message
    try {
      if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
        $item.status = [int]$_.Exception.Response.StatusCode
      }
    } catch {}
  }
  return $item
}

function Invoke-BacklogAddHttpScenario {
  param(
    [string]$BaseUrl,
    [hashtable]$Headers,
    [string]$Channel = 'main'
  )

  $sw = [Diagnostics.Stopwatch]::StartNew()
  $errors = New-Object 'System.Collections.Generic.List[string]'
  $log = New-Object 'System.Collections.Generic.List[string]'
  $marker = 'backlog-flow-e8061e8f51a0'
  $markerText = 'bridge backlog add list delete verification c350bcc7614c4d749cbb5985c3486163'
  $uniqueToken = $marker + '-' + [Guid]::NewGuid().ToString('N')
  $saltWords = @(
    'atlas','lagoon','copper','matrix','harbor','violet','lantern','orchard',
    'signal','meadow','canyon','silver','comet','ribbon','marble','cedar',
    'pixel','garden','anchor','velvet','summit','cobalt','quartz','ember'
  ) | Get-Random -Count 8
  $taskText = $marker + ' ' + $markerText + ' ' + $uniqueToken + ' ' + ($saltWords -join ' ')
  $addId = ''

  try {
    $health = Invoke-RestMethod -Uri (($BaseUrl.TrimEnd('/')) + '/api/backlog/health') -Headers $Headers -TimeoutSec 10
    if ($health.addIdea -eq $true) { [void]$log.Add('OK: Add-Idea function loaded on server') } else { [void]$errors.Add('Add-Idea function not loaded on server') }
    if ($health.getBacklogPath -eq $true) { [void]$log.Add('OK: Get-BacklogPath function loaded on server') } else { [void]$errors.Add('Get-BacklogPath function not loaded on server') }
  } catch {
    [void]$errors.Add('GET /api/backlog/health failed: ' + $_.Exception.Message)
  }

  if ($errors.Count -eq 0) {
    try {
      $body = @{ text = $taskText; status = 'new'; channel = $Channel; skip_curator = $true } | ConvertTo-Json -Compress
      $addResp = Invoke-RestMethod -Uri (($BaseUrl.TrimEnd('/')) + '/api/backlog/add') -Method POST -Body $body -ContentType 'application/json; charset=utf-8' -Headers $Headers -TimeoutSec 45
      if ($addResp.ok -eq $true) { [void]$log.Add('OK: POST returned ok=true') } else { [void]$errors.Add('POST /api/backlog/add returned ok != true') }
      if ($addResp.id -and ([string]$addResp.id).Length -ge 8) {
        $addId = [string]$addResp.id
        [void]$log.Add('OK: POST returned an id')
        [void]$log.Add('added id: ' + $addId)
      } else {
        [void]$errors.Add('POST /api/backlog/add did not return an id')
      }
    } catch {
      [void]$errors.Add('POST /api/backlog/add failed: ' + $_.Exception.Message)
    }
  }

  if ($errors.Count -eq 0) {
    try {
      $listResp = Invoke-RestMethod -Uri (($BaseUrl.TrimEnd('/')) + '/api/backlog?channel=' + [Uri]::EscapeDataString($Channel) + '&include=all') -Headers $Headers -TimeoutSec 15
      if ($listResp.ok -eq $true) { [void]$log.Add('OK: GET /api/backlog returned ok=true') } else { [void]$errors.Add('GET /api/backlog returned ok != true') }
      $items = @()
      if ($listResp.items) { $items = @($listResp.items) }
      [void]$log.Add('backlog items returned: ' + $items.Count)
      $found = $null
      foreach ($item in $items) {
        if ($item -and ([string]$item.text).Contains($uniqueToken)) { $found = $item; break }
      }
      if ($found) {
        [void]$log.Add('OK: item with marker found in backlog')
        if ([string]$found.id -eq $addId) { [void]$log.Add('OK: id matches POST response') } else { [void]$errors.Add('id does not match POST response') }
        $allowedStatuses = @('new','approved','held','auto-dropped')
        if ($allowedStatuses -contains [string]$found.status) { [void]$log.Add('OK: item status is a known post-add status') } else { [void]$errors.Add('item status is not a known post-add status') }
      } else {
        [void]$errors.Add('item with marker not found in backlog')
      }
    } catch {
      [void]$errors.Add('GET /api/backlog failed: ' + $_.Exception.Message)
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($addId)) {
    try {
      $deleteBody = @{ id = $addId; channel = $Channel } | ConvertTo-Json -Compress
      $deleteResp = Invoke-RestMethod -Uri (($BaseUrl.TrimEnd('/')) + '/api/backlog/delete') -Method POST -Body $deleteBody -ContentType 'application/json; charset=utf-8' -Headers $Headers -TimeoutSec 45
      if ($deleteResp.ok -eq $true) { [void]$log.Add('OK: DELETE returned ok=true') } else { [void]$errors.Add('DELETE /api/backlog/delete returned ok != true') }
      $afterResp = Invoke-RestMethod -Uri (($BaseUrl.TrimEnd('/')) + '/api/backlog?channel=' + [Uri]::EscapeDataString($Channel) + '&include=all') -Headers $Headers -TimeoutSec 30
      $afterItems = @()
      if ($afterResp.items) { $afterItems = @($afterResp.items) }
      $archivedItem = $null
      foreach ($item in $afterItems) {
        if ($item -and [string]$item.id -eq $addId) { $archivedItem = $item; break }
      }
      if ($archivedItem -and [string]$archivedItem.status -eq 'rejected') { [void]$log.Add('OK: deleted item archived as rejected') } else { [void]$errors.Add('deleted item was not archived as rejected') }
      $visibleAfterResp = Invoke-RestMethod -Uri (($BaseUrl.TrimEnd('/')) + '/api/backlog?channel=' + [Uri]::EscapeDataString($Channel)) -Headers $Headers -TimeoutSec 30
      $visibleAfterItems = @()
      if ($visibleAfterResp.items) { $visibleAfterItems = @($visibleAfterResp.items) }
      $stillVisible = $false
      foreach ($item in $visibleAfterItems) {
        if ($item -and [string]$item.id -eq $addId) { $stillVisible = $true; break }
      }
      if (-not $stillVisible) { [void]$log.Add('OK: deleted item absent from active backlog') } else { [void]$errors.Add('deleted item still visible in active backlog') }
      [void]$log.Add('cleanup: deleted scenario item ' + $addId)
    } catch {
      [void]$errors.Add('DELETE verification failed: ' + $_.Exception.Message)
    }
  }

  $sw.Stop()
  return [pscustomobject][ordered]@{
    name = 'backlog-add'
    ok = ($errors.Count -eq 0)
    errors = @($errors.ToArray())
    log = @($log.ToArray())
    fallback = 'http'
    timings = @{ totalMs = [int]$sw.ElapsedMilliseconds }
  }
}

function Invoke-ChannelSwitchHttpScenario {
  param(
    [string]$BaseUrl,
    [hashtable]$Headers
  )

  $sw = [Diagnostics.Stopwatch]::StartNew()
  $errors = New-Object 'System.Collections.Generic.List[string]'
  $log = New-Object 'System.Collections.Generic.List[string]'
  $initial = ''
  $target = ''

  try {
    $channels = Invoke-RestMethod -Uri (($BaseUrl.TrimEnd('/')) + '/api/channels') -Headers $Headers -TimeoutSec 10
    if ($channels.ok -eq $true) { [void]$log.Add('OK: GET /api/channels returned ok=true') } else { [void]$errors.Add('GET /api/channels returned ok != true') }
    $items = @()
    if ($channels.items) { $items = @($channels.items) }
    [void]$log.Add('channels returned: ' + $items.Count)
    if ($items.Count -lt 2) {
      [void]$errors.Add('channel-switch needs at least 2 channels')
    } else {
      $initial = [string]$channels.active
      if ([string]::IsNullOrWhiteSpace($initial)) { $initial = [string]$items[0].slug }
      foreach ($item in $items) {
        $slug = [string]$item.slug
        if (-not [string]::IsNullOrWhiteSpace($slug) -and $slug -ne $initial) {
          $target = $slug
          break
        }
      }
      if ([string]::IsNullOrWhiteSpace($target)) { [void]$errors.Add('no target channel found') } else { [void]$log.Add('target channel: ' + $target) }
    }
  } catch {
    [void]$errors.Add('GET /api/channels failed: ' + $_.Exception.Message)
  }

  if ($errors.Count -eq 0) {
    try {
      $body = @{ slug = $target } | ConvertTo-Json -Compress
      $switchResp = Invoke-RestMethod -Uri (($BaseUrl.TrimEnd('/')) + '/api/channels/active') -Method POST -Body $body -ContentType 'application/json; charset=utf-8' -Headers $Headers -TimeoutSec 10
      if ($switchResp.ok -eq $true -and [string]$switchResp.active -eq $target) { [void]$log.Add('OK: switch initial -> target persisted') } else { [void]$errors.Add('POST /api/channels/active target failed') }

      $messagesResp = @(Invoke-RestMethod -Uri (($BaseUrl.TrimEnd('/')) + '/api/messages?since=0&channel=' + [Uri]::EscapeDataString($target)) -Headers $Headers -TimeoutSec 15)
      [void]$log.Add('OK: GET /api/messages target returned ' + $messagesResp.Count + ' messages')

      $roundTripBody = @{ slug = $initial } | ConvertTo-Json -Compress
      $roundTripResp = Invoke-RestMethod -Uri (($BaseUrl.TrimEnd('/')) + '/api/channels/active') -Method POST -Body $roundTripBody -ContentType 'application/json; charset=utf-8' -Headers $Headers -TimeoutSec 10
      if ($roundTripResp.ok -eq $true -and [string]$roundTripResp.active -eq $initial) { [void]$log.Add('OK: switch target -> initial persisted') } else { [void]$errors.Add('POST /api/channels/active initial failed') }

      $initialMessagesResp = @(Invoke-RestMethod -Uri (($BaseUrl.TrimEnd('/')) + '/api/messages?since=0&channel=' + [Uri]::EscapeDataString($initial)) -Headers $Headers -TimeoutSec 15)
      [void]$log.Add('OK: GET /api/messages initial returned ' + $initialMessagesResp.Count + ' messages')
    } catch {
      [void]$errors.Add('channel switch HTTP fallback failed: ' + $_.Exception.Message)
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($initial)) {
    try {
      $restoreBody = @{ slug = $initial } | ConvertTo-Json -Compress
      [void](Invoke-RestMethod -Uri (($BaseUrl.TrimEnd('/')) + '/api/channels/active') -Method POST -Body $restoreBody -ContentType 'application/json; charset=utf-8' -Headers $Headers -TimeoutSec 10)
      [void]$log.Add('cleanup: restored active channel ' + $initial)
    } catch {
      [void]$errors.Add('cleanup restore active channel failed: ' + $_.Exception.Message)
    }
  }

  $sw.Stop()
  return [pscustomobject][ordered]@{
    name = 'channel-switch'
    ok = ($errors.Count -eq 0)
    errors = @($errors.ToArray())
    log = @($log.ToArray())
    fallback = 'http'
    timings = @{ totalMs = [int]$sw.ElapsedMilliseconds }
  }
}

if (-not ($Name -match '^[a-z0-9_-]+$')) {
  Write-Error "Bad scenario name '$Name' (allowed: a-z 0-9 _ -)"
  exit 2
}

if ($Name -eq 'features-registry') {
  & (Join-Path $root 'tools\check-features-registry.ps1') -Url $Url
  exit $LASTEXITCODE
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
$scenarioChannel = Get-ScenarioChannel
$baseLoadUrl = $loadUrl
$loadUrl = Add-ScenarioQueryParam -Original $baseLoadUrl -ScenarioName $Name
$loadUrl = Add-ScenarioChannelQueryParam -Original $loadUrl -Channel $scenarioChannel
$probeName = $Name + '-probe'
$probeLoadUrl = Add-ScenarioQueryParam -Original $baseLoadUrl -ScenarioName $probeName
$probeLoadUrl = Add-ScenarioChannelQueryParam -Original $probeLoadUrl -Channel $scenarioChannel

# Mark start time so we can ignore older results in the JSONL log.
$startTs = (Get-Date).ToUniversalTime().ToString('o')

# Temp profile dir so Edge/Chrome doesn't fight a real session.
# Prefer the bridge runtime tree: this sandbox can write there, while browser
# subprocesses can hit Access Denied under the user's AppData\Temp.
$scenarioRuntimeDir = Join-Path $root 'runtime\scenario'
[void](New-Item -ItemType Directory -Path $scenarioRuntimeDir -Force)
$scenarioProfileRoot = Join-Path $scenarioRuntimeDir 'profiles'
try {
  [void](New-Item -ItemType Directory -Path $scenarioProfileRoot -Force)
  $probeWrite = Join-Path $scenarioProfileRoot ('.write-test-' + [guid]::NewGuid().ToString('N'))
  [System.IO.File]::WriteAllText($probeWrite, 'ok', (New-Object System.Text.UTF8Encoding($false)))
  Remove-Item -LiteralPath $probeWrite -Force -ErrorAction SilentlyContinue
} catch {
  $scenarioProfileRoot = Join-Path ([System.IO.Path]::GetTempPath()) 'bridge-scenario-runtime'
  [void](New-Item -ItemType Directory -Path $scenarioProfileRoot -Force)
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
  profile_root = $scenarioProfileRoot
  load_url = (Get-RedactedUrl -Original $loadUrl)
  probe_url = (Get-RedactedUrl -Original $probeLoadUrl)
  result_url = (Get-RedactedUrl -Original (($Url.TrimEnd('/')) + '/api/scenario/result?name=' + [Uri]::EscapeDataString($Name)))
  attempts = @()
  http_checks = @()
}

$headers = Get-AuthHeaders
$diag.http_checks += (Test-ScenarioHttpEndpoint -CheckUrl $loadUrl -Headers $headers)
$diag.http_checks += (Test-ScenarioHttpEndpoint -CheckUrl (($Url.TrimEnd('/')) + '/tools/scenarios/' + [Uri]::EscapeDataString($Name) + '.js') -Headers $headers)
Write-ScenarioDiagnostics -Path $diagPath -Data $diag
$resultUrl = ($Url.TrimEnd('/')) + '/api/scenario/result?name=' + [Uri]::EscapeDataString($Name) + '&since=' + [Uri]::EscapeDataString($startTs)
$debugName = 'debug-boot-' + $Name
$debugUrl = ($Url.TrimEnd('/')) + '/api/scenario/result?name=' + [Uri]::EscapeDataString($debugName) + '&since=' + [Uri]::EscapeDataString($startTs)
$probeDebugName = 'debug-boot-' + $probeName
$probeDebugUrl = ($Url.TrimEnd('/')) + '/api/scenario/result?name=' + [Uri]::EscapeDataString($probeDebugName) + '&since=' + [Uri]::EscapeDataString($startTs)
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$result = $null
$debugMarker = $null
$lastProcHandle = $null
$lastProfileDir = ''

$modes = @('headless', 'headless-single-process', 'headed-offscreen', 'headed-single-process')
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
  $cacheDir = Join-Path $profileDir 'cache'
  [void](New-Item -ItemType Directory -Path $cacheDir -Force)

  $probeStdoutPath = Join-Path $logDir ($attemptId + '.probe.browser.stdout.log')
  $probeStderrPath = Join-Path $logDir ($attemptId + '.probe.browser.stderr.log')
  $probeArgsList = @(New-BrowserArguments -Mode $mode -LoadUrl $probeLoadUrl -ProfileDir $profileDir -CrashDir $crashDir -CacheDir $cacheDir)
  $probeAttempt = @{
    phase = 'self-probe'
    scenario_name = $probeName
    mode = $mode
    browser_path = $browserCandidate
    profile_dir = $profileDir
    crash_dir = $crashDir
    cache_dir = $cacheDir
    stdout = $probeStdoutPath
    stderr = $probeStderrPath
    args = @($probeArgsList | ForEach-Object { ConvertTo-RedactedArgument ([string]$_) })
    arguments = (Join-ProcessArguments -Arguments @($probeArgsList | ForEach-Object { ConvertTo-RedactedArgument ([string]$_) }))
    started_at = (Get-Date).ToUniversalTime().ToString('o')
    launch_elapsed_ms = $null
    exit_code = $null
    elapsed_ms = $null
    debug_marker_seen = $false
    result_seen = $false
  }
  $diag.attempts += $probeAttempt
  Write-ScenarioDiagnostics -Path $diagPath -Data $diag

  $probeHandle = $null
  $probeMarker = $null
  $sw = [Diagnostics.Stopwatch]::StartNew()
  try {
    $probeHandle = Start-ScenarioBrowserProcess -FilePath $browserCandidate -Arguments $probeArgsList -StdoutPath $probeStdoutPath -StderrPath $probeStderrPath -ProfileDir $profileDir
    $probeAttempt.launch_elapsed_ms = [int]$sw.ElapsedMilliseconds
  } catch {
    $probeAttempt.launch_error = $_.Exception.Message
    Write-ScenarioDiagnostics -Path $diagPath -Data $diag
    if ($mode -eq 'headless') { continue }
    Write-Error ('Failed to launch browser probe: ' + $_.Exception.Message)
    exit 2
  }

  $probeProc = $probeHandle.Process
  $probeDeadline = (Get-Date).AddSeconds([Math]::Min(8, [Math]::Max(1, [int](($deadline - (Get-Date)).TotalSeconds))))
  $exitSeenAt = $null
  $exitGraceUntil = $null
  while ((Get-Date) -lt $probeDeadline) {
    try {
      $dresp = Invoke-RestMethod -Uri $probeDebugUrl -Headers $headers -TimeoutSec 3
      if ($dresp.ok -and $dresp.result) {
        $probeMarker = $dresp.result
        $probeAttempt.debug_marker_seen = $true
        break
      }
    } catch {}
    if ($probeProc -and $probeProc.HasExited) {
      if (-not $exitSeenAt) {
        $exitSeenAt = Get-Date
        $exitGraceUntil = $exitSeenAt.AddSeconds(2)
        $probeAttempt.exit_code = $probeProc.ExitCode
      }
      if ((Get-Date) -ge $exitGraceUntil) { break }
    }
    Start-Sleep -Milliseconds 300
  }
  $sw.Stop()
  if ($probeProc -and $probeProc.HasExited -and $null -eq $probeAttempt.exit_code) { $probeAttempt.exit_code = $probeProc.ExitCode }
  $probeAttempt.elapsed_ms = [int]$sw.ElapsedMilliseconds
  $probeAttempt.completed_at = (Get-Date).ToUniversalTime().ToString('o')
  Complete-ScenarioBrowserProcess -Handle $probeHandle -Kill
  Write-ScenarioDiagnostics -Path $diagPath -Data $diag
  if (-not $probeMarker) { continue }

  $stdoutPath = Join-Path $logDir ($attemptId + '.browser.stdout.log')
  $stderrPath = Join-Path $logDir ($attemptId + '.browser.stderr.log')
  $argsList = @(New-BrowserArguments -Mode $mode -LoadUrl $loadUrl -ProfileDir $profileDir -CrashDir $crashDir -CacheDir $cacheDir)

  $attempt = @{
    phase = 'scenario'
    scenario_name = $Name
    mode = $mode
    browser_path = $browserCandidate
    profile_dir = $profileDir
    crash_dir = $crashDir
    cache_dir = $cacheDir
    stdout = $stdoutPath
    stderr = $stderrPath
    args = @($argsList | ForEach-Object { ConvertTo-RedactedArgument ([string]$_) })
    arguments = (Join-ProcessArguments -Arguments @($argsList | ForEach-Object { ConvertTo-RedactedArgument ([string]$_) }))
    started_at = (Get-Date).ToUniversalTime().ToString('o')
    launch_elapsed_ms = $null
    exit_code = $null
    elapsed_ms = $null
    debug_marker_seen = $false
    result_seen = $false
  }
  $diag.attempts += $attempt
  Write-ScenarioDiagnostics -Path $diagPath -Data $diag

  $sw = [Diagnostics.Stopwatch]::StartNew()
  $procHandle = $null
  try {
    $procHandle = Start-ScenarioBrowserProcess -FilePath $browserCandidate -Arguments $argsList -StdoutPath $stdoutPath -StderrPath $stderrPath -ProfileDir $profileDir
    $proc = $procHandle.Process
    $attempt.launch_elapsed_ms = [int]$sw.ElapsedMilliseconds
  } catch {
    $attempt.launch_error = $_.Exception.Message
    Write-ScenarioDiagnostics -Path $diagPath -Data $diag
    if ($mode -eq 'headless') { continue }
    Write-Error ('Failed to launch browser: ' + $_.Exception.Message)
    exit 2
  }

  $lastProcHandle = $procHandle
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
  if ($proc -and $proc.HasExited) {
    Complete-ScenarioBrowserProcess -Handle $procHandle
  }
  Write-ScenarioDiagnostics -Path $diagPath -Data $diag

  if ($result) { break }

  Complete-ScenarioBrowserProcess -Handle $procHandle -Kill
}
if ($result) { break }
}

# Optional: keep browser alive for a bit (useful when chained with visit.ps1 for screenshots).
if ($KeepBrowserMs -gt 0) { Start-Sleep -Milliseconds $KeepBrowserMs }

# Teardown.
try {
  if ($lastProcHandle -and $lastProcHandle.Process -and -not $lastProcHandle.Process.HasExited) {
    Complete-ScenarioBrowserProcess -Handle $lastProcHandle -Kill
  }
} catch {}
if ($result -and $lastProfileDir) {
  try { Remove-Item -LiteralPath $lastProfileDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
Write-ScenarioDiagnostics -Path $diagPath -Data $diag

if (-not $result) {
  if ($Name -eq 'backlog-add') {
    $fallbackResult = Invoke-BacklogAddHttpScenario -BaseUrl $Url -Headers $headers -Channel $scenarioChannel
    $diag.fallback = 'http'
    $diag.fallback_result = $fallbackResult
    Write-ScenarioDiagnostics -Path $diagPath -Data $diag
    $fallbackResult | ConvertTo-Json -Compress -Depth 6
    if ([bool]$fallbackResult.ok) { exit 0 } else { exit 1 }
  }
  if ($Name -eq 'channel-switch') {
    $fallbackResult = Invoke-ChannelSwitchHttpScenario -BaseUrl $Url -Headers $headers
    $diag.fallback = 'http'
    $diag.fallback_result = $fallbackResult
    Write-ScenarioDiagnostics -Path $diagPath -Data $diag
    $fallbackResult | ConvertTo-Json -Compress -Depth 6
    if ([bool]$fallbackResult.ok) { exit 0 } else { exit 1 }
  }
  $failureDiagnostic = Get-ScenarioFailureDiagnostic -Diagnostics $diag -DebugMarkerSeen ([bool]$debugMarker)
  $detail = ''
  if (-not [string]::IsNullOrWhiteSpace([string]$failureDiagnostic.summary)) {
    $detail = [string]$failureDiagnostic.summary
    $diag.failure_reason = $detail
    $diag.browser_failures = @($failureDiagnostic.failures)
    Write-ScenarioDiagnostics -Path $diagPath -Data $diag
  } elseif ($lastProcHandle -and $lastProcHandle.Process -and $lastProcHandle.Process.HasExited) {
    $detail = 'browser exited before scenario result (exit ' + $lastProcHandle.Process.ExitCode + ')'
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
