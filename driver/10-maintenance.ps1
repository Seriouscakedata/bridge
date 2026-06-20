function Get-ObjectValue {
  param($Object, [string[]]$Names)
  if ($null -eq $Object) { return $null }
  foreach ($name in @($Names)) {
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    try {
      $prop = $Object.PSObject.Properties[$name]
      if ($prop -and $null -ne $prop.Value) { return $prop.Value }
    } catch {}
  }
  return $null
}

if ([string]::IsNullOrWhiteSpace([string]$bridgeRoot)) {
  try {
    if (Get-Command Get-BridgeRoot -ErrorAction SilentlyContinue) { $bridgeRoot = [string](Get-BridgeRoot) }
  } catch {}
  if ([string]::IsNullOrWhiteSpace([string]$bridgeRoot)) {
    try { $bridgeRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')) } catch {}
  }
}

function Normalize-ComparisonText {
  param([string]$Text)
  return (([string]$Text -replace '\s+', ' ').Trim().ToLowerInvariant())
}

function Read-JsonFileSafe {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json -Depth 20)
  } catch {
    return $null
  }
}

function Resolve-AddIdeaOutcome {
  param(
    $AddResult,
    [string]$IdeaText,
    [string]$From = ''
  )

  $out = [ordered]@{
    itemId  = ''
    deduped = $false
    cosine  = $null
    created = $false
  }

  if ($AddResult -is [string]) {
    $out.itemId = ([string]$AddResult).Trim()
    $out.created = -not [string]::IsNullOrWhiteSpace($out.itemId)
  } elseif ($AddResult) {
    $out.itemId = [string](Get-ObjectValue $AddResult @('itemId','id','existingId','existingItemId'))
    $dedupFlag = Get-ObjectValue $AddResult @('deduped','isDuplicate','duplicate')
    if ($null -ne $dedupFlag) {
      try { $out.deduped = [bool]$dedupFlag } catch {}
    }
    $status = [string](Get-ObjectValue $AddResult @('status','result','action'))
    if (-not $out.deduped -and $status -imatch '^(deduped|duplicate)$') { $out.deduped = $true }
    $createdFlag = Get-ObjectValue $AddResult @('created','isNew','newItemCreated','wasCreated')
    if ($null -ne $createdFlag) {
      try { $out.created = [bool]$createdFlag } catch {}
    }
    $out.cosine = Get-ObjectValue $AddResult @('cosine','similarity','score')
    if (-not $out.created -and -not $out.deduped -and -not [string]::IsNullOrWhiteSpace($out.itemId)) {
      $out.created = $true
    }
  }

  $fallback = Read-JsonFileSafe -Path $script:LastAddIdeaPath
  if ($fallback) {
    $recentEnough = $true
    try {
      $tsRaw = [string](Get-ObjectValue $fallback @('ts','timestamp'))
      if (-not [string]::IsNullOrWhiteSpace($tsRaw)) {
        $ts = [datetime]$tsRaw
        $recentEnough = ([math]::Abs(((Get-Date).ToUniversalTime() - $ts.ToUniversalTime()).TotalSeconds) -le 30)
      }
    } catch {}
    $matchText = $true
    $fallbackText = [string](Get-ObjectValue $fallback @('text','idea','inputText'))
    if (-not [string]::IsNullOrWhiteSpace($fallbackText) -and -not [string]::IsNullOrWhiteSpace($IdeaText)) {
      $matchText = ((Normalize-ComparisonText $fallbackText) -eq (Normalize-ComparisonText $IdeaText))
    }
    $matchFrom = $true
    $fallbackFrom = [string](Get-ObjectValue $fallback @('from','speaker','source'))
    if (-not [string]::IsNullOrWhiteSpace($fallbackFrom) -and -not [string]::IsNullOrWhiteSpace($From)) {
      $matchFrom = ((Normalize-ComparisonText $fallbackFrom) -eq (Normalize-ComparisonText $From))
    }
    if ($recentEnough -and $matchText -and $matchFrom) {
      $fallbackId = [string](Get-ObjectValue $fallback @('itemId','id','existingId','existingItemId'))
      if (-not [string]::IsNullOrWhiteSpace($fallbackId)) { $out.itemId = $fallbackId }
      $fallbackDedup = Get-ObjectValue $fallback @('deduped','isDuplicate','duplicate')
      if ($null -ne $fallbackDedup) {
        try { $out.deduped = [bool]$fallbackDedup } catch {}
      }
      $fallbackAction = [string](Get-ObjectValue $fallback @('status','result','action'))
      if (-not $out.deduped -and $fallbackAction -imatch '^(deduped|duplicate)$') { $out.deduped = $true }
      $fallbackCosine = Get-ObjectValue $fallback @('cosine','similarity','score')
      if ($null -ne $fallbackCosine) { $out.cosine = $fallbackCosine }
      $fallbackCreated = Get-ObjectValue $fallback @('created','isNew','newItemCreated','wasCreated')
      if ($null -ne $fallbackCreated) {
        try { $out.created = [bool]$fallbackCreated } catch {}
      } elseif (-not $out.deduped -and -not [string]::IsNullOrWhiteSpace($out.itemId)) {
        $out.created = $true
      }
    }
  }

  return [pscustomobject]$out
}

# 2026-05-27v6: Start-BacklogCuratorAsync REMOVED.
# Was: dead-code duplicate of lib/backlog.ps1:Start-BacklogCuratorJob with
# `Start-Process -Command $string` (shell-injection risk if ItemId contained
# ';', '`', '$(' or newlines). No callers (grep confirmed). The live code path
# is lib/backlog.ps1:Start-BacklogCuratorJob which uses a temp .ps1 launcher
# (no -Command injection surface). Removal closes the audit P1 finding.

function Get-NewCuratorDecisions {
  $items = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path -LiteralPath $script:CuratorDecisionsPath)) { return @() }
  $lines = @()
  try { $lines = @(Get-Content -LiteralPath $script:CuratorDecisionsPath -Encoding UTF8) } catch { return @() }
  if ($lines.Count -lt [int]$script:CuratorDecisionLineCount) { $script:CuratorDecisionLineCount = 0 }
  if ($lines.Count -le [int]$script:CuratorDecisionLineCount) {
    $script:CuratorDecisionLineCount = $lines.Count
    return @()
  }
  $start = [int]$script:CuratorDecisionLineCount
  for ($i = $start; $i -lt $lines.Count; $i++) {
    $line = [string]$lines[$i]
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $obj = $line | ConvertFrom-Json -Depth 20
      if ($obj) { [void]$items.Add($obj) }
    } catch {}
  }
  $script:CuratorDecisionLineCount = $lines.Count
  return @($items.ToArray())
}

function Publish-CuratorDecisionEvents {
  param([object[]]$Decisions = @())

  foreach ($decision in @($Decisions)) {
    if (-not $decision) { continue }
    $verdict = [string](Get-ObjectValue $decision @('verdict'))
    $action = [string](Get-ObjectValue $decision @('action'))
    $text = [string](Get-ObjectValue $decision @('text','idea','itemText','preview'))
    $reason = [string](Get-ObjectValue $decision @('reason','why'))
    $preview = Get-PushSnippet -Text $text -Max 80

    if ($action -eq 'freshness-skip' -or $action -eq 'freshness-auto-resolved') {
      $skipId = [string](Get-ObjectValue $decision @('item_id','itemId','id','ideaId'))
      $skipSha = [string](Get-ObjectValue $decision @('sha','commit','commitSha'))
      if ($skipSha.Length -gt 7) { $skipSha = $skipSha.Substring(0, 7) }
      if ([string]::IsNullOrWhiteSpace($skipId)) { $skipId = $preview }
      if ([string]::IsNullOrWhiteSpace($skipSha)) { $skipSha = 'unknown' }
      Add-Message -From system -Text "✓ Идея $skipId уже сделана в SHA $skipSha — пропускаю" -Kind event | Out-Null
      continue
    }

    switch ($verdict) {
      'approve' {
        Add-Message -From system -Text "✅ Куратор одобрил: $preview" -Kind event | Out-Null
      }
      'hold' {
        $msg = "⏸ Куратор просит твоё решение: $text"
        if (-not [string]::IsNullOrWhiteSpace($reason)) { $msg += " — $reason" }
        Add-Message -From system -Text $msg -Kind event | Out-Null
        try { Send-PushEvent -Kind need_you -Text $msg } catch {}
      }
      'drop' {
        $msg = "🚫 Куратор отклонил: $text"
        if (-not [string]::IsNullOrWhiteSpace($reason)) { $msg += " — $reason" }
        Add-Message -From system -Text $msg -Kind event | Out-Null
      }
    }
  }
}

function Get-MessageAttachmentPaths {
  param($Message)
  if (-not $Message.PSObject.Properties['attachments'] -or $null -eq $Message.attachments) { return @() }
  $paths = @()
  foreach ($att in @($Message.attachments)) {
    $url = [string]$att.url
    if ([string]::IsNullOrWhiteSpace($url) -or -not $url.StartsWith('/files/')) { continue }
    $storedName = [System.Uri]::UnescapeDataString($url.Substring('/files/'.Length))
    if ([string]::IsNullOrWhiteSpace($storedName)) { continue }
    $paths += [System.IO.Path]::GetFullPath((Join-Path (Get-FilesPath) $storedName))
  }
  return $paths
}

try {
  if (Test-Path -LiteralPath $script:CuratorDecisionsPath) {
    $script:CuratorDecisionLineCount = @(Get-Content -LiteralPath $script:CuratorDecisionsPath -Encoding UTF8).Count
  }
} catch {
  $script:CuratorDecisionLineCount = 0
}

function Start-LibrarianIfDue {
  # Run the memory consolidator detached when idle, gated by HYBRID schedule:
  #   - HARD floor: at least 30 min since the last run (so we don't spam Gemini).
  #   - SOFT ceiling: at least 6h since the last run -> run unconditionally.
  #   - DELTA trigger: >= 5 new memories since the last run -> run early (after the floor).
  # Old "every 24h" was useless during active development (map could be 24h stale while
  # memory grew 50+ entries). User noticed: "карта памяти сутки не обновлялась". 2026-05-26.
  try { $mc = Get-MemoryConfig } catch { return }
  if (-not $mc.enabled) { return }
  $deltaTrigger = 10
  $ceilingHours = 6
  try {
    $cfgLib = Get-BridgeConfig
    if ($cfgLib -and ($cfgLib.PSObject.Properties.Name -contains 'librarian') -and $cfgLib.librarian) {
      if (($cfgLib.librarian.PSObject.Properties.Name -contains 'deltaTriggerCount') -and $cfgLib.librarian.deltaTriggerCount) { $deltaTrigger = [int]$cfgLib.librarian.deltaTriggerCount }
      if (($cfgLib.librarian.PSObject.Properties.Name -contains 'ceilingHours') -and $cfgLib.librarian.ceilingHours) { $ceilingHours = [int]$cfgLib.librarian.ceilingHours }
    }
  } catch {}
  $scope = Get-EffectiveScope
  $marker = Join-Path ([string]$scope.memory_root) 'librarian.last'
  $countMarker = Join-Path ([string]$scope.memory_root) 'librarian.count.last'
  $lastTs = $null
  if (Test-Path $marker) { try { $lastTs = [datetime]((Get-Content $marker -Raw -Encoding UTF8).Trim()) } catch {} }
  if ($lastTs) {
    $age = (Get-Date) - $lastTs
    if ($age -lt [TimeSpan]::FromMinutes(30)) { return }     # hard floor
    if ($age -lt [TimeSpan]::FromHours($ceilingHours)) {
      # within the soft ceiling: only run if enough new memories accumulated
      $lastCount = -1
      if (Test-Path $countMarker) { try { $lastCount = [int]((Get-Content $countMarker -Raw -Encoding UTF8).Trim()) } catch {} }
      $curCount = 0
      try { $curCount = @(Get-AllMemories).Count } catch {}
      if ($lastCount -ge 0 -and ($curCount - $lastCount) -lt $deltaTrigger) { return }
    }
  }
  $lib = Join-Path $bridgeRoot 'librarian.ps1'
  if (-not (Test-Path $lib)) { return }
  # Touch the marker NOW so we don't relaunch every idle tick while it runs.
  try {
    $md = [string]$scope.memory_root
    if (-not (Test-Path $md)) { New-Item -ItemType Directory -Path $md -Force | Out-Null }
    [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
  try {
    $launch = [pscustomobject]@{ File = $lib }
    $libProc = Invoke-WithChannelEnv -Slug ([string]$scope.slug) -ArgumentList $launch -Action {
      param($Launch)
      Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',([string]$Launch.File) -WindowStyle Hidden -PassThru
    }
    if ($libProc) {
      $libTicks = 0L; try { $libTicks = (Get-Process -Id $libProc.Id -ErrorAction Stop).StartTime.Ticks } catch {}
      try { Register-ChildProcess -Label 'librarian' -ProcessId $libProc.Id -Ticks $libTicks } catch {}
    }
    Add-Message -From system -Text "🧠 Запущен библиотекарь памяти (консолидация в фоне)." -Kind event | Out-Null
  } catch {}
}

function Get-AuditMaintenanceDir {
  param([string]$Channel = 'main')
  $slug = $Channel
  try { if (Get-Command Normalize-ChannelSlug -ErrorAction SilentlyContinue) { $slug = Normalize-ChannelSlug $slug } } catch {}
  if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'main' }
  if ($slug -eq 'main') { return (Join-Path $bridgeRoot 'audit') }
  try {
    if (Get-Command Get-ChannelDir -ErrorAction SilentlyContinue) {
      return (Join-Path (Get-ChannelDir -Slug $slug) 'audit')
    }
  } catch {}
  return (Join-Path (Join-Path (Join-Path $bridgeRoot 'channels') $slug) 'audit')
}

function ConvertTo-AuditMaintenanceLogText {
  param([string]$Text, [int]$MaxLength = 1200)
  $out = ([string]$Text) -replace '[\r\n]+', ' '
  $out = $out.Trim()
  if ($MaxLength -gt 0 -and $out.Length -gt $MaxLength) { return ($out.Substring(0, $MaxLength) + '...<truncated>') }
  return $out
}

function Write-AuditMaintenanceLog {
  param(
    [string]$Channel = 'main',
    [string]$AuditDir = '',
    [Parameter(Mandatory=$true)][string]$Message
  )
  $msg = ConvertTo-AuditMaintenanceLogText -Text $Message
  if ([string]::IsNullOrWhiteSpace($msg)) { return }
  try {
    if (Get-Command Write-AuditorLog -ErrorAction SilentlyContinue) {
      Write-AuditorLog $msg
    }
  } catch {}
  try {
    $auditDir = $AuditDir
    if ([string]::IsNullOrWhiteSpace($auditDir)) { $auditDir = Get-AuditMaintenanceDir -Channel $Channel }
    if (-not (Test-Path -LiteralPath $auditDir)) { New-Item -ItemType Directory -Path $auditDir -Force | Out-Null }
    $logPath = Join-Path $auditDir 'audit.log'
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    [System.IO.File]::AppendAllText($logPath, ($line + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

function Write-AuditMaintenanceExceptionLog {
  param(
    [string]$Channel = 'main',
    [string]$AuditDir = '',
    [Parameter(Mandatory=$true)][string]$Context,
    [Parameter(Mandatory=$true)]$ErrorRecord
  )
  $type = ''
  $message = ''
  $stack = ''
  try { if ($ErrorRecord.Exception) { $type = $ErrorRecord.Exception.GetType().FullName; $message = [string]$ErrorRecord.Exception.Message } } catch {}
  try { $stack = [string]$ErrorRecord.ScriptStackTrace } catch {}
  Write-AuditMaintenanceLog -Channel $Channel -AuditDir $AuditDir -Message ("{0}: type={1}; message={2}; stack={3}" -f $Context, (ConvertTo-AuditMaintenanceLogText -Text $type -MaxLength 300), (ConvertTo-AuditMaintenanceLogText -Text $message -MaxLength 500), (ConvertTo-AuditMaintenanceLogText -Text $stack -MaxLength 900))
}

function Write-AuditMaintenanceSkipLog {
  param(
    [string]$Channel = 'main',
    [Parameter(Mandatory=$true)][string]$Reason,
    [string]$Detail = '',
    [int]$ThrottleMinutes = 15
  )
  if (-not $script:AuditMaintenanceSkipLogLast) { $script:AuditMaintenanceSkipLogLast = @{} }
  $key = ([string]$Channel) + '|' + ([string]$Reason)
  $now = (Get-Date).ToUniversalTime()
  $last = $null
  try { if ($script:AuditMaintenanceSkipLogLast.ContainsKey($key)) { $last = [datetime]$script:AuditMaintenanceSkipLogLast[$key] } } catch {}
  if ($last -and (($now - $last) -lt [TimeSpan]::FromMinutes([Math]::Max(1, $ThrottleMinutes)))) { return }
  $script:AuditMaintenanceSkipLogLast[$key] = $now
  $suffix = ''
  if (-not [string]::IsNullOrWhiteSpace($Detail)) { $suffix = '; ' + (ConvertTo-AuditMaintenanceLogText -Text $Detail -MaxLength 700) }
  Write-AuditMaintenanceLog -Channel $Channel -Message ("Start-AuditIfDue skipped: channel={0}; reason={1}{2}" -f ([string]$Channel), ([string]$Reason), $suffix)
}

function Test-AuditMaintenanceBusy {
  param([int]$MaxWaitMinutes = 60, [string]$AuditDir = $null)
  if ([string]::IsNullOrWhiteSpace($AuditDir)) { $AuditDir = Join-Path $bridgeRoot 'audit' }
  $auditDir = $AuditDir
  $waitMarker = Join-Path $auditDir 'audit.waiting'
  $lockMarker = Join-Path (Join-Path $bridgeRoot 'audit') '.audit.lock'
  $freshFor = [TimeSpan]::FromMinutes([Math]::Max(1, $MaxWaitMinutes + 10))

  if (Test-Path -LiteralPath $waitMarker) {
    $waitTs = $null
    try { $waitTs = [datetime]((Get-Content -LiteralPath $waitMarker -Raw -Encoding UTF8).Trim()) } catch {}
    if ($waitTs -and ((Get-Date) - $waitTs) -lt $freshFor) { return $true }
    try { Remove-Item -LiteralPath $waitMarker -Force -ErrorAction SilentlyContinue } catch {}
  }

  if (Test-Path -LiteralPath $lockMarker) {
    $lockPid = 0
    try { $lockPid = [int]((Get-Content -LiteralPath $lockMarker -Raw -Encoding UTF8).Trim()) } catch {}
    if ($lockPid -gt 0) {
      try {
        if (Get-Process -Id $lockPid -ErrorAction SilentlyContinue) { return $true }
      } catch {}
    }
    try { Remove-Item -LiteralPath $lockMarker -Force -ErrorAction SilentlyContinue } catch {}
  }

  return $false
}

function ConvertTo-AuditLaunchJsonLine {
  param(
    [Parameter(Mandatory=$true)]$Object
  )

  $json = ConvertTo-Json -InputObject $Object -Compress -Depth 8 -ErrorAction Stop
  if ([string]::IsNullOrWhiteSpace($json)) { throw 'empty audit launch json' }
  if ($json -match "[`r`n]") { throw 'audit launch json must be single-line jsonl' }
  return [string]$json
}

function ConvertFrom-AuditLaunchJsonLine {
  param([string]$Line)

  if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
  try {
    return (ConvertFrom-Json -InputObject $Line -ErrorAction Stop)
  } catch {
    return $null
  }
}

function Write-AuditLaunchLedgerEntry {
  param(
    [Parameter(Mandatory=$true)][string]$AuditDir,
    [Parameter(Mandatory=$true)][string]$Channel,
    [Parameter(Mandatory=$true)][string]$Decision,
    [string]$Reason = '',
    [int]$MaxAttempts = 0,
    [int]$WindowMinutes = 0,
    [int]$ProcessId = 0,
    [string]$RunId = '',
    [string]$ReportPath = '',
    [double]$RuntimeSeconds = 0,
    [string]$ExitReason = ''
  )

  if (-not (Test-Path -LiteralPath $AuditDir)) { New-Item -ItemType Directory -Path $AuditDir -Force | Out-Null }
  $ledgerPath = Join-Path $AuditDir 'audit.launches.jsonl'
  $entry = [ordered]@{
    ts             = (Get-Date).ToUniversalTime().ToString('o')
    channel        = [string]$Channel
    decision       = [string]$Decision
    reason         = [string]$Reason
    max_attempts   = [int]$MaxAttempts
    window_minutes = [int]$WindowMinutes
    pid            = [int]$ProcessId
    run_id         = [string]$RunId
    report_path    = [string]$ReportPath
    runtime_seconds = [math]::Round([double]$RuntimeSeconds, 3)
    runtime        = [TimeSpan]::FromSeconds([Math]::Max(0, [double]$RuntimeSeconds)).ToString()
    exit_reason    = [string]$ExitReason
  }
  $line = ConvertTo-AuditLaunchJsonLine -Object $entry
  $encoding = New-Object System.Text.UTF8Encoding($false)
  $bytes = $encoding.GetBytes($line + "`n")
  $lastError = $null
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    $stream = $null
    try {
      $stream = [System.IO.File]::Open($ledgerPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
      $stream.Write($bytes, 0, $bytes.Length)
      return $ledgerPath
    } catch {
      $lastError = $_.Exception
      if ($attempt -lt 5) { Start-Sleep -Milliseconds (25 * $attempt) }
    } finally {
      if ($stream) { $stream.Dispose() }
    }
  }
  if ($lastError) { throw $lastError }
  throw 'audit launch ledger append failed'
}

function Get-AuditLaunchAttemptCount {
  param(
    [Parameter(Mandatory=$true)][string]$AuditDir,
    [Parameter(Mandatory=$true)][datetime]$SinceUtc,
    [string]$Channel = ''
  )

  $ledgerPath = Join-Path $AuditDir 'audit.launches.jsonl'
  if (-not (Test-Path -LiteralPath $ledgerPath)) { return 0 }
  $lines = @()
  try { $lines = [System.IO.File]::ReadAllLines($ledgerPath) } catch { return 0 }

  $allParsed = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in @($lines)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $entry = ConvertFrom-AuditLaunchJsonLine -Line $line
      if ($entry) { [void]$allParsed.Add($entry) }
    } catch {}
  }

  $abandonedRunIds = @{}
  foreach ($entry in $allParsed) {
    if ([string]$entry.decision -eq 'abandoned' -and -not [string]::IsNullOrWhiteSpace([string]$entry.run_id)) {
      $abandonedRunIds[[string]$entry.run_id] = $true
    }
  }

  $sinceNorm = $SinceUtc.ToUniversalTime()
  $count = 0
  foreach ($entry in $allParsed) {
    if ([string]$entry.decision -ne 'started') { continue }
    if (-not [string]::IsNullOrWhiteSpace($Channel) -and [string]$entry.channel -ne [string]$Channel) { continue }
    try {
      $ts = [datetime]::Parse([string]$entry.ts, $null, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
      if ($ts -lt $sinceNorm) { continue }
    } catch { continue }
    $runId = [string]$entry.run_id
    if (-not [string]::IsNullOrWhiteSpace($runId) -and $abandonedRunIds.ContainsKey($runId)) { continue }
    $count++
  }
  return $count
}

function Invoke-AuditLaunchStaleStartReconciliation {
  param(
    [Parameter(Mandatory=$true)][string]$AuditDir,
    [string]$Channel = '',
    [Parameter(Mandatory=$true)][datetime]$SinceUtc,
    [int]$StaleStartedTtlMinutes = 60
  )

  $ledgerPath = Join-Path $AuditDir 'audit.launches.jsonl'
  if (-not (Test-Path -LiteralPath $ledgerPath)) { return 0 }
  $lines = @()
  try { $lines = [System.IO.File]::ReadAllLines($ledgerPath) } catch { return 0 }

  $allParsed = New-Object 'System.Collections.Generic.List[object]'
  $corruptLines = 0
  foreach ($line in @($lines)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $entry = ConvertFrom-AuditLaunchJsonLine -Line $line
      if ($entry) { [void]$allParsed.Add($entry) }
      else { $corruptLines++ }
    } catch {}
  }

  $terminalDecisions = @{
    completed_ok      = $true
    completed_partial = $true
    failed            = $true
    runner_timeout    = $true
    skipped_not_idle  = $true
    abandoned         = $true
  }
  $terminalRunIds = @{}
  foreach ($entry in $allParsed) {
    if ($terminalDecisions.ContainsKey([string]$entry.decision) -and -not [string]::IsNullOrWhiteSpace([string]$entry.run_id)) {
      $terminalRunIds[[string]$entry.run_id] = $true
    }
  }

  $now = (Get-Date).ToUniversalTime()
  $staleThreshold = $now.AddMinutes(-1 * [Math]::Max(1, $StaleStartedTtlMinutes))
  $sinceNorm = $SinceUtc.ToUniversalTime()
  $reconciled = 0
  $invalidTimestamps = 0
  foreach ($entry in $allParsed) {
    if ([string]$entry.decision -ne 'started') { continue }
    if (-not [string]::IsNullOrWhiteSpace($Channel) -and [string]$entry.channel -ne [string]$Channel) { continue }
    $runId = [string]$entry.run_id
    if ([string]::IsNullOrWhiteSpace($runId)) { continue }
    if ($terminalRunIds.ContainsKey($runId)) { continue }
    try {
      $ts = [datetime]::Parse([string]$entry.ts, $null, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
      if ($ts -lt $sinceNorm) { continue }
      if ($ts -gt $staleThreshold) { continue }
    } catch {
      $invalidTimestamps++
      continue
    }

    $entryPid = 0
    try { $entryPid = [int]$entry.pid } catch { $entryPid = 0 }
    if ($entryPid -le 0) { continue }

    $alive = $false
    try { $alive = [bool](Get-Process -Id $entryPid -ErrorAction SilentlyContinue) } catch {}
    if ($alive) { continue }

    try {
      Write-AuditLaunchLedgerEntry -AuditDir $AuditDir -Channel ([string]$entry.channel) -Decision 'abandoned' -Reason 'stale_pid_dead' -ProcessId $entryPid -RunId $runId -ExitReason ('stale_pid_dead: pid=' + $entryPid) | Out-Null
      $terminalRunIds[$runId] = $true
      $reconciled++
    } catch {}
  }
  if ($corruptLines -gt 0 -or $invalidTimestamps -gt 0) {
    Write-AuditMaintenanceLog -Channel $Channel -AuditDir $AuditDir -Message ("audit launch stale-start reconcile skipped corrupt_lines={0}; invalid_timestamps={1}; ledger={2}" -f $corruptLines, $invalidTimestamps, $ledgerPath)
  }
  return $reconciled
}

function Test-AuditLaunchLockActive {
  param(
    [Parameter(Mandatory=$true)][string]$LockPath,
    [int]$TtlMinutes = 10
  )

  if (-not (Test-Path -LiteralPath $LockPath)) { return $false }
  $ttl = [TimeSpan]::FromMinutes([Math]::Max(1, $TtlMinutes))
  $now = (Get-Date).ToUniversalTime()
  $created = $null
  $lockPid = 0
  try {
    $raw = Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      $lock = ConvertFrom-AuditLaunchJsonLine -Line $raw
      if ($lock -and $lock.PSObject.Properties.Name -contains 'created_at') {
        try { $created = [datetime]::Parse([string]$lock.created_at, $null, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch {}
      }
      if ($lock -and $lock.PSObject.Properties.Name -contains 'pid') {
        try { $lockPid = [int]$lock.pid } catch { $lockPid = 0 }
      }
    }
  } catch {}
  if (-not $created) {
    try { $created = ([System.IO.File]::GetLastWriteTimeUtc($LockPath)) } catch { $created = $now }
  }
  $age = $now - $created
  if ($age -ge $ttl) {
    try { Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue } catch {}
    return $false
  }
  if ($lockPid -gt 0) {
    $alive = $false
    try { $alive = [bool](Get-Process -Id $lockPid -ErrorAction SilentlyContinue) } catch {}
    if (-not $alive) {
      try { Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue } catch {}
      return $false
    }
  }
  return $true
}

function New-AuditLaunchAdmissionLock {
  param(
    [Parameter(Mandatory=$true)][string]$LockPath,
    [Parameter(Mandatory=$true)][string]$Channel,
    [int]$TtlMinutes = 10
  )

  $parent = Split-Path -Parent $LockPath
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
  if (Test-AuditLaunchLockActive -LockPath $LockPath -TtlMinutes $TtlMinutes) {
    return [pscustomobject]@{ acquired = $false; reason = 'launch_lock_active'; token = '' }
  }

  $token = [guid]::NewGuid().ToString('N')
  $payloadObject = [ordered]@{
    token      = $token
    channel    = [string]$Channel
    pid        = [int]$PID
    created_at = (Get-Date).ToUniversalTime().ToString('o')
  }
  $payload = ConvertTo-AuditLaunchJsonLine -Object $payloadObject
  $stream = $null
  try {
    $stream = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($payload)
    $stream.Write($bytes, 0, $bytes.Length)
    return [pscustomobject]@{ acquired = $true; reason = ''; token = $token }
  } catch {
    return [pscustomobject]@{ acquired = $false; reason = 'launch_lock_race'; token = '' }
  } finally {
    if ($stream) { $stream.Dispose() }
  }
}

function Remove-AuditLaunchAdmissionLock {
  param(
    [Parameter(Mandatory=$true)][string]$LockPath,
    [string]$Token = ''
  )

  if (-not (Test-Path -LiteralPath $LockPath)) { return }
  if (-not [string]::IsNullOrWhiteSpace($Token)) {
    try {
      $raw = Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8
      $lock = ConvertFrom-AuditLaunchJsonLine -Line $raw
      if ($lock -and [string]$lock.token -ne [string]$Token) { return }
    } catch { return }
  }
  try { Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue } catch {}
}

function Request-AuditLaunchAdmission {
  param(
    [Parameter(Mandatory=$true)][string]$AuditDir,
    [string]$Channel = 'main',
    [int]$MaxAttempts = 2,
    [int]$WindowMinutes = 60,
    [int]$LockTtlMinutes = 10,
    [int]$StaleStartedTtlMinutes = 60
  )

  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }
  if ($MaxAttempts -lt 1) { $MaxAttempts = 1 } elseif ($MaxAttempts -gt 24) { $MaxAttempts = 24 }
  if ($WindowMinutes -lt 5) { $WindowMinutes = 5 } elseif ($WindowMinutes -gt 1440) { $WindowMinutes = 1440 }
  if ($LockTtlMinutes -lt 1) { $LockTtlMinutes = 1 } elseif ($LockTtlMinutes -gt 60) { $LockTtlMinutes = 60 }
  if ($StaleStartedTtlMinutes -lt 0) { $StaleStartedTtlMinutes = 0 } elseif ($StaleStartedTtlMinutes -gt 480) { $StaleStartedTtlMinutes = 480 }
  if (-not (Test-Path -LiteralPath $AuditDir)) { New-Item -ItemType Directory -Path $AuditDir -Force | Out-Null }

  $lockPath = Join-Path $AuditDir 'audit.launch.lock'
  $lock = New-AuditLaunchAdmissionLock -LockPath $lockPath -Channel $Channel -TtlMinutes $LockTtlMinutes
  if (-not [bool]$lock.acquired) {
    try { Write-AuditLaunchLedgerEntry -AuditDir $AuditDir -Channel $Channel -Decision 'denied' -Reason ([string]$lock.reason) -MaxAttempts $MaxAttempts -WindowMinutes $WindowMinutes -ProcessId $PID | Out-Null } catch {}
    return [pscustomobject]@{ allowed = $false; reason = [string]$lock.reason; count = $null; lock_path = $lockPath }
  }

  try {
    $runId = [guid]::NewGuid().ToString()
    $since = (Get-Date).ToUniversalTime().AddMinutes(-1 * $WindowMinutes)
    if ($StaleStartedTtlMinutes -gt 0) {
      try { Invoke-AuditLaunchStaleStartReconciliation -AuditDir $AuditDir -Channel $Channel -SinceUtc $since -StaleStartedTtlMinutes $StaleStartedTtlMinutes | Out-Null } catch {
        Write-AuditMaintenanceExceptionLog -Channel $Channel -AuditDir $AuditDir -Context 'audit launch stale-start reconciliation failed; continuing' -ErrorRecord $_
      }
    }
    $count = Get-AuditLaunchAttemptCount -AuditDir $AuditDir -SinceUtc $since -Channel $Channel
    if ($count -ge $MaxAttempts) {
      Write-AuditLaunchLedgerEntry -AuditDir $AuditDir -Channel $Channel -Decision 'denied' -Reason 'max_attempts_per_window' -MaxAttempts $MaxAttempts -WindowMinutes $WindowMinutes -ProcessId $PID | Out-Null
      return [pscustomobject]@{ allowed = $false; reason = 'max_attempts_per_window'; count = $count; lock_path = $lockPath }
    }
    Write-AuditLaunchLedgerEntry -AuditDir $AuditDir -Channel $Channel -Decision 'started' -Reason '' -MaxAttempts $MaxAttempts -WindowMinutes $WindowMinutes -ProcessId $PID -RunId $runId | Out-Null
    return [pscustomobject]@{ allowed = $true; reason = ''; count = ($count + 1); lock_path = $lockPath; run_id = $runId }
  } catch {
    Write-AuditMaintenanceExceptionLog -Channel $Channel -AuditDir $AuditDir -Context 'audit launch admission failed' -ErrorRecord $_
    try { Write-AuditLaunchLedgerEntry -AuditDir $AuditDir -Channel $Channel -Decision 'denied' -Reason 'launch_ledger_error' -MaxAttempts $MaxAttempts -WindowMinutes $WindowMinutes -ProcessId $PID | Out-Null } catch {}
    return [pscustomobject]@{ allowed = $false; reason = 'launch_ledger_error'; count = $null; lock_path = $lockPath }
  } finally {
    Remove-AuditLaunchAdmissionLock -LockPath $lockPath -Token ([string]$lock.token)
  }
}

function Test-ChannelMaintenanceEnabled {
  param(
    [ValidateSet('audit','brainstorm')]
    [string]$Kind,
    [string]$Channel = ''
  )

  $slug = $Channel
  try {
    if ([string]::IsNullOrWhiteSpace($slug) -and (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue)) {
      $slug = [string](Get-EffectiveChannel)
    }
  } catch {}
  if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'main' }
  try { if (Get-Command Normalize-ChannelSlug -ErrorAction SilentlyContinue) { $slug = Normalize-ChannelSlug $slug } } catch {}
  if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'main' }
  if ($slug -eq 'main') { return $true }

  $field = if ($Kind -eq 'audit') { 'nonMainAuditEnabled' } else { 'nonMainBrainstormEnabled' }
  $enabled = $false
  try {
    $cfg = Get-BridgeConfig
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'channelMaintenance') -and $cfg.channelMaintenance) {
      $node = $cfg.channelMaintenance
      if (($node.PSObject.Properties.Name -contains $field) -and $null -ne $node.$field) {
        $enabled = [bool]$node.$field
      }
    }
  } catch {}
  return [bool]$enabled
}

function Start-BacklogReaperIfDue {
  try { Invoke-BacklogHeldItemAutoTriage | Out-Null } catch {}
  # Recover zombie running/working backlog items whose worker died -- no live agent_pid, no fresh
  # worker heartbeat, and no matching active runtime task. The reaper (lib/backlog-state-reaper.ps1)
  # was built + unit-tested but NEVER wired into the loop, so an orphaned 'running' atom (e.g. a stream
  # the parallel collector quarantined) sat indefinitely holding a lease that wedged the whole queue
  # (observed: an atom stuck 'running' ~13h). Run on idle: any running item with no live owner is a
  # zombie -> recovered to 'held', releasing the lease for a clean re-attempt. The reaper preserves
  # anything with a live PID / fresh heartbeat / matching active runtime, so it never reaps live work.
  if (-not (Get-Command Invoke-BacklogStateReaper -ErrorAction SilentlyContinue)) { return }
  $recovered = @()
  try {
    $preItems = @(Get-Backlog)
    $hasRunning = @($preItems | Where-Object { @('running','working') -contains ([string]$_.status).Trim().ToLowerInvariant() }).Count
    if ($hasRunning -eq 0) { return }
    $recovered = @(Invoke-BacklogLocked ({
      $items = @(Get-Backlog)
      $reapState = $null; try { $reapState = Read-State } catch {}
      $r = Invoke-BacklogStateReaper -Items $items -RuntimeState $reapState -HeartbeatMaxAgeSeconds 900
      if (@($r.recovered).Count -gt 0) { Save-Backlog @($r.items); return @($r.recovered) }
      return @()
    }.GetNewClosure()))
  } catch { $recovered = @() }
  foreach ($rec in @($recovered)) {
    try {
      Add-Message -From system -Text ("♻️ Zombie-reaper восстановил задачу " + [string]$rec.id + " (была '" + [string]$rec.from_status + "' без живого владельца) → held; lease освобождён для повторного claim.") -Kind event | Out-Null
    } catch {}
  }
}

function Test-BacklogHeldItemAutoTriageDue {
  param(
    [string]$MarkerPath = '',
    [double]$FloorHours = 3.0,
    [switch]$Force
  )
  if ($Force) { return $true }
  if ([string]::IsNullOrWhiteSpace($MarkerPath)) { $MarkerPath = Join-Path $bridgeRoot 'control\held-auto-triage.last' }
  if (-not (Test-Path -LiteralPath $MarkerPath)) { return $true }
  try {
    $last = [datetime]::Parse((Get-Content -LiteralPath $MarkerPath -Raw -Encoding UTF8).Trim(), $null, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    return (((Get-Date).ToUniversalTime() - $last).TotalHours -ge [Math]::Max(0.1, $FloorHours))
  } catch {
    return $true
  }
}

function Test-BacklogHeldItemOldEnough {
  param($Item, [double]$MinAgeDays = 1.0)
  if (-not $Item) { return $false }
  $raw = ''
  foreach ($name in @('created_at','ts','created','submitted_at')) {
    try { $raw = [string](Get-BacklogPackObjectValue -Obj $Item -Name $name -Default '') } catch { $raw = '' }
    if (-not [string]::IsNullOrWhiteSpace($raw)) { break }
  }
  if ([string]::IsNullOrWhiteSpace($raw)) { return $false }
  try {
    $created = [datetime]::Parse($raw, $null, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    return (((Get-Date).ToUniversalTime() - $created).TotalDays -gt $MinAgeDays)
  } catch {
    return $false
  }
}

function Invoke-BacklogHeldItemAutoTriage {
  param(
    [object[]]$Items = $null,
    [int]$MaxActions = 5,
    [double]$MinAgeDays = 1.0,
    [double]$FloorHours = 3.0,
    [string]$MarkerPath = '',
    [switch]$Force
  )
  if (-not (Get-Command Test-BacklogAutoTriageDecision -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ actions=0; escalated=0; changed=$false } }
  if (-not (Get-Command Approve-BacklogItemViaCanary -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ actions=0; escalated=0; changed=$false } }
  if ($MaxActions -lt 1) { $MaxActions = 1 } elseif ($MaxActions -gt 20) { $MaxActions = 20 }
  if ([string]::IsNullOrWhiteSpace($MarkerPath)) { $MarkerPath = Join-Path $bridgeRoot 'control\held-auto-triage.last' }
  if (-not (Test-BacklogHeldItemAutoTriageDue -MarkerPath $MarkerPath -FloorHours $FloorHours -Force:$Force)) { return [pscustomobject]@{ actions=0; escalated=0; changed=$false; due=$false } }

  $loadedFromBacklog = ($null -eq $Items)
  if ($loadedFromBacklog) { $Items = @(Get-Backlog) }
  $actions = 0
  $changed = $false
  $escalated = New-Object 'System.Collections.Generic.List[string]'
  foreach ($item in @($Items)) {
    if ($actions -ge $MaxActions) { break }
    $status = ([string](Get-BacklogPackObjectValue -Obj $item -Name 'status' -Default '')).Trim().ToLowerInvariant()
    if ($status -notin @('held','new')) { continue }
    if (-not (Test-BacklogHeldItemOldEnough -Item $item -MinAgeDays $MinAgeDays)) { continue }
    $id = [string](Get-BacklogPackObjectValue -Obj $item -Name 'id' -Default '')
    $decision = Test-BacklogAutoTriageDecision -Item $item
    $kind = ([string](Get-BacklogPackObjectValue -Obj $decision -Name 'decision' -Default '')).Trim().ToLowerInvariant()
    $reason = [string](Get-BacklogPackObjectValue -Obj $decision -Name 'reason' -Default '')
    if ($kind -eq 'approve') {
      Set-BacklogObjectProperty -Item $item -Name 'status' -Value 'approved'
      Set-BacklogObjectProperty -Item $item -Name 'approved_at' -Value ((Get-Date).ToUniversalTime().ToString('o'))
      Set-BacklogObjectProperty -Item $item -Name 'approved_by' -Value 'auto-triage'
      try { Add-Message -From system -Text ("Авто-триаж: approved " + $id + " (" + $reason + ")") -Kind event | Out-Null } catch {}
      $actions++; $changed = $true
    } elseif ($kind -eq 'canary') {
      [void](Approve-BacklogItemViaCanary -Item $item -Decision $decision)
      try { Add-Message -From system -Text ("Авто-триаж: canary " + $id + " (" + $reason + ")") -Kind event | Out-Null } catch {}
      $actions++; $changed = $true
    } elseif ($kind -eq 'reject') {
      Set-BacklogObjectProperty -Item $item -Name 'status' -Value 'rejected'
      Set-BacklogObjectProperty -Item $item -Name 'rejected_at' -Value ((Get-Date).ToUniversalTime().ToString('o'))
      Set-BacklogObjectProperty -Item $item -Name 'rejected_reason' -Value $reason
      try { Add-Message -From system -Text ("Авто-триаж: rejected " + $id + " (" + $reason + ")") -Kind event | Out-Null } catch {}
      $actions++; $changed = $true
    } else {
      [void]$escalated.Add(($id + " " + $reason).Trim())
      try { Add-Message -From system -Text ("Авто-триаж: escalate " + $id + " (" + $reason + ")") -Kind event | Out-Null } catch {}
    }
  }
  if ($escalated.Count -gt 0) {
    try { Add-Message -From system -Text (($escalated.Count.ToString()) + " задач ждут решения оператора: " + ((@($escalated.ToArray()) | Select-Object -First 10) -join '; ')) -Kind event | Out-Null } catch {}
  }
  if ($changed -and $loadedFromBacklog) { Save-Backlog @($Items) }
  try {
    $parent = Split-Path -Parent $MarkerPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($MarkerPath, (Get-Date).ToUniversalTime().ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
  return [pscustomobject]@{ actions=$actions; escalated=$escalated.Count; changed=$changed; due=$true }
}

function Start-AuditIfDue {
  # Run the daily audit for this driver's channel during the configured night window:
  #   - audit.enabled in config.json gates the whole thing.
  #   - current local hour must be inside [windowStartHour..windowEndHour] (wraps midnight if start > end).
  #   - channel-specific audit.last marker must be older than floorHours (default 20h) so we run ~once/day.
  # The detached audit runner dot-sources lib/common.ps1 + tools/audit.ps1, waits
  # for stable idle, then calls Invoke-BridgeAudit. audit.last is written only by
  # a successful audit; audit.waiting only prevents duplicate waiting processes.
  $auditCfg = $null
  try {
    $cfgA = Get-BridgeConfig
    if ($cfgA -and ($cfgA.PSObject.Properties.Name -contains 'audit') -and $cfgA.audit) { $auditCfg = $cfgA.audit }
  } catch {
    Write-AuditMaintenanceExceptionLog -Channel 'main' -Context 'Start-AuditIfDue config read failed' -ErrorRecord $_
    return
  }
  if (-not $auditCfg) {
    Write-AuditMaintenanceSkipLog -Channel 'main' -Reason 'missing_audit_config'
    return
  }
  $enabled = if ($null -ne $auditCfg.enabled) { [bool]$auditCfg.enabled } else { $true }
  if (-not $enabled) {
    Write-AuditMaintenanceSkipLog -Channel 'main' -Reason 'audit_disabled'
    return
  }
  $startH  = if ($null -ne $auditCfg.windowStartHour) { [int]$auditCfg.windowStartHour } else { 1 }
  $endH    = if ($null -ne $auditCfg.windowEndHour)   { [int]$auditCfg.windowEndHour }   else { 6 }
  $floorH  = if ($null -ne $auditCfg.floorHours)      { [int]$auditCfg.floorHours }      else { 20 }
  $maxWait = if ($null -ne $auditCfg.maxWaitMinutes)  { [int]$auditCfg.maxWaitMinutes }  else { 60 }
  $launchMax = if ($null -ne $auditCfg.maxLaunchAttemptsPerWindow) { [int]$auditCfg.maxLaunchAttemptsPerWindow } else { 2 }
  $launchWindow = if ($null -ne $auditCfg.launchAttemptWindowMinutes) { [int]$auditCfg.launchAttemptWindowMinutes } else { 60 }
  $launchLockTtl = if ($null -ne $auditCfg.launchLockTtlMinutes) { [int]$auditCfg.launchLockTtlMinutes } else { 10 }
  $launchStaleTtl = if ($null -ne $auditCfg.launchStaleStartedTtlMinutes) { [int]$auditCfg.launchStaleStartedTtlMinutes } else { 60 }
  if ($startH -lt 0) { $startH = 0 } elseif ($startH -gt 23) { $startH = 23 }
  if ($endH -lt 0) { $endH = 0 } elseif ($endH -gt 23) { $endH = 23 }
  if ($floorH -lt 1) { $floorH = 1 } elseif ($floorH -gt 168) { $floorH = 168 }
  if ($maxWait -lt 1) { $maxWait = 1 } elseif ($maxWait -gt 240) { $maxWait = 240 }
  if ($launchMax -lt 1) { $launchMax = 1 } elseif ($launchMax -gt 24) { $launchMax = 24 }
  if ($launchWindow -lt 5) { $launchWindow = 5 } elseif ($launchWindow -gt 1440) { $launchWindow = 1440 }
  if ($launchLockTtl -lt 1) { $launchLockTtl = 1 } elseif ($launchLockTtl -gt 60) { $launchLockTtl = 60 }
  if ($launchStaleTtl -lt 0) { $launchStaleTtl = 0 } elseif ($launchStaleTtl -gt 480) { $launchStaleTtl = 480 }
  $hourNow = (Get-Date).Hour
  $inWindow = $false
  if ($startH -le $endH) {
    if ($hourNow -ge $startH -and $hourNow -le $endH) { $inWindow = $true }
  } else {
    # window wraps midnight (e.g. 22..5)
    if ($hourNow -ge $startH -or $hourNow -le $endH) { $inWindow = $true }
  }
  if (-not $inWindow) {
    Write-AuditMaintenanceSkipLog -Channel 'main' -Reason 'outside_window' -Detail ("hour={0}; window={1}-{2}" -f $hourNow, $startH, $endH)
    return
  }
  $auditChannel = 'main'
  try { $auditChannel = [string](Get-EffectiveChannel) } catch {}
  if ([string]::IsNullOrWhiteSpace($auditChannel)) { $auditChannel = 'main' }
  try { if (Get-Command Normalize-ChannelSlug -ErrorAction SilentlyContinue) { $auditChannel = Normalize-ChannelSlug $auditChannel } } catch {}
  if (-not (Test-ChannelMaintenanceEnabled -Kind 'audit' -Channel $auditChannel)) {
    Write-AuditMaintenanceSkipLog -Channel $auditChannel -Reason 'channel_audit_disabled'
    return
  }
  $auditDir = Get-AuditMaintenanceDir -Channel $auditChannel
  $marker   = Join-Path $auditDir 'audit.last'
  $waitMarker = Join-Path $auditDir 'audit.waiting'
  if (Test-Path -LiteralPath $marker) {
    try {
      $last = [datetime]((Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim())
      # 2026-06-05 FIX (operator): once-per-window-OCCURRENCE, not a sliding floorHours.
      # Bug: a sliding floorHours anchored on audit.last let an off-window/manual run (e.g. 19:13)
      # push the next allowed run (19:13+20h=15:13) PAST the whole 01-06 night window, silently
      # skipping the nightly audit. We are already inside the window here (checked above), so anchor
      # to the START of the current window occurrence: skip only if the last audit already landed
      # at/after this window opened. An earlier off-window run no longer blocks the night.
      $nowD = Get-Date
      $winStart = Get-Date -Hour $startH -Minute 0 -Second 0
      if ($startH -gt $endH -and $nowD.Hour -le $endH) { $winStart = $winStart.AddDays(-1) }
      if ($last -ge $winStart) {
        Write-AuditMaintenanceSkipLog -Channel $auditChannel -Reason 'already_ran_this_window' -Detail ("last={0}; winStart={1}" -f $last.ToString('o'), $winStart.ToString('o'))
        return
      }
      # secondary anti-double-run guard: never re-run within floorH of a run that already happened
      # AFTER the window opened (cheap protection if the window is ever misconfigured very wide).
      if ($last -ge $winStart -and (($nowD - $last) -lt [TimeSpan]::FromHours($floorH))) {
        Write-AuditMaintenanceSkipLog -Channel $auditChannel -Reason 'floor_hours_guard' -Detail ("last={0}; floor_hours={1}" -f $last.ToString('o'), $floorH)
        return
      }
    } catch {
      Write-AuditMaintenanceExceptionLog -Channel $auditChannel -Context 'Start-AuditIfDue audit.last parse failed; continuing' -ErrorRecord $_
    }
  }
  $auditScript = Join-Path $bridgeRoot 'tools\audit.ps1'
  if (-not (Test-Path -LiteralPath $auditScript)) {
    Write-AuditMaintenanceSkipLog -Channel $auditChannel -Reason 'missing_audit_script' -Detail $auditScript
    return
  }
  $auditRunner = Join-Path $bridgeRoot 'tools\audit-runner.ps1'
  if (-not (Test-Path -LiteralPath $auditRunner)) {
    Write-AuditMaintenanceSkipLog -Channel $auditChannel -Reason 'missing_audit_runner' -Detail $auditRunner
    return
  }
  if (Test-AuditMaintenanceBusy -MaxWaitMinutes $maxWait -AuditDir $auditDir) {
    Write-AuditMaintenanceSkipLog -Channel $auditChannel -Reason 'audit_busy'
    return
  }
  $launchAdmission = Request-AuditLaunchAdmission -AuditDir $auditDir -Channel $auditChannel -MaxAttempts $launchMax -WindowMinutes $launchWindow -LockTtlMinutes $launchLockTtl -StaleStartedTtlMinutes $launchStaleTtl
  if (-not $launchAdmission -or -not [bool]$launchAdmission.allowed) {
    $denyReason = if ($launchAdmission) { [string]$launchAdmission.reason } else { 'no_admission_result' }
    $denyCount = if ($launchAdmission) { [string]$launchAdmission.count } else { '' }
    Write-AuditMaintenanceSkipLog -Channel $auditChannel -Reason 'launch_denied' -Detail ("admission_reason={0}; count={1}" -f $denyReason, $denyCount)
    return
  }
  $auditRunId = [string]$launchAdmission.run_id
  $launchStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  $waitMarkerWritten = $false
  try {
    if (-not (Test-Path -LiteralPath $auditDir)) { New-Item -ItemType Directory -Path $auditDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($waitMarker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
    $waitMarkerWritten = $true
  } catch {
    try { Write-AuditLaunchLedgerEntry -AuditDir $auditDir -Channel $auditChannel -Decision 'failed' -Reason 'wait_marker_write_failed' -ProcessId $PID -RunId $auditRunId -RuntimeSeconds $launchStopwatch.Elapsed.TotalSeconds -ExitReason ('wait_marker_write_failed: ' + $_.Exception.Message) | Out-Null } catch {}
    Write-AuditMaintenanceExceptionLog -Channel $auditChannel -Context 'Start-AuditIfDue wait marker write failed' -ErrorRecord $_
    return
  }
  if (-not $waitMarkerWritten) {
    Write-AuditMaintenanceSkipLog -Channel $auditChannel -Reason 'wait_marker_not_written'
    return
  }
  $stateFile = $null
  try { $stateFile = Get-StatePath } catch {}
  if ([string]::IsNullOrWhiteSpace($stateFile)) { $stateFile = Join-Path $bridgeRoot 'channels\main\state.json' }
  try {
    $args = @(
      '-NoProfile',
      '-ExecutionPolicy', 'Bypass',
      '-File', $auditRunner,
      '-BridgePath', $bridgeRoot,
      '-StateFile', $stateFile,
      '-MaxWaitMinutes', [string]$maxWait,
      '-WaitMarker', $waitMarker,
      '-Channel', $auditChannel,
      '-RunId', $auditRunId
    )
    $launch = [pscustomobject]@{ Args = $args; Channel = $auditChannel }
    $auditProc = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
      param($Launch)
      Start-Process -FilePath 'powershell.exe' -ArgumentList $Launch.Args -WindowStyle Hidden -PassThru
    }
    if (-not $auditProc) { throw 'Start-Process did not return an audit process' }
    $auditTicks = 0L
    try { $auditTicks = (Get-Process -Id $auditProc.Id -ErrorAction Stop).StartTime.Ticks } catch {}
    try { Register-ChildProcess -Label 'audit' -ProcessId $auditProc.Id -Ticks $auditTicks } catch {}
    $auditLabel = if ($auditChannel -eq 'main') { 'моста' } else { "проекта канала $auditChannel" }
    Add-Message -From system -Text ("🔍 Запущен аудит {0} (фоновое задание, ожидание idle до {1} мин)." -f $auditLabel, $maxWait) -Kind event | Out-Null
  } catch {
    try { if (Test-Path -LiteralPath $waitMarker) { Remove-Item -LiteralPath $waitMarker -Force -ErrorAction SilentlyContinue } } catch {}
    try { Write-AuditLaunchLedgerEntry -AuditDir $auditDir -Channel $auditChannel -Decision 'failed' -Reason 'runner_start_failed' -ProcessId $PID -RunId $auditRunId -RuntimeSeconds $launchStopwatch.Elapsed.TotalSeconds -ExitReason ('runner_start_failed: ' + $_.Exception.Message) | Out-Null } catch {}
    Write-AuditMaintenanceExceptionLog -Channel $auditChannel -Context 'Start-AuditIfDue runner start failed' -ErrorRecord $_
  }
}

function Start-FeatureVerifierIfDue {
  # 2026-05-28 Phase 4: daily feature verifier. Walks features/registry.json,
  # runs scenarios from each feature's `scenarios` field via tools/scenario.ps1
  # (headless Chrome user-flow tests), records pass/fail to features/state.json
  # + audit/feature-verifier-YYYY-MM-DD.md. Broken features post chat alert.
  $vCfg = $null
  try {
    $cfgF = Get-BridgeConfig
    if ($cfgF -and ($cfgF.PSObject.Properties.Name -contains 'featureVerifier') -and $cfgF.featureVerifier) { $vCfg = $cfgF.featureVerifier }
  } catch {}
  $enabled = if ($vCfg -and $null -ne $vCfg.enabled) { [bool]$vCfg.enabled } else { $true }
  if (-not $enabled) { return }
  $startH = if ($vCfg -and $null -ne $vCfg.windowStartHour) { [int]$vCfg.windowStartHour } else { 2 }
  $endH   = if ($vCfg -and $null -ne $vCfg.windowEndHour)   { [int]$vCfg.windowEndHour }   else { 6 }
  $floorH = if ($vCfg -and $null -ne $vCfg.floorHours)      { [int]$vCfg.floorHours }      else { 20 }
  $hourNow = (Get-Date).Hour
  $inWindow = if ($startH -le $endH) { ($hourNow -ge $startH -and $hourNow -le $endH) } else { ($hourNow -ge $startH -or $hourNow -le $endH) }
  if (-not $inWindow) { return }
  $marker = Join-Path $bridgeRoot 'features\verifier.last'
  if (Test-Path -LiteralPath $marker) {
    try {
      $last = [datetime]((Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim())
      if (((Get-Date) - $last) -lt [TimeSpan]::FromHours($floorH)) { return }
    } catch {}
  }
  $verifierScript = Join-Path $bridgeRoot 'tools\feature-verifier.ps1'
  if (-not (Test-Path -LiteralPath $verifierScript)) { return }
  try {
    $vArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verifierScript, '-BridgePath', $bridgeRoot)
    $launch = [pscustomobject]@{ Args = $vArgs; Channel = (Get-EffectiveChannel) }
    $vp = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
      param($Launch)
      Start-Process -FilePath 'powershell.exe' -ArgumentList $Launch.Args -WindowStyle Hidden -PassThru
    }
    if ($vp) {
      $vpTicks = 0L
      try { $vpTicks = (Get-Process -Id $vp.Id -ErrorAction Stop).StartTime.Ticks } catch {}
      try { Register-ChildProcess -Label 'feature-verifier' -ProcessId $vp.Id -Ticks $vpTicks } catch {}
      try { [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
      Add-Message -From system -Text "🩻 Запущен Feature Verifier (проверка сценариев на живом UI)." -Kind event | Out-Null
    }
  } catch {}
}

function Start-ReflectIfDue {
  param([switch]$Force)
  # Launch idle self-reflection at most once per autonomy.reflectEveryHours, detached.
  $marker = Join-Path $bridgeRoot 'reflect.last'
  try {
    $stSkipReflect = Read-State
    if ([bool]$stSkipReflect.skip_reflect -or [bool]$stSkipReflect.last_task_skip_reflect) {
      try { [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
      try { Update-State { param($s) $s | Add-Member -NotePropertyName last_task_skip_reflect -NotePropertyValue $false -Force } | Out-Null } catch {}
      return
    }
  } catch {}
  $auto = $null
  try { $auto = Get-AutonomySettings } catch {
    try { $cfgA = Get-BridgeConfig; if ($cfgA.PSObject.Properties.Name -contains 'autonomy') { $auto = $cfgA.autonomy } } catch { return }
  }
  $enabled = if ($auto -and $null -ne $auto.enabled) { [bool]$auto.enabled } else { $true }
  if (-not $enabled) { return }
  $everyH = if ($auto -and $auto.reflectEveryHours) { [double]$auto.reflectEveryHours } else { 6 }
  if ((-not $Force) -and (Test-Path $marker)) {
    try {
      $last = [datetime]((Get-Content $marker -Raw -Encoding UTF8).Trim())
      if (((Get-Date) - $last) -lt [TimeSpan]::FromHours($everyH)) { return }
    } catch {}
  }
  if (-not $Force) { try {
    $cfgReflect = Get-BridgeConfig
    $minSec = 60
    if ($cfgReflect -and ($cfgReflect.PSObject.Properties.Name -contains 'reflect') -and $cfgReflect.reflect) {
      if (($cfgReflect.reflect.PSObject.Properties.Name -contains 'minTaskDurationSec') -and $cfgReflect.reflect.minTaskDurationSec) { $minSec = [int]$cfgReflect.reflect.minTaskDurationSec }
    }
    $stReflect = Read-State
    $totalSec = 0
    try { $totalSec = [int]$stReflect.task_agent_duration_sec } catch {}
    if ($totalSec -le 0) { try { $totalSec = [int]$stReflect.last_task_agent_duration_sec } catch {} }
    if ($totalSec -gt 0 -and $totalSec -lt $minSec) {
      try { Write-Host "[reflect skipped: task duration $totalSec s < $minSec s]" } catch {}
      try { [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
      return
    }
  } catch {} }
  $rf = Join-Path $bridgeRoot 'reflect.ps1'
  if (-not (Test-Path $rf)) { return }
  try { [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
  try {
    $launch = [pscustomobject]@{ File = $rf; Channel = (Get-EffectiveChannel) }
    $rfProc = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
      param($Launch)
      Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',([string]$Launch.File) -WindowStyle Hidden -PassThru
    }
    if ($rfProc) {
      $rfTicks = 0L; try { $rfTicks = (Get-Process -Id $rfProc.Id -ErrorAction Stop).StartTime.Ticks } catch {}
      try { Register-ChildProcess -Label 'reflect' -ProcessId $rfProc.Id -Ticks $rfTicks } catch {}
      return $true
    }
  } catch {}
  return $false
}

function Start-TechRadarIfDue {
  # Launch weekly tech-radar, detached, no more than once per radarEveryHours (default 168=7d).
  $everyH = 168
  try { $cfgB = Get-BridgeConfig; if ($cfgB.PSObject.Properties.Name -contains 'radarEveryHours') { $everyH = [int]$cfgB.radarEveryHours } } catch {}
  $marker = Join-Path $bridgeRoot 'radar.last'
  if (Test-Path -LiteralPath $marker) {
    try {
      $last = [datetime]((Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim())
      if (((Get-Date) - $last) -lt [TimeSpan]::FromHours($everyH)) { return }
    } catch {}
  }
  $rf = Join-Path $bridgeRoot 'techradar.ps1'
  if (-not (Test-Path -LiteralPath $rf)) { return }
  try { [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
  try {
    $launch = [pscustomobject]@{ File = $rf; Channel = (Get-EffectiveChannel) }
    $rdProc = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
      param($Launch)
      Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',([string]$Launch.File) -WindowStyle Hidden -PassThru
    }
    if ($rdProc) {
      $rdTicks = 0L; try { $rdTicks = (Get-Process -Id $rdProc.Id -ErrorAction Stop).StartTime.Ticks } catch {}
      try { Register-ChildProcess -Label 'tech-radar' -ProcessId $rdProc.Id -Ticks $rdTicks } catch {}
    }
    Add-Message -From system -Text "📡 Тех-радар запущен в фоне (еженедельный обход Хабра)." -Kind event | Out-Null
  } catch {}
}

function Start-CanaryIfDue {
  try {
    $ccfg = Get-BridgeConfig
    $canaryCfg = $null
    if ($ccfg.PSObject.Properties.Name -contains 'canary') { $canaryCfg = $ccfg.canary }
    if ($canaryCfg -and ($canaryCfg.PSObject.Properties.Name -contains 'enabled') -and -not [bool]$canaryCfg.enabled) { return }

    $ivH = 6.0
    try {
      if ($canaryCfg -and ($canaryCfg.PSObject.Properties.Name -contains 'intervalHours') -and $canaryCfg.intervalHours) {
        $ivH = [double]$canaryCfg.intervalHours
      }
    } catch {}

    $ctlDir = Join-Path $bridgeRoot 'control'
    if (-not (Test-Path -LiteralPath $ctlDir)) { New-Item -ItemType Directory -Path $ctlDir -Force | Out-Null }
    $launchMarker = Join-Path $ctlDir 'canary-launch.last'
    if (Test-Path -LiteralPath $launchMarker) {
      try {
        $lastLaunch = [DateTime]::Parse((Get-Content -LiteralPath $launchMarker -Raw -Encoding UTF8).Trim(), $null, [Globalization.DateTimeStyles]::RoundtripKind)
        if (((Get-Date).ToUniversalTime() - $lastLaunch.ToUniversalTime()).TotalMinutes -lt 30) { return }
      } catch {}
    }

    $lastRun = $null
    $runsPath = Join-Path $ctlDir 'canary-runs.jsonl'
    if (Test-Path -LiteralPath $runsPath) {
      try {
        $lastLine = Get-Content -LiteralPath $runsPath -Tail 1 -Encoding UTF8
        if ($lastLine) {
          $lastObj = $lastLine | ConvertFrom-Json
          if ($lastObj.timestamp) {
            $lastRun = [DateTime]::Parse([string]$lastObj.timestamp, $null, [Globalization.DateTimeStyles]::RoundtripKind)
          }
        }
      } catch {}
    }
    if (-not $lastRun) {
      try {
        $cst = Get-CanaryState
        if ($cst.last_heartbeat_at) {
          $lastRun = [DateTime]::Parse([string]$cst.last_heartbeat_at, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        }
      } catch {}
    }
    if ($lastRun -and (((Get-Date).ToUniversalTime() - $lastRun.ToUniversalTime()).TotalHours -lt $ivH)) { return }

    $canaryScript = Join-Path $PSScriptRoot 'canary.ps1'
    if (-not (Test-Path -LiteralPath $canaryScript)) { return }
    [System.IO.File]::WriteAllText($launchMarker, (Get-Date).ToUniversalTime().ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
    $launch = [pscustomobject]@{ File = $canaryScript; Channel = (Get-EffectiveChannel) }
    $caProc = Invoke-WithChannelEnv -Slug ([string]$launch.Channel) -ArgumentList $launch -Action {
      param($Launch)
      Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',([string]$Launch.File)) -WindowStyle Hidden -PassThru
    }
    if ($caProc) {
      $caTicks = 0L; try { $caTicks = (Get-Process -Id $caProc.Id -ErrorAction Stop).StartTime.Ticks } catch {}
      try { Register-ChildProcess -Label 'canary' -ProcessId $caProc.Id -Ticks $caTicks } catch {}
    }
  } catch {}
}

function Invoke-ConversationAutoArchiveIfDue {
  # Busy-safe live feed hygiene. The archive function is bridge-locked and keeps
  # agent context via summary.txt + hot tail, so this can run from the regular
  # driver tick instead of waiting for idle housekeeping.
  param(
    [int]$Keep = 200,
    [int]$DefaultThreshold = 1500,
    [double]$ThrottleHours = 6.0
  )

  if (-not (Get-Command Invoke-ConversationArchive -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ ok=$false; action='missing_archive_function'; lineCount=0; threshold=$DefaultThreshold; archived=0; kept=0 } }

  $threshold = [int]$DefaultThreshold
  try {
    $cfg = Get-BridgeConfig
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'conversationAutoArchiveLines') -and $null -ne $cfg.conversationAutoArchiveLines) {
      $candidate = [int]$cfg.conversationAutoArchiveLines
      if ($candidate -gt 0) { $threshold = $candidate }
    }
  } catch {}
  if ($threshold -lt $Keep) { $threshold = $Keep }
  if ($ThrottleHours -le 0) { $ThrottleHours = 6.0 }

  $convPath = ''
  try { $convPath = Get-ConversationPath } catch { return [pscustomobject]@{ ok=$false; action='no_conversation_path'; lineCount=0; threshold=$threshold; archived=0; kept=0 } }
  if ([string]::IsNullOrWhiteSpace($convPath) -or -not (Test-Path -LiteralPath $convPath)) {
    return [pscustomobject]@{ ok=$true; action='missing_feed'; lineCount=0; threshold=$threshold; archived=0; kept=0 }
  }

  $marker = Join-Path (Split-Path -Parent $convPath) 'conversation-auto-archive.last'
  if (Test-Path -LiteralPath $marker) {
    try {
      $last = [datetime]::Parse((Get-Content -LiteralPath $marker -Raw -Encoding UTF8).Trim(), $null, [Globalization.DateTimeStyles]::RoundtripKind)
      if (((Get-Date).ToUniversalTime() - $last.ToUniversalTime()).TotalHours -lt $ThrottleHours) {
        return [pscustomobject]@{ ok=$true; action='throttled'; lineCount=0; threshold=$threshold; archived=0; kept=0 }
      }
    } catch {}
  }

  $count = 0
  try {
    foreach ($line in [System.IO.File]::ReadLines($convPath, [System.Text.Encoding]::UTF8)) {
      if (-not [string]::IsNullOrWhiteSpace([string]$line)) { $count++ }
      if ($count -gt $threshold) { break }
    }
  } catch {
    return [pscustomobject]@{ ok=$false; action='count_failed'; lineCount=$count; threshold=$threshold; archived=0; kept=0 }
  }
  if ($count -le $threshold) {
    return [pscustomobject]@{ ok=$true; action='under_threshold'; lineCount=$count; threshold=$threshold; archived=0; kept=0 }
  }

  $result = $null
  try { $result = Invoke-ConversationArchive -Keep $Keep } catch { return [pscustomobject]@{ ok=$false; action='archive_failed'; lineCount=$count; threshold=$threshold; archived=0; kept=0 } }
  try { [System.IO.File]::WriteAllText($marker, (Get-Date).ToUniversalTime().ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}
  $archiveResult = $null
  try {
    $candidates = @($result | Where-Object {
      $_ -and ($_.PSObject.Properties.Name -contains 'archived') -and ($_.PSObject.Properties.Name -contains 'kept')
    })
    if ($candidates.Count -gt 0) { $archiveResult = $candidates[-1] }
  } catch {}
  if ($null -eq $archiveResult) { $archiveResult = $result }

  $archived = 0
  $kept = 0
  $ok = $true
  try {
    $archived = [int]$archiveResult.archived
    $kept = [int]$archiveResult.kept
    if ($archiveResult.PSObject.Properties.Name -contains 'ok') { $ok = [bool]$archiveResult.ok }
  } catch {
    return [pscustomobject]@{ ok=$false; action='archive_result_invalid'; lineCount=$count; threshold=$threshold; archived=0; kept=0; error=$_.Exception.Message }
  }
  if ($archived -gt 0) {
    $eventText = "🗄 Live feed auto-archive: moved " + $archived + " old messages; kept hot tail " + $kept + " (threshold " + $threshold + ")."
    $eventWritten = $false
    try {
      $beforeEventCount = @([System.IO.File]::ReadAllLines($convPath, [System.Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
      Add-Message -From system -Kind event -Text $eventText | Out-Null
      $afterEventCount = @([System.IO.File]::ReadAllLines($convPath, [System.Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
      $eventWritten = ($afterEventCount -gt $beforeEventCount)
    } catch {}
    if (-not $eventWritten) {
      try {
        $liveLines = @([System.IO.File]::ReadAllLines($convPath, [System.Text.Encoding]::UTF8) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $lastSeq = 0
        if ($liveLines.Count -gt 0) {
          try { $lastSeq = [int](($liveLines[-1] | ConvertFrom-Json).seq) } catch { $lastSeq = 0 }
        }
        $fallbackEvent = [ordered]@{
          seq  = ($lastSeq + 1)
          ts   = (Get-Date).ToUniversalTime().ToString('o')
          from = 'system'
          kind = 'event'
          text = $eventText
        }
        [System.IO.File]::AppendAllText($convPath, (($fallbackEvent | ConvertTo-Json -Compress -Depth 6) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
      } catch {}
    }
  }
  return [pscustomobject]@{ ok=$ok; action='archived'; lineCount=$count; threshold=$threshold; archived=$archived; kept=$kept }
}

function Get-AutonomyRequireApproval {
  try { return [bool](Get-AutonomySettings).requireApproval } catch { return $false }
}

function Get-LastUserActivityMinutes {
  # Minutes since the last write to conversation.jsonl (mtime = any bridge activity proxy).
  # Faster than parsing messages; captures user, agent, and system writes alike.
  # Fallback: driver start time from state.
  $ts = $null
  try {
    $p = Get-ConversationPath
    if (Test-Path -LiteralPath $p) { $ts = (Get-Item -LiteralPath $p).LastWriteTimeUtc }
  } catch {}
  if (-not $ts) { try { $ts = ([datetime](Read-State).driver_started).ToUniversalTime() } catch {} }
  if (-not $ts) { return 99999 }
  try { return ((Get-Date).ToUniversalTime() - $ts).TotalMinutes } catch { return 99999 }
}

# Detect-StudyMode now lives in lib/study.ps1 (loaded via common.ps1).
# It requires a BOUNDED study command-verb and accepts -IsAutonomous to skip
# backlog tasks. Defining it here would shadow the lib version -> do not re-add.
