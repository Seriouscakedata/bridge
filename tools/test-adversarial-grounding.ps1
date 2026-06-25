#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'adversarial-audit.ps1')

# --- Setup temp snapshot ---
$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) "audit-grounding-test-$([System.Diagnostics.Stopwatch]::GetTimestamp())"
New-Item -ItemType Directory -Path $tmpRoot | Out-Null

$subDir = Join-Path $tmpRoot 'src'
New-Item -ItemType Directory -Path $subDir | Out-Null

$testFile = Join-Path $subDir 'sample.ps1'
$fileContent = @(
    'function Get-Foo { param($x) }',
    'Write-Output "hello world"',
    '$result = Get-Foo -x 42',
    'if ($result -eq $null) { throw "err" }',
    'return $result'
)
Set-Content -Path $testFile -Value $fileContent -Encoding UTF8

$pass = 0
$fail = 0
function Assert([bool]$cond, [string]$msg) {
    if ($cond) { Write-Host "PASS: $msg"; $script:pass++ }
    else        { Write-Host "FAIL: $msg"; $script:fail++ }
}

# (a) valid: line=2, snippet = substring of line 2
$fA = [pscustomobject]@{
    file             = 'src/sample.ps1'
    line             = 2
    evidence_snippet = 'hello world'
    root_cause='x'; severity='low'; why='x'; fix_sketch='x'; confidence=0.5; dimension='x'; agent_id='x'
}

# (b) file-missing
$fB = [pscustomobject]@{
    file             = 'nope.txt'
    line             = 1
    evidence_snippet = 'anything'
    root_cause='x'; severity='low'; why='x'; fix_sketch='x'; confidence=0.5; dimension='x'; agent_id='x'
}

# (c) line-out-of-range
$fC = [pscustomobject]@{
    file             = 'src/sample.ps1'
    line             = 999
    evidence_snippet = 'hello world'
    root_cause='x'; severity='low'; why='x'; fix_sketch='x'; confidence=0.5; dimension='x'; agent_id='x'
}

# (d) evidence-mismatch: line=2 but wrong snippet
$fD = [pscustomobject]@{
    file             = 'src/sample.ps1'
    line             = 2
    evidence_snippet = 'totally unrelated zzz'
    root_cause='x'; severity='low'; why='x'; fix_sketch='x'; confidence=0.5; dimension='x'; agent_id='x'
}

$all = @($fA, $fB, $fC, $fD)
$tagged = Invoke-AuditGroundingGate -Findings $all -SnapshotRoot $tmpRoot

# Per-case assertions
Assert ($tagged[0].state -eq 'grounded')             '(a) valid -> state=grounded'
Assert ($tagged[0].grounding_reason -eq 'grounded')  '(a) valid -> reason=grounded'

Assert ($tagged[1].state -eq 'rejected_grounding')          '(b) file-missing -> state=rejected_grounding'
Assert ($tagged[1].grounding_reason -eq 'file-missing')      '(b) file-missing -> reason=file-missing'

Assert ($tagged[2].state -eq 'rejected_grounding')           '(c) line-out-of-range -> state=rejected_grounding'
Assert ($tagged[2].grounding_reason -eq 'line-out-of-range') '(c) line-out-of-range -> reason=line-out-of-range'

Assert ($tagged[3].state -eq 'rejected_grounding')            '(d) evidence-mismatch -> state=rejected_grounding'
Assert ($tagged[3].grounding_reason -eq 'evidence-mismatch')  '(d) evidence-mismatch -> reason=evidence-mismatch'

# Summary assertions
$summary = Get-AuditGroundingSummary -Findings $tagged
Assert ($summary.grounded -eq 1)           'summary: grounded=1'
Assert ($summary.rejected_grounding -eq 3) 'summary: rejected_grounding=3'

# Cleanup
Remove-Item -Recurse -Force $tmpRoot

Write-Host ""
if ($fail -eq 0) {
    Write-Host "ALL $pass TESTS PASSED"
} else {
    Write-Host "$fail FAILED, $pass passed"
    exit 1
}
