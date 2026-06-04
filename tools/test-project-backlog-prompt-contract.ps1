param()

$ErrorActionPreference = 'Stop'

function Assert-Contains {
  param([string]$Text, [string]$Needle, [string]$Message)
  if ($Text.IndexOf($Needle, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw $Message
  }
}

$root = Split-Path -Parent $PSScriptRoot
$promptBuilderPath = Join-Path $root 'lib\prompt-builder.ps1'
$backlogAutopilotPath = Join-Path $root 'lib\backlog-autopilot.ps1'

$promptBuilderText = [System.IO.File]::ReadAllText($promptBuilderPath, [System.Text.Encoding]::UTF8)
$autopilotStart = $promptBuilderText.IndexOf('- PROJECT AUTOPILOT:', [System.StringComparison]::Ordinal)
if ($autopilotStart -lt 0) { throw 'driver PROJECT AUTOPILOT prompt block not found' }
$autopilotEnd = $promptBuilderText.IndexOf('- ДОЛГИЕ ПРОЦЕССЫ:', $autopilotStart, [System.StringComparison]::Ordinal)
if ($autopilotEnd -lt 0) { $autopilotEnd = [Math]::Min($promptBuilderText.Length, $autopilotStart + 2500) }
$autopilotBlock = $promptBuilderText.Substring($autopilotStart, $autopilotEnd - $autopilotStart)

$required = @('slug','title','task','chapter','wave','parallel_group','files','depends_on','acceptance','checks','serial_reason')
foreach ($field in $required) {
  Assert-Contains -Text $autopilotBlock -Needle $field -Message ("driver PROJECT AUTOPILOT prompt missing required field: " + $field)
}
if (($autopilotBlock.IndexOf('risk', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) -and ($autopilotBlock.IndexOf('severity', [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) {
  throw 'driver PROJECT AUTOPILOT prompt missing risk/severity requirement'
}
if ($autopilotBlock -match 'Каждый atom:\s*`slug`,\s*`title`,\s*`task`,\s*`files`,\s*`depends_on`,\s*`severity`') {
  throw 'driver PROJECT AUTOPILOT prompt regressed to stale minimal schema'
}
Assert-Contains -Text $autopilotBlock -Needle 'STRICT JSON array' -Message 'driver prompt must require STRICT JSON array'
Assert-Contains -Text $autopilotBlock -Needle 'deterministic gate' -Message 'driver prompt must mention deterministic gate rejection'
Assert-Contains -Text $autopilotBlock -Needle 'backlog.jsonl' -Message 'driver prompt must forbid manual backlog.jsonl edits'

$backlogText = [System.IO.File]::ReadAllText($backlogAutopilotPath, [System.Text.Encoding]::UTF8)
$coordStart = $backlogText.IndexOf('function New-ProjectAutopilotCoordinatorTaskText', [System.StringComparison]::Ordinal)
if ($coordStart -lt 0) { throw 'New-ProjectAutopilotCoordinatorTaskText not found' }
$coordEnd = $backlogText.IndexOf('function Test-ProjectPlanApproved', $coordStart, [System.StringComparison]::Ordinal)
if ($coordEnd -lt 0) { throw 'New-ProjectAutopilotCoordinatorTaskText end marker not found' }
$coordBlock = $backlogText.Substring($coordStart, $coordEnd - $coordStart)

foreach ($field in $required) {
  Assert-Contains -Text $coordBlock -Needle ('"' + $field + '"') -Message ("coordinator PROJECT_BACKLOG example missing required field: " + $field)
}
if (($coordBlock.IndexOf('"risk"', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) -and ($coordBlock.IndexOf('"severity"', [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) {
  throw 'coordinator PROJECT_BACKLOG example missing risk/severity field'
}
Assert-Contains -Text $coordBlock -Needle 'workpack_touch_set' -Message 'coordinator prompt should document optional workpack_touch_set'
Assert-Contains -Text $coordBlock -Needle 'workpack_conflict_group' -Message 'coordinator prompt should document optional workpack_conflict_group'
Assert-Contains -Text $coordBlock -Needle 'deterministic ingest gate' -Message 'coordinator prompt must mention deterministic ingest gate'

Write-Output 'PROJECT BACKLOG PROMPT CONTRACT TEST OK'
