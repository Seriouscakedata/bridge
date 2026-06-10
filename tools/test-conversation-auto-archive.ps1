#Requires -Version 5.1
# test-conversation-auto-archive.ps1 -- size-based live feed archive on maintenance tick.

$ErrorActionPreference = 'Stop'

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$bridgeRoot = $root
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'driver\10-maintenance.ps1')

$script:pass = 0
$script:fail = 0

function Check-ConversationAutoArchive {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    $Actual = $null
  )
  if ($Condition) {
    $script:pass++
    Write-Host ("PASS " + $Name) -ForegroundColor Green
  } else {
    $script:fail++
    $suffix = ''
    if ($null -ne $Actual) {
      try { $suffix = ' actual=' + (($Actual | Format-List * | Out-String).Trim()) } catch { $suffix = ' actual=' + [string]$Actual }
      if ($suffix.Length -gt 600) { $suffix = $suffix.Substring(0, 600) + '...<truncated>' }
    }
    Write-Host ("FAIL " + $Name + $suffix) -ForegroundColor Red
  }
}

function New-TestMessageLine {
  param([int]$Seq)
  return ([ordered]@{
    seq  = $Seq
    ts   = (Get-Date).ToUniversalTime().ToString('o')
    from = 'system'
    kind = 'event'
    text = "line $Seq"
  } | ConvertTo-Json -Compress)
}

$slug = 'test-auto-archive-' + [guid]::NewGuid().ToString('N')
$channelDir = Join-Path $root ("channels\" + $slug)
$prevChannel = $env:BRIDGE_CHANNEL
$hadPrevChannel = Test-Path Env:BRIDGE_CHANNEL

try {
  New-Item -ItemType Directory -Path $channelDir -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $channelDir 'channel.json'), (@{ slug=$slug; name=$slug; project_root=$root } | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
  [System.IO.File]::WriteAllText((Join-Path $channelDir 'state.json'), (@{ lastSeq=0 } | ConvertTo-Json -Compress), (New-Object System.Text.UTF8Encoding($false)))
  $env:BRIDGE_CHANNEL = $slug

  $convPath = Get-ConversationPath
  $archivePath = Get-ConversationArchivePath
  $threshold = 1500
  try {
    $cfg = Get-BridgeConfig
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'conversationAutoArchiveLines') -and $null -ne $cfg.conversationAutoArchiveLines) {
      $threshold = [int]$cfg.conversationAutoArchiveLines
    }
  } catch {}
  $overCount = $threshold + 1
  $underCount = $threshold - 1
  $overLines = @(1..$overCount | ForEach-Object { New-TestMessageLine -Seq $_ })
  [System.IO.File]::WriteAllText($convPath, (($overLines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

  $over = Invoke-ConversationAutoArchiveIfDue -Keep 5 -ThrottleHours 6
  $liveAfterOver = @([System.IO.File]::ReadAllLines($convPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $archAfterOver = @([System.IO.File]::ReadAllLines($archivePath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  $expectedArchived = $overCount - 5

  Check-ConversationAutoArchive 'over-threshold tick archives existing feed' ([string]$over.action -eq 'archived' -and [int]$over.archived -eq $expectedArchived -and [int]$over.kept -eq 5) $over
  Check-ConversationAutoArchive 'over-threshold tick keeps hot tail plus system event' ($liveAfterOver.Count -eq 6) @{ live = $liveAfterOver.Count; lines = $liveAfterOver }
  Check-ConversationAutoArchive 'archive sidecar receives old lines' ($archAfterOver.Count -eq $expectedArchived) @{ archive = $archAfterOver.Count; expected = $expectedArchived }

  $throttled = Invoke-ConversationAutoArchiveIfDue -Keep 5 -ThrottleHours 6
  $liveAfterThrottle = @([System.IO.File]::ReadAllLines($convPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  Check-ConversationAutoArchive 'second tick is throttled' ([string]$throttled.action -eq 'throttled' -and $liveAfterThrottle.Count -eq $liveAfterOver.Count) $throttled

  Remove-Item -LiteralPath (Join-Path $channelDir 'conversation-auto-archive.last') -Force
  $underLines = @(1..$underCount | ForEach-Object { New-TestMessageLine -Seq $_ })
  [System.IO.File]::WriteAllText($convPath, (($underLines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }

  $under = Invoke-ConversationAutoArchiveIfDue -Keep 5 -ThrottleHours 6
  $liveAfterUnder = @([System.IO.File]::ReadAllLines($convPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  Check-ConversationAutoArchive 'under-threshold tick does nothing' ([string]$under.action -eq 'under_threshold' -and $liveAfterUnder.Count -eq $underCount -and -not (Test-Path -LiteralPath $archivePath)) $under
} finally {
  if ($hadPrevChannel) { $env:BRIDGE_CHANNEL = $prevChannel } else { Remove-Item Env:BRIDGE_CHANNEL -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath $channelDir) { Remove-Item -LiteralPath $channelDir -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:fail -gt 0) {
  Write-Host ("FAILURES: " + $script:fail) -ForegroundColor Red
  exit 1
}

Write-Host ("conversation auto archive tests passed: " + $script:pass)
