param([string]$File1, [string]$File2)
$files = @($File1, $File2) | Where-Object { $_ }
foreach ($f in $files) {
  $errs = $null; $tok = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f,[ref]$tok,[ref]$errs) | Out-Null
  $b = [System.IO.File]::ReadAllBytes($f)
  $bom = ($b[0] -eq 239 -and $b[1] -eq 187 -and $b[2] -eq 191)
  if ($errs.Count) { "ERR $f : " + $errs[0].Message }
  else { "PARSE OK BOM=$bom : $f" }
}
