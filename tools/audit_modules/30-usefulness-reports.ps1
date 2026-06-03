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
