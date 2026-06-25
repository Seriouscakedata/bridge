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

# === Phase: floor test (peak >= 15 of 20 dummy jobs) ===
Write-Host "=== Floor test: 20 dummy jobs, expect peak_active >= 15 ==="

# Warm-up spawn to pre-load powershell.exe process creation.
$warmup = $null
try {
  $warmup = Start-Process -FilePath $powershellExe -ArgumentList @('-NoProfile', '-Command', 'exit 0') `
    -PassThru -NoNewWindow -ErrorAction SilentlyContinue
  if ($warmup) { $warmup.WaitForExit(3000) | Out-Null }
} catch {}

Clear-ReadOnlyAuditPoolRegistry | Out-Null
Reset-ReadOnlyAuditPoolTimeline

$floorJobs = @()
for ($i = 0; $i -lt 20; $i++) {
  $floorJobs += Start-ReadOnlyAuditJob -FilePath $powershellExe -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'Start-Sleep -Milliseconds 1500'
  )
}

$fsw = [System.Diagnostics.Stopwatch]::StartNew()
while ($fsw.Elapsed.TotalSeconds -lt 3.5) {
  Add-ReadOnlyAuditTimelineSample
  Start-Sleep -Milliseconds 50
}
while ((Get-ReadOnlyAuditPoolStatus).active -gt 0 -and $fsw.Elapsed.TotalSeconds -lt 10) {
  Start-Sleep -Milliseconds 100
}

$floorTimeline = Get-ReadOnlyAuditPoolTimeline
$floorPeak    = [int]$floorTimeline.peak
$floorSamples = [int]$floorTimeline.count
Write-Host ("Floor test: peak_active={0}, samples={1}" -f $floorPeak, $floorSamples)
if ($floorPeak -lt 15) {
  throw ("Floor test FAIL: expected peak_active >= 15, got {0} (samples={1})" -f $floorPeak, $floorSamples)
}
Write-Host ("Floor test PASS peak_active={0}" -f $floorPeak)

# === Phase: fault-isolation (4 jobs: 1 fail, 1 hang/kill, 2 normal) ===
Write-Host "=== Fault-isolation test ==="

# Wait until all floor jobs have exited before clearing.
$fsw2 = [System.Diagnostics.Stopwatch]::StartNew()
while ((Get-ReadOnlyAuditPoolStatus).active -gt 0 -and $fsw2.Elapsed.TotalSeconds -lt 8) {
  Start-Sleep -Milliseconds 100
}
Clear-ReadOnlyAuditPoolRegistry | Out-Null
Reset-ReadOnlyAuditPoolTimeline

$fiJobs = @()
# job 0: exits immediately with code 1
$fiJobs += Start-ReadOnlyAuditJob -FilePath $powershellExe -ArgumentList @(
  '-NoProfile', '-Command', 'exit 1'
)
# job 1: hangs ~30s, will be killed explicitly
$fiJobs += Start-ReadOnlyAuditJob -FilePath $powershellExe -ArgumentList @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'Start-Sleep -Seconds 30'
)
# job 2: normal
$fiJobs += Start-ReadOnlyAuditJob -FilePath $powershellExe -ArgumentList @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'Start-Sleep -Milliseconds 500'
)
# job 3: normal
$fiJobs += Start-ReadOnlyAuditJob -FilePath $powershellExe -ArgumentList @(
  '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', 'Start-Sleep -Milliseconds 500'
)

# Give exit-1 and normal jobs a moment to settle.
Start-Sleep -Milliseconds 1200

# Explicitly kill the hang job.
$hangRec = $fiJobs[1]
Stop-ReadOnlyAuditJob -Record $hangRec -TimeoutSec 5

# Drain pool.
Wait-ReadOnlyAuditPoolDrain -TimeoutSec 10

$fiStatus = Get-ReadOnlyAuditPoolStatus

Assert-ReadonlyParallel ([int]$fiStatus.active -eq 0) `
  ("fault-isolation: expected active=0, got {0}" -f $fiStatus.active)
Assert-ReadonlyParallel ([int]$fiStatus.total -eq 4) `
  ("fault-isolation: expected total=4, got {0}" -f $fiStatus.total)

# Normal jobs should have completedAt.
$norm1Rec = if ($null -ne $fiJobs[2].pid) { $script:ReadOnlyAuditRegistry[[string]$fiJobs[2].pid] } else { $null }
$norm2Rec = if ($null -ne $fiJobs[3].pid) { $script:ReadOnlyAuditRegistry[[string]$fiJobs[3].pid] } else { $null }
Assert-ReadonlyParallel ($null -ne $norm1Rec -and $null -ne $norm1Rec.completedAt) `
  "fault-isolation: normal job 2 missing completedAt"
Assert-ReadonlyParallel ($null -ne $norm2Rec -and $null -ne $norm2Rec.completedAt) `
  "fault-isolation: normal job 3 missing completedAt"

# Fail job should be recorded with non-null completedAt and non-zero exit code.
$failKey = if ($null -ne $fiJobs[0].pid) { [string]$fiJobs[0].pid } else { 'failed:' + $fiJobs[0].jobId }
$failRec = $script:ReadOnlyAuditRegistry[$failKey]
Assert-ReadonlyParallel ($null -ne $failRec) "fault-isolation: fail job not in registry"
Assert-ReadonlyParallel ($null -ne $failRec.completedAt) "fault-isolation: fail job missing completedAt"
if ($failRec.proc) {
  Assert-ReadonlyParallel ([int]$failRec.proc.ExitCode -ne 0) `
    ("fault-isolation: fail job exit code should be non-zero, got {0}" -f $failRec.proc.ExitCode)
}

# Status should not throw.
$statusOk = $true
try { Get-ReadOnlyAuditPoolStatus | Out-Null } catch { $statusOk = $false }
Assert-ReadonlyParallel $statusOk "fault-isolation: Get-ReadOnlyAuditPoolStatus threw unexpectedly"

Write-Host "PASS fault-isolation"
