# backlog.ps1 -- the bridge's self-improvement backlog (ideas/observations the agents
# raise themselves). Dot-sourced from common.ps1. Stored in backlog.jsonl at the root.
# Statuses: new (proposed) -> approved (user OK'd, eligible to auto-run) -> running -> done
#           also: rejected, failed.

function Get-BacklogPath { Join-Path (Get-BridgeRoot) 'backlog.jsonl' }

function Add-Idea {
  # Append a backlog idea. Returns the new id.
  param([string]$Text, [string]$From = 'agent', [string[]]$Tags = @(), [string]$Status = 'new')
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $rec = [ordered]@{
    id       = [guid]::NewGuid().ToString('N')
    ts       = (Get-Date).ToUniversalTime().ToString('o')
    from     = $From
    status   = $Status
    tags     = @($Tags)
    attempts = 0
    text     = [string]$Text
  }
  $line = ($rec | ConvertTo-Json -Compress -Depth 6)
  Use-BridgeLock ({ Add-Content -LiteralPath (Get-BacklogPath) -Value $line -Encoding UTF8 }.GetNewClosure())
  return $rec.id
}

function Get-Backlog {
  $p = Get-BacklogPath
  if (-not (Test-Path $p)) { return @() }
  $out = New-Object 'System.Collections.Generic.List[object]'
  foreach ($line in (Get-Content -LiteralPath $p -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $i = $line | ConvertFrom-Json } catch { continue }
    [void]$out.Add($i)
  }
  return @($out.ToArray())
}

function Save-Backlog {
  param($Items)
  $lines = @($Items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 })
  $content = if ($lines.Count) { ($lines -join "`n") + "`n" } else { '' }
  Use-BridgeLock ({ Write-AtomicFile -Path (Get-BacklogPath) -Content $content }.GetNewClosure())
}

function Set-Idea {
  # Edit a backlog item. Pass $null to leave a field unchanged.
  param([string]$Id, $Status = $null, $Text = $null, $IncrementAttempts = $false)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $items = @(Get-Backlog)
  $found = $false
  foreach ($i in $items) {
    if ([string]$i.id -ne $Id) { continue }
    $found = $true
    if ($null -ne $Status) { $i | Add-Member -NotePropertyName status -NotePropertyValue ([string]$Status) -Force }
    if ($null -ne $Text -and -not [string]::IsNullOrWhiteSpace([string]$Text)) { $i | Add-Member -NotePropertyName text -NotePropertyValue ([string]$Text) -Force }
    if ($IncrementAttempts) {
      $a = 0; try { $a = [int]$i.attempts } catch {}
      $i | Add-Member -NotePropertyName attempts -NotePropertyValue ($a + 1) -Force
    }
    break
  }
  if (-not $found) { return $false }
  Save-Backlog $items
  return $true
}

function Remove-Idea {
  param([string]$Id)
  if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
  $items = @(Get-Backlog)
  $kept = @($items | Where-Object { [string]$_.id -ne $Id })
  if ($kept.Count -eq $items.Count) { return $false }
  Save-Backlog $kept
  return $true
}

function Get-NextApprovedIdea {
  # Oldest approved item, for autonomous execution.
  $items = @(Get-Backlog | Where-Object { [string]$_.status -eq 'approved' } | Sort-Object { [string]$_.ts })
  if ($items.Count -gt 0) { return $items[0] }
  return $null
}

function Get-NextRunnableIdea {
  # Next idea to auto-run. With -IncludeNew (autonomy without manual approval) 'new'
  # items are also runnable; 'approved' always takes priority, then oldest-first.
  param([bool]$IncludeNew = $false)
  $statuses = if ($IncludeNew) { @('approved','new') } else { @('approved') }
  $items = @(Get-Backlog | Where-Object { $statuses -contains [string]$_.status } |
    Sort-Object @{Expression={ if ([string]$_.status -eq 'approved') {0} else {1} }}, @{Expression={[string]$_.ts}})
  if ($items.Count -gt 0) { return $items[0] }
  return $null
}

function Get-IdeaById {
  param([string]$Id)
  foreach ($i in @(Get-Backlog)) { if ([string]$i.id -eq $Id) { return $i } }
  return $null
}
