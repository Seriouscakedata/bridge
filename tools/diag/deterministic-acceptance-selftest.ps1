#Requires -Version 5.1
# VERIFY-COVERS: driver/86-loop-completion-checks.ps1
# Tests Invoke-DeterministicAcceptance (speed program 1a): the driver runs declared checks
# itself (py_compile for .py, parse for .ps1) instead of burning a planner VERIFY turn.
# Security contract: never executes raw task strings; unrecognized -> $null (normal VERIFY);
# path escape -> $null.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# Stub the job-scriptblock dependencies that 86-checks references at load (assignments only).
. (Join-Path $root 'driver\86-loop-completion-checks.ps1')

$sandbox = Join-Path $env:TEMP ('det-accept-' + ([guid]::NewGuid().ToString('N').Substring(0,8)))
New-Item -ItemType Directory -Path (Join-Path $sandbox 'src') -Force | Out-Null
$u8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $sandbox 'src\good.py'), "x = 1`nprint(x)`n", $u8)
[System.IO.File]::WriteAllText((Join-Path $sandbox 'src\bad.py'), "def broken(:`n", $u8)
[System.IO.File]::WriteAllText((Join-Path $sandbox 'src\good.ps1'), "function Test-X { return 1 }`n", $u8)
[System.IO.File]::WriteAllText((Join-Path $sandbox 'src\bad.ps1'), "function Broken {`n", $u8)

$fails = 0
function Assert { param([string]$Name, [bool]$Cond) if ($Cond) { Write-Host "  PASS: $Name" } else { Write-Host "  FAIL: $Name"; $script:fails++ } }

Write-Host "[DA1] valid .py with py_compile check -> Ok + factual evidence"
$r = Invoke-DeterministicAcceptance -TaskText 'Polish src/good.py. Files: src/good.py. Checks: py_compile' -RepoRoot $sandbox
Assert 'DA1 not null' ($null -ne $r)
Assert 'DA1 Ok' ($r -and [bool]$r.Ok)
Assert 'DA1 evidence has exit 0' ($r -and ([string]$r.Evidence) -match 'exit 0')

Write-Host "[DA2] broken .py -> Ok=false with error evidence (goes to normal VERIFY)"
$r = Invoke-DeterministicAcceptance -TaskText 'Fix src/bad.py. Files: src/bad.py. Checks: py_compile' -RepoRoot $sandbox
Assert 'DA2 not null' ($null -ne $r)
Assert 'DA2 not Ok' ($r -and -not [bool]$r.Ok)

Write-Host "[DA3] valid .ps1 -> parse OK"
$r = Invoke-DeterministicAcceptance -TaskText 'Edit module. Files: src/good.ps1. Acceptance: parse clean' -RepoRoot $sandbox
Assert 'DA3 Ok' ($r -and [bool]$r.Ok)
Assert 'DA3 parse evidence' ($r -and ([string]$r.Evidence) -match 'parse .*OK')

Write-Host "[DA4] broken .ps1 -> Ok=false"
$r = Invoke-DeterministicAcceptance -TaskText 'Edit. Files: src/bad.ps1. Checks: parse' -RepoRoot $sandbox
Assert 'DA4 not Ok' ($r -and -not [bool]$r.Ok)

Write-Host "[DA5] unrecognized file type -> null (normal VERIFY turn)"
$r = Invoke-DeterministicAcceptance -TaskText 'Edit page. Files: web/index.html. Acceptance: looks right' -RepoRoot $sandbox
Assert 'DA5 null' ($null -eq $r)

Write-Host "[DA6] no Files: line -> null"
$r = Invoke-DeterministicAcceptance -TaskText 'Just do something nice with py_compile' -RepoRoot $sandbox
Assert 'DA6 null' ($null -eq $r)

Write-Host "[DA7] path escape ..\..\ -> never executed outside root (regex strips dots; resolves inside sandbox -> not found -> Ok=false, or null)"
$r = Invoke-DeterministicAcceptance -TaskText 'Files: ../../outside.ps1. Checks: parse' -RepoRoot $sandbox
Assert 'DA7 safe (null or not-Ok, nothing ran outside root)' (($null -eq $r) -or (-not [bool]$r.Ok))

Write-Host "[DA8] .py without py_compile keyword -> null (no implicit exec)"
$r = Invoke-DeterministicAcceptance -TaskText 'Files: src/good.py. Acceptance: just vibes' -RepoRoot $sandbox
Assert 'DA8 null' ($null -eq $r)

Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($fails -eq 0) { Write-Host 'DETERMINISTIC-ACCEPTANCE: PASS'; exit 0 }
else { Write-Host "DETERMINISTIC-ACCEPTANCE: FAIL ($fails assertion(s))"; exit 1 }
