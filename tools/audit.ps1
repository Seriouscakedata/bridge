# audit.ps1 -- main bridge audit orchestrator.
# Runs security + functional auditors back-to-back, merges findings into a single
# daily report (JSON + Markdown), and feeds critical issues into the backlog.
# Designed to be invoked from tools/audit-runner.ps1 during idle windows.

$ErrorActionPreference = 'Continue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
try { [Console]::OutputEncoding = $Utf8NoBom } catch {}

function Get-AuditBridgeRoot {
  param([string]$Hint)
  if ($Hint -and (Test-Path -LiteralPath $Hint)) { return ([System.IO.Path]::GetFullPath($Hint)) }
  if (Get-Command Get-BridgeRoot -ErrorAction SilentlyContinue) {
    try { return (Get-BridgeRoot) } catch {}
  }
  # tools/audit.ps1 -> parent of tools/ is bridge root
  return ([System.IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)))
}

function Get-AuditDir {
  param([string]$BridgePath)
  Join-Path $BridgePath 'audit'
}

function Normalize-AuditChannelSlug {
  param([string]$Channel)
  if (Get-Command Normalize-ChannelSlug -ErrorAction SilentlyContinue) {
    try { return (Normalize-ChannelSlug $Channel) } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($Channel)) { return 'main' }
  $slug = ([string]$Channel).Trim().ToLowerInvariant()
  $slug = ($slug -replace '\s+', '-' -replace '[^a-z0-9_-]+', '-').Trim('-','_')
  if ([string]::IsNullOrWhiteSpace($slug)) { return 'main' }
  return $slug
}

function Test-AuditSamePath {
  param([string]$Left, [string]$Right)
  if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
  try {
    $trim = [char[]]@('\','/')
    $a = [System.IO.Path]::GetFullPath($Left).TrimEnd($trim)
    $b = [System.IO.Path]::GetFullPath($Right).TrimEnd($trim)
    return [string]::Equals($a, $b, [System.StringComparison]::OrdinalIgnoreCase)
  } catch {
    return ([string]::Equals($Left.TrimEnd('\','/'), $Right.TrimEnd('\','/'), [System.StringComparison]::OrdinalIgnoreCase))
  }
}

function Get-AuditChannelDir {
  param([string]$BridgePath, [string]$Channel)
  $slug = Normalize-AuditChannelSlug -Channel $Channel
  if (Get-Command Get-ChannelDir -ErrorAction SilentlyContinue) {
    try { return (Get-ChannelDir -Slug $slug) } catch {}
  }
  return (Join-Path (Join-Path $BridgePath 'channels') $slug)
}

function Get-AuditReportDir {
  param(
    [string]$BridgePath,
    [string]$Channel = 'main',
    [string]$Kind = 'bridge'
  )
  $slug = Normalize-AuditChannelSlug -Channel $Channel
  $kindNorm = ([string]$Kind).ToLowerInvariant()
  if ($slug -eq 'main' -or $kindNorm -eq 'bridge') {
    return (Get-AuditDir -BridgePath $BridgePath)
  }
  return (Join-Path (Get-AuditChannelDir -BridgePath $BridgePath -Channel $slug) 'audit')
}

function New-AuditContext {
  param(
    [string]$BridgePath,
    [string]$Channel = 'main',
    [string]$ProjectRoot = $null
  )
  $bridgeRoot = Get-AuditBridgeRoot -Hint $BridgePath
  $slug = Normalize-AuditChannelSlug -Channel $Channel
  $target = if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    if ($slug -eq 'main') { $bridgeRoot } else { '' }
  } else {
    [string]$ProjectRoot
  }
  try { $target = [System.IO.Path]::GetFullPath($target) } catch {}
  $isBridge = ($slug -eq 'main')
  $kind = if ($isBridge) { 'bridge' } else { 'project' }
  $reportRoot = Get-AuditReportDir -BridgePath $bridgeRoot -Channel $slug -Kind $kind
  $backlogChannel = if ($kind -eq 'bridge') { 'main' } else { $slug }
  [pscustomobject][ordered]@{
    kind            = $kind
    channel         = $slug
    bridge_root     = $bridgeRoot
    target_root     = $target
    report_root     = $reportRoot
    backlog_channel = $backlogChannel
    profile         = if ($kind -eq 'bridge') { 'bridge-self' } else { 'external-project' }
  }
}

function Get-AuditLockPath {
  param([string]$BridgePath)
  Join-Path (Get-AuditDir -BridgePath $BridgePath) '.audit.lock'
}

function Get-AuditLastMarker {
  param([string]$BridgePath, [string]$AuditDir = $null)
  $dir = if ([string]::IsNullOrWhiteSpace($AuditDir)) { Get-AuditDir -BridgePath $BridgePath } else { $AuditDir }
  Join-Path $dir 'audit.last'
}

function Get-FindingsLedgerPath {
  param([string]$BridgePath, [string]$AuditDir = $null)
  $dir = if ([string]::IsNullOrWhiteSpace($AuditDir)) { Get-AuditDir -BridgePath $BridgePath } else { $AuditDir }
  Join-Path $dir 'findings-ledger.jsonl'
}

function Get-AuditMainBacklogPath {
  param([string]$BridgePath)
  $channelPath = Join-Path $BridgePath 'channels\main\backlog.jsonl'
  $channelDir = Split-Path -Parent $channelPath
  if (Test-Path -LiteralPath $channelDir -PathType Container) { return $channelPath }
  return (Join-Path $BridgePath 'backlog.jsonl')
}

function Get-AuditBacklogPath {
  param([string]$BridgePath, [string]$Channel = 'main')
  $slug = Normalize-AuditChannelSlug -Channel $Channel
  if ($slug -eq 'main') { return (Get-AuditMainBacklogPath -BridgePath $BridgePath) }
  if (Get-Command Get-ChannelBacklogPath -ErrorAction SilentlyContinue) {
    try { return (Get-ChannelBacklogPath -Slug $slug) } catch {}
  }
  return (Join-Path (Get-AuditChannelDir -BridgePath $BridgePath -Channel $slug) 'backlog.jsonl')
}

function Format-AuditNativeArg {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) { return '""' }
  $s = [string]$Value
  if ($s.Length -eq 0) { return '""' }
  if ($s -notmatch '[\s"]') { return $s }
  return '"' + ($s -replace '"','\"') + '"'
}

function Invoke-AuditBridgeLocked {
  param([scriptblock]$Body)
  $mutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeCodexBridgeLock')
  $got = $false
  try {
    try {
      $got = $mutex.WaitOne(15000)
    } catch [System.Threading.AbandonedMutexException] {
      $got = $true
    }
    if (-not $got) { throw 'Could not acquire bridge lock within 15s' }
    & $Body
  } finally {
    if ($got) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
  }
}

function Write-AuditLog {
  param([string]$BridgePath, [string]$Message)
  try {
    $dir = Get-AuditDir -BridgePath $BridgePath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $log = Join-Path $dir 'audit.log'
    try {
      if (Get-Command Rotate-LogIfBig -ErrorAction SilentlyContinue) {
        Rotate-LogIfBig -Path $log -MaxBytes 200KB
      }
    } catch {}
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ([string]$Message)
    [System.IO.File]::AppendAllText($log, ($line + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

function Write-AuditAtomicFile {
  param([string]$Path, [string]$Content)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $tmp = "$Path.tmp.$([guid]::NewGuid().ToString('N').Substring(0,8))"
  [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
  if (Test-Path -LiteralPath $Path) { Move-Item -LiteralPath $tmp -Destination $Path -Force }
  else { Move-Item -LiteralPath $tmp -Destination $Path }
}

function Test-AuditLock {
  # Returns the PID inside the lock if it still belongs to a live process, otherwise $null.
  param([string]$BridgePath)
  $lock = Get-AuditLockPath -BridgePath $BridgePath
  if (-not (Test-Path -LiteralPath $lock)) { return $null }
  try {
    $raw = (Get-Content -LiteralPath $lock -Raw -Encoding UTF8).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $lockPid = [int]$raw
    if ($lockPid -le 0) { return $null }
    $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
    if ($proc) { return $lockPid }
    return $null
  } catch { return $null }
}

function New-AuditLock {
  param([string]$BridgePath)
  $dir = Get-AuditDir -BridgePath $BridgePath
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $lock = Get-AuditLockPath -BridgePath $BridgePath
  [System.IO.File]::WriteAllText($lock, [string]$PID, (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-AuditLock {
  param([string]$BridgePath)
  $lock = Get-AuditLockPath -BridgePath $BridgePath
  if (Test-Path -LiteralPath $lock) {
    try { Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue } catch {}
  }
}

function Invoke-AuditSubcomponent {
  # Dot-sources an auditor script (lives in tools/) and invokes its entry function.
  # Returns @{ findings = @(...); runtime_sec = N; error = $null|string }.
  param(
    [string]$BridgePath,
    [string]$ScriptName,
    [string]$EntryFunction,
    [string]$TargetRoot = $null,
    [string]$AuditKind = 'bridge'
  )
  $result = @{ findings = @(); runtime_sec = 0.0; error = $null }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    $scriptPath = Join-Path (Join-Path $BridgePath 'tools') $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
      $result.error = "missing: $ScriptName"
      Write-AuditLog -BridgePath $BridgePath -Message "subcomponent $ScriptName not present; skipped"
      return $result
    }
    . $scriptPath
    $fn = Get-Command -Name $EntryFunction -ErrorAction SilentlyContinue
    if (-not $fn) {
      $result.error = "function $EntryFunction not exported by $ScriptName"
      return $result
    }
    $raw = & $EntryFunction -BridgePath $BridgePath -TargetRoot $TargetRoot -AuditKind $AuditKind
    if ($null -ne $raw) {
      # Accept either an array of finding objects, or @{ findings = @(...) }
      if ($raw -is [System.Collections.IDictionary] -and $raw.Contains('findings')) {
        $result.findings = @($raw['findings'])
      } elseif ($raw.PSObject -and $raw.PSObject.Properties.Name -contains 'findings') {
        $result.findings = @($raw.findings)
      } else {
        $result.findings = @($raw)
      }
    }
  } catch {
    $result.error = [string]$_.Exception.Message
    Write-AuditLog -BridgePath $BridgePath -Message "subcomponent $ScriptName threw: $($_.Exception.Message)"
  } finally {
    $sw.Stop()
    $result.runtime_sec = [math]::Round($sw.Elapsed.TotalSeconds, 2)
  }
  return $result
}

function Get-AuditFindingField {
  param($Raw, [string[]]$Names)
  if ($null -eq $Raw) { return $null }
  foreach ($name in $Names) {
    try {
      if ($Raw -is [System.Collections.IDictionary] -and $Raw.Contains($name) -and $null -ne $Raw[$name]) {
        return $Raw[$name]
      }
      if ($Raw.PSObject -and ($Raw.PSObject.Properties.Name -contains $name) -and $null -ne $Raw.$name) {
        return $Raw.$name
      }
    } catch {}
  }
  return $null
}

function Format-AuditFindings {
  # Normalize a raw finding (hashtable or PSObject) into a flat object with known fields.
  param($Source, $Raw)
  $sev = 'info'
  $category = ''
  $component = ''
  $file = ''
  $title = ''
  $detail = ''
  $area = ''
  try {
    if ($Raw -is [string]) {
      $title = [string]$Raw
    } else {
      $rawSev = Get-AuditFindingField -Raw $Raw -Names @('severity','sev','level')
      if ($rawSev) { $sev = ([string]$rawSev).ToLowerInvariant() }

      $rawCategory = Get-AuditFindingField -Raw $Raw -Names @('category','kind','type')
      if ($rawCategory) { $category = ([string]$rawCategory).ToLowerInvariant() }

      $rawTitle = Get-AuditFindingField -Raw $Raw -Names @('title','name','summary','rule','category')
      if ($rawTitle) { $title = [string]$rawTitle }

      $rawDetail = Get-AuditFindingField -Raw $Raw -Names @('detail','message','description','msg')
      if ($rawDetail) { $detail = [string]$rawDetail }
      $rawRecommendation = Get-AuditFindingField -Raw $Raw -Names @('recommendation')
      if ($rawRecommendation) {
        if ($detail) { $detail += " Recommendation: $rawRecommendation" }
        else { $detail = [string]$rawRecommendation }
      }

      $rawComponent = Get-AuditFindingField -Raw $Raw -Names @('component')
      if ($rawComponent) { $component = [string]$rawComponent }

      $rawFile = Get-AuditFindingField -Raw $Raw -Names @('file','path','target')
      if ($rawFile) { $file = [string]$rawFile }

      $rawArea = Get-AuditFindingField -Raw $Raw -Names @('area','path','file','target','component')
      if ($rawArea) { $area = [string]$rawArea }
      if (-not $component -and $rawArea) { $component = [string]$rawArea }
      if (-not $file -and $rawFile) { $file = [string]$rawFile }
      $rawLine = Get-AuditFindingField -Raw $Raw -Names @('line','lineno','line_number')
      if ($rawLine -and $area -and $area -notmatch ':\d+$') { $area += ":$rawLine" }
    }
  } catch {}
  if ($sev -notin @('critical','warning','info')) {
    switch ($sev) {
      'high'   { $sev = 'critical' }
      'err'    { $sev = 'critical' }
      'error'  { $sev = 'critical' }
      'warn'   { $sev = 'warning' }
      'medium' { $sev = 'warning' }
      'low'    { $sev = 'info' }
      default  { $sev = 'info' }
    }
  }
  if ([string]::IsNullOrWhiteSpace($title)) { $title = '(no title)' }
  return [pscustomobject]@{
    source   = [string]$Source
    severity = $sev
    category = $category
    component = $component
    file = $file
    title    = $title
    detail   = $detail
    area     = $area
  }
}

function Get-AuditSeverityCounts {
  param($Findings)
  $c = @{ critical = 0; warning = 0; info = 0 }
  foreach ($f in @($Findings)) {
    $s = [string]$f.severity
    if ($c.ContainsKey($s)) { $c[$s] = $c[$s] + 1 } else { $c.info = $c.info + 1 }
  }
  return $c
}

function Merge-AuditFindings {
  param($Findings)
  $deduped = New-Object 'System.Collections.Generic.List[object]'
  $seen = @{}
  foreach ($f in @($Findings)) {
    $cat = [string](Get-AuditFindingField -Raw $f -Names @('category'))
    if ($cat) { $cat = $cat.ToLowerInvariant() }
    $normalizedCat = $cat -replace '_', '-'
    if ($normalizedCat -eq 'orphaned-files') { $normalizedCat = 'orphaned-file' }
    $key = ''
    if ($normalizedCat -match '(dead|orphan)') {
      $component = [string](Get-AuditFindingField -Raw $f -Names @('component'))
      $file = [string](Get-AuditFindingField -Raw $f -Names @('file'))
      $key = "$normalizedCat|$component|$file"
    }
    if ($key -and $seen.ContainsKey($key)) { continue }
    if ($key) { $seen[$key] = $true }
    [void]$deduped.Add($f)
  }
  return @($deduped.ToArray())
}

function Normalize-AuditLedgerToken {
  param([string]$Value, [string]$Fallback = 'unknown')
  $s = ([string]$Value).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($s)) { $s = $Fallback }
  $s = $s -replace '[\s_]+', '-'
  $s = $s -replace '[^a-z0-9.\-]+', '-'
  $s = $s.Trim('-')
  if ([string]::IsNullOrWhiteSpace($s)) { return $Fallback }
  return $s
}

function Normalize-AuditLedgerPathScope {
  param([string]$Value, [switch]$KeepLine)
  $s = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($s)) { return '' }

  $lineSuffix = ''
  if ($s -match ':(\d+)$') {
    $lineSuffix = ":$($Matches[1])"
    $s = $s -replace ':\d+$', ''
  }

  $s = $s -replace '\\', '/'
  $s = $s -replace '^[A-Za-z]:', ''
  $s = $s.Trim('/')
  if ($s -match '/') {
    $parts = $s -split '/'
    $s = $parts[$parts.Length - 1]
  }
  $s = $s.Trim()
  if ([string]::IsNullOrWhiteSpace($s)) { return '' }
  if ($KeepLine -and $lineSuffix) { return "$s$lineSuffix" }
  return $s
}

function Normalize-AuditLedgerTitle {
  param([string]$Value)
  $s = ([string]$Value).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($s)) { return 'unknown' }
  $s = $s -replace '\d+', '#'
  $s = $s -replace '\s+', ' '
  $s = $s.Trim()
  if ($s.Length -gt 120) { $s = $s.Substring(0, 120) }
  return (Normalize-AuditLedgerToken -Value $s -Fallback 'unknown')
}

function Get-AuditLedgerScope {
  param($Finding, [switch]$KeepLine)
  $scope = [string](Get-AuditFindingField -Raw $Finding -Names @('file'))
  if ([string]::IsNullOrWhiteSpace($scope)) {
    $scope = [string](Get-AuditFindingField -Raw $Finding -Names @('component'))
  }
  if ([string]::IsNullOrWhiteSpace($scope)) {
    $scope = [string](Get-AuditFindingField -Raw $Finding -Names @('area'))
  }
  $normalized = Normalize-AuditLedgerPathScope -Value $scope -KeepLine:$KeepLine
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    $normalized = Normalize-AuditLedgerTitle -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('title')))
  }
  return (Normalize-AuditLedgerToken -Value $normalized -Fallback 'unknown')
}

function Get-AuditLedgerEvidenceKey {
  param($Finding)
  $evidence = [string](Get-AuditFindingField -Raw $Finding -Names @('area'))
  if ([string]::IsNullOrWhiteSpace($evidence)) {
    $evidence = [string](Get-AuditFindingField -Raw $Finding -Names @('file'))
  }
  if ([string]::IsNullOrWhiteSpace($evidence)) {
    $evidence = [string](Get-AuditFindingField -Raw $Finding -Names @('component'))
  }
  $normalized = Normalize-AuditLedgerPathScope -Value $evidence -KeepLine
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    $normalized = Normalize-AuditLedgerTitle -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('title')))
  }
  return (Normalize-AuditLedgerToken -Value $normalized -Fallback 'unknown')
}

function New-FindingId {
  param($Finding)
  $source = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('source'))) -Fallback 'unknown'
  $category = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('category'))) -Fallback 'uncategorized'
  $scope = Get-AuditLedgerScope -Finding $Finding
  $evidenceKey = Get-AuditLedgerEvidenceKey -Finding $Finding
  return "$source|$category|$scope|$evidenceKey"
}

function New-RootCauseKey {
  param($Finding)
  $category = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('category'))) -Fallback 'uncategorized'
  $component = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('component'))) -Fallback ''
  $file = Normalize-AuditLedgerToken -Value (Normalize-AuditLedgerPathScope -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('file'))) -KeepLine) -Fallback ''
  $area = Normalize-AuditLedgerToken -Value (Normalize-AuditLedgerPathScope -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('area'))) -KeepLine) -Fallback ''
  $evidence = $area
  if ([string]::IsNullOrWhiteSpace($evidence)) { $evidence = $file }
  if ([string]::IsNullOrWhiteSpace($component) -and [string]::IsNullOrWhiteSpace($evidence)) {
    $title = Normalize-AuditLedgerTitle -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('title')))
    return "$category|$title"
  }
  if ([string]::IsNullOrWhiteSpace($evidence)) { $evidence = Get-AuditLedgerEvidenceKey -Finding $Finding }
  if ([string]::IsNullOrWhiteSpace($component)) { $component = Get-AuditLedgerScope -Finding $Finding }
  return "$category|$component|$evidence"
}

function Read-FindingsLedger {
  param([string]$LedgerPath)
  $ledger = @{}
  if (-not (Test-Path -LiteralPath $LedgerPath)) { return $ledger }
  foreach ($line in @(Get-Content -LiteralPath $LedgerPath -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $entry = $line | ConvertFrom-Json
      if ($entry -and $entry.rootCauseKey) {
        $ledger[[string]$entry.rootCauseKey] = $entry
      }
    } catch {
      Write-Warning "Skipping malformed findings-ledger line in ${LedgerPath}: $($_.Exception.Message)"
    }
  }
  return $ledger
}

function Set-AuditLedgerEntryValue {
  param($Entry, [string]$Name, $Value)
  if ($Entry.PSObject.Properties.Name -contains $Name) {
    $Entry.$Name = $Value
  } else {
    $Entry | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function New-AuditLedgerEntry {
  param($Finding, [string]$RootCauseKey, [string]$FindingId, [string]$NowText)
  $category = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('category'))) -Fallback 'uncategorized'
  $severity = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('severity'))) -Fallback 'info'
  if ($severity -notin @('critical','warning','info')) { $severity = 'info' }
  $slice = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('source'))) -Fallback 'unknown'
  return [pscustomobject][ordered]@{
    id = $FindingId
    rootCauseKey = $RootCauseKey
    slice = $slice
    category = $category
    severity = $severity
    firstSeen = $NowText
    lastSeen = $NowText
    seenCount = 1
    state = 'new'
    title = [string](Get-AuditFindingField -Raw $Finding -Names @('title'))
  }
}

function Update-FindingsLedger {
  param($CurrentFindings, $Ledger, [datetime]$Now)
  if ($null -eq $Ledger) { $Ledger = @{} }
  $reportFindings = New-Object 'System.Collections.Generic.List[object]'
  $seenThisRun = @{}
  $suppressedCount = 0
  $nowText = $Now.ToUniversalTime().ToString('o')

  foreach ($f in @($CurrentFindings)) {
    $rck = New-RootCauseKey -Finding $f
    $fid = New-FindingId -Finding $f
    if ([string]::IsNullOrWhiteSpace($rck)) { $rck = $fid }
    $seenThisRun[$rck] = $true
    $severity = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $f -Names @('severity'))) -Fallback 'info'
    $isCritical = ($severity -eq 'critical')

    if (-not $Ledger.ContainsKey($rck)) {
      $entry = New-AuditLedgerEntry -Finding $f -RootCauseKey $rck -FindingId $fid -NowText $nowText
      $Ledger[$rck] = $entry
      [void]$reportFindings.Add($f)
      continue
    }

    $entry = $Ledger[$rck]
    $state = Normalize-AuditLedgerToken -Value ([string]$entry.state) -Fallback 'open'
    $seenCount = 0
    try { $seenCount = [int]$entry.seenCount } catch { $seenCount = 0 }
    Set-AuditLedgerEntryValue -Entry $entry -Name 'id' -Value $fid
    Set-AuditLedgerEntryValue -Entry $entry -Name 'lastSeen' -Value $nowText
    Set-AuditLedgerEntryValue -Entry $entry -Name 'seenCount' -Value ($seenCount + 1)
    Set-AuditLedgerEntryValue -Entry $entry -Name 'severity' -Value $severity
    Set-AuditLedgerEntryValue -Entry $entry -Name 'title' -Value ([string](Get-AuditFindingField -Raw $f -Names @('title')))

    if ($state -in @('fixed','suppressed')) {
      Set-AuditLedgerEntryValue -Entry $entry -Name 'state' -Value 'regressed'
      [void]$reportFindings.Add($f)
      continue
    }

    if ($state -eq 'regressed') {
      [void]$reportFindings.Add($f)
      continue
    }

    if ($state -eq 'new') {
      Set-AuditLedgerEntryValue -Entry $entry -Name 'state' -Value 'open'
    }

    if ($isCritical) {
      [void]$reportFindings.Add($f)
    } else {
      $suppressedCount++
    }
  }

  return @{
    ledger = $Ledger
    reportFindings = @($reportFindings.ToArray())
    suppressedCount = $suppressedCount
  }
}

function Write-FindingsLedger {
  param([string]$LedgerPath, $Ledger)
  $entries = @($Ledger.Values | Sort-Object @{ Expression = { [string]$_.firstSeen } }, @{ Expression = { [string]$_.rootCauseKey } })
  $lines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($entry in $entries) {
    [void]$lines.Add(($entry | ConvertTo-Json -Compress -Depth 8))
  }
  $content = [string]::Join("`n", $lines.ToArray())
  if ($content.Length -gt 0) { $content += "`n" }
  Write-AuditAtomicFile -Path $LedgerPath -Content $content
}

function Get-AuditUsefulnessPath {
  param([string]$BridgePath, [string]$AuditDir = $null)
  $dir = if ([string]::IsNullOrWhiteSpace($AuditDir)) { Get-AuditDir -BridgePath $BridgePath } else { $AuditDir }
  Join-Path $dir 'usefulness.jsonl'
}

function Write-AuditUsefulnessScore {
  # Idea 11: after each audit, score how USEFUL it was -- so a noisy / low-value
  # audit becomes visible over time (and a noisy slice can later be downgraded to
  # a cheaper model). Appends one JSON line to audit/usefulness.jsonl.
  #   action_rate           = critical findings that became backlog tasks
  #   resolved_signal_delta = open signals the ledger closed since last run
  #   incident_capture_rate = share of findings that touch runtime reliability
  param(
    [string]$BridgePath,
    $ReportFindings,
    [int]$FiledToBacklog = 0,
    [int]$SuppressedKnown = 0,
    [int]$PrevOpenCount = 0,
    $NewLedger = $null,
    [datetime]$Now = ([datetime]::Now),
    [string]$AuditDir = $null
  )
  try {
    $path = Get-AuditUsefulnessPath -BridgePath $BridgePath -AuditDir $AuditDir
    $findings = @($ReportFindings)
    $total = $findings.Count
    $critical = @($findings | Where-Object { ([string](Get-AuditFindingField -Raw $_ -Names @('severity'))) -eq 'critical' }).Count
    $reliability = @($findings | Where-Object { $s = [string]$_.source; $s -eq 'reliability' -or $s -eq 'functional' }).Count

    $actionRate = 0.0
    if ($critical -gt 0) { $actionRate = [Math]::Round([double]$FiledToBacklog / $critical, 3) }

    $curOpen = 0
    if ($NewLedger) {
      $openStates = @('open','new','regressed')
      $curOpen = @($NewLedger.Values | Where-Object { (Normalize-AuditLedgerToken -Value ([string]$_.state) -Fallback 'open') -in $openStates }).Count
    }
    $resolvedDelta = $PrevOpenCount - $curOpen

    $incidentCapture = 0.0
    if ($total -gt 0) { $incidentCapture = [Math]::Round([double]$reliability / $total, 3) }

    $resolvedNorm = 0.0
    if ($PrevOpenCount -gt 0) { $resolvedNorm = [Math]::Max(0.0, [Math]::Min(1.0, [double]$resolvedDelta / $PrevOpenCount)) }
    $usefulness = [Math]::Round(($actionRate * 0.4) + ($resolvedNorm * 0.35) + ($incidentCapture * 0.25), 3)

    $prevUsefulness = $null
    try {
      if (Test-Path -LiteralPath $path) {
        $lastLine = @(Get-Content -LiteralPath $path -Tail 1 -ErrorAction SilentlyContinue)
        if ($lastLine.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($lastLine[0])) {
          $prevRec = $lastLine[0] | ConvertFrom-Json
          $prevUsefulness = [double]$prevRec.usefulness
        }
      }
    } catch {}
    $trend = 0.0
    if ($null -ne $prevUsefulness) { $trend = [Math]::Round($usefulness - $prevUsefulness, 3) }

    $rec = [ordered]@{
      ts                    = $Now.ToUniversalTime().ToString('o')
      report_findings       = $total
      critical              = $critical
      filed_to_backlog      = $FiledToBacklog
      suppressed_known      = $SuppressedKnown
      action_rate           = $actionRate
      resolved_signal_delta = $resolvedDelta
      ledger_open_prev      = $PrevOpenCount
      ledger_open_now       = $curOpen
      incident_capture_rate = $incidentCapture
      usefulness            = $usefulness
      prev_usefulness       = $prevUsefulness
      trend                 = $trend
    }
    $line = ($rec | ConvertTo-Json -Compress -Depth 6)
    [System.IO.File]::AppendAllText($path, ($line + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-AuditLog -BridgePath $BridgePath -Message ("audit usefulness={0} trend={1} action_rate={2} resolved_delta={3}" -f $usefulness, $trend, $actionRate, $resolvedDelta)
    return $rec
  } catch {
    try { Write-AuditLog -BridgePath $BridgePath -Message ("usefulness-score failed: " + $_.Exception.Message) } catch {}
    return $null
  }
}

function Format-AuditFindingMarkdown {
  param($F)
  $line = "- **$($F.title)**"
  if ($F.area)   { $line += " _($($F.area))_" }
  $line += " — _$($F.source)_"
  if ($F.detail) {
    $det = ($F.detail -replace '\s+', ' ').Trim()
    if ($det.Length -gt 400) { $det = $det.Substring(0, 400) + '...' }
    $line += "`n  " + $det
  }
  return $line
}

function Write-AuditReports {
  param([string]$BridgePath, $Report, $AuditContext = $null)
  $dir = $null
  if ($AuditContext) {
    try { $dir = [string]$AuditContext.report_root } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Get-AuditDir -BridgePath $BridgePath }
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $date = (Get-Date -Format 'yyyy-MM-dd')
  $jsonPath = Join-Path $dir "$date.json"
  $mdPath   = Join-Path $dir "$date.md"

  $json = $Report | ConvertTo-Json -Depth 8
  Write-AuditAtomicFile -Path $jsonPath -Content $json

  $sec = $Report.security_counts
  $fnc = $Report.functional_counts
  $kind = 'bridge'
  $channel = 'main'
  $targetRoot = $BridgePath
  $reportRoot = $dir
  try {
    if ($AuditContext) {
      $kind = [string]$AuditContext.kind
      $channel = [string]$AuditContext.channel
      $targetRoot = [string]$AuditContext.target_root
      $reportRoot = [string]$AuditContext.report_root
    } elseif ($Report.PSObject.Properties.Name -contains 'audit_context' -and $Report.audit_context) {
      $kind = [string]$Report.audit_context.kind
      $channel = [string]$Report.audit_context.channel
      $targetRoot = [string]$Report.audit_context.target_root
      $reportRoot = [string]$Report.audit_context.report_root
    }
  } catch {}
  if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'bridge' }
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = 'main' }
  $titlePrefix = if ($kind -eq 'project') { 'Project Audit Report' } else { 'Bridge Audit Report' }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("# $titlePrefix — $date")
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('## Summary')
  [void]$sb.AppendLine("- Security: $($sec.critical) critical, $($sec.warning) warning, $($sec.info) info")
  [void]$sb.AppendLine("- Functional: $($fnc.critical) critical, $($fnc.warning) warning, $($fnc.info) info")
  [void]$sb.AppendLine("- Channel: $channel")
  [void]$sb.AppendLine("- Scope: $kind")
  [void]$sb.AppendLine("- Target root: $targetRoot")
  [void]$sb.AppendLine("- Report root: $reportRoot")
  [void]$sb.AppendLine('')

  $all = @($Report.findings)
  $crit = @($all | Where-Object { $_.severity -eq 'critical' })
  $warn = @($all | Where-Object { $_.severity -eq 'warning' })
  $info = @($all | Where-Object { $_.severity -eq 'info' })
  $runtimeForDisplay = $Report.runtime_sec
  $generatedForDisplay = $Report.generated_at
  if ($Report.PSObject.Properties.Name -contains 'metadata' -and $Report.metadata) {
    if ($Report.metadata.runtime_seconds -ne $null) { $runtimeForDisplay = $Report.metadata.runtime_seconds }
    if ($Report.metadata.gen_timestamp) { $generatedForDisplay = $Report.metadata.gen_timestamp }
  }

  [void]$sb.AppendLine('## 🔴 Critical Issues')
  if ($crit.Count -eq 0) { [void]$sb.AppendLine('_(none)_') }
  else { foreach ($f in $crit) { [void]$sb.AppendLine((Format-AuditFindingMarkdown -F $f)) } }
  [void]$sb.AppendLine('')

  [void]$sb.AppendLine('## 🟡 Warnings')
  if ($warn.Count -eq 0) { [void]$sb.AppendLine('_(none)_') }
  else { foreach ($f in $warn) { [void]$sb.AppendLine((Format-AuditFindingMarkdown -F $f)) } }
  [void]$sb.AppendLine('')

  [void]$sb.AppendLine('## 🔵 Info / Cleanup Candidates')
  if ($info.Count -eq 0) { [void]$sb.AppendLine('_(none)_') }
  else { foreach ($f in $info) { [void]$sb.AppendLine((Format-AuditFindingMarkdown -F $f)) } }
  [void]$sb.AppendLine('')

  [void]$sb.AppendLine('## Metadata')
  [void]$sb.AppendLine("- Runtime: $($runtimeForDisplay)s")
  [void]$sb.AppendLine("- Generated: $($generatedForDisplay)")
  if ($Report.errors -and @($Report.errors).Count -gt 0) {
    [void]$sb.AppendLine('- Errors:')
    foreach ($e in @($Report.errors)) { [void]$sb.AppendLine("  - $e") }
  }

  Write-AuditAtomicFile -Path $mdPath -Content $sb.ToString()
  return @{ json = $jsonPath; md = $mdPath }
}

function Write-AuditIndexEntry {
  param([string]$BridgePath, $AuditContext, $Paths, $Report)
  try {
    $dir = Get-AuditDir -BridgePath $BridgePath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $indexPath = Join-Path $dir 'index.jsonl'
    $rec = [ordered]@{
      ts          = (Get-Date).ToUniversalTime().ToString('o')
      date        = (Get-Date -Format 'yyyy-MM-dd')
      channel     = if ($AuditContext) { [string]$AuditContext.channel } else { 'main' }
      kind        = if ($AuditContext) { [string]$AuditContext.kind } else { 'bridge' }
      target_root = if ($AuditContext) { [string]$AuditContext.target_root } else { [string]$BridgePath }
      report_root = if ($AuditContext) { [string]$AuditContext.report_root } else { (Get-AuditDir -BridgePath $BridgePath) }
      report_json = if ($Paths) { [string]$Paths.json } else { '' }
      report_md   = if ($Paths) { [string]$Paths.md } else { '' }
      status      = if ($Report -and ($Report.PSObject.Properties.Name -contains 'status')) { [string]$Report.status } else { '' }
    }
    [System.IO.File]::AppendAllText($indexPath, (($rec | ConvertTo-Json -Compress -Depth 6) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

function Add-AuditCriticalsToBacklog {
  param([string]$BridgePath, $Findings, $AuditContext = $null)
  $added = 0
  $crit = @($Findings | Where-Object { $_.severity -eq 'critical' })
  if ($crit.Count -eq 0) { return 0 }
  $auditKind = 'bridge'
  $backlogChannel = 'main'
  if ($AuditContext) {
    try { if (-not [string]::IsNullOrWhiteSpace([string]$AuditContext.kind)) { $auditKind = [string]$AuditContext.kind } } catch {}
    try { if (-not [string]::IsNullOrWhiteSpace([string]$AuditContext.backlog_channel)) { $backlogChannel = [string]$AuditContext.backlog_channel } } catch {}
  }
  $isProjectAudit = ($auditKind -eq 'project')
  $existingTexts = @{}
  try {
    $backlogPath = Get-AuditBacklogPath -BridgePath $BridgePath -Channel $backlogChannel
    if (Test-Path -LiteralPath $backlogPath) {
      foreach ($line in @([System.IO.File]::ReadAllLines($backlogPath, (New-Object System.Text.UTF8Encoding($false))))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
          $item = $line | ConvertFrom-Json
          $txt = [string]$item.text
          if (-not [string]::IsNullOrWhiteSpace($txt)) { $existingTexts[$txt] = $true }
        } catch {}
      }
    }
  } catch {
    Write-AuditLog -BridgePath $BridgePath -Message "failed to read backlog for audit exact dedupe: $($_.Exception.Message)"
  }
  $helperErrors = New-Object 'System.Collections.Generic.List[string]'
  $addIdeaAvailable = Initialize-AuditBacklogHelpers -Root $BridgePath -ResolvedChannel $backlogChannel -Errors ([ref]$helperErrors)
  if (-not $addIdeaAvailable) {
    Write-AuditLog -BridgePath $BridgePath -Message ("audit critical filing skipped: Add-Idea unavailable; errors=" + ((@($helperErrors.ToArray())) -join '; '))
    return 0
  }
  $runner = {
    $localAdded = 0
    foreach ($f in $crit) {
      try {
        $prefix = if ($isProjectAudit) { "audit/$backlogChannel/$($f.source)" } else { "audit/$($f.source)" }
        $text = "[$prefix] $($f.title)"
        if ($f.area)   { $text += " ($($f.area))" }
        if ($f.detail) {
          $det = ($f.detail -replace '\s+', ' ').Trim()
          if ($det.Length -gt 240) { $det = $det.Substring(0, 240) + '...' }
          $text += " — $det"
        }
        if ($existingTexts.ContainsKey($text)) { continue }
        # Static criticals now go through the same intake gate as deep-audit findings.
        # SkipCurator only skips the cheap LLM curator; deterministic intake still runs
        # inside Add-Idea and can dedup/hold/drop before anything reaches approved.
        $status = if ($isProjectAudit) { 'held' } else { 'approved' }
        $tags = if ($isProjectAudit) { @('audit', 'project-audit', $backlogChannel, [string]$f.source, 'critical') } else { @('audit', [string]$f.source, 'critical') }
        $bid = Add-Idea -Text $text -From 'audit' -Tags $tags -Status $status -Severity 'critical' -Project $backlogChannel -Scope $auditKind -SkipCurator
        if ($bid) {
          $existingTexts[$text] = $true
          $localAdded++
        }
      } catch {
        Write-AuditLog -BridgePath $BridgePath -Message "audit backlog Add-Idea filing failed: $($_.Exception.Message)"
      }
    }
    return $localAdded
  }.GetNewClosure()
  try {
    if (Get-Command Invoke-WithChannelEnv -ErrorAction SilentlyContinue) {
      $added = [int](Invoke-WithChannelEnv -Slug $backlogChannel -Action $runner)
    } else {
      $added = [int](& $runner)
    }
  } catch {
    Write-AuditLog -BridgePath $BridgePath -Message "audit critical Add-Idea filing failed: $($_.Exception.Message)"
  }
  return $added
}

function Resolve-AuditProjectScope {
  param(
    [string]$Root,
    [string]$Channel,
    [string]$ProjectRoot
  )
  # Resolve target project root: explicit -ProjectRoot > Get-EffectiveScope($Channel).project_root > $root.
  $resolvedProject = $root
  $projectResolved = $false
  $resolvedChannel = if (-not [string]::IsNullOrWhiteSpace($Channel)) { $Channel } else { '' }
  if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
    if (Test-Path -LiteralPath $ProjectRoot -PathType Container) {
      try { $resolvedProject = [System.IO.Path]::GetFullPath($ProjectRoot) } catch { $resolvedProject = $ProjectRoot }
      $projectResolved = $true
    }
  } else {
    try {
      $commonLib = Join-Path $root 'lib\common.ps1'
      if (Test-Path -LiteralPath $commonLib -PathType Leaf) { . $commonLib }
      if (Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($resolvedChannel) -and (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue)) {
          $resolvedChannel = [string](Get-EffectiveChannel)
        }
        $pr = ''
        try {
          $scope = Get-EffectiveScope -Slug $resolvedChannel
          $pr = [string]$scope.project_root
        } catch {}
        if (-not [string]::IsNullOrWhiteSpace($pr) -and (Test-Path -LiteralPath $pr -PathType Container)) {
          try { $resolvedProject = [System.IO.Path]::GetFullPath($pr) } catch { $resolvedProject = $pr }
          $projectResolved = $true
        }
      } elseif (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) {
        if ([string]::IsNullOrWhiteSpace($resolvedChannel) -and (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue)) {
          $resolvedChannel = [string](Get-EffectiveChannel)
        }
        $pr = ''
        try { $pr = [string](Get-EffectiveProjectRoot -Slug $resolvedChannel) } catch {}
        if (-not [string]::IsNullOrWhiteSpace($pr) -and (Test-Path -LiteralPath $pr -PathType Container)) {
          try { $resolvedProject = [System.IO.Path]::GetFullPath($pr) } catch { $resolvedProject = $pr }
          $projectResolved = $true
        }
      }
    } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($resolvedChannel) -and (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue)) {
    try { $resolvedChannel = [string](Get-EffectiveChannel) } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($resolvedChannel)) { $resolvedChannel = 'main' }
  $resolvedChannel = Normalize-AuditChannelSlug -Channel $resolvedChannel
  if ($resolvedChannel -ne 'main' -and -not $projectResolved) { $resolvedProject = '' }
  return [pscustomobject]@{
    resolvedProject  = $resolvedProject
    resolvedChannel  = $resolvedChannel
    projectResolved  = $projectResolved
  }
}

function Invoke-AuditSignalCollection {
  param(
    [string]$Root,
    [string]$ScriptRoot
  )
  # Collect telemetry signals before LLM agents (incident/speed/cost slices).
  try {
    $sigScript = Join-Path $ScriptRoot 'audit-signals.ps1'
    if (Test-Path -LiteralPath $sigScript -PathType Leaf) {
      $sigPowerShell = Join-Path $PSHOME 'powershell.exe'
      if (-not (Test-Path -LiteralPath $sigPowerShell -PathType Leaf)) { throw "powershell.exe not found under PSHOME: $PSHOME" }
      $sigJob = $null
      try {
        $sigJob = Start-Job -ScriptBlock {
          param($PowerShellPath, $ScriptPath, $BridgeRoot)
          $output = & $PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -BridgePath $BridgeRoot -WindowHours 24 2>&1
          $exitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
          [pscustomobject]@{
            ExitCode = $exitCode
            Output = @($output | ForEach-Object { [string]$_ })
          }
        } -ArgumentList $sigPowerShell, $sigScript, $root

        if (-not (Wait-Job -Job $sigJob -Timeout 30)) {
          Stop-Job -Job $sigJob -ErrorAction SilentlyContinue
          Write-AuditLog -BridgePath $root -Message "signal-collector timeout after 30s; job stopped"
        } else {
          $sigResult = @(Receive-Job -Job $sigJob -ErrorAction SilentlyContinue)
          if ($sigResult.Count -gt 0) {
            $sigExitCode = [int]$sigResult[-1].ExitCode
            $sigText = (@($sigResult[-1].Output) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' '
          } else {
            $sigExitCode = 1
            $sigText = 'no output from signal collector job'
          }
          if ($sigExitCode -eq 0) {
            Write-AuditLog -BridgePath $root -Message "signals: $sigText"
          } else {
            Write-AuditLog -BridgePath $root -Message "signal-collector exit=${sigExitCode}: $sigText"
          }
        }
      } finally {
        if ($sigJob) { Remove-Job -Job $sigJob -Force -ErrorAction SilentlyContinue }
      }
    }
  } catch { Write-AuditLog -BridgePath $root -Message "signal-collector error: $_" }
}

function Invoke-DeepAuditProcess {
  param(
    [string]$Root,
    [string]$DeepScript,
    [object]$AuditCtx,
    [string]$ReportDir,
    [string]$FunctionalAgent,
    [string]$ResolvedChannel,
    [int]$DeepAuditTimeoutSec,
    [ref]$Errors
  )
    # 11. DEEP-AUDIT phase (Codex security + multi-agent model fan-out)
    # 2026-05-28: implements backlog item 90747e410b. Runs after the static+
    # deepseek pipeline because (a) static is fast and always-on as safety net,
    # (b) deep-audit is heavier (~3-5min) so we want it last. Each half is
    # individually skippable on timeout/spawn-fail — graceful degradation.
    $deepCodexResult = $null
    $deepClaudeResult = $null
    $deepModelAgentResults = @()
    $deepStatus = 'skipped'
    $deepRuntimeSec = 0.0
    $deepWatchdogFired = $false
    try {
      if (Test-Path -LiteralPath $deepScript -PathType Leaf) {
        Write-AuditLog -BridgePath $root -Message "deep-audit start (Codex+multi-agent phase, watchdog=${DeepAuditTimeoutSec}s)"
        $deepSw = [System.Diagnostics.Stopwatch]::StartNew()
        $deepStdout = ''
        $deepStderr = ''
        $deepExitCode = 0
        $deepTmpDir = Join-Path $reportDir 'tmp'
        if (-not (Test-Path -LiteralPath $deepTmpDir)) { New-Item -ItemType Directory -Path $deepTmpDir -Force | Out-Null }
        $deepStamp = (Get-Date -Format 'yyyyMMddHHmmss') + '_' + ([guid]::NewGuid().ToString('N').Substring(0,6))
        $deepOutPath = Join-Path $deepTmpDir ("audit-deep-stdout_$deepStamp.txt")
        $deepErrPath = Join-Path $deepTmpDir ("audit-deep-stderr_$deepStamp.txt")
        # 2026-05-28: explicit JSON output file. Required workaround for PS 5.1
        # Start-Process -RedirectStandardOutput -WindowStyle Hidden, which binds
        # the subprocess stdout to cp866 (Russian Windows OEM) BEFORE the script
        # can switch [Console]::OutputEncoding to UTF-8. Result: every Cyrillic
        # observation arrives as cp866 mojibake. Writing the result JSON to a
        # file via [System.IO.File]::WriteAllText UTF-8 NoBOM sidesteps the
        # console layer entirely.
        $deepResultPath = Join-Path $deepTmpDir ("audit-deep-result_$deepStamp.json")
        try {
          # 2026-05-28: pass -ProjectRoot so codex/claude scope to the active
          # channel's codebase (not the bridge). Parallel is the default;
          # add -Sequential to fall back to back-to-back execution.
          # Also pass -FunctionalAgent (auto/gemini-only) for A/B testing.
          $deepArgValues = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $deepScript,
            '-BridgePath', $root,
            '-ProjectRoot', ([string]$auditCtx.target_root),
            '-FunctionalAgent', $FunctionalAgent,
            '-OutputFile', $deepResultPath
          )
          $deepArgs = @($deepArgValues | ForEach-Object { Format-AuditNativeArg ([string]$_) })
          $startDeepProcess = {
            Start-Process -FilePath 'powershell.exe' `
              -ArgumentList $deepArgs `
              -WorkingDirectory $root -RedirectStandardOutput $deepOutPath -RedirectStandardError $deepErrPath `
              -WindowStyle Hidden -PassThru
          }
          if (Get-Command Invoke-WithChannelEnv -ErrorAction SilentlyContinue) {
            $deepProc = Invoke-WithChannelEnv -Slug $resolvedChannel -Action $startDeepProcess
          } else {
            $deepProc = & $startDeepProcess
          }
          $deepWaited = $deepProc.WaitForExit([int]($DeepAuditTimeoutSec * 1000))
          if (-not $deepWaited) {
            $deepWatchdogFired = $true
            $deepStatus = 'deep_failed'
            try { $deepProc.Kill() } catch {}
            try { $deepProc.WaitForExit(5000) | Out-Null } catch {}
            [void]$Errors.Value.Add("deep-audit watchdog timeout after ${DeepAuditTimeoutSec}s; process killed")
            Write-AuditLog -BridgePath $root -Message "deep-audit watchdog timeout after ${DeepAuditTimeoutSec}s; pid=$($deepProc.Id) killed"
          } else {
            try { $deepExitCode = [int]$deepProc.ExitCode } catch { $deepExitCode = 0 }
          }
          # Prefer the explicit result file (UTF-8 guaranteed). Fall back to
          # stdout for older deep-audit.ps1 versions that don't write the file.
          if (Test-Path -LiteralPath $deepResultPath) {
            $deepStdout = [System.IO.File]::ReadAllText($deepResultPath, [System.Text.Encoding]::UTF8)
          } elseif (Test-Path -LiteralPath $deepOutPath) {
            $deepStdout = [System.IO.File]::ReadAllText($deepOutPath, [System.Text.Encoding]::UTF8)
          }
          if (Test-Path -LiteralPath $deepErrPath) { $deepStderr = [System.IO.File]::ReadAllText($deepErrPath, [System.Text.Encoding]::UTF8) }
        } finally {
          try {
            if ($deepSw) {
              $deepSw.Stop()
              $deepRuntimeSec = [math]::Round($deepSw.Elapsed.TotalSeconds, 2)
            }
          } catch {}
          try { Remove-Item -LiteralPath $deepOutPath,$deepErrPath,$deepResultPath -Force -ErrorAction SilentlyContinue } catch {}
        }
        if (-not $deepWatchdogFired -and $deepExitCode -ne 0) {
          $deepStatus = 'deep_failed'
          $stderrTail = (($deepStderr -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 8) -join ' | '
          [void]$Errors.Value.Add(("deep-audit exited with code {0}: {1}" -f $deepExitCode, $stderrTail))
        }
        # Extract last JSON line from stdout
        $deepJson = $null
        foreach ($ln in (($deepStdout -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
          $t = $ln.Trim().Trim([char]0xFEFF)
          if ($t.StartsWith('{') -and $t.EndsWith('}')) { $deepJson = $t }
        }
        if ($deepJson) {
          try {
            $deepParsed = $deepJson | ConvertFrom-Json
            $deepCodexResult  = $deepParsed.codex_security
            $deepClaudeResult = $deepParsed.claude_functional
            # 2026-05-30: orchestrator emits 'agents' (multi-agent path); older
            # versions used 'model_agents'. Read 'agents' first, fall back to the
            # legacy name -- the mismatch made every deep-audit report agents=0.
            if ($deepParsed.PSObject.Properties.Name -contains 'agents') {
              $deepModelAgentResults = @($deepParsed.agents)
            } elseif ($deepParsed.PSObject.Properties.Name -contains 'model_agents') {
              $deepModelAgentResults = @($deepParsed.model_agents)
            }
            if (-not $deepWatchdogFired -and $deepExitCode -eq 0) { $deepStatus = 'ok' }
          } catch {
            $deepStatus = 'deep_failed'
            $jsonSnippet = $deepJson
            if ($jsonSnippet.Length -gt 500) { $jsonSnippet = $jsonSnippet.Substring(0,500) + '...' }
            [void]$Errors.Value.Add('deep-audit JSON parse failed: ' + $_.Exception.Message + '; json_snippet=' + $jsonSnippet)
          }
        } elseif (-not $deepWatchdogFired) {
          $deepStatus = 'deep_failed'
          $stdoutTail = (($deepStdout -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 8) -join ' | '
          $stderrTail = (($deepStderr -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 8) -join ' | '
          [void]$Errors.Value.Add('deep-audit: no JSON in stdout; stdout_tail=' + $stdoutTail + '; stderr_tail=' + $stderrTail)
        }
      } else {
        $deepStatus = 'skipped'
      }
    } catch {
      $deepStatus = 'deep_failed'
      [void]$Errors.Value.Add('deep-audit invocation failed: ' + $_.Exception.Message)
    }
  return [pscustomobject]@{
    deepCodexResult        = $deepCodexResult
    deepClaudeResult       = $deepClaudeResult
    deepModelAgentResults  = @($deepModelAgentResults)
    deepStatus             = $deepStatus
    deepRuntimeSec         = $deepRuntimeSec
    deepWatchdogFired      = $deepWatchdogFired
  }
}

function Initialize-AuditBacklogHelpers {
  param(
    [string]$Root,
    [string]$ResolvedChannel,
    [ref]$Errors
  )
  $addIdeaAvailable = $false
    try {
      # 2026-05-28: dot-source common.ps1 (not just backlog.ps1). Same bug class as
      # Start-BacklogCuratorJob hit earlier — Add-Idea internally references
      # Get-BacklogPath -> Get-ChannelBacklogPath (lib/channels.ps1) and the
      # write closure needs Use-BridgeLock (lib/common.ps1) + Get-Backlog
      # (lib/backlog.ps1). Loading common.ps1 brings the whole stack in the right
      # order so audit can actually file findings instead of throwing
      # "Get-BacklogPath not recognized".
      $addIdeaLoaded = [bool](Get-Command Add-Idea -ErrorAction SilentlyContinue)
      $getBacklogPathLoaded = [bool](Get-Command Get-BacklogPath -ErrorAction SilentlyContinue)
      if (-not $addIdeaLoaded -or -not $getBacklogPathLoaded) {
        $commonLib = Join-Path $root 'lib\common.ps1'
        if (Test-Path -LiteralPath $commonLib -PathType Leaf) { . $commonLib }
      }
      $initializeChannelsLoaded = Get-Command Initialize-Channels -ErrorAction SilentlyContinue
      if ($initializeChannelsLoaded) {
        try {
          Initialize-Channels | Out-Null
        } catch {
          Write-Warning ("audit-self-diag: Initialize-Channels failed after common.ps1 load: " + $_.Exception.Message)
        }
      }
      # Pin the channel so Get-BacklogPath resolves to the active channel's
      # backlog.jsonl. 2026-05-28: was hard-pinned to 'main' — that meant a
      # travel-channel audit would file its findings into the bridge backlog,
      # not the travel one. Now we use $resolvedChannel (already computed at
      # the top of Invoke-BridgeAudit from -Channel / Get-EffectiveChannel),
      # so the findings land where the user actually triggered the audit.
      if (Get-Command Set-PinnedChannel -ErrorAction SilentlyContinue) {
        $pinSlug = if (-not [string]::IsNullOrWhiteSpace($resolvedChannel)) { $resolvedChannel } else { 'main' }
        try { Set-PinnedChannel $pinSlug } catch {}
      }
      if (-not (Get-Command Get-BacklogPath -ErrorAction SilentlyContinue)) {
        Write-Warning 'audit-self-diag: Get-BacklogPath unavailable after common.ps1 load and Initialize-Channels; skipping Add-Idea filing for deep-audit findings'
      }
      $addIdeaAvailable = [bool](Get-Command Add-Idea -ErrorAction SilentlyContinue) -and [bool](Get-Command Get-BacklogPath -ErrorAction SilentlyContinue)
    } catch {
      [void]$Errors.Value.Add('deep-audit backlog helper load failed: ' + $_.Exception.Message)
    }
  return [bool]$addIdeaAvailable
}

function Add-DeepAuditFindingsToBacklog {
  param(
    [string]$Root,
    [object]$AuditCtx,
    [object]$DeepCodexResult,
    [object]$DeepClaudeResult,
    [object[]]$DeepModelAgentResults,
    [bool]$AddIdeaAvailable,
    [ref]$Errors
  )
  $deepFiled = 0
  $deepCodexCount = 0
  $deepClaudeCount = 0
  $deepModelAgentCount = 0
  $deepBacklogHelperWarned = $false
    # Bridge deep-audit findings are pre-validated and go in approved. Project
    # deep-audit findings go in held so an external codebase is never changed
    # just because a tab-level audit found something.
    # 2026-05-28: diagnostic — earlier "deep[claude=10] backlog+=0+0" runs lost
    # findings silently because Write-AuditReports already ran and errors-list
    # had nowhere to go. Log every decision (filed/skipped/failed) directly to
    # audit.log so the next failure is debuggable from one place.
    $writeDiag = {
      param([string]$Source, [string]$Sev, [string]$Outcome, [string]$Detail)
      try {
        Write-AuditLog -BridgePath $root -Message ("deep-audit filing: source=$Source sev=$Sev outcome=$Outcome" + $(if ($Detail) { " detail=$Detail" } else { '' }))
      } catch {}
    }
    if (-not $addIdeaAvailable) {
      & $writeDiag 'init' '' 'add-idea-unavailable' ('add-idea-loaded=' + [bool](Get-Command Add-Idea -EA SilentlyContinue) + ' get-backlogpath-loaded=' + [bool](Get-Command Get-BacklogPath -EA SilentlyContinue))
    }
    $deepBacklogStatus = if ([string]$auditCtx.kind -eq 'project') { 'held' } else { 'approved' }
    $deepBacklogProject = [string]$auditCtx.backlog_channel
    $deepBacklogScope = [string]$auditCtx.kind
    $deepBaseTags = if ([string]$auditCtx.kind -eq 'project') { @('audit','project-audit',$deepBacklogProject,'deep-audit') } else { @('audit','deep-audit') }
    if ($deepCodexResult) {
      $cf = @($deepCodexResult.findings)
      $deepCodexCount = $cf.Count
      foreach ($f in $cf) {
        if (-not $f) { continue }
        $sev = ([string]$f.severity).ToLowerInvariant()
        if ($sev -notin @('critical','warning','info')) {
          & $writeDiag 'codex' $sev 'skip-bad-severity' ''
          continue
        }
        try {
          $bText = "[deep-codex/security] " + [string]$f.category + " (" + [string]$f.file + ":" + [string]$f.line + ") -- " + [string]$f.finding + " | Recommend: " + [string]$f.recommendation
          if ($addIdeaAvailable) {
            $bid = Add-Idea -Text $bText -From 'audit-deep-codex' -Tags @($deepBaseTags + @('codex','security',$sev)) -Status $deepBacklogStatus -Severity $sev -SkipCurator -Project $deepBacklogProject -Scope $deepBacklogScope
            if ($bid) {
              $deepFiled++
              & $writeDiag 'codex' $sev 'filed' "id=$bid"
            } else {
              & $writeDiag 'codex' $sev 'add-idea-returned-null' "text-len=$($bText.Length)"
            }
          } elseif (-not $deepBacklogHelperWarned) {
            [void]$Errors.Value.Add('deep-audit backlog filing skipped: Add-Idea unavailable')
            $deepBacklogHelperWarned = $true
          }
        } catch {
          $msg = $_.Exception.Message
          [void]$Errors.Value.Add('deep-audit codex backlog filing failed: ' + $msg)
          & $writeDiag 'codex' $sev 'exception' $msg
        }
      }
    }
    if ($deepClaudeResult) {
      $cf = @($deepClaudeResult.findings)
      $deepClaudeCount = $cf.Count
      # Claude's findings (critical / warning / info) all go to backlog now —
      # severity controls picker order, info-level just lands last.
      foreach ($f in $cf) {
        if (-not $f) { continue }
        $sev = ([string]$f.severity).ToLowerInvariant()
        if ($sev -notin @('critical','warning','info')) {
          & $writeDiag 'claude' $sev 'skip-bad-severity' ''
          continue
        }
        try {
          $bText = "[deep-claude/" + [string]$f.category + "] " + [string]$f.feature_id + ": " + [string]$f.observation + " | Предлагает: " + [string]$f.recommendation
          if ($addIdeaAvailable) {
            $bid = Add-Idea -Text $bText -From 'audit-deep-claude' -Tags @($deepBaseTags + @('claude','functional',$sev)) -Status $deepBacklogStatus -Severity $sev -SkipCurator -Project $deepBacklogProject -Scope $deepBacklogScope
            if ($bid) {
              $deepFiled++
              & $writeDiag 'claude' $sev 'filed' "id=$bid"
            } else {
              & $writeDiag 'claude' $sev 'add-idea-returned-null' "text-len=$($bText.Length)"
            }
          } elseif (-not $deepBacklogHelperWarned) {
            [void]$Errors.Value.Add('deep-audit backlog filing skipped: Add-Idea unavailable')
            $deepBacklogHelperWarned = $true
          }
        } catch {
          $msg = $_.Exception.Message
          [void]$Errors.Value.Add('deep-audit claude backlog filing failed: ' + $msg)
          & $writeDiag 'claude' $sev 'exception' $msg
        }
      }
    }
    foreach ($agent in @($deepModelAgentResults)) {
      if (-not $agent) { continue }
      $agentRole = [string]$agent.role
      $agentModel = [string]$agent.model
      $af = @($agent.findings)
      $deepModelAgentCount += $af.Count
      foreach ($f in $af) {
        if (-not $f) { continue }
        $sev = ([string]$f.severity).ToLowerInvariant()
        if ($sev -notin @('critical','warning','info')) {
          & $writeDiag $agentRole $sev 'skip-bad-severity' ''
          continue
        }
        try {
          $area = [string]$f.area
          $cat = [string]$f.category
          $obs = [string]$f.observation
          $rec = [string]$f.recommendation
          $bText = "[deep-agent/$agentRole/$agentModel] $cat"
          if (-not [string]::IsNullOrWhiteSpace($area)) { $bText += " ($area)" }
          $bText += " -- $obs | Recommend: $rec"
          if ($addIdeaAvailable) {
            $bid = Add-Idea -Text $bText -From 'audit-deep-agent' -Tags @($deepBaseTags + @('agent',$agentRole,$sev)) -Status $deepBacklogStatus -Severity $sev -SkipCurator -Project $deepBacklogProject -Scope $deepBacklogScope
            if ($bid) {
              $deepFiled++
              & $writeDiag $agentRole $sev 'filed' "id=$bid"
            } else {
              & $writeDiag $agentRole $sev 'add-idea-returned-null' "text-len=$($bText.Length)"
            }
          } elseif (-not $deepBacklogHelperWarned) {
            [void]$Errors.Value.Add('deep-audit backlog filing skipped: Add-Idea unavailable')
            $deepBacklogHelperWarned = $true
          }
        } catch {
          $msg = $_.Exception.Message
          [void]$Errors.Value.Add('deep-audit model-agent backlog filing failed: ' + $msg)
          & $writeDiag $agentRole $sev 'exception' $msg
        }
      }
    }
  return [pscustomobject]@{
    deepFiled             = $deepFiled
    deepCodexCount        = $deepCodexCount
    deepClaudeCount       = $deepClaudeCount
    deepModelAgentCount   = $deepModelAgentCount
  }
}

function Add-DeepAuditSectionsToMarkdown {
  param(
    [object]$Paths,
    [string]$DeepStatus,
    [double]$DeepRuntimeSec,
    [int]$DeepAuditTimeoutSec,
    [bool]$DeepWatchdogFired,
    [object[]]$DeepModelAgentResults,
    [object]$DeepCodexResult,
    [object]$DeepClaudeResult,
    [int]$DeepCodexCount,
    [int]$DeepClaudeCount,
    [ref]$Errors
  )
  $deepModelAgentCount = 0
  foreach ($agent in @($DeepModelAgentResults)) { if (-not $agent) { continue }; $deepModelAgentCount += @($agent.findings).Count }
    # Append deep-audit sections to the MD report (in-place edit)
    if ($paths -and $paths.md -and (Test-Path -LiteralPath $paths.md)) {
      try {
        $mdExisting = [System.IO.File]::ReadAllText($paths.md, [System.Text.Encoding]::UTF8)
        $deepBlock = New-Object 'System.Text.StringBuilder'
        [void]$deepBlock.AppendLine('')
        [void]$deepBlock.AppendLine("## Deep Audit Status")
        [void]$deepBlock.AppendLine("- Status: $deepStatus")
        [void]$deepBlock.AppendLine("- Runtime: ${deepRuntimeSec}s")
        [void]$deepBlock.AppendLine("- Model agents: $(@($deepModelAgentResults).Count) agents, $deepModelAgentCount findings")
        if ($deepWatchdogFired) { [void]$deepBlock.AppendLine("- Watchdog: timeout after ${DeepAuditTimeoutSec}s") }
        [void]$deepBlock.AppendLine('')
        [void]$deepBlock.AppendLine('## 🤖 Codex Security (deep)')
        if (-not $deepCodexResult -or $deepCodexResult.skipped) {
          $reason = if ($deepCodexResult) { [string]$deepCodexResult.reason } else { 'не запущено' }
          [void]$deepBlock.AppendLine("_Пропущено: $reason_")
        } elseif ($deepCodexResult.error) {
          [void]$deepBlock.AppendLine("_Ошибка: $($deepCodexResult.error)_")
        } else {
          if ($deepCodexCount -eq 0) {
            [void]$deepBlock.AppendLine('_Codex не нашёл реальных уязвимостей в изменённых за 24ч файлах._')
          } else {
            foreach ($f in @($deepCodexResult.findings)) {
              if (-not $f) { continue }
              # 2026-05-28: was using backtick-escaped $(...) inside double quotes
              # to wrap file:line in markdown backticks. PowerShell read the backtick
              # as escape and the whole $([string]$f.file...) expression became a
              # literal in the report. Build via concatenation so the inline code
              # markers are literal but the expression runs.
              $codexFL = '`' + [string]$f.file + ':' + [string]$f.line + '`'
              [void]$deepBlock.AppendLine("- **$([string]$f.severity)** $([string]$f.category) _($codexFL)_: $([string]$f.finding)")
              if ($f.recommendation) { [void]$deepBlock.AppendLine("  - Рекомендация: $([string]$f.recommendation)") }
            }
          }
        }
        [void]$deepBlock.AppendLine('')
        [void]$deepBlock.AppendLine('## 🤖 Claude Functional (deep)')
        if (-not $deepClaudeResult -or $deepClaudeResult.skipped) {
          $reason = if ($deepClaudeResult) { [string]$deepClaudeResult.reason } else { 'не запущено' }
          [void]$deepBlock.AppendLine("_Пропущено: $reason_")
        } elseif ($deepClaudeResult.error) {
          [void]$deepBlock.AppendLine("_Ошибка: $($deepClaudeResult.error)_")
        } else {
          if ($deepClaudeCount -eq 0) {
            [void]$deepBlock.AppendLine('_Claude не нашёл архитектурных проблем — реестр консистентен с состоянием._')
          } else {
            foreach ($f in @($deepClaudeResult.findings)) {
              if (-not $f) { continue }
              # 2026-05-28: build the literal-backtick wrap via concat to avoid
              # the `$(...) escape-trap (same fix as the codex block above).
              $claudeFid = '`' + [string]$f.feature_id + '`'
              [void]$deepBlock.AppendLine("- **$([string]$f.severity)** $([string]$f.category) — фича $claudeFid : $([string]$f.observation)")
              if ($f.recommendation) { [void]$deepBlock.AppendLine("  - Рекомендация: $([string]$f.recommendation)") }
            }
          }
        }
        [void]$deepBlock.AppendLine('')
        [void]$deepBlock.AppendLine('## 🤖 Model Agents (deep)')
        if (@($deepModelAgentResults).Count -eq 0) {
          [void]$deepBlock.AppendLine('_Не запущены или не вернули результатов._')
        } else {
          foreach ($agent in @($deepModelAgentResults)) {
            if (-not $agent) { continue }
            $role = [string]$agent.role
            $model = [string]$agent.model
            if ($agent.skipped) {
              $reason = if ($agent.reason) { [string]$agent.reason } else { 'skipped' }
              [void]$deepBlock.AppendLine("- `$role` / `$model`: skipped ($reason)")
              continue
            }
            if ($agent.error) {
              [void]$deepBlock.AppendLine("- `$role` / `$model`: error $([string]$agent.error)")
              continue
            }
            $finds = @($agent.findings)
            if ($finds.Count -eq 0) {
              [void]$deepBlock.AppendLine("- `$role` / `$model`: findings=0")
              continue
            }
            [void]$deepBlock.AppendLine("- `$role` / `$model`: findings=$($finds.Count)")
            foreach ($f in $finds) {
              if (-not $f) { continue }
              $area = if ($f.area) { ' _(`' + [string]$f.area + '`)_ ' } else { ' ' }
              [void]$deepBlock.AppendLine("  - **$([string]$f.severity)** $([string]$f.category)$($area): $([string]$f.observation)")
              if ($f.recommendation) { [void]$deepBlock.AppendLine("    - Рекомендация: $([string]$f.recommendation)") }
            }
          }
        }
        [System.IO.File]::WriteAllText($paths.md, $mdExisting + $deepBlock.ToString(), (New-Object System.Text.UTF8Encoding($false)))
      } catch {
        [void]$Errors.Value.Add('deep-audit md merge failed: ' + $_.Exception.Message)
      }
    }
}

function Initialize-BridgeAuditInvocation {
  param(
    [string]$BridgePath,
    [string]$Channel,
    [string]$ProjectRoot
  )
  $root = Get-AuditBridgeRoot -Hint $BridgePath
  try {
    $commonLib = Join-Path $root 'lib\common.ps1'
    if (Test-Path -LiteralPath $commonLib -PathType Leaf) { . $commonLib }
  } catch {}
  $scope = Resolve-AuditProjectScope -Root $root -Channel $Channel -ProjectRoot $ProjectRoot
  $resolvedProject = [string]$scope.resolvedProject
  $resolvedChannel = [string]$scope.resolvedChannel
  $auditCtx = New-AuditContext -BridgePath $root -Channel $resolvedChannel -ProjectRoot $resolvedProject
  $reportDir = [string]$auditCtx.report_root
  try { if (-not (Test-Path -LiteralPath $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null } } catch {}
  return [pscustomobject]@{
    root            = $root
    resolvedProject = $resolvedProject
    resolvedChannel = $resolvedChannel
    auditCtx        = $auditCtx
    reportDir       = $reportDir
  }
}

function Start-BridgeAuditInvocation {
  param(
    [string]$Root,
    [object]$AuditCtx
  )
  $existing = Test-AuditLock -BridgePath $Root
  if ($existing) {
    Write-AuditLog -BridgePath $Root -Message "audit already running under PID $existing; abort"
    return @{ status = 'locked'; pid = $existing }
  }
  New-AuditLock -BridgePath $Root
  $scopeLabel = "kind=$($AuditCtx.kind) channel=$($AuditCtx.channel) target=$($AuditCtx.target_root)"
  try { Write-AuditLog -BridgePath $Root -Message "audit start (root=$Root, pid=$PID, scope=$scopeLabel)" } catch {}
  try { if (Get-Command Add-Message -ErrorAction SilentlyContinue) { [void](Add-Message -From system -Text '🔍 Аудит запущен (статика + deep multi-agent)…' -Kind event) } } catch {}
  try {
    Invoke-AuditSignalCollection -Root $Root -ScriptRoot $PSScriptRoot | Out-Null
  } catch {
    try { Write-AuditLog -BridgePath $Root -Message ("audit signal collection failed: " + $_.Exception.Message) } catch {}
  }
  return $null
}

function Invoke-BridgeAuditStaticAnalysis {
  param(
    [string]$Root,
    [object]$AuditCtx,
    [string]$ReportDir,
    [ref]$Errors
  )
  $allFindings = New-Object 'System.Collections.Generic.List[object]'
  $secFindings = @(); $fncFindings = @()

  $sec = Invoke-AuditSubcomponent -BridgePath $Root -ScriptName 'audit-security.ps1' -EntryFunction 'Invoke-SecurityAudit' -TargetRoot ([string]$AuditCtx.target_root) -AuditKind ([string]$AuditCtx.kind)
  if ($sec.error) { [void]$Errors.Value.Add("security: $($sec.error)") }
  foreach ($f in @($sec.findings)) { $norm = Format-AuditFindings -Source 'security' -Raw $f; $secFindings += ,$norm; [void]$allFindings.Add($norm) }

  $fnc = Invoke-AuditSubcomponent -BridgePath $Root -ScriptName 'audit-functional.ps1' -EntryFunction 'Invoke-FunctionalAudit' -TargetRoot ([string]$AuditCtx.target_root) -AuditKind ([string]$AuditCtx.kind)
  if ($fnc.error) { [void]$Errors.Value.Add("functional: $($fnc.error)") }
  foreach ($f in @($fnc.findings)) { $norm = Format-AuditFindings -Source 'functional' -Raw $f; $fncFindings += ,$norm; [void]$allFindings.Add($norm) }

  $mergedFindings = Merge-AuditFindings -Findings $allFindings.ToArray()
  $ledgerSuppressedCount = 0; $ledgerPrevOpenCount = 0; $ledgerResult = $null
  try {
    $ledgerPath = Get-FindingsLedgerPath -BridgePath $Root -AuditDir $ReportDir
    $ledger = Read-FindingsLedger -LedgerPath $ledgerPath
    try { $ledgerPrevOpenCount = @($ledger.Values | Where-Object { (Normalize-AuditLedgerToken -Value ([string]$_.state) -Fallback 'open') -in @('open','new','regressed') }).Count } catch {}
    $ledgerResult = Update-FindingsLedger -CurrentFindings $mergedFindings -Ledger $ledger -Now (Get-Date).ToUniversalTime()
    Write-FindingsLedger -LedgerPath $ledgerPath -Ledger $ledgerResult.ledger
    $mergedFindings = @($ledgerResult.reportFindings); $ledgerSuppressedCount = [int]$ledgerResult.suppressedCount
    if ($ledgerSuppressedCount -gt 0) { Write-AuditLog -BridgePath $Root -Message "findings-ledger: suppressed $ledgerSuppressedCount known open findings" }
  } catch {
    $msg = "findings-ledger failed: $($_.Exception.Message)"
    [void]$Errors.Value.Add($msg); Write-AuditLog -BridgePath $Root -Message $msg
  }

  return [pscustomobject]@{
    secFindings            = @($secFindings)
    fncFindings            = @($fncFindings)
    sec                    = $sec
    fnc                    = $fnc
    mergedFindings         = @($mergedFindings)
    ledgerResult           = $ledgerResult
    ledgerSuppressedCount  = $ledgerSuppressedCount
    ledgerPrevOpenCount    = $ledgerPrevOpenCount
    secCounts              = Get-AuditSeverityCounts -Findings @($mergedFindings | Where-Object { $_.source -eq 'security' })
    fncCounts              = Get-AuditSeverityCounts -Findings @($mergedFindings | Where-Object { $_.source -eq 'functional' })
  }
}

function New-BridgeAuditReport {
  param(
    [string]$Root,
    [string]$ResolvedChannel,
    [string]$ResolvedProject,
    [object]$AuditCtx,
    [object]$StaticResult,
    [System.Diagnostics.Stopwatch]$Stopwatch,
    [ref]$Errors
  )
  $generatedAtLocal = (Get-Date).ToString('o'); $generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
  $runtimeSeconds = [math]::Round($Stopwatch.Elapsed.TotalSeconds, 2)
  return [pscustomobject]@{
    generated_at = $generatedAtUtc; bridge_root = $Root; runtime_sec = $runtimeSeconds
    metadata = [ordered]@{
      bridge_path = $Root; channel = $ResolvedChannel; audit_kind = [string]$AuditCtx.kind; project_root = $ResolvedProject
      target_root = [string]$AuditCtx.target_root; report_root = [string]$AuditCtx.report_root; backlog_channel = [string]$AuditCtx.backlog_channel; profile = [string]$AuditCtx.profile
      generated_at = $generatedAtLocal; gen_timestamp = $generatedAtUtc; runtime_seconds = $runtimeSeconds
      security_runtime_sec = $StaticResult.sec.runtime_sec; functional_runtime_sec = $StaticResult.fnc.runtime_sec; findings_ledger_suppressed_count = $StaticResult.ledgerSuppressedCount
    }
    security_counts = $StaticResult.secCounts; functional_counts = $StaticResult.fncCounts; security_runtime_sec = $StaticResult.sec.runtime_sec; functional_runtime_sec = $StaticResult.fnc.runtime_sec
    audit_kind = [string]$AuditCtx.kind; channel = [string]$AuditCtx.channel; target_root = [string]$AuditCtx.target_root; report_root = [string]$AuditCtx.report_root
    audit_context = $AuditCtx; findings = @($StaticResult.mergedFindings); errors = @($Errors.Value.ToArray())
  }
}

function Publish-BridgeAuditStaticReport {
  param(
    [string]$Root,
    [object]$AuditCtx,
    [object]$Report,
    [object]$StaticResult,
    [string]$ReportDir
  )
  $paths = Write-AuditReports -BridgePath $Root -Report $Report -AuditContext $AuditCtx
  try { $marker = Get-AuditLastMarker -BridgePath $Root -AuditDir $ReportDir; [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
  $filed = 0
  if ($StaticResult.secCounts.critical -gt 0 -or $StaticResult.fncCounts.critical -gt 0) {
    $filed = Add-AuditCriticalsToBacklog -BridgePath $Root -Findings $StaticResult.mergedFindings -AuditContext $AuditCtx
  }
  try {
    $newLedgerForScore = $null
    if ($StaticResult.ledgerResult) { $newLedgerForScore = $StaticResult.ledgerResult.ledger }
    Write-AuditUsefulnessScore -BridgePath $Root -ReportFindings $StaticResult.mergedFindings -FiledToBacklog $filed -SuppressedKnown $StaticResult.ledgerSuppressedCount -PrevOpenCount $StaticResult.ledgerPrevOpenCount -NewLedger $newLedgerForScore -Now (Get-Date) -AuditDir $ReportDir | Out-Null
  } catch {}
  return [pscustomobject]@{
    paths = $paths
    filed = $filed
  }
}

function Invoke-BridgeAuditDeepPhase {
  param(
    [string]$Root,
    [object]$AuditCtx,
    [string]$ReportDir,
    [string]$FunctionalAgent,
    [string]$ResolvedChannel,
    [int]$DeepAuditTimeoutSec,
    [object]$Paths,
    [ref]$Errors
  )
  $deepScript = Join-Path $Root 'tools\deep-audit.ps1'
  $deepR = Invoke-DeepAuditProcess -Root $Root -DeepScript $deepScript -AuditCtx $AuditCtx -ReportDir $ReportDir -FunctionalAgent $FunctionalAgent -ResolvedChannel $ResolvedChannel -DeepAuditTimeoutSec $DeepAuditTimeoutSec -Errors $Errors
  $deepCodexResult = $deepR.deepCodexResult; $deepClaudeResult = $deepR.deepClaudeResult; $deepModelAgentResults = @($deepR.deepModelAgentResults)
  $deepStatus = [string]$deepR.deepStatus; $deepRuntimeSec = [double]$deepR.deepRuntimeSec; $deepWatchdogFired = [bool]$deepR.deepWatchdogFired
  $addIdeaAvailable = Initialize-AuditBacklogHelpers -Root $Root -ResolvedChannel $ResolvedChannel -Errors $Errors
  $filingR = Add-DeepAuditFindingsToBacklog -Root $Root -AuditCtx $AuditCtx -DeepCodexResult $deepCodexResult -DeepClaudeResult $deepClaudeResult -DeepModelAgentResults @($deepModelAgentResults) -AddIdeaAvailable $addIdeaAvailable -Errors $Errors
  $deepFiled = [int]$filingR.deepFiled; $deepCodexCount = [int]$filingR.deepCodexCount; $deepClaudeCount = [int]$filingR.deepClaudeCount; $deepModelAgentCount = [int]$filingR.deepModelAgentCount
  Add-DeepAuditSectionsToMarkdown -Paths $Paths -DeepStatus $deepStatus -DeepRuntimeSec $deepRuntimeSec -DeepAuditTimeoutSec $DeepAuditTimeoutSec -DeepWatchdogFired $deepWatchdogFired -DeepModelAgentResults @($deepModelAgentResults) -DeepCodexResult $deepCodexResult -DeepClaudeResult $deepClaudeResult -DeepCodexCount $deepCodexCount -DeepClaudeCount $deepClaudeCount -Errors $Errors
  return [pscustomobject]@{
    deepCodexResult       = $deepCodexResult
    deepClaudeResult      = $deepClaudeResult
    deepModelAgentResults = @($deepModelAgentResults)
    deepStatus            = $deepStatus
    deepRuntimeSec        = $deepRuntimeSec
    deepWatchdogFired     = $deepWatchdogFired
    deepFiled             = $deepFiled
    deepCodexCount        = $deepCodexCount
    deepClaudeCount       = $deepClaudeCount
    deepModelAgentCount   = $deepModelAgentCount
  }
}

function Complete-BridgeAuditReport {
  param(
    [string]$Root,
    [object]$AuditCtx,
    [object]$Report,
    [object]$Paths,
    [object]$StaticResult,
    [int]$Filed,
    [object]$DeepResult,
    [int]$DeepAuditTimeoutSec,
    [ref]$Errors
  )
  $finalStatus = if ($DeepResult.deepStatus -eq 'deep_failed') { 'partial' } else { 'ok' }
  try {
    $Report | Add-Member -NotePropertyName status -NotePropertyValue $finalStatus -Force
    $Report | Add-Member -NotePropertyName errors -NotePropertyValue @($Errors.Value.ToArray()) -Force
    $Report | Add-Member -NotePropertyName deep_results -NotePropertyValue ([ordered]@{ codex_security = $DeepResult.deepCodexResult; claude_functional = $DeepResult.deepClaudeResult; model_agents = @($DeepResult.deepModelAgentResults) }) -Force
    if ($Report.metadata) { $Report.metadata['deep_status'] = $DeepResult.deepStatus; $Report.metadata['deep_runtime_sec'] = $DeepResult.deepRuntimeSec; $Report.metadata['deep_watchdog_timeout_sec'] = $DeepAuditTimeoutSec; $Report.metadata['deep_watchdog_fired'] = $DeepResult.deepWatchdogFired; $Report.metadata['deep_model_agent_count'] = $DeepResult.deepModelAgentCount }
    if ($Paths -and $Paths.json) { Write-AuditAtomicFile -Path $Paths.json -Content ($Report | ConvertTo-Json -Depth 8) }
    Write-AuditIndexEntry -BridgePath $Root -AuditContext $AuditCtx -Paths $Paths -Report $Report
  } catch { [void]$Errors.Value.Add('audit report deep-status update failed: ' + $_.Exception.Message) }

  Write-AuditLog -BridgePath $Root -Message ("audit {11} in {0}s — sec[{1}c/{2}w/{3}i] fnc[{4}c/{5}w/{6}i] deep[{12} codex={7} claude={8} agents={13}] backlog+={9}+{10}" -f $Report.runtime_sec, $StaticResult.secCounts.critical, $StaticResult.secCounts.warning, $StaticResult.secCounts.info, $StaticResult.fncCounts.critical, $StaticResult.fncCounts.warning, $StaticResult.fncCounts.info, $DeepResult.deepCodexCount, $DeepResult.deepClaudeCount, $Filed, $DeepResult.deepFiled, $finalStatus, $DeepResult.deepStatus, $DeepResult.deepModelAgentCount)
  try {
    if (Get-Command Add-Message -ErrorAction SilentlyContinue) {
      $auditIcon = if ($finalStatus -eq 'ok') { '✅' } else { '⚠️' }
      $totalFindings = [int]$StaticResult.secCounts.critical + [int]$StaticResult.secCounts.warning + [int]$StaticResult.secCounts.info + [int]$StaticResult.fncCounts.critical + [int]$StaticResult.fncCounts.warning + [int]$StaticResult.fncCounts.info
      $deepLabel = if ($DeepResult.deepStatus -eq 'ok') { "deep ok · агентов:$($DeepResult.deepModelAgentCount)" } else { "deep:$($DeepResult.deepStatus)" }
      [void](Add-Message -From system -Text "$auditIcon Аудит завершён за $($Report.runtime_sec)s · $deepLabel · находок:$totalFindings · в backlog:+$($Filed + $DeepResult.deepFiled)" -Kind event)
    }
  } catch {}

  return [pscustomobject]@{
    status = $finalStatus; deep_status = $DeepResult.deepStatus; audit_kind = [string]$AuditCtx.kind; channel = [string]$AuditCtx.channel; target_root = [string]$AuditCtx.target_root
    report_json = $Paths.json; report_md = $Paths.md; security_counts = $StaticResult.secCounts; functional_counts = $StaticResult.fncCounts
    deep_codex_count = $DeepResult.deepCodexCount; deep_claude_count = $DeepResult.deepClaudeCount; deep_model_agent_count = $DeepResult.deepModelAgentCount; deep_runtime_sec = $DeepResult.deepRuntimeSec
    backlog_added = $Filed + $DeepResult.deepFiled; runtime_sec = $Report.runtime_sec; errors = @($Errors.Value.ToArray())
  }
}

function Invoke-BridgeAudit {
  param(
    [string]$BridgePath = $null,
    [string]$Channel = $null,
    [string]$ProjectRoot = $null,
    [int]$DeepAuditTimeoutSec = 420,
    [ValidateSet('auto','gemini-only')]
    [string]$FunctionalAgent = 'gemini-only'
  )
  if ($DeepAuditTimeoutSec -lt 1) { $DeepAuditTimeoutSec = 1 }
  $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $run = Initialize-BridgeAuditInvocation -BridgePath $BridgePath -Channel $Channel -ProjectRoot $ProjectRoot
  $root = [string]$run.root
  $auditCtx = $run.auditCtx
  $lockAcquired = $false

  try {
    $locked = Start-BridgeAuditInvocation -Root $root -AuditCtx $auditCtx
    if ($locked) { return $locked }
    $lockAcquired = $true

    $errors = New-Object 'System.Collections.Generic.List[string]'
    $static = Invoke-BridgeAuditStaticAnalysis -Root $root -AuditCtx $auditCtx -ReportDir ([string]$run.reportDir) -Errors ([ref]$errors)
    $report = New-BridgeAuditReport -Root $root -ResolvedChannel ([string]$run.resolvedChannel) -ResolvedProject ([string]$run.resolvedProject) -AuditCtx $auditCtx -StaticResult $static -Stopwatch $stopwatch -Errors ([ref]$errors)
    $published = Publish-BridgeAuditStaticReport -Root $root -AuditCtx $auditCtx -Report $report -StaticResult $static -ReportDir ([string]$run.reportDir)
    $deep = Invoke-BridgeAuditDeepPhase -Root $root -AuditCtx $auditCtx -ReportDir ([string]$run.reportDir) -FunctionalAgent $FunctionalAgent -ResolvedChannel ([string]$run.resolvedChannel) -DeepAuditTimeoutSec $DeepAuditTimeoutSec -Paths $published.paths -Errors ([ref]$errors)
    return (Complete-BridgeAuditReport -Root $root -AuditCtx $auditCtx -Report $report -Paths $published.paths -StaticResult $static -Filed ([int]$published.filed) -DeepResult $deep -DeepAuditTimeoutSec $DeepAuditTimeoutSec -Errors ([ref]$errors))
  } finally {
    if ($lockAcquired) { Remove-AuditLock -BridgePath $root }
  }
}

function Wait-BridgeIdle {
  # Polls state.json until idle (no agent_pid, no active_jobs, status=='idle'). Returns
  # $true on idle, $false on timeout. Designed to be called inside a Start-Job from
  # driver.ps1 so a long wait doesn't block the main loop.
  param(
    [string]$StateFile,
    [int]$MaxMinutes = 60,
    [int]$PollSeconds = 30,
    [int]$StablePolls = 1
  )
  if ([string]::IsNullOrWhiteSpace($StateFile)) { return $false }
  if ($StablePolls -lt 1) { $StablePolls = 1 }
  $stableCount = 0
  $deadline = (Get-Date).AddMinutes($MaxMinutes)
  while ((Get-Date) -lt $deadline) {
    $isIdle = $false
    try {
      if (Test-Path -LiteralPath $StateFile) {
        $raw = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
          $st = $raw | ConvertFrom-Json
          $status = ''
          $agentPid = 0
          $activeCount = 0
          try { $status = [string]$st.status } catch {}
          try {
            if ($st.PSObject.Properties.Name -contains 'agent_pid' -and $null -ne $st.agent_pid) {
              $agentPid = [int]$st.agent_pid
            }
          } catch {}
          if (-not $agentPid) {
            try {
              if ($st.PSObject.Properties.Name -contains 'current_agent_pid' -and $null -ne $st.current_agent_pid) {
                $agentPid = [int]$st.current_agent_pid
              }
            } catch {}
          }
          try {
            if ($st.PSObject.Properties.Name -contains 'active_jobs' -and $st.active_jobs) {
              $activeCount = @($st.active_jobs).Count
            }
          } catch {}
          if ($status -eq 'idle' -and $agentPid -eq 0 -and $activeCount -eq 0) { $isIdle = $true }
        }
      }
    } catch {}
    if ($isIdle) {
      $stableCount++
      if ($stableCount -ge $StablePolls) { return $true }
    } else {
      $stableCount = 0
    }
    Start-Sleep -Seconds $PollSeconds
  }
  return $false
}

# When invoked directly (powershell.exe -File tools\audit.ps1), run the audit
# immediately against the parent directory of tools/. Dot-source consumers
# (driver's Start-AuditIfDue Start-Job) just pull the functions and call
# Wait-BridgeIdle + Invoke-BridgeAudit themselves.
if ($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\.\s') {
  $defaultRoot = Get-AuditBridgeRoot -Hint $null
  Invoke-BridgeAudit -BridgePath $defaultRoot | Out-Null
}
