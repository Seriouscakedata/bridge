$ErrorActionPreference = 'Stop'

$bridgeRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $bridgeRoot 'lib\startup-maintenance.ps1')

function Assert-True {
  param(
    [Parameter(Mandatory=$true)][bool]$Condition,
    [Parameter(Mandatory=$true)][string]$Message
  )
  if (-not $Condition) { throw "supervisor startup backlog compaction test failed: $Message" }
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-supervisor-compact-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'tools') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'channels\main') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'channels\side') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'compact-backlog.ps1') -Destination (Join-Path $tmpRoot 'tools\compact-backlog.ps1') -Force

try {
  $mainBacklog = Join-Path $tmpRoot 'channels\main\backlog.jsonl'
  $sideBacklog = Join-Path $tmpRoot 'channels\side\backlog.jsonl'
  $padding = 'x' * 11000000

  [System.IO.File]::WriteAllLines(
    $mainBacklog,
    @(
      ('{"id":"task-a","value":"old","padding":"' + $padding + '"}')
      '{"id":"task-b","value":"keep"}'
      '{"id":"task-a","value":"new"}'
    ),
    [System.Text.UTF8Encoding]::new($false)
  )
  [System.IO.File]::WriteAllLines(
    $sideBacklog,
    @('{"id":"side-a","value":"small-old"}', '{"id":"side-a","value":"small-new"}'),
    [System.Text.UTF8Encoding]::new($false)
  )

  $messages = [System.Collections.Generic.List[string]]::new()
  Invoke-StartupBacklogCompaction -BridgeRoot $tmpRoot -LogBlock { param($m) $messages.Add([string]$m) }

  $mainLines = @([System.IO.File]::ReadAllLines($mainBacklog, [System.Text.Encoding]::UTF8))
  $mainText = $mainLines -join "`n"
  $sideLines = @([System.IO.File]::ReadAllLines($sideBacklog, [System.Text.Encoding]::UTF8))

  Assert-True ($mainLines.Count -eq 2) 'oversized backlog should be folded by duplicate id'
  Assert-True ($mainText.Contains('"id":"task-a","value":"new"')) 'last line should win for duplicated id'
  Assert-True (-not $mainText.Contains('"value":"old"')) 'old duplicate line should be removed'
  Assert-True (Test-Path -LiteralPath $mainBacklog) 'startup compaction should keep backlog.jsonl at the original path'
  Assert-True (-not (Test-Path -LiteralPath ($mainBacklog + '.compact.tmp'))) 'startup compaction should not leave atomic replace temp files behind'
  Assert-True ($sideLines.Count -eq 2) 'small backlog should stay below threshold and remain unchanged'
  Assert-True (($messages -join "`n") -match 'startup backlog compaction: compact-backlog: backlog\.jsonl') 'startup compaction should be logged'
  Assert-True (($messages -join "`n") -match 'threshold -- skip') 'startup compaction should scan every channel backlog and log threshold skips'

  $missingScriptRoot = Join-Path $tmpRoot 'missing-script-root'
  New-Item -ItemType Directory -Path (Join-Path $missingScriptRoot 'channels\main') -Force | Out-Null
  $missingScriptMessages = [System.Collections.Generic.List[string]]::new()
  Invoke-StartupBacklogCompaction -BridgeRoot $missingScriptRoot -LogBlock { param($m) $missingScriptMessages.Add([string]$m) }
  Assert-True (($missingScriptMessages -join "`n") -match 'startup backlog compaction skipped: missing .*tools\\compact-backlog\.ps1') 'startup compaction should log missing helper script'

  $missingChannelsRoot = Join-Path $tmpRoot 'missing-channels-root'
  New-Item -ItemType Directory -Path (Join-Path $missingChannelsRoot 'tools') -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'compact-backlog.ps1') -Destination (Join-Path $missingChannelsRoot 'tools\compact-backlog.ps1') -Force
  $missingChannelsMessages = [System.Collections.Generic.List[string]]::new()
  Invoke-StartupBacklogCompaction -BridgeRoot $missingChannelsRoot -LogBlock { param($m) $missingChannelsMessages.Add([string]$m) }
  Assert-True (($missingChannelsMessages -join "`n") -match 'startup backlog compaction skipped: missing .*channels') 'startup compaction should log missing channels root'

  Write-Output 'PASS supervisor startup backlog compaction test'
} finally {
  if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
