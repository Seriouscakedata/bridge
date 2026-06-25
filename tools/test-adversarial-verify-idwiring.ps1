# test-adversarial-verify-idwiring.ps1
# NON-FIXTURE: verifies finding_id assignment and vote correlation without hand-injecting id.
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'adversarial-audit.ps1')

$pass = 0
$fail = 0

function Assert-Equal {
    param($Label, $Got, $Expected)
    if ($Got -eq $Expected) {
        Write-Host "PASS: $Label"
        $script:pass++
    } else {
        Write-Host "FAIL: $Label — expected '$Expected', got '$Got'"
        $script:fail++
    }
}
function Assert-True {
    param($Label, $Cond)
    if ($Cond) {
        Write-Host "PASS: $Label"
        $script:pass++
    } else {
        Write-Host "FAIL: $Label"
        $script:fail++
    }
}

# --- Setup temp snapshot with sample.ps1 (5 lines) ---
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "idwiring-test-$([System.IO.Path]::GetRandomFileName())"
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$sampleContent = "line1`nline2 alpha`nline3 beta gamma`nline4`nline5"
[System.IO.File]::WriteAllText((Join-Path $tmpDir 'sample.ps1'), $sampleContent, [System.Text.Encoding]::UTF8)

# --- Build 2 findings WITHOUT finding_id (as real finder schema produces) ---
$f1 = [pscustomobject]@{
    root_cause       = 'missing null check'
    file             = 'sample.ps1'
    line             = 2
    evidence_snippet = 'alpha'
    severity         = 'high'
    why              = 'causes NPE'
    fix_sketch       = 'add null check'
    confidence       = 0.9
    dimension        = 'correctness'
    agent_id         = 'a1'
}
$f2 = [pscustomobject]@{
    root_cause       = 'SQL injection risk'
    file             = 'sample.ps1'
    line             = 3
    evidence_snippet = 'beta gamma'
    severity         = 'low'
    why              = 'injection vector'
    fix_sketch       = 'use parameterized query'
    confidence       = 0.9
    dimension        = 'security'
    agent_id         = 'a2'
}
$f3 = [pscustomobject]@{
    root_cause       = 'abstain test'
    file             = 'sample.ps1'
    line             = 4
    evidence_snippet = 'line4'
    severity         = 'low'
    why              = 'test abstain counting'
    fix_sketch       = 'n/a'
    confidence       = 0.9
    dimension        = 'correctness'
    agent_id         = 'a3'
}

# --- Test: Invoke-AuditGroundingGate assigns finding_id ---
$grounded = Invoke-AuditGroundingGate -Findings @($f1,$f2,$f3) -SnapshotRoot $tmpDir

$g1 = $grounded[0]
$g2 = $grounded[1]
$g3 = $grounded[2]

Assert-True 'g1 has non-empty finding_id' (-not [string]::IsNullOrWhiteSpace([string]$g1.finding_id))
Assert-True 'g2 has non-empty finding_id' (-not [string]::IsNullOrWhiteSpace([string]$g2.finding_id))
Assert-True 'g1 and g2 finding_ids are different' (([string]$g1.finding_id) -ne ([string]$g2.finding_id))
Assert-Equal 'g1 is grounded' $g1.state 'grounded'
Assert-Equal 'g2 is grounded' $g2.state 'grounded'

# --- Test: Invoke-AuditVerifyStage vote correlation (confirms id wiring) ---
# VoteCollector reads finding_id from jobSpecs (proves real correlation, not hand-picked literal)
$id1 = [string]$g1.finding_id
$id2 = [string]$g2.finding_id

$collector = {
    param($jobSpecs)
    $votes = @()
    foreach ($spec in $jobSpecs) {
        $fid = [string]$spec.finding_id
        if ($fid -eq $id1) {
            # f1 -> [support, support, refute] => confirmed
            $voteVal = @('support','support','refute')[$spec.index % 3]
            $votes += [pscustomobject]@{ finding_id=$fid; vote=$voteVal; reason='test'; file='sample.ps1'; line=2 }
        } elseif ($fid -eq $id2) {
            # f2 -> [refute, refute, support] => refuted
            $voteVal = @('refute','refute','support')[$spec.index % 3]
            $votes += [pscustomobject]@{ finding_id=$fid; vote=$voteVal; reason='test'; file='sample.ps1'; line=3 }
        } else {
            # f3 -> votes handled separately, skip here (only grounded f1,f2 get skeptics)
            $votes += [pscustomobject]@{ finding_id=$fid; vote='abstain'; reason='test'; file='sample.ps1'; line=4 }
        }
    }
    return $votes
}

$results = Invoke-AuditVerifyStage -Findings @($g1,$g2) -SnapshotRoot $tmpDir -VoteCollector $collector -SkepticsPerFinding 3 -MinValidVotes 2

$r1 = $results | Where-Object { [string]$_.finding_id -eq $id1 }
$r2 = $results | Where-Object { [string]$_.finding_id -eq $id2 }

Assert-Equal 'f1 verdict is confirmed' ([string]$r1.verdict) 'confirmed'
Assert-Equal 'f2 verdict is refuted'  ([string]$r2.verdict) 'refuted'

# --- Test: abstain case — quorum.valid_count excludes abstains ---
$id3 = [string]$g3.finding_id
$collectorAbstain = {
    param($jobSpecs)
    $votes = @()
    foreach ($spec in $jobSpecs) {
        $fid = [string]$spec.finding_id
        $voteVal = @('support','abstain','abstain')[$spec.index % 3]
        $votes += [pscustomobject]@{ finding_id=$fid; vote=$voteVal; reason='test'; file='sample.ps1'; line=4 }
    }
    return $votes
}

$absResults = Invoke-AuditVerifyStage -Findings @($g3) -SnapshotRoot $tmpDir -VoteCollector $collectorAbstain -SkepticsPerFinding 3 -MinValidVotes 2

$r3 = $absResults | Where-Object { [string]$_.finding_id -eq $id3 }
Assert-Equal 'f3 verdict is unverified (abstains dont count)' ([string]$r3.verdict) 'unverified'
Assert-Equal 'f3 quorum.valid_count==1 (only non-abstain support)' ([int]$r3.quorum.valid_count) 1

# --- Cleanup ---
Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Results: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 } else { exit 0 }