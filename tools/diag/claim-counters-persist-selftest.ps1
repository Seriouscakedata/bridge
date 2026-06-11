#Requires -Version 5.1
# VERIFY-COVERS: driver/81-loop-idle-claim.ps1
# Tests the persisted claim-guard escape counters (freeze-audit wave1 atom3):
# Get-DriverDirtyDeferDecision and Get-DriverSerialClaimStrikeDecision. Both used to live in
# $script: variables that every driver restart reset to 0, so the escape mechanisms
# (auto-stash at >=6 defers, serial-claim hold at >=4 strikes) could never fire under
# frequent restarts. Decisions now read previous counts from persisted state.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# Dot-sourcing driver/81 only assigns $script:DriverLoopIdleClaimBlock and defines the two
# top-level pure functions; the claim loop itself does not execute.
. (Join-Path $root 'driver\81-loop-idle-claim.ps1')

$fails = 0
function Assert {
  param([string]$Name, [bool]$Cond)
  if ($Cond) { Write-Host "  PASS: $Name" }
  else { Write-Host "  FAIL: $Name"; $script:fails++ }
}

Write-Host "[DD1] fresh state -> streak 1, no autostash"
$d = Get-DriverDirtyDeferDecision -State ([pscustomobject]@{}) -IdeaId 'idea-X'
Assert 'DD1 streak=1' ($d.streak -eq 1)
Assert 'DD1 no autostash' (-not $d.autostash)

Write-Host "[DD2] persisted streak 5 + same idea (restart survived) -> streak 6, AUTOSTASH"
$st = [pscustomobject]@{ dirty_defer_id = 'idea-X'; dirty_defer_streak = 5 }
$d = Get-DriverDirtyDeferDecision -State $st -IdeaId 'idea-X'
Assert 'DD2 streak=6' ($d.streak -eq 6)
Assert 'DD2 autostash fires' ([bool]$d.autostash)

Write-Host "[DD3] different idea -> streak resets to 1"
$st = [pscustomobject]@{ dirty_defer_id = 'idea-X'; dirty_defer_streak = 5 }
$d = Get-DriverDirtyDeferDecision -State $st -IdeaId 'idea-Y'
Assert 'DD3 streak=1' ($d.streak -eq 1)
Assert 'DD3 no autostash' (-not $d.autostash)

Write-Host "[DD4] null state -> streak 1, no crash"
$d = Get-DriverDirtyDeferDecision -State $null -IdeaId 'idea-Z'
Assert 'DD4 streak=1' ($d.streak -eq 1)

Write-Host "[SC1] fresh state -> strike 1, no hold"
$d = Get-DriverSerialClaimStrikeDecision -State ([pscustomobject]@{}) -ItemId 'item-A'
Assert 'SC1 strikes=1' ($d.strikes -eq 1)
Assert 'SC1 no hold' (-not $d.hold)

Write-Host "[SC2] persisted 3 strikes + same item (restart survived) -> strike 4, HOLD"
$map = [pscustomobject]@{ 'item-A' = 3 }
$st = [pscustomobject]@{ serial_claim_strikes = $map }
$d = Get-DriverSerialClaimStrikeDecision -State $st -ItemId 'item-A'
Assert 'SC2 strikes=4' ($d.strikes -eq 4)
Assert 'SC2 hold fires' ([bool]$d.hold)

Write-Host "[SC3] different item -> own counter, strike 1"
$map = [pscustomobject]@{ 'item-A' = 3 }
$st = [pscustomobject]@{ serial_claim_strikes = $map }
$d = Get-DriverSerialClaimStrikeDecision -State $st -ItemId 'item-B'
Assert 'SC3 strikes=1' ($d.strikes -eq 1)
Assert 'SC3 no hold' (-not $d.hold)

Write-Host "[SC4] null state / missing map -> strike 1, no crash"
$d = Get-DriverSerialClaimStrikeDecision -State $null -ItemId 'item-C'
Assert 'SC4 strikes=1' ($d.strikes -eq 1)

Write-Host ''
if ($fails -eq 0) { Write-Host 'CLAIM-COUNTERS-PERSIST: PASS'; exit 0 }
else { Write-Host "CLAIM-COUNTERS-PERSIST: FAIL ($fails assertion(s))"; exit 1 }
