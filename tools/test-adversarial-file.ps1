# test-adversarial-file.ps1 -- Phase 5 filing tests: idempotency + control-plane gate
[CmdletBinding()]param()
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$root\adversarial-audit.ps1"

$pass = 0
$fail = 0

function Assert-Equal {
    param([string]$Label, $Got, $Expected)
    if ($Got -eq $Expected) {
        Write-Host "PASS: $Label"
        $script:pass++
    } else {
        Write-Host "FAIL: $Label -- expected '$Expected' got '$Got'"
        $script:fail++
    }
}

function Assert-True {
    param([string]$Label, [bool]$Cond)
    if ($Cond) {
        Write-Host "PASS: $Label"
        $script:pass++
    } else {
        Write-Host "FAIL: $Label"
        $script:fail++
    }
}

function Assert-Throws {
    param([string]$Label, [scriptblock]$Body)
    try {
        & $Body
        Write-Host "FAIL: $Label -- expected exception"
        $script:fail++
    } catch {
        Write-Host "PASS: $Label"
        $script:pass++
    }
}

# --- Build 2 confirmed findings with distinct fingerprints ---
$f1 = [pscustomobject]@{
    verdict          = 'confirmed'
    file             = 'lib/foo.ps1'
    line             = 10
    category         = 'null-ref'
    evidence_snippet = 'if ($x -eq $null)'
    severity         = 'high'
}
$f2 = [pscustomobject]@{
    verdict          = 'confirmed'
    file             = 'lib/bar.ps1'
    line             = 42
    category         = 'unhandled-exception'
    evidence_snippet = 'catch { }'
    severity         = 'medium'
}

# Test 1: First call — 2 findings filed, 0 skipped
$filedAtoms = [System.Collections.Generic.List[object]]::new()
$fakeFiler = { param($atom) [void]$script:filedAtoms.Add($atom) }

$r1 = Invoke-AuditFileConfirmed -ConfirmedFindings @($f1, $f2) -RunId 'run-test-001' -Filer $fakeFiler
Assert-Equal 'call1: counts.filed'   $r1.counts.filed   2
Assert-Equal 'call1: counts.skipped' $r1.counts.skipped 0

# Collect fingerprints from call 1
$fps1 = @($r1.filed | ForEach-Object { $_.audit_fingerprint })
Assert-Equal 'call1: 2 fingerprints collected' $fps1.Count 2

# Test 2: Second call with ExistingFingerprints — idempotent (0 filed, 2 skipped)
$filedAtoms2 = [System.Collections.Generic.List[object]]::new()
$fakeFiler2  = { param($atom) [void]$script:filedAtoms2.Add($atom) }

$r2 = Invoke-AuditFileConfirmed -ConfirmedFindings @($f1, $f2) -RunId 'run-test-002' `
      -ExistingFingerprints $fps1 -Filer $fakeFiler2
Assert-Equal 'call2: counts.filed'   $r2.counts.filed   0
Assert-Equal 'call2: counts.skipped' $r2.counts.skipped 2

# Test 3: Control-plane finding — Build-AuditFixAtom sets requires_admission + 'operator' tag
$fDriver = [pscustomobject]@{
    verdict          = 'confirmed'
    file             = 'driver.ps1'
    line             = 99
    category         = 'loop-risk'
    evidence_snippet = 'while ($true)'
    severity         = 'critical'
}
$atom = Build-AuditFixAtom -Finding $fDriver -RunId 'run-cp-test'
Assert-True  'cp: requires_admission=$true'   ([bool]$atom.requires_admission)
Assert-True  'cp: tags contains operator'     (($atom.tags -contains 'operator'))
Assert-True  'cp: tags contains audit'        (($atom.tags -contains 'audit'))

# Test 4: Unconfirmed finding cannot be filed through the confirmed-only gate
$fUnverified = [pscustomobject]@{
    verdict          = 'unverified'
    file             = 'lib/not-confirmed.ps1'
    line             = 7
    category         = 'candidate-only'
    evidence_snippet = 'maybe risky'
    severity         = 'low'
}
$filedAtoms3 = [System.Collections.Generic.List[object]]::new()
$fakeFiler3 = { param($atom) [void]$script:filedAtoms3.Add($atom) }
Assert-Throws 'policy: unconfirmed finding rejected' {
    Invoke-AuditFileConfirmed -ConfirmedFindings @($fUnverified) -RunId 'run-unconfirmed-test' -Filer $fakeFiler3 | Out-Null
}
Assert-Equal 'policy: unconfirmed not filed' $filedAtoms3.Count 0

Write-Host ""
Write-Host "Results: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 }
