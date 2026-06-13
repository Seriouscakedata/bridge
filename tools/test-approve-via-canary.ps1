Set-StrictMode -Version Latest
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\backlog.ps1')
Set-StrictMode -Version Latest

$script:Messages = New-Object 'System.Collections.Generic.List[string]'
function Add-Message {
  param([string]$From, [string]$Text, [string]$Kind = 'message')
  [void]$script:Messages.Add($Text)
  return [pscustomobject]@{ ok = $true }
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

$item = [pscustomobject]@{
  id = 'canary-test-1'
  status = 'held'
  scope = 'bridge'
  tags = @('auto')
  files = @('driver.ps1')
  acceptance = @('driver.ps1 -SelfTest')
  text = 'Files: driver.ps1 Acceptance: driver.ps1 -SelfTest'
}
$decision = [pscustomobject]@{ decision='canary'; reason='control_plane_with_bounded_files_and_acceptance' }

[void](Approve-BacklogItemViaCanary -Item $item -Decision $decision)

Assert-True ([string]$item.status -eq 'approved') 'item was not approved'
Assert-True (@($item.tags) -contains 'operator') 'operator tag missing'
Assert-True ($null -ne $item.bridge_self_admission) 'bridge_self_admission missing'
Assert-True ([bool]$item.bridge_self_admission.canary_required) 'canary_required missing'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$item.bridge_self_admission.rollback_plan)) 'rollback_plan missing'

$claim = Test-BacklogApprovedItemClaimable -Item $item
Assert-True ([bool]$claim.claimable) ("item not claimable: " + [string]$claim.reason)
Assert-True ([string]$claim.reason -eq 'bridge-self-admission') ("item did not pass canary admission path: " + [string]$claim.reason)
Assert-True ([string]$claim.reason -ne 'control-plane-blocked') 'item is still control-plane-blocked'
Assert-True (($script:Messages -join "`n") -match 'Авто-canary одобрение: canary-test-1') 'approval log missing'

'test-approve-via-canary: PASS'
