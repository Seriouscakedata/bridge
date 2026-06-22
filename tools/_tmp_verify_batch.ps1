$root = 'C:\Users\rafie\OneDrive\Documents\bridge'
$files = @('lib\agent-wait.ps1','driver\40-agent-invoke.ps1','tools\test-agent-wait.ps1','lib\backlog.ps1')
$allOk = $true
foreach ($f in $files) {
    $path = Join-Path $root $f
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors) | Out-Null
    if ($errors.Count) { Write-Host "ERR $f"; $allOk = $false } else { Write-Host "OK  $f" }
}
if ($allOk) { Write-Host "PARSER_ALL_OK" } else { Write-Host "PARSER_ERRORS"; exit 1 }
