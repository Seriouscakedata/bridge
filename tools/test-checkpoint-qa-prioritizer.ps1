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
  $secretPrompt = 'PROMPT BODY Authorization: Bearer abcdefghijk password=plain secrets.json contains hidden'
  $cp = Save-TaskCheckpointFromState -State $state -TaskTitle 'Unit checkpoint task' -Channel 'main' -Reason 'before-agent' -Prompt $secretPrompt -Context 'SUMMARY BODY'
  $read = Read-TaskCheckpoint -TaskId 'task-unit' -Channel 'main'
  $restore = Format-TaskCheckpointRestoreText -Checkpoint $read
  Check 'checkpoint writes JSONL row' ($null -ne $cp -and (Test-Path (Join-Path $sandbox 'channels\main\checkpoints\task-unit.jsonl')))
  Check 'checkpoint restores summary and reason' ($restore -match 'SUMMARY BODY' -and $restore -match 'before-agent') $restore
  Check 'checkpoint redacts secrets from stored prompt' ([string]$read.prompt -notmatch 'abcdefghijk|plain|hidden' -and [string]$read.prompt -match '<redacted>') ([string]$read.prompt)
  foreach ($n in 1..25) {
    Write-TaskCheckpoint -TaskId 'rotate-unit' -TaskTitle 'Rotate' -Step $n -Channel 'main' -Reason 'unit' -Prompt 'p' -Context 'c' | Out-Null
  }
  $rotatePath = Join-Path $sandbox 'channels\main\checkpoints\rotate-unit.jsonl'
  $rotateLines = @([System.IO.File]::ReadAllLines($rotatePath, [System.Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
  Check 'checkpoint rotation keeps bounded JSONL history' ($rotateLines.Count -le 20) ('lines=' + $rotateLines.Count)

  $qaRoot = Join-Path $sandbox 'qa'
  $toolsDir = Join-Path $qaRoot 'tools'
  $scenariosDir = Join-Path $toolsDir 'scenarios'
  New-Item -ItemType Directory -Path $scenariosDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $scenariosDir 'alpha.js'), "// @audit-safe: yes`n// alpha", (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText((Join-Path $scenariosDir 'unsafe.js'), "// @audit-safe: no`n// unsafe", (New-Object System.Text.UTF8Encoding($false)))
  $runner = @'
param([string]$Name,[string]$Url,[int]$TimeoutSec)
Write-Host ("dummy scenario " + $Name)
if ($Name -eq "fail") { Write-Error "forced scenario failure"; exit 1 }
exit 0
'@
  [System.IO.File]::WriteAllText((Join-Path $toolsDir 'scenario.ps1'), $runner, (New-Object System.Text.UTF8Encoding($true)))
  $qa = Invoke-QAAgentScenarioSuite -BridgeRoot $qaRoot -Url 'http://localhost:8787' -TimeoutSec 5
  Check 'QA scenario suite runs audit-safe dummy scenario' ([bool]$qa.Ran -and [bool]$qa.Ok -and [int]$qa.Passed -eq 1) ($qa | ConvertTo-Json -Compress -Depth 5)
  Check 'QA scenario suite skips unsafe scenarios by default' ([int]$qa.Skipped -eq 1 -and @($qa.SkippedUnsafe) -contains 'unsafe.js') ($qa | ConvertTo-Json -Compress -Depth 5)
  $qaPostCommit = Invoke-QAAgentPostCommit -BridgeRoot $qaRoot -CommitSha 'abcdef1234567890' -TaskId 'task-unit' -TaskTitle 'Unit QA task' -Channel 'main'
  Check 'QA post-commit returns PASS verdict' ([string]$qaPostCommit.Verdict -eq 'PASS' -and [string]$qaPostCommit.Summary -match 'post-commit abcdef1') ($qaPostCommit | ConvertTo-Json -Compress -Depth 5)
  Check 'QA post-commit writes qa-results ledger' (Test-Path (Join-Path $qaRoot 'channels\main\qa-results.jsonl'))
  [System.IO.File]::WriteAllText((Join-Path $scenariosDir 'fail.js'), "// @audit-safe: yes`n// fail", (New-Object System.Text.UTF8Encoding($false)))
  $qaFail = Invoke-QAAgentPostCommit -BridgeRoot $qaRoot -CommitSha '1234567890abcdef' -TaskId 'task-unit' -TaskTitle 'Unit QA fail task' -Channel 'main'
  Check 'QA post-commit returns FAIL when scenario fails' ([string]$qaFail.Verdict -eq 'FAIL' -and [string]$qaFail.Summary -match 'scenarios FAIL') ($qaFail | ConvertTo-Json -Compress -Depth 5)

  $configText = [System.IO.File]::ReadAllText((Join-Path $bridgeRoot 'config.json'), [System.Text.Encoding]::UTF8)
  $config = ConvertFrom-BacklogJsonDictionary -JsonText $configText
  $backlogCfg = Get-BacklogDictionaryValue -Map $config -Name 'backlog' -Default $null
  $qaCfg = Get-BacklogDictionaryValue -Map $config -Name 'qaRunner' -Default $null
  Check 'config enables idle backlog prioritizer explicitly' ([bool](Get-BacklogDictionaryValue -Map $backlogCfg -Name 'enableLLMPrioritizerOnIdle' -Default $false) -and [int](Get-BacklogDictionaryValue -Map $backlogCfg -Name 'prioritizerIntervalMinutes' -Default 0) -eq 60 -and [int](Get-BacklogDictionaryValue -Map $backlogCfg -Name 'prioritizerMaxItems' -Default 0) -eq 20)
  Check 'config keeps unsafe QA scenarios disabled by default' (-not [bool](Get-BacklogDictionaryValue -Map $qaCfg -Name 'runUnsafeScenarios' -Default $true))
  $prioritySettings = Get-BacklogPrioritizerSettings -Channel 'main' -IntervalMinutes 60 -MaxItems 20
  Check 'prioritizer settings distinguish idle from claim-time LLM priority' ([bool]$prioritySettings.IdleEnabled -and -not [bool]$prioritySettings.UseLLMPriority -and [bool]$prioritySettings.Enabled) ($prioritySettings | ConvertTo-Json -Compress -Depth 5)

  $prompt = New-BacklogLLMPriorityPrompt -Ideas @(
    [pscustomobject]@{ id='hard'; text='Fix recurring timeout and avoidance of hard task'; effort=5; value=5 },
    [pscustomobject]@{ id='easy'; text='Small cosmetic cleanup'; effort=1; value=1 }
  )
  Check 'prioritizer prompt includes anti-avoidance criteria' ($prompt -match 'Anti-avoidance' -and $prompt -match 'сложные/избегаемые') $prompt
  $prioItems = @(
    [pscustomobject][ordered]@{ id='easy'; status='approved'; score=1; text='Small cosmetic cleanup' },
    [pscustomobject][ordered]@{ id='done'; status='done'; score=99; text='Already done' },
    [pscustomobject][ordered]@{ id='hard'; status='approved'; score=1; text='Fix recurring timeout and avoidance of hard task' }
  )
  $prioIdeas = @($prioItems[0], $prioItems[2])
  $prioRanked = @(
    [pscustomobject]@{ id='hard'; score=95; reason='blocks repeated timeout' },
    [pscustomobject]@{ id='easy'; score=10; reason='low urgency' }
  )
  $prioUpdate = Update-BacklogLLMPriorityOrder -AllItems $prioItems -Ideas $prioIdeas -Ranked $prioRanked
  $prioOrder = @($prioUpdate.Items | ForEach-Object { [string]$_.id })
  Check 'prioritizer physically reorders eligible top-N slots' ($prioOrder[0] -eq 'hard' -and $prioOrder[1] -eq 'done' -and $prioOrder[2] -eq 'easy' -and [bool]$prioUpdate.Reordered) ($prioOrder -join ',')
  Check 'prioritizer persists LLM score fields on items' ([double]$prioUpdate.Items[0].llm_priority_score -eq 95 -and [string]$prioUpdate.Items[0].llm_priority_reason -match 'timeout') ($prioUpdate.Items[0] | ConvertTo-Json -Compress -Depth 5)

  $commonSource = [System.IO.File]::ReadAllText((Join-Path $bridgeRoot 'lib\common.ps1'), [System.Text.Encoding]::UTF8)
  Check 'task failure kind allows qa_failed' ($commonSource -match "'qa_failed'") 'qa_failed missing from Set-TaskLastFailure ValidateSet'
  Check 'task failure helper can clear qa_failed only' ($commonSource -match 'function Clear-TaskLastFailureKind' -and $commonSource -match '\$curKind -eq \[string\]\$Kind') 'Clear-TaskLastFailureKind missing'
  $backlogCoreSource = [System.IO.File]::ReadAllText((Join-Path $bridgeRoot 'lib\backlog-core.ps1'), [System.Text.Encoding]::UTF8)
  $unsafeConfigReadPattern = 'Get-Content\s+\(Join-Path\s+\(Split-Path -Parent \$PSScriptRoot\)\s+''config\.json''\)\s+-Raw\s+-Encoding UTF8\s+\|\s+ConvertFrom-Json'
  Check 'Get-NextRunnableIdea uses safe prioritizer settings helper' ($backlogCoreSource -match 'Get-BacklogPrioritizerSettings' -and $backlogCoreSource -notmatch $unsafeConfigReadPattern) 'unsafe config read still present in Get-NextRunnableIdea'
  Check 'prioritizer settings avoid PSCustomObject ConvertFrom-Json config parse' ($backlogCoreSource -match 'ConvertFrom-BacklogJsonDictionary' -and $backlogCoreSource -notmatch '\$cfg\s*=\s*\$raw\s*\|\s*ConvertFrom-Json') 'prioritizer settings still uses ConvertFrom-Json for config'
  $completionCleanupSource = [System.IO.File]::ReadAllText((Join-Path $bridgeRoot 'driver\86-loop-completion-cleanup.ps1'), [System.Text.Encoding]::UTF8)
  Check 'completion cleanup fail-closes done when qa_failed remains' ($completionCleanupSource -match "\$lastFailureKind -eq 'qa_failed'" -and $completionCleanupSource -match "\$plannerStatus = 'CONTINUE'") 'cleanup qa_failed guard missing'
} catch {
  Write-Host "FAIL: unhandled exception :: $($_.Exception.Message)"
  $script:fail++
} finally {
  Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("Checkpoint/QA/prioritizer tests: {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
