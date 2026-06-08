param([string[]]$Files)
foreach ($f in $Files) {
  $errors = $null; $tokens = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$tokens,[ref]$errors) | Out-Null
  $bytes = [System.IO.File]::ReadAllBytes($f)
  $hasBom = ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  if ($errors.Count) {
    Write-Host "ERR $f : $($errors[0].Message)"
  } else {
    Write-Host "PARSE OK BOM=$hasBom : $f"
  }
}
