Set-StrictMode -Version Latest
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\backlog.ps1')
Set-StrictMode -Version Latest

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

$path = Join-Path (Join-Path $root 'tmp') 'coordinator-cost.jsonl'
$before = 0
if (Test-Path -LiteralPath $path) {
  $before = @([System.IO.File]::ReadAllLines($path) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
}

$written = Write-ProjectAutopilotCoordinatorCostMetric -Channel 'test-channel' -ChapterHint 'chapter-a' -WallclockSec 1.25 -AtomsEmitted 3
Assert-True ([string]$written -eq [string]$path) 'unexpected metric path'
Assert-True (Test-Path -LiteralPath $path) 'metric file missing'

$lines = @([System.IO.File]::ReadAllLines($path) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
Assert-True ($lines.Count -eq ($before + 1)) 'metric line was not appended'
$last = $lines[-1] | ConvertFrom-Json
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$last.ts)) 'ts missing'
Assert-True ([string]$last.channel -eq 'test-channel') 'channel mismatch'
Assert-True ([double]$last.wallclock_sec -ge 1.0) 'wallclock_sec invalid'
Assert-True ([int]$last.atoms_emitted -eq 3) 'atoms_emitted mismatch'

'test-coordinator-cost-metric: PASS'
