#Requires -Version 5.1
param([string]$BridgeRoot = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0

function Assert {
  param([string]$Name, [bool]$Condition)
  if ($Condition) { Write-Host "PASS: $Name"; $script:pass++ }
  else { Write-Host "FAIL: $Name"; $script:fail++ }
}

. (Join-Path $BridgeRoot 'lib\postmortem.ps1')

$profile = Get-TimeoutPostMortemContextProfile `
  -Task 'Invoke-PlanDag path has MaxWaves wave-cap and TimeoutMin guard' `
  -Context 'Codex timeout after 2007s: 131KB output on opus-fallback slow model; work already complete.'

Assert 'guard detected' ([bool]$profile.has_timeout_guard)
Assert 'agent output delay detected' ([bool]$profile.likely_agent_output_delay)
Assert 'combined mode selected' ([string]$profile.mode -eq 'agent_output_delay_with_guard')
Assert 'guidance rejects unsupported infinite hang' ([string]$profile.guidance -match 'infinite hang')
Assert 'guidance names guard' ([string]$profile.guidance -match 'wave-cap|timeout guard')

$plain = Get-TimeoutPostMortemContextProfile -Task 'task timed out' -Context 'no other data'
Assert 'plain timeout has no guard' (-not [bool]$plain.has_timeout_guard)
Assert 'plain timeout has unknown mode' ([string]$plain.mode -eq 'unknown_timeout')

Write-Host "RESULT: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 }
exit 0
