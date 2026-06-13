#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\..\lib\prompt-builder.ps1"
. "$PSScriptRoot\..\driver\86-loop-completion-checks.ps1"

$script:passed = 0
$script:failed = 0

function Get-Value {
  param(
    [AllowNull()][object]$Object,
    [Parameter(Mandatory=$true)][string]$Name
  )

  if ($null -eq $Object) { return $null }
  if ($Object -is [System.Collections.IDictionary]) {
    if ($Object.Contains($Name)) { return $Object[$Name] }
    return $null
  }

  $prop = $Object.PSObject.Properties[$Name]
  if ($null -ne $prop) { return $prop.Value }
  return $null
}

function Assert-True {
  param(
    [Parameter(Mandatory=$true)][bool]$Condition,
    [Parameter(Mandatory=$true)][string]$Name,
    [AllowNull()][object]$Actual = $null
  )

  if ($Condition) {
    $script:passed++
    Write-Host ("PASS: {0}" -f $Name)
    return
  }

  $script:failed++
  $suffix = ''
  if ($null -ne $Actual) {
    try {
      $suffix = ' actual=' + ($Actual | ConvertTo-Json -Compress -Depth 8)
    } catch {
      $suffix = ' actual=' + [string]$Actual
    }
  }
  Write-Host ("FAIL: {0}{1}" -f $Name, $suffix)
}

function Invoke-Case {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][scriptblock]$Body
  )

  try {
    & $Body
  } catch {
    Assert-True -Condition $false -Name $Name -Actual $_.Exception.Message
  }
}

Invoke-Case 'Detector: >=3 files -> large task' {
  $actual = Test-IsLargeTask -TaskText 'Нужно изменить lib/foo.ps1, driver/bar.ps1 и tools/baz.ps1'
  Assert-True -Condition ([bool]$actual) -Name 'Detector: >=3 files -> large task' -Actual $actual
}

Invoke-Case 'Detector: [ФИЧА] marker -> large task' {
  $actual = Test-IsLargeTask -TaskText '[ФИЧА] Новая функция (короткий текст)'
  Assert-True -Condition ([bool]$actual) -Name 'Detector: [ФИЧА] marker -> large task' -Actual $actual
}

Invoke-Case 'Detector: decomposed-child tag disables recursion' {
  $actual = Test-IsLargeTask -TaskText '[ФИЧА] много файлов lib/a.ps1 lib/b.ps1 lib/c.ps1' -Tags @('decomposed-child')
  Assert-True -Condition (-not [bool]$actual) -Name 'Detector: decomposed-child tag disables recursion' -Actual $actual
}

Invoke-Case 'Detector: atom tag is not large' {
  $actual = Test-IsLargeTask -TaskText 'задача с lib/a.ps1 lib/b.ps1 lib/c.ps1' -Tags @('atom')
  Assert-True -Condition (-not [bool]$actual) -Name 'Detector: atom tag is not large' -Actual $actual
}

Invoke-Case '[[DECOMPOSED]] handler parses marker' {
  $actual = Test-PlannerDecomposed -ReplyText '[[DECOMPOSED: 3 атомов]]'
  $isDecomposed = [bool](Get-Value -Object $actual -Name 'IsDecomposed')
  $count = [int](Get-Value -Object $actual -Name 'Count')
  Assert-True -Condition ($isDecomposed -and $count -eq 3) -Name '[[DECOMPOSED]] handler parses marker' -Actual $actual
}

Invoke-Case '[[DECOMPOSED]] handler without marker -> false' {
  $actual = Test-PlannerDecomposed -ReplyText 'STATUS: DONE'
  $isDecomposed = [bool](Get-Value -Object $actual -Name 'IsDecomposed')
  Assert-True -Condition (-not $isDecomposed) -Name '[[DECOMPOSED]] handler without marker -> false' -Actual $actual
}

Invoke-Case 'Integration: decomposed-child atom product is not large' {
  $actual = Test-IsLargeTask -TaskText '[ФИЧА] Files: lib/foo.ps1, lib/bar.ps1, lib/baz.ps1' -Tags @('decomposed-child')
  Assert-True -Condition (-not [bool]$actual) -Name 'Integration: decomposed-child atom product is not large' -Actual $actual
}

Write-Host ("{0} passed, {1} failed" -f $script:passed, $script:failed)
if ($script:failed -gt 0) { exit 1 }
exit 0
