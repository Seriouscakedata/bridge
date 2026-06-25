#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'adversarial-audit.ps1')

$pass = 0; $fail = 0
function Assert-Eq { param($Label,$Got,$Expected)
    if ($Got -eq $Expected) { Write-Host "PASS: $Label"; $script:pass++ }
    else { Write-Host "FAIL: $Label`n  Got:      $Got`n  Expected: $Expected"; $script:fail++ }
}

$tmp = [System.IO.Path]::GetTempPath()

# Test 1: codex reads result_path
$fileA = Join-Path $tmp ("ta1a-"+[guid]::NewGuid().ToString('N')+'.txt')
$fileB = Join-Path $tmp ("ta1b-"+[guid]::NewGuid().ToString('N')+'.json')
[System.IO.File]::WriteAllText($fileA, 'event: foo', (New-Object System.Text.UTF8Encoding($false)))
$jsonB = '{"finding_id":"x","vote":"support","reason":"r","file":"f","line":1}'
[System.IO.File]::WriteAllText($fileB, $jsonB, (New-Object System.Text.UTF8Encoding($false)))
$r1 = [pscustomobject]@{ outputPath=$fileA; metadata=@{ provider='codex'; result_path=$fileB } }
$got1 = Read-AuditJobOutput -Record $r1
Assert-Eq 'codex reads result_path (not stdout)' $got1 $jsonB

# Test 2: claude reads outputPath
$fileC = Join-Path $tmp ("ta2c-"+[guid]::NewGuid().ToString('N')+'.json')
$fileD = Join-Path $tmp ("ta2d-"+[guid]::NewGuid().ToString('N')+'.json')
$jsonC = '{"finding_id":"y","vote":"refute","reason":"r2","file":"g","line":2}'
[System.IO.File]::WriteAllText($fileC, $jsonC, (New-Object System.Text.UTF8Encoding($false)))
[System.IO.File]::WriteAllText($fileD, '', (New-Object System.Text.UTF8Encoding($false)))
$r2 = [pscustomobject]@{ outputPath=$fileC; metadata=@{ provider='claude'; result_path=$fileD } }
$got2 = Read-AuditJobOutput -Record $r2
Assert-Eq 'claude reads outputPath' $got2 $jsonC

# Test 3: codex fallback when result_path empty
$fileE = Join-Path $tmp ("ta3e-"+[guid]::NewGuid().ToString('N')+'.json')
$fileF = Join-Path $tmp ("ta3f-"+[guid]::NewGuid().ToString('N')+'.json')
[System.IO.File]::WriteAllText($fileE, '', (New-Object System.Text.UTF8Encoding($false)))
$jsonF = '{"finding_id":"z","vote":"support","reason":"r3","file":"h","line":3}'
[System.IO.File]::WriteAllText($fileF, $jsonF, (New-Object System.Text.UTF8Encoding($false)))
$r3 = [pscustomobject]@{ outputPath=$fileF; metadata=@{ provider='codex'; result_path=$fileE } }
$got3 = Read-AuditJobOutput -Record $r3
Assert-Eq 'codex fallback to outputPath when result_path empty' $got3 $jsonF

# Cleanup
@($fileA,$fileB,$fileC,$fileD,$fileE,$fileF) | ForEach-Object { if (Test-Path $_) { Remove-Item $_ -Force } }

Write-Host "`nResult: $pass PASS / $fail FAIL"
if ($fail -gt 0) { exit 1 }
