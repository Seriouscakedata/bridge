#Requires -Version 5.1
# project-verify.ps1 -- verification gate for a PROJECT channel: actually BUILD & TEST the code.
# Foundation #4 lesson: the driver's critic is an LLM diff-review; it does NOT run the project, so
# "done" did not guarantee "compiles". This tool RUNS the toolchain (install -> typecheck -> build
# -> optional e2e) so the operator (or a future driver hook) gets a hard pass/fail. Safe, standalone:
# touches NO bridge control-plane code.
#   Usage: powershell -NoProfile -File tools\project-verify.ps1 -Channel aipartners [-E2E] [-BaseUrl http://localhost:3100]
param([string]$Channel = 'aipartners', [switch]$E2E, [string]$BaseUrl = '')
$ErrorActionPreference = 'Continue'
$root = if ($env:BRIDGE_ROOT) { $env:BRIDGE_ROOT } else { 'C:\Users\rafie\OneDrive\Documents\bridge' }

# --- resolve project_root from channel.json ---
$chJson = Join-Path $root "channels\$Channel\channel.json"
if (-not (Test-Path $chJson)) { Write-Host "channel not found: $Channel" -ForegroundColor Red; exit 2 }
$proj = ''
try { $proj = [string]((Get-Content $chJson -Raw -Encoding UTF8 | ConvertFrom-Json).project_root) } catch {}
if (-not $proj -or -not (Test-Path $proj)) { Write-Host "project_root missing/invalid: '$proj'" -ForegroundColor Red; exit 2 }

# --- ensure node on PATH (same locator as driver's injection) ---
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  $nd = @()
  try { $nd += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\OpenJS.NodeJS*\node-*-win-x64\node.exe') -ErrorAction SilentlyContinue | ForEach-Object { $_.DirectoryName }) } catch {}
  $nd += @((Join-Path $env:ProgramFiles 'nodejs'), (Join-Path $env:LOCALAPPDATA 'Programs\nodejs'))
  foreach ($d in $nd) { if ($d -and (Test-Path (Join-Path $d 'node.exe'))) { $env:Path = [string]$d + ';' + $env:Path; break } }
}
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Write-Host 'node not found on PATH' -ForegroundColor Red; exit 2 }
$npmCmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
$script:NpmExe = if ($npmCmd -and $npmCmd.Source) { [string]$npmCmd.Source } else { 'npm.cmd' }

Set-Location $proj
Write-Host ("=== PROJECT VERIFY: " + $Channel + "  (" + $proj + ") ===") -ForegroundColor Yellow
Write-Host ("node " + (& node --version))

if (-not (Test-Path (Join-Path $proj 'package.json'))) { Write-Host 'no package.json -- non-node project, nothing to build'; exit 0 }
$pkg = $null; try { $pkg = Get-Content (Join-Path $proj 'package.json') -Raw | ConvertFrom-Json } catch {}
$scripts = if ($pkg) { $pkg.scripts } else { $null }
$fail = 0

# load .env into process env (prisma/tsx need it)
$envFile = Join-Path $proj '.env'
if (Test-Path $envFile) {
  foreach ($ln in (Get-Content $envFile -Encoding UTF8)) {
    if ($ln -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"?([^"]*)"?\s*$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], 'Process') }
  }
}

function Has($name) { return ($scripts -and ($scripts.PSObject.Properties.Name -contains $name)) }

function ConvertTo-ProjectVerifyProcessArgument {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }
  $escaped = ([string]$Value) -replace '(\\*)"', '$1$1\"'
  $escaped = $escaped -replace '(\\+)$', '$1$1'
  return '"' + $escaped + '"'
}

function Invoke-ProjectVerifyProcess {
  param(
    [Parameter(Mandatory=$true)][string]$FilePath,
    [string[]]$Arguments = @(),
    [string]$WorkingDirectory = $proj,
    [int]$TimeoutSec = 900
  )
  # CB review 2026-06-01: keep native stderr out of the PowerShell pipeline.
  # Under Windows PowerShell 5.1, merged native stderr/stdout can become NativeCommandError.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = (@($Arguments) | ForEach-Object { ConvertTo-ProjectVerifyProcessArgument ([string]$_) }) -join ' '
  $psi.WorkingDirectory = $WorkingDirectory
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  try {
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  } catch {}
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEndAsync()
  $stderr = $proc.StandardError.ReadToEndAsync()
  $timedOut = $false
  if (-not $proc.WaitForExit([Math]::Max(1, $TimeoutSec) * 1000)) {
    $timedOut = $true
    try { $proc.Kill() } catch {}
    try { $proc.WaitForExit(3000) | Out-Null } catch {}
  }
  try { $stdout.Wait(3000) | Out-Null } catch {}
  try { $stderr.Wait(3000) | Out-Null } catch {}
  return [pscustomobject]@{
    ExitCode = if ($timedOut) { 124 } else { [int]$proc.ExitCode }
    TimedOut = [bool]$timedOut
    Output = @(
      if ($stdout.IsCompleted -and -not [string]::IsNullOrEmpty($stdout.Result)) { $stdout.Result }
      if ($stderr.IsCompleted -and -not [string]::IsNullOrEmpty($stderr.Result)) { $stderr.Result }
      if ($timedOut) { "TIMEOUT after $TimeoutSec seconds" }
    )
  }
}

function Step($label, $scriptName) {
  if (-not (Has $scriptName)) { Write-Host ("  - " + $label + ": (no '" + $scriptName + "' script, skip)") -ForegroundColor DarkGray; return }
  Write-Host ("  > " + $label + " ...") -ForegroundColor Cyan
  $result = Invoke-ProjectVerifyProcess -FilePath $script:NpmExe -Arguments @('run', $scriptName) -WorkingDirectory $proj -TimeoutSec 900
  if ($result.ExitCode -eq 0 -and -not $result.TimedOut) { Write-Host ("    PASS " + $label) -ForegroundColor Green }
  else {
    Write-Host ("    FAIL " + $label) -ForegroundColor Red
    $outText = @($result.Output) -join "`n"
    ($outText -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 10 | ForEach-Object { Write-Host ("      " + $_) })
    $script:fail++
  }
}

if (-not (Test-Path (Join-Path $proj 'node_modules'))) {
  Write-Host '  > npm install (first run) ...' -ForegroundColor Cyan
  $install = Invoke-ProjectVerifyProcess -FilePath $script:NpmExe -Arguments @('install', '--no-audit', '--no-fund') -WorkingDirectory $proj -TimeoutSec 900
  if ($install.ExitCode -ne 0 -or $install.TimedOut) {
    Write-Host '    FAIL npm install' -ForegroundColor Red
    $installText = @($install.Output) -join "`n"
    ($installText -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 10 | ForEach-Object { Write-Host ("      " + $_) })
    exit 1
  }
}

Step 'typecheck' 'typecheck'
Step 'build' 'build'
if ($E2E -and (Has 'test:e2e')) {
  if ($BaseUrl) { $env:BASE_URL = $BaseUrl }
  Step 'e2e' 'test:e2e'
} elseif ($E2E) { Write-Host '  - e2e: (no test:e2e script)' -ForegroundColor DarkGray }

Write-Host ("=== RESULT: " + $(if ($fail -eq 0) { 'ALL PASS' } else { ([string]$fail + ' STEP(S) FAILED') }) + " ===") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
exit $(if ($fail -gt 0) { 1 } else { 0 })
