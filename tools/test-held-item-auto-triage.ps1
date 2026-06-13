Set-StrictMode -Version Latest
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\backlog.ps1')
. (Join-Path $root 'driver\10-maintenance.ps1')
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

$old = (Get-Date).ToUniversalTime().AddDays(-2).ToString('o')
function New-ItemObj {
  param([string]$Id, [string]$Status, [string]$Text, [string[]]$Files)
  [pscustomobject]@{
    id = $Id
    status = $Status
    ts = $old
    text = $Text
    files = @($Files)
    acceptance = @('acceptance present')
    scope = 'bridge'
    tags = @()
  }
}

$items = @(
  (New-ItemObj 'safe-1' 'held' 'Files: docs/a.md Acceptance: ok' @('docs/a.md')),
  (New-ItemObj 'cp-1' 'new' 'Files: driver.ps1 Acceptance: driver selftest' @('driver.ps1')),
  ([pscustomobject]@{ id='junk-1'; status='held'; ts=$old; text='no useful metadata'; files=@(); scope='bridge'; tags=@() }),
  (New-ItemObj 'risk-1' 'held' 'Files: driver.ps1, supervisor.ps1, watchdog.ps1, server.ps1 Acceptance: broad CP' @('driver.ps1','supervisor.ps1','watchdog.ps1','server.ps1')),
  (New-ItemObj 'safe-2' 'held' 'Files: docs/b.md Acceptance: ok' @('docs/b.md')),
  (New-ItemObj 'safe-3' 'held' 'Files: docs/c.md Acceptance: ok' @('docs/c.md')),
  (New-ItemObj 'safe-4' 'held' 'Files: docs/d.md Acceptance: ok' @('docs/d.md'))
)

$marker = Join-Path $env:TEMP ("held-auto-triage-" + [guid]::NewGuid().ToString('N') + ".last")
$result = Invoke-BacklogHeldItemAutoTriage -Items $items -MaxActions 5 -MarkerPath $marker -Force

Assert-True ([int]$result.actions -eq 5) 'action limit not honored'
Assert-True ([string]$items[0].status -eq 'approved') 'safe non-CP was not approved'
Assert-True ([string]$items[1].status -eq 'approved') 'CP item was not approved via canary'
Assert-True ($null -ne $items[1].bridge_self_admission) 'CP item missing canary admission'
Assert-True ([string]$items[2].status -eq 'rejected') 'junk item was not rejected'
Assert-True ([string]$items[3].status -eq 'held') 'risky item should remain held'
Assert-True ([string]$items[5].status -eq 'approved') 'fifth action should be allowed'
Assert-True ([string]$items[6].status -eq 'held') 'sixth action should remain held due to limit'

$log = $script:Messages -join "`n"
Assert-True ($log -match 'Авто-триаж: approved safe-1') 'approve log missing'
Assert-True ($log -match 'Авто-триаж: canary cp-1') 'canary log missing'
Assert-True ($log -match 'Авто-триаж: rejected junk-1') 'reject log missing'
Assert-True ($log -match 'Авто-триаж: escalate risk-1') 'escalate log missing'
Assert-True ($log -match '1 задач ждут решения оператора: risk-1') 'operator digest missing'

try { Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue } catch {}
'test-held-item-auto-triage: PASS'
