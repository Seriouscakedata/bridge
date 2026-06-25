# UTF-8 BOM required
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\adversarial-audit.ps1"

$pass = 0
$fail = 0

function Assert-Eq {
    param($Label, $Got, $Expected)
    if ($Got -eq $Expected) {
        Write-Host "PASS: $Label"
        $script:pass++
    }
    else {
        Write-Host "FAIL: $Label (expected '$Expected', got '$Got')"
        $script:fail++
    }
}

# 3 grounded + 1 rejected_grounding findings
$findings = @(
    [pscustomobject]@{ finding_id='F1'; state='grounded'; file='foo.ps1'; line=10; description='bug1'; evidence_snippet='x' },
    [pscustomobject]@{ finding_id='F2'; state='grounded'; file='foo.ps1'; line=20; description='bug2'; evidence_snippet='y' },
    [pscustomobject]@{ finding_id='F3'; state='grounded'; file='foo.ps1'; line=30; description='bug3'; evidence_snippet='z' },
    [pscustomobject]@{ finding_id='F4'; state='rejected_grounding'; file='bar.ps1'; line=5; description='bug4'; evidence_snippet='w' }
)

$voteMap = @{
    'F1' = @(
        [pscustomobject]@{ finding_id='F1'; vote='refute'; reason='r1'; file='foo.ps1'; line=10 },
        [pscustomobject]@{ finding_id='F1'; vote='refute'; reason='r2'; file='foo.ps1'; line=10 },
        [pscustomobject]@{ finding_id='F1'; vote='support'; reason='r3'; file='foo.ps1'; line=10 }
    )
    'F2' = @(
        [pscustomobject]@{ finding_id='F2'; vote='support'; reason='r4'; file='foo.ps1'; line=20 },
        [pscustomobject]@{ finding_id='F2'; vote='support'; reason='r5'; file='foo.ps1'; line=20 },
        [pscustomobject]@{ finding_id='F2'; vote='refute'; reason='r6'; file='foo.ps1'; line=20 }
    )
    'F3' = @(
        [pscustomobject]@{ finding_id='F3'; vote='support'; reason='r7'; file='foo.ps1'; line=30 }
    )
}

$collector = {
    param($JobSpecs)
    $seen = @{}
    $allVotes = @()
    foreach ($spec in $JobSpecs) {
        $fid = $spec.finding_id
        if (-not $seen[$fid] -and $voteMap.ContainsKey($fid)) {
            $allVotes += $voteMap[$fid]
            $seen[$fid] = $true
        }
    }
    $allVotes
}

$_verifyResult = Invoke-AuditVerifyStage -Findings $findings -SnapshotRoot 'C:\fake\snapshot' -SkepticsPerFinding 3 -MinValidVotes 2 -VoteCollector $collector
$results = @($_verifyResult.findings)

Assert-Eq 'F1 verdict: refuted'            ($results | Where-Object { $_.finding_id -eq 'F1' } | Select-Object -First 1).verdict 'refuted'
Assert-Eq 'F2 verdict: confirmed'          ($results | Where-Object { $_.finding_id -eq 'F2' } | Select-Object -First 1).verdict 'confirmed'
Assert-Eq 'F3 verdict: unverified'         ($results | Where-Object { $_.finding_id -eq 'F3' } | Select-Object -First 1).verdict 'unverified'
Assert-Eq 'F4 verdict: rejected_grounding' ($results | Where-Object { $_.finding_id -eq 'F4' } | Select-Object -First 1).verdict 'rejected_grounding'
Assert-Eq 'F1 quorum.skeptics_requested=3' ($results | Where-Object { $_.finding_id -eq 'F1' } | Select-Object -First 1).quorum.skeptics_requested 3
Assert-Eq 'F2 quorum.skeptics_requested=3' ($results | Where-Object { $_.finding_id -eq 'F2' } | Select-Object -First 1).quorum.skeptics_requested 3
Assert-Eq 'F3 quorum.skeptics_requested=3' ($results | Where-Object { $_.finding_id -eq 'F3' } | Select-Object -First 1).quorum.skeptics_requested 3
Assert-Eq 'F4 quorum.skeptics_requested=0' ($results | Where-Object { $_.finding_id -eq 'F4' } | Select-Object -First 1).quorum.skeptics_requested 0

$summary = Get-AuditVerifySummary -Findings $results
Assert-Eq 'summary.confirmed=1'          $summary.confirmed 1
Assert-Eq 'summary.refuted=1'            $summary.refuted 1
Assert-Eq 'summary.unverified=1'         $summary.unverified 1
Assert-Eq 'summary.rejected_grounding=1' $summary.rejected_grounding 1

Write-Host ""
Write-Host "Results: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 }
Write-Host "ALL TESTS PASSED"
