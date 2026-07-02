#Requires -Version 5.1
# test-coordinator-prompt-profile.ps1 -- lean coordinator prompt profile tests.
# Covers: (a) coordinator task -> lean shared block + compact suffix (no general
# channel rules, no large-task decompose block), (b) non-coordinator task keeps
# the legacy blocks, (c) Format-Transcript truncates oversized autotask echoes
# and caps the rolling summary on coordinator turns, (d) detector pos/neg cases.
# ASCII-only file: Cyrillic assertion markers are built from codepoints.

[CmdletBinding()]
param()

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:PassCount = 0
$script:FailCount = 0

function Write-TestResult {
  param(
    [string]$SuccessMessage,
    [bool]$Condition,
    [string]$FailureDetail = ''
  )

  if ($Condition) {
    $script:PassCount++
    Write-Host ("PASS: {0}" -f $SuccessMessage)
    return
  }

  $script:FailCount++
  if ([string]::IsNullOrWhiteSpace($FailureDetail)) {
    Write-Host ("FAIL: {0}" -f $SuccessMessage)
  } else {
    Write-Host ("FAIL: {0} - {1}" -f $SuccessMessage, $FailureDetail)
  }
}

function Assert-Contains {
  param([string]$Text, [string]$Expected, [string]$Message)
  $ok = (-not [string]::IsNullOrEmpty($Text)) -and ($Text.IndexOf($Expected, [System.StringComparison]::Ordinal) -ge 0)
  Write-TestResult -SuccessMessage $Message -Condition $ok -FailureDetail 'expected substring missing'
}

function Assert-NotContains {
  param([string]$Text, [string]$Unexpected, [string]$Message)
  $ok = [string]::IsNullOrEmpty($Text) -or ($Text.IndexOf($Unexpected, [System.StringComparison]::Ordinal) -lt 0)
  Write-TestResult -SuccessMessage $Message -Condition $ok -FailureDetail 'unexpected substring present'
}

function ConvertTo-StringFromCodepoints {
  param([int[]]$Codes)
  $chars = @()
  foreach ($c in $Codes) { $chars += [char]$c }
  return (-join $chars)
}

# Cyrillic markers (this file stays ASCII-only):
# 'LAPA' (GUI hands skill)
$ruLapa = ConvertTo-StringFromCodepoints @(0x041B, 0x0410, 0x041F, 0x0410)
# 'KRUPNAYA ZADACHA' (large-task decompose block header)
$ruKrupnaya = ConvertTo-StringFromCodepoints @(0x041A, 0x0420, 0x0423, 0x041F, 0x041D, 0x0410, 0x042F, 0x0020, 0x0417, 0x0410, 0x0414, 0x0410, 0x0427, 0x0410)
# 'ROLI:' (roles line of the legacy rules block)
$ruRoli = ConvertTo-StringFromCodepoints @(0x0420, 0x041E, 0x041B, 0x0418, 0x003A)
# 'Beru zadachu iz bekloga' (autotask claim echo marker)
$ruBeru = ConvertTo-StringFromCodepoints @(0x0411, 0x0435, 0x0440, 0x0443, 0x0020, 0x0437, 0x0430, 0x0434, 0x0430, 0x0447, 0x0443, 0x0020, 0x0438, 0x0437, 0x0020, 0x0431, 0x044D, 0x043A, 0x043B, 0x043E, 0x0433, 0x0430)
# 'TEKUSHCHAYA ZADACHA' (current-task section name)
$ruTekZadacha = ConvertTo-StringFromCodepoints @(0x0422, 0x0415, 0x041A, 0x0423, 0x0429, 0x0410, 0x042F, 0x0020, 0x0417, 0x0410, 0x0414, 0x0410, 0x0427, 0x0410)

# --- source lib\prompt-builder.ps1 standalone ---
$script:bridgeRoot = $script:RepoRoot
$script:Channel = 'main'
$script:workRoot = $script:RepoRoot
$script:discussMinTurns = 3
$script:discussMaxTurns = 8
$script:studyMaxTurns = 5

. (Join-Path $script:RepoRoot 'lib\prompt-builder.ps1')
Write-TestResult -SuccessMessage 'dot-sourced lib\prompt-builder.ps1 standalone' -Condition $true

# --- fixtures ---
$coordTask = '[project-autopilot selfie-styler] [[NORMAL]]' + "`n" +
  "Project Autopilot coordinator for channel 'selfie-styler'." + "`n" +
  'COORD-TASK-UNIQUE-SENTINEL plan the next chapter into atoms. ' +
  ('Schema constraints and acceptance details fill out the body of this task text. ' * 30)

$plainTask = 'Fix the header color in web/index.html'
$largePlainTask = 'Refactor the settings storage layer end to end. ' * 40

$ctx = [pscustomobject]@{
  ActiveProjectRoot    = 'C:\proj\demo'
  ActiveProjectBlock   = 'FOCUS-BLOCK-SENTINEL'
  SelfModelPromptBlock = ''
  ChannelIsMain        = $false
  BridgeRoot           = $script:RepoRoot
  WorkRoot             = $script:RepoRoot
  BridgeScopeRules     = 'BRIDGE-SCOPE-SENTINEL'
  RestartReminder      = 'RESTART-SENTINEL'
  SafetyGateRule       = 'SAFETY-SENTINEL'
  AutoToolsLine        = ''
}
$progress = [pscustomobject]@{ PlanPromptBlock = '' }
$promptState = [pscustomobject]@{
  discuss_snapshot  = ''
  study_subtype     = ''
  study_phase       = ''
  study_snapshot    = ''
  chunk_progress    = ''
  chunk_base_commit = ''
}

# --- (d) detector positive/negative ---
Write-TestResult -SuccessMessage 'detector: coordinator task -> true' -Condition (Test-PromptBuilderCoordinatorTask -Task $coordTask)
Write-TestResult -SuccessMessage 'detector: tag without coordinator sentence -> false' -Condition (-not (Test-PromptBuilderCoordinatorTask -Task '[project-autopilot demo] just a tagged note'))
Write-TestResult -SuccessMessage 'detector: coordinator sentence without tag -> false' -Condition (-not (Test-PromptBuilderCoordinatorTask -Task "Project Autopilot coordinator for channel 'demo'. no tag here"))
Write-TestResult -SuccessMessage 'detector: plain task -> false' -Condition (-not (Test-PromptBuilderCoordinatorTask -Task $plainTask))
Write-TestResult -SuccessMessage 'detector: empty -> false' -Condition (-not (Test-PromptBuilderCoordinatorTask -Task ''))
Write-TestResult -SuccessMessage 'detector: null -> false' -Condition (-not (Test-PromptBuilderCoordinatorTask -Task $null))

# --- (a) coordinator task -> lean shared block + compact suffix ---
$sharedCoord = New-SharedPromptBlock -Task $coordTask -Transcript 'TRANSCRIPT-SENTINEL' -AutoScopeLine '' -Context $ctx -ProgressBlocks $progress
$suffixCoord = New-ClaudePromptSuffix -Mode 'normal' -PromptState $promptState -DiscussTurn 0 -StudyTurn 0 `
  -TaskText $coordTask -TaskTags @() -CurrentTaskId 'tid-coord' -Channel 'selfie-styler' -Scope 'project' `
  -AcceptanceCount 0 -SubsystemCount 0 -EstimatedTurns 0 -Files @() `
  -ClaudeToolHint 'TOOL-HINT-SENTINEL' -ClaudeActionBlock 'ACTION-BLOCK-SENTINEL'

Assert-NotContains $sharedCoord $ruLapa 'coordinator shared block has no LAPA GUI skill rules'
Assert-NotContains $sharedCoord '[[RUNJOB' 'coordinator shared block has no RUNJOB rules'
Assert-NotContains $sharedCoord '[[NEED-TOOL' 'coordinator shared block has no NEED-TOOL rules'
Assert-NotContains $sharedCoord '[[PARALLEL' 'coordinator shared block has no PARALLEL dispatch forms or worked examples'
Assert-NotContains $sharedCoord 'web-smoke.ps1' 'coordinator shared block has no web-smoke runner rule'
Assert-Contains $sharedCoord 'PROJECT_BACKLOG' 'coordinator shared block carries PROJECT_BACKLOG guidance'
Assert-Contains $sharedCoord 'STATUS: DONE' 'coordinator shared block names the STATUS: DONE deliverable'
Assert-Contains $sharedCoord $ruTekZadacha 'coordinator shared block keeps the current-task section header'
Assert-Contains $sharedCoord 'FOCUS-BLOCK-SENTINEL' 'coordinator shared block keeps the focus/contract block'
Assert-Contains $sharedCoord 'TRANSCRIPT-SENTINEL' 'coordinator shared block keeps the transcript (project context pack rides it)'
Assert-Contains $sharedCoord '[[REMEMBER' 'coordinator etiquette allows REMEMBER memory marker'
Assert-Contains $sharedCoord '[[IDEA' 'coordinator etiquette allows IDEA marker'
Assert-Contains $sharedCoord '[[PROJECT_FACT' 'coordinator etiquette allows typed project memory markers'
Assert-Contains $sharedCoord 'Reply in Russian' 'coordinator etiquette pins the reply language'

$taskEchoCount = ([regex]::Matches($sharedCoord, 'COORD-TASK-UNIQUE-SENTINEL')).Count
Write-TestResult -SuccessMessage 'coordinator shared block contains the task text exactly once' -Condition ($taskEchoCount -eq 1) -FailureDetail ("occurrences: {0}" -f $taskEchoCount)

Assert-NotContains $suffixCoord $ruKrupnaya 'coordinator suffix has no KRUPNAYA ZADACHA decompose block'
Assert-NotContains $suffixCoord '[[DECOMPOSED' 'coordinator suffix has no DECOMPOSED marker instruction'
Assert-NotContains $suffixCoord 'CODER-DELEGATION' 'coordinator suffix has no coder-delegation machinery'
Assert-NotContains $suffixCoord '[[VERIFIED' 'coordinator suffix has no VERIFIED verification machinery'
Assert-Contains $suffixCoord 'STATUS: DONE' 'coordinator suffix defines STATUS: DONE'
Assert-Contains $suffixCoord 'STATUS: BLOCKED' 'coordinator suffix defines STATUS: BLOCKED'
Assert-Contains $suffixCoord 'PROJECT_BACKLOG' 'coordinator suffix demands the PROJECT_BACKLOG marker'
Assert-Contains $suffixCoord 'in THIS response' 'coordinator suffix demands the marker in this response'
Assert-Contains $suffixCoord 'Do not ask questions' 'coordinator suffix forbids questions'
Assert-Contains $suffixCoord 'Do not delegate' 'coordinator suffix forbids delegation'
Write-TestResult -SuccessMessage 'coordinator suffix is compact (<= 2000 chars)' -Condition ($suffixCoord.Length -le 2000) -FailureDetail ("length: {0}" -f $suffixCoord.Length)

# --- (b) non-coordinator task keeps the legacy blocks (presence spot-checks) ---
$sharedPlain = New-SharedPromptBlock -Task $plainTask -Transcript 'TRANSCRIPT-SENTINEL' -AutoScopeLine '' -Context $ctx -ProgressBlocks $progress
$suffixPlain = New-ClaudePromptSuffix -Mode 'normal' -PromptState $promptState -DiscussTurn 0 -StudyTurn 0 `
  -TaskText $plainTask -TaskTags @() -CurrentTaskId 'tid-plain' -Channel 'main' -Scope '' `
  -AcceptanceCount 0 -SubsystemCount 0 -EstimatedTurns 0 -Files @() `
  -ClaudeToolHint 'TOOL-HINT-SENTINEL' -ClaudeActionBlock 'ACTION-BLOCK-SENTINEL'

Assert-Contains $sharedPlain $ruLapa 'plain shared block still carries LAPA rules'
Assert-Contains $sharedPlain '[[RUNJOB' 'plain shared block still carries RUNJOB rules'
Assert-Contains $sharedPlain '[[NEED-TOOL' 'plain shared block still carries NEED-TOOL rules'
Assert-Contains $sharedPlain '[[PARALLEL' 'plain shared block still carries PARALLEL rules'
Assert-Contains $sharedPlain $ruRoli 'plain shared block still carries the roles line'
Assert-Contains $sharedPlain 'BRIDGE-SCOPE-SENTINEL' 'plain shared block still carries bridge scope rules'
Assert-Contains $suffixPlain 'CODER-DELEGATION' 'plain suffix still carries coder-delegation rule'
Assert-Contains $suffixPlain 'STATUS: CONTINUE' 'plain suffix still carries STATUS: CONTINUE marker'
Assert-NotContains $suffixPlain $ruKrupnaya 'plain SHORT task suffix has no decompose block (guard sanity)'

$suffixLargePlain = New-ClaudePromptSuffix -Mode 'normal' -PromptState $promptState -DiscussTurn 0 -StudyTurn 0 `
  -TaskText $largePlainTask -TaskTags @() -CurrentTaskId 'tid-large' -Channel 'selfie-styler' -Scope 'project' `
  -AcceptanceCount 0 -SubsystemCount 0 -EstimatedTurns 0 -Files @() `
  -ClaudeToolHint 'TOOL-HINT-SENTINEL' -ClaudeActionBlock 'ACTION-BLOCK-SENTINEL'
Assert-Contains $suffixLargePlain $ruKrupnaya 'large NON-coordinator task still gets the decompose block (suppression is coordinator-only)'

# --- size delta measurement (legacy vs lean) for the same coordinator task ---
$realDetector = ${function:Test-PromptBuilderCoordinatorTask}
Set-Item function:Test-PromptBuilderCoordinatorTask { param([string]$Task) return $false }
$sharedLegacy = New-SharedPromptBlock -Task $coordTask -Transcript 'TRANSCRIPT-SENTINEL' -AutoScopeLine '' -Context $ctx -ProgressBlocks $progress
$suffixLegacy = New-ClaudePromptSuffix -Mode 'normal' -PromptState $promptState -DiscussTurn 0 -StudyTurn 0 `
  -TaskText $coordTask -TaskTags @() -CurrentTaskId 'tid-coord' -Channel 'selfie-styler' -Scope 'project' `
  -AcceptanceCount 0 -SubsystemCount 0 -EstimatedTurns 0 -Files @() `
  -ClaudeToolHint 'TOOL-HINT-SENTINEL' -ClaudeActionBlock 'ACTION-BLOCK-SENTINEL'
Set-Item function:Test-PromptBuilderCoordinatorTask $realDetector
Write-TestResult -SuccessMessage 'detector restored after legacy measurement' -Condition (Test-PromptBuilderCoordinatorTask -Task $coordTask)

$legacyLen = $sharedLegacy.Length + $suffixLegacy.Length
$leanLen = $sharedCoord.Length + $suffixCoord.Length
Write-Host ("MEASURE: coordinator shared+suffix legacy={0} chars, lean={1} chars, saved={2} chars" -f $legacyLen, $leanLen, ($legacyLen - $leanLen))
Write-TestResult -SuccessMessage 'lean coordinator profile saves at least 15000 chars vs legacy' -Condition (($legacyLen - $leanLen) -ge 15000) -FailureDetail ("saved only {0}" -f ($legacyLen - $leanLen))

# --- (c) Format-Transcript: echo truncation + coordinator summary cap ---
$script:FakeState = [pscustomobject]@{ summarized_seq = 0; current_task = ''; task_start_seq = 0; task_intent = $null }
$script:FakeSummary = ''
$script:FakeMessages = @()

function Read-State { return $script:FakeState }
function Get-Messages { param([int]$Since = 0) return $script:FakeMessages }
function Get-MessageAttachmentPaths { param($Message) return @() }
function Read-Summary { return $script:FakeSummary }
function Get-DecisionsRecall { param([string]$TaskText) return '' }
function Get-EvidenceRecall { param([string]$TaskText) return '' }

. (Join-Path $script:RepoRoot 'driver\20-context.ps1')
Write-TestResult -SuccessMessage 'dot-sourced driver\20-context.ps1 with stubs' -Condition $true

$bigEcho = 'robot ' + $ruBeru + ' (autonomous): ' + ('X' * 5000)
$autopilotEcho = 'claimed [project-autopilot demo] work body ' + ('Z' * 3000)
$smallEchoNote = 'note ' + $ruBeru + ' small'
$script:FakeMessages = @(
  [pscustomobject]@{ seq = 1; from = 'system'; text = $bigEcho },
  [pscustomobject]@{ seq = 2; from = 'user';   text = 'SHORT-USER-MESSAGE-SENTINEL' },
  [pscustomobject]@{ seq = 3; from = 'system'; text = $autopilotEcho },
  [pscustomobject]@{ seq = 4; from = 'codex';  text = ('Y' * 2500) },
  [pscustomobject]@{ seq = 5; from = 'system'; text = $smallEchoNote }
)
$transcript = Format-Transcript -TaskText 'plain short task'

Assert-Contains $transcript 'echo truncated]' 'transcript: oversized claim echo carries the truncation marker'
Assert-Contains $transcript 'full task text is in' 'transcript: truncation marker points at the current-task section'
Assert-Contains $transcript $ruTekZadacha 'transcript: truncation marker names the current-task section'
Assert-Contains $transcript ('X' * 250) 'transcript: first 300 chars of the claim echo are kept'
Assert-NotContains $transcript ('X' * 300) 'transcript: claim echo body beyond 300 chars is dropped'
Assert-Contains $transcript ('Z' * 250) 'transcript: first 300 chars of the autopilot echo are kept'
Assert-NotContains $transcript ('Z' * 300) 'transcript: autopilot echo body beyond 300 chars is dropped'
Assert-Contains $transcript ('Y' * 2500) 'transcript: long message WITHOUT echo markers passes through untouched'
Assert-Contains $transcript 'SHORT-USER-MESSAGE-SENTINEL' 'transcript: short user message passes through untouched'
Assert-Contains $transcript $smallEchoNote 'transcript: short message WITH echo marker passes through untouched'

# summary cap: coordinator turn trims a >1000 char rolling summary
$script:FakeSummary = ('S' * 3000)
$script:FakeMessages = @([pscustomobject]@{ seq = 1; from = 'user'; text = 'hello there' })
$coordTranscript = Format-Transcript -TaskText $coordTask
Assert-Contains $coordTranscript '[...trimmed for coordinator turn...]' 'coordinator transcript: summary carries the trim marker'
Assert-NotContains $coordTranscript ('S' * 1500) 'coordinator transcript: summary capped to 1000 chars'
Assert-Contains $coordTranscript ('S' * 1000) 'coordinator transcript: first 1000 summary chars kept'

$plainTranscript = Format-Transcript -TaskText 'plain short task'
Assert-Contains $plainTranscript ('S' * 3000) 'plain transcript: full summary kept'
Assert-NotContains $plainTranscript 'trimmed for coordinator turn' 'plain transcript: no coordinator trim marker'

Write-Host ("RESULT: {0} PASS, {1} FAIL" -f $script:PassCount, $script:FailCount)

if ($script:FailCount -eq 0) {
  exit 0
}

exit 1
