# test-primitives.ps1 -- unit tests for lib/primitives.ps1 + that the two divergent ObjectValue
# semantics are PRESERVED exactly by the delegating wrappers (governor=return-null,
# workpack=null-as-missing). SPEC-PINNED: if these flip, a gate can silently see/not-see a field.

$ErrorActionPreference = 'Stop'
$bridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $bridgeRoot 'lib\primitives.ps1')
. (Join-Path $bridgeRoot 'lib\backlog-governor.ps1')
. (Join-Path $bridgeRoot 'lib\backlog.ps1')   # loads workpack (Get-BacklogPackObjectValue)
. (Join-Path $bridgeRoot 'lib\backlog-dedup.ps1')
. (Join-Path $bridgeRoot 'lib\backlog-state-reaper.ps1')
. (Join-Path $bridgeRoot 'lib\metrics.ps1')
. (Join-Path $bridgeRoot 'lib\project-acceptance.ps1')
. (Join-Path $bridgeRoot 'lib\self-model.ps1')
. (Join-Path $bridgeRoot 'lib\task-outcome-ledger.ps1')
. (Join-Path $bridgeRoot 'lib\task-management.ps1')
. (Join-Path $bridgeRoot 'lib\workpack-obligation.ps1')
. (Join-Path $bridgeRoot 'lib\delivery-contract.ps1')
. (Join-Path $bridgeRoot 'lib\backlog-autopilot.ps1')
. (Join-Path $bridgeRoot 'lib\delivery-mode.ps1')
. (Join-Path $bridgeRoot 'lib\delivery-gate.ps1')

$script:pass = 0; $script:fail = 0
function Assert-Prim { param([string]$Name, [bool]$Cond, $Detail='') if ($Cond) { Write-Host "PASS: $Name"; $script:pass++ } else { Write-Host "FAIL: $Name $Detail"; $script:fail++ } }

# ── canonical Get-BridgeObjectValue ──────────────────────────────────────────────
$po = [pscustomobject]@{ a = 1; b = $null; nested = 'x' }
$di = @{ a = 1; b = $null }
Assert-Prim 'psobject: first match wins' ((Get-BridgeObjectValue -Object $po -Names @('a','nested')) -eq 1)
Assert-Prim 'psobject: case-insensitive' ((Get-BridgeObjectValue -Object $po -Names @('NESTED')) -eq 'x')
Assert-Prim 'psobject: missing -> default' ((Get-BridgeObjectValue -Object $po -Names @('zzz') -Default 'd') -eq 'd')
Assert-Prim 'dict: key found' ((Get-BridgeObjectValue -Object $di -Names @('a')) -eq 1)
Assert-Prim 'null object -> default' ((Get-BridgeObjectValue -Object $null -Names @('a') -Default 7) -eq 7)
# the divergence, both directions:
Assert-Prim 'present-null WITHOUT NullAsMissing -> returns null' ($null -eq (Get-BridgeObjectValue -Object $po -Names @('b') -Default 'd'))
Assert-Prim 'present-null WITH NullAsMissing -> default' ((Get-BridgeObjectValue -Object $po -Names @('b') -Default 'd' -NullAsMissing) -eq 'd')
Assert-Prim 'dict present-null WITH NullAsMissing -> default' ((Get-BridgeObjectValue -Object $di -Names @('b') -Default 'd' -NullAsMissing) -eq 'd')

# ── wrappers preserve exact original semantics ───────────────────────────────────
Assert-Prim 'governor wrapper returns present-null (orig behavior)' ($null -eq (Get-BacklogGovernorObjectValue -Object $po -Names @('b') -Default 'd'))
Assert-Prim 'governor wrapper missing -> default' ((Get-BacklogGovernorObjectValue -Object $po -Names @('zzz') -Default 'd') -eq 'd')
Assert-Prim 'workpack wrapper treats present-null as missing (orig behavior)' ((Get-BacklogPackObjectValue -Obj $po -Name 'b' -Default 'd') -eq 'd')
Assert-Prim 'workpack wrapper returns real value' ((Get-BacklogPackObjectValue -Obj $po -Name 'a' -Default 'd') -eq 1)
Assert-Prim 'dedup wrapper returns present-null (orig behavior)' ($null -eq (Get-BacklogDedupObjectValue -Object $po -Names @('b') -Default 'd'))
Assert-Prim 'state-reaper wrapper returns present-null (orig behavior)' ($null -eq (Get-BacklogStateReaperObjectValue -Object $po -Names @('b') -Default 'd'))
Assert-Prim 'metrics wrapper returns present-null (orig behavior)' ($null -eq (Get-MetricsObjectValue -Obj $po -Name 'b'))
Assert-Prim 'project-acceptance wrapper treats present-null as missing (orig behavior)' ((Get-ProjectAcceptanceObjectValue -Obj $po -Names @('b') -Default 'd') -eq 'd')
Assert-Prim 'self-model wrapper returns present-null (orig behavior)' ($null -eq (Get-SelfModelObjectValue -Object $po -Names @('b') -Default 'd'))
Assert-Prim 'task-outcome-ledger wrapper returns present-null (orig behavior)' ($null -eq (Get-TaskOutcomeLedgerObjectValue -Object $po -Names @('b') -Default 'd'))

# ── string-array + truthy ────────────────────────────────────────────────────────
Assert-Prim 'stringarray: null -> empty' ((@(ConvertTo-BridgeStringArray $null)).Count -eq 0)
Assert-Prim 'stringarray: string -> one' ((@(ConvertTo-BridgeStringArray 'x')).Count -eq 1)
Assert-Prim 'stringarray: drops blanks' ((@(ConvertTo-BridgeStringArray @('a','',' ','b'))).Count -eq 2)
Assert-Prim 'governor stringarray wrapper works' ((@(ConvertTo-BacklogGovernorStringArray @('a','','b'))).Count -eq 2)
Assert-Prim 'dedup stringarray wrapper preserves canonical behavior' ((@(ConvertTo-BacklogDedupStringArray @('a','','b'))).Count -eq 2)
Assert-Prim 'truthy: enabled -> true' (Test-BridgeTruthy -Value 'enabled' -Default $false)
Assert-Prim 'truthy: off -> false' (-not (Test-BridgeTruthy -Value 'off' -Default $true))
Assert-Prim 'truthy: junk -> default' (Test-BridgeTruthy -Value 'maybe' -Default $true)
Assert-Prim 'pack-bool wrapper: disabled -> false' (-not (ConvertTo-BacklogPackBool 'disabled' $true))
Assert-Prim 'finding: task-management string array still trims+dedups' ((@(ConvertTo-TaskManagementStringArray @(' a ','a'))).Count -eq 1)
Assert-Prim 'finding: workpack unique string array still dedups case-insensitive' ((@(ConvertTo-WorkpackUniqueStringArray @('A','a'))).Count -eq 1)
Assert-Prim 'finding: workpack string array still trims values' ((@(ConvertTo-WorkpackStringArray @(' a ')))[0] -eq 'a')
Assert-Prim 'finding: delivery-contract truthy still accepts y' (Test-DeliveryContractTruthy -Value 'y')
Assert-Prim 'finding: project-autopilot truthy still accepts numeric nonzero' (Test-ProjectAutopilotTruthy -Value 2)
Assert-Prim 'finding: delivery truthy still accepts numeric nonzero' (Test-DeliveryTruthy -Value 2)
Assert-Prim 'finding: delivery-gate boolean remains strict bool' (-not (Test-DeliveryGateBooleanValue -Value 'true'))

Write-Host ("Primitives tests: {0} PASS, {1} FAIL" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
exit 0
