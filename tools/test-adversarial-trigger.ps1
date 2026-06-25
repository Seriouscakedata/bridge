$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'adversarial-audit.ps1')

$script:Pass = 0
$script:Fail = 0

function Report-Case {
    param(
        [Parameter(Mandatory=$true)][string]$Name,
        [Parameter(Mandatory=$true)][bool]$Ok,
        [string]$Detail = ''
    )

    if ($Ok) {
        $script:Pass++
        Write-Host "PASS $Name"
    } else {
        $script:Fail++
        if ([string]::IsNullOrWhiteSpace($Detail)) {
            Write-Host "FAIL $Name"
        } else {
            Write-Host "FAIL $Name - $Detail"
        }
    }
}

function Test-AllowedCase {
    param(
        [string]$Trigger,
        [bool]$Expected
    )

    $actual = Test-AuditAdversarialTriggerAllowed -Trigger $Trigger
    $display = if ($Trigger -eq '') { '<empty>' } else { $Trigger }
    Report-Case -Name "trigger '$display' allowed=$Expected" -Ok ($actual.allowed -eq $Expected) -Detail "actual=$($actual.allowed), reason=$($actual.reason)"
}

Test-AllowedCase -Trigger 'operator' -Expected $true
Test-AllowedCase -Trigger 'milestone-pretraining' -Expected $true
Test-AllowedCase -Trigger 'milestone-postpipeline' -Expected $true
Test-AllowedCase -Trigger 'nightly_cron' -Expected $false
Test-AllowedCase -Trigger 'static_daily' -Expected $false
Test-AllowedCase -Trigger 'random-xyz' -Expected $false
Test-AllowedCase -Trigger '' -Expected $false

$nightlyThrows = $false
try {
    Assert-AuditAdversarialAllowed -Trigger 'nightly_cron'
} catch {
    $nightlyThrows = $true
}
Report-Case -Name "Assert nightly_cron throws" -Ok $nightlyThrows

$operatorThrows = $false
try {
    Assert-AuditAdversarialAllowed -Trigger 'operator'
} catch {
    $operatorThrows = $true
}
Report-Case -Name "Assert operator does not throw" -Ok (-not $operatorThrows)

Report-Case -Name "Get-AuditMode operator" -Ok ((Get-AuditMode -Trigger 'operator') -eq 'adversarial_milestone')
Report-Case -Name "Get-AuditMode nightly_cron" -Ok ((Get-AuditMode -Trigger 'nightly_cron') -eq 'static_daily')
Report-Case -Name "Get-AuditMode whatever" -Ok ((Get-AuditMode -Trigger 'whatever') -eq 'static_daily')

Write-Host "$script:Pass PASS, $script:Fail FAIL"
if ($script:Fail -gt 0) {
    exit 1
}
