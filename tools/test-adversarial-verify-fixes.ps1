#Requires -Version 5.1
<#
.SYNOPSIS
  Tests for adversarial-audit VERIFY-stage bug fixes #3, #4, #6.
#>

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$auditScript = Join-Path $scriptDir 'adversarial-audit.ps1'
. $auditScript

$pass = 0
$fail = 0

function Assert-Equal {
    param($Label, $Actual, $Expected)
    if ($Actual -eq $Expected) {
        Write-Host "PASS: $Label"
        $script:pass++
    } else {
        Write-Host "FAIL: $Label (expected=$Expected actual=$Actual)"
        $script:fail++
    }
}
function Assert-True {
    param($Label, $Value)
    if ($Value) {
        Write-Host "PASS: $Label"
        $script:pass++
    } else {
        Write-Host "FAIL: $Label (value was falsy: $Value)"
        $script:fail++
    }
}
function Assert-False {
    param($Label, $Value)
    if (-not $Value) {
        Write-Host "PASS: $Label"
        $script:pass++
    } else {
        Write-Host "FAIL: $Label (expected false, got: $Value)"
        $script:fail++
    }
}

# ─── TEST #4: Resolve-AuditJobVote ──────────────────────────────────────────

$v1 = [pscustomobject]@{ finding_id='F'; vote='support'; reason='ok'; file='a.ps1'; line=1 }
$v2 = [pscustomobject]@{ finding_id='F'; vote='support'; reason='also ok'; file='b.ps1'; line=2 }

# #4-a: two support objects -> returns exactly ONE object (the first)
$res = Resolve-AuditJobVote -Parsed @($v1, $v2) -FindingId 'F'
Assert-Equal '#4-a: two-support returns one' ($res.vote) 'support'
Assert-Equal '#4-a: two-support returns v1 reason' ($res.reason) 'ok'

# #4-b: empty parsed -> returns abstain with correct finding_id
$res = Resolve-AuditJobVote -Parsed @() -FindingId 'F'
Assert-Equal '#4-b: empty returns abstain vote' ($res.vote) 'abstain'
Assert-Equal '#4-b: empty returns correct finding_id' ($res.finding_id) 'F'
Assert-Equal '#4-b: empty reason is stdout-json-parse-failed' ($res.reason) 'stdout-json-parse-failed'

# #4-c: null parsed -> returns abstain
$res = Resolve-AuditJobVote -Parsed $null -FindingId 'F'
Assert-Equal '#4-c: null returns abstain' ($res.vote) 'abstain'

# #4-d: single object (not array) -> returns that object
$singleObj = [pscustomobject]@{ finding_id='F'; vote='refute'; reason='no'; file='c.ps1'; line=3 }
$res = Resolve-AuditJobVote -Parsed $singleObj -FindingId 'F'
Assert-Equal '#4-d: single object returns vote' ($res.vote) 'refute'

# ─── TEST #6: Build-AuditSkepticJobSpec uses root_cause/why/evidence ────────

$f6 = [pscustomobject]@{
    finding_id      = 'F6'
    file            = 'test.ps1'
    line            = 10
    dimension       = 'correctness'
    agent_id        = 'test-agent'
    root_cause      = 'NULL deref bug'
    why             = 'pointer never checked'
    evidence_snippet= 'line 10: $x.Count'
    state           = 'grounded'
    severity        = 'high'
}
# NO 'description' field on $f6

$spec = Build-AuditSkepticJobSpec -Finding $f6 -SnapshotRoot 'C:/x' -Provider 'claude' -Index 0
Assert-True  '#6-a: prompt contains root_cause text' ($spec.prompt -match 'NULL deref bug')
Assert-False '#6-b: prompt does NOT contain description=.' ($spec.prompt -match 'description=\.')

# ─── TEST #3: Invoke-AdversarialAudit does NOT drop single finding ───────────

# Temp snapshot directory with sample.ps1
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("audit-test-" + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmpRoot -Force
$null = New-Item -ItemType Directory -Path (Join-Path $tmpRoot '.bridge') -Force
$samplePs1 = Join-Path $tmpRoot 'sample.ps1'
Set-Content -LiteralPath $samplePs1 -Value '# sample' -Encoding UTF8

# Single schema-complete finding (NO finding_id — orchestrator must assign one)
$singleFinding = [pscustomobject]@{
    dimension        = 'correctness'
    agent_id         = 'test-finder'
    root_cause       = 'Test root cause'
    why              = 'Test why'
    evidence_snippet = 'line 1: # sample'
    file             = 'sample.ps1'
    line             = 1
    severity         = 'high'
    confidence       = 1.0
}

# FindRunner returns exactly ONE finding
$findRunner = {
    param($SnapshotRoot, $RunId, $Dimensions, $AgentIds, $MaxFindingsPerAgent)
    return @($singleFinding)
}

# VoteCollector echoes finding_id with [support, support, refute] — quorum passes (2 support)
$voteCollector = {
    param($JobSpecs)
    $votes = @()
    foreach ($js in $JobSpecs) {
        $voteVal = if ($votes.Count -lt 2) { 'support' } else { 'refute' }
        $votes += [pscustomobject]@{
            finding_id = $js.finding_id
            vote       = $voteVal
            reason     = 'test'
            file       = $js.snapshot_root
            line       = 0
        }
    }
    return $votes
}

$outRoot = Join-Path $tmpRoot 'out'
$null = New-Item -ItemType Directory -Path $outRoot -Force

try {
    $result = Invoke-AdversarialAudit `
        -Trigger 'operator' `
        -SnapshotRoot $tmpRoot `
        -RunId 'test-run-001' `
        -OutRoot $outRoot `
        -FindRunner $findRunner `
        -VoteCollector $voteCollector `
        -SkepticsPerFinding 3 `
        -MinValidVotes 2

    Assert-Equal '#3-a: confirmed_after_dedup==1' ($result.phases.synth.confirmed_after_dedup) 1
    Assert-Equal '#3-b: filed.filed==1' ($result.phases.filed.filed) 1
    Assert-True  '#3-c: report_json_path exists' (Test-Path $result.report_json_path)
} catch {
    Write-Host "FAIL: #3 threw exception: $_"
    $script:fail++
} finally {
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
}

# ─── SUMMARY ────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Results: $pass PASS / $fail FAIL"
if ($fail -gt 0) { exit 1 } else { exit 0 }