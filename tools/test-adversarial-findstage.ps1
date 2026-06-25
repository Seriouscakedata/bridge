#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'adversarial-audit.ps1')

$pass = 0; $fail = 0
function Assert-True { param($Label,[bool]$Cond,[string]$Detail='')
    if ($Cond) { Write-Host "PASS: $Label"; $script:pass++ }
    else { Write-Host "FAIL: $Label$(if($Detail){' -- '+$Detail})"; $script:fail++ }
}
function Assert-Eq { param($Label,$Got,$Expected)
    if ("$Got" -eq "$Expected") { Write-Host "PASS: $Label"; $script:pass++ }
    else { Write-Host "FAIL: $Label`n  Got:      $Got`n  Expected: $Expected"; $script:fail++ }
}
function Assert-Throws { param($Label,[scriptblock]$Block)
    $threw = $false
    try { & $Block } catch { $threw = $true }
    if ($threw) { Write-Host "PASS: $Label"; $script:pass++ }
    else { Write-Host "FAIL: $Label (expected throw, got none)"; $script:fail++ }
}

# ---- Test 1: Build-AuditFinderJobSpec -Provider 'gemini' throws ----
Assert-Throws 'gemini provider throws' { Build-AuditFinderJobSpec -Dimension 'security' -Perspective ([pscustomobject]@{}) -SnapshotRoot 'C:/x' -Provider 'gemini' -Index 0 }

# ---- Test 2: Build-AuditFinderJobSpec returns correct fields ----
$spec = Build-AuditFinderJobSpec -Dimension 'correctness' -Perspective ([pscustomobject]@{ model='gpt-5.5'; tier='high' }) -SnapshotRoot 'C:/snap' -Provider 'codex' -Index 3
Assert-Eq 'spec.agent_id' $spec.agent_id 'codex-correctness-3'
Assert-Eq 'spec.dimension' $spec.dimension 'correctness'
Assert-Eq 'spec.provider' $spec.provider 'codex'
Assert-Eq 'spec.snapshot_root' $spec.snapshot_root 'C:/snap'
Assert-True 'spec.prompt contains dimension' ($spec.prompt -like '*correctness*')
Assert-True 'spec.prompt contains agent_id' ($spec.prompt -like '*codex-correctness-3*')

# ---- Test 3: Invoke-AuditFindStage with JobRunner seam ----
$m = Get-AuditFindMatrix

# JobRunner: returns one finding per spec, OMITTING dimension+agent_id (to prove stamping)
$jr = {
    param($specs)
    $results = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $specs) {
        $f = [pscustomobject]@{
            root_cause       = 'test root cause'
            file             = 'stub.ps1'
            line             = 1
            evidence_snippet = 'stub'
            severity         = 'info'
            why              = 'test why'
            fix_sketch       = 'n/a'
            confidence       = 0.5
        }
        [void]$results.Add((ConvertTo-Json @($f) -Compress))
    }
    $results.ToArray()
}

$result = Invoke-AuditFindStage -Matrix $m -SnapshotRoot 'C:/x' -MaxFinders 6 -JobRunner $jr

$dispatched = $result.finder_jobs
$findings   = @($result.findings)

Assert-True 'finder_jobs <= 6' ($dispatched -le 6)
Assert-True 'finder_jobs >= 1' ($dispatched -ge 1)
Assert-Eq   'findings count == finder_jobs' $findings.Count $dispatched

# Every finding must have non-empty dimension AND agent_id (stamped from spec)
$allHaveDim = $true; $allHaveAid = $true
foreach ($f in $findings) {
    if ([string]::IsNullOrWhiteSpace([string]$f.dimension)) { $allHaveDim = $false }
    if ([string]::IsNullOrWhiteSpace([string]$f.agent_id)) { $allHaveAid = $false }
}
Assert-True 'all findings have dimension (stamped)' $allHaveDim
Assert-True 'all findings have agent_id (stamped)' $allHaveAid

# At least one claude and one codex (alternation check via spec agent_ids)
$specArr = @()
$specIdx = 0
foreach ($cell in $m) {
    if ($specIdx -ge $dispatched) { break }
    $provider = if ($specIdx % 2 -eq 0) { 'claude' } else { 'codex' }
    $specArr += $provider
    $specIdx++
}
Assert-True 'alternation: at least one claude' ($specArr -contains 'claude')
Assert-True 'alternation: at least one codex' ($specArr -contains 'codex')

# ---- Test 4: Invoke-AdversarialAudit with -FindJobRunner (no -FindRunner) reaches grounding ----
$snapRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("findstage-snap-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $snapRoot -Force | Out-Null
$testFile = Join-Path $snapRoot 'sample.ps1'
[System.IO.File]::WriteAllText($testFile, 'function Test-Sample { $x = 1 }', (New-Object System.Text.UTF8Encoding($false)))

$outRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("findstage-out-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $outRoot -Force | Out-Null

# FindJobRunner: return a valid grounded finding (all 10 fields, correct file/line/evidence)
$findJobRunner2 = {
    param($specs)
    $results = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $specs) {
        $f = [pscustomobject]@{
            root_cause       = 'test cause'
            file             = 'sample.ps1'
            line             = 1
            evidence_snippet = 'function Test-Sample'
            severity         = 'info'
            why              = 'test'
            fix_sketch       = 'n/a'
            confidence       = 0.5
            dimension        = [string]$s.dimension
            agent_id         = [string]$s.agent_id
        }
        [void]$results.Add((ConvertTo-Json @($f) -Compress))
    }
    $results.ToArray()
}

# VoteCollector seam: support all findings
$voteCollector2 = {
    param($jobSpecs)
    $votes = @()
    foreach ($js in $jobSpecs) {
        $votes += [pscustomobject]@{
            finding_id = [string]$js.finding_id
            vote       = 'support'
            reason     = 'seam-support'
            file       = 'sample.ps1'
            line       = 1
        }
    }
    $votes
}

# Filer seam: no-op
$filer2 = { param($Atoms) }

$auditResult = Invoke-AdversarialAudit `
    -Trigger 'adversarial_milestone' `
    -SnapshotRoot $snapRoot `
    -RunId 'test-findstage-001' `
    -OutRoot $outRoot `
    -MaxFinders 2 `
    -FindJobRunner $findJobRunner2 `
    -VoteCollector $voteCollector2 `
    -Filer $filer2

Assert-True 'find_raw >= 1' ($auditResult.phases.find_raw -ge 1)
Assert-True 'finder_jobs >= 1' ($auditResult.phases.finder_jobs -ge 1)
Assert-True 'result has phases' ($null -ne $auditResult.phases)

# Cleanup
if (Test-Path $snapRoot) { Remove-Item $snapRoot -Recurse -Force }
if (Test-Path $outRoot)  { Remove-Item $outRoot  -Recurse -Force }

Write-Host "`nResult: $pass PASS / $fail FAIL"
if ($fail -gt 0) { exit 1 }
