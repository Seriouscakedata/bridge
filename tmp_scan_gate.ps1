$ErrorActionPreference='Stop'
Set-Location 'C:\Users\rafie\OneDrive\Documents\bridge'
. .\lib\common.ps1 *> $null
. .\driver\20-context.ps1 *> $null
if (-not (Get-Command Test-AutonomousTaskSafe -ErrorAction SilentlyContinue)) { Write-Output 'ABORT: gate not loaded'; exit 2 }
if (-not (Get-Command Test-PolicyAutotaskExecutionBlocked -ErrorAction SilentlyContinue)) { try { . .\lib\policy.ps1 *> $null } catch {} }
$polLoaded = [bool](Get-Command Test-PolicyAutotaskExecutionBlocked -ErrorAction SilentlyContinue)

$root = (Get-Location).Path
$files = @('channels/main/backlog.jsonl','channels/oko/backlog.jsonl','channels/computer-control/backlog.jsonl','channels/glass-interpreter/backlog.jsonl')

$hits = New-Object System.Collections.Generic.List[object]
foreach ($f in $files) {
  if (-not (Test-Path $f)) { continue }
  Get-Content -Path $f -Encoding UTF8 | ForEach-Object {
    $line = $_.Trim(); if (-not $line) { return }
    try { $o = $line | ConvertFrom-Json } catch { return }
    $txt = [string]$o.text
    if ([string]::IsNullOrWhiteSpace($txt)) { return }
    $r = Test-AutonomousTaskSafe -TaskText $txt -BridgeRoot $root
    if ($r.safe) { return }
    $polBlocked = $null; $exempt = ''
    if ($polLoaded) {
      try { $pv = Test-PolicyAutotaskExecutionBlocked -Item $o -TaskText $txt -BridgeRoot $root; $polBlocked = [bool]$pv.blocked; $exempt = [string]$pv.exempt } catch { $polBlocked = 'ERR' }
    }
    $hits.Add([pscustomobject]@{
      file=$f; id=$o.id; status=$o.status; from=$o.from
      tags=(@($o.tags) -join ','); reason=$r.reason
      discuss = [bool]($txt -match '\[\[DISCUSS\]\]')
      polBlocked = $polBlocked; polExempt = $exempt
      texthead = ($txt.Substring(0,[Math]::Min(220,$txt.Length)) -replace '\s+',' ')
    })
  }
}
Write-Output ("TOTAL GATE-BLOCKED ITEMS: " + $hits.Count)
foreach ($h in $hits) {
  Write-Output '==========='
  Write-Output ("id=$($h.id) status=$($h.status) from=$($h.from) tags=[$($h.tags)]")
  Write-Output ("discuss=$($h.discuss) policyBlocked=$($h.polBlocked) exempt='$($h.polExempt)'")
  Write-Output ("reason: $($h.reason)")
  Write-Output ("text: $($h.texthead)")
}
