# tools/test-adversarial-floor.ps1 — unit+stress tests for concurrency floor telemetry
#Requires -Version 5.1

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

# Dot-source dependencies
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\parallel.ps1')
. (Join-Path $root 'tools\adversarial-audit.ps1')

$pass = 0
$fail = 0

function Assert-Equal {
    param([string]$Label, $Got, $Expected)
    if ($Got -eq $Expected) {
        Write-Host "PASS: $Label"
        $script:pass++
    } else {
        Write-Host "FAIL: $Label — expected '$Expected' got '$Got'"
        $script:fail++
    }
}

# ── 1. Get-AuditConcurrencyFloor ──────────────────────────────────────────────

$r1 = Get-AuditConcurrencyFloor
Assert-Equal 'Floor default = 20' $r1 20

$cfg = [pscustomobject]@{
    audit = [pscustomobject]@{
        adversarial = [pscustomobject]@{ concurrencyFloor = 8 }
    }
}
$r2 = Get-AuditConcurrencyFloor -Config $cfg
Assert-Equal 'Floor from config = 8' $r2 8

# ── 2. Test-AuditFloorMet ─────────────────────────────────────────────────────

# Peak=20, Jobs=24, Floor=20 -> true (Peak >= Floor)
$r3 = Test-AuditFloorMet -Peak 20 -JobsDispatched 24 -Floor 20
Assert-Equal 'FloorMet Peak=20,Jobs=24,Floor=20 -> true' $r3 $true

# Peak=12, Jobs=24, Floor=20 -> false
$r4 = Test-AuditFloorMet -Peak 12 -JobsDispatched 24 -Floor 20
Assert-Equal 'FloorMet Peak=12,Jobs=24,Floor=20 -> false' $r4 $false

# Peak=3, Jobs=3, Floor=20 -> true (all 3 ran concurrently; Jobs<Floor)
$r5 = Test-AuditFloorMet -Peak 3 -JobsDispatched 3 -Floor 20
Assert-Equal 'FloorMet Peak=3,Jobs=3,Floor=20 -> true (all ran)' $r5 $true

# Peak=2, Jobs=3, Floor=20 -> false (not all ran concurrently)
$r6 = Test-AuditFloorMet -Peak 2 -JobsDispatched 3 -Floor 20
Assert-Equal 'FloorMet Peak=2,Jobs=3,Floor=20 -> false' $r6 $false

# ── 3. Pool stress test ───────────────────────────────────────────────────────

Write-Host ""
Write-Host "Pool stress: dispatching 20 dummy jobs..."

Clear-ReadOnlyAuditPoolRegistry | Out-Null
Reset-ReadOnlyAuditPoolTimeline
$powershellExe = (Get-Command powershell.exe -ErrorAction Stop).Source

$dummyScript = @"
Start-Sleep -Milliseconds 300
"@
$dummyPath = Join-Path ([System.IO.Path]::GetTempPath()) ("floor-dummy-" + [guid]::NewGuid().ToString('N') + '.ps1')
Set-Content -Path $dummyPath -Value $dummyScript -Encoding UTF8

$jobCount = 20
for ($i = 0; $i -lt $jobCount; $i++) {
    Start-ReadOnlyAuditJob `
        -FilePath $powershellExe `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $dummyPath) `
        -WorkingDirectory ([System.IO.Path]::GetTempPath()) `
        -InputText $null `
        -Metadata @{ index = $i } | Out-Null
}

Wait-ReadOnlyAuditPoolDrain

try { Remove-Item -LiteralPath $dummyPath -Force -ErrorAction SilentlyContinue } catch {}

$tl = Get-ReadOnlyAuditPoolTimeline

Write-Host "Pool timeline: peak=$($tl.peak) samples=$($tl.count)"

if ($tl.peak -ge 15) {
    Write-Host "PASS: pool stress peak >= 15 (got $($tl.peak))"
    $pass++
} else {
    Write-Host "FAIL: pool stress peak < 15 (got $($tl.peak))"
    $fail++
}

$floorMetResult = Test-AuditFloorMet -Peak ([int]$tl.peak) -JobsDispatched $jobCount -Floor $jobCount
if ($tl.peak -ge $jobCount) {
    Assert-Equal "FloorMet with stress peak=$($tl.peak),Jobs=$jobCount,Floor=$jobCount -> true" $floorMetResult $true
} else {
    # Peak < Jobs -> floor_met = (Peak >= Jobs) = false — correct
    Assert-Equal "FloorMet with stress peak=$($tl.peak),Jobs=$jobCount,Floor=$jobCount reflects correctly" $floorMetResult $false
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "Results: $pass PASS / $fail FAIL"
if ($fail -gt 0) { exit 1 }
