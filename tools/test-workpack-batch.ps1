param()

$ErrorActionPreference = 'Stop'

$script:TestBridgeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-workpack-batch-test-' + [guid]::NewGuid().ToString('N'))

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Get-BridgeRoot { return $script:TestBridgeRoot }
function Get-EffectiveChannel { return 'main' }
function Get-ChannelDir {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = 'main' }
  return (Join-Path (Join-Path $script:TestBridgeRoot 'channels') $Slug)
}
function Get-ChannelBacklogPath {
  param([string]$Slug = $null)
  return (Join-Path (Get-ChannelDir -Slug $Slug) 'backlog.jsonl')
}
function Use-BridgeLock {
  param([scriptblock]$Body)
  & $Body
}
function Get-AutonomySettings {
  return [pscustomobject]@{
    workpackExecEnabled = $true
    workpackExecMinItems = 2
    workpackExecMaxItems = 3
    workpackExecIncludeProtected = $false
    backlogPackEnabled = $true
    backlogPackBurstCount = 5
    backlogPackWindowMinutes = 60
    backlogPackUnpackedOpenCount = 8
    backlogPackAuditBurstCount = 3
    backlogPackAuditWindowMinutes = 30
    backlogPackCooldownMinutes = 30
    backlogPackMinItems = 2
  }
}

try {
  $mainDir = Get-ChannelDir -Slug 'main'
  New-Item -ItemType Directory -Path $mainDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Get-ChannelBacklogPath -Slug 'main'), '', (New-Object System.Text.UTF8Encoding($false)))

  . (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\backlog.ps1')

  $idAudit = Add-Idea -Text 'fix audit scenario stale warning in tools/audit-functional.ps1' -From 'test' -Status 'approved' -SkipCurator
  $idMemory = Add-Idea -Text 'tighten memory recall guard in lib/memory.ps1' -From 'test' -Status 'approved' -SkipCurator
  $idAudit2 = Add-Idea -Text 'another audit-only tweak in tools/audit.ps1' -From 'test' -Status 'approved' -SkipCurator
  $idSafety = Add-Idea -Text 'change watchdog safety behavior in watchdog.ps1' -From 'test' -Status 'approved' -SkipCurator

  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idAudit) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-audit' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'audit' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('tools/audit-functional.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idMemory) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-memory' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'memory' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('lib/memory.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idAudit2) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-audit-2' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'audit' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('tools/audit.ps1') -Force
    } elseif ([string]$item.id -eq [string]$idSafety) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-safety' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'safety' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('watchdog.ps1') -Force
    }
  }
  Save-Backlog $items

  $batch = Get-NextBacklogWorkpackBatch
  Assert-True ($batch -ne $null) 'expected a workpack batch'
  Assert-True ([int]$batch.count -eq 2) ("expected 2 selected items, got {0}" -f [int]$batch.count)
  Assert-True (@($batch.ids) -contains [string]$idAudit) 'expected audit item'
  Assert-True (@($batch.ids) -contains [string]$idMemory) 'expected memory item'
  Assert-True (-not (@($batch.ids) -contains [string]$idAudit2)) 'same conflict group should be skipped'
  Assert-True (-not (@($batch.ids) -contains [string]$idSafety)) 'protected safety group should be skipped by default'

  $taskText = New-BacklogWorkpackBatchTaskText -Items @($batch.items)
  Assert-True ($taskText -match '\[\[PARALLEL:wp1\]\]') 'expected parallel template wp1'
  Assert-True ($taskText -match '\[\[PARALLEL:wp2\]\]') 'expected parallel template wp2'
  Assert-True ($taskText -match 'STATUS:\s*CONTINUE') 'expected planner status hint'

  $startSrvText = '[deep-agent/reliability-model/deepseek-v4-flash] process_supervision -- Start-Srv and Start-Drv use Start-Process with -NoNewWindow but redirect stdout/stderr to files. If the log file path is unavailable, supervisor can fail silently.'
  $reapText = '[deep-agent/reliability-model/deepseek-v4-flash] process_supervision -- Reap-Bloated kills tracked processes with private memory > 8GB. The threshold is hardcoded.'
  $auditText = '[deep-claude/Functional Bug] : The deep-audit phase of audit-self-diag is encountering Get-BacklogPath exceptions during drift analysis.'
  $orphanRestartText = '[deep-agent/runtime-incident-model/deepseek-v4-flash] orphan-restart -- Multiple orphan restarts detected with no associated task turn within 5 minutes. Consider adding task attribution to restart events.'
  $featureStateText = "[deep-claude/Data Structure / Registry Drift] : The 'features\state.json' file contains a single, very long key that concatenates multiple feature IDs and scenario_results."
  $commandInjectionText = '[deep-agent/security-model/deepseek-v4-pro] command_injection -- The script passes user-supplied arguments directly to powershell.exe via -File; sub-scripts tools\replay-cli.ps1 and tools\live-status.ps1 receive unsanitized input.'
  $taskkillText = '[deep-agent/security-model/deepseek-v4-pro] command_injection -- The script constructs and executes ''taskkill /PID $_.ProcessId /F /T'' using string interpolation.'
  $configSecretText = '[deep-codex/security] hardcoded_secrets (config.json:1) -- Recommend: Use environment variables or relative paths instead of hardcoded absolute paths.'
  $toolPathSecretText = "[deep-agent/security-model/deepseek-v4-pro] hardcoded_secrets -- The configuration file contains hardcoded paths: 'C:/Users/rafie/AppData/Local/OpenAI/Codex/bin/codex.exe', 'C:/Users/rafie/AppData/Roaming/Claude/claude-code/*/claude.exe', 'C:/Users/rafie/OneDrive/Documents/bridge-canary-worktree'."
  $unsafeDynamicText = '[deep-codex/security] unsafe_dynamic_execution (canary.ps1:1) -- Recommend: If channels.ps1 is optional, make this explicit rather than silently continuing.'
  $intentClassifierText = 'для bridge — при аудит-задачах с явным «без дебатов / заверши STATUS: DONE» классификатор намерений не должен форсить discuss-режим'
  $codexExecText = "deep-think discuss-mode не получает ответ Codex — codex exec падает с unexpected argument '-' found; проверить, как driver передаёт discuss-промпт в codex"
  $startClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $startSrvText })
  $reapClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $reapText })
  $auditClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $auditText })
  $orphanClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $orphanRestartText })
  $featureStateClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $featureStateText })
  $commandInjectionClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $commandInjectionText })
  $taskkillClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $taskkillText })
  $configSecretClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $configSecretText })
  $toolPathSecretClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $toolPathSecretText })
  $unsafeDynamicClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $unsafeDynamicText })
  $intentClassifierClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $intentClassifierText })
  $codexExecClass = Get-BacklogWorkpackClassification -Item ([pscustomobject]@{ text = $codexExecText })
  Assert-True (@($startClass.touch_set) -contains 'supervisor.ps1') 'Start-Srv/Start-Drv should infer supervisor.ps1'
  Assert-True (@($reapClass.touch_set) -contains 'supervisor.ps1') 'Reap-Bloated should infer supervisor.ps1'
  Assert-True ([string]$startClass.key -eq 'file:supervisor.ps1') ("expected supervisor key for Start-Srv, got {0}" -f [string]$startClass.key)
  Assert-True ([string]$reapClass.key -eq 'file:supervisor.ps1') ("expected supervisor key for Reap-Bloated, got {0}" -f [string]$reapClass.key)
  Assert-True ([string]$startClass.conflict_group -eq 'safety') 'supervisor Start-Srv should be safety conflict'
  Assert-True ([string]$reapClass.conflict_group -eq 'safety') 'supervisor Reap-Bloated should be safety conflict'
  Assert-True (@($auditClass.touch_set) -contains 'tools/audit.ps1') 'deep-audit Get-BacklogPath should infer tools/audit.ps1'
  Assert-True (@($auditClass.touch_set) -contains 'lib/backlog.ps1') 'deep-audit Get-BacklogPath should infer lib/backlog.ps1'
  Assert-True (@($orphanClass.touch_set) -contains 'lib/circuit-breaker.ps1') 'orphan-restart should infer circuit breaker'
  Assert-True (-not (@($orphanClass.touch_set) -contains 'llm')) 'orphan-restart source model should not become llm touch'
  Assert-True ([string]$orphanClass.conflict_group -eq 'safety') 'orphan-restart should be safety conflict'
  Assert-True ([string]$featureStateClass.key -eq 'file:features/state.js') ("expected feature state key, got {0}" -f [string]$featureStateClass.key)
  Assert-True ([string]$featureStateClass.conflict_group -eq 'state') 'feature state drift should be state conflict'
  Assert-True ([string]$commandInjectionClass.conflict_group -eq 'safety') 'command injection should be safety conflict'
  Assert-True (-not ([string]$taskkillClass.key -eq 'module:ui')) 'taskkill text should not be misread as ui'
  Assert-True (@($taskkillClass.touch_set) -contains 'supervisor.ps1') 'taskkill ProcessId text should infer supervisor.ps1'
  Assert-True ([string]$taskkillClass.conflict_group -eq 'safety') 'taskkill text should be safety conflict'
  Assert-True ([string]$configSecretClass.key -eq 'file:config.json') ("expected config.json key, got {0}" -f [string]$configSecretClass.key)
  Assert-True ([string]$configSecretClass.conflict_group -eq 'safety') 'hardcoded secrets should be safety conflict'
  Assert-True ([string]$toolPathSecretClass.key -eq 'file:config.json') ("expected tool path hardcoded secret to map to config.json, got {0}" -f [string]$toolPathSecretClass.key)
  Assert-True (-not (@($toolPathSecretClass.touch_set) -contains 'lib/parallel.ps1')) 'worktree path alone should not infer lib/parallel.ps1'
  Assert-True (@($unsafeDynamicClass.touch_set) -contains 'lib/channels.ps1') 'bare channels.ps1 should infer lib/channels.ps1'
  Assert-True (@('core','safety') -contains [string]$unsafeDynamicClass.conflict_group) 'unsafe dynamic execution should be protected'
  Assert-True ([string]$intentClassifierClass.key -eq 'file:driver.ps1') 'Russian intent classifier task should infer driver.ps1'
  Assert-True ([string]$codexExecClass.key -eq 'file:driver.ps1') 'codex exec discuss-mode task should infer driver.ps1'

  $idStale = Add-Idea -Text $startSrvText -From 'test' -Status 'approved' -SkipCurator
  $items = @(Get-Backlog)
  foreach ($item in $items) {
    if ([string]$item.id -eq [string]$idStale) {
      $item | Add-Member -NotePropertyName workpack_id -NotePropertyValue 'wp-stale-supervisor' -Force
      $item | Add-Member -NotePropertyName workpack_root_cause_key -NotePropertyValue 'module:llm' -Force
      $item | Add-Member -NotePropertyName workpack_conflict_group -NotePropertyValue 'llm' -Force
      $item | Add-Member -NotePropertyName workpack_touch_set -NotePropertyValue @('llm') -Force
    }
  }
  Save-Backlog $items
  $updated = Update-BacklogWorkpackClassifications
  Assert-True ([int]$updated -ge 1) 'expected stale workpack classification to be refreshed'
  $stale = @(Get-Backlog | Where-Object { [string]$_.id -eq [string]$idStale })[0]
  Assert-True ([string]$stale.workpack_root_cause_key -eq 'file:supervisor.ps1') 'expected stale supervisor task key to be refreshed'
  Assert-True ([string]$stale.workpack_conflict_group -eq 'safety') 'expected stale supervisor task conflict group to be refreshed'
  Assert-True (@($stale.workpack_touch_set) -contains 'supervisor.ps1') 'expected stale supervisor task touch set to be refreshed'

  Write-Host ('OK workpack batch: selected {0} independent items' -f [int]$batch.count)
} finally {
  try {
    $resolved = [System.IO.Path]::GetFullPath($script:TestBridgeRoot)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolved.StartsWith($tempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolved)) {
      Remove-Item -LiteralPath $resolved -Recurse -Force
    }
  } catch {}
}
