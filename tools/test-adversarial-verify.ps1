#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'adversarial-audit.ps1')

$pass = 0
$fail = 0
function Assert([bool]$cond, [string]$msg) {
    if ($cond) { Write-Host "PASS: $msg"; $script:pass++ }
    else        { Write-Host "FAIL: $msg"; $script:fail++ }
}

# --- Test-AuditSkepticSchema ---

# valid refute vote
$r1 = Test-AuditSkepticSchema -Obj ([pscustomobject]@{
    finding_id = 'f-001'
    vote       = 'refute'
    reason     = 'not reproducible'
})
Assert ($r1.valid -eq $true)          'schema: valid refute vote -> valid'
Assert ($r1.missing.Count -eq 0)      'schema: valid refute vote -> no missing fields'

# support without file -> invalid
$r2 = Test-AuditSkepticSchema -Obj ([pscustomobject]@{
    finding_id = 'f-002'
    vote       = 'support'
    reason     = 'confirmed'
    line       = 5
})
Assert ($r2.valid -eq $false)         'schema: support without file -> invalid'
Assert ('file' -in $r2.missing)       'schema: support without file -> missing=file'

# bad vote 'maybe' -> invalid
$r3 = Test-AuditSkepticSchema -Obj ([pscustomobject]@{
    finding_id = 'f-003'
    vote       = 'maybe'
    reason     = 'unsure'
})
Assert ($r3.valid -eq $false)         'schema: bad vote maybe -> invalid'
Assert ('vote' -in $r3.missing)       'schema: bad vote maybe -> missing=vote'

# valid support vote (with file + line)
$r4 = Test-AuditSkepticSchema -Obj ([pscustomobject]@{
    finding_id = 'f-004'
    vote       = 'support'
    reason     = 'line confirms issue'
    file       = 'src/foo.ps1'
    line       = 42
})
Assert ($r4.valid -eq $true)          'schema: valid support with file+line -> valid'

# --- Resolve-AuditFindingVerdict ---

$groundedFinding = [pscustomobject]@{ finding_id='f-001'; state='grounded' }

# helper: make a vote object
function MakeVote([string]$vote, [string]$fid='f-001') {
    $obj = [pscustomobject]@{
        finding_id = $fid
        vote       = $vote
        reason     = 'test reason'
    }
    if ($vote -eq 'support') {
        $obj | Add-Member -NotePropertyName 'file' -NotePropertyValue 'src/foo.ps1' -Force
        $obj | Add-Member -NotePropertyName 'line' -NotePropertyValue 10 -Force
    }
    $obj
}

# [refute, refute, support] -> 'refuted' (2 >= ceil(3/2)=2)
$v1 = Resolve-AuditFindingVerdict -Finding $groundedFinding -Votes @(
    (MakeVote 'refute'),
    (MakeVote 'refute'),
    (MakeVote 'support')
) -MinValidVotes 2
Assert ($v1.verdict -eq 'refuted')    'verdict: [refute,refute,support] -> refuted'
Assert ($v1.refute_count -eq 2)       'verdict: refute_count=2'
Assert ($v1.support_count -eq 1)      'verdict: support_count=1'

# [support, support, refute] -> 'confirmed' (refute 1 < 2; support>=1)
$v2 = Resolve-AuditFindingVerdict -Finding $groundedFinding -Votes @(
    (MakeVote 'support'),
    (MakeVote 'support'),
    (MakeVote 'refute')
) -MinValidVotes 2
Assert ($v2.verdict -eq 'confirmed')  'verdict: [support,support,refute] -> confirmed'

# 1 valid vote [support] -> 'unverified' (valid_count 1 < 2)
$v3 = Resolve-AuditFindingVerdict -Finding $groundedFinding -Votes @(
    (MakeVote 'support')
) -MinValidVotes 2
Assert ($v3.verdict -eq 'unverified') 'verdict: 1 valid vote -> unverified'
Assert ($v3.valid_count -eq 1)        'verdict: valid_count=1'

# 3 votes all 'abstain' -> 'unverified' (valid_count 0)
$v4 = Resolve-AuditFindingVerdict -Finding $groundedFinding -Votes @(
    [pscustomobject]@{ finding_id='f-001'; vote='abstain'; reason='no opinion' },
    [pscustomobject]@{ finding_id='f-001'; vote='abstain'; reason='no opinion' },
    [pscustomobject]@{ finding_id='f-001'; vote='abstain'; reason='no opinion' }
) -MinValidVotes 2
Assert ($v4.verdict -eq 'unverified') 'verdict: all abstain -> unverified'
Assert ($v4.valid_count -eq 0)        'verdict: valid_count=0'

# finding with state='rejected_grounding' + any votes -> 'rejected_grounding'
$rejFinding = [pscustomobject]@{ finding_id='f-999'; state='rejected_grounding' }
$v5 = Resolve-AuditFindingVerdict -Finding $rejFinding -Votes @(
    (MakeVote 'support' 'f-999')
) -MinValidVotes 2
Assert ($v5.verdict -eq 'rejected_grounding') 'verdict: rejected_grounding passthrough'

Write-Host ""
if ($fail -eq 0) {
    Write-Host "ALL $pass TESTS PASSED"
} else {
    Write-Host "$fail FAILED, $pass passed"
    exit 1
}