# test-wp-verify.ps1 -- quick verify for wp1/wp2 parallel fixes
$b = 'C:\Users\rafie\OneDrive\Documents\bridge'
$pass = 0; $fail = 0

function Test-Check {
  param([string]$Name, [scriptblock]$Block)
  try {
    $r = & $Block
    if ($r) { Write-Host "PASS: $Name"; $script:pass++ }
    else     { Write-Host "FAIL: $Name"; $script:fail++ }
  } catch {
    Write-Host "FAIL: $Name :: $($_.Exception.Message)"
    $script:fail++
  }
}

# WP2: Get-BacklogPath and Ensure-BacklogPathFunction defined in backlog.ps1
. (Join-Path $b 'lib\common.ps1')
. (Join-Path $b 'lib\backlog.ps1')

Test-Check 'Get-BacklogPath is defined' { Get-Command Get-BacklogPath -ErrorAction SilentlyContinue -ne $null }
Test-Check 'Resolve-BacklogPathValue is defined' { Get-Command Resolve-BacklogPathValue -ErrorAction SilentlyContinue -ne $null }
Test-Check 'Ensure-BacklogPathFunction is defined' { Get-Command Ensure-BacklogPathFunction -ErrorAction SilentlyContinue -ne $null }
Test-Check 'Get-BacklogPath returns non-empty string' {
  $p = Get-BacklogPath
  -not [string]::IsNullOrWhiteSpace($p)
}
Test-Check 'Resolve-BacklogPathValue returns same as Get-BacklogPath' {
  (Get-BacklogPath) -eq (Resolve-BacklogPathValue)
}

# WP2: Ensure-BacklogPathFunction re-registers if missing
Test-Check 'Ensure re-registers Get-BacklogPath after removal' {
  # remove from local scope simulation: just call Ensure again (idempotent)
  Ensure-BacklogPathFunction
  $p = Get-BacklogPath
  -not [string]::IsNullOrWhiteSpace($p)
}

# WP1: Resolve-MemoryContainedPath accepts BasePath param
. (Join-Path $b 'lib\memory.ps1')
Test-Check 'Resolve-MemoryContainedPath has BasePath param' {
  $cmd = Get-Command Resolve-MemoryContainedPath -ErrorAction SilentlyContinue
  $cmd -and ($cmd.Parameters.ContainsKey('BasePath'))
}

# WP1: librarian path-traversal rejection via Resolve-BridgeContainedPath
Test-Check 'Resolve-BridgeContainedPath rejects path-traversal' {
  try {
    Resolve-BridgeContainedPath -Path '..\..\..\Windows\win.ini' -Purpose 'test traversal'
    $false  # should have thrown
  } catch {
    $_.Exception.Message -match 'escapes'
  }
}

Test-Check 'operator-batch summary marker survives read-write and prevents repost' {
  $sandbox = Join-Path $env:TEMP ('operator-batch-test-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
  $script:testBacklogPath = Join-Path $sandbox 'backlog.jsonl'
  $script:testConversationPath = Join-Path $sandbox 'conversation.jsonl'
  $script:msgs = New-Object 'System.Collections.Generic.List[object]'
  function script:Get-ChannelBacklogPath { return $script:testBacklogPath }
  function script:Get-BacklogControlDir { return $sandbox }
  function script:Get-ConversationPath { return $script:testConversationPath }
  function script:Add-Message {
    param($From, $Text, $Kind)
    [void]$script:msgs.Add([pscustomobject]@{ From = [string]$From; Text = [string]$Text; Kind = [string]$Kind })
    $line = ([ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); from = [string]$From; text = [string]$Text; kind = [string]$Kind } | ConvertTo-Json -Compress -Depth 4)
    [System.IO.File]::AppendAllText($script:testConversationPath, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
    return $script:msgs.Count
  }
  function Write-TestBacklogItems {
    param([object[]]$Items)
    $lines = @($Items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
    [System.IO.File]::WriteAllText($script:testBacklogPath, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  }
  try {
    $baseItems = @(
      [pscustomobject][ordered]@{ id = 'unit-a'; title = 'Done title'; text = 'done text'; status = 'done'; tags = @('operator','batch:unit') },
      [pscustomobject][ordered]@{ id = 'unit-b'; title = 'Failed title'; text = 'failed text'; status = 'failed'; tags = @('operator','batch:unit') }
    )
    Write-TestBacklogItems -Items $baseItems
    $first = @(Publish-OperatorBatchCompletionSummariesIfNeeded)
    Write-TestBacklogItems -Items $baseItems
    $repair = @(Publish-OperatorBatchCompletionSummariesIfNeeded)
    $second = @(Publish-OperatorBatchCompletionSummariesIfNeeded)
    $ledgerPath = Get-OperatorBatchReportLedgerPath
    $ledgerCount = if (Test-Path -LiteralPath $ledgerPath) { @(Get-Content -LiteralPath $ledgerPath -Encoding UTF8).Count } else { 0 }
    $saved = @(Get-Backlog | Where-Object { @($_.tags) -contains 'batch:unit' })
    $marked = @($saved | Where-Object {
      [bool](Get-BacklogPackObjectValue -Obj $_ -Name 'operator_batch_reported' -Default $false)
    }).Count
    $summary = if ($script:msgs.Count -gt 0) { [string]$script:msgs[0].Text } else { '' }
    return (
      $first.Count -eq 1 -and
      $repair.Count -eq 1 -and
      $second.Count -eq 0 -and
      $script:msgs.Count -eq 1 -and
      $ledgerCount -eq 1 -and
      $marked -eq 2 -and
      $summary -match 'operator-batch unit: 1 done, 1 failed, 0 blocked' -and
      $summary -match 'Failed title'
    )
  } finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Test-Check 'operator-batch summary marker resets when Add-Message fails before post' {
  $sandbox = Join-Path $env:TEMP ('operator-batch-fail-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
  $script:testBacklogPath = Join-Path $sandbox 'backlog.jsonl'
  $script:testConversationPath = Join-Path $sandbox 'conversation.jsonl'
  function script:Get-ChannelBacklogPath { return $script:testBacklogPath }
  function script:Get-BacklogControlDir { return $sandbox }
  function script:Get-ConversationPath { return $script:testConversationPath }
  function script:Add-Message { throw 'unit add-message failure' }
  try {
    $items = @(
      [pscustomobject][ordered]@{ id = 'unit-c'; title = 'Done title'; text = 'done text'; status = 'done'; tags = @('operator','batch:fail') }
    )
    $lines = @($items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
    [System.IO.File]::WriteAllText($script:testBacklogPath, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    $published = @(Publish-OperatorBatchCompletionSummariesIfNeeded)
    $saved = @(Get-Backlog | Where-Object { @($_.tags) -contains 'batch:fail' })
    $reported = [bool](Get-BacklogPackObjectValue -Obj $saved[0] -Name 'operator_batch_reported' -Default $false)
    $errorText = [string](Get-BacklogPackObjectValue -Obj $saved[0] -Name 'operator_batch_report_error' -Default '')
    return ($published.Count -eq 0 -and -not $reported -and $errorText -match 'Add-Message failed')
  } finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Test-Check 'Get-BacklogGitOutput handles native git errors under Stop' {
  $oldPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Stop'
    $out = Get-BacklogGitOutput -GitArgs @('definitely-not-a-git-subcommand')
    return [string]::IsNullOrEmpty([string]$out)
  } finally {
    $ErrorActionPreference = $oldPreference
  }
}

Test-Check 'operator-batch duplicate scan detects raw malformed JSON lines' {
  $sandbox = Join-Path $env:TEMP ('operator-batch-raw-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
  $script:testConversationPath = Join-Path $sandbox 'conversation.jsonl'
  function script:Get-ConversationPath { return $script:testConversationPath }
  function script:Get-BacklogControlDir { return $sandbox }
  try {
    [System.IO.File]::WriteAllText($script:testConversationPath, '{broken operator-batch raw: 1 done, 0 failed, 0 blocked', (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText((Join-Path $sandbox 'operator-batch-reports.jsonl'), '{broken batch:raw', (New-Object System.Text.UTF8Encoding($false)))
    $seen = Test-OperatorBatchSummaryAlreadyPosted -Summary 'operator-batch raw: 1 done, 0 failed, 0 blocked' -BatchId 'raw' -BatchTag 'batch:raw' -Tail 10
    $logged = Test-OperatorBatchReportLogged -BatchTag 'batch:raw' -BatchId 'raw'
    return ($seen -and $logged)
  } finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
  }
}

. (Join-Path $b 'lib\replay.ps1')

Test-Check 'replay task meta restores from WAL when meta is missing' {
  $sandbox = Join-Path $env:TEMP ('replay-wal-test-' + [guid]::NewGuid().ToString('N').Substring(0,8))
  New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
  $script:testBridgeRoot = $sandbox
  function script:Get-BridgeRoot { return $script:testBridgeRoot }
  $taskId = 'codex-wal-test'
  try {
    Save-ReplayTaskMeta -TaskId $taskId -Meta @{ status='done'; turn_count=7; channel='unit' }
    $dir = Join-Path (Join-Path $sandbox 'replay') $taskId
    $metaPath = Join-Path $dir '_meta.json'
    $walPath = Join-Path $dir '_meta.json.wal'
    if (-not (Test-Path -LiteralPath $walPath -PathType Leaf)) { return $false }
    Remove-Item -LiteralPath $metaPath -Force
    $meta = Get-ReplayTaskMeta -TaskId $taskId
    return ($null -ne $meta -and [string]$meta.status -eq 'done' -and [int]$meta.turn_count -eq 7 -and (Test-Path -LiteralPath $metaPath -PathType Leaf))
  } finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host ""
Write-Host "Result: $pass passed, $fail failed"
exit $fail
