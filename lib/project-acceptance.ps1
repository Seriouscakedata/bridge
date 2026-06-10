# project-acceptance.ps1 -- final project acceptance pass for project channels.
#
# This is intentionally deterministic. It does not decide product quality by itself;
# it runs the project's declared checks, records evidence, posts chat status, and
# optionally opens one follow-up backlog task when acceptance fails.

if (-not (Get-Command Get-ProjectTrackedGeneratedArtifactPaths -ErrorAction SilentlyContinue)) {
  . (Join-Path $PSScriptRoot 'project-artifact-policy.ps1')
}
if (-not (Get-Command Get-BridgeObjectValue -ErrorAction SilentlyContinue)) {
  try { . (Join-Path $PSScriptRoot 'primitives.ps1') } catch {}
}

function Get-ProjectAcceptanceBridgeRoot {
  try { return (Get-BridgeRoot) } catch {}
  try { return (Split-Path -Parent $PSScriptRoot) } catch {}
  return 'C:\Users\rafie\OneDrive\Documents\bridge'
}

function Get-ProjectAcceptanceChannel {
  param([string]$Channel = '')
  if (-not [string]::IsNullOrWhiteSpace($Channel)) { return [string]$Channel }
  try { if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { return [string](Get-EffectiveChannel) } } catch {}
  if (-not [string]::IsNullOrWhiteSpace($env:BRIDGE_CHANNEL)) { return [string]$env:BRIDGE_CHANNEL }
  return 'main'
}

function Get-ProjectAcceptanceChannelDir {
  param([string]$Channel = '')
  $root = Get-ProjectAcceptanceBridgeRoot
  $ch = Get-ProjectAcceptanceChannel -Channel $Channel
  return (Join-Path (Join-Path $root 'channels') $ch)
}

function Get-ProjectAcceptanceBinding {
  param([string]$Channel = '')
  $ch = Get-ProjectAcceptanceChannel -Channel $Channel
  if ([string]::IsNullOrWhiteSpace($ch) -or $ch -eq 'main') { return $null }
  try {
    if (Get-Command Get-ChannelProjectBinding -ErrorAction SilentlyContinue) {
      $b = Get-ChannelProjectBinding -Slug $ch
      if ($b -and [bool]$b.ok -and -not [string]::IsNullOrWhiteSpace([string]$b.project_root)) { return $b }
    }
  } catch {}
  try {
    $p = Join-Path (Get-ProjectAcceptanceChannelDir -Channel $ch) 'channel.json'
    if (Test-Path -LiteralPath $p -PathType Leaf) {
      $raw = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
      if ($raw -and -not [string]::IsNullOrWhiteSpace([string]$raw.project_root)) {
        return [pscustomobject]@{ ok = $true; slug = $ch; project_root = [string]$raw.project_root }
      }
    }
  } catch {}
  return $null
}

function Get-ProjectAcceptanceObjectValue {
  # Delegate preserves original acceptance semantics: present-but-null is treated as missing.
  param($Obj, [string[]]$Names, $Default = $null)
  return Get-BridgeObjectValue -Object $Obj -Names $Names -Default $Default -NullAsMissing
}

function Read-ProjectAcceptanceJson {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
  try { return ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Write-ProjectAcceptanceText {
  param([string]$Path, [string]$Text)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($Path, [string]$Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-ProjectAcceptanceTrace {
  param([string]$Channel = '', [string]$Text = '')
  try {
    $path = Join-Path (Get-ProjectAcceptanceChannelDir -Channel $Channel) 'project-acceptance.trace.log'
    $line = (Get-Date).ToString('o') + ' ' + [string]$Text + "`n"
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::AppendAllText($path, $line, (New-Object System.Text.UTF8Encoding($false)))
    if ([string]$env:PROJECT_ACCEPTANCE_TRACE_STDERR -eq '1') {
      try { [Console]::Error.WriteLine($line.TrimEnd()) } catch {}
    }
  } catch {}
}

function Invoke-ProjectAcceptanceSidecar {
  param(
    [string]$Name,
    [hashtable]$Payload,
    [string]$Body,
    [int]$TimeoutSec = 20
  )
  $id = [guid]::NewGuid().ToString('N')
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "bridge-project-acceptance-$Name-$id"
  $payloadPath = "$tmp.json"
  $scriptPath = "$tmp.ps1"
  $outPath = "$tmp.out.log"
  $errPath = "$tmp.err.log"
  $traceChannel = ''
  try { if ($Payload.ContainsKey('channel')) { $traceChannel = [string]$Payload['channel'] } } catch {}
  try {
    Write-ProjectAcceptanceTrace -Channel $traceChannel -Text "sidecar $Name payload write"
    Write-ProjectAcceptanceText -Path $payloadPath -Text (($Payload | ConvertTo-Json -Depth 8) + "`n")
    $payloadLiteral = $payloadPath.Replace("'", "''")
    $script = @"
`$ErrorActionPreference = 'Stop'
`$payload = [System.IO.File]::ReadAllText('$payloadLiteral', [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$Body
"@
    Write-ProjectAcceptanceTrace -Channel $traceChannel -Text "sidecar $Name script write"
    Write-ProjectAcceptanceText -Path $scriptPath -Text $script
    $p = Start-Process -FilePath powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath) -RedirectStandardOutput $outPath -RedirectStandardError $errPath -NoNewWindow -PassThru
    Write-ProjectAcceptanceTrace -Channel $traceChannel -Text "sidecar $Name started pid=$($p.Id)"
    if (-not $p.WaitForExit([Math]::Max(1, $TimeoutSec) * 1000)) {
      try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
      Write-ProjectAcceptanceTrace -Channel $traceChannel -Text "sidecar $Name timeout"
      return $false
    }
    try { $p.Refresh() } catch {}
    $exitCode = 0
    try { $exitCode = [int]$p.ExitCode } catch { $exitCode = -999 }
    Write-ProjectAcceptanceTrace -Channel $traceChannel -Text "sidecar $Name exited code=$exitCode"
    return ($exitCode -eq 0)
  } catch {
    Write-ProjectAcceptanceTrace -Channel $traceChannel -Text "sidecar $Name exception=$($_.Exception.Message)"
    return $false
  } finally {
    Write-ProjectAcceptanceTrace -Channel $traceChannel -Text "sidecar $Name cleanup"
    foreach ($path in @($payloadPath,$scriptPath,$outPath,$errPath)) {
      try { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } } catch {}
    }
  }
}

function Add-ProjectAcceptanceMemoryBestEffort {
  param(
    [string]$Channel,
    [string]$Text,
    [string]$Kind,
    [string]$Report,
    [string]$Head,
    [string]$Status
  )
  $body = @'
. (Join-Path ([string]$payload.bridge_root) 'lib\common.ps1')
. (Join-Path ([string]$payload.bridge_root) 'lib\memory.ps1')
$meta = [pscustomobject]@{
  report = [string]$payload.report
  head = [string]$payload.head
  status = [string]$payload.status
}
Add-ProjectMemory -Text ([string]$payload.text) -Kind ([string]$payload.kind) -Trust 'observed' -Tags @('acceptance','final-check') -Source 'project-acceptance' -Importance 0.8 -Channel ([string]$payload.channel) -Meta $meta | Out-Null
'@
  return (Invoke-ProjectAcceptanceSidecar -Name 'memory' -TimeoutSec 30 -Payload @{
    bridge_root = Get-ProjectAcceptanceBridgeRoot
    channel = [string]$Channel
    text = [string]$Text
    kind = [string]$Kind
    report = [string]$Report
    head = [string]$Head
    status = [string]$Status
  } -Body $body)
}

function Add-ProjectAcceptanceMessageBestEffort {
  param([string]$Text)
  $body = @'
. (Join-Path ([string]$payload.bridge_root) 'lib\common.ps1')
Add-Message -From system -Text ([string]$payload.text) -Kind event | Out-Null
'@
  return (Invoke-ProjectAcceptanceSidecar -Name 'message' -TimeoutSec 10 -Payload @{
    bridge_root = Get-ProjectAcceptanceBridgeRoot
    text = [string]$Text
  } -Body $body)
}

function Get-ProjectAcceptanceStatePath {
  param([string]$Channel = '')
  return (Join-Path (Get-ProjectAcceptanceChannelDir -Channel $Channel) 'project-acceptance.last.json')
}

function Read-ProjectAcceptanceState {
  param([string]$Channel = '')
  return (Read-ProjectAcceptanceJson -Path (Get-ProjectAcceptanceStatePath -Channel $Channel))
}

function Write-ProjectAcceptanceState {
  param([string]$Channel = '', $State)
  $json = ($State | ConvertTo-Json -Compress -Depth 10) + "`n"
  Write-ProjectAcceptanceText -Path (Get-ProjectAcceptanceStatePath -Channel $Channel) -Text $json
}

function Get-ProjectAcceptanceGitHead {
  param([string]$ProjectRoot)
  try { return ([string](& git -C $ProjectRoot rev-parse HEAD 2>$null)).Trim() } catch { return '' }
}

function Test-ProjectAcceptanceGitClean {
  param([string]$ProjectRoot)
  try {
    $dirty = @(& git -C $ProjectRoot status --porcelain 2>$null | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    return ($dirty.Count -eq 0)
  } catch {
    return $false
  }
}

function Get-ProjectAcceptancePackage {
  param([string]$ProjectRoot)
  $p = Join-Path $ProjectRoot 'package.json'
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
  try { return ([System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Test-ProjectAcceptancePackageScript {
  param($PackageJson, [string]$Name)
  try { return ($PackageJson -and $PackageJson.scripts -and ($PackageJson.scripts.PSObject.Properties.Name -contains $Name)) } catch { return $false }
}

function Get-ProjectAcceptanceDefaultSmokeScripts {
  param($PackageJson)
  if (Test-ProjectAcceptancePackageScript -PackageJson $PackageJson -Name 'smoke:launch') {
    return @('smoke:launch')
  }

  $candidates = @('smoke:browser','smoke:e2e','test:e2e','e2e','smoke:auth','smoke:ux','smoke:pages','smoke:api')
  $result = @()
  foreach ($candidate in $candidates) {
    if ($result.Count -ge 8) { break }
    if (($result -notcontains $candidate) -and (Test-ProjectAcceptancePackageScript -PackageJson $PackageJson -Name $candidate)) {
      $result += $candidate
    }
  }
  return $result
}

function Get-ProjectAcceptanceConfig {
  param([string]$ProjectRoot)
  $cfgPath = Join-Path (Join-Path $ProjectRoot '.bridge') 'acceptance.json'
  $cfg = Read-ProjectAcceptanceJson -Path $cfgPath
  if (-not $cfg) { $cfg = [pscustomobject]@{} }

  $pkg = Get-ProjectAcceptancePackage -ProjectRoot $ProjectRoot
  $defaultScripts = @()
  foreach ($name in @('typecheck','lint','build')) {
    if (Test-ProjectAcceptancePackageScript -PackageJson $pkg -Name $name) { $defaultScripts += $name }
  }
  $defaultSmoke = @(Get-ProjectAcceptanceDefaultSmokeScripts -PackageJson $pkg)
  $defaultChecks = @()
  if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'app\api\health\route.ts')) { $defaultChecks += '/api/health=200' }
  if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'app\login\page.tsx')) { $defaultChecks += '/login=200' }
  if (Test-Path -LiteralPath (Join-Path $ProjectRoot 'app\register\page.tsx')) { $defaultChecks += '/register=200' }

  $server = Get-ProjectAcceptanceObjectValue -Obj $cfg -Names @('server') -Default $null
  $checks = @()
  $checksSpecified = $false
  try { if ($server -and ($server.PSObject.Properties.Name -contains 'checks')) { $checksSpecified = $true } } catch {}
  if ($server) { try { $checks = @($server.checks | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) } catch { $checks = @() } }
  if ((-not $checksSpecified) -and $checks.Count -eq 0) { $checks = $defaultChecks }

  $scripts = @(Get-ProjectAcceptanceObjectValue -Obj $cfg -Names @('requiredScripts','scripts') -Default $defaultScripts)
  $smokeScripts = @(Get-ProjectAcceptanceObjectValue -Obj $cfg -Names @('smokeScripts') -Default $defaultSmoke)

  return [pscustomobject]@{
    path = $cfgPath
    requiredScripts = @($scripts | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    smokeScripts = @($smokeScripts | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    readyPath = [string](Get-ProjectAcceptanceObjectValue -Obj $server -Names @('readyPath') -Default '/')
    readyStatuses = @(Get-ProjectAcceptanceObjectValue -Obj $server -Names @('readyStatuses') -Default @('200','204','301','302','307','308','401','403','404'))
    checks = @($checks)
    timeoutSec = [int](Get-ProjectAcceptanceObjectValue -Obj $server -Names @('timeoutSec') -Default 180)
    startScript = [string](Get-ProjectAcceptanceObjectValue -Obj $server -Names @('startScript') -Default 'start')
    startCommand = [string](Get-ProjectAcceptanceObjectValue -Obj $server -Names @('startCommand','command') -Default '')
  }
}

function Get-ProjectAcceptanceFreePort {
  $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse('127.0.0.1'), 0)
  try {
    $listener.Start()
    return [int]$listener.LocalEndpoint.Port
  } finally {
    try { $listener.Stop() } catch {}
  }
}

function Import-ProjectAcceptanceDotEnv {
  param([string]$ProjectRoot, [System.Diagnostics.ProcessStartInfo]$ProcessStartInfo = $null)
  $envFile = Join-Path $ProjectRoot '.env'
  if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) { return @{} }
  $vars = @{}
  foreach ($line in (Get-Content -LiteralPath $envFile -Encoding UTF8)) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
      $name = $matches[1]
      $value = $matches[2].Trim()
      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        if ($value.Length -ge 2) { $value = $value.Substring(1, $value.Length - 2) }
      }
      $vars[$name] = $value
      if ($ProcessStartInfo) { Set-ProjectAcceptanceProcessEnv -ProcessStartInfo $ProcessStartInfo -Name $name -Value $value }
    }
  }
  return $vars
}

function Set-ProjectAcceptanceProcessEnv {
  param(
    [Parameter(Mandatory=$true)]$ProcessStartInfo,
    [Parameter(Mandatory=$true)][string]$Name,
    [AllowNull()][string]$Value
  )

  try {
    if ($null -ne $ProcessStartInfo.EnvironmentVariables) {
      $ProcessStartInfo.EnvironmentVariables[$Name] = [string]$Value
      return
    }
  } catch {}
  try {
    if ($null -ne $ProcessStartInfo.Environment) {
      $ProcessStartInfo.Environment[$Name] = [string]$Value
      return
    }
  } catch {}
  throw ("cannot set process environment variable '{0}'" -f $Name)
}

function Invoke-ProjectAcceptanceProcess {
  param(
    [string]$ProjectRoot,
    [string]$CommandLine,
    [hashtable]$Env = @{},
    [int]$TimeoutSec = 600
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
  $psi.Arguments = '/d /s /c ' + $CommandLine
  $psi.WorkingDirectory = $ProjectRoot
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  [void](Import-ProjectAcceptanceDotEnv -ProjectRoot $ProjectRoot -ProcessStartInfo $psi)
  foreach ($k in @($Env.Keys)) { Set-ProjectAcceptanceProcessEnv -ProcessStartInfo $psi -Name ([string]$k) -Value ([string]$Env[$k]) }
  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  $started = $false
  $out = ''
  try {
    $started = $p.Start()
    if (-not $started) { throw 'Process.Start returned false' }
    $stdoutTask = $p.StandardOutput.ReadToEndAsync()
    $stderrTask = $p.StandardError.ReadToEndAsync()
    $done = $p.WaitForExit([Math]::Max(1, $TimeoutSec) * 1000)
    if (-not $done) {
      try { Stop-ProjectAcceptanceProcessTree -RootPid ([int]$p.Id) } catch { try { $p.Kill() } catch {} }
      return [pscustomobject]@{ ok=$false; exit_code=-1; timed_out=$true; command=$CommandLine; output_tail="timed out after ${TimeoutSec}s" }
    }
    try { $p.WaitForExit() } catch {}
    try { $out = ([string]$stdoutTask.Result) + [Environment]::NewLine + ([string]$stderrTask.Result) } catch { $out = '' }
    $tail = ($out -replace "`r","").Trim()
    if ($tail.Length -gt 4000) { $tail = $tail.Substring($tail.Length - 4000) }
    return [pscustomobject]@{ ok=($p.ExitCode -eq 0); exit_code=[int]$p.ExitCode; timed_out=$false; command=$CommandLine; output_tail=$tail }
  } catch {
    return [pscustomobject]@{ ok=$false; exit_code=-2; timed_out=$false; command=$CommandLine; output_tail=$_.Exception.Message }
  } finally {
    try { $p.Dispose() } catch {}
  }
}

function Get-ProjectAcceptanceStatusCode {
  param([string]$Url, [string]$Method = 'GET')
  try {
    $r = Invoke-WebRequest -UseBasicParsing -DisableKeepAlive -Uri $Url -Method $Method -TimeoutSec 8 -MaximumRedirection 0 -ErrorAction Stop
    return [int]$r.StatusCode
  } catch {
    try { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } } catch {}
    return 0
  }
}

function Join-ProjectAcceptanceUrl {
  param([string]$BaseUrl, [string]$Path)
  if ($Path -match '^(?i)https?://') { return $Path }
  if ([string]::IsNullOrWhiteSpace($Path)) { $Path = '/' }
  if (-not $Path.StartsWith('/')) { $Path = '/' + $Path }
  return $BaseUrl.TrimEnd('/') + $Path
}

function ConvertTo-ProjectAcceptanceStatusSet {
  param([object[]]$Values)
  $out = New-Object 'System.Collections.Generic.List[int]'
  foreach ($v in @($Values)) {
    foreach ($piece in ([string]$v -split ',')) {
      $n = 0
      if ([int]::TryParse($piece.Trim(), [ref]$n)) { [void]$out.Add($n) }
    }
  }
  return @($out.ToArray())
}

function Test-ProjectAcceptanceDynamicPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
  return [bool]($Path -match '(^|/):[^/]+|[[\]]')
}

function Normalize-ProjectAcceptanceJourneyPathCandidate {
  param([string]$Candidate)
  if ([string]::IsNullOrWhiteSpace($Candidate)) { return '' }
  $trimChars = [char[]]@(
    [char]0x20,
    [char]0x09,
    [char]0x0d,
    [char]0x0a,
    [char]0x22,
    [char]0x27,
    [char]0x2c,
    [char]0x3b,
    [char]0x2e,
    [char]0x28,
    [char]0x29
  )
  return ([string]$Candidate).Trim($trimChars)
}

function Test-ProjectAcceptanceStaticLocalPath {
  param([string]$Path)
  $p = Normalize-ProjectAcceptanceJourneyPathCandidate -Candidate $Path
  if ([string]::IsNullOrWhiteSpace($p)) { return $false }
  if ($p -match '^(?i)https?://') { return $false }
  if (-not $p.StartsWith('/')) { return $false }
  if ($p -match '(^|/):[^/]+|\[[^\]]+\]|\{[^}]+\}|<[^>]+>|\*') { return $false }
  return $true
}

function Get-ProjectAcceptanceJourneyStringPath {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  $tokens = @(([string]$Text) -split '\s+')
  for ($i = 0; $i -lt $tokens.Count; $i++) {
    $token = Normalize-ProjectAcceptanceJourneyPathCandidate -Candidate ([string]$tokens[$i])
    if ([string]::IsNullOrWhiteSpace($token)) { continue }
    if ($token.ToUpperInvariant() -eq 'GET' -and ($i + 1) -lt $tokens.Count) {
      $next = Normalize-ProjectAcceptanceJourneyPathCandidate -Candidate ([string]$tokens[$i + 1])
      if (Test-ProjectAcceptanceStaticLocalPath -Path $next) { return $next }
    }
    if (Test-ProjectAcceptanceStaticLocalPath -Path $token) { return $token }
  }
  return ''
}

function Get-ProjectAcceptanceDefaultStatusesForAccess {
  param([string]$Access)
  $a = ([string]$Access).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($a) -or $a -in @('public','guest','anonymous','unauthenticated')) { return @(200) }
  if ($a -in @('user','auth','authenticated','member','admin','private','protected')) { return @(302,303,307,308,401,403) }
  return @(200)
}

function Test-ProjectAcceptanceDeferredWebSurface {
  param($Item)
  if ($null -eq $Item -or $Item -is [string]) { return $false }

  $required = Get-ProjectAcceptanceObjectValue -Obj $Item -Names @('required','acceptance_required','acceptanceRequired','required_for_acceptance','requiredForAcceptance') -Default $null
  if ($null -ne $required) {
    $requiredText = ([string]$required).Trim().ToLowerInvariant()
    if ($requiredText -in @('false','0','no','optional','deferred','later')) { return $true }
  }

  $status = ([string](Get-ProjectAcceptanceObjectValue -Obj $Item -Names @('status','state','phase','stage') -Default '')).Trim().ToLowerInvariant()
  if ($status -in @('deferred','later','future','planned','backlog','not_started','todo','optional')) { return $true }

  $kind = ([string](Get-ProjectAcceptanceObjectValue -Obj $Item -Names @('kind','type','surface_kind','surfaceKind') -Default '')).Trim().ToLowerInvariant()
  if ($kind -in @('api','web','server')) {
    $label = ([string](Get-ProjectAcceptanceObjectValue -Obj $Item -Names @('id','name','title','label') -Default '')).Trim().ToLowerInvariant()
    if ($label -match '(^|[-_\s])(later|future|deferred|optional)($|[-_\s])') { return $true }
  }

  return $false
}

function Parse-ProjectAcceptanceCheck {
  param([string]$Spec, [string]$BaseUrl)
  $s = ([string]$Spec).Trim()
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  $parts = $s -split '=', 2
  $left = $parts[0].Trim()
  $expectedRaw = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '200' }
  $method = 'GET'
  if ($left -match '^(GET|POST|PUT|PATCH|DELETE|HEAD)\s+(.+)$') {
    $method = $matches[1].ToUpperInvariant()
    $left = $matches[2].Trim()
  }
  return [pscustomobject]@{
    spec = $s
    method = $method
    url = (Join-ProjectAcceptanceUrl -BaseUrl $BaseUrl -Path $left)
    expected = @(ConvertTo-ProjectAcceptanceStatusSet -Values @($expectedRaw))
  }
}

function Start-ProjectAcceptanceServer {
  param([string]$ProjectRoot, $Config)
  $port = Get-ProjectAcceptanceFreePort
  $baseUrl = "http://127.0.0.1:$port"
  $startCommand = ''
  try { $startCommand = ([string]$Config.startCommand).Trim() } catch { $startCommand = '' }
  if (-not [string]::IsNullOrWhiteSpace($startCommand)) {
    $cmd = $startCommand.
      Replace('{port}', [string]$port).
      Replace('{host}', '127.0.0.1').
      Replace('{hostname}', '127.0.0.1').
      Replace('{baseUrl}', $baseUrl)
  } else {
    $pkg = Get-ProjectAcceptancePackage -ProjectRoot $ProjectRoot
    $scriptName = [string]$Config.startScript
    if ([string]::IsNullOrWhiteSpace($scriptName)) { $scriptName = 'start' }
    if (-not (Test-ProjectAcceptancePackageScript -PackageJson $pkg -Name $scriptName)) {
      return [pscustomobject]@{ ok=$false; reason="missing package script '$scriptName'" }
    }
    $cmd = "npm.cmd run $scriptName -- --hostname 127.0.0.1 --port $port"
  }
  $logDir = Join-Path $ProjectRoot '.bridge-acceptance'
  if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $outPath = Join-Path $logDir "server-$stamp-$port.out.log"
  $errPath = Join-Path $logDir "server-$stamp-$port.err.log"

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
  $quotedOut = '"' + $outPath + '"'
  $quotedErr = '"' + $errPath + '"'
  $psi.Arguments = '/d /s /c ' + $cmd + ' 1>> ' + $quotedOut + ' 2>> ' + $quotedErr
  $psi.WorkingDirectory = $ProjectRoot
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $false
  $psi.RedirectStandardError = $false
  $psi.CreateNoWindow = $true
  [void](Import-ProjectAcceptanceDotEnv -ProjectRoot $ProjectRoot -ProcessStartInfo $psi)
  Set-ProjectAcceptanceProcessEnv -ProcessStartInfo $psi -Name 'PORT' -Value ([string]$port)
  Set-ProjectAcceptanceProcessEnv -ProcessStartInfo $psi -Name 'HOST' -Value '127.0.0.1'
  Set-ProjectAcceptanceProcessEnv -ProcessStartInfo $psi -Name 'HOSTNAME' -Value '127.0.0.1'
  Set-ProjectAcceptanceProcessEnv -ProcessStartInfo $psi -Name 'NEXT_TELEMETRY_DISABLED' -Value '1'

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  try {
    [void]$proc.Start()
    $readyPath = [string]$Config.readyPath
    if ([string]::IsNullOrWhiteSpace($readyPath)) { $readyPath = '/' }
    $readyUrl = Join-ProjectAcceptanceUrl -BaseUrl $baseUrl -Path $readyPath
    $readyStatuses = @(ConvertTo-ProjectAcceptanceStatusSet -Values @($Config.readyStatuses))
    if ($readyStatuses.Count -eq 0) { $readyStatuses = @(200,204,301,302,307,308,401,403,404) }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt [int]$Config.timeoutSec) {
      if ($proc.HasExited) {
        return [pscustomobject]@{ ok=$false; reason="server exited before ready code=$($proc.ExitCode)"; process=$proc; baseUrl=$baseUrl; out=$outPath; err=$errPath }
      }
      $code = Get-ProjectAcceptanceStatusCode -Url $readyUrl
      if (@($readyStatuses) -contains $code) {
        return [pscustomobject]@{ ok=$true; process=$proc; baseUrl=$baseUrl; port=$port; command=$cmd; out=$outPath; err=$errPath; readyStatus=$code }
      }
      Start-Sleep -Seconds 1
    }
    return [pscustomobject]@{ ok=$false; reason="server not ready after $([int]$Config.timeoutSec)s"; process=$proc; baseUrl=$baseUrl; out=$outPath; err=$errPath }
  } catch {
    return [pscustomobject]@{ ok=$false; reason=$_.Exception.Message; process=$proc; baseUrl=$baseUrl; out=$outPath; err=$errPath }
  }
}

function Stop-ProjectAcceptanceProcessTree {
  param([int]$RootPid)
  if ($RootPid -le 0) { return }
  $children = New-Object 'System.Collections.Generic.List[int]'
  try {
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
    function Add-ProjectAcceptanceChildren {
      param([int]$ParentPid, [object[]]$AllProcesses, $List)
      foreach ($p in @($AllProcesses | Where-Object { [int]$_.ParentProcessId -eq $ParentPid })) {
        Add-ProjectAcceptanceChildren -ParentPid ([int]$p.ProcessId) -AllProcesses $AllProcesses -List $List
        [void]$List.Add([int]$p.ProcessId)
      }
    }
    Add-ProjectAcceptanceChildren -ParentPid $RootPid -AllProcesses $all -List $children
  } catch {}
  foreach ($childPid in @($children.ToArray())) {
    try { Stop-Process -Id $childPid -Force -ErrorAction SilentlyContinue } catch {}
  }
  try { Stop-Process -Id $RootPid -Force -ErrorAction SilentlyContinue } catch {}
}

function Stop-ProjectAcceptanceServer {
  param($Server)
  try {
    if ($Server -and $Server.process -and -not $Server.process.HasExited) {
      Stop-ProjectAcceptanceProcessTree -RootPid ([int]$Server.process.Id)
      try { if (-not $Server.process.WaitForExit(5000)) { $Server.process.Kill() } } catch {}
    }
  } catch {}
}

function New-ProjectAcceptanceStep {
  param([string]$Name, [bool]$Ok, [string]$Details = '', [int]$ExitCode = 0)
  return [pscustomobject]@{ name=$Name; ok=[bool]$Ok; exit_code=[int]$ExitCode; details=[string]$Details }
}

function Get-ProjectAcceptanceFileText {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } catch { return '' }
}

function Get-ProjectAcceptanceSha256 {
  param([string]$Text)
  try {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
  } catch {
    return ''
  }
}

function Get-ProjectAcceptancePlanContractPath {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return '' }
  return (Join-Path (Join-Path $ProjectRoot '.bridge') 'project-contract.json')
}

function Get-ProjectAcceptancePlanningStageDefinitions {
  return @(
    [pscustomobject]@{ id='brief';       path='PROJECT_BRIEF.md';       min_chars=800;  label='project brief' },
    [pscustomobject]@{ id='product';     path='DISCUSS_PRODUCT.md';     min_chars=900;  label='product discussion' },
    [pscustomobject]@{ id='ux';          path='DISCUSS_UX.md';          min_chars=900;  label='UX discussion' },
    [pscustomobject]@{ id='ui';          path='DISCUSS_UI.md';          min_chars=800;  label='UI discussion' },
    [pscustomobject]@{ id='backend';     path='DISCUSS_BACKEND.md';     min_chars=900;  label='backend discussion' },
    [pscustomobject]@{ id='qa';          path='DISCUSS_QA.md';          min_chars=800;  label='QA/acceptance discussion' },
    [pscustomobject]@{ id='integration'; path='DISCUSS_INTEGRATION.md'; min_chars=800;  label='cross-stage integration review' }
  )
}

function Get-ProjectAcceptancePlanSignatureFiles {
  $files = New-Object 'System.Collections.Generic.List[string]'
  foreach ($stage in @(Get-ProjectAcceptancePlanningStageDefinitions)) {
    [void]$files.Add([string]$stage.path)
  }
  foreach ($rel in @('PROJECT_MAP.md','PROJECT_PLAN.md','.bridge\project-contract.json')) {
    [void]$files.Add([string]$rel)
  }
  return @($files.ToArray())
}

function Get-ProjectAcceptancePlanSignature {
  param([string]$ProjectRoot)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { return '' }
  $parts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($rel in @(Get-ProjectAcceptancePlanSignatureFiles)) {
    $path = Join-Path $ProjectRoot $rel
    [void]$parts.Add($rel.Replace('\','/') + "`n" + (Get-ProjectAcceptanceFileText -Path $path))
  }
  return (Get-ProjectAcceptanceSha256 -Text (($parts.ToArray()) -join "`n---bridge-plan-part---`n"))
}

function Get-ProjectAcceptanceContractArray {
  param($Obj, [string[]]$Names = @())
  $v = Get-ProjectAcceptanceObjectValue -Obj $Obj -Names $Names -Default $null
  if ($null -eq $v) { return @() }
  try {
    if ($v -is [string]) {
      if ([string]::IsNullOrWhiteSpace([string]$v)) { return @() }
      return @([string]$v)
    }
    return @($v | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) })
  } catch {
    return @()
  }
}

function Get-ProjectAcceptanceContractCount {
  param($Obj, [string[]]$Names = @())
  $arr = @(Get-ProjectAcceptanceContractArray -Obj $Obj -Names $Names)
  if ($arr.Count -gt 0) { return [int]$arr.Count }
  $v = Get-ProjectAcceptanceObjectValue -Obj $Obj -Names $Names -Default $null
  try {
    if ($v -and $v.PSObject.Properties.Count -gt 0) { return [int]$v.PSObject.Properties.Count }
  } catch {}
  return 0
}

function Get-ProjectAcceptancePlanningStageById {
  param($PlanningFlow)
  $map = @{}
  $stages = @(Get-ProjectAcceptanceContractArray -Obj $PlanningFlow -Names @('stages','planning_stages','discussions'))
  foreach ($stage in @($stages)) {
    $id = ([string](Get-ProjectAcceptanceObjectValue -Obj $stage -Names @('id','stage','name') -Default '')).Trim().ToLowerInvariant()
    if (-not [string]::IsNullOrWhiteSpace($id)) { $map[$id] = $stage }
  }
  return $map
}

function Read-ProjectAcceptancePlanContract {
  param([string]$ProjectRoot)
  $path = Get-ProjectAcceptancePlanContractPath -ProjectRoot $ProjectRoot
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return [pscustomobject]@{ exists=$false; path=$path; contract=$null; error='' }
  }
  try {
    return [pscustomobject]@{
      exists = $true
      path = $path
      contract = ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json)
      error = ''
    }
  } catch {
    return [pscustomobject]@{ exists=$true; path=$path; contract=$null; error=$_.Exception.Message }
  }
}

function Get-ProjectAcceptancePlanContractSteps {
  param([string]$ProjectRoot)
  $steps = New-Object 'System.Collections.Generic.List[object]'
  $mapPath = Join-Path $ProjectRoot 'PROJECT_MAP.md'
  $planPath = Join-Path $ProjectRoot 'PROJECT_PLAN.md'
  $mapText = Get-ProjectAcceptanceFileText -Path $mapPath
  $planText = Get-ProjectAcceptanceFileText -Path $planPath
  [void]$steps.Add((New-ProjectAcceptanceStep -Name 'plan:PROJECT_MAP.md-depth' -Ok ($mapText.Length -ge 1500) -Details ("chars=" + [string]$mapText.Length)))
  [void]$steps.Add((New-ProjectAcceptanceStep -Name 'plan:PROJECT_PLAN.md-depth' -Ok ($planText.Length -ge 2000) -Details ("chars=" + [string]$planText.Length)))
  foreach ($stageDef in @(Get-ProjectAcceptancePlanningStageDefinitions)) {
    $stagePath = Join-Path $ProjectRoot ([string]$stageDef.path)
    $stageText = Get-ProjectAcceptanceFileText -Path $stagePath
    [void]$steps.Add((New-ProjectAcceptanceStep -Name ("plan-stage-doc:" + [string]$stageDef.id) -Ok ($stageText.Length -ge [int]$stageDef.min_chars) -Details (([string]$stageDef.path) + " chars=" + [string]$stageText.Length + " min=" + [string]$stageDef.min_chars)))
  }

  $info = Read-ProjectAcceptancePlanContract -ProjectRoot $ProjectRoot
  [void]$steps.Add((New-ProjectAcceptanceStep -Name 'plan-contract:present' -Ok ([bool]$info.exists -and $null -ne $info.contract) -Details ($(if ($info.contract) { [string]$info.path } elseif (-not [string]::IsNullOrWhiteSpace([string]$info.error)) { [string]$info.error } else { [string]$info.path }))))
  if (-not $info.contract) { return @($steps.ToArray()) }

  $goal = [string](Get-ProjectAcceptanceObjectValue -Obj $info.contract -Names @('project_goal','goal','mission','outcome') -Default '')
  $reqCount = [int](Get-ProjectAcceptanceContractCount -Obj $info.contract -Names @('requirements','capabilities','features','functional_requirements'))
  $surfaceCount = [int](Get-ProjectAcceptanceContractCount -Obj $info.contract -Names @('screens','routes','views','surfaces','pages','endpoints','modules'))
  $journeyCount = [int](Get-ProjectAcceptanceContractCount -Obj $info.contract -Names @('user_journeys','journeys','flows','workflows','scenarios'))
  $acceptanceCount = [int](Get-ProjectAcceptanceContractCount -Obj $info.contract -Names @('acceptance_scenarios','acceptance','done_criteria','checks','quality_gates'))
  $interfaceCount = [int](Get-ProjectAcceptanceContractCount -Obj $info.contract -Names @('ux_contract','ux','interface_contract','experience_principles','interaction_model'))
  $planningFlow = Get-ProjectAcceptanceObjectValue -Obj $info.contract -Names @('planning_flow','planningFlow','discussion_flow') -Default $null
  $stageById = Get-ProjectAcceptancePlanningStageById -PlanningFlow $planningFlow
  [void]$steps.Add((New-ProjectAcceptanceStep -Name 'plan-contract:goal' -Ok ($goal.Trim().Length -ge 40) -Details ("chars=" + [string]$goal.Trim().Length)))
  [void]$steps.Add((New-ProjectAcceptanceStep -Name 'plan-contract:requirements' -Ok ($reqCount -ge 3) -Details ("count=" + [string]$reqCount)))
  [void]$steps.Add((New-ProjectAcceptanceStep -Name 'plan-contract:surfaces' -Ok ($surfaceCount -ge 2) -Details ("count=" + [string]$surfaceCount)))
  [void]$steps.Add((New-ProjectAcceptanceStep -Name 'plan-contract:journeys' -Ok ($journeyCount -ge 2) -Details ("count=" + [string]$journeyCount)))
  [void]$steps.Add((New-ProjectAcceptanceStep -Name 'plan-contract:acceptance' -Ok ($acceptanceCount -ge 3) -Details ("count=" + [string]$acceptanceCount)))
  [void]$steps.Add((New-ProjectAcceptanceStep -Name 'plan-contract:interface' -Ok ($interfaceCount -ge 1) -Details ("count=" + [string]$interfaceCount)))
  [void]$steps.Add((New-ProjectAcceptanceStep -Name 'plan-contract:planning-flow' -Ok ($null -ne $planningFlow -and [int]$stageById.Count -ge 7) -Details ("count=" + [string]$stageById.Count)))
  foreach ($stageDef in @(Get-ProjectAcceptancePlanningStageDefinitions)) {
    $sid = [string]$stageDef.id
    $stageOk = $false
    $details = 'missing'
    if ($stageById.ContainsKey($sid)) {
      $stage = $stageById[$sid]
      $status = ([string](Get-ProjectAcceptanceObjectValue -Obj $stage -Names @('status','state') -Default '')).Trim().ToLowerInvariant()
      $summary = ([string](Get-ProjectAcceptanceObjectValue -Obj $stage -Names @('summary','outcome','decision_summary') -Default '')).Trim()
      $stageOk = ($status -in @('complete','approved','done') -and $summary.Length -ge 40)
      $details = 'status=' + $status + ' summary_chars=' + [string]$summary.Length
    }
    [void]$steps.Add((New-ProjectAcceptanceStep -Name ('plan-contract-stage:' + $sid) -Ok ([bool]$stageOk) -Details $details))
  }
  $integration = $null
  try { if ($stageById.ContainsKey('integration')) { $integration = $stageById['integration'] } } catch {}
  $integrationDeps = @(Get-ProjectAcceptanceContractArray -Obj $integration -Names @('depends_on','dependsOn','validated_stages'))
  [void]$steps.Add((New-ProjectAcceptanceStep -Name 'plan-contract:integration-validates-prior-stages' -Ok ($integrationDeps.Count -ge 5) -Details ('depends_on=' + (($integrationDeps | ForEach-Object { [string]$_ }) -join ','))))
  return @($steps.ToArray())
}

function Resolve-ProjectAcceptanceEntryPath {
  param([string]$ProjectRoot, [string]$Entry)
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or [string]::IsNullOrWhiteSpace($Entry)) { return '' }
  try {
    $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot)
    $candidate = [string]$Entry
    if (-not [System.IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $rootFull $candidate }
    $full = [System.IO.Path]::GetFullPath($candidate)
    if (-not $full.StartsWith($rootFull.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase) -and -not $full.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
      return ''
    }
    return $full
  } catch {
    return ''
  }
}

function Test-ProjectAcceptanceStubBindingLine {
  param([string]$Line, [string]$Symbol)
  if ([string]::IsNullOrWhiteSpace($Line) -or [string]::IsNullOrWhiteSpace($Symbol)) { return $false }
  $trimmed = $Line.Trim()
  if ($trimmed.StartsWith('//') -or $trimmed.StartsWith('#') -or $trimmed.StartsWith('*') -or $trimmed.StartsWith('<!--')) { return $false }
  $symbolPattern = '(?<![A-Za-z0-9_$])' + [regex]::Escape($Symbol) + '(?![A-Za-z0-9_$])'
  if ($trimmed -notmatch $symbolPattern) { return $false }
  return ($trimmed -match '\b(import|require|from|new|provider|providers|binding|bindings|bind|container|useFactory|factory|const|let|var)\b|[=:]')
}

function Get-ProjectAcceptanceProductionEntryPointFact {
  param([string]$ProjectRoot)
  $info = Read-ProjectAcceptancePlanContract -ProjectRoot $ProjectRoot
  if (-not $info.contract) {
    return [pscustomobject]@{ required=$false; ok=$true; entry_count=0; symbol_count=0; violations=@(); reason='contract missing' }
  }
  $entries = @(Get-ProjectAcceptanceContractArray -Obj $info.contract -Names @('production_entrypoints','productionEntryPoints'))
  $symbols = @(Get-ProjectAcceptanceContractArray -Obj $info.contract -Names @('forbidden_stub_symbols','forbiddenStubSymbols'))
  $entries = @($entries | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $symbols = @($symbols | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $required = ($entries.Count -gt 0 -and $symbols.Count -gt 0)
  $violations = New-Object 'System.Collections.Generic.List[object]'
  if (-not $required) {
    return [pscustomobject]@{ required=$false; ok=$true; entry_count=[int]$entries.Count; symbol_count=[int]$symbols.Count; violations=@(); reason='not configured' }
  }
  foreach ($entry in @($entries)) {
    $fullPath = Resolve-ProjectAcceptanceEntryPath -ProjectRoot $ProjectRoot -Entry $entry
    if ([string]::IsNullOrWhiteSpace($fullPath) -or -not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
      [void]$violations.Add([pscustomobject][ordered]@{ entry=$entry; symbol=''; line=0; reason='entrypoint-missing' })
      continue
    }
    $lines = @()
    try { $lines = [System.IO.File]::ReadAllLines($fullPath, [System.Text.Encoding]::UTF8) } catch { $lines = @() }
    for ($i = 0; $i -lt $lines.Count; $i++) {
      foreach ($symbol in @($symbols)) {
        if (Test-ProjectAcceptanceStubBindingLine -Line ([string]$lines[$i]) -Symbol ([string]$symbol)) {
          [void]$violations.Add([pscustomobject][ordered]@{ entry=$entry; symbol=[string]$symbol; line=($i + 1); reason='forbidden-stub-binding' })
        }
      }
    }
  }
  return [pscustomobject]@{
    required = $true
    ok = ($violations.Count -eq 0)
    entry_count = [int]$entries.Count
    symbol_count = [int]$symbols.Count
    violations = @($violations.ToArray())
    reason = $(if ($violations.Count -eq 0) { 'no forbidden stub bindings' } else { 'forbidden stub binding found' })
  }
}

function New-ProjectAcceptanceProductionEntryPointStep {
  param($Fact)
  $details = 'required=' + [string]$Fact.required +
    ' entry_count=' + [string]$Fact.entry_count +
    ' symbol_count=' + [string]$Fact.symbol_count +
    ' reason=' + [string]$Fact.reason
  $sample = @($Fact.violations | Select-Object -First 5 | ForEach-Object {
    [string]$_.entry + ':' + [string]$_.line + ':' + [string]$_.symbol + ':' + [string]$_.reason
  })
  if ($sample.Count -gt 0) { $details += ' sample=' + ($sample -join ' | ') }
  return (New-ProjectAcceptanceStep -Name 'plan-contract:production-entrypoints-no-stubs' -Ok ([bool]$Fact.ok) -Details $details)
}

function Get-ProjectAcceptancePlanContractWebSpecs {
  param([string]$ProjectRoot)
  $info = Read-ProjectAcceptancePlanContract -ProjectRoot $ProjectRoot
  if (-not $info.contract) { return @() }
  $items = @()
  foreach ($names in @(
    @('screens'),
    @('routes'),
    @('views'),
    @('surfaces'),
    @('pages'),
    @('endpoints')
  )) {
    $items += @(Get-ProjectAcceptanceContractArray -Obj $info.contract -Names $names)
  }
  $specs = New-Object 'System.Collections.Generic.List[object]'
  foreach ($it in @($items)) {
    if (Test-ProjectAcceptanceDeferredWebSurface -Item $it) { continue }
    $path = [string](Get-ProjectAcceptanceObjectValue -Obj $it -Names @('test_path','testPath','example_path','examplePath','sample_path','samplePath','path','route','url','href') -Default '')
    if ([string]::IsNullOrWhiteSpace($path)) { continue }
    if (-not ($path.StartsWith('/') -or $path -match '^(?i)https?://')) { continue }
    if (Test-ProjectAcceptanceDynamicPath -Path $path) { continue }
    $name = [string](Get-ProjectAcceptanceObjectValue -Obj $it -Names @('id','name','title','label') -Default $path)
    $access = [string](Get-ProjectAcceptanceObjectValue -Obj $it -Names @('access','auth','visibility','role') -Default '')
    $explicitExpected = Get-ProjectAcceptanceObjectValue -Obj $it -Names @('expected_status','expectedStatus','http_status','httpStatus') -Default $null
    $expected = if ($null -ne $explicitExpected) { @($explicitExpected) } else { @(Get-ProjectAcceptanceDefaultStatusesForAccess -Access $access) }
    $tokens = @(Get-ProjectAcceptanceContractArray -Obj $it -Names @('must_contain','mustContain','contains','visible_text','visibleText','text_assertions'))
    [void]$specs.Add([pscustomobject]@{
      name = $name
      path = $path
      expected = @(ConvertTo-ProjectAcceptanceStatusSet -Values @($expected))
      access = $access
      must_contain = @($tokens | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 8)
    })
  }
  return @($specs.ToArray())
}

function Get-ProjectAcceptancePlanContractJourneySpecs {
  param([string]$ProjectRoot)
  $info = Read-ProjectAcceptancePlanContract -ProjectRoot $ProjectRoot
  if (-not $info.contract) { return @() }

  $journeys = @()
  foreach ($names in @(
    @('user_journeys'),
    @('journeys'),
    @('flows'),
    @('workflows'),
    @('scenarios')
  )) {
    $journeys += @(Get-ProjectAcceptanceContractArray -Obj $info.contract -Names $names)
  }

  $specs = New-Object 'System.Collections.Generic.List[object]'
  $journeyOrdinal = 0
  foreach ($journey in @($journeys)) {
    if ($specs.Count -ge 50) { break }
    $journeyOrdinal++
    $journeyId = ([string](Get-ProjectAcceptanceObjectValue -Obj $journey -Names @('id','name','title','label') -Default '')).Trim()
    if ([string]::IsNullOrWhiteSpace($journeyId)) { $journeyId = 'journey-' + [string]$journeyOrdinal }
    $journeyAccess = ([string](Get-ProjectAcceptanceObjectValue -Obj $journey -Names @('access','role','persona','actor') -Default '')).Trim()
    $steps = @(Get-ProjectAcceptanceContractArray -Obj $journey -Names @('steps'))
    $stepIndex = 0
    foreach ($step in @($steps)) {
      $stepIndex++
      if ($specs.Count -ge 50) { break }

      $path = ''
      $name = ''
      $access = $journeyAccess
      $explicitExpected = $null
      $tokens = @()

      if ($step -is [string]) {
        $path = Get-ProjectAcceptanceJourneyStringPath -Text ([string]$step)
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $name = $path
      } else {
        $rawPath = [string](Get-ProjectAcceptanceObjectValue -Obj $step -Names @('path','route','url','href','test_path','testPath') -Default '')
        $path = Normalize-ProjectAcceptanceJourneyPathCandidate -Candidate $rawPath
        if (-not (Test-ProjectAcceptanceStaticLocalPath -Path $path)) { continue }
        $name = ([string](Get-ProjectAcceptanceObjectValue -Obj $step -Names @('id','name','title','label','action') -Default $path)).Trim()
        $stepAccess = ([string](Get-ProjectAcceptanceObjectValue -Obj $step -Names @('access','role','persona','actor','auth','visibility') -Default '')).Trim()
        if (-not [string]::IsNullOrWhiteSpace($stepAccess)) { $access = $stepAccess }
        $explicitExpected = Get-ProjectAcceptanceObjectValue -Obj $step -Names @('expected_status','expectedStatus','http_status','httpStatus') -Default $null
        $tokens = @(Get-ProjectAcceptanceContractArray -Obj $step -Names @('must_contain','mustContain','contains','visible_text','visibleText','text_assertions'))
      }

      if (-not (Test-ProjectAcceptanceStaticLocalPath -Path $path)) { continue }
      $expected = if ($null -ne $explicitExpected) { @($explicitExpected) } else { @(Get-ProjectAcceptanceDefaultStatusesForAccess -Access $access) }
      [void]$specs.Add([pscustomobject]@{
        name = $name
        journey_id = $journeyId
        step_index = [int]$stepIndex
        path = $path
        expected = @(ConvertTo-ProjectAcceptanceStatusSet -Values @($expected))
        access = $access
        must_contain = @($tokens | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 8)
        source = 'journey'
      })
    }
  }
  return @($specs.ToArray())
}

function Get-ProjectAcceptanceBrowserSmokeScripts {
  param([object[]]$SmokeScripts = @())
  $result = @()
  foreach ($scriptName in @($SmokeScripts)) {
    $name = ([string]$scriptName).Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $lower = $name.ToLowerInvariant()
    $isBrowserSmoke = ($lower -eq 'smoke:launch' -or $lower -match 'browser' -or $lower -match 'e2e')
    if ($isBrowserSmoke -and ($result -notcontains $name)) { $result += $name }
  }
  return $result
}

function Get-ProjectAcceptancePlanContractNonWebEvidence {
  param([string]$ProjectRoot)
  $info = Read-ProjectAcceptancePlanContract -ProjectRoot $ProjectRoot
  if (-not $info.contract) {
    return [pscustomobject]@{
      surface_count = 0
      command_check_count = 0
      surface_kinds = @()
      command_check_ids = @()
      ok = $false
    }
  }

  $nonWebKinds = @('cli','artifact','report','file','document','data','manifest')
  $surfaceKinds = New-Object 'System.Collections.Generic.List[string]'
  foreach ($surface in @(Get-ProjectAcceptanceContractArray -Obj $info.contract -Names @('surfaces'))) {
    if ($surface -is [string]) { continue }
    $kind = ([string](Get-ProjectAcceptanceObjectValue -Obj $surface -Names @('kind','type','surface_kind','surfaceKind') -Default '')).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($kind)) { continue }
    if ($nonWebKinds -contains $kind) { [void]$surfaceKinds.Add($kind) }
  }

  $commandIds = New-Object 'System.Collections.Generic.List[string]'
  foreach ($check in @(Get-ProjectAcceptanceContractArray -Obj $info.contract -Names @('checks','quality_gates','done_criteria'))) {
    if ($check -is [string]) { continue }
    $command = ([string](Get-ProjectAcceptanceObjectValue -Obj $check -Names @('command','cmd','shell','run') -Default '')).Trim()
    if ([string]::IsNullOrWhiteSpace($command)) { continue }
    $id = ([string](Get-ProjectAcceptanceObjectValue -Obj $check -Names @('id','name','title','label') -Default $command)).Trim()
    if ([string]::IsNullOrWhiteSpace($id)) { $id = $command }
    [void]$commandIds.Add($id)
  }

  return [pscustomobject]@{
    surface_count = [int]$surfaceKinds.Count
    command_check_count = [int]$commandIds.Count
    surface_kinds = @($surfaceKinds.ToArray() | Select-Object -Unique)
    command_check_ids = @($commandIds.ToArray() | Select-Object -First 12)
    ok = ([int]$surfaceKinds.Count -gt 0 -and [int]$commandIds.Count -gt 0)
  }
}

function Get-ProjectAcceptancePlanContractJourneyTraceCount {
  param([string]$ProjectRoot)
  $info = Read-ProjectAcceptancePlanContract -ProjectRoot $ProjectRoot
  if (-not $info.contract) { return 0 }

  $journeys = @()
  foreach ($names in @(
    @('user_journeys'),
    @('journeys'),
    @('flows'),
    @('workflows'),
    @('scenarios')
  )) {
    $journeys += @(Get-ProjectAcceptanceContractArray -Obj $info.contract -Names $names)
  }

  $traceCount = 0
  foreach ($journey in @($journeys)) {
    if ($journey -is [string]) { continue }
    $traces = @(Get-ProjectAcceptanceContractArray -Obj $journey -Names @('acceptance_trace','acceptanceTrace','acceptance','checks','coverage'))
    foreach ($trace in @($traces)) {
      if (-not [string]::IsNullOrWhiteSpace([string]$trace)) { $traceCount++ }
    }
  }
  return [int]$traceCount
}

function Get-ProjectAcceptanceJourneyCoverageFact {
  param([string]$ProjectRoot, $Config)
  $info = Read-ProjectAcceptancePlanContract -ProjectRoot $ProjectRoot
  $journeyCount = 0
  if ($info.contract) {
    $journeyCount = [int](Get-ProjectAcceptanceContractCount -Obj $info.contract -Names @('user_journeys','journeys','flows','workflows','scenarios'))
  }
  $journeyWebSpecs = @(Get-ProjectAcceptancePlanContractJourneySpecs -ProjectRoot $ProjectRoot)
  $browserSmokeScripts = @(Get-ProjectAcceptanceBrowserSmokeScripts -SmokeScripts @($Config.smokeScripts))
  $nonWebEvidence = Get-ProjectAcceptancePlanContractNonWebEvidence -ProjectRoot $ProjectRoot
  $acceptanceTraceCount = Get-ProjectAcceptancePlanContractJourneyTraceCount -ProjectRoot $ProjectRoot
  $required = ($journeyCount -gt 0)
  $ok = $true
  $reason = 'no journeys declared'
  if ($required) {
    if ($journeyWebSpecs.Count -gt 0) {
      $reason = 'static journey checks present'
    } elseif ($browserSmokeScripts.Count -gt 0) {
      $reason = 'browser/e2e smoke script present'
    } elseif ([bool]$nonWebEvidence.ok) {
      $reason = 'cli/artifact contract checks present'
    } elseif ($acceptanceTraceCount -gt 0) {
      $reason = 'journey acceptance traces present'
    } else {
      $ok = $false
      $reason = 'journeys declared but no static journey checks, browser/e2e smoke script, cli/artifact contract checks, or journey acceptance traces'
    }
  }
  return [pscustomobject]@{
    required = [bool]$required
    ok = [bool]$ok
    journey_count = [int]$journeyCount
    journey_web_specs_count = [int]$journeyWebSpecs.Count
    browser_smoke_scripts = @($browserSmokeScripts)
    acceptance_trace_count = [int]$acceptanceTraceCount
    non_web_surface_count = [int]$nonWebEvidence.surface_count
    non_web_command_check_count = [int]$nonWebEvidence.command_check_count
    non_web_surface_kinds = @($nonWebEvidence.surface_kinds)
    non_web_command_check_ids = @($nonWebEvidence.command_check_ids)
    reason = [string]$reason
  }
}

function Get-ProjectAcceptanceWebAcceptanceFact {
  param([string]$ProjectRoot, $Config)
  $contractWebSpecs = @(Get-ProjectAcceptancePlanContractWebSpecs -ProjectRoot $ProjectRoot)
  $contractJourneySpecs = @(Get-ProjectAcceptancePlanContractJourneySpecs -ProjectRoot $ProjectRoot)
  $configChecks = @()
  try { $configChecks = @($Config.checks) } catch { $configChecks = @() }
  return [pscustomobject]@{
    required = ($configChecks.Count -gt 0 -or $contractWebSpecs.Count -gt 0 -or $contractJourneySpecs.Count -gt 0)
    config_checks_count = [int]$configChecks.Count
    contract_web_specs_count = [int]$contractWebSpecs.Count
    contract_journey_specs_count = [int]$contractJourneySpecs.Count
  }
}

function New-ProjectAcceptanceJourneyCoverageStep {
  param($Fact)
  $details = 'required=' + [string]$Fact.required +
    ' journey_count=' + [string]$Fact.journey_count +
    ' journey_web_specs_count=' + [string]$Fact.journey_web_specs_count +
    ' browser_smoke_scripts=' + ((@($Fact.browser_smoke_scripts) | ForEach-Object { [string]$_ }) -join ',') +
    ' acceptance_trace_count=' + [string]$Fact.acceptance_trace_count +
    ' non_web_surface_count=' + [string]$Fact.non_web_surface_count +
    ' non_web_command_check_count=' + [string]$Fact.non_web_command_check_count +
    ' non_web_surface_kinds=' + ((@($Fact.non_web_surface_kinds) | ForEach-Object { [string]$_ }) -join ',') +
    ' non_web_command_check_ids=' + ((@($Fact.non_web_command_check_ids) | ForEach-Object { [string]$_ }) -join ',') +
    ' reason=' + [string]$Fact.reason
  return (New-ProjectAcceptanceStep -Name 'plan-contract:journey-coverage' -Ok ([bool]$Fact.ok) -Details $details)
}

function Invoke-ProjectAcceptanceHttpText {
  param([string]$Url)
  try {
    $r = Invoke-WebRequest -UseBasicParsing -DisableKeepAlive -Uri $Url -Method GET -TimeoutSec 10 -MaximumRedirection 0 -ErrorAction Stop
    return [pscustomobject]@{ status=[int]$r.StatusCode; text=[string]$r.Content; error='' }
  } catch {
    $code = 0
    try { if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } } catch {}
    return [pscustomobject]@{ status=$code; text=''; error=$_.Exception.Message }
  }
}

function Invoke-ProjectAcceptance {
  param(
    [string]$Channel = '',
    [string]$ProjectRoot = '',
    [string]$Trigger = 'manual',
    [switch]$CreateFixTask
  )
  $ch = Get-ProjectAcceptanceChannel -Channel $Channel
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $binding = Get-ProjectAcceptanceBinding -Channel $ch
    if ($binding) { $ProjectRoot = [string]$binding.project_root }
  }
  if ([string]::IsNullOrWhiteSpace($ProjectRoot) -or -not (Test-Path -LiteralPath $ProjectRoot -PathType Container)) {
    return [pscustomobject]@{ ran=$false; reason='project-root-missing'; channel=$ch; project_root=$ProjectRoot }
  }

  Write-ProjectAcceptanceTrace -Channel $ch -Text "start trigger=$Trigger root=$ProjectRoot"
  $cfg = Get-ProjectAcceptanceConfig -ProjectRoot $ProjectRoot
  $head = Get-ProjectAcceptanceGitHead -ProjectRoot $ProjectRoot
  $steps = New-Object 'System.Collections.Generic.List[object]'
  $planSignature = Get-ProjectAcceptancePlanSignature -ProjectRoot $ProjectRoot
  $planContractPath = Get-ProjectAcceptancePlanContractPath -ProjectRoot $ProjectRoot
  foreach ($planStep in @(Get-ProjectAcceptancePlanContractSteps -ProjectRoot $ProjectRoot)) {
    [void]$steps.Add($planStep)
  }
  [void]$steps.Add((New-ProjectAcceptanceProductionEntryPointStep -Fact (Get-ProjectAcceptanceProductionEntryPointFact -ProjectRoot $ProjectRoot)))
  $trackedGeneratedArtifacts = @(Get-ProjectTrackedGeneratedArtifactPaths -ProjectRoot $ProjectRoot -ExcludeVerificationArtifacts)
  $artifactDetails = if ($trackedGeneratedArtifacts.Count -eq 0) {
    'none'
  } else {
    'count=' + [string]$trackedGeneratedArtifacts.Count + ' sample=' + (($trackedGeneratedArtifacts | Select-Object -First 20) -join ', ')
  }
  [void]$steps.Add((New-ProjectAcceptanceStep -Name 'repo:generated-artifacts-not-tracked' -Ok ($trackedGeneratedArtifacts.Count -eq 0) -Details $artifactDetails))
  $journeyCoverage = Get-ProjectAcceptanceJourneyCoverageFact -ProjectRoot $ProjectRoot -Config $cfg
  [void]$steps.Add((New-ProjectAcceptanceJourneyCoverageStep -Fact $journeyCoverage))

  foreach ($scriptName in @($cfg.requiredScripts)) {
    Write-ProjectAcceptanceTrace -Channel $ch -Text "script start $scriptName"
    $pkg = Get-ProjectAcceptancePackage -ProjectRoot $ProjectRoot
    if (-not (Test-ProjectAcceptancePackageScript -PackageJson $pkg -Name $scriptName)) {
      [void]$steps.Add((New-ProjectAcceptanceStep -Name "script:$scriptName" -Ok $true -Details 'missing script, skipped'))
      Write-ProjectAcceptanceTrace -Channel $ch -Text "script skip $scriptName"
      continue
    }
    $res = Invoke-ProjectAcceptanceProcess -ProjectRoot $ProjectRoot -CommandLine "npm.cmd run $scriptName" -TimeoutSec 900
    [void]$steps.Add((New-ProjectAcceptanceStep -Name "script:$scriptName" -Ok ([bool]$res.ok) -ExitCode ([int]$res.exit_code) -Details ([string]$res.output_tail)))
    Write-ProjectAcceptanceTrace -Channel $ch -Text ("script done " + $scriptName + " ok=" + [string]$res.ok + " exit=" + [string]$res.exit_code)
  }

  $contractWebSpecs = @(Get-ProjectAcceptancePlanContractWebSpecs -ProjectRoot $ProjectRoot)
  $contractJourneySpecs = @(Get-ProjectAcceptancePlanContractJourneySpecs -ProjectRoot $ProjectRoot)
  $webAcceptance = Get-ProjectAcceptanceWebAcceptanceFact -ProjectRoot $ProjectRoot -Config $cfg
  if ([bool]$webAcceptance.required) {
    $webServer = $null
    try {
      Write-ProjectAcceptanceTrace -Channel $ch -Text "web server start"
      $webServer = Start-ProjectAcceptanceServer -ProjectRoot $ProjectRoot -Config $cfg
      [void]$steps.Add((New-ProjectAcceptanceStep -Name 'server:web-start' -Ok ([bool]$webServer.ok) -Details ($(if ($webServer.ok) { "ready $($webServer.baseUrl) status=$($webServer.readyStatus)" } else { [string]$webServer.reason }))))
      Write-ProjectAcceptanceTrace -Channel $ch -Text ("web server done ok=" + [string]$webServer.ok + " base=" + [string]$webServer.baseUrl)
      if ($webServer.ok) {
        foreach ($spec in @($cfg.checks)) {
          Write-ProjectAcceptanceTrace -Channel $ch -Text ("web start " + [string]$spec)
          $check = Parse-ProjectAcceptanceCheck -Spec ([string]$spec) -BaseUrl ([string]$webServer.baseUrl)
          if (-not $check) { continue }
          $actual = Get-ProjectAcceptanceStatusCode -Url ([string]$check.url) -Method ([string]$check.method)
          $ok = @($check.expected) -contains $actual
          [void]$steps.Add((New-ProjectAcceptanceStep -Name ("web:" + [string]$check.spec) -Ok ([bool]$ok) -ExitCode $actual -Details ("actual=$actual url=$($check.url)")))
          Write-ProjectAcceptanceTrace -Channel $ch -Text ("web done " + [string]$spec + " actual=" + [string]$actual)
        }
        foreach ($spec in @($contractWebSpecs)) {
          $url = Join-ProjectAcceptanceUrl -BaseUrl ([string]$webServer.baseUrl) -Path ([string]$spec.path)
          Write-ProjectAcceptanceTrace -Channel $ch -Text ("contract web start " + [string]$spec.name + " " + [string]$spec.path)
          $http = Invoke-ProjectAcceptanceHttpText -Url $url
          $expectedStatuses = @($spec.expected)
          if ($expectedStatuses.Count -eq 0) { $expectedStatuses = @(200) }
          $statusOk = @($expectedStatuses) -contains [int]$http.status
          $missing = New-Object 'System.Collections.Generic.List[string]'
          $canAssertBody = ([int]$http.status -eq 200)
          if ($canAssertBody) {
            foreach ($token in @($spec.must_contain)) {
              if (-not [string]::IsNullOrWhiteSpace([string]$token) -and ([string]$http.text).IndexOf([string]$token, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                [void]$missing.Add([string]$token)
              }
            }
          }
          $ok = ($statusOk -and $missing.Count -eq 0)
          $details = "status=$($http.status) expected=" + ((@($expectedStatuses) | ForEach-Object { [string]$_ }) -join ',') + " url=$url"
          if ($missing.Count -gt 0) { $details += " missing=" + (($missing.ToArray()) -join ' | ') }
          if (-not [string]::IsNullOrWhiteSpace([string]$http.error)) { $details += " error=" + [string]$http.error }
          [void]$steps.Add((New-ProjectAcceptanceStep -Name ("contract-web:" + [string]$spec.name) -Ok ([bool]$ok) -ExitCode ([int]$http.status) -Details $details))
          Write-ProjectAcceptanceTrace -Channel $ch -Text ("contract web done " + [string]$spec.name + " ok=" + [string]$ok + " actual=" + [string]$http.status)
        }
        foreach ($spec in @($contractJourneySpecs)) {
          $url = Join-ProjectAcceptanceUrl -BaseUrl ([string]$webServer.baseUrl) -Path ([string]$spec.path)
          $stepName = "contract-journey:" + [string]$spec.journey_id + ":" + [string]$spec.step_index
          Write-ProjectAcceptanceTrace -Channel $ch -Text ("contract journey start " + [string]$spec.journey_id + " step=" + [string]$spec.step_index + " " + [string]$spec.path)
          $http = Invoke-ProjectAcceptanceHttpText -Url $url
          $expectedStatuses = @($spec.expected)
          if ($expectedStatuses.Count -eq 0) { $expectedStatuses = @(200) }
          $statusOk = @($expectedStatuses) -contains [int]$http.status
          $missing = New-Object 'System.Collections.Generic.List[string]'
          $canAssertBody = ([int]$http.status -eq 200)
          if ($canAssertBody) {
            foreach ($token in @($spec.must_contain)) {
              if (-not [string]::IsNullOrWhiteSpace([string]$token) -and ([string]$http.text).IndexOf([string]$token, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
                [void]$missing.Add([string]$token)
              }
            }
          }
          $ok = ($statusOk -and $missing.Count -eq 0)
          $details = "status=$($http.status) expected=" + ((@($expectedStatuses) | ForEach-Object { [string]$_ }) -join ',') + " url=$url source=journey name=" + [string]$spec.name
          if ($missing.Count -gt 0) { $details += " missing=" + (($missing.ToArray()) -join ' | ') }
          if (-not [string]::IsNullOrWhiteSpace([string]$http.error)) { $details += " error=" + [string]$http.error }
          [void]$steps.Add((New-ProjectAcceptanceStep -Name $stepName -Ok ([bool]$ok) -ExitCode ([int]$http.status) -Details $details))
          Write-ProjectAcceptanceTrace -Channel $ch -Text ("contract journey done " + [string]$spec.journey_id + " step=" + [string]$spec.step_index + " ok=" + [string]$ok + " actual=" + [string]$http.status)
        }
      }
    } finally {
      Write-ProjectAcceptanceTrace -Channel $ch -Text "web server stop"
      Stop-ProjectAcceptanceServer -Server $webServer
      Write-ProjectAcceptanceTrace -Channel $ch -Text "web server stopped"
    }
  }

  if (@($cfg.smokeScripts).Count -gt 0) {
    $smokeServer = $null
    try {
      Write-ProjectAcceptanceTrace -Channel $ch -Text "smoke server start"
      $smokeServer = Start-ProjectAcceptanceServer -ProjectRoot $ProjectRoot -Config $cfg
      [void]$steps.Add((New-ProjectAcceptanceStep -Name 'server:smoke-start' -Ok ([bool]$smokeServer.ok) -Details ($(if ($smokeServer.ok) { "ready $($smokeServer.baseUrl) status=$($smokeServer.readyStatus)" } else { [string]$smokeServer.reason }))))
      Write-ProjectAcceptanceTrace -Channel $ch -Text ("smoke server done ok=" + [string]$smokeServer.ok + " base=" + [string]$smokeServer.baseUrl)
      if ($smokeServer.ok) {
        foreach ($scriptName in @($cfg.smokeScripts)) {
          Write-ProjectAcceptanceTrace -Channel $ch -Text "smoke start $scriptName"
          $pkg = Get-ProjectAcceptancePackage -ProjectRoot $ProjectRoot
          if (-not (Test-ProjectAcceptancePackageScript -PackageJson $pkg -Name $scriptName)) {
            [void]$steps.Add((New-ProjectAcceptanceStep -Name "smoke:$scriptName" -Ok $true -Details 'missing script, skipped'))
            Write-ProjectAcceptanceTrace -Channel $ch -Text "smoke skip $scriptName"
            continue
          }
          $envVars = @{ BASE_URL = [string]$smokeServer.baseUrl; SMOKE_ALLOW_MUTATION = '1' }
          $res = Invoke-ProjectAcceptanceProcess -ProjectRoot $ProjectRoot -CommandLine "npm.cmd run $scriptName" -Env $envVars -TimeoutSec 300
          [void]$steps.Add((New-ProjectAcceptanceStep -Name "smoke:$scriptName" -Ok ([bool]$res.ok) -ExitCode ([int]$res.exit_code) -Details ([string]$res.output_tail)))
          Write-ProjectAcceptanceTrace -Channel $ch -Text ("smoke done " + $scriptName + " ok=" + [string]$res.ok + " exit=" + [string]$res.exit_code)
        }
      }
    } finally {
      Write-ProjectAcceptanceTrace -Channel $ch -Text "smoke server stop"
      Stop-ProjectAcceptanceServer -Server $smokeServer
      Write-ProjectAcceptanceTrace -Channel $ch -Text "smoke server stopped"
    }
  }

  $allOk = $true
  foreach ($s in @($steps.ToArray())) { if (-not [bool]$s.ok) { $allOk = $false; break } }
  $status = if ($allOk) { 'PASS' } else { 'FAIL' }
  $now = (Get-Date).ToUniversalTime()
  $stamp = $now.ToString('yyyyMMdd-HHmmss')
  $dir = Join-Path (Get-ProjectAcceptanceChannelDir -Channel $ch) 'acceptance'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $jsonPath = Join-Path $dir "$stamp-$status.json"
  $mdPath = Join-Path $dir "$stamp-$status.md"

  $report = [ordered]@{
    ts = $now.ToString('o')
    channel = $ch
    project_root = $ProjectRoot
    head = $head
    trigger = [string]$Trigger
    status = $status
    plan_signature = $planSignature
    plan_contract_path = $planContractPath
    steps = @($steps.ToArray())
  }
  Write-ProjectAcceptanceTrace -Channel $ch -Text "write json"
  Write-ProjectAcceptanceText -Path $jsonPath -Text (($report | ConvertTo-Json -Depth 10) + "`n")

  $md = New-Object System.Text.StringBuilder
  [void]$md.AppendLine("# Project Acceptance")
  [void]$md.AppendLine("")
  [void]$md.AppendLine("- channel: $ch")
  [void]$md.AppendLine("- project_root: $ProjectRoot")
  [void]$md.AppendLine("- head: $head")
  [void]$md.AppendLine("- trigger: $Trigger")
  [void]$md.AppendLine("- status: $status")
  [void]$md.AppendLine("- plan_signature: $planSignature")
  [void]$md.AppendLine("- plan_contract: $planContractPath")
  [void]$md.AppendLine("")
  [void]$md.AppendLine("## Steps")
  foreach ($s in @($steps.ToArray())) {
    $mark = if ([bool]$s.ok) { "PASS" } else { "FAIL" }
    [void]$md.AppendLine("- $mark $($s.name) exit=$($s.exit_code)")
    $details = ([string]$s.details).Trim()
    if (-not [string]::IsNullOrWhiteSpace($details)) {
      if ($details.Length -gt 1200) { $details = $details.Substring($details.Length - 1200) }
      [void]$md.AppendLine("")
      [void]$md.AppendLine('```text')
      [void]$md.AppendLine($details)
      [void]$md.AppendLine('```')
      [void]$md.AppendLine("")
    }
  }
  Write-ProjectAcceptanceTrace -Channel $ch -Text "write md"
  Write-ProjectAcceptanceText -Path $mdPath -Text ($md.ToString())

  $fixTaskId = ''
  if (-not $allOk -and $CreateFixTask) {
    try {
      if (Get-Command Add-Idea -ErrorAction SilentlyContinue) {
        $taskText = "[project-acceptance-fix] Acceptance failed for channel '$ch'. Read report: ${mdPath}. Fix every FAIL step, run the same checks, commit the project changes, and finish only when acceptance can pass."
        $fixTaskId = [string](Add-Idea -Text $taskText -From 'project-acceptance' -Tags @('project-acceptance','auto-generated') -Status 'approved' -Severity 'critical' -Project $ch -Scope 'project' -SkipCurator)
      }
    } catch { $fixTaskId = '' }
  }

  $state = [ordered]@{
    ts = $now.ToString('o')
    channel = $ch
    project_root = $ProjectRoot
    head = $head
    status = $status
    trigger = [string]$Trigger
    report_json = $jsonPath
    report_md = $mdPath
    fix_task_id = $fixTaskId
  }
  Write-ProjectAcceptanceTrace -Channel $ch -Text "write state"
  Write-ProjectAcceptanceState -Channel $ch -State ([pscustomobject]$state)

  $memoryKind = if ($allOk) { 'project_test' } else { 'project_risk' }
  $memoryText = "Project acceptance $status at head $head. Report: $mdPath"
  Write-ProjectAcceptanceTrace -Channel $ch -Text 'memory sidecar start'
  [void](Add-ProjectAcceptanceMemoryBestEffort -Channel $ch -Text $memoryText -Kind $memoryKind -Report $mdPath -Head $head -Status $status)
  Write-ProjectAcceptanceTrace -Channel $ch -Text 'memory sidecar done'

  $extra = if (-not [string]::IsNullOrWhiteSpace($fixTaskId)) { " Fix task queued: $fixTaskId." } else { '' }
  $messageText = "Project Acceptance: " + $status + " for channel '" + $ch + "'. Report: " + $mdPath + "." + $extra
  Write-ProjectAcceptanceTrace -Channel $ch -Text 'message sidecar start'
  [void](Add-ProjectAcceptanceMessageBestEffort -Text $messageText)
  Write-ProjectAcceptanceTrace -Channel $ch -Text 'message sidecar done'

  Write-ProjectAcceptanceTrace -Channel $ch -Text "done status=$status"
  return [pscustomobject]@{
    ran = $true
    status = $status
    ok = $allOk
    channel = $ch
    project_root = $ProjectRoot
    head = $head
    report_json = $jsonPath
    report_md = $mdPath
    fix_task_id = $fixTaskId
    steps = @($steps.ToArray())
  }
}

function Start-ProjectAcceptanceIfDue {
  param([string]$Channel = '', [string]$Trigger = 'idle-empty-backlog', [switch]$Force)
  $ch = Get-ProjectAcceptanceChannel -Channel $Channel
  $binding = Get-ProjectAcceptanceBinding -Channel $ch
  if (-not $binding) { return [pscustomobject]@{ ran=$false; reason='not-project-channel'; channel=$ch } }
  $root = [string]$binding.project_root
  if (-not (Test-Path -LiteralPath $root -PathType Container)) { return [pscustomobject]@{ ran=$false; reason='project-root-missing'; channel=$ch; project_root=$root } }

  try {
    if (-not $Force -and (Get-Command Get-ProjectAutopilotBacklogPressure -ErrorAction SilentlyContinue)) {
      $pressure = Get-ProjectAutopilotBacklogPressure
      if ([int]$pressure.runnable -gt 0) { return [pscustomobject]@{ ran=$false; reason='backlog-not-empty'; channel=$ch; pressure=$pressure } }
    }
  } catch {}

  $autoPaused = $false
  try {
    if (Get-Command Read-ProjectAutopilotState -ErrorAction SilentlyContinue) {
      $pa = Read-ProjectAutopilotState
      if ($pa) { $autoPaused = [bool](Get-ProjectAcceptanceObjectValue -Obj $pa -Names @('paused') -Default $false) }
    }
  } catch {}
  if (-not $Force -and -not $autoPaused) { return [pscustomobject]@{ ran=$false; reason='autopilot-not-finished'; channel=$ch } }

  if (-not (Test-ProjectAcceptanceGitClean -ProjectRoot $root)) { return [pscustomobject]@{ ran=$false; reason='project-dirty'; channel=$ch; project_root=$root } }
  $head = Get-ProjectAcceptanceGitHead -ProjectRoot $root
  $last = Read-ProjectAcceptanceState -Channel $ch
  if (-not $Force -and $last -and [string](Get-ProjectAcceptanceObjectValue -Obj $last -Names @('head') -Default '') -eq $head) {
    $st = [string](Get-ProjectAcceptanceObjectValue -Obj $last -Names @('status') -Default '')
    if ($st -in @('PASS','FAIL')) { return [pscustomobject]@{ ran=$false; reason='already-checked-head'; channel=$ch; status=$st; report_md=[string]$last.report_md } }
  }

  try {
    if (Get-Command Add-Message -ErrorAction SilentlyContinue) {
      Add-Message -From system -Text ("Project Acceptance: starting final acceptance for channel '$ch' at head $head.") -Kind event | Out-Null
    }
  } catch {}
  return (Invoke-ProjectAcceptance -Channel $ch -ProjectRoot $root -Trigger $Trigger -CreateFixTask)
}
