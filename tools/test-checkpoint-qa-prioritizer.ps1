# Regression tests for task checkpoint/restore, QA scenario runner, and backlog prioritizer prompt.

$ErrorActionPreference = 'Stop'
$bridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $bridgeRoot 'lib\checkpoint.ps1')
. (Join-Path $bridgeRoot 'lib\qa-agent.ps1')
. (Join-Path $bridgeRoot 'lib\backlog.ps1')

$script:pass = 0
$script:fail = 0

function Check {
  param([string]$Name, [bool]$Condition, [string]$Detail = '')
  if ($Condition) {
    Write-Host "PASS: $Name"
    $script:pass++
  } else {
    Write-Host "FAIL: $Name $Detail"
    $script:fail++
  }
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-checkpoint-qa-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

try {
  function Get-TaskCheckpointBridgeRoot { return $sandbox }
  $state = [pscustomobject][ordered]@{
    current_task_id = 'task-unit'
    current_backlog_id = 'backlog-unit'
    task_turn = 3
    task_mode = 'normal'
    active_agent = 'codex'
    status_text = 'working'
    workpack_batch_ids = @()
    progress_fingerprints = @('abc')
  }
  $cp = Save-TaskCheckpointFromState -State $state -TaskTitle 'Unit checkpoint task' -Channel 'main' -Reason 'before-agent' -Prompt 'PROMPT BODY' -Context 'SUMMARY BODY'
  $read = Read-TaskCheckpoint -TaskId 'task-unit' -Channel 'main'
  $restore = Format-TaskCheckpointRestoreText -Checkpoint $read
  Check 'checkpoint writes JSONL row' ($null -ne $cp -and (Test-Path (Join-Path $sandbox 'channels\main\checkpoints\task-unit.jsonl')))
  Check 'checkpoint restores summary and reason' ($restore -match 'SUMMARY BODY' -and $restore -match 'before-agent') $restore

  $qaRoot = Join-Path $sandbox 'qa'
  $toolsDir = Join-Path $qaRoot 'tools'
  $scenariosDir = Join-Path $toolsDir 'scenarios'
  New-Item -ItemType Directory -Path $scenariosDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $scenariosDir 'alpha.js'), "// @audit-safe: yes`n// alpha", (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText((Join-Path $scenariosDir 'unsafe.js'), "// @audit-safe: no`n// unsafe", (New-Object System.Text.UTF8Encoding($false)))
  $runner = @'
param([string]$Name,[string]$Url,[int]$TimeoutSec)
Write-Host ("dummy scenario " + $Name)
exit 0
'@
  [System.IO.File]::WriteAllText((Join-Path $toolsDir 'scenario.ps1'), $runner, (New-Object System.Text.UTF8Encoding($true)))
  $qa = Invoke-QAAgentScenarioSuite -BridgeRoot $qaRoot -Url 'http://localhost:8787' -TimeoutSec 5
  Check 'QA scenario suite runs audit-safe dummy scenario' ([bool]$qa.Ran -and [bool]$qa.Ok -and [int]$qa.Passed -eq 1) ($qa | ConvertTo-Json -Compress -Depth 5)
  Check 'QA scenario suite skips unsafe scenarios by default' ([int]$qa.Skipped -eq 1 -and @($qa.SkippedUnsafe) -contains 'unsafe.js') ($qa | ConvertTo-Json -Compress -Depth 5)
  $qaPostCommit = Invoke-QAAgentPostCommit -BridgeRoot $qaRoot -CommitSha 'abcdef1234567890' -TaskId 'task-unit' -TaskTitle 'Unit QA task' -Channel 'main'
  Check 'QA post-commit returns PASS verdict' ([string]$qaPostCommit.Verdict -eq 'PASS' -and [string]$qaPostCommit.Summary -match 'post-commit abcdef1') ($qaPostCommit | ConvertTo-Json -Compress -Depth 5)
  Check 'QA post-commit writes qa-results ledger' (Test-Path (Join-Path $qaRoot 'channels\main\qa-results.jsonl'))

  $config = Get-Content -LiteralPath (Join-Path $bridgeRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Check 'config enables idle backlog prioritizer explicitly' ([bool]$config.backlog.enableLLMPrioritizerOnIdle -and [int]$config.backlog.prioritizerIntervalMinutes -eq 60 -and [int]$config.backlog.prioritizerMaxItems -eq 20)
  Check 'config keeps unsafe QA scenarios disabled by default' (-not [bool]$config.qaRunner.runUnsafeScenarios)

  $prompt = New-BacklogLLMPriorityPrompt -Ideas @(
    [pscustomobject]@{ id='hard'; text='Fix recurring timeout and avoidance of hard task'; effort=5; value=5 },
    [pscustomobject]@{ id='easy'; text='Small cosmetic cleanup'; effort=1; value=1 }
  )
  Check 'prioritizer prompt includes anti-avoidance criteria' ($prompt -match 'Anti-avoidance' -and $prompt -match 'сложные/избегаемые') $prompt
} catch {
  Write-Host "FAIL: unhandled exception :: $($_.Exception.Message)"
  $script:fail++
} finally {
  Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("Checkpoint/QA/prioritizer tests: {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
