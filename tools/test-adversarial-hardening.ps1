#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot 'adversarial-audit.ps1')

$pass = 0; $fail = 0

function Assert-True {
    param([bool]$Condition, [string]$Label)
    if ($Condition) { Write-Host "PASS: $Label"; $script:pass++ }
    else { Write-Host "FAIL: $Label"; $script:fail++ }
}

# --- PART B ---
$f1 = [pscustomobject]@{
    file='src/foo.ps1'; dimension='correctness'; evidence_snippet='some evidence here'
    line=42; severity='high'; root_cause='r'; why='w'; fix_sketch='f'; confidence=0.8; agent_id='test'
}
$f2 = [pscustomobject]@{
    file='src/foo.ps1'; dimension='security'; evidence_snippet='some evidence here'
    line=42; severity='high'; root_cause='r'; why='w'; fix_sketch='f'; confidence=0.8; agent_id='test'
}

$k1 = Get-AuditFindingStructuralKey -Finding $f1
$k2 = Get-AuditFindingStructuralKey -Finding $f2
Assert-True ($k1 -ne $k2) 'B1: different dimensions yield different structural keys'
Assert-True ($k1 -ne '') 'B2: key1 is non-empty'
Assert-True ($k2 -ne '') 'B3: key2 is non-empty'

$atom1 = Build-AuditFixAtom -Finding $f1 -RunId 'test-run-01'
Assert-True ($atom1.text -match 'correctness') "B4: Build-AuditFixAtom text contains 'correctness'"
$atom2 = Build-AuditFixAtom -Finding $f2 -RunId 'test-run-01'
Assert-True ($atom2.text -match 'security') "B5: Build-AuditFixAtom text contains 'security'"
Assert-True ($atom1.text -notmatch '^Fix \[\]') 'B6: atom text does not have empty brackets []'

# --- PART C ---
$baseF = [pscustomobject]@{
    root_cause='rc'; file='src/foo.ps1'; line=42; evidence_snippet='ev'; severity='high'
    why='w'; fix_sketch='f'; confidence=0.8; dimension='correctness'; agent_id='test'
}

function Make-Finding {
    param($lineVal, $confVal=$null)
    $f = $baseF | Select-Object -Property *
    $f.line = $lineVal
    if ($null -ne $confVal) { $f.confidence = $confVal }
    return $f
}

Assert-True ((Test-AuditFinderSchema -Obj (Make-Finding 3000000000)).valid -eq $true) 'C1: line=3000000000 (Int64) -> valid'
Assert-True ((Test-AuditFinderSchema -Obj (Make-Finding 5.0)).valid -eq $true) 'C2: line=5.0 -> valid'
Assert-True ((Test-AuditFinderSchema -Obj (Make-Finding '42')).valid -eq $true) "C3: line='42' (string) -> valid"
Assert-True ((Test-AuditFinderSchema -Obj (Make-Finding 1 '0.9')).valid -eq $true) "C4: confidence='0.9' (string) -> valid"
Assert-True ((Test-AuditFinderSchema -Obj (Make-Finding 'abc')).valid -eq $false) "C5: line='abc' -> invalid"
Assert-True ((Test-AuditFinderSchema -Obj (Make-Finding 5.5)).valid -eq $false) 'C6: line=5.5 -> invalid'
Assert-True ((Test-AuditFinderSchema -Obj (Make-Finding 0)).valid -eq $false) 'C7: line=0 -> invalid'

$batch = @(
    (Make-Finding 3000000000),
    (Make-Finding 'bad'),
    (Make-Finding 10)
)
$batchThrew = $false
$batchValid = $null
try {
    $batchValid = @($batch | Where-Object {
        $item = $_
        try { (Test-AuditFinderSchema -Obj $item).valid } catch { $false }
    })
} catch {
    $batchThrew = $true
}
Assert-True (-not $batchThrew) 'C8: batch filter does not throw'
Assert-True ($batchValid.Count -eq 2) 'C9: batch filter keeps 2 valid findings'

# --- PART E ---
$tempRoot = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "test-hardening-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))")
New-Item -ItemType Directory -Path (Join-Path $tempRoot 'src') -Force | Out-Null
$testFile = Join-Path $tempRoot 'src\target.ps1'
[System.IO.File]::WriteAllText($testFile, "line1`nline2`nsome evidence here`nline4", [System.Text.UTF8Encoding]::new($false))

$fE = [pscustomobject]@{
    root_cause='rc'; file='src/target.ps1'; line=3; evidence_snippet='some evidence here'
    severity='Critical'; why='w'; fix_sketch='f'; confidence=0.8; dimension='correctness'; agent_id='test'
}

$groundedOut = Invoke-AuditGroundingGate -Findings @($fE) -SnapshotRoot $tempRoot
$groundedArr = @($groundedOut)
Assert-True ($groundedArr.Count -gt 0) 'E1: grounding gate returned at least one result'
if ($groundedArr.Count -gt 0) {
    Assert-True ($groundedArr[0].severity -eq 'critical') "E2: severity normalized from 'Critical' to 'critical'"
}
Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Results: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
