# backlog.ps1 -- compatibility loader for the backlog subsystem.
# The implementation is split into lib/backlog/*.ps1 to keep agent context small.
# Dot-source this file exactly as before; it preserves the old public function surface.

$backlogModuleDir = Join-Path $PSScriptRoot 'backlog'
$backlogModules = @(
  '00-core.ps1',
  '10-pack-config.ps1',
  '11-workpack-classify.ps1',
  '12-workpack-exec.ps1',
  '20-store.ps1',
  '21-priority-curator.ps1',
  '30-claim.ps1',
  '40-autopilot-state.ps1',
  '41-autopilot-contract.ps1',
  '42-autopilot-run.ps1',
  '50-selfexec.ps1'
)

foreach ($moduleName in $backlogModules) {
  $modulePath = Join-Path $backlogModuleDir $moduleName
  if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw "Backlog module missing: $modulePath"
  }
  . $modulePath
}