param()

# ==============================================================================
# tools/test-worker-diversity.ps1
#   Select-WorkerForStream must SPREAD 'complex' streams across CLIs (Claude + Codex),
#   not route 100% to codex. Verifies:
#     * premium Claude (Opus) is eligible for 'complex' when the flag is ON (default);
#     * the cli-balance sort + round-robin uses BOTH codex and claude across a wave;
#     * with the flag OFF, premium Claude is excluded from 'complex' (old behaviour).
# ==============================================================================

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
. (Join-Path $root 'lib\common.ps1') | Out-Null
. (Join-Path $root 'lib\parallel.ps1') | Out-Null

$fail = 0
function Assert-True { param([bool]$Cond, [string]$Label)
  $res = if ($Cond) { 'PASS' } else { 'FAIL' }
  if (-not $Cond) { $script:fail++ }
  Write-Host ("[{0}] {1}" -f $res, $Label)
}

# fixed pool: 2 strong codex + 2 strong claude-opus (all >= complex floor 4)
function Get-ParallelWorkerPool {
  @(
    [pscustomobject]@{ id='codex-high';   cli='codex';  model='gpt-5.5';         reasoning='high'; strength=4; speed=2; cost=4; domains=@('any') },
    [pscustomobject]@{ id='codex-high-2'; cli='codex';  model='gpt-5.5';         reasoning='high'; strength=4; speed=2; cost=4; domains=@('any') },
    [pscustomobject]@{ id='claude-fable';   cli='claude'; model='claude-opus-4-8'; strength=5; speed=3; cost=5; domains=@('any') },
    [pscustomobject]@{ id='claude-fable-2'; cli='claude'; model='claude-opus-4-8'; strength=5; speed=3; cost=5; domains=@('any') }
  )
}
$stream = [pscustomobject]@{ id='s1'; complexity='complex'; files=@('app/x.kt'); body='' }

# ---- A: flag ON (default) -> a 4-wide complex wave uses BOTH CLIs ----
function Get-BridgeConfig { [pscustomobject]@{ parallel = [pscustomobject]@{} } }
$used=@(); $picks=@()
for ($i=0; $i -lt 4; $i++) { $w = Select-WorkerForStream -Stream $stream -AlreadyUsedIds $used; if (-not $w) { break }; $picks += [string]$w.id; $used += [string]$w.id }
$clis = @($picks | ForEach-Object { if ($_ -match 'claude') { 'claude' } else { 'codex' } })
Assert-True ($picks.Count -eq 4)                       "4-wide wave assigns 4 distinct workers"
Assert-True (@($clis | Where-Object { $_ -eq 'claude' }).Count -ge 1) "complex wave uses Claude (not 100% codex)"
Assert-True (@($clis | Where-Object { $_ -eq 'codex'  }).Count -ge 1) "complex wave uses Codex too"
Assert-True ((@($clis | Where-Object { $_ -eq 'claude' }).Count -eq 2) -and (@($clis | Where-Object { $_ -eq 'codex' }).Count -eq 2)) "cli-balance splits evenly 2 codex / 2 claude"

# ---- B: first pick alternates (cli-balance), not codex-locked ----
$w1 = Select-WorkerForStream -Stream $stream -AlreadyUsedIds @('codex-high','codex-high-2')  # both codex used
Assert-True ([string]$w1.cli -eq 'claude') "when both codex used, next pick is the free Claude (fallback)"

# ---- C: flag OFF -> premium Claude excluded from complex (old behaviour) ----
function Get-BridgeConfig { [pscustomobject]@{ parallel = [pscustomobject]@{ allowPremiumClaudeForComplex = $false } } }
$wOff = Select-WorkerForStream -Stream $stream -AlreadyUsedIds @()
Assert-True ([string]$wOff.cli -eq 'codex') "flag OFF: complex routes to codex only (premium guard)"

# ---- D: architectural always allows premium Claude regardless of flag ----
$archStream = [pscustomobject]@{ id='s2'; complexity='architectural'; files=@('app/x.kt'); body='' }
$usedA=@(); $picksA=@()
for ($i=0; $i -lt 4; $i++) { $w = Select-WorkerForStream -Stream $archStream -AlreadyUsedIds $usedA; if (-not $w) { break }; $picksA += [string]$w.id; $usedA += [string]$w.id }
Assert-True (@($picksA | Where-Object { $_ -match 'claude' }).Count -ge 1) "architectural uses Claude even with flag OFF"

Write-Host ""
if ($fail -eq 0) { Write-Host "RESULT: ALL PASS" } else { Write-Host ("RESULT: {0} FAIL" -f $fail); exit 1 }
