$env:POSTMORTEM_TEST = '1'
$root = 'C:\Users\rafie\OneDrive\Documents\bridge'
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\postmortem.ps1')
$fakeState = [pscustomobject]@{
    task_last_failure = [pscustomobject]@{ kind='smoke_failed'; text='Test error X4'; ts='2026-05-28T10:00:00Z' }
    current_channel = 'main'
}
$sha = (git -C $root log -1 --format='%H').Trim()
$sha8 = $sha.Substring(0,8)
$outFile = Join-Path $root "decisions\post-mortem-$sha8.md"
if (Test-Path $outFile) { Remove-Item $outFile -Force }
Write-Host "SHA: $sha"
$result = Invoke-PostMortem -CommitSha $sha -State $fakeState -RepoRoot $root -TimeoutSec 30
Write-Host "Result: $result"
if ($result -and (Test-Path $result)) {
    Write-Host 'FILE_EXISTS=True'
    $bytes = [System.IO.File]::ReadAllBytes($result)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    Write-Host "MD_BOM=$hasBom"
    $content = [System.IO.File]::ReadAllText($result, [System.Text.Encoding]::UTF8)
    Write-Host ($content.Substring(0, [Math]::Min(700, $content.Length)))
    # Check ledger
    $ledger = Join-Path $root 'decisions\session-ledger.jsonl'
    if (Test-Path $ledger) {
        $lines = [System.IO.File]::ReadAllLines($ledger, [System.Text.Encoding]::UTF8)
        $lastLine = ($lines | Select-Object -Last 1)
        Write-Host "LEDGER_LAST: $lastLine"
    }
    Remove-Item $result -Force
    Write-Host 'CLEANUP=OK'
} else {
    Write-Host 'FILE_EXISTS=False - FAIL'
}
