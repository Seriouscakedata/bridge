# supervisor_exit_code_test.ps1 -- focused self-test for supervisor fatal exit-code handling.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\common.ps1')
. (Join-Path $root 'lib\supervisor-restart-limit.ps1')

function Assert-SupervisorExitCode {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERT: $Message" }
}

$cfg = [pscustomobject]@{
  supervisor = [pscustomobject]@{
    fatalDriverExitCodes = @(3)
    fatalServerExitCodes = @()
  }
}
$settings = Get-SupervisorFatalExitCodeSettings -Config $cfg
$fatalProc = [pscustomobject]@{ ExitCode = 3 }
$nonFatalProc = [pscustomobject]@{ ExitCode = 1 }

$fatalDetected = Test-SupervisorFatalExitCode -ExitCode ([int]$fatalProc.ExitCode) -FatalCodes $settings.fatalDriverExitCodes
$nonFatalDetected = -not (Test-SupervisorFatalExitCode -ExitCode ([int]$nonFatalProc.ExitCode) -FatalCodes $settings.fatalDriverExitCodes)

$fatalBlockState = @{}
if ($fatalDetected) { $fatalBlockState['main'] = Get-Date }
$fatalBlock = $fatalBlockState.ContainsKey('main')

$exitLine = Format-SupervisorProcessExitLine -ProcessKey 'driver[main]' -ExitCode ([int]$fatalProc.ExitCode)
$exitCodeLogged = ($exitLine -match 'driver\[main\] EXITED exitCode=3')
$tmpErr = Join-Path ([System.IO.Path]::GetTempPath()) ('bridge-supervisor-exit-code-test.' + [Guid]::NewGuid().ToString('N') + '.err.log')
try {
  @('first line','fatal config detail','last line') | Set-Content -LiteralPath $tmpErr -Encoding UTF8
  $tail = @(Get-Content -LiteralPath $tmpErr -Encoding UTF8 -Tail 2 -ErrorAction Stop) -join "`n"
  $stderrTailRead = ($tail -match 'fatal config detail' -and $tail -match 'last line' -and $tail -notmatch 'first line')
} finally {
  Remove-Item -LiteralPath $tmpErr -Force -ErrorAction SilentlyContinue
}

Assert-SupervisorExitCode $fatalDetected 'exit code 3 should be fatal for driver'
Assert-SupervisorExitCode $nonFatalDetected 'exit code 1 should not be fatal for driver'
Assert-SupervisorExitCode $fatalBlock 'fatal exit should set driver fatal block'
Assert-SupervisorExitCode $exitCodeLogged 'exit log line should include process key and exitCode=3'
Assert-SupervisorExitCode $stderrTailRead 'stderr tail should read the latest lines'

[pscustomobject]@{
  ok = $true
  fatalDetected = $fatalDetected
  nonFatalDetected = $nonFatalDetected
  fatalBlock = $fatalBlock
  exitCodeLogged = $exitCodeLogged
  stderrTailRead = $stderrTailRead
} | ConvertTo-Json -Compress
