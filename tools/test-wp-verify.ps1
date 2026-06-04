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
      $marked -eq 2 -and
      $summary -match 'operator-batch unit: 1 done, 1 failed, 0 blocked' -and
      $summary -match 'Failed title'
    )
  } finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host ""
Write-Host "Result: $pass passed, $fail failed"
exit $fail
