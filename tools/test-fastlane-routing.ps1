$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$commonPath = Join-Path $root 'lib\common.ps1'
$intentPath = Join-Path $root 'lib\intent.ps1'
$driverPath = Join-Path $root 'driver.ps1'

. $commonPath
. $intentPath

$driverSrc = Get-Content -LiteralPath $driverPath -Raw -Encoding UTF8
$m = [regex]::Match($driverSrc, '(?ms)function\s+Test-IsTrivialTask\s*\{.*?\n\}')
if (-not $m.Success) { throw 'Test-IsTrivialTask not found in driver.ps1' }
Invoke-Expression $m.Value

function Add-Check {
  param(
    [System.Collections.ArrayList]$Results,
    [string]$Name,
    [object]$Expected,
    [object]$Actual
  )
  $pass = ($Actual -eq $Expected)
  $status = if ($pass) { 'PASS' } else { 'FAIL' }
  [void]$Results.Add([pscustomobject]@{
    Status = $status
    Name = $Name
    Expected = $Expected
    Actual = $Actual
  })
}

$results = [System.Collections.ArrayList]::new()

Add-Check $results 'safe: сделай скриншот' $true ([bool](Test-IsSafeOsFastLaneTask 'сделай скриншот'))
Add-Check $results 'safe: запусти калькулятор' $true ([bool](Test-IsSafeOsFastLaneTask 'запусти калькулятор'))
Add-Check $results 'safe: найди chrome на компьютере' $true ([bool](Test-IsSafeOsFastLaneTask 'найди chrome на компьютере'))
Add-Check $results 'safe: покажи логи' $true ([bool](Test-IsSafeOsFastLaneTask 'покажи логи'))
Add-Check $results 'unsafe: удали папку temp' $true ([bool](Test-IsUnsafeFastLaneTask 'удали папку temp'))
Add-Check $results 'unsafe blocks safe: удали папку temp' $false ([bool](Test-IsSafeOsFastLaneTask 'удали папку temp'))
Add-Check $results 'unsafe blocks safe: убей процесс chrome' $false ([bool](Test-IsSafeOsFastLaneTask 'убей процесс chrome'))
Add-Check $results 'unsafe blocks safe: убить процесс chrome' $false ([bool](Test-IsSafeOsFastLaneTask 'убить процесс chrome'))
Add-Check $results 'unsafe blocks safe: закрой chrome' $false ([bool](Test-IsSafeOsFastLaneTask 'закрой chrome'))
Add-Check $results 'unsafe blocks safe: перезапусти мост' $false ([bool](Test-IsSafeOsFastLaneTask 'перезапусти мост'))
Add-Check $results 'code edit not safe: поправь server.ps1' $false ([bool](Test-IsSafeOsFastLaneTask 'поправь server.ps1'))
Add-Check $results 'discuss not safe: обсудите скриншот' $false ([bool](Test-IsSafeOsFastLaneTask 'обсудите скриншот'))
Add-Check $results 'implement not safe: реализуйте скриншот' $false ([bool](Test-IsSafeOsFastLaneTask 'реализуйте скриншот'))
Add-Check $results 'trivial: сделай скриншот' $true ([bool](Test-IsTrivialTask -TaskText 'сделай скриншот' -MinChars 100))
Add-Check $results 'trivial blocks unsafe: удали папку temp' $false ([bool](Test-IsTrivialTask -TaskText 'удали папку temp' -MinChars 100))
Add-Check $results 'trivial blocks code edit: поправь server.ps1' $false ([bool](Test-IsTrivialTask -TaskText 'поправь server.ps1' -MinChars 100))
Add-Check $results 'trivial blocks discuss: обсудите скриншот' $false ([bool](Test-IsTrivialTask -TaskText 'обсудите скриншот' -MinChars 100))

$intent = Test-TaskIntent -TaskText 'сделай скриншот'
$intentMode = if ($intent) { [string]$intent.primary_mode } else { '' }
$intentSource = if ($intent) { [string]$intent.source } else { '' }
Add-Check $results 'intent short-skip mode: сделай скриншот' 'fast' $intentMode
Add-Check $results 'intent short-skip source: сделай скриншот' 'short-skip-fast' $intentSource

foreach ($r in $results) {
  Write-Host ("{0} {1} expected={2} actual={3}" -f $r.Status, $r.Name, $r.Expected, $r.Actual)
}

$failed = @($results | Where-Object { $_.Status -ne 'PASS' })
if ($failed.Count -gt 0) { exit 1 }
exit 0
