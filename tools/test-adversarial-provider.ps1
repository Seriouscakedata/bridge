. (Join-Path $PSScriptRoot "adversarial-audit.ps1")

function Assert-True {
    param(
        [Parameter(Mandatory=$true)][bool]$Condition,
        [Parameter(Mandatory=$true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$snap = "C:\tmp\snap-test"
$prompt = 'audit this'

$spec = New-AuditCliJobSpec -Provider 'codex' -SnapshotRoot $snap -Prompt $prompt
Assert-True -Condition ($spec.filePath -eq 'codex') -Message "FAIL: filePath not codex"
Assert-True -Condition ($spec.inputText -eq $prompt) -Message "FAIL: codex inputText mismatch"
Assert-True -Condition ($spec.argumentList -contains '-s') -Message "FAIL: missing -s"
Assert-True -Condition ($spec.argumentList -contains 'read-only') -Message "FAIL: missing read-only"
$idx = [Array]::IndexOf([string[]]$spec.argumentList, '-C')
Assert-True -Condition ($idx -ge 0 -and $spec.argumentList[$idx + 1] -eq $snap) -Message "FAIL: -C <snapshot> missing"
Write-Host "PASS codex-spec"

$spec2 = New-AuditCliJobSpec -Provider 'claude' -SnapshotRoot $snap -Prompt $prompt
Assert-True -Condition ($spec2.filePath -eq 'claude') -Message "FAIL: filePath not claude"
Assert-True -Condition ($spec2.inputText -eq $prompt) -Message "FAIL: claude inputText mismatch"
$idxAT = [Array]::IndexOf([string[]]$spec2.argumentList, '--allowedTools')
Assert-True -Condition ($idxAT -ge 0 -and $spec2.argumentList[$idxAT + 1] -eq 'Read,Grep,Glob') -Message "FAIL: --allowedTools missing"
Write-Host "PASS claude-spec"

$caught = $false
try {
    $null = New-AuditCliJobSpec -Provider 'gemini' -SnapshotRoot $snap -Prompt 'x'
} catch {
    $caught = $true
}
Assert-True -Condition $caught -Message "FAIL: gemini should throw"
Write-Host "PASS gemini-disallowed"

$r1 = Get-AuditProviderErrorClass -ExitCode 0 -StdErr '' -StdOut ''
Assert-True -Condition ($r1 -eq 'ok') -Message "FAIL: expected ok, got $r1"
Write-Host "PASS error-class-ok"

$r2 = Get-AuditProviderErrorClass -ExitCode 1 -StdErr '429 rate limit exceeded'
Assert-True -Condition ($r2 -eq 'rate_limit') -Message "FAIL: expected rate_limit, got $r2"
Write-Host "PASS error-class-rate_limit"

$r3 = Get-AuditProviderErrorClass -ExitCode 124 -StdErr ''
Assert-True -Condition ($r3 -eq 'timeout') -Message "FAIL: expected timeout, got $r3"
Write-Host "PASS error-class-timeout"

$r4 = Get-AuditProviderErrorClass -ExitCode 1 -StdErr 'Unauthorized'
Assert-True -Condition ($r4 -eq 'auth') -Message "FAIL: expected auth, got $r4"
Write-Host "PASS error-class-auth"
