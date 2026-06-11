#Requires -Version 5.1
# ASCII-only regression test for critic-debt salvage quarantine.
$ErrorActionPreference = 'Stop'

$bridgeRoot = Split-Path -Parent $PSScriptRoot
$doctorLib = Join-Path $bridgeRoot 'lib\doctor.ps1'
$backlogLib = Join-Path $bridgeRoot 'lib\backlog.ps1'
if (-not (Test-Path -LiteralPath $doctorLib)) { Write-Host 'FAIL: doctor.ps1 not found'; exit 1 }
if (-not (Test-Path -LiteralPath $backlogLib)) { Write-Host 'FAIL: backlog.ps1 not found'; exit 1 }

$script:TestRoot = Join-Path $env:TEMP ('bridge-salvage-critic-debt-' + [guid]::NewGuid().ToString('N'))
$script:Pass = 0
$script:Fail = 0

function Check {
  param([string]$Name, [bool]$Condition, $Detail = '')
  if ($Condition) {
    $script:Pass++
    Write-Host "PASS: $Name"
  } else {
    $script:Fail++
    Write-Host "FAIL: $Name $Detail"
  }
}

function Write-Utf8NoBom {
  param([string]$Path, [string]$Text)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Add-ConversationLine {
  param([string]$From, [string]$Kind, [string]$Text)
  $path = Join-Path $script:TestRoot 'channels\main\conversation.jsonl'
  $obj = [ordered]@{
    ts = (Get-Date).ToUniversalTime().ToString('o')
    from = $From
    kind = $Kind
    text = $Text
  }
  [System.IO.File]::AppendAllText($path, (($obj | ConvertTo-Json -Compress -Depth 5) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

try {
  New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
  & git -C $script:TestRoot init -q 2>$null
  & git -C $script:TestRoot config user.email 'test@example.invalid' 2>$null
  & git -C $script:TestRoot config user.name 'test' 2>$null
  & git -C $script:TestRoot config core.autocrlf false 2>$null
  Write-Utf8NoBom -Path (Join-Path $script:TestRoot 'good.ps1') -Text "function Good { return 1 }`n"
  New-Item -ItemType Directory -Path (Join-Path $script:TestRoot 'channels\main') -Force | Out-Null
  Write-Utf8NoBom -Path (Join-Path $script:TestRoot 'channels\main\backlog.jsonl') -Text ''
  Write-Utf8NoBom -Path (Join-Path $script:TestRoot 'channels\main\conversation.jsonl') -Text ''
  & git -C $script:TestRoot add -A 2>$null
  & git -C $script:TestRoot commit -q -m baseline 2>$null

  $script:Messages = New-Object System.Collections.ArrayList
  $script:Pushes = New-Object System.Collections.ArrayList
  function Get-BridgeRoot { return $script:TestRoot }
  function Get-EffectiveChannel { return 'main' }
  function Get-ChannelBacklogPath { return (Join-Path $script:TestRoot 'channels\main\backlog.jsonl') }
  function Add-Message { param($From, $Text, $Kind) [void]$script:Messages.Add([string]$Text) }
  function Write-DoctorLog { param($Message) }
  function Invoke-AutoPush { param($Root) }
  function Send-PushEvent { param($Kind, $Text) [void]$script:Pushes.Add([string]$Text) }

  . $backlogLib
  . $doctorLib

  Add-ConversationLine -From system -Kind event -Text 'TASK START ids=old-task'
  Add-ConversationLine -From system -Kind event -Text 'Independent critic found serious issue in old task'
  Add-ConversationLine -From system -Kind event -Text 'marked failed old task'
  Add-ConversationLine -From system -Kind event -Text 'TASK START ids=target-task'
  Add-ConversationLine -From system -Kind event -Text 'critic OK / none for target before retry'
  Add-ConversationLine -From system -Kind event -Text 'Independent critic found serious issue: target breaks persistence'
  Add-ConversationLine -From system -Kind event -Text 'task failed target-task after restart cap'
  Add-ConversationLine -From system -Kind event -Text 'TASK START ids=next-task'
  Add-ConversationLine -From system -Kind event -Text 'Independent critic found serious issue in next task'

  $vOld = Get-FailedTaskCriticVerdict -Root $script:TestRoot -TaskText 'old task' -BacklogId 'old-task'
  $vTarget = Get-FailedTaskCriticVerdict -Root $script:TestRoot -TaskText 'target task' -BacklogId 'target-task'
  Check 'strict window keeps target serious verdict' ([bool]$vTarget.serious -and ([string]$vTarget.findings -match 'target breaks persistence')) ($vTarget | ConvertTo-Json -Compress -Depth 5)
  Check 'strict window does not reuse previous task verdict' (([string]$vTarget.findings -notmatch 'old task') -and [bool]$vOld.serious) ($vTarget | ConvertTo-Json -Compress -Depth 5)
  Check 'strict window excludes next task verdict' ([string]$vTarget.findings -notmatch 'next task') ($vTarget | ConvertTo-Json -Compress -Depth 5)

  Write-Utf8NoBom -Path (Join-Path $script:TestRoot 'good.ps1') -Text "function Good { return 2 }`n"
  $headBefore = ([string](& git -C $script:TestRoot rev-parse --short HEAD 2>$null)).Trim()
  $r1 = Invoke-FailedTaskSalvage -TaskText 'target task' -BacklogId 'target-task'
  $headAfter = ([string](& git -C $script:TestRoot rev-parse --short HEAD 2>$null)).Trim()
  $dirtyCodeAfter = @(& git -C $script:TestRoot status --porcelain 2>$null | Where-Object {
    $l = [string]$_
    $nm = if ($l.Length -gt 3) { $l.Substring(3).Trim().Trim('"') } else { '' }
    ($l -match '\S') -and ($nm -notmatch '^(channels/.*|control/.*)$')
  })
  $stashList = @(& git -C $script:TestRoot stash list 2>$null)
  $items1 = @(Get-Backlog)
  $fu1 = @($items1 | Where-Object { [string]$_.followup_kind -eq 'critic-debt' -and [string]$_.followup_of -eq 'target-task' })
  Check 'serious critic routes parse-clean tail to stash' ([string]$r1.action -eq 'stashed' -and $stashList.Count -eq 1) ($r1 | ConvertTo-Json -Compress -Depth 5)
  Check 'serious critic does not create commit' ($headBefore -eq $headAfter) "before=$headBefore after=$headAfter"
  Check 'stash sha/ref recorded' (([string]$r1.stash_ref -eq 'stash@{0}') -and -not [string]::IsNullOrWhiteSpace([string]$r1.stash_sha)) ($r1 | ConvertTo-Json -Compress -Depth 5)
  Check 'code tree clean after critic stash' ($dirtyCodeAfter.Count -eq 0) ($dirtyCodeAfter -join '; ')
  Check 'critic-debt follow-up created open' ($fu1.Count -eq 1 -and [string]$fu1[0].status -eq 'open') ($fu1 | ConvertTo-Json -Compress -Depth 6)
  Check 'follow-up stores findings and stash ref' (([string]$fu1[0].critic_findings -match 'target breaks persistence') -and [string]$fu1[0].stash_ref -eq 'stash@{0}') ($fu1[0] | ConvertTo-Json -Compress -Depth 6)

  & git -C $script:TestRoot stash pop -q 2>$null | Out-Null
  $r2 = Invoke-FailedTaskSalvage -TaskText 'target task' -BacklogId 'target-task'
  $fu2 = @((Get-Backlog) | Where-Object { [string]$_.followup_kind -eq 'critic-debt' -and [string]$_.followup_of -eq 'target-task' })
  Check 'critic-debt follow-up dedupes by kind and task' ($fu2.Count -eq 1 -and [string]$r2.critic_debt_followup_id -eq [string]$fu1[0].id) ($fu2 | ConvertTo-Json -Compress -Depth 6)

  $prodBacklog = Join-Path $bridgeRoot 'channels\main\backlog.jsonl'
  Check 'test uses temp backlog path' ((Get-BacklogPath) -ne $prodBacklog) (Get-BacklogPath)
} catch {
  $script:Fail++
  Write-Host ('FAIL: unexpected error: ' + $_.Exception.Message)
} finally {
  try { Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}

Write-Host ("RESULT: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
