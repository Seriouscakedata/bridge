#Requires -Version 5.1
# test-no-progress-doctor-escalation.ps1 -- source-level guard for no-progress Doctor escalation.

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'driver\85-loop-mode-transitions.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

Assert-True ($source -match "Activate-Doctor\s+-Reason\s+'no_progress_loop'") 'no-progress threshold must activate Doctor with reason no_progress_loop'
Assert-True ($source -notmatch 'if\s*\(\$newNpc\s+-ge\s+4\)\s*\{(?s).*?no_progress_count\s*=\s*0') 'no-progress threshold must not self-reset before escalation'

Write-Output 'NO PROGRESS DOCTOR ESCALATION TEST OK'
