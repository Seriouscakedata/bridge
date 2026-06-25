#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# dot-source implementation
$auditScript = Join-Path $PSScriptRoot 'adversarial-audit.ps1'
. $auditScript

$pass = 0; $fail = 0
function Assert-Equal {
    param([string]$Name, $Got, $Expected)
    if ($Got -eq $Expected) {
        Write-Host "  PASS $Name"
        $script:pass++
    } else {
        Write-Host ("  FAIL {0}: expected={1} got={2}" -f $Name, $Expected, $Got)
        $script:fail++
    }
}

# Build findings:
# F1, F2: same file+category+evidence_snippet; F1 severity=medium, F2 severity=high -> dedup keeps F2
# F3: confirmed, different file
# F4: refuted; F5: unverified; F6: rejected_grounding
$sharedSnippet = 'foo bar  baz'  # has whitespace runs -> normalized to "foo bar baz"

$F1 = [pscustomobject]@{ finding_id='f1'; file='src/app.ps1'; category='sql-injection'; evidence_snippet=$sharedSnippet; severity='medium'; verdict='confirmed'; line=10 }
$F2 = [pscustomobject]@{ finding_id='f2'; file='src/app.ps1'; category='sql-injection'; evidence_snippet=$sharedSnippet; severity='high';   verdict='confirmed'; line=10 }
$F3 = [pscustomobject]@{ finding_id='f3'; file='src/other.ps1'; category='xss';          evidence_snippet='other evidence'; severity='low'; verdict='confirmed'; line=20 }
$F4 = [pscustomobject]@{ finding_id='f4'; file='src/app.ps1'; category='info-leak';      evidence_snippet='leak here';      severity='low'; verdict='refuted';   line=5 }
$F5 = [pscustomobject]@{ finding_id='f5'; file='src/app.ps1'; category='auth-bypass';    evidence_snippet='bypass me';      severity='medium'; verdict='unverified'; line=30 }
$F6 = [pscustomobject]@{ finding_id='f6'; file='src/app.ps1'; category='rce';            evidence_snippet='exec here';      severity='critical'; verdict='rejected_grounding'; line=50 }

$findings = @($F1, $F2, $F3, $F4, $F5, $F6)

# Test structural key dedup: F1 and F2 must produce the same key
$k1 = Get-AuditFindingStructuralKey -Finding $F1
$k2 = Get-AuditFindingStructuralKey -Finding $F2
$k3 = Get-AuditFindingStructuralKey -Finding $F3
Assert-Equal 'F1 and F2 same key' ($k1 -eq $k2) $true
Assert-Equal 'F3 key differs from F1' ($k3 -ne $k1) $true

# Run synthesize
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('audit-synth-test-' + [guid]::NewGuid().ToString('N'))
$runId    = 'test-run-001'
$telemetry = [pscustomobject]@{ peak_concurrency = 4 }

$result = Invoke-AuditSynthesize -Findings $findings -RunId $runId -OutRoot $tempRoot -Telemetry $telemetry

# Count assertions
Assert-Equal 'counts.confirmed==3'             $result.counts.confirmed              3
Assert-Equal 'counts.confirmed_after_dedup==2' $result.counts.confirmed_after_dedup  2
Assert-Equal 'counts.refuted==1'               $result.counts.refuted                1
Assert-Equal 'counts.unverified==1'            $result.counts.unverified             1
Assert-Equal 'counts.rejected_grounding==1'    $result.counts.rejected_grounding     1

# Files exist
Assert-Equal 'report.json exists' (Test-Path -LiteralPath $result.report_json_path -PathType Leaf) $true
Assert-Equal 'report.md exists'   (Test-Path -LiteralPath $result.report_md_path -PathType Leaf)   $true

# JSON parses and confirmed_deduped length==2
$json = Get-Content -Path $result.report_json_path -Raw | ConvertFrom-Json
Assert-Equal 'json.confirmed_deduped.Count==2' @($json.confirmed_deduped).Count 2

# Kept duplicate is the higher-severity one (F2 high, not F1 medium)
$keptSevs = @($result.confirmed_deduped | Where-Object { $_.finding_id -eq 'f2' }).Count
Assert-Equal 'kept finding is f2 (high severity)' $keptSevs 1
$notKeptSevs = @($result.confirmed_deduped | Where-Object { $_.finding_id -eq 'f1' }).Count
Assert-Equal 'f1 (medium) not in deduped' $notKeptSevs 0

# Cleanup
Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Results: $pass PASS, $fail FAIL"
if ($fail -gt 0) { exit 1 }
