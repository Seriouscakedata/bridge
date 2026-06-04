param()

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$helper = Join-Path $root 'lib\retry-helper.ps1'
$common = Join-Path $root 'lib\common.ps1'
$llm = Join-Path $root 'lib\llm.ps1'
$memory = Join-Path $root 'lib\memory.ps1'
$test = $PSCommandPath

$pass = 0
$fail = 0

function Assert {
  param([string]$Name, [bool]$Condition)
  if ($Condition) {
    Write-Host "PASS: $Name"
    $script:pass++
  } else {
    Write-Host "FAIL: $Name"
    $script:fail++
  }
}

function Test-Utf8Bom {
  param([string]$Path)
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function Test-ParseOk {
  param([string]$Path)
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
  return ($errors.Count -eq 0)
}

$files = @($helper, $common, $llm, $memory, $test)
foreach ($f in $files) {
  Assert "BOM $(Split-Path -Leaf $f)" (Test-Utf8Bom $f)
  Assert "Parse $(Split-Path -Leaf $f)" (Test-ParseOk $f)
}

. $helper

Assert 'Default backoff attempt 1 is 3 seconds' ((Get-InvokeWithTimeoutBackoffSec -Attempt 1) -eq 3)
Assert 'Default backoff attempt 2 is 7 seconds' ((Get-InvokeWithTimeoutBackoffSec -Attempt 2) -eq 7)
Assert 'Default backoff attempt 3 is 15 seconds' ((Get-InvokeWithTimeoutBackoffSec -Attempt 3) -eq 15)
Assert 'Default backoff attempt 4 is 31 seconds' ((Get-InvokeWithTimeoutBackoffSec -Attempt 4) -eq 31)

$timeoutName = 'retry-helper-timeout-test'
$errorName = 'retry-helper-error-test'

$before = @(Get-Job -Name "$timeoutName*" -ErrorAction SilentlyContinue).Count + @(Get-Job -Name "$errorName*" -ErrorAction SilentlyContinue).Count
Assert 'No matching jobs before test' ($before -eq 0)

$timeoutResult = Invoke-WithTimeout -Name $timeoutName -TimeoutSec 1 -MaxAttempts 2 -BackoffSeconds @(0,0) -ScriptBlock {
  Start-Sleep -Seconds 5
  'late'
}
Assert 'Timeout returns structured object' (Test-InvokeWithTimeoutResult -Value $timeoutResult -Status 'Timeout')
Assert 'Timeout attempts equals max' ([int]$timeoutResult.Attempts -eq 2)
Assert 'TimeoutSec is preserved' ([int]$timeoutResult.TimeoutSec -eq 1)

$successResult = Invoke-WithTimeout -Name 'retry-helper-success-test' -TimeoutSec 5 -MaxAttempts 2 -BackoffSeconds @(0,0) -ArgumentList @('ok') -ScriptBlock {
  param([string]$Value)
  "result:$Value"
}
Assert 'Successful scriptblock returns normal output' ([string]$successResult -eq 'result:ok')

$errorResult = Invoke-WithTimeout -Name $errorName -TimeoutSec 5 -MaxAttempts 2 -BackoffSeconds @(0,0) -ScriptBlock {
  throw 'planned failure'
}
Assert 'Exception returns structured error object' (Test-InvokeWithTimeoutResult -Value $errorResult -Status 'Error')
Assert 'Exception message is preserved' ([string]$errorResult.Error -match 'planned failure')

$after = @(Get-Job -Name "$timeoutName*" -ErrorAction SilentlyContinue).Count + @(Get-Job -Name "$errorName*" -ErrorAction SilentlyContinue).Count
Assert 'No matching jobs remain after test' ($after -eq 0)

Write-Host "RESULT: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 }
exit 0
