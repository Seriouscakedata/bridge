$path = 'C:\Users\rafie\OneDrive\Documents\bridge\channels\travel\memory\memory.jsonl'
$lines = @(Get-Content -LiteralPath $path | Where-Object { $_ -notmatch 'phase-verify-travel-write-test' })
[System.IO.File]::WriteAllLines($path, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ('remaining=' + (Get-Content -LiteralPath $path).Count)
