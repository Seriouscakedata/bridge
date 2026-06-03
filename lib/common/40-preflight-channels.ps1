function Get-PreflightBlockers {
  param([string]$Channel = '', [string]$ProjectRoot = '')

  $hard = New-Object 'System.Collections.Generic.List[string]'
  $soft = New-Object 'System.Collections.Generic.List[string]'
  $root = Get-BridgeRoot

  if ([string]::IsNullOrWhiteSpace($Channel)) {
    try {
      if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { $Channel = [string](Get-EffectiveChannel) }
    } catch {
      [void]$soft.Add("не удалось определить текущий канал: $($_.Exception.Message)")
    }
  }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = 'main' }
  $channelSlug = $Channel
  try {
    if (Get-Command Normalize-ChannelSlug -ErrorAction SilentlyContinue) { $channelSlug = Normalize-ChannelSlug $Channel }
  } catch {}

  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    try {
      if (Get-Command Get-ChannelProjectBinding -ErrorAction SilentlyContinue) {
        $binding = Get-ChannelProjectBinding -Slug $channelSlug
        if ($binding -and [bool]$binding.ok) {
          $ProjectRoot = [string]$binding.project_root
        } elseif ($channelSlug -ne 'main') {
          $berr = if ($binding) { [string]$binding.error } else { "Канал '$channelSlug' не привязан к проекту" }
          if ([string]::IsNullOrWhiteSpace($berr)) { $berr = "Канал '$channelSlug' не привязан к проекту" }
          [void]$hard.Add($berr)
        }
      } elseif (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) {
        $ProjectRoot = [string](Get-EffectiveProjectRoot -Slug $channelSlug)
      }
    } catch {
      [void]$soft.Add("не удалось определить проект канала '$channelSlug': $($_.Exception.Message)")
    }
  }
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = $root }

  $channelState = $null
  try {
    if (Get-Command Get-ChannelStatePath -ErrorAction SilentlyContinue) {
      $statePath = Get-ChannelStatePath -Slug $Channel
      if (Test-Path -LiteralPath $statePath) {
        $channelState = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
      }
    }
    if ($null -eq $channelState) { $channelState = Read-State }
  } catch {
    [void]$soft.Add("не удалось прочитать state канала '$Channel': $($_.Exception.Message)")
  }

  # Codex MSIX supports one exec session per machine. Treat only a live, verified lock as hard.
  $lockPath = Join-Path $root 'runtime\codex.lock'
  if (Test-Path -LiteralPath $lockPath) {
    try {
      $raw = ([string](Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 -ErrorAction Stop)).Trim()
      $parts = @($raw -split '\|')
      $lockPid = 0
      $lockTicks = [long]0
      if ($parts.Count -ge 1) { [int]::TryParse($parts[0], [ref]$lockPid) | Out-Null }
      if ($parts.Count -ge 2) { [long]::TryParse($parts[1], [ref]$lockTicks) | Out-Null }

      if ($lockPid -gt 0) {
        $proc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
        if ($proc) {
          $sameProcess = $true
          if ($lockTicks -gt 0) {
            try {
              $sameProcess = ($proc.StartTime.Ticks -eq $lockTicks)
            } catch {
              $sameProcess = $false
              [void]$soft.Add("codex.lock PID $lockPid найден, но start-time не проверен: $($_.Exception.Message)")
            }
          }
          if ($sameProcess) {
            $lockAgeSec = 0
            try { $lockAgeSec = [math]::Max(0, [int](((Get-Date) - (Get-Item -LiteralPath $lockPath).LastWriteTime).TotalSeconds)) } catch { $lockAgeSec = 0 }
            if ($lockAgeSec -le 920) {
              $sameChannelActiveCodex = $false
              try {
                if ($channelState -and ([string]$channelState.current_agent).ToLowerInvariant() -eq 'codex' -and [int]$channelState.current_agent_pid -eq $lockPid) {
                  $sameChannelActiveCodex = $true
                }
              } catch {
                [void]$soft.Add("не удалось сверить codex.lock с current_agent канала '$Channel': $($_.Exception.Message)")
              }
              if (-not $sameChannelActiveCodex) {
                [void]$hard.Add("codex.lock активен (PID $lockPid) - другая coder-сессия в работе")
              }
            } else {
              [void]$soft.Add("codex.lock выглядит устаревшим (PID $lockPid, age ${lockAgeSec}s)")
            }
          } else {
            [void]$soft.Add("codex.lock выглядит устаревшим (PID $lockPid не совпал по start-time)")
          }
        } else {
          [void]$soft.Add("codex.lock выглядит устаревшим (PID $lockPid не найден)")
        }
      } elseif (-not [string]::IsNullOrWhiteSpace($raw)) {
        [void]$soft.Add("codex.lock имеет неожиданный формат")
      }
    } catch {
      [void]$soft.Add("не удалось проверить codex.lock: $($_.Exception.Message)")
    }
  }

  try {
    $st = $channelState
    if ($st -and [bool]$st.doctor_active) {
      $curTask = [string]$st.current_task
      $isDoctorTask = ($curTask -match '^\s*🩺\s*ДОКТОР' -or $curTask -match 'ДОКТОР\s+.\s+задача саморемонта моста')
      if (-not $isDoctorTask) {
        [void]$hard.Add("Doctor активен на канале '$Channel'")
      }
    }
  } catch {
    [void]$soft.Add("не удалось проверить Doctor на канале '$Channel': $($_.Exception.Message)")
  }

  $gitDir = Join-Path $ProjectRoot '.git'
  try {
    $gitDirRaw = @(& git -C $ProjectRoot rev-parse --git-dir 2>$null | Select-Object -First 1)
    if ($gitDirRaw -and -not [string]::IsNullOrWhiteSpace([string]$gitDirRaw[0])) {
      $gd = [string]$gitDirRaw[0]
      if ([System.IO.Path]::IsPathRooted($gd)) { $gitDir = $gd } else { $gitDir = Join-Path $ProjectRoot $gd }
    }
  } catch {
    [void]$soft.Add("не удалось определить .git каталог: $($_.Exception.Message)")
  }

  foreach ($m in @('MERGE_HEAD','CHERRY_PICK_HEAD','REBASE_HEAD','index.lock')) {
    if (Test-Path -LiteralPath (Join-Path $gitDir $m)) { [void]$hard.Add("git mid-op: .git/$m") }
  }
  foreach ($d in @('rebase-merge','rebase-apply')) {
    if (Test-Path -LiteralPath (Join-Path $gitDir $d) -PathType Container) { [void]$hard.Add("git mid-op: .git/$d/") }
  }

  try {
    $dirty = @(& git -C $ProjectRoot status --porcelain 2>$null)
    $dirtyCount = @($dirty | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count
    if ($dirtyCount -gt 0) { [void]$soft.Add("worktree dirty: $dirtyCount изменённых/untracked файлов") }
  } catch {
    [void]$soft.Add("не удалось проверить git status: $($_.Exception.Message)")
  }

  return [pscustomobject]@{
    Hard = @($hard.ToArray())
    Soft = @($soft.ToArray())
  }
}

function Is-TestChannel {
  param([Parameter(Mandatory)][string]$Name)
  if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
  if ($Name -match '[\\/]') { return $false }
  return ($Name -match '^(smoke|test)[-_]')
}

function Get-TestChannelDriverProcessIds {
  param([Parameter(Mandatory)][string]$Name)

  $ids = New-Object 'System.Collections.Generic.List[int]'
  if (-not (Is-TestChannel -Name $Name)) { return @() }
  $pattern = "(?i)(^|\s)-Channel\s+[`"']?" + [regex]::Escape($Name) + "[`"']?(\s|$)"
  try {
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
      $cmd = [string]$p.CommandLine
      if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
      if ($cmd -notmatch '\\driver\.ps1\b') { continue }
      if ($cmd -match $pattern) { [void]$ids.Add([int]$p.ProcessId) }
    }
  } catch {}
  return @($ids.ToArray())
}

function Set-TestChannelArchivedFlag {
  param([Parameter(Mandatory)][string]$Name)

  if (-not (Is-TestChannel -Name $Name)) { return $false }
  $cfgPath = Join-Path (Join-Path (Join-Path (Get-BridgeRoot) 'channels') $Name) 'channel.json'
  try {
    if (Test-Path -LiteralPath $cfgPath) {
      $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } else {
      $cfg = [pscustomobject]@{ slug=$Name; name=$Name }
    }
    $cfg | Add-Member -NotePropertyName archived -NotePropertyValue $true -Force
    $cfg | Add-Member -NotePropertyName archived_at -NotePropertyValue ((Get-Date).ToString('o')) -Force
    [System.IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
    return $true
  } catch {
    return $false
  }
}

function Archive-TestChannelIfIdle {
  param(
    [Parameter(Mandatory)][string]$Name,
    [int]$GraceMinutes = 10
  )

  if (-not (Is-TestChannel -Name $Name)) { return $null }
  if ($Name -ne [System.IO.Path]::GetFileName($Name)) { return $null }
  if ($GraceMinutes -lt 0) { $GraceMinutes = 0 }

  $root = Get-BridgeRoot
  $chRoot = Join-Path $root 'channels'
  $chDir = Join-Path $chRoot $Name
  if (-not (Test-Path -LiteralPath $chDir -PathType Container)) { return $null }

  $current = ''
  try {
    if (Get-Command Get-EffectiveChannel -ErrorAction SilentlyContinue) { $current = [string](Get-EffectiveChannel) }
  } catch {}
  if (-not [string]::IsNullOrWhiteSpace($current) -and $current -eq $Name) { return $null }
  try {
    $active = [string](Get-ActiveChannel)
    if (-not [string]::IsNullOrWhiteSpace($active) -and $active -eq $Name) { return $null }
  } catch {}

  $locks = @(Get-ChildItem -LiteralPath $chDir -Filter '*.lock' -File -ErrorAction SilentlyContinue)
  if ($locks.Count -gt 0) { return $null }

  $statePath = Join-Path $chDir 'state.json'
  if (Test-Path -LiteralPath $statePath) {
    try {
      $st = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
      $status = ([string]$st.status).ToLowerInvariant()
      if (-not [string]::IsNullOrWhiteSpace($status) -and $status -notin @('idle','done')) { return $null }
      if (-not [string]::IsNullOrWhiteSpace([string]$st.current_task)) { return $null }
      if (-not [string]::IsNullOrWhiteSpace([string]$st.active_agent)) { return $null }
      if (-not [string]::IsNullOrWhiteSpace([string]$st.current_agent)) { return $null }
      if ([bool]$st.doctor_active) { return $null }
      if ($st.active_jobs -and @($st.active_jobs).Count -gt 0) { return $null }
      if ($st.PSObject.Properties.Name -contains 'task_id') {
        if (-not [string]::IsNullOrWhiteSpace([string]$st.task_id) -and -not [bool]$st.task_archived) { return $null }
      }
    } catch {
      return [pscustomobject]@{ Name=$Name; Archived=$null; Error=("state read failed: " + $_.Exception.Message) }
    }
  }

  $lastTouch = (Get-Date).AddYears(-1)
  $sawActivityFile = $false
  foreach ($f in @('conversation.jsonl','turns.jsonl','channel.json','plan.jsonl','backlog.jsonl')) {
    $fp = Join-Path $chDir $f
    if (Test-Path -LiteralPath $fp) {
      $mt = (Get-Item -LiteralPath $fp).LastWriteTime
      $sawActivityFile = $true
      if ($mt -gt $lastTouch) { $lastTouch = $mt }
    }
  }
  if (-not $sawActivityFile) { $lastTouch = (Get-Item -LiteralPath $chDir).LastWriteTime }
  $ageMin = ((Get-Date) - $lastTouch).TotalMinutes
  if ($ageMin -lt $GraceMinutes) { return $null }

  $driverPids = @(Get-TestChannelDriverProcessIds -Name $Name)
  if ($driverPids.Count -gt 0) {
    if (Set-TestChannelArchivedFlag -Name $Name) {
      return [pscustomobject]@{ Name=$Name; Archived=$null; PendingStop=$true; DriverPids=$driverPids; AgeMinutes=[int]$ageMin }
    }
    return [pscustomobject]@{ Name=$Name; Archived=$null; Error='failed to mark channel archived before driver stop' }
  }

  $archRoot = Join-Path $chRoot '_archive'
  if (-not (Test-Path -LiteralPath $archRoot)) { New-Item -ItemType Directory -Path $archRoot -Force | Out-Null }
  $stamp = (Get-Date).ToString('yyyy-MM-dd_HHmmss')
  $dest = Join-Path $archRoot ($stamp + '_' + $Name)
  $n = 1
  while (Test-Path -LiteralPath $dest) {
    $dest = Join-Path $archRoot ($stamp + '_' + $Name + '_' + $n)
    $n++
  }

  try {
    Move-Item -LiteralPath $chDir -Destination $dest -ErrorAction Stop
    try {
      $purged = Purge-MemoryForChannel -Slug $Name
      if ($purged -gt 0) {
        try { Add-Message -From system -Kind event -Text ("Auto-purge: удалено " + $purged + " memory-записей архивированного канала " + $Name) | Out-Null } catch {}
      }
    } catch {}
    return [pscustomobject]@{ Name=$Name; Archived=$dest; AgeMinutes=[int]$ageMin }
  } catch {
    return [pscustomobject]@{ Name=$Name; Archived=$null; Error=$_.Exception.Message }
  }
}

function Invoke-TestChannelCleanup {
  param([int]$GraceMinutes = 10)

  $root = Get-BridgeRoot
  $chRoot = Join-Path $root 'channels'
  if (-not (Test-Path -LiteralPath $chRoot -PathType Container)) { return @() }

  $results = New-Object 'System.Collections.Generic.List[object]'
  foreach ($ch in @(Get-ChildItem -LiteralPath $chRoot -Directory -ErrorAction SilentlyContinue)) {
    if ($ch.Name -eq '_archive') { continue }
    if (-not (Is-TestChannel -Name $ch.Name)) { continue }
    $r = Archive-TestChannelIfIdle -Name $ch.Name -GraceMinutes $GraceMinutes
    if ($r -and ($r.Archived -or $r.PendingStop)) {
      try {
        if ($r.PendingStop) {
          Add-Message -From system -Kind event -Text ("test_channel_archive_pending: " + $r.Name + " marked archived; waiting for driver stop (pid " + ((@($r.DriverPids) | ForEach-Object { [string]$_ }) -join ',') + ", age " + $r.AgeMinutes + " min)") | Out-Null
        } else {
          Add-Message -From system -Kind event -Text ("test_channel_archived: " + $r.Name + " -> " + $r.Archived + " (age " + $r.AgeMinutes + " min)") | Out-Null
        }
      } catch {}
      [void]$results.Add($r)
    }
  }
  return @($results.ToArray())
}

