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

function Assert-Match($name, $text, $pattern) {
  $options = [System.Text.RegularExpressions.RegexOptions]::Singleline
  Assert $name ([System.Text.RegularExpressions.Regex]::IsMatch($text, $pattern, $options))
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
Assert-Match 'RunCommandInJob cleans stdoutRead via finally or SafeFileHandle lifecycle' $nativeSource '(?:CloseHandleSafe\s*\(\s*ref\s+stdoutRead\s*\)|stdoutRead\s*=\s*IntPtr\.Zero.*?SafeFileHandle\s*\(\s*readHandle\s*,\s*true\s*\))'
Assert-Match 'RunCommandInJob cleans stderrRead via finally or SafeFileHandle lifecycle' $nativeSource '(?:CloseHandleSafe\s*\(\s*ref\s+stderrRead\s*\)|stderrRead\s*=\s*IntPtr\.Zero.*?SafeFileHandle\s*\(\s*readHandle\s*,\s*true\s*\))'
Assert-Match 'RunCommandInJob cleans stdoutWrite with CloseHandleSafe' $nativeSource 'CloseHandleSafe\s*\(\s*ref\s+stdoutWrite\s*\)'
Assert-Match 'RunCommandInJob cleans stderrWrite with CloseHandleSafe' $nativeSource 'CloseHandleSafe\s*\(\s*ref\s+stderrWrite\s*\)'
Assert-Match 'RunCommandInJob closes hJob in finally' $nativeSource 'finally\s*\{.*?if\s*\(\s*hJob\s*!=\s*IntPtr\.Zero\s*\)\s*CloseHandle\s*\(\s*hJob\s*\)\s*;'
Assert-Match 'RunCommandInJob cleanup guards stdout thread join' $nativeSource '(?:try\s*\{\s*if\s*\(\s*stdoutThread\s*!=\s*null\s*&&\s*stdoutThread\.IsAlive\s*\)\s*stdoutThread\.Join\(\s*1000\s*\)\s*;\s*\}\s*catch\s*\{\s*\}|if\s*\(\s*stdoutThread\s*!=\s*null\s*&&\s*stdoutThread\.IsAlive\s*\)\s*stdoutThread\.Join\(\s*1000\s*\)\s*;)'
Assert-Match 'RunCommandInJob cleanup guards stderr thread join' $nativeSource '(?:try\s*\{\s*if\s*\(\s*stderrThread\s*!=\s*null\s*&&\s*stderrThread\.IsAlive\s*\)\s*stderrThread\.Join\(\s*1000\s*\)\s*;\s*\}\s*catch\s*\{\s*\}|if\s*\(\s*stderrThread\s*!=\s*null\s*&&\s*stderrThread\.IsAlive\s*\)\s*stderrThread\.Join\(\s*1000\s*\)\s*;)'
Assert-Match 'AssignProcessToJobObject failure terminates process and throws into common finally' $nativeSource 'if\s*\(\s*!AssignProcessToJobObject\s*\(\s*hJob\s*,\s*pi\.hProcess\s*\)\s*\)\s*\{.*?TerminateProcess\s*\(\s*pi\.hProcess\s*,\s*1\s*\)\s*;.*?throw\s+new\s+InvalidOperationException\s*\(\s*"AssignProcessToJobObject failed:\s*"\s*\+\s*err\s*\)\s*;.*?\}\s*WriteReadyMarker'

Write-Host "RESULT: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 } else { exit 0 }
