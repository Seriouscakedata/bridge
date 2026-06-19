#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $repoRoot 'lib\prompt-builder.ps1')
. (Join-Path $repoRoot 'driver\86-loop-completion-actions.ps1')

$script:PassCount = 0
$script:FailCount = 0

function Convert-TestValue {
  param([AllowNull()][object]$Value)
  if ($null -eq $Value) { return '<null>' }
  try { return ($Value | ConvertTo-Json -Compress -Depth 8) } catch { return [string]$Value }
}

function Write-TestResult {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][bool]$Condition,
    [AllowNull()][object]$Actual = $null
  )

  if ($Condition) {
    $script:PassCount++
    Write-Host ("PASS: {0}" -f $Name)
    return
  }

  $script:FailCount++
  Write-Host ("FAIL: {0} actual={1}" -f $Name, (Convert-TestValue -Value $Actual))
}

function Invoke-TestCase {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][scriptblock]$Body
  )

  try {
    & $Body
  } catch {
    Write-TestResult -Name $Name -Condition $false -Actual $_.Exception.Message
  }
}

function New-TestIdea {
  param(
    [string]$Id = 'crusher-parent',
    [string[]]$Tags = @()
  )

  return [pscustomobject]@{
    id = $Id
    text = 'short bridge self task'
    scope = 'bridge'
    tags = @($Tags)
    files = @()
    acceptance = @('a','b','c','d','e')
  }
}

function New-TestState {
  param(
    [string]$ParentId = 'crusher-parent',
    [object[]]$Atoms = @(),
    [string[]]$Errors = @(),
    [int]$RetryCount = 0,
    [string]$RetryParentId = $ParentId
  )

  return [pscustomobject]@{
    bridge_self_last_decompose_ingest = [pscustomobject]@{
      parent_id = $ParentId
      atoms = @($Atoms)
      errors = @($Errors)
    }
    bridge_self_decompose_retry_count = $RetryCount
    bridge_self_decompose_retry_parent_id = $RetryParentId
    bridge_self_decompose_retry_errors = @()
  }
}

function Invoke-GateWithSyntheticState {
  param(
    [Parameter(Mandatory=$true)]$State,
    [string]$Id = 'crusher-parent',
    [string[]]$Tags = @()
  )

  & {
    param($LocalState, $LocalId, [string[]]$LocalTags)

    $script:GateIdeaWrites = @()
    $script:GateHoldWrites = @()
    $script:GateStateWrites = 0
    $script:GateStateReads = 0

    function Get-IdeaById {
      param([string]$Id)
      return (New-TestIdea -Id $Id)
    }

    function Set-Idea {
      param([string]$Id, [string]$Status, [string]$Reason)
      $script:GateIdeaWrites += [pscustomobject]@{ id=$Id; status=$Status; reason=$Reason }
      return $true
    }

    function Set-IdeaHoldReason {
      param([string]$Id, [string]$Reason)
      $script:GateHoldWrites += [pscustomobject]@{ id=$Id; reason=$Reason }
      return $true
    }

    function Read-State {
      $script:GateStateReads++
      throw 'synthetic PromptState should avoid Read-State'
    }

    function Update-State {
      param([scriptblock]$Mutator)
      $script:GateStateWrites++
      & $Mutator $LocalState
      return $LocalState
    }

    $result = Invoke-BridgeSelfDecomposeGate `
      -Id $LocalId `
      -Channel 'main' `
      -Scope 'bridge' `
      -Tags $LocalTags `
      -TaskText 'short bridge self task' `
      -PromptState $LocalState

    return [pscustomobject]@{
      result = $result
      idea_writes = @($script:GateIdeaWrites)
      hold_writes = @($script:GateHoldWrites)
      state_writes = [int]$script:GateStateWrites
      state_reads = [int]$script:GateStateReads
      state = $LocalState
    }
  } $State $Id $Tags
}

Invoke-TestCase 'TEST 1 largeness: main bridge acceptance_count=5 is large; decomposed-child is not large' {
  $large = Test-IsLargeTask -Channel 'main' -Scope 'bridge' -AcceptanceCount 5
  $child = Test-IsLargeTask -Channel 'main' -Scope 'bridge' -AcceptanceCount 5 -Tags @('decomposed-child')
  Write-TestResult -Name 'TEST 1 largeness' -Condition ([bool]$large -and -not [bool]$child) -Actual @{ large=$large; child=$child }
}

Invoke-TestCase 'TEST 2 valid split: gate returns decomposed and suppresses coder continuation' {
  $state = New-TestState -Atoms @(
    [pscustomobject]@{ valid_for_split=$true; action='created' },
    [pscustomobject]@{ valid_for_split=$true; action='created' }
  ) -Errors @()

  $actual = Invoke-GateWithSyntheticState -State $state
  $ok = [string]$actual.result.action -eq 'decomposed' `
    -and [bool]$actual.result.suppressContinue `
    -and [int]$actual.result.validSplitCount -eq 2 `
    -and [string]$actual.result.status -eq 'decomposed' `
    -and @($actual.idea_writes | Where-Object { $_.status -eq 'decomposed' }).Count -eq 1 `
    -and [int]$actual.state_reads -eq 0

  Write-TestResult -Name 'TEST 2 valid split' -Condition $ok -Actual $actual
}

Invoke-TestCase 'TEST 3 gate exhaustion: retry_count=3 invalid split holds parent' {
  $state = New-TestState -Atoms @() -Errors @() -RetryCount 3
  $actual = Invoke-GateWithSyntheticState -State $state
  $ok = [string]$actual.result.action -eq 'held' `
    -and [bool]$actual.result.suppressContinue `
    -and [string]$actual.result.reason -eq 'bridge-self-decomposition-invalid' `
    -and [string]$actual.result.status -eq 'held' `
    -and @($actual.idea_writes | Where-Object { $_.status -eq 'held' -and $_.reason -eq 'bridge-self-decomposition-invalid' }).Count -eq 1 `
    -and @($actual.hold_writes | Where-Object { $_.reason -eq 'bridge-self-decomposition-invalid' }).Count -eq 1

  Write-TestResult -Name 'TEST 3 gate exhaustion' -Condition $ok -Actual $actual
}

Invoke-TestCase 'TEST 4 child bypass: decomposed-child tag passes through gate' {
  & {
    function Get-IdeaById { throw 'child bypass must not read idea' }
    function Read-State { throw 'child bypass must not read state' }
    function Update-State { throw 'child bypass must not write state' }
    function Set-Idea { throw 'child bypass must not write idea' }
    function Set-IdeaHoldReason { throw 'child bypass must not write hold reason' }

    $actual = Invoke-BridgeSelfDecomposeGate `
      -Id 'crusher-child' `
      -Channel 'main' `
      -Scope 'bridge' `
      -Tags @('decomposed-child') `
      -TaskText 'child atom' `
      -PromptState (New-TestState -ParentId 'crusher-child' -RetryCount 3)

    $ok = [string]$actual.action -eq 'noop' -and -not [bool]$actual.suppressContinue
    Write-TestResult -Name 'TEST 4 child bypass' -Condition $ok -Actual $actual
  }
}

Write-Host ("RESULT: {0} PASS, {1} FAIL" -f $script:PassCount, $script:FailCount)
if ($script:FailCount -gt 0) { exit 1 }
exit 0
