function Build-Prompt {
  param([string]$Role, [string]$Task, [string]$Mode = 'normal', [switch]$FastLane)
  Invoke-PromptBuilder -Role $Role -Task $Task -Mode $Mode -FastLane:$FastLane
}
function Set-AgentPid([int]$ProcId) { Update-State ({ param($s) $s.agent_pid = $ProcId }.GetNewClosure()) | Out-Null }
function Clear-AgentPid { Update-State { param($s) $s.agent_pid = $null } | Out-Null }

$agentPidsFile = Join-Path $bridgeRoot 'runtime\agent_pids.txt'

function Stop-AgentTree {
  param([int]$ProcId)
  if ($ProcId -le 0) { return }
  try { & taskkill /PID $ProcId /T /F 2>$null | Out-Null } catch {}
}

function Register-AgentPid {
  param([int]$ProcId)
  if ($ProcId -le 0) { return }
  try {
    $dir = Split-Path -Parent $agentPidsFile
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # Record PID + start-time + name. Start-time makes the record uniquely identify THIS
    # process, so a later-recycled PID (e.g. the user's app) can never be mistaken for ours.
    $ticks = 0; $name = ''
    try { $pp = Get-Process -Id $ProcId -ErrorAction SilentlyContinue; if ($pp) { $ticks = $pp.StartTime.Ticks; $name = $pp.ProcessName } } catch {}
    Add-Content -LiteralPath $agentPidsFile -Value ("$ProcId|$ticks|$name") -Encoding UTF8
  } catch {}
}

function Unregister-AgentPid {
  param([int]$ProcId)
  if ($ProcId -le 0) { return }
  try {
    if (-not (Test-Path $agentPidsFile)) { return }
    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Get-Content $agentPidsFile -Encoding UTF8)) {
      $trimmed = ([string]$line).Trim()
      if (-not $trimmed) { continue }
      $linePid = ($trimmed -split '\|')[0]
      if ($linePid -notmatch '^\d+$') { continue }
      if ([int]$linePid -ne $ProcId) { [void]$kept.Add($trimmed) }
    }
    [System.IO.File]::WriteAllLines($agentPidsFile, $kept.ToArray(), $Utf8NoBom)
  } catch {}
}

function Sweep-AgentOrphans {
  # Kill ONLY processes this bridge spawned, verified by PID **and** start-time. A recycled
  # PID now owned by another app (e.g. the user's Codex) has a different start-time -> skipped.
  # Records without a verified start-time are NEVER killed (fail-safe). Format: PID|ticks|name.
  param()
  if (-not (Test-Path $agentPidsFile)) { return }
  try {
    $seen = @{}
    foreach ($line in (Get-Content $agentPidsFile -Encoding UTF8)) {
      $trimmed = ([string]$line).Trim()
      if (-not $trimmed) { continue }
      $parts = $trimmed -split '\|'
      if ($parts[0] -notmatch '^\d+$') { continue }
      $orphanPid = [int]$parts[0]
      $ticks = 0; if ($parts.Count -ge 2 -and $parts[1] -match '^\d+$') { $ticks = [long]$parts[1] }
      if ($orphanPid -eq $PID -or $seen.ContainsKey($orphanPid)) { continue }
      $seen[$orphanPid] = $true
      if ($ticks -le 0) { continue }   # no verified start-time -> DO NOT kill (safety)
      try {
        $proc = Get-Process -Id $orphanPid -ErrorAction SilentlyContinue
        if ($proc -and $proc.StartTime.Ticks -eq $ticks) {
          Write-Host "Sweep: убиваю свой орфан PID $orphanPid ($($proc.ProcessName))"
          Stop-AgentTree $orphanPid
        }
      } catch {}
    }
  } catch {}
  try { [System.IO.File]::WriteAllText($agentPidsFile, '', $Utf8NoBom) } catch {}
}

function Get-OtherChannelsAgents { Get-OtherChannelsAgentsImpl }
function Set-CurrentAgent {
  param([string]$Agent)
  Set-CurrentAgentImpl -Agent $Agent
}

function Test-DirectCoderTask {
  # 2026-06-01 ROOT FIX (efficiency, re-applied after a watchdog "moving to stable" rollback dropped
  # the first copy): a SINGLE explicit file edit ("Перепиши/Создай <file>") does NOT need the claude
  # planner stage — the planner just burns the 150s zero-output grace before falling back to codex
  # anyway. Route such tasks straight to the codex coder. Planner stays for multi-file / architectural
  # / discussion tasks where a coordinating plan genuinely matters. Universal: any channel, any task.
  param([string]$TaskText)
  if ([string]::IsNullOrWhiteSpace($TaskText)) { return $false }
  $tgt = ''
  try { if (Get-Command Get-BacklogTaskTargetFile -ErrorAction SilentlyContinue) { $tgt = [string](Get-BacklogTaskTargetFile -Text $TaskText) } } catch {}
  if ([string]::IsNullOrWhiteSpace($tgt)) { return $false }
  if ($TaskText -match '(?i)обсуди|спроектируй|архитектур|схему\s+(бд|баз)|миграци|несколько\s+файл|по\s+шагам|и\s+зат[ае]м|разбери|исследуй|многофайл|design\s+system|migration') { return $false }
  return $true
}
