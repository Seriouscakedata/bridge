#Requires -Version 5.1
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'adversarial-audit.ps1')

$pass = 0
$fail = 0

function Assert-Eq {
    param(
        $Actual,
        $Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Actual -eq $Expected) {
        Write-Host "PASS: $Message"
        $script:pass++
    } else {
        Write-Host "FAIL: $Message (actual=$Actual expected=$Expected)"
        $script:fail++
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Condition) {
        Write-Host "PASS: $Message"
        $script:pass++
    } else {
        Write-Host "FAIL: $Message"
        $script:fail++
    }
}

$tempRoot = [System.IO.Path]::GetTempPath()
$snapDir = Join-Path $tempRoot ("adversarial-audit-snap-" + [guid]::NewGuid().ToString('N'))
$outDir = Join-Path $tempRoot ("adversarial-audit-out-" + [guid]::NewGuid().ToString('N'))

$null = New-Item -ItemType Directory -Path $snapDir -Force
$null = New-Item -ItemType Directory -Path $outDir -Force

$samplePath = Join-Path $snapDir 'sample.ps1'
$sampleText = @'
# sample bridge audit test fixture
param([string]$Name = 'world')
Write-Host "Hello, $Name"
$result = Get-Date
return $result
'@
$lines = $sampleText.Trim() -split "`r?`n"
Set-Content -LiteralPath $samplePath -Value $lines -Encoding UTF8

$findRunner = {
    param($matrix, $snapshotRoot)
    $fg = [pscustomobject]@{ finding_id='f-good'; root_cause='write-host-in-script'; file='sample.ps1'; line=3; evidence_snippet='Write-Host'; severity='high'; why='Write-Host in non-debug code'; fix_sketch='use Write-Verbose'; confidence=0.9; dimension='correctness'; agent_id='agent-good'; category='style' }
    $fb = [pscustomobject]@{ finding_id='f-bad';  root_cause='unused-date';         file='sample.ps1'; line=4; evidence_snippet='Get-Date';   severity='low';  why='Unused date variable';         fix_sketch='remove assignment';   confidence=0.7; dimension='security';    agent_id='agent-bad';  category='perf' }
    return @($fg, $fb)
}

$voteCollector = {
    param($jobSpecs)
    $votes = [System.Collections.Generic.List[object]]::new()
    foreach ($spec in $jobSpecs) {
        $fid = [string]$spec.finding_id
        $idx = [int]$spec.index % 3
        $vc  = if ($fid -eq 'f-good') { @('support','support','refute')[$idx] } `
               elseif ($fid -eq 'f-bad') { @('refute','refute','support')[$idx] } `
               else { 'abstain' }
        $ln  = if ($fid -eq 'f-good') { 3 } else { 4 }
        [void]$votes.Add([pscustomobject]@{ finding_id=$fid; vote=$vc; reason='synthetic-vote'; file='sample.ps1'; line=$ln })
    }
    $votes.ToArray()
}

$script:filedAtoms = [System.Collections.Generic.List[object]]::new()
$filerBlock = { param($atom) [void]$script:filedAtoms.Add($atom) }

try {
    Write-Host "=== Test 1: Main e2e run ==="
    $r = Invoke-AdversarialAudit -Trigger 'operator' -SnapshotRoot $snapDir -RunId 'e2e-1' -OutRoot $outDir -FindRunner $findRunner -VoteCollector $voteCollector -Filer $filerBlock
    Assert-Eq $r.phases.find_raw 2 'find_raw==2'
    Assert-Eq $r.phases.grounded 2 'grounded==2'
    Assert-Eq $r.phases.verify.confirmed 1 'verify.confirmed==1'
    Assert-Eq $r.phases.verify.refuted 1 'verify.refuted==1'
    Assert-Eq $r.phases.synth.confirmed_after_dedup 1 'synth.confirmed_after_dedup==1'
    Assert-Eq $r.phases.filed.filed 1 'filed.filed==1'
    Assert-True (Test-Path -LiteralPath $r.report_json_path -PathType Leaf) 'report_json_path exists'

    $fp = [string]$script:filedAtoms[0].audit_fingerprint

    Write-Host "=== Test 2: Idempotency ==="
    $script:filedAtoms = [System.Collections.Generic.List[object]]::new()
    $r2 = Invoke-AdversarialAudit -Trigger 'operator' -SnapshotRoot $snapDir -RunId 'e2e-1' -OutRoot $outDir -FindRunner $findRunner -VoteCollector $voteCollector -Filer $filerBlock -ExistingFingerprints @($fp)
    Assert-Eq $r2.phases.filed.filed 0 'idempotency: filed==0'
    Assert-Eq $r2.phases.filed.skipped 1 'idempotency: skipped==1'

    Write-Host "=== Test 3: Trigger separation ==="
    $threw = $false
    try {
        Invoke-AdversarialAudit -Trigger 'nightly_cron' -SnapshotRoot $snapDir -RunId 'e2e-3' -OutRoot $outDir -FindRunner $findRunner -VoteCollector $voteCollector -Filer $filerBlock
    } catch {
        $threw = $true
    }
    Assert-True $threw 'nightly_cron throws'
} finally {
    Remove-Item -Recurse -Force $snapDir, $outDir -ErrorAction SilentlyContinue
}

Write-Host "=== RESULT: $pass PASS, $fail FAIL ==="
if ($fail -gt 0) {
    exit 1
}
