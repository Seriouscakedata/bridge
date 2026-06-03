param()

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')

$fail = 0
function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) {
    Write-Host "FAIL $Message"
    $script:fail++
  }
}

$cfgPath = Join-Path $root 'config.json'
$raw = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
Assert-True -Condition (-not ($raw -match '(?i)C:[/\\]+Users[/\\]+')) -Message 'tracked config.json must not contain a Windows user profile path'
Assert-True -Condition (-not ($raw -match '(?i)OneDrive[/\\]+Documents[/\\]+bridge')) -Message 'tracked config.json must not contain a local bridge worktree path'

$trackedCfg = $raw | ConvertFrom-Json
Assert-True -Condition ([string]::IsNullOrWhiteSpace([string]$trackedCfg.codexExe)) -Message 'tracked codexExe should be empty'
Assert-True -Condition ([string]::IsNullOrWhiteSpace([string]$trackedCfg.claudeGlob)) -Message 'tracked claudeGlob should be empty'
Assert-True -Condition ([string]::IsNullOrWhiteSpace([string]$trackedCfg.workRoot)) -Message 'tracked workRoot should be empty'

$oldCodex = [System.Environment]::GetEnvironmentVariable('BRIDGE_CODEX_EXE')
$oldClaude = [System.Environment]::GetEnvironmentVariable('BRIDGE_CLAUDE_GLOB')
$oldWorkRoot = [System.Environment]::GetEnvironmentVariable('BRIDGE_WORK_ROOT')
$oldUserProfile = [System.Environment]::GetEnvironmentVariable('USERPROFILE')
try {
  [System.Environment]::SetEnvironmentVariable('BRIDGE_CODEX_EXE', 'X:\bridge-test\codex.exe', 'Process')
  [System.Environment]::SetEnvironmentVariable('BRIDGE_CLAUDE_GLOB', 'X:\bridge-test\claude-code\*\claude.exe', 'Process')
  [System.Environment]::SetEnvironmentVariable('BRIDGE_WORK_ROOT', 'X:\bridge-test\work', 'Process')
  $script:__bridgeCfgCache = $null

  $cfg = Get-BridgeConfig
  Assert-True -Condition ([string]$cfg.codexExe -eq 'X:\bridge-test\codex.exe') -Message 'BRIDGE_CODEX_EXE should override codexExe'
  Assert-True -Condition ([string]$cfg.claudeGlob -eq 'X:\bridge-test\claude-code\*\claude.exe') -Message 'BRIDGE_CLAUDE_GLOB should override claudeGlob'
  Assert-True -Condition ([string]$cfg.workRoot -eq 'X:\bridge-test\work') -Message 'BRIDGE_WORK_ROOT should override workRoot'

  [System.Environment]::SetEnvironmentVariable('BRIDGE_WORK_ROOT', $null, 'Process')
  [System.Environment]::SetEnvironmentVariable('USERPROFILE', 'X:\bridge-test\profile', 'Process')
  $script:__bridgeCfgCache = $null
  $cfg = Get-BridgeConfig
  Assert-True -Condition ([string]$cfg.workRoot -eq 'X:\bridge-test\profile') -Message 'empty workRoot should fall back to USERPROFILE'
} finally {
  [System.Environment]::SetEnvironmentVariable('BRIDGE_CODEX_EXE', $oldCodex, 'Process')
  [System.Environment]::SetEnvironmentVariable('BRIDGE_CLAUDE_GLOB', $oldClaude, 'Process')
  [System.Environment]::SetEnvironmentVariable('BRIDGE_WORK_ROOT', $oldWorkRoot, 'Process')
  [System.Environment]::SetEnvironmentVariable('USERPROFILE', $oldUserProfile, 'Process')
  $script:__bridgeCfgCache = $null
}

if ($fail -gt 0) {
  throw "test-config-overrides failed: $fail assertion(s)"
}

Write-Host 'CONFIG OVERRIDES TEST OK'
