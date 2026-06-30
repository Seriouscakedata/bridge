# Ch0 hang-fix unit test: Get-ProjectAutopilotInterfaceContracts must return @() WITHOUT the expensive
# recursive .bridge file-walk when there are no real contract files, even if .bridge/changes & .bridge/specs
# are full of files (the trap that froze the driver heartbeat). And it must still enumerate real contracts.
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[System.Text.Encoding]::UTF8
$root='C:\Users\rafie\OneDrive\Documents\bridge'
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\backlog-autopilot.ps1')
if (-not (Get-Command Get-ProjectAutopilotInterfaceContracts -EA SilentlyContinue)) { throw 'FAIL: function not loaded' }

$tmp = Join-Path $env:TEMP ('ch0test-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$fail = 0
function Assert($cond,$msg){ if($cond){ Write-Host ("  PASS: "+$msg) } else { Write-Host ("  FAIL: "+$msg); $script:fail++ } }

try {
  # --- Scenario A: no .bridge at all ---
  $a = Join-Path $tmp 'A'; New-Item -ItemType Directory -Force $a | Out-Null
  $ra = @(Get-ProjectAutopilotInterfaceContracts -ProjectRoot $a -Channel 'test')
  Assert ($ra.Count -eq 0) "A: no .bridge -> 0 contracts"

  # --- Scenario B: contracts dir exists but only schema; .bridge stuffed with 300 trap files ---
  $b = Join-Path $tmp 'B'
  $bc = Join-Path $b '.bridge\specs\contracts'; New-Item -ItemType Directory -Force $bc | Out-Null
  Set-Content (Join-Path $bc 'contract.schema.json') -Value '{"type":"object"}' -Encoding UTF8
  $changes = Join-Path $b '.bridge\changes'; New-Item -ItemType Directory -Force $changes | Out-Null
  $specs   = Join-Path $b '.bridge\specs';   New-Item -ItemType Directory -Force $specs | Out-Null
  foreach($i in 1..300){ Set-Content (Join-Path $changes ("trap$i.md")) -Value ("# trap $i`nPROJECT_OPEN_QUESTION: noise line to make the old walk read this file`n" * 5) -Encoding UTF8 }
  foreach($i in 1..120){ Set-Content (Join-Path $specs ("noise$i.md")) -Value ("# noise $i`nlots of text here`n" * 5) -Encoding UTF8 }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $rb = @(Get-ProjectAutopilotInterfaceContracts -ProjectRoot $b -Channel 'test')
  $sw.Stop(); $msB = $sw.ElapsedMilliseconds
  Assert ($rb.Count -eq 0) "B: only schema (no real contracts) -> 0 contracts"
  Assert ($msB -lt 500) ("B: returned in ${msB}ms (<500ms => 420 trap files NOT walked)")

  # --- Scenario C: a real contract file present -> still enumerated ---
  $c = Join-Path $tmp 'C'
  $cc = Join-Path $c '.bridge\specs\contracts'; New-Item -ItemType Directory -Force $cc | Out-Null
  Set-Content (Join-Path $cc 'contract.schema.json') -Value '{"type":"object"}' -Encoding UTF8
  $contract = @{ id='styler-iface'; version='1.0.0'; signature='fun apply(b:Bitmap):Bitmap'; behavior='applies a filter matrix'; invariants=@('output non-null'); errors=@('OOM'); golden_examples=@(@{ input='b1'; output='b2' }); owned_files=@('app/src/main/Styler.kt') } | ConvertTo-Json -Depth 6
  Set-Content (Join-Path $cc 'styler-iface.json') -Value $contract -Encoding UTF8
  $rc = @(Get-ProjectAutopilotInterfaceContracts -ProjectRoot $c -Channel 'test')
  Assert ($rc.Count -eq 1) "C: one real contract -> 1 enumerated"
  Assert ($rc.Count -eq 1 -and [string]$rc[0].id -eq 'styler-iface') "C: contract id parsed = styler-iface"
} finally {
  try { Remove-Item $tmp -Recurse -Force -EA SilentlyContinue } catch {}
}
$res = if($fail -eq 0){'ALL PASS'}else{"$fail FAILED"}
Write-Host ("`nRESULT: " + $res)
exit $fail