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
  $backlogPath = Get-AuditBacklogPath -BridgePath $BridgePath -Channel $backlogChannel
  $backlogDir = Split-Path -Parent $backlogPath
  if (-not (Test-Path -LiteralPath $backlogDir)) {
    try { New-Item -ItemType Directory -Path $backlogDir -Force | Out-Null } catch {}
  }
  $existingTexts = @{}
  try {
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
    Write-AuditLog -BridgePath $BridgePath -Message "failed to read backlog for audit dedupe: $($_.Exception.Message)"
  }
  try {
    $addedInLock = Invoke-AuditBridgeLocked {
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
          # Bridge self-audit criticals auto-approve because the bridge may fix itself autonomously.
          # Project audits are written as held review items: the operator decides before the bridge
          # touches an external codebase.
          $rec = [ordered]@{
            id       = [guid]::NewGuid().ToString('N')
            ts       = (Get-Date).ToUniversalTime().ToString('o')
            from     = 'audit'
            status   = if ($isProjectAudit) { 'held' } else { 'approved' }
            tags     = if ($isProjectAudit) { @('audit', 'project-audit', $backlogChannel, [string]$f.source, 'critical') } else { @('audit', [string]$f.source, 'critical') }
            attempts = 0
            score    = 0.0
            project  = $backlogChannel
            scope    = $auditKind
            severity = 'critical'
            text     = $text
          }
          $line = ($rec | ConvertTo-Json -Compress -Depth 6)
          [System.IO.File]::AppendAllText($backlogPath, ($line + "`n"), (New-Object System.Text.UTF8Encoding($false)))
          $existingTexts[$text] = $true
          $localAdded++
        } catch {
          Write-AuditLog -BridgePath $BridgePath -Message "audit backlog append failed: $($_.Exception.Message)"
        }
      }
      return $localAdded
    }
    try { $added = [int]$addedInLock } catch { $added = 0 }
  } catch {
    Write-AuditLog -BridgePath $BridgePath -Message "failed to acquire backlog lock for audit findings: $($_.Exception.Message)"
  }
  return $added
}
