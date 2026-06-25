#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'adversarial-audit.ps1')

$pass = 0; $fail = 0

function Assert-True {
    param([bool]$Cond, [string]$Name)
    if ($Cond) { Write-Host "PASS $Name"; $script:pass++ }
    else       { Write-Host "FAIL $Name"; $script:fail++ }
}

# --- Matrix tests ---
$matrix = Get-AuditFindMatrix
Assert-True ($matrix.Count -eq 30)       'matrix-count-30'
Assert-True ($matrix.Count -ge 20)       'matrix-count-ge-20'

$defaultDims = @('correctness','security','concurrency','error-handling','resources','contracts','observability','state-persistence','scheduler-driver-flow','audit-backlog-flow')
$allHaveAgentId = ($matrix | Where-Object { -not $_.agent_id }) -eq $null
Assert-True $allHaveAgentId              'matrix-agent-ids-nonempty'
$allDimsValid = ($matrix | Where-Object { $_.dimension -notin $defaultDims }) -eq $null
Assert-True $allDimsValid                'matrix-dims-valid'

# --- Schema tests ---
$validFinding = [pscustomobject]@{
    root_cause       = 'null deref'
    file             = 'lib/foo.ps1'
    line             = 5
    evidence_snippet = 'foo = $null'
    severity         = 'high'
    why              = 'crashes on empty input'
    fix_sketch       = 'add null check'
    confidence       = 0.9
    dimension        = 'correctness'
    agent_id         = 'find-correctness-codex-medium'
}
$r1 = Test-AuditFinderSchema -Obj $validFinding
Assert-True ($r1.valid -eq $true)        'schema-valid-complete'

$noFile = $validFinding.PSObject.Copy()
$noFile.PSObject.Properties.Remove('file')
$r2 = Test-AuditFinderSchema -Obj $noFile
Assert-True ($r2.valid -eq $false)       'schema-missing-file-invalid'
Assert-True ('file' -in $r2.missing)     'schema-missing-file-in-missing'

$badSev = $validFinding.PSObject.Copy()
$badSev.severity = 'fatal'
$r3 = Test-AuditFinderSchema -Obj $badSev
Assert-True ($r3.valid -eq $false)       'schema-bad-severity-invalid'

# --- Output parser tests ---
$f1 = $validFinding
$f2 = [pscustomobject]@{
    root_cause       = 'race condition'
    file             = 'lib/bar.ps1'
    line             = 42
    evidence_snippet = 'parallel write'
    severity         = 'critical'
    why              = 'concurrent access'
    fix_sketch       = 'add lock'
    confidence       = 0.8
    dimension        = 'concurrency'
    agent_id         = 'find-concurrency-codex-high'
}
$jsonArr = @($f1, $f2) | ConvertTo-Json -Depth 5
$parsed = ConvertFrom-AuditFinderOutput -Text $jsonArr
Assert-True ($parsed.Count -eq 2)        'parser-array-2-valid'

$prose = "Here is the analysis result:`n" + ($f1 | ConvertTo-Json -Depth 5) + "`nEnd of analysis."
$parsed2 = ConvertFrom-AuditFinderOutput -Text $prose
Assert-True ($parsed2.Count -eq 1)       'parser-prose-object-1'

$parsed3 = ConvertFrom-AuditFinderOutput -Text 'garbage text no json here!!!'
Assert-True ($parsed3.Count -eq 0)       'parser-garbage-0'

Write-Host ""
Write-Host "Results: $pass passed, $fail failed"
if ($fail -gt 0) { exit 1 }
