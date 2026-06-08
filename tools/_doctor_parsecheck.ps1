$root = 'C:\Users\rafie\OneDrive\Documents\bridge'
$files = @(
 'driver/10-maintenance.ps1','driver/81-loop-idle-claim.ps1','driver/85-loop-mode-transitions.ps1',
 'driver/86-loop-completion-checks.ps1','lib/backlog-crud.ps1','lib/backlog-governor.ps1',
 'lib/project-acceptance.ps1','tools/test-backlog-governor.ps1','tools/test-queue-governor-completion-hooks.ps1')
foreach($f in $files){
  $e=$null;$t=$null
  [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $f),[ref]$t,[ref]$e) | Out-Null
  if($e.Count){
    Write-Output ("{0} : ERR x{1}" -f $f,$e.Count)
    $e | Select-Object -First 3 | ForEach-Object { Write-Output ("    L{0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) }
  } else { Write-Output ("{0} : OK" -f $f) }
}
