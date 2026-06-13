[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:PassCount = 0
$script:FailCount = 0

function Write-TestResult {
  param(
    [string]$Name,
    [bool]$Condition,
    [string]$FailureDetail = ''
  )

  if ($Condition) {
    $script:PassCount++
    Write-Host ("PASS: {0}" -f $Name)
    return
  }

  $script:FailCount++
  if ([string]::IsNullOrWhiteSpace($FailureDetail)) {
    Write-Host ("FAIL: {0}" -f $Name)
  } else {
    Write-Host ("FAIL: {0} - {1}" -f $Name, $FailureDetail)
  }
}

function New-Idea {
  param(
    [string]$Id,
    [string]$Text,
    [string[]]$Tags = @()
  )

  return [pscustomobject]@{
    id = $Id
    text = $Text
    tags = $Tags
  }
}

function Invoke-GuardCase {
  param(
    [string]$Name,
    [object[]]$Backlog
  )

  $setIdeaCalls = New-Object System.Collections.ArrayList
  $messages = New-Object System.Collections.ArrayList

  $result = Invoke-DriverDecomposedMarker `
    -DecompResult ([pscustomobject]@{ IsDecomposed = $true; Count = 2 }) `
    -BridgeRoot $repoRoot `
    -ReadStateScript ({ [pscustomobject]@{ current_backlog_id = 'parent-1'; current_task_id = '' } }) `
    -GetBacklogScript ({ $Backlog }.GetNewClosure()) `
    -SetIdeaScript ({
      param([string]$Id, [string]$Status, [string]$Reason)
      $setIdeaCalls.Add([pscustomobject]@{ Id = $Id; Status = $Status; Reason = $Reason }) | Out-Null
      return $true
    }.GetNewClosure()) `
    -AddMessageScript ({
      param([string]$Text)
      $messages.Add($Text) | Out-Null
    }.GetNewClosure()) `
    -UpdateStateScript ({
      param([int]$Expected, [string]$ParentId)
    }) `
    -SendPushScript ({
      param([string]$ParentId)
    })

  return [pscustomobject]@{
    Name = $Name
    Result = $result
    SetIdeaCalls = @($setIdeaCalls)
    Messages = @($messages)
  }
}

function Test-ParseFile {
  param([string]$Path)

  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
  return @($errors).Count -eq 0
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$checksPath = Join-Path $repoRoot 'driver\86-loop-completion-checks.ps1'
$selfPath = $MyInvocation.MyCommand.Path

Write-TestResult -Name 'ParseFile OK: self' -Condition (Test-ParseFile -Path $selfPath)
Write-TestResult -Name 'ParseFile OK: driver checks' -Condition (Test-ParseFile -Path $checksPath)

. $checksPath

$parent = New-Idea -Id 'parent-1' -Text 'parent task' -Tags @('operator')

$caseA = Invoke-GuardCase -Name 'A' -Backlog @($parent)
Write-TestResult -Name 'A: marker handled' -Condition ([bool]$caseA.Result.Handled)
Write-TestResult -Name 'A: no children found' -Condition ($caseA.Result.ChildrenFound -eq 0) -FailureDetail ("actual={0}" -f $caseA.Result.ChildrenFound)
Write-TestResult -Name 'A: parent not closed' -Condition (-not [bool]$caseA.Result.ParentClosed)
Write-TestResult -Name 'A: Set-Idea not called with decomposed' -Condition (-not (@($caseA.SetIdeaCalls | Where-Object { $_.Status -eq 'decomposed' }).Count))
Write-TestResult -Name 'A: log contains DECOMPOSE FAILED' -Condition ((@($caseA.Messages) -join "`n") -match 'DECOMPOSE FAILED')

$caseBChildren = @(
  (New-Idea -Id 'child-1' -Text 'child one for parent-1' -Tags @('decomposed-child')),
  (New-Idea -Id 'child-2' -Text 'child two for parent-1' -Tags @('decomposed-child'))
)
$caseB = Invoke-GuardCase -Name 'B' -Backlog (@($parent) + $caseBChildren)
Write-TestResult -Name 'B: two children found' -Condition ($caseB.Result.ChildrenFound -eq 2) -FailureDetail ("actual={0}" -f $caseB.Result.ChildrenFound)
Write-TestResult -Name 'B: parent closed as decomposed' -Condition ([bool]$caseB.Result.ParentClosed)
Write-TestResult -Name 'B: Set-Idea called once with decomposed' -Condition ((@($caseB.SetIdeaCalls | Where-Object { $_.Id -eq 'parent-1' -and $_.Status -eq 'decomposed' }).Count) -eq 1)

$caseCChildren = @(
  New-Idea -Id 'child-1' -Text 'single child for parent-1' -Tags @('decomposed-child')
)
$caseC = Invoke-GuardCase -Name 'C' -Backlog (@($parent) + $caseCChildren)
Write-TestResult -Name 'C: one child reaches ceil(2/2) boundary' -Condition ($caseC.Result.ChildrenFound -eq 1) -FailureDetail ("actual={0}" -f $caseC.Result.ChildrenFound)
Write-TestResult -Name 'C: parent closed at boundary' -Condition ([bool]$caseC.Result.ParentClosed)
Write-TestResult -Name 'C: Set-Idea called once with decomposed' -Condition ((@($caseC.SetIdeaCalls | Where-Object { $_.Id -eq 'parent-1' -and $_.Status -eq 'decomposed' }).Count) -eq 1)

Write-Host ("{0} passed, {1} failed" -f $script:PassCount, $script:FailCount)

if ($script:FailCount -gt 0) {
  exit 1
}

exit 0
