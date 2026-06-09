$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
. "$root\lib\backlog-core.ps1"

$pass = 0
$fail = 0

function Add-Result {
  param(
    [Parameter(Mandatory=$true)][string]$Label,
    [Parameter(Mandatory=$true)][bool]$Ok,
    [Parameter(Mandatory=$true)][string]$Detail
  )

  if ($Ok) {
    Write-Host ("PASS {0}: {1}" -f $Label, $Detail)
    $script:pass++
    return
  }

  Write-Host ("FAIL {0}: {1}" -f $Label, $Detail)
  $script:fail++
}

function Assert-TextContains {
  param(
    [Parameter(Mandatory=$true)][string]$Label,
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Needle
  )

  $text = [System.IO.File]::ReadAllText($Path)
  $found = $text.Contains($Needle)
  Add-Result -Label $Label -Ok $found -Detail ("{0} contains '{1}'" -f $Path, $Needle)
}

function Assert-Penalty {
  param(
    [Parameter(Mandatory=$true)][string]$Label,
    [Parameter(Mandatory=$true)]$Idea,
    [Parameter(Mandatory=$true)][int]$Expected
  )

  if (-not (Get-Command Get-IdeaNetNewPenaltyRank -ErrorAction SilentlyContinue)) {
    Add-Result -Label $Label -Ok $false -Detail "Get-IdeaNetNewPenaltyRank is missing"
    return
  }

  $actual = [int](Get-IdeaNetNewPenaltyRank $Idea)
  $ok = ($actual -eq $Expected)
  $detail = ("expected={0} actual={1}" -f $Expected, $actual)
  if ($Label -eq 'net-new-unjustified') {
    $detail = $detail + ' penalty detected'
  } elseif ($Label -eq 'net-new-operator-justified') {
    $detail = $detail + ' operator-justified exempt'
  } elseif ($Label -match '^(fix|harden|coverage|reliability)$') {
    $detail = $detail + ' unaffected'
  }

  Add-Result -Label $Label -Ok $ok -Detail $detail
}

$architectPath = Join-Path $root 'lib\architect.ps1'
$reflectPath = Join-Path $root 'reflect.ps1'

Assert-TextContains -Label 'architect-foundation2-wording' -Path $architectPath -Needle 'FOUNDATION #2:'
Assert-TextContains -Label 'architect-operator-justification' -Path $architectPath -Needle 'operator_justification'
Assert-TextContains -Label 'reflect-operator-justification' -Path $reflectPath -Needle 'operator_justification'
Assert-TextContains -Label 'reflect-net-new-wording' -Path $reflectPath -Needle 'net-new'

Assert-Penalty -Label 'net-new-unjustified' -Idea ([PSCustomObject]@{ category = 'net-new'; text = 'create new subsystem X' }) -Expected 1
Assert-Penalty -Label 'fix' -Idea ([PSCustomObject]@{ category = 'fix'; text = 'fix bug in existing Y' }) -Expected 0
Assert-Penalty -Label 'harden' -Idea ([PSCustomObject]@{ category = 'harden'; text = 'harden retry logic' }) -Expected 0
Assert-Penalty -Label 'coverage' -Idea ([PSCustomObject]@{ category = 'coverage'; text = 'add coverage for edge case' }) -Expected 0
Assert-Penalty -Label 'reliability' -Idea ([PSCustomObject]@{ category = 'reliability'; text = 'improve reliability of watchdog' }) -Expected 0
Assert-Penalty -Label 'net-new-operator-justified' -Idea ([PSCustomObject]@{ category = 'net-new'; text = 'introduce new top-level mechanism'; operator_justification = 'required by compliance mandate' }) -Expected 0
Assert-Penalty -Label 'heuristic-net-new' -Idea ([PSCustomObject]@{ text = 'create new subsystem for scheduling' }) -Expected 1
Assert-Penalty -Label 'heuristic-safe-fix' -Idea ([PSCustomObject]@{ text = 'fix bug in the logger' }) -Expected 0

Write-Host ("PASS: {0}  FAIL: {1}" -f $pass, $fail)

if ($fail -gt 0) {
  exit 1
}

exit 0
