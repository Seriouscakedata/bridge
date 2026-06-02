# auditor-tick.ps1 -- standalone Auditor wrapper for scheduled/manual checks.
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\auditor.ps1')

Start-AuditorIfDue
