$root = if ($env:BRIDGE_ROOT) { $env:BRIDGE_ROOT } else { Split-Path -Parent $PSScriptRoot }

$t1 = @(); $e1 = @()
[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'driver.ps1'), [ref]$t1, [ref]$e1) | Out-Null
if ($e1.Count) { "driver.ps1 ERR: " + $e1[0].Message } else { "driver.ps1: OK" }

$t2 = @(); $e2 = @()
[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'lib\common.ps1'), [ref]$t2, [ref]$e2) | Out-Null
if ($e2.Count) { "common.ps1 ERR: " + $e2[0].Message } else { "common.ps1: OK" }

$turns = Join-Path $root 'turns.jsonl'
if (Test-Path -LiteralPath $turns) { Get-Content $turns -Tail 3 }
