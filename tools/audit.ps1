# audit.ps1 -- main bridge audit orchestrator.
# Runs security + functional auditors back-to-back, merges findings into a single
# daily report (JSON + Markdown), and feeds critical issues into the backlog.
# Designed to be invoked from driver.ps1 as a detached Start-Job during idle windows.

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

function Get-AuditLockPath {
  param([string]$BridgePath)
  Join-Path (Get-AuditDir -BridgePath $BridgePath) '.audit.lock'
}

function Get-AuditLastMarker {
  param([string]$BridgePath)
  Join-Path (Get-AuditDir -BridgePath $BridgePath) 'audit.last'
}

function Write-AuditLog {
  param([string]$BridgePath, [string]$Message)
  try {
    $dir = Get-AuditDir -BridgePath $BridgePath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $log = Join-Path $dir 'audit.log'
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
  param([string]$BridgePath, [string]$ScriptName, [string]$EntryFunction)
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
    $raw = & $EntryFunction -BridgePath $BridgePath
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
  $title = ''
  $detail = ''
  $area = ''
  try {
    if ($Raw -is [string]) {
      $title = [string]$Raw
    } else {
      $rawSev = Get-AuditFindingField -Raw $Raw -Names @('severity','sev','level')
      if ($rawSev) { $sev = ([string]$rawSev).ToLowerInvariant() }

      $rawTitle = Get-AuditFindingField -Raw $Raw -Names @('title','name','summary','rule','category')
      if ($rawTitle) { $title = [string]$rawTitle }

      $rawDetail = Get-AuditFindingField -Raw $Raw -Names @('detail','message','description','msg')
      if ($rawDetail) { $detail = [string]$rawDetail }
      $rawRecommendation = Get-AuditFindingField -Raw $Raw -Names @('recommendation')
      if ($rawRecommendation) {
        if ($detail) { $detail += " Recommendation: $rawRecommendation" }
        else { $detail = [string]$rawRecommendation }
      }

      $rawArea = Get-AuditFindingField -Raw $Raw -Names @('area','path','file','target','component')
      if ($rawArea) { $area = [string]$rawArea }
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
  param([string]$BridgePath, $Report)
  $dir = Get-AuditDir -BridgePath $BridgePath
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $date = (Get-Date -Format 'yyyy-MM-dd')
  $jsonPath = Join-Path $dir "$date.json"
  $mdPath   = Join-Path $dir "$date.md"

  $json = $Report | ConvertTo-Json -Depth 8
  Write-AuditAtomicFile -Path $jsonPath -Content $json

  $sec = $Report.security_counts
  $fnc = $Report.functional_counts
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine("# Bridge Audit Report — $date")
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('## Summary')
  [void]$sb.AppendLine("- Security: $($sec.critical) critical, $($sec.warning) warning, $($sec.info) info")
  [void]$sb.AppendLine("- Functional: $($fnc.critical) critical, $($fnc.warning) warning, $($fnc.info) info")
  [void]$sb.AppendLine('')

  $all = @($Report.findings)
  $crit = @($all | Where-Object { $_.severity -eq 'critical' })
  $warn = @($all | Where-Object { $_.severity -eq 'warning' })
  $info = @($all | Where-Object { $_.severity -eq 'info' })

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
  [void]$sb.AppendLine("- Runtime: $($Report.runtime_sec)s")
  [void]$sb.AppendLine("- Generated: $($Report.generated_at)")
  if ($Report.errors -and @($Report.errors).Count -gt 0) {
    [void]$sb.AppendLine('- Errors:')
    foreach ($e in @($Report.errors)) { [void]$sb.AppendLine("  - $e") }
  }

  Write-AuditAtomicFile -Path $mdPath -Content $sb.ToString()
  return @{ json = $jsonPath; md = $mdPath }
}

function Add-AuditCriticalsToBacklog {
  param([string]$BridgePath, $Findings)
  $added = 0
  $crit = @($Findings | Where-Object { $_.severity -eq 'critical' })
  if ($crit.Count -eq 0) { return 0 }
  $lib = Join-Path $BridgePath 'lib\backlog.ps1'
  if (-not (Test-Path -LiteralPath $lib)) {
    Write-AuditLog -BridgePath $BridgePath -Message "lib/backlog.ps1 missing; cannot file critical findings"
    return 0
  }
  try {
    . $lib
    if (-not (Get-Command Add-Idea -ErrorAction SilentlyContinue)) {
      Write-AuditLog -BridgePath $BridgePath -Message 'Add-Idea not available after dot-source'
      return 0
    }
  } catch {
    Write-AuditLog -BridgePath $BridgePath -Message "failed to load backlog.ps1: $($_.Exception.Message)"
    return 0
  }
  foreach ($f in $crit) {
    try {
      $text = "[audit/$($f.source)] $($f.title)"
      if ($f.area)   { $text += " ($($f.area))" }
      if ($f.detail) {
        $det = ($f.detail -replace '\s+', ' ').Trim()
        if ($det.Length -gt 240) { $det = $det.Substring(0, 240) + '...' }
        $text += " — $det"
      }
      $id = Add-Idea -Text $text -From 'audit' -Tags @('audit', $f.source) -SkipCurator
      if ($id) { $added++ }
    } catch {
      Write-AuditLog -BridgePath $BridgePath -Message "Add-Idea failed: $($_.Exception.Message)"
    }
  }
  return $added
}

function Invoke-BridgeAudit {
  param([string]$BridgePath = $null)
  $root = Get-AuditBridgeRoot -Hint $BridgePath

  # 1. lock
  $existing = Test-AuditLock -BridgePath $root
  if ($existing) {
    Write-AuditLog -BridgePath $root -Message "audit already running under PID $existing; abort"
    return @{ status = 'locked'; pid = $existing }
  }
  New-AuditLock -BridgePath $root
  Write-AuditLog -BridgePath $root -Message "audit start (root=$root, pid=$PID)"

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $errors = New-Object 'System.Collections.Generic.List[string]'
  $allFindings = New-Object 'System.Collections.Generic.List[object]'
  $secFindings = @()
  $fncFindings = @()
  try {
    # 5. security audit
    $sec = Invoke-AuditSubcomponent -BridgePath $root -ScriptName 'audit-security.ps1' -EntryFunction 'Invoke-SecurityAudit'
    if ($sec.error) { [void]$errors.Add("security: $($sec.error)") }
    foreach ($f in @($sec.findings)) {
      $norm = Format-AuditFindings -Source 'security' -Raw $f
      $secFindings += ,$norm
      [void]$allFindings.Add($norm)
    }

    # 6. functional audit
    $fnc = Invoke-AuditSubcomponent -BridgePath $root -ScriptName 'audit-functional.ps1' -EntryFunction 'Invoke-FunctionalAudit'
    if ($fnc.error) { [void]$errors.Add("functional: $($fnc.error)") }
    foreach ($f in @($fnc.findings)) {
      $norm = Format-AuditFindings -Source 'functional' -Raw $f
      $fncFindings += ,$norm
      [void]$allFindings.Add($norm)
    }

    $secCounts = Get-AuditSeverityCounts -Findings $secFindings
    $fncCounts = Get-AuditSeverityCounts -Findings $fncFindings

    $sw.Stop()
    $report = [pscustomobject]@{
      generated_at      = (Get-Date).ToUniversalTime().ToString('o')
      bridge_root       = $root
      runtime_sec       = [math]::Round($sw.Elapsed.TotalSeconds, 2)
      security_counts   = $secCounts
      functional_counts = $fncCounts
      security_runtime_sec   = $sec.runtime_sec
      functional_runtime_sec = $fnc.runtime_sec
      findings          = @($allFindings.ToArray())
      errors            = @($errors.ToArray())
    }

    # 7-8. write reports
    $paths = Write-AuditReports -BridgePath $root -Report $report

    # 9. update audit.last
    try {
      $marker = Get-AuditLastMarker -BridgePath $root
      [System.IO.File]::WriteAllText($marker, (Get-Date).ToString('o'), (New-Object System.Text.UTF8Encoding($false)))
    } catch {}

    # 10. file critical findings into backlog
    $filed = 0
    if ($secCounts.critical -gt 0 -or $fncCounts.critical -gt 0) {
      $filed = Add-AuditCriticalsToBacklog -BridgePath $root -Findings $allFindings
    }

    Write-AuditLog -BridgePath $root -Message ("audit done in {0}s — sec[{1}c/{2}w/{3}i] fnc[{4}c/{5}w/{6}i] backlog+={7}" -f `
      $report.runtime_sec, $secCounts.critical, $secCounts.warning, $secCounts.info, `
      $fncCounts.critical, $fncCounts.warning, $fncCounts.info, $filed)

    return [pscustomobject]@{
      status            = 'ok'
      report_json       = $paths.json
      report_md         = $paths.md
      security_counts   = $secCounts
      functional_counts = $fncCounts
      backlog_added     = $filed
      runtime_sec       = $report.runtime_sec
      errors            = @($errors.ToArray())
    }
  } finally {
    Remove-AuditLock -BridgePath $root
  }
}

function Wait-BridgeIdle {
  # Polls state.json until idle (no agent_pid, no active_jobs, status=='idle'). Returns
  # $true on idle, $false on timeout. Designed to be called inside a Start-Job from
  # driver.ps1 so a long wait doesn't block the main loop.
  param(
    [string]$StateFile,
    [int]$MaxMinutes = 60,
    [int]$PollSeconds = 30
  )
  if ([string]::IsNullOrWhiteSpace($StateFile)) { return $false }
  $deadline = (Get-Date).AddMinutes($MaxMinutes)
  while ((Get-Date) -lt $deadline) {
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
          if ($status -eq 'idle' -and $agentPid -eq 0 -and $activeCount -eq 0) { return $true }
        }
      }
    } catch {}
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
