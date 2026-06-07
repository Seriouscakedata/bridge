$ErrorActionPreference = 'Stop'

$bridgeRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $bridgeRoot ('tmp\regression-fix-backlog-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

$script:TestRoot = $testRoot
$script:Ideas = New-Object 'System.Collections.Generic.List[object]'
$script:Memories = New-Object 'System.Collections.Generic.List[object]'
$script:GitMode = 'ok'
$script:Pass = 0
$script:Fail = 0
$script:GuardResult = [pscustomobject]@{
  allowed = $true
  reason = 'guard_passed'
  detail = [pscustomobject]@{}
}
$script:BridgeConfig = [pscustomobject]@{
  learningLoop = [pscustomobject]@{
    autoRevert = $false
    autoRevertShadow = $true
    autoRevertMaxHypothesisAgeHours = 30
    autoRevertMaxCommitsBehindHead = 0
    autoRevertRequireUnhealthy = $false
    autoRevertRequireCleanWorktree = $true
  }
}

function Get-BridgeRoot { return $script:TestRoot }
function Get-BridgeConfig { return $script:BridgeConfig }
function Add-Memory {
  param([string]$Text, [string[]]$Tags = @(), [double]$Importance = 0.0)
  $item = [pscustomobject]@{
    text = $Text
    tags = @($Tags)
    importance = $Importance
  }
  [void]$script:Memories.Add($item)
  return ('memory-' + $script:Memories.Count)
}
function Add-Idea {
  param(
    [string]$Text,
    [string]$From = '',
    [string[]]$Tags = @(),
    [string]$Severity = ''
  )
  $item = [pscustomobject]@{
    text = $Text
    from = $From
    tags = @($Tags)
    severity = $Severity
  }
  [void]$script:Ideas.Add($item)
  return ('idea-' + $script:Ideas.Count)
}

. (Join-Path $bridgeRoot 'lib\metrics.ps1')

Set-Item -Path Function:\Test-GitCommitExists -Value {
  param([string]$Root, [string]$Commit)
  return $true
} -Force
Set-Item -Path Function:\Test-LearningLoopAutoRevertGuard -Value {
  param([string]$Root, [string]$Commit, [string]$HypothesisTs, $Config)
  return $script:GuardResult
} -Force
Set-Item -Path Function:\git -Value {
  param([Parameter(ValueFromRemainingArguments = $true)][object[]]$ArgsList)
  $argsText = @($ArgsList | ForEach-Object { [string]$_ })
  $cmd = @($argsText | Where-Object { $_ -ne '-C' -and $_ -ne $script:TestRoot })
  if ($cmd.Count -eq 0) {
    $global:LASTEXITCODE = 0
    return
  }

  switch ($cmd[0]) {
    'diff' {
      $global:LASTEXITCODE = 0
      return
    }
    'revert' {
      if ($cmd.Count -gt 1 -and $cmd[1] -eq '--abort') {
        $global:LASTEXITCODE = 0
        return
      }
      if ($script:GitMode -eq 'fail') {
        $global:LASTEXITCODE = 1
        return 'simulated revert failure'
      }
      $global:LASTEXITCODE = 0
      return
    }
    'log' {
      $global:LASTEXITCODE = 0
      return 'revert-head-123'
    }
    default {
      $global:LASTEXITCODE = 0
      return
    }
  }
} -Force

function Check {
  param([string]$Name, [bool]$Condition, $Actual = $null)
  if ($Condition) {
    $script:Pass++
    Write-Host "PASS: $Name"
  } else {
    $script:Fail++
    Write-Host "FAIL: $Name"
    if ($null -ne $Actual) {
      try { $Actual | ConvertTo-Json -Compress -Depth 8 | Write-Host } catch { Write-Host $Actual }
    }
  }
}

function Get-MetricsRecords {
  $metricsPath = Join-Path $script:TestRoot 'metrics.jsonl'
  if (-not (Test-Path -LiteralPath $metricsPath)) { return @() }
  return @(Get-Content -LiteralPath $metricsPath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-FixIdeas {
  return @($script:Ideas | Where-Object { @([string[]]$_.tags) -contains 'fix' })
}

function Get-FixIdeasByAction {
  param([string]$Action)
  return @(Get-FixIdeas | Where-Object { @([string[]]$_.tags) -contains $Action })
}

try {
  $shadowTs = '2026-06-06T00:00:00Z'
  $shadow = Invoke-VerdictActuation -Verdict 'worse' -Commit 'abc1234' -Task 'Shadow regression candidate' -HypothesisTs $shadowTs -AfterTurns 7
  $shadowFix = @(Get-FixIdeasByAction -Action 'revert_shadow')
  $shadowMetrics = @(Get-MetricsRecords | Where-Object { [string]$_.type -eq 'regression_fix_backlog' -and [string]$_.action -eq 'revert_shadow' })
  Check 'worse+revert_shadow creates fix backlog idea' (
    [string]$shadow.action -eq 'revert_shadow' -and
    $shadowFix.Count -eq 1 -and
    $shadowFix[0].severity -eq 'warning' -and
    @([string[]]$shadowFix[0].tags) -contains 'learning-loop' -and
    @([string[]]$shadowFix[0].tags) -contains 'regression' -and
    $shadowFix[0].text -match 'abc1234' -and
    $shadowFix[0].text -match 'revert_shadow' -and
    $shadowFix[0].text -match 'доказать root cause' -and
    $shadowMetrics.Count -eq 1
  ) @{ result = $shadow; ideas = $shadowFix; metrics = $shadowMetrics }

  $shadowRepeat = Invoke-VerdictActuation -Verdict 'worse' -Commit 'abc1234' -Task 'Shadow regression candidate' -HypothesisTs $shadowTs -AfterTurns 7
  $shadowFixAfterRepeat = @(Get-FixIdeasByAction -Action 'revert_shadow')
  $shadowMetricsAfterRepeat = @(Get-MetricsRecords | Where-Object { [string]$_.type -eq 'regression_fix_backlog' -and [string]$_.action -eq 'revert_shadow' })
  Check 'repeat revert_shadow does not duplicate fix backlog idea' (
    [string]$shadowRepeat.action -eq 'revert_shadow' -and
    $shadowFixAfterRepeat.Count -eq 1 -and
    $shadowMetricsAfterRepeat.Count -eq 1
  ) @{ result = $shadowRepeat; ideas = $shadowFixAfterRepeat; metrics = $shadowMetricsAfterRepeat }

  $script:GuardResult = [pscustomobject]@{
    allowed = $false
    reason = 'stale_hypothesis'
    detail = [pscustomobject]@{ age_hours = 36.591; max_age_hours = 30 }
  }
  $blockedShadowTs = '2026-06-04T00:00:00Z'
  $blockedShadow = Invoke-VerdictActuation -Verdict 'worse' -Commit 'stale123' -Task 'Stale shadow candidate' -HypothesisTs $blockedShadowTs -AfterTurns 9
  $blockedShadowFix = @(Get-FixIdeasByAction -Action 'revert_shadow' | Where-Object { $_.text -match 'stale123' })
  $blockedShadowMetrics = @(Get-MetricsRecords | Where-Object { [string]$_.type -eq 'regression_fix_backlog' -and [string]$_.action -eq 'revert_shadow' -and [string]$_.commit -eq 'stale123' })
  $blockedShadowActuation = @(Get-MetricsRecords | Where-Object { [string]$_.type -eq 'actuation' -and [string]$_.action -eq 'revert_shadow' -and [string]$_.commit -eq 'stale123' })
  Check 'blocked revert_shadow records actuation but does not create fix backlog idea' (
    [string]$blockedShadow.action -eq 'revert_shadow' -and
    $blockedShadowActuation.Count -eq 1 -and
    [bool]$blockedShadowActuation[0].would_revert -eq $false -and
    [string]$blockedShadowActuation[0].reason -eq 'stale_hypothesis' -and
    $blockedShadowFix.Count -eq 0 -and
    $blockedShadowMetrics.Count -eq 0
  ) @{ result = $blockedShadow; ideas = $blockedShadowFix; metrics = $blockedShadowMetrics; actuation = $blockedShadowActuation }
  $script:GuardResult = [pscustomobject]@{
    allowed = $true
    reason = 'guard_passed'
    detail = [pscustomobject]@{}
  }

  $script:BridgeConfig.learningLoop.autoRevert = $true
  $script:BridgeConfig.learningLoop.autoRevertShadow = $false
  $script:GitMode = 'fail'
  $failTs = '2026-06-06T01:00:00Z'
  $failed = Invoke-VerdictActuation -Verdict 'worse' -Commit 'def5678' -Task 'Failed revert regression candidate' -HypothesisTs $failTs -AfterTurns 11
  $failedFix = @(Get-FixIdeasByAction -Action 'revert_failed')
  $failedManual = @($script:Ideas | Where-Object { $_.text -match 'Ручной разбор регресса: коммит def5678' })
  $failedMetrics = @(Get-MetricsRecords | Where-Object { [string]$_.type -eq 'regression_fix_backlog' -and [string]$_.action -eq 'revert_failed' })
  Check 'worse+revert_failed creates separate fix backlog idea and keeps manual analysis idea' (
    [string]$failed.action -eq 'revert_failed' -and
    $failedFix.Count -eq 1 -and
    $failedManual.Count -eq 1 -and
    $failedFix[0].text -match 'def5678' -and
    $failedFix[0].text -match 'revert_failed' -and
    $failedMetrics.Count -eq 1
  ) @{ result = $failed; fix = $failedFix; manual = $failedManual; metrics = $failedMetrics }

  $failedRepeat = Invoke-VerdictActuation -Verdict 'worse' -Commit 'def5678' -Task 'Failed revert regression candidate' -HypothesisTs $failTs -AfterTurns 11
  $failedFixAfterRepeat = @(Get-FixIdeasByAction -Action 'revert_failed')
  $failedMetricsAfterRepeat = @(Get-MetricsRecords | Where-Object { [string]$_.type -eq 'regression_fix_backlog' -and [string]$_.action -eq 'revert_failed' })
  Check 'repeat revert_failed does not duplicate fix backlog idea' (
    [string]$failedRepeat.action -eq 'revert_failed' -and
    $failedFixAfterRepeat.Count -eq 1 -and
    $failedMetricsAfterRepeat.Count -eq 1
  ) @{ result = $failedRepeat; fix = $failedFixAfterRepeat; metrics = $failedMetricsAfterRepeat; ideaCount = $script:Ideas.Count }

  $fixCountBeforeWorked = (Get-FixIdeas).Count
  $worked = Invoke-VerdictActuation -Verdict 'worked' -Commit 'ghi9012' -Task 'Worked candidate' -HypothesisTs '2026-06-06T02:00:00Z' -AfterTurns 5
  Check 'worked does not create fix backlog idea' (
    [string]$worked.action -eq 'cement' -and
    (Get-FixIdeas).Count -eq $fixCountBeforeWorked
  ) @{ result = $worked; ideas = Get-FixIdeas }

  $fixCountBeforeNoEffect = (Get-FixIdeas).Count
  $noEffect = Invoke-VerdictActuation -Verdict 'no_effect' -Commit 'jkl3456' -Task 'No effect candidate' -HypothesisTs '2026-06-06T03:00:00Z' -AfterTurns 4
  Check 'no_effect does not create fix backlog idea' (
    [string]$noEffect.action -eq 'none' -and
    (Get-FixIdeas).Count -eq $fixCountBeforeNoEffect
  ) @{ result = $noEffect; ideas = Get-FixIdeas }
} finally {
  $safeTmp = [System.IO.Path]::GetFullPath((Join-Path $bridgeRoot 'tmp')).TrimEnd('\') + '\'
  $fullTest = [System.IO.Path]::GetFullPath($testRoot)
  if ($fullTest.StartsWith($safeTmp, [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $fullTest)) {
    Remove-Item -LiteralPath $fullTest -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host ("Regression fix backlog tests: {0} PASS, {1} FAIL" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
