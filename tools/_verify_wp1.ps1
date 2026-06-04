$path = 'C:\Users\rafie\OneDrive\Documents\bridge\lib\jobs.ps1'
$errors = $null
$tokens = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
if ($errors.Count -eq 0) { Write-Host 'PARSE OK' } else { Write-Host ('PARSE ERR: ' + $errors[0].Message) }
$bytes = [System.IO.File]::ReadAllBytes($path)
$bom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
Write-Host "BOM=$bom"
# Count lines per function
$content = Get-Content $path
$funcStarts = @{}
$current = $null
$lineNo = 0
foreach ($line in $content) {
    $lineNo++
    if ($line -match '^function\s+([\w-]+)') {
        $current = $Matches[1]
        $funcStarts[$current] = $lineNo
    }
}
# Just report key function sizes
$src = [System.IO.File]::ReadAllText($path)
$funcs = [regex]::Matches($src, 'function\s+([\w-]+)')
Write-Host "Total functions: $($funcs.Count)"
Write-Host "File lines: $lineNo"
