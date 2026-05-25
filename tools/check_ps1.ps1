param([string]$Path)
$errs = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$errs)
if ($errs.Count) { 'ERR'; $errs | ForEach-Object { $_.Message } } else { 'OK' }
