$t1 = @(); $e1 = @()
[System.Management.Automation.Language.Parser]::ParseFile('C:\Users\rafie\OneDrive\Documents\bridge\driver.ps1', [ref]$t1, [ref]$e1) | Out-Null
if ($e1.Count) { "driver.ps1 ERR: " + $e1[0].Message } else { "driver.ps1: OK" }
$t2 = @(); $e2 = @()
[System.Management.Automation.Language.Parser]::ParseFile('C:\Users\rafie\OneDrive\Documents\bridge\lib\common.ps1', [ref]$t2, [ref]$e2) | Out-Null
if ($e2.Count) { "common.ps1 ERR: " + $e2[0].Message } else { "common.ps1: OK" }
Get-Content 'C:\Users\rafie\OneDrive\Documents\bridge\turns.jsonl' -Tail 3
