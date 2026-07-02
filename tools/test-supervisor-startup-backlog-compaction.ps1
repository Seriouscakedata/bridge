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

function Count-BacklogId {
  param(
    [Parameter(Mandatory=$true)][string[]]$Lines,
    [Parameter(Mandatory=$true)][string]$Id
  )
  return @($Lines | Where-Object { $_ -match ('"id"\s*:\s*"' + [regex]::Escape($Id) + '"') }).Count
}

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("bridge-supervisor-compact-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'tools') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'channels\main') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'channels\other') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $tmpRoot 'channels\side') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'compact-backlog.ps1') -Destination (Join-Path $tmpRoot 'tools\compact-backlog.ps1') -Force

try {
  $supervisorPath = Join-Path $bridgeRoot 'supervisor.ps1'
  $supervisorText = [System.IO.File]::ReadAllText($supervisorPath, [System.Text.Encoding]::UTF8)
  Assert-True ($supervisorText -match "lib\\startup-maintenance\.ps1") 'supervisor should dot-source startup maintenance helpers'
  Assert-True ($supervisorText -match 'Invoke-StartupBacklogCompaction\s+-BridgeRoot\s+\$root') 'supervisor should run backlog compaction on startup'

  $mainBacklog = Join-Path $tmpRoot 'channels\main\backlog.jsonl'
  $otherBacklog = Join-Path $tmpRoot 'channels\other\backlog.jsonl'
  $sideBacklog = Join-Path $tmpRoot 'channels\side\backlog.jsonl'
  $padding = 'x' * 11000000

  [System.IO.File]::WriteAllLines(
    $mainBacklog,
    @(
      ('{"id":"task-a","value":"old","padding":"' + $padding + '"}')
      '{"id":"task-b","value":"keep"}'
      'not-json-but-operator-visible'
      '{"id":"task-a","value":"new"}'
    ),
    [System.Text.UTF8Encoding]::new($false)
  )
  [System.IO.File]::WriteAllLines(
    $otherBacklog,
    @(
      ('{"id":"other-a","value":"old","padding":"' + $padding + '"}')
      '{"id":"other-a","value":"new"}'
      '{"id":"other-b","value":"keep"}'
    ),
    [System.Text.UTF8Encoding]::new($false)
  )
  [System.IO.File]::WriteAllLines(
    $sideBacklog,
    @('{"id":"side-a","value":"small-old"}', '{"id":"side-a","value":"small-new"}'),
    [System.Text.UTF8Encoding]::new($false)
  )
  $mainOriginalLength = (Get-Item -LiteralPath $mainBacklog).Length

  $messages = [System.Collections.Generic.List[string]]::new()
  Invoke-StartupBacklogCompaction -BridgeRoot $tmpRoot -LogBlock { param($m) $messages.Add([string]$m) }

  $mainLines = @([System.IO.File]::ReadAllLines($mainBacklog, [System.Text.Encoding]::UTF8))
  $mainText = $mainLines -join "`n"
  $mainCompactedLength = (Get-Item -LiteralPath $mainBacklog).Length
  $otherLines = @([System.IO.File]::ReadAllLines($otherBacklog, [System.Text.Encoding]::UTF8))
  $otherText = $otherLines -join "`n"
  $sideLines = @([System.IO.File]::ReadAllLines($sideBacklog, [System.Text.Encoding]::UTF8))

  Assert-True ($mainLines.Count -eq 3) 'oversized backlog should be folded by duplicate id while preserving no-id lines'
  Assert-True ((Count-BacklogId -Lines $mainLines -Id 'task-a') -eq 1) 'oversized backlog should keep exactly one last-line-wins entry for task-a'
  Assert-True ($mainCompactedLength -lt $mainOriginalLength) 'startup compaction should rewrite oversized duplicate backlog, not only dry-run'
  Assert-True ($mainText.Contains('"id":"task-a","value":"new"')) 'last line should win for duplicated id'
  Assert-True (-not $mainText.Contains('"value":"old"')) 'old duplicate line should be removed'
  Assert-True ($mainText.Contains('not-json-but-operator-visible')) 'no-id backlog lines should be preserved during compaction'
  Assert-True (Test-Path -LiteralPath $mainBacklog) 'startup compaction should keep backlog.jsonl at the original path'
  Assert-True (-not (Test-Path -LiteralPath ($mainBacklog + '.compact.tmp'))) 'startup compaction should not leave atomic replace temp files behind'
  Assert-True ($otherLines.Count -eq 2) 'startup compaction should fold every oversized channel backlog, not just the first one'
  Assert-True ((Count-BacklogId -Lines $otherLines -Id 'other-a') -eq 1) 'later oversized channel backlog should keep exactly one last-line-wins entry per duplicate id'
  Assert-True ($otherText.Contains('"id":"other-a","value":"new"')) 'last line should win in later oversized channel backlogs'
  Assert-True (-not $otherText.Contains('"value":"old"')) 'older duplicate line should be removed in later oversized channel backlogs'
  Assert-True ($sideLines.Count -eq 2) 'small backlog should stay below threshold and remain unchanged'
  Assert-True (($messages -join "`n") -match 'startup backlog compaction: compact-backlog: backlog\.jsonl') 'startup compaction should be logged'
  Assert-True (($messages -join "`n") -match '10MB threshold') 'startup compaction should use the default 10MB threshold'
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
