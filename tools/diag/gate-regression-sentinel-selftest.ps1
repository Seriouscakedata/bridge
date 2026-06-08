#Requires -Version 5.1
# VERIFY-COVERS: driver/86-loop-completion-checks.ps1
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$checksPath = Join-Path $repoRoot 'driver\86-loop-completion-checks.ps1'
if (-not (Test-Path -LiteralPath $checksPath -PathType Leaf)) {
  Write-Host "FAIL: checks file not found: $checksPath"
  exit 1
}

. $checksPath

$script:Pass = 0
$script:Fail = 0

function Assert-GateSentinel {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    [string]$Detail = ''
  )
  if ($Condition) {
    $script:Pass++
    Write-Host ("PASS: {0}" -f $Name)
    return
  }
  $script:Fail++
  if ([string]::IsNullOrWhiteSpace($Detail)) {
    Write-Host ("FAIL: {0}" -f $Name)
  } else {
    Write-Host ("FAIL: {0} :: {1}" -f $Name, $Detail)
  }
}

function Invoke-TestGit {
  param(
    [Parameter(Mandatory=$true)][string]$Root,
    [Parameter(Mandatory=$true)][string[]]$Arguments
  )
  $errFile = [System.IO.Path]::GetTempFileName()
  $oldErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $out = @(& git -C $Root @Arguments 2> $errFile)
    if ($LASTEXITCODE -ne 0) {
      $err = ''
      try { $err = [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8) } catch {}
      throw ("git {0} failed: {1} {2}" -f ($Arguments -join ' '), (($out | ForEach-Object { [string]$_ }) -join ' '), $err)
    }
    return @($out)
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
  }
}

function New-TestGitRoot {
  $root = Join-Path $env:TEMP ('gate-regression-sentinel-' + ([guid]::NewGuid().ToString('N').Substring(0,8)))
  New-Item -ItemType Directory -Path $root -Force | Out-Null
  Invoke-TestGit -Root $root -Arguments @('init') | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $root 'README.md'), "init`n", (New-Object System.Text.UTF8Encoding($false)))
  Invoke-TestGit -Root $root -Arguments @('add','README.md') | Out-Null
  Invoke-TestGit -Root $root -Arguments @('-c','user.name=bridge-test','-c','user.email=bridge-test@example.invalid','commit','-m','init') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $root 'lib') -Force | Out-Null
  [System.IO.File]::WriteAllText((Join-Path $root 'lib\common.ps1'), "function Test-Common { 'ok' }`n", (New-Object System.Text.UTF8Encoding($false)))
  return $root
}

function Invoke-GateRuntimeCase {
  param([scriptblock]$Setup)

  $caseRoot = New-TestGitRoot
  $script:CaseMessages = New-Object 'System.Collections.Generic.List[string]'
  $script:CaseFailures = New-Object 'System.Collections.Generic.List[object]'
  $script:CaseState = [pscustomobject][ordered]@{
    task_did_actions = $true
    task_base_commit = ''
  }

  try {
    $speaker = 'claude'
    $fastLaneDone = $false
    $plannerStatus = 'DONE'
    $modeBeforeIncrement = 'normal'
    $bridgeRoot = $caseRoot
    $Channel = 'main'
    $task = 'gate regression sentinel diag'

    function Read-State { return $script:CaseState }
    function Add-Message {
      param([string]$From, [string]$Text, [string]$Kind = 'event')
      [void]$script:CaseMessages.Add([string]$Text)
      return [pscustomobject]@{ ok = $true }
    }
    function Set-TaskLastFailure {
      param([string]$Kind, [string]$Text)
      [void]$script:CaseFailures.Add([pscustomobject]@{ Kind = $Kind; Text = $Text })
    }
    function Update-State {
      param([scriptblock]$ScriptBlock)
      if ($ScriptBlock) { & $ScriptBlock $script:CaseState | Out-Null }
      return $script:CaseState
    }
    function Get-EffectiveChannel { return 'main' }
    function Invoke-WithChannelEnv {
      param([string]$Slug, [object]$ArgumentList, [scriptblock]$Action)
      & $Action $ArgumentList
    }
    function Invoke-QAAgent { throw 'QA agent should not run after gate-regression fail-closed' }

    if ($Setup) { . $Setup }
    . $script:DriverLoopCompletionRuntimeChecksBlock

    return [pscustomobject][ordered]@{
      PlannerStatus = $plannerStatus
      Messages = @($script:CaseMessages.ToArray())
      Failures = @($script:CaseFailures.ToArray())
    }
  } finally {
    Remove-Item -LiteralPath $caseRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Test-NoSkippedMessage {
  param([object]$Case)
  return (@($Case.Messages | Where-Object { [string]$_ -match 'skipped' })).Count -eq 0
}

Write-Host '[GRS1] missing gate-regression imports fail closed'
$case = Invoke-GateRuntimeCase -Setup {}
Assert-GateSentinel 'GRS1 plannerStatus CONTINUE' ($case.PlannerStatus -eq 'CONTINUE')
Assert-GateSentinel 'GRS1 failure evidence recorded' (@($case.Failures | Where-Object { $_.Kind -eq 'gate_regression_runtime_error' }).Count -eq 1)
Assert-GateSentinel 'GRS1 mentions import missing' ((@($case.Messages) -join "`n") -match 'runtime import missing')
Assert-GateSentinel 'GRS1 does not say skipped' (Test-NoSkippedMessage $case) ((@($case.Messages) -join ' | '))

Write-Host "`n[GRS2] missing Invoke-GateRegressionSuite fails closed before scope skip"
$case = Invoke-GateRuntimeCase -Setup {
  function Get-GateRegressionScope {
    param([string[]]$ChangedPaths)
    return @()
  }
}
Assert-GateSentinel 'GRS2 plannerStatus CONTINUE' ($case.PlannerStatus -eq 'CONTINUE')
Assert-GateSentinel 'GRS2 names missing suite import' ((@($case.Messages) -join "`n") -match 'Invoke-GateRegressionSuite')
Assert-GateSentinel 'GRS2 does not say skipped' (Test-NoSkippedMessage $case) ((@($case.Messages) -join ' | '))

Write-Host "`n[GRS3] scope exception after real changed-path collection fails closed"
$case = Invoke-GateRuntimeCase -Setup {
  function Get-GateRegressionScope {
    param([string[]]$ChangedPaths)
    if (@($ChangedPaths) -notcontains 'lib/common.ps1') { throw 'expected real changed path lib/common.ps1' }
    throw 'scope boom'
  }
  function Invoke-GateRegressionSuite {
    throw 'suite should not run when scope fails'
  }
}
Assert-GateSentinel 'GRS3 plannerStatus CONTINUE' ($case.PlannerStatus -eq 'CONTINUE')
Assert-GateSentinel 'GRS3 failure evidence has scope error' ((@($case.Failures.Text) -join "`n") -match 'scope boom')
Assert-GateSentinel 'GRS3 does not say skipped' (Test-NoSkippedMessage $case) ((@($case.Messages) -join ' | '))

Write-Host "`n[GRS4] suite exception after non-empty scope fails closed"
$case = Invoke-GateRuntimeCase -Setup {
  function Get-GateRegressionScope {
    param([string[]]$ChangedPaths)
    if (@($ChangedPaths) -notcontains 'lib/common.ps1') { throw 'expected real changed path lib/common.ps1' }
    return @('lib/common.ps1')
  }
  function Invoke-GateRegressionSuite {
    throw 'suite boom'
  }
}
Assert-GateSentinel 'GRS4 plannerStatus CONTINUE' ($case.PlannerStatus -eq 'CONTINUE')
Assert-GateSentinel 'GRS4 failure evidence has suite error' ((@($case.Failures.Text) -join "`n") -match 'suite boom')
Assert-GateSentinel 'GRS4 does not say skipped' (Test-NoSkippedMessage $case) ((@($case.Messages) -join ' | '))

Write-Host ''
Write-Host ("GATE-REGRESSION-SENTINEL: {0} PASS, {1} FAIL" -f $script:Pass, $script:Fail)
if ($script:Fail -gt 0) { exit 1 }
exit 0
