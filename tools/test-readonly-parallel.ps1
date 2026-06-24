$ErrorActionPreference = 'Stop'

$BridgeRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $BridgeRoot 'lib\common.ps1')
. (Join-Path $BridgeRoot 'lib\parallel.ps1')

function Assert-ReadonlyParallel {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Test-ParseClean {
  param([string]$Path)
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count -gt 0) {
    throw ("ParseFile failed for {0}: {1}" -f $Path, ($errors | Select-Object -First 1 | ForEach-Object { $_.Message }))
  }
}

$parallelPath = Join-Path $BridgeRoot 'lib\parallel.ps1'
$testPath = $PSCommandPath
Test-ParseClean $parallelPath
Test-ParseClean $testPath

$powershellExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$jobs = @()
$peak = 0
$failed = $null

try {
  $failed = Start-ReadOnlyAuditJob -FilePath 'definitely-missing-readonly-audit-cli.exe' -ArgumentList @('--nope')
  Assert-ReadonlyParallel ($failed.proc -eq $null) 'invalid command should be recorded without an active process'

  for ($i = 0; $i -lt 3; $i++) {
    $jobs += Start-ReadOnlyAuditJob -FilePath $powershellExe -ArgumentList @(
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      'Start-Sleep -Seconds 7'
    )
  }

  foreach ($job in $jobs) {
    Assert-ReadonlyParallel ($job.proc -ne $null) ("job did not start: {0}" -f $job.jobId)
    Assert-ReadonlyParallel ($job.pid -ne $null) ("job did not capture root pid: {0}" -f $job.jobId)
    Assert-ReadonlyParallel (Test-Path -LiteralPath $job.inputPath) ("missing input file: {0}" -f $job.inputPath)
    Assert-ReadonlyParallel (Test-Path -LiteralPath $job.outputPath) ("missing output file: {0}" -f $job.outputPath)
    Assert-ReadonlyParallel (Test-Path -LiteralPath $job.errorPath) ("missing error file: {0}" -f $job.errorPath)
    Assert-ReadonlyParallel (Test-Path -LiteralPath $job.resultPath) ("missing result file: {0}" -f $job.resultPath)
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt 12) {
    $status = Get-ReadOnlyAuditPoolStatus
    if ([int]$status.active -gt $peak) { $peak = [int]$status.active }
    if ($peak -ge 3 -and [int]$status.active -eq 0) { break }
    Start-Sleep -Milliseconds 100
  }

  Assert-ReadonlyParallel ($peak -ge 3) ("expected peak active >= 3, got {0}" -f $peak)

  while ((Get-ReadOnlyAuditPoolStatus).active -gt 0 -and $sw.Elapsed.TotalSeconds -lt 20) {
    Start-Sleep -Milliseconds 100
  }

  $final = Get-ReadOnlyAuditPoolStatus
  Assert-ReadonlyParallel ([int]$final.total -ge 4) ("expected registry total >= 4, got {0}" -f $final.total)
  Assert-ReadonlyParallel ($script:ReadOnlyAuditRegistry -ne $null) 'registry is not script-scoped/visible'
  foreach ($job in $jobs) {
    $key = [string]$job.pid
    Assert-ReadonlyParallel ($script:ReadOnlyAuditRegistry.ContainsKey($key)) ("registry missing pid key: {0}" -f $key)
    $record = $script:ReadOnlyAuditRegistry[$key]
    Assert-ReadonlyParallel ($record.jobId -and $record.pid -and $record.PSObject.Properties['pidTicks'] -and $record.proc) ("registry record incomplete for pid {0}" -f $key)
  }

  Write-Host ("readonly parallel test PASS peak_active={0} registry_total={1}" -f $peak, $final.total)
} finally {
  foreach ($job in @($jobs)) {
    try {
      if ($job.proc -and -not $job.proc.HasExited) {
        $job.proc.Kill()
        $job.proc.WaitForExit(3000) | Out-Null
      }
    } catch {}
  }
  try { Clear-ReadOnlyAuditPoolRegistry -DeleteFiles | Out-Null } catch {}
}
