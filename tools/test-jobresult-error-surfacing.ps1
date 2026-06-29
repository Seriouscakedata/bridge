param()
# 2026-06-29: verifies Get-JobResult surfaces the FIRST error section (not just the last 3000
# chars), so build-tool failures whose cause precedes a long trailing dump (e.g. gradle's
# runtime-classpath tree) are visible to the agents instead of being truncated away.
$ErrorActionPreference = 'Stop'
$script:pass = 0; $script:fail = 0
function A { param([bool]$c,[string]$m) if($c){$script:pass++}else{$script:fail++;Write-Host "FAIL: $m"} }

. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\jobs.ps1')

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('jobres-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$u8 = New-Object System.Text.UTF8Encoding($false)
try {
  $cause = 'Dependency androidx.camera:camera-view:1.4.1 requires compileSdk 34 but :app uses 33.'
  $dump  = (1..400 | ForEach-Object { "  :app:debugRuntimeClasspath -> androidx.foo:bar:$_ -> baz:qux:$_ -> a:b:$_" }) -join "`n"
  $log   = "> Configure project :app`n> Task :app:checkDebugAarMetadata FAILED`n`nFAILURE: Build failed with an exception.`n`n* What went wrong:`nExecution failed for task ':app:checkDebugAarMetadata'.`n> $cause`n$dump`n`n* Try:`n> Run with --stacktrace`n`nBUILD FAILED in 49s"
  $logF = Join-Path $tmp 'a.log'; $doneF = Join-Path $tmp 'a.done'
  [IO.File]::WriteAllText($logF, $log, $u8); [IO.File]::WriteAllText($doneF, '1', $u8)
  $r = Get-JobResult -Job @{ log = $logF; done = $doneF }
  A ($r.exitCode -eq '1') 'exit code read'
  A ($r.tail -match 'What went wrong') "tail surfaces 'What went wrong'"
  A ($r.tail -match 'requires compileSdk 34') 'tail surfaces the actual cause line'
  A ($r.tail -match 'BUILD FAILED in 49s') 'tail still includes the final line'
  A (-not ($log.Substring($log.Length - 3000) -match 'What went wrong')) 'CONTROL: cause absent from last 3000 chars (old logic would miss it)'

  $logF2 = Join-Path $tmp 'b.log'; $doneF2 = Join-Path $tmp 'b.done'
  [IO.File]::WriteAllText($logF2, 'BUILD SUCCESSFUL in 3s', $u8); [IO.File]::WriteAllText($doneF2, '0', $u8)
  $r2 = Get-JobResult -Job @{ log = $logF2; done = $doneF2 }
  A ($r2.tail -eq 'BUILD SUCCESSFUL in 3s') 'small output unchanged'
  A ($r2.exitCode -eq '0') 'small exit code'

  $big = (1..600 | ForEach-Object { "line $_ of routine verbose progress output with assorted details" }) -join "`n"
  $logF3 = Join-Path $tmp 'c.log'; $doneF3 = Join-Path $tmp 'c.done'
  [IO.File]::WriteAllText($logF3, $big, $u8); [IO.File]::WriteAllText($doneF3, '0', $u8)
  $r3 = Get-JobResult -Job @{ log = $logF3; done = $doneF3 }
  A ($r3.tail -match 'line 600') 'no-marker large output keeps the tail'
  A ($r3.tail.Length -lt 3200) 'no-marker large output stays tail-capped'
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "PASS=$script:pass FAIL=$script:fail"
if ($script:fail) { exit 1 } else { Write-Host 'OK' }
