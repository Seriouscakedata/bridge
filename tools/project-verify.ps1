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
function Step($label, $scriptName) {
  if (-not (Has $scriptName)) { Write-Host ("  - " + $label + ": (no '" + $scriptName + "' script, skip)") -ForegroundColor DarkGray; return }
  Write-Host ("  > " + $label + " ...") -ForegroundColor Cyan
  $out = & npm run $scriptName 2>&1 | Out-String
  if ($LASTEXITCODE -eq 0) { Write-Host ("    PASS " + $label) -ForegroundColor Green }
  else { Write-Host ("    FAIL " + $label) -ForegroundColor Red; ($out -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 10 | ForEach-Object { Write-Host ("      " + $_) }); $script:fail++ }
}

if (-not (Test-Path (Join-Path $proj 'node_modules'))) {
  Write-Host '  > npm install (first run) ...' -ForegroundColor Cyan
  & npm install --no-audit --no-fund 2>&1 | Out-Null
}

Step 'typecheck' 'typecheck'
Step 'build' 'build'
if ($E2E -and (Has 'test:e2e')) {
  if ($BaseUrl) { $env:BASE_URL = $BaseUrl }
  Step 'e2e' 'test:e2e'
} elseif ($E2E) { Write-Host '  - e2e: (no test:e2e script)' -ForegroundColor DarkGray }

Write-Host ("=== RESULT: " + $(if ($fail -eq 0) { 'ALL PASS' } else { ([string]$fail + ' STEP(S) FAILED') }) + " ===") -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
exit $(if ($fail -gt 0) { 1 } else { 0 })
