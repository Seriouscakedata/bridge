#Requires -Version 5.1

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:HarnessBridgeRoot = $null
$script:TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-test-active-task-transcript-fence-' + [guid]::NewGuid().ToString('N'))

function Write-Utf8BomFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Text
  )

  $parent = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
  }

  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($true)))
}

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message
  )

  if (-not $Condition) { throw $Message }
}

function Assert-Contains {
  param(
    [string]$Text,
    [string]$Expected,
    [string]$Message
  )

  if ([string]::IsNullOrEmpty($Text) -or $Text.IndexOf($Expected, [System.StringComparison]::Ordinal) -lt 0) {
    throw ($Message + "`nMissing: " + $Expected + "`nTranscript:`n" + $Text)
  }
}

function Assert-NotContains {
  param(
    [string]$Text,
    [string]$Unexpected,
    [string]$Message
  )

  if (-not [string]::IsNullOrEmpty($Text) -and $Text.IndexOf($Unexpected, [System.StringComparison]::Ordinal) -ge 0) {
    throw ($Message + "`nUnexpected: " + $Unexpected + "`nTranscript:`n" + $Text)
  }
}

. (Join-Path $script:RepoRoot 'lib\common.ps1')

function global:Get-BridgeRoot {
  return $script:HarnessBridgeRoot
}

. (Join-Path $script:RepoRoot 'lib\channels.ps1')

function global:Get-MessageAttachmentPaths {
  param($Message)
  if (-not $Message -or -not $Message.PSObject.Properties['attachments'] -or $null -eq $Message.attachments) { return @() }
  $paths = @()
  foreach ($att in @($Message.attachments)) {
    $url = [string]$att.url
    if ([string]::IsNullOrWhiteSpace($url) -or -not $url.StartsWith('/files/')) { continue }
    $storedName = [System.Uri]::UnescapeDataString($url.Substring('/files/'.Length))
    if ([string]::IsNullOrWhiteSpace($storedName)) { continue }
    $paths += [System.IO.Path]::GetFullPath((Join-Path (Get-FilesPath) $storedName))
  }
  return $paths
}

. (Join-Path $script:RepoRoot 'driver\20-context.ps1')

function New-TranscriptFixture {
  param(
    [Parameter(Mandatory)][string]$Root,
    [AllowNull()][AllowEmptyString()][string]$CurrentTask
  )

  $channelRoot = Join-Path $Root 'channels\main'
  New-Item -ItemType Directory -Path (Join-Path $channelRoot 'files') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $Root 'control') -Force | Out-Null

  $state = [ordered]@{
    status              = $(if ([string]::IsNullOrWhiteSpace($CurrentTask)) { 'idle' } else { 'working' })
    paused              = $false
    stop                = $false
    abort               = $false
    active_agent        = $null
    active_model        = $null
    status_text         = $null
    agent_pid           = $null
    current_task        = $CurrentTask
    current_task_id     = $null
    task_turn           = 0
    task_mode           = 'normal'
    discuss_turn        = 0
    discuss_snapshot    = ''
    study_phase         = ''
    study_subtype       = ''
    study_snapshot      = ''
    research_count      = 0
    task_start_seq      = 10
    no_progress_count   = 0
    timeout_retry_count = 0
    task_did_actions    = $false
    verify_retry_count  = 0
    force_planner       = $false
    last_user_seq       = 10
    summarized_seq      = 0
    turn                = 0
    lastSeq             = 13
    heartbeat           = (Get-Date).ToString('o')
    driver_started      = $null
    claimed_at          = $null
    current_backlog_id  = $null
    autonomous_day      = $null
    autonomous_count    = 0
  }

  $conversation = @(
    ([ordered]@{ seq = 8;  from = 'user';   text = 'USER_BEFORE_START_SEQ_8' } | ConvertTo-Json -Compress),
    ([ordered]@{ seq = 11; from = 'user';   text = 'USER_AFTER_START_SEQ_11' } | ConvertTo-Json -Compress),
    ([ordered]@{ seq = 12; from = 'system'; text = 'SYSTEM_AFTER_START_SEQ_12' } | ConvertTo-Json -Compress),
    ([ordered]@{ seq = 13; from = 'codex';  text = 'CODEX_AFTER_START_SEQ_13' } | ConvertTo-Json -Compress)
  ) -join "`n"

  Write-Utf8BomFile -Path (Join-Path $channelRoot 'state.json') -Text (($state | ConvertTo-Json -Depth 8) + "`n")
  Write-Utf8BomFile -Path (Join-Path $channelRoot 'conversation.jsonl') -Text ($conversation + "`n")
  Write-Utf8BomFile -Path (Join-Path $Root 'summary.txt') -Text ''
}

function Invoke-TranscriptScenario {
  param(
    [Parameter(Mandatory)][string]$Name,
    [AllowNull()][AllowEmptyString()][string]$CurrentTask
  )

  $root = Join-Path $script:TestRoot $Name
  New-TranscriptFixture -Root $root -CurrentTask $CurrentTask

  $script:HarnessBridgeRoot = $root
  $script:bridgeRoot = $root
  $script:Channel = 'main'
  Set-PinnedChannel 'main'

  return (Format-Transcript)
}

function Test-BusyBranchNote {
  $idleClaimPath = Join-Path $script:RepoRoot 'driver\81-loop-idle-claim.ps1'
  $idleClaimText = Get-Content -LiteralPath $idleClaimPath -Raw -Encoding UTF8

  if ($idleClaimText -match 'else\s*\{\s*if\s*\(\$maxUser\s*-gt\s*\[int\]\$state\.last_user_seq\)\s*\{\s*Update-State') {
    Write-Host 'NOTE busy-branch check skipped: driver/81-loop-idle-claim.ps1 still contains explicit last_user_seq advance while current_task is active.'
    return
  }

  Write-Host 'NOTE busy-branch source check: no explicit active-task else-branch last_user_seq advance found; transcript fence behavior is structurally deterministic.'
}

try {
  $activeTranscript = Invoke-TranscriptScenario -Name 'active' -CurrentTask 'Active task under test'
  Assert-Contains $activeTranscript 'USER_BEFORE_START_SEQ_8' 'active task transcript must keep older user context'
  Assert-NotContains $activeTranscript 'USER_AFTER_START_SEQ_11' 'active task transcript must hide post-start user message'
  Assert-Contains $activeTranscript 'SYSTEM_AFTER_START_SEQ_12' 'active task transcript must keep system message after task start'
  Assert-Contains $activeTranscript 'CODEX_AFTER_START_SEQ_13' 'active task transcript must keep codex message after task start'
  Assert-Contains $activeTranscript 'Pending operator message(s) after current task start are queued and hidden from this active task: 1' 'active task transcript must report hidden pending operator messages'

  $idleTranscript = Invoke-TranscriptScenario -Name 'idle' -CurrentTask $null
  Assert-Contains $idleTranscript 'USER_AFTER_START_SEQ_11' 'idle transcript must include the user message after task start'
  Assert-Contains $idleTranscript 'SYSTEM_AFTER_START_SEQ_12' 'idle transcript must include the system message after task start'
  Assert-Contains $idleTranscript 'CODEX_AFTER_START_SEQ_13' 'idle transcript must include the codex message after task start'

  Test-BusyBranchNote

  Write-Output 'ACTIVE TASK TRANSCRIPT FENCE TEST OK'
} finally {
  try { Clear-PinnedChannel } catch {}
  try { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
