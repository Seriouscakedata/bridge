param()

. ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\lib\common.ps1')))

$pass = 0
$fail = 0

function Assert($name, $cond) {
  if ($cond) {
    Write-Host "PASS: $name"
    $script:pass++
  } else {
    Write-Host "FAIL: $name"
    $script:fail++
  }
}

$startBridgeJob = Get-Command Start-BridgeJob -ErrorAction SilentlyContinue
$nativeSource = ''
$startBridgeJobSource = ''

if (Get-Command Get-BridgeJobNativeSource -ErrorAction SilentlyContinue) {
  $nativeSource = Get-BridgeJobNativeSource
}
if ($startBridgeJob) {
  $startBridgeJobSource = $startBridgeJob.ScriptBlock.ToString()
}

Assert 'Start-BridgeJob accepts TimeoutHours' ($startBridgeJob.Parameters.ContainsKey('TimeoutHours'))
Assert 'Start-BridgeJob defaults TimeoutHours to 24' ($startBridgeJobSource -match '\$TimeoutHours\s*=\s*24')
Assert 'Get-BridgeJobNativeSource contains timeoutMs' ($nativeSource -match 'timeoutMs')
Assert 'Get-BridgeJobNativeSource does not use WaitForSingleObject INFINITE' (-not ($nativeSource -match 'WaitForSingleObject\(pi\.hProcess,\s*INFINITE\)'))
Assert 'Get-BridgeJobNativeSource contains WAIT_TIMEOUT' ($nativeSource -match 'WAIT_TIMEOUT')
Assert 'timeoutMs is passed into C# RunCommandInJob call' ($nativeSource -match 'RunCommandInJob.*timeoutMs')

Write-Host "RESULT: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 } else { exit 0 }
