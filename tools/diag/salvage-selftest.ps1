#Requires -Version 5.1
# ASCII-only self-test for Invoke-FailedTaskSalvage (lib/doctor.ps1).
# Sandbox git repo; stubs common helpers; extracts ONLY the salvage function.
$ErrorActionPreference = 'Stop'
$doctorLib = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'lib\doctor.ps1'
if (-not (Test-Path $doctorLib)) { Write-Host "FAIL: doctor.ps1 not found"; exit 1 }

$sandbox = Join-Path $env:TEMP ('salvage-test-' + ([guid]::NewGuid().ToString('N').Substring(0,8)))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
$script:sandbox = $sandbox
& git -C $sandbox init -q 2>$null
& git -C $sandbox config user.email "t@t" 2>$null
& git -C $sandbox config user.name "t" 2>$null
'function Foo { return 1 }' | Out-File (Join-Path $sandbox 'good.ps1') -Encoding ascii
& git -C $sandbox add -A 2>$null; & git -C $sandbox commit -q -m "baseline" 2>$null

# stubs (defined before extract; extract only defines Invoke-FailedTaskSalvage)
$script:msgs = New-Object System.Collections.ArrayList
$script:pushes = New-Object System.Collections.ArrayList
function Get-BridgeRoot { return $script:sandbox }
function Add-Message { param($From, $Text, $Kind) [void]$script:msgs.Add([string]$Text) }
function Write-DoctorLog { param($Message) }
function Invoke-AutoPush { param($Root) }
function Send-PushEvent { param($Kind, $Text) [void]$script:pushes.Add([string]$Text) }

$src = [System.IO.File]::ReadAllText($doctorLib, [System.Text.Encoding]::UTF8)
$i = $src.IndexOf('function Invoke-FailedTaskSalvage')
if ($i -lt 0) { Write-Host 'FAIL: salvage function not found'; exit 1 }
. ([scriptblock]::Create($src.Substring($i)))

$fails = 0
function Assert($n, $c) { if ($c) { Write-Host "  PASS: $n" } else { Write-Host "  FAIL: $n"; $script:fails++ } }
function TreeClean { $d = @(& git -C $script:sandbox status --porcelain 2>$null | Where-Object { $_ -match '\S' }); return ($d.Count -eq 0) }
function GitHead { return (([string](& git -C $script:sandbox rev-parse --short HEAD 2>$null)).Trim()) }

Write-Host "[V3] clean tree -> none"
$r = Invoke-FailedTaskSalvage -TaskText 'nothing'
Assert 'V3 action=none' ($r.action -eq 'none')

Write-Host "`n[V1] valid dirty tail -> commit + tree clean"
$head0 = GitHead
'function Foo { return 2 }' | Out-File (Join-Path $sandbox 'good.ps1') -Encoding ascii
'function Bar { return 3 }' | Out-File (Join-Path $sandbox 'newfile.ps1') -Encoding ascii
$r = Invoke-FailedTaskSalvage -TaskText 'valid fix tail'
Assert 'V1 action=committed' ($r.action -eq 'committed')
Assert 'V1 tree clean after' (TreeClean)
Assert 'V1 head moved' ((GitHead) -ne $head0)
Assert 'V1 new file is tracked now' (@(& git -C $sandbox ls-files newfile.ps1).Count -ge 1)
Assert 'V1 chat announced' ($script:msgs.Count -ge 1)

Write-Host "`n[V2] broken dirty tail -> stash + tree clean"
'function Broken { (((' | Out-File (Join-Path $sandbox 'good.ps1') -Encoding ascii
$r = Invoke-FailedTaskSalvage -TaskText 'broken fix tail'
Assert 'V2 action=stashed' ($r.action -eq 'stashed')
Assert 'V2 tree clean after' (TreeClean)
Assert 'V2 stash created' (@(& git -C $sandbox stash list 2>$null).Count -ge 1)
Assert 'V2 operator paged' (@($script:pushes | Where-Object { $_ -match 'salvage' }).Count -ge 1)
Assert 'V2 good.ps1 restored valid' ((Get-Content (Join-Path $sandbox 'good.ps1') -Raw) -match 'return 2')

Write-Host "`n[V4] runtime-only churn -> none"
& git -C $sandbox stash drop 2>$null | Out-Null
New-Item -ItemType Directory -Path (Join-Path $sandbox 'channels\main') -Force | Out-Null
'{"x":1}' | Out-File (Join-Path $sandbox 'channels\main\state.json') -Encoding ascii
$r = Invoke-FailedTaskSalvage -TaskText 'runtime churn'
Assert 'V4 action=none (runtime excluded)' ($r.action -eq 'none')

Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fails -eq 0) { Write-Host 'SALVAGE-SELFTEST: PASS' } else { Write-Host "SALVAGE-SELFTEST: FAIL ($fails assertion(s))"; exit 1 }
