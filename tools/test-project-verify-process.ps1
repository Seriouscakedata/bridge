# test-project-verify-process.ps1 -- regression test for project-verify native process handling.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$sandbox = Join-Path $root ('tmp\project-verify-test-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$bridgeRoot = Join-Path $sandbox 'bridge-root'
$projectRoot = Join-Path $sandbox 'project'

try {
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    $nodeDirs = @()
    try { $nodeDirs += @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages\OpenJS.NodeJS*\node-*-win-x64\node.exe') -ErrorAction SilentlyContinue | ForEach-Object { $_.DirectoryName }) } catch {}
    $nodeDirs += @((Join-Path $env:ProgramFiles 'nodejs'), (Join-Path $env:LOCALAPPDATA 'Programs\nodejs'))
    foreach ($dir in $nodeDirs) {
      if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'node.exe'))) {
        $env:Path = [string]$dir + ';' + $env:Path
        break
      }
    }
  }
  if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host 'SKIP: node not found'
    exit 0
  }
  if (-not (Get-Command npm.cmd -ErrorAction SilentlyContinue)) {
    Write-Host 'SKIP: npm.cmd not found'
    exit 0
  }

  New-Item -ItemType Directory -Path (Join-Path $bridgeRoot 'channels\unit') -Force | Out-Null
  New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

  $channel = [ordered]@{ project_root = $projectRoot }
  [System.IO.File]::WriteAllText(
    (Join-Path $bridgeRoot 'channels\unit\channel.json'),
    (($channel | ConvertTo-Json -Depth 4) + "`n"),
    (New-Object System.Text.UTF8Encoding($false))
  )

  $pkg = [ordered]@{
    scripts = [ordered]@{
      typecheck = 'node -e "console.error(''typecheck-stderr-ok''); process.exit(0)"'
      build = 'node -e "console.log(''build-stdout-ok''); process.exit(0)"'
    }
  }
  [System.IO.File]::WriteAllText(
    (Join-Path $projectRoot 'package.json'),
    (($pkg | ConvertTo-Json -Depth 6) + "`n"),
    (New-Object System.Text.UTF8Encoding($false))
  )

  $oldBridgeRoot = $env:BRIDGE_ROOT
  $env:BRIDGE_ROOT = $bridgeRoot
  try {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\project-verify.ps1') -Channel unit | Out-String
    $exit = [int]$LASTEXITCODE
  } finally {
    $env:BRIDGE_ROOT = $oldBridgeRoot
  }

  if ($exit -ne 0) {
    Write-Host $out
    Write-Host "FAIL: project-verify exited $exit"
    exit 1
  }
  if ($out -notmatch 'PASS typecheck' -or $out -notmatch 'PASS build' -or $out -notmatch 'RESULT: ALL PASS') {
    Write-Host $out
    Write-Host 'FAIL: project-verify did not report expected pass lines'
    exit 1
  }
  Write-Host 'PASS: project-verify runs npm scripts through ProcessStartInfo helper'
  exit 0
} finally {
  if (Test-Path -LiteralPath $sandbox) {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
  }
}
