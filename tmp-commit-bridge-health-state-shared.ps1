$ErrorActionPreference = 'Stop'

$scriptPath = $MyInvocation.MyCommand.Path
$root = 'C:\Users\rafie\OneDrive\Documents\bridge'
Set-Location -LiteralPath $root

Write-Host '--- git status before ---'
git status --short

Write-Host '--- health hot-path legacy reads ---'
$legacyReads = Select-String -Path .\server.ps1 -Pattern 'ReadAllText|Get-Content' |
  Where-Object { $_.LineNumber -ge 453 -and $_.LineNumber -le 599 }
if ($legacyReads) {
  $legacyReads | ForEach-Object { Write-Host ("{0}: {1}" -f $_.LineNumber, $_.Line.Trim()) }
  throw 'legacy health hot-path reads remain'
}
Write-Host 'none'

Write-Host '--- shared state read check ---'
Select-String -Path .\server.ps1 -Pattern 'Read-TextFileShared -Path \$statePath|FileShare\]::ReadWrite' |
  ForEach-Object { Write-Host ("{0}: {1}" -f $_.LineNumber, $_.Line.Trim()) }

Write-Host '--- smoke ---'
powershell -NoProfile -ExecutionPolicy Bypass -File .\smoke.ps1

Write-Host '--- api health ---'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8787/api/health' -TimeoutSec 5
$sw.Stop()
Write-Host ("StatusCode={0} ElapsedMs={1}" -f $r.StatusCode, [int]$sw.ElapsedMilliseconds)
Write-Host $r.Content
if ($r.StatusCode -ne 200) { throw 'health returned non-200' }
if ($sw.ElapsedMilliseconds -ge 500) { throw 'health took >=500ms' }

Write-Host '--- commit ---'
git add -- server.ps1
git commit -m "repair(server): state.json read in health uses FileShare.ReadWrite" `
  -m "Root: ReadAllText on state.json uses FileShare.Read by default, which can block under OneDrive oplock during driver heartbeat writes. Same class of bug as Get-FastJsonlTailLines fixed in 4522be7." `
  -m "Fix: use File.Open(..., FileShare.ReadWrite) through shared text reads in the health hot-path." `
  -m "Verification: smoke OK; /api/health HTTP 200 <500ms."

Write-Host '--- HEAD ---'
git log -1 --oneline

Write-Host '--- cleanup ---'
Remove-Item -LiteralPath $scriptPath -Force

Write-Host '--- git status after ---'
git status --short
