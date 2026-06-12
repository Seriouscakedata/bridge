#Requires -Version 5.1
# memory-tail.ps1 -- stage 3a (speed program): the post-close memory writes (Add-TaskMemory,
# Update-ProjectMemoryAfterTask worklog, Add-SkillMemory) are 2-3 LLM calls that used to run
# SYNCHRONOUSLY inside the close path, blocking the next claim for ~2-3 minutes per task.
# The driver fires this script as a detached process (NOT a bridge job: active_jobs are
# awaited by preflight, which would re-block the loop) and closes immediately; memory lands a
# few seconds later and reports to the channel. Payload JSON keeps the big strings off the
# command line; it is deleted on completion. ASCII-only on purpose (PS5.1 + no-BOM hazard).
param([Parameter(Mandatory=$true)][string]$PayloadPath)

$ErrorActionPreference = 'Continue'
try {
  if (-not (Test-Path -LiteralPath $PayloadPath -PathType Leaf)) { exit 0 }
  $payload = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json

  $bridgeRoot = Split-Path -Parent $PSScriptRoot
  . (Join-Path $bridgeRoot 'lib\common.ps1')
  if (-not [string]::IsNullOrWhiteSpace([string]$payload.channel)) { $env:BRIDGE_CHANNEL = [string]$payload.channel }

  $task       = [string]$payload.task
  $outcome    = [string]$payload.outcome
  $mode       = [string]$payload.mode
  $modeBefore = [string]$payload.mode_before
  $didActions = [bool]$payload.did_actions
  $taskTurn   = [int]$payload.task_turn
  $startSeq   = [int]$payload.start_seq
  $commit     = [string]$payload.commit
  $notes      = New-Object System.Collections.Generic.List[string]

  try {
    $memId = Add-TaskMemory -TaskText $task -Outcome $outcome -Source ('task:' + $mode)
    if ($memId) { [void]$notes.Add('task-memory') }
  } catch {}
  try {
    if (($didActions -or $mode -eq 'study') -and (Get-Command Update-ProjectMemoryAfterTask -ErrorAction SilentlyContinue)) {
      $worklogId = Update-ProjectMemoryAfterTask -TaskText $task -Outcome $outcome -Channel ([string]$payload.channel) -Commit $commit
      if ($worklogId) { [void]$notes.Add('worklog') }
    }
  } catch {}
  try {
    if ($taskTurn -ge 2 -and $didActions -and $modeBefore -ne 'study') {
      $thread = (Get-Messages -Since ($startSeq - 1) | ForEach-Object { "**$($_.from):** $($_.text)" }) -join "`n`n"
      $skillId = Add-SkillMemory -TaskText $task -Transcript $thread
      if ($skillId) { [void]$notes.Add('playbook') }
    }
  } catch {}

  if ($notes.Count -gt 0) {
    try { Add-Message -From system -Text ('Memory tail (background): ' + ($notes -join ' + ') + ' written.') -Kind event | Out-Null } catch {}
  }
} finally {
  try { Remove-Item -LiteralPath $PayloadPath -Force -ErrorAction SilentlyContinue } catch {}
}
exit 0
