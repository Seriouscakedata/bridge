$root = 'C:\Users\rafie\OneDrive\Documents\bridge'
$files = @('lib/jobs.ps1','lib/parallel.ps1','lib/memory.ps1','librarian.ps1','lib/backlog.ps1','tools/deep-audit-agent.ps1')
Write-Host '=== PARSE + BOM ==='
foreach($f in $files){
  $p = Join-Path $root $f
  $e=$null;$t=$null
  [System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e)|Out-Null
  $bytes=[System.IO.File]::ReadAllBytes($p)
  $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
  $st = if($e.Count){'ERR'}else{'OK'}
  '{0,-32} parse={1,-4} bom={2}' -f $f, $st, $bom
  if($e.Count){ $e | ForEach-Object { '   '+$_.Message } }
}
Write-Host ''
Write-Host '=== FUNCTION LINE COUNTS (target <=150 for refactored) ==='
$targets = @(
  @{ file='lib/jobs.ps1'; fn='Get-BridgeJobNativeSource' },
  @{ file='lib/parallel.ps1'; fn='Invoke-ParallelDispatch' },
  @{ file='tools/deep-audit-agent.ps1'; fn='New-AgentPrompt' }
)
foreach($tg in $targets){
  $p = Join-Path $root $tg.file
  $e=$null;$t=$null
  $ast=[System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$t,[ref]$e)
  $fn = $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $tg.fn},$true) | Select-Object -First 1
  if($fn){
    $lines = $fn.Extent.EndLineNumber - $fn.Extent.StartLineNumber + 1
    '{0} :: {1} = {2} lines' -f $tg.file, $tg.fn, $lines
  } else {
    '{0} :: {1} = NOT FOUND' -f $tg.file, $tg.fn
  }
}
