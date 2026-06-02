#Requires -Version 5.1
param(
  [string]$ProjectRoot = '',
  [string]$StartCommand = '',
  [string]$BaseUrl = '',
  [string]$BindHost = '127.0.0.1',
  [int]$Port = 0,
  [string]$ReadyPath = '/',
  [string[]]$ReadyStatus = @('200','204','301','302','307','308','401','403','404'),
  [string[]]$Check = @(),
  [int]$TimeoutSec = 180,
  [string]$LogPath = '',
  [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Write-WebSmokeLine {
  param([string]$Text)
  $line = '[web-smoke] ' + $Text
  Write-Host $line
}

function Get-FreeTcpPort {
  $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse('127.0.0.1'), 0)
  try {
    $listener.Start()
    return [int]$listener.LocalEndpoint.Port
  } finally {
    try { $listener.Stop() } catch {}
  }
}

function Resolve-ProjectRoot {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { $Path = (Get-Location).Path }
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "ProjectRoot not found: $Path" }
  return [System.IO.Path]::GetFullPath($Path)
}

function Add-NodePathIfNeeded {
  if (Get-Command node -ErrorAction SilentlyContinue) { return }
  $candidates = @()
  try { $candidates += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\OpenJS.NodeJS*\node-*-win-x64\node.exe') -ErrorAction SilentlyContinue | ForEach-Object { $_.DirectoryName }) } catch {}
  $candidates += @((Join-Path $env:ProgramFiles 'nodejs'), (Join-Path $env:LOCALAPPDATA 'Programs\nodejs'))
  foreach ($dir in $candidates) {
    if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'node.exe'))) {
      $env:Path = [string]$dir + ';' + $env:Path
      return
    }
  }
}

function Import-DotEnv {
  param([string]$Root)
  $envFile = Join-Path $Root '.env'
  if (-not (Test-Path -LiteralPath $envFile)) { return }
  foreach ($line in (Get-Content -LiteralPath $envFile -Encoding UTF8)) {
    if ($line -match '^\s*#') { continue }
    if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$') {
      $name = $matches[1]
      $value = $matches[2].Trim()
      if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
        if ($value.Length -ge 2) { $value = $value.Substring(1, $value.Length - 2) }
      }
      [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
  }
}

function Get-PackageManagerCommand {
  param([string]$Root, $PackageJson)
  $pm = ''
  try { if ($PackageJson.packageManager) { $pm = [string]$PackageJson.packageManager } } catch {}
  if ($pm -match '^\s*pnpm@') { return 'pnpm' }
  if ($pm -match '^\s*yarn@') { return 'yarn' }
  if ($pm -match '^\s*bun@') { return 'bun' }
  if (Test-Path -LiteralPath (Join-Path $Root 'pnpm-lock.yaml')) { return 'pnpm' }
  if (Test-Path -LiteralPath (Join-Path $Root 'yarn.lock')) { return 'yarn' }
  if ((Test-Path -LiteralPath (Join-Path $Root 'bun.lockb')) -or (Test-Path -LiteralPath (Join-Path $Root 'bun.lock'))) { return 'bun' }
  return 'npm'
}

function Test-PackageScript {
  param($Scripts, [string]$Name)
  return ($Scripts -and ($Scripts.PSObject.Properties.Name -contains $Name))
}

function Get-PackageScriptValue {
  param($Scripts, [string]$Name)
  if (-not (Test-PackageScript -Scripts $Scripts -Name $Name)) { return '' }
  return [string]$Scripts.PSObject.Properties[$Name].Value
}

function New-RunCommand {
  param([string]$Manager, [string]$Script, [bool]$AppendHostPort, [string]$BindHost, [int]$Port)
  $args = ''
  if ($AppendHostPort) { $args = " -- --hostname $BindHost --port $Port" }
  if ($Manager -eq 'yarn') {
    if ($AppendHostPort) { return "yarn run $Script --hostname $BindHost --port $Port" }
    return "yarn run $Script"
  }
  if ($Manager -eq 'pnpm') { return "pnpm run $Script$args" }
  if ($Manager -eq 'bun') { return "bun run $Script$args" }
  return "npm run $Script$args"
}

function Get-InferredStartCommand {
  param([string]$Root, [string]$BindHost, [int]$Port)
  $pkgPath = Join-Path $Root 'package.json'
  if (-not (Test-Path -LiteralPath $pkgPath)) {
    throw 'StartCommand is required for non-Node projects without package.json'
  }
  $pkg = Get-Content -LiteralPath $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $scripts = $pkg.scripts
  $manager = Get-PackageManagerCommand -Root $Root -PackageJson $pkg
  $allScriptText = ''
  try { $allScriptText = (($scripts.PSObject.Properties | ForEach-Object { [string]$_.Value }) -join "`n") } catch {}
  $hasNext = $false
  try { if ($pkg.dependencies.PSObject.Properties.Name -contains 'next') { $hasNext = $true } } catch {}
  try { if ($pkg.devDependencies.PSObject.Properties.Name -contains 'next') { $hasNext = $true } } catch {}
  if ($allScriptText -match '(?i)\bnext\b') { $hasNext = $true }

  if ($hasNext) {
    if ((Test-Path -LiteralPath (Join-Path $Root '.next')) -and (Test-PackageScript -Scripts $scripts -Name 'start')) {
      return Get-PackageRunCommand -Manager $manager -Script 'start' -AppendHostPort $true -BindHost $BindHost -Port $Port
    }
    if (Test-PackageScript -Scripts $scripts -Name 'dev') {
      return Get-PackageRunCommand -Manager $manager -Script 'dev' -AppendHostPort $true -BindHost $BindHost -Port $Port
    }
    if (Test-PackageScript -Scripts $scripts -Name 'start') {
      return Get-PackageRunCommand -Manager $manager -Script 'start' -AppendHostPort $true -BindHost $BindHost -Port $Port
    }
  }

  foreach ($name in @('start','dev','serve','preview')) {
    if (Test-PackageScript -Scripts $scripts -Name $name) {
      return Get-PackageRunCommand -Manager $manager -Script $name -AppendHostPort $false -BindHost $BindHost -Port $Port
    }
  }
  throw 'No runnable package script found. Provide -StartCommand.'
}

function Get-PackageRunCommand {
  param([string]$Manager, [string]$Script, [bool]$AppendHostPort, [string]$BindHost, [int]$Port)
  return New-RunCommand -Manager $Manager -Script $Script -AppendHostPort $AppendHostPort -BindHost $BindHost -Port $Port
}

function Get-StatusCode {
  param([string]$Url, [string]$Method = 'GET')
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -Method $Method -TimeoutSec 5 -ErrorAction Stop
    return [int]$response.StatusCode
  } catch {
    try {
      if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
    } catch {}
    return 0
  }
}

function ConvertTo-StatusSet {
  param([string[]]$Values)
  $set = New-Object 'System.Collections.Generic.HashSet[int]'
  foreach ($v in @($Values)) {
    foreach ($part in ([string]$v -split ',')) {
      $n = 0
      if ([int]::TryParse($part.Trim(), [ref]$n)) { [void]$set.Add($n) }
    }
  }
  return $set
}

function Join-UrlPath {
  param([string]$Base, [string]$Path)
  if ($Path -match '^(?i)https?://') { return $Path }
  if ([string]::IsNullOrWhiteSpace($Path)) { $Path = '/' }
  if (-not $Path.StartsWith('/')) { $Path = '/' + $Path }
  return $Base.TrimEnd('/') + $Path
}

function Parse-CheckSpec {
  param([string]$Spec, [string]$Base)
  $s = ([string]$Spec).Trim()
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  $parts = $s -split '=', 2
  $left = $parts[0].Trim()
  $expected = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '200' }
  $method = 'GET'
  if ($left -match '^(GET|POST|PUT|PATCH|DELETE|HEAD)\s+(.+)$') {
    $method = $matches[1].ToUpperInvariant()
    $left = $matches[2].Trim()
  }
  $statuses = New-Object 'System.Collections.Generic.List[int]'
  foreach ($piece in ($expected -split ',')) {
    $n = 0
    if ([int]::TryParse($piece.Trim(), [ref]$n)) { [void]$statuses.Add($n) }
  }
  if ($statuses.Count -eq 0) { throw "Invalid expected statuses in check: $Spec" }
  return [pscustomobject]@{ method = $method; url = (Join-UrlPath -Base $Base -Path $left); expected = @($statuses.ToArray()); spec = $Spec }
}

function Get-TextTail {
  param([string]$Path, [int]$MaxChars = 3000)
  if (-not (Test-Path -LiteralPath $Path)) { return '' }
  $text = ''
  try { $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) } catch { return '' }
  if ($text.Length -gt $MaxChars) { return $text.Substring($text.Length - $MaxChars) }
  return $text
}

$result = [ordered]@{
  ok = $false
  projectRoot = ''
  baseUrl = ''
  command = ''
  ready = $false
  checks = @()
  logPath = ''
  reason = ''
}

$proc = $null
$outEvent = $null
$errEvent = $null

function Invoke-WebSmokeMain {
try {
  $ProjectRoot = Resolve-ProjectRoot -Path $ProjectRoot
  $result.projectRoot = $ProjectRoot
  if ($Port -le 0) { $Port = Get-FreeTcpPort }
  if ([string]::IsNullOrWhiteSpace($BaseUrl)) { $BaseUrl = "http://${BindHost}:$Port" }
  $result.baseUrl = $BaseUrl
  if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $logDir = Join-Path $ProjectRoot '.bridge-smoke'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $LogPath = Join-Path $logDir ('web-smoke-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $Port + '.log')
  }
  $result.logPath = $LogPath
  $logParent = Split-Path -Parent $LogPath
  if ($logParent -and -not (Test-Path -LiteralPath $logParent)) { New-Item -ItemType Directory -Path $logParent -Force | Out-Null }
  [System.IO.File]::WriteAllText($LogPath, '', (New-Object System.Text.UTF8Encoding($false)))

  Add-NodePathIfNeeded
  Import-DotEnv -Root $ProjectRoot
  if ([string]::IsNullOrWhiteSpace($StartCommand)) {
    $StartCommand = Get-InferredStartCommand -Root $ProjectRoot -BindHost $BindHost -Port $Port
  }
  $result.command = $StartCommand

  $env:PORT = [string]$Port
  $env:HOST = $BindHost
  $env:HOSTNAME = $BindHost
  $env:BROWSER = 'none'
  $env:NEXT_TELEMETRY_DISABLED = '1'

  Write-WebSmokeLine "project=$ProjectRoot"
  Write-WebSmokeLine "base=$BaseUrl ready=$ReadyPath timeout=${TimeoutSec}s"
  Write-WebSmokeLine "command=$StartCommand"
  Write-WebSmokeLine "log=$LogPath"

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
  $cmdFile = [System.IO.Path]::ChangeExtension($LogPath, '.cmd')
  [System.IO.File]::WriteAllText($cmdFile, "@echo off`r`n" + $StartCommand + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
  $psi.Arguments = '/d /s /c call "' + $cmdFile + '"'
  $psi.WorkingDirectory = $ProjectRoot
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.EnvironmentVariables['PORT'] = [string]$Port
  $psi.EnvironmentVariables['HOST'] = $BindHost
  $psi.EnvironmentVariables['HOSTNAME'] = $BindHost
  $psi.EnvironmentVariables['BROWSER'] = 'none'
  $psi.EnvironmentVariables['NEXT_TELEMETRY_DISABLED'] = '1'

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  $append = {
    param($sender, $eventArgs)
    if ($eventArgs.Data) {
      try {
        [System.IO.File]::AppendAllText($LogPath, ($eventArgs.Data + [Environment]::NewLine), [System.Text.Encoding]::UTF8)
      } catch {}
    }
  }
  $proc.add_OutputDataReceived($append)
  $proc.add_ErrorDataReceived($append)
  if (-not $proc.Start()) { throw 'Process.Start returned false' }
  $proc.BeginOutputReadLine()
  $proc.BeginErrorReadLine()

  $readyStatuses = ConvertTo-StatusSet -Values $ReadyStatus
  $readyUrl = Join-UrlPath -Base $BaseUrl -Path $ReadyPath
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $lastProgress = -1
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    if ($proc.HasExited) {
      Start-Sleep -Milliseconds 200
      $tail = Get-TextTail -Path $LogPath -MaxChars 3000
      $result.reason = "server process exited before ready, code=$($proc.ExitCode)"
      Write-WebSmokeLine $result.reason
      if ($tail) { Write-WebSmokeLine "server log tail:`n$tail" }
      return 1
    }
    $code = Get-StatusCode -Url $readyUrl
    if ($readyStatuses.Contains($code)) {
      $result.ready = $true
      Write-WebSmokeLine "ready: $readyUrl -> $code"
      break
    }
    $elapsed = [int]$sw.Elapsed.TotalSeconds
    if (($elapsed % 10) -eq 0 -and $elapsed -ne $lastProgress) {
      $lastProgress = $elapsed
      Write-WebSmokeLine "waiting ready (${elapsed}s): $readyUrl lastStatus=$code"
    }
    Start-Sleep -Seconds 1
  }

  if (-not [bool]$result.ready) {
    $tail = Get-TextTail -Path $LogPath -MaxChars 3000
    $result.reason = "server not ready after ${TimeoutSec}s"
    Write-WebSmokeLine $result.reason
    if ($tail) { Write-WebSmokeLine "server log tail:`n$tail" }
    return 1
  }

  $failures = New-Object 'System.Collections.Generic.List[string]'
  $checkResults = New-Object 'System.Collections.Generic.List[object]'
  foreach ($rawSpec in @($Check)) {
    foreach ($spec in (([string]$rawSpec) -split '\s*;\s*')) {
      $checkObj = Parse-CheckSpec -Spec $spec -Base $BaseUrl
      if (-not $checkObj) { continue }
      $actual = Get-StatusCode -Url ([string]$checkObj.url) -Method ([string]$checkObj.method)
      $pass = @($checkObj.expected) -contains $actual
      $checkRec = [pscustomobject]@{
        spec = [string]$checkObj.spec
        method = [string]$checkObj.method
        url = [string]$checkObj.url
        expected = @($checkObj.expected)
        actual = $actual
        ok = $pass
      }
      [void]$checkResults.Add($checkRec)
      Write-WebSmokeLine ("check " + $checkObj.method + " " + $checkObj.url + " -> " + $actual + " expected=" + ((@($checkObj.expected) | ForEach-Object { [string]$_ }) -join ',') + " " + $(if ($pass) { 'PASS' } else { 'FAIL' }))
      if (-not $pass) { [void]$failures.Add([string]$checkObj.spec + " got " + $actual) }
    }
  }
  $result.checks = @($checkResults.ToArray())
  if ($failures.Count -gt 0) {
    $result.reason = 'checks failed: ' + (($failures.ToArray()) -join '; ')
    Write-WebSmokeLine $result.reason
    return 1
  }
  $result.ok = $true
  $result.reason = 'ok'
  Write-WebSmokeLine 'PASS'
  return 0
} catch {
  $result.reason = $_.Exception.Message
  Write-WebSmokeLine ("FAIL: " + $_.Exception.Message)
  return 1
} finally {
  try {
    if ($Json) {
      Write-Host ($result | ConvertTo-Json -Depth 8)
    }
  } catch {}
  try {
    if ($proc -and -not $proc.HasExited) {
      Write-WebSmokeLine ("stopping server pid=" + $proc.Id)
      try { & taskkill.exe /PID ([string]$proc.Id) /T /F 2>$null | Out-Null } catch {}
      try { if (-not $proc.WaitForExit(5000)) { $proc.Kill() } } catch {}
    }
  } catch {}
  try { if ($proc) { $proc.Dispose() } } catch {}
}
}

$webSmokeReturn = @(Invoke-WebSmokeMain)
$webSmokeCode = 1
if ($webSmokeReturn.Count -gt 0) {
  $parsedCode = 1
  if ([int]::TryParse([string]$webSmokeReturn[-1], [ref]$parsedCode)) { $webSmokeCode = $parsedCode }
}
[Environment]::Exit($webSmokeCode)
