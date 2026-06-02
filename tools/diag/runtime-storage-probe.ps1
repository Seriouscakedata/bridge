# runtime-storage-probe.ps1 -- isolated storage/race probe for bridge state primitives.
param(
  [int]$Iterations = 300,
  [int]$ConcurrentIterations = 150,
  [int]$ReaderIterations = 300,
  [switch]$KeepWorkDirs
)

$ErrorActionPreference = 'Stop'
$bridgeRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Get-ProbeRuntimeRoot {
  $base = [string]$env:USERPROFILE
  if ([string]::IsNullOrWhiteSpace($base)) { $dir = Join-Path $bridgeRoot 'control' }
  else { $dir = Join-Path $base '.bridge-runtime' }
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return $dir
}

function New-ProbeDirectory {
  param([string]$Path)
  [System.IO.Directory]::CreateDirectory($Path) | Out-Null
}

function Clear-ProbeDirectory {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return }
  if ([System.IO.Directory]::Exists($Path)) {
    [System.IO.Directory]::Delete($Path, $true)
  }
}

function Test-ProbeDirectoryWritable {
  param([string]$Path)
  try {
    New-ProbeDirectory -Path $Path
    $testFile = Join-Path $Path '.write-test'
    [System.IO.File]::WriteAllText($testFile, 'ok', (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::Delete($testFile)
    return @{ ok = $true; error = '' }
  } catch {
    return @{ ok = $false; error = $_.Exception.Message }
  }
}

function New-ProbeChecksum {
  param([string]$Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $hash = $sha.ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally {
    $sha.Dispose()
  }
}

function New-ProbeStateJson {
  param([string]$Writer, [int]$Seq)
  $payload = "$Writer|$Seq"
  [pscustomobject]@{
    kind = 'runtime-storage-probe'
    writer = $Writer
    seq = $Seq
    payload = $payload
    checksum = (New-ProbeChecksum $payload)
    ts = (Get-Date).ToUniversalTime().ToString('o')
  } | ConvertTo-Json -Compress -Depth 4
}

function Write-ProbeAtomicFile {
  param([string]$Path, [string]$Content)
  $tmp = "$Path.tmp.$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
  [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
  $tries = 0
  $maxTries = 6
  $sharing = 0
  while ($true) {
    try {
      if (Test-Path -LiteralPath $Path) {
        [System.IO.File]::Replace($tmp, $Path, $null)
      } else {
        [System.IO.File]::Move($tmp, $Path)
      }
      return @{ ok = $true; retriesUsed = $tries; sharingViolation = $sharing; renameFail = 0; copyFallback = 0 }
    } catch [System.IO.IOException] {
      $tries++
      $sharing++
      if ($tries -ge $maxTries) {
        try {
          Copy-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
          Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
          return @{ ok = $true; retriesUsed = $tries; sharingViolation = $sharing; renameFail = 0; copyFallback = 1 }
        } catch {
          Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
          return @{ ok = $false; retriesUsed = $tries; sharingViolation = $sharing; renameFail = 1; copyFallback = 0; error = $_.Exception.Message }
        }
      }
      Start-Sleep -Milliseconds (60 * $tries)
    } catch {
      $tries++
      if ($tries -ge $maxTries) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return @{ ok = $false; retriesUsed = $tries; sharingViolation = $sharing; renameFail = 1; copyFallback = 0; error = $_.Exception.Message }
      }
      Start-Sleep -Milliseconds (60 * $tries)
    }
  }
}

function Read-ProbeState {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return @{ ok = $false; missing = 1; parseError = 0; checksumMismatch = 0; error = 'missing' } }
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $obj = $raw | ConvertFrom-Json
    $payload = [string]$obj.payload
    $expected = New-ProbeChecksum $payload
    if ($expected -ne [string]$obj.checksum) {
      return @{ ok = $false; missing = 0; parseError = 0; checksumMismatch = 1; error = 'checksum-mismatch' }
    }
    return @{ ok = $true; missing = 0; parseError = 0; checksumMismatch = 0; writer = [string]$obj.writer; seq = [int]$obj.seq }
  } catch {
    return @{ ok = $false; missing = 0; parseError = 1; checksumMismatch = 0; error = $_.Exception.Message }
  }
}

function Use-ProbeMutex {
  param([string]$Name, [scriptblock]$Body)
  $mutex = New-Object System.Threading.Mutex($false, $Name)
  $got = $false
  try {
    try {
      $got = $mutex.WaitOne(15000)
    } catch [System.Threading.AbandonedMutexException] {
      $got = $true
    }
    if (-not $got) { throw "Could not acquire probe mutex $Name within 15s" }
    & $Body
  } finally {
    if ($got) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
  }
}

function New-Metrics {
  [ordered]@{
    writes = 0
    reads = 0
    renameFail = 0
    sharingViolation = 0
    corruptRead = 0
    missingRead = 0
    parseError = 0
    checksumMismatch = 0
    retriesUsed = 0
    copyFallback = 0
    errors = @()
  }
}

function Add-WriteMetric {
  param($Metrics, $WriteResult)
  $Metrics.writes++
  $Metrics.renameFail += [int]$WriteResult.renameFail
  $Metrics.sharingViolation += [int]$WriteResult.sharingViolation
  $Metrics.retriesUsed += [int]$WriteResult.retriesUsed
  $Metrics.copyFallback += [int]$WriteResult.copyFallback
  if (-not $WriteResult.ok -and $WriteResult.error) { $Metrics.errors += [string]$WriteResult.error }
}

function Add-ReadMetric {
  param($Metrics, $ReadResult)
  $Metrics.reads++
  if (-not $ReadResult.ok) {
    if ($ReadResult.missing) { $Metrics.missingRead++ }
    elseif ($ReadResult.parseError) { $Metrics.parseError++; $Metrics.corruptRead++ }
    elseif ($ReadResult.checksumMismatch) { $Metrics.checksumMismatch++; $Metrics.corruptRead++ }
    else { $Metrics.corruptRead++ }
    if ($ReadResult.error) { $Metrics.errors += [string]$ReadResult.error }
  }
}

function Complete-Metrics {
  param($Metrics)
  $readDenom = [math]::Max(1, [int]$Metrics.reads)
  $writeDenom = [math]::Max(1, [int]$Metrics.writes)
  [pscustomobject]@{
    writes = [int]$Metrics.writes
    reads = [int]$Metrics.reads
    renameFail = [int]$Metrics.renameFail
    sharingViolation = [int]$Metrics.sharingViolation
    corruptRead = [int]$Metrics.corruptRead
    missingRead = [int]$Metrics.missingRead
    parseError = [int]$Metrics.parseError
    checksumMismatch = [int]$Metrics.checksumMismatch
    retriesUsed = [int]$Metrics.retriesUsed
    copyFallback = [int]$Metrics.copyFallback
    corruptReadRate = [math]::Round(([double]$Metrics.corruptRead / $readDenom), 6)
    renameFailRate = [math]::Round(([double]$Metrics.renameFail / $writeDenom), 6)
    sharingViolationRate = [math]::Round(([double]$Metrics.sharingViolation / $writeDenom), 6)
    sampleErrors = @($Metrics.errors | Select-Object -First 3)
  }
}

function Invoke-SingleWriterLoop {
  param([string]$Dir, [int]$Count)
  New-Item -ItemType Directory -Path $Dir -Force | Out-Null
  $path = Join-Path $Dir 'state.json'
  $m = New-Metrics
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  foreach ($i in 1..$Count) {
    $wr = Write-ProbeAtomicFile -Path $path -Content (New-ProbeStateJson -Writer 'single' -Seq $i)
    Add-WriteMetric -Metrics $m -WriteResult $wr
    $rr = Read-ProbeState -Path $path
    Add-ReadMetric -Metrics $m -ReadResult $rr
  }
  $sw.Stop()
  $done = Complete-Metrics $m
  $done | Add-Member -NotePropertyName elapsedMs -NotePropertyValue $sw.ElapsedMilliseconds -Force
  return $done
}

$workerBlock = {
  param(
    [string]$Role,
    [string]$Path,
    [int]$Iterations,
    [bool]$UseWriteMutex,
    [bool]$UseReadMutex,
    [string]$MutexName
  )

  function New-ProbeChecksum {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
      $hash = $sha.ComputeHash($bytes)
      return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally { $sha.Dispose() }
  }
  function New-ProbeStateJson {
    param([string]$Writer, [int]$Seq)
    $payload = "$Writer|$Seq"
    [pscustomobject]@{ kind='runtime-storage-probe'; writer=$Writer; seq=$Seq; payload=$payload; checksum=(New-ProbeChecksum $payload); ts=(Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress -Depth 4
  }
  function Write-ProbeAtomicFile {
    param([string]$Path, [string]$Content)
    $tmp = "$Path.tmp.$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
    [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
    $tries = 0; $maxTries = 6; $sharing = 0
    while ($true) {
      try {
        if (Test-Path -LiteralPath $Path) { [System.IO.File]::Replace($tmp, $Path, $null) }
        else { [System.IO.File]::Move($tmp, $Path) }
        return @{ ok=$true; retriesUsed=$tries; sharingViolation=$sharing; renameFail=0; copyFallback=0 }
      } catch [System.IO.IOException] {
        $tries++; $sharing++
        if ($tries -ge $maxTries) {
          try {
            Copy-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return @{ ok=$true; retriesUsed=$tries; sharingViolation=$sharing; renameFail=0; copyFallback=1 }
          } catch {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            return @{ ok=$false; retriesUsed=$tries; sharingViolation=$sharing; renameFail=1; copyFallback=0; error=$_.Exception.Message }
          }
        }
        Start-Sleep -Milliseconds (60 * $tries)
      } catch {
        $tries++
        if ($tries -ge $maxTries) {
          Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
          return @{ ok=$false; retriesUsed=$tries; sharingViolation=$sharing; renameFail=1; copyFallback=0; error=$_.Exception.Message }
        }
        Start-Sleep -Milliseconds (60 * $tries)
      }
    }
  }
  function Read-ProbeState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{ ok=$false; missing=1; parseError=0; checksumMismatch=0; error='missing' } }
    try {
      $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
      $obj = $raw | ConvertFrom-Json
      $payload = [string]$obj.payload
      if ((New-ProbeChecksum $payload) -ne [string]$obj.checksum) { return @{ ok=$false; missing=0; parseError=0; checksumMismatch=1; error='checksum-mismatch' } }
      return @{ ok=$true; missing=0; parseError=0; checksumMismatch=0 }
    } catch {
      return @{ ok=$false; missing=0; parseError=1; checksumMismatch=0; error=$_.Exception.Message }
    }
  }
  function Use-ProbeMutex {
    param([string]$Name, [scriptblock]$Body)
    $mutex = New-Object System.Threading.Mutex($false, $Name)
    $got = $false
    try {
      try { $got = $mutex.WaitOne(15000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
      if (-not $got) { throw "Could not acquire probe mutex $Name within 15s" }
      & $Body
    } finally {
      if ($got) { try { $mutex.ReleaseMutex() } catch {} }
      $mutex.Dispose()
    }
  }
  function New-Metrics {
    [ordered]@{ writes=0; reads=0; renameFail=0; sharingViolation=0; corruptRead=0; missingRead=0; parseError=0; checksumMismatch=0; retriesUsed=0; copyFallback=0; errors=@() }
  }
  function Add-WriteMetric {
    param($Metrics, $WriteResult)
    $Metrics.writes++; $Metrics.renameFail += [int]$WriteResult.renameFail; $Metrics.sharingViolation += [int]$WriteResult.sharingViolation; $Metrics.retriesUsed += [int]$WriteResult.retriesUsed; $Metrics.copyFallback += [int]$WriteResult.copyFallback
    if (-not $WriteResult.ok -and $WriteResult.error) { $Metrics.errors += [string]$WriteResult.error }
  }
  function Add-ReadMetric {
    param($Metrics, $ReadResult)
    $Metrics.reads++
    if (-not $ReadResult.ok) {
      if ($ReadResult.missing) { $Metrics.missingRead++ }
      elseif ($ReadResult.parseError) { $Metrics.parseError++; $Metrics.corruptRead++ }
      elseif ($ReadResult.checksumMismatch) { $Metrics.checksumMismatch++; $Metrics.corruptRead++ }
      else { $Metrics.corruptRead++ }
      if ($ReadResult.error) { $Metrics.errors += [string]$ReadResult.error }
    }
  }
  function Complete-Metrics {
    param($Metrics)
    $readDenom = [math]::Max(1, [int]$Metrics.reads); $writeDenom = [math]::Max(1, [int]$Metrics.writes)
    [pscustomobject]@{
      role = $Role
      writes = [int]$Metrics.writes
      reads = [int]$Metrics.reads
      renameFail = [int]$Metrics.renameFail
      sharingViolation = [int]$Metrics.sharingViolation
      corruptRead = [int]$Metrics.corruptRead
      missingRead = [int]$Metrics.missingRead
      parseError = [int]$Metrics.parseError
      checksumMismatch = [int]$Metrics.checksumMismatch
      retriesUsed = [int]$Metrics.retriesUsed
      copyFallback = [int]$Metrics.copyFallback
      corruptReadRate = [math]::Round(([double]$Metrics.corruptRead / $readDenom), 6)
      renameFailRate = [math]::Round(([double]$Metrics.renameFail / $writeDenom), 6)
      sharingViolationRate = [math]::Round(([double]$Metrics.sharingViolation / $writeDenom), 6)
      sampleErrors = @($Metrics.errors | Select-Object -First 3)
    }
  }

  $m = New-Metrics
  if ($Role -like 'writer*') {
    for ($i = 1; $i -le $Iterations; $i++) {
      $body = { Write-ProbeAtomicFile -Path $Path -Content (New-ProbeStateJson -Writer $Role -Seq $i) }
      if ($UseWriteMutex) { $wr = Use-ProbeMutex -Name $MutexName -Body $body }
      else { $wr = & $body }
      Add-WriteMetric -Metrics $m -WriteResult $wr
    }
  } else {
    for ($i = 1; $i -le $Iterations; $i++) {
      $body = { Read-ProbeState -Path $Path }
      if ($UseReadMutex) { $rr = Use-ProbeMutex -Name $MutexName -Body $body }
      else { $rr = & $body }
      Add-ReadMetric -Metrics $m -ReadResult $rr
    }
  }
  Complete-Metrics $m
}

function Invoke-ConcurrentScenario {
  param(
    [string]$Dir,
    [string]$ScenarioName,
    [bool]$UseWriteMutex,
    [bool]$UseReadMutex,
    [int]$WriterIterations,
    [int]$ReadIterations
  )
  New-Item -ItemType Directory -Path $Dir -Force | Out-Null
  $path = Join-Path $Dir 'state.json'
  [System.IO.File]::WriteAllText($path, (New-ProbeStateJson -Writer 'seed' -Seq 0), (New-Object System.Text.UTF8Encoding($false)))
  $mutexName = 'Global\BridgeRuntimeProbe_' + ([System.Guid]::NewGuid().ToString('N'))
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $jobs = @()
  $jobs += Start-Job -ScriptBlock $workerBlock -ArgumentList @('writer-A', $path, $WriterIterations, $UseWriteMutex, $UseReadMutex, $mutexName)
  $jobs += Start-Job -ScriptBlock $workerBlock -ArgumentList @('writer-B', $path, $WriterIterations, $UseWriteMutex, $UseReadMutex, $mutexName)
  $jobs += Start-Job -ScriptBlock $workerBlock -ArgumentList @('reader', $path, $ReadIterations, $UseWriteMutex, $UseReadMutex, $mutexName)
  try {
    $done = Wait-Job -Job $jobs -Timeout 45
    if (@($done).Count -ne @($jobs).Count) {
      throw "Probe scenario '$ScenarioName' timed out waiting for child jobs"
    }
    $parts = @($jobs | Receive-Job)
  } finally {
    $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
  }
  $sw.Stop()
  $writes = ($parts | Measure-Object -Property writes -Sum).Sum
  $reads = ($parts | Measure-Object -Property reads -Sum).Sum
  $renameFail = ($parts | Measure-Object -Property renameFail -Sum).Sum
  $sharing = ($parts | Measure-Object -Property sharingViolation -Sum).Sum
  $corrupt = ($parts | Measure-Object -Property corruptRead -Sum).Sum
  $missing = ($parts | Measure-Object -Property missingRead -Sum).Sum
  $parse = ($parts | Measure-Object -Property parseError -Sum).Sum
  $checksum = ($parts | Measure-Object -Property checksumMismatch -Sum).Sum
  $retries = ($parts | Measure-Object -Property retriesUsed -Sum).Sum
  $copyFallback = ($parts | Measure-Object -Property copyFallback -Sum).Sum
  [pscustomobject]@{
    scenario = $ScenarioName
    writeMutex = $UseWriteMutex
    readMutex = $UseReadMutex
    writes = [int]$writes
    reads = [int]$reads
    renameFail = [int]$renameFail
    sharingViolation = [int]$sharing
    corruptRead = [int]$corrupt
    missingRead = [int]$missing
    parseError = [int]$parse
    checksumMismatch = [int]$checksum
    retriesUsed = [int]$retries
    copyFallback = [int]$copyFallback
    corruptReadRate = [math]::Round(([double]$corrupt / [math]::Max(1, [int]$reads)), 6)
    renameFailRate = [math]::Round(([double]$renameFail / [math]::Max(1, [int]$writes)), 6)
    sharingViolationRate = [math]::Round(([double]$sharing / [math]::Max(1, [int]$writes)), 6)
    elapsedMs = $sw.ElapsedMilliseconds
    workers = @($parts)
  }
}

function Get-LocationReport {
  param([string]$Name, [string]$BaseDir)
  New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null
  [pscustomobject]@{
    name = $Name
    baseDir = $BaseDir
    singleWriterAtomicLoop = Invoke-SingleWriterLoop -Dir (Join-Path $BaseDir 'single-writer') -Count $Iterations
    twoWritersNoMutex = Invoke-ConcurrentScenario -Dir (Join-Path $BaseDir 'two-writers-no-mutex') -ScenarioName 'two-writers-no-mutex' -UseWriteMutex:$false -UseReadMutex:$false -WriterIterations $ConcurrentIterations -ReadIterations $ReaderIterations
    twoWritersMutexReadUnlocked = Invoke-ConcurrentScenario -Dir (Join-Path $BaseDir 'two-writers-mutex-read-unlocked') -ScenarioName 'two-writers-mutex-read-unlocked' -UseWriteMutex:$true -UseReadMutex:$false -WriterIterations $ConcurrentIterations -ReadIterations $ReaderIterations
    twoWritersFullMutex = Invoke-ConcurrentScenario -Dir (Join-Path $BaseDir 'two-writers-full-mutex') -ScenarioName 'two-writers-full-mutex' -UseWriteMutex:$true -UseReadMutex:$true -WriterIterations $ConcurrentIterations -ReadIterations $ReaderIterations
  }
}

function Get-ProbeVerdict {
  param($OneDrive, $Runtime)
  $reasons = New-Object 'System.Collections.Generic.List[string]'
  $labels = New-Object 'System.Collections.Generic.List[string]'

  $odSingleFaults = [int]$OneDrive.singleWriterAtomicLoop.renameFail + [int]$OneDrive.singleWriterAtomicLoop.sharingViolation + [int]$OneDrive.singleWriterAtomicLoop.corruptRead
  $rtSingleFaults = [int]$Runtime.singleWriterAtomicLoop.renameFail + [int]$Runtime.singleWriterAtomicLoop.sharingViolation + [int]$Runtime.singleWriterAtomicLoop.corruptRead
  if ($odSingleFaults -gt 0 -and $odSingleFaults -ge [math]::Max(2, ($rtSingleFaults * 5))) {
    [void]$labels.Add('onedrive-sync-fault')
    [void]$reasons.Add(("single-writer faults: OneDrive={0}, runtime={1}" -f $odSingleFaults, $rtSingleFaults))
  }

  $noMutexCorrupt = [int]$OneDrive.twoWritersNoMutex.corruptRead + [int]$Runtime.twoWritersNoMutex.corruptRead
  $fullMutexCorrupt = [int]$OneDrive.twoWritersFullMutex.corruptRead + [int]$Runtime.twoWritersFullMutex.corruptRead
  if ($noMutexCorrupt -gt 0 -and $fullMutexCorrupt -le [math]::Floor($noMutexCorrupt / 10)) {
    [void]$labels.Add('process-race')
    [void]$reasons.Add(("two-writer corrupt reads: noMutex={0}, fullMutex={1}" -f $noMutexCorrupt, $fullMutexCorrupt))
  }

  $writerMutexReaderUnlocked = [int]$OneDrive.twoWritersMutexReadUnlocked.corruptRead + [int]$Runtime.twoWritersMutexReadUnlocked.corruptRead
  if ($writerMutexReaderUnlocked -gt 0 -and $fullMutexCorrupt -le [math]::Floor($writerMutexReaderUnlocked / 10)) {
    [void]$labels.Add('read-without-lock')
    [void]$reasons.Add(("writer-mutex/reader-unlocked corrupt reads={0}, fullMutex={1}" -f $writerMutexReaderUnlocked, $fullMutexCorrupt))
  }

  if ($labels.Count -eq 0) {
    $allFaults = $odSingleFaults + $rtSingleFaults + $noMutexCorrupt + $fullMutexCorrupt + $writerMutexReaderUnlocked
    return [pscustomobject]@{
      class = 'no-fault-observed'
      text = "No storage/corruption fault observed in bounded probe; measured faults=$allFaults. Treat as inconclusive, not as proof that runtime migration is safe."
      reasons = @("single-writer faults OneDrive=$odSingleFaults runtime=$rtSingleFaults", "two-writer corrupt reads noMutex=$noMutexCorrupt writerMutexReaderUnlocked=$writerMutexReaderUnlocked fullMutex=$fullMutexCorrupt")
    }
  }
  $unique = @($labels | Select-Object -Unique)
  $class = if ($unique.Count -eq 1) { $unique[0] } else { 'both/mixed' }
  [pscustomobject]@{
    class = $class
    text = ("{0}: {1}" -f $class, (($reasons | Select-Object -Unique) -join '; '))
    reasons = @($reasons | Select-Object -Unique)
  }
}

$runId = (Get-Date -Format 'yyyyMMddHHmmss') + '-' + ([System.Guid]::NewGuid().ToString('N').Substring(0,8))
$oneDriveDir = Join-Path $bridgeRoot ("tmp\probe-onedrive-$runId")
$runtimeRoot = Get-ProbeRuntimeRoot
$requestedRuntimeDir = Join-Path $runtimeRoot ("probe-test-$runId")
$runtimeAccess = Test-ProbeDirectoryWritable -Path $requestedRuntimeDir
$runtimeDir = $requestedRuntimeDir
$runtimeLocationNote = 'Get-RuntimeRoot'
if (-not $runtimeAccess.ok) {
  $fallbackBase = Join-Path $env:USERPROFILE 'AppData\Local\Temp\claude'
  if (-not (Test-Path -LiteralPath $fallbackBase)) { New-ProbeDirectory -Path $fallbackBase }
  $runtimeDir = Join-Path $fallbackBase ("bridge-runtime-probe-test-$runId")
  $runtimeLocationNote = 'sandbox-fallback-temp-claude'
}
$start = Get-Date

try {
  foreach ($p in @($oneDriveDir, $runtimeDir)) {
    New-ProbeDirectory -Path $p
  }

  $oneDrive = Get-LocationReport -Name 'onedrive-synced' -BaseDir $oneDriveDir
  $runtime = Get-LocationReport -Name 'non-synced-runtime' -BaseDir $runtimeDir
  $verdict = Get-ProbeVerdict -OneDrive $oneDrive -Runtime $runtime
  $end = Get-Date

  $report = [pscustomobject]@{
    ok = $true
    started = $start.ToUniversalTime().ToString('o')
    finished = $end.ToUniversalTime().ToString('o')
    elapsedSeconds = [math]::Round(($end - $start).TotalSeconds, 3)
    runId = $runId
    bridgeRoot = $bridgeRoot
    runtimeRoot = $runtimeRoot
    requestedRuntimeDir = $requestedRuntimeDir
    runtimeRootWritable = [bool]$runtimeAccess.ok
    runtimeRootAccessError = [string]$runtimeAccess.error
    nonSyncedLocationNote = $runtimeLocationNote
    parameters = [pscustomobject]@{
      iterations = $Iterations
      concurrentIterations = $ConcurrentIterations
      readerIterations = $ReaderIterations
    }
    locations = @($oneDrive, $runtime)
    verdict = $verdict
    cleanup = if ($KeepWorkDirs) { 'kept' } else { 'removed' }
  }

  $json = $report | ConvertTo-Json -Depth 20
  Write-Output $json
  Write-Output ("VERDICT: {0}" -f $verdict.text)
} finally {
  if (-not $KeepWorkDirs) {
    foreach ($p in @($oneDriveDir, $runtimeDir)) {
      try { Clear-ProbeDirectory -Path $p } catch {}
    }
  }
}
