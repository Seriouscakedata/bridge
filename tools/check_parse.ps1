param([string]$Path)
$errors = $null
$tokens = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { 'ERR: ' + $errors[0].Message } else { 'OK' }
