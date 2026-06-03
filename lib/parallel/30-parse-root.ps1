function Get-ParallelRoot {
  Join-Path (Get-BridgeRoot) 'worktrees\parallel'
}

function Get-ParallelJobsDir {
  $dir = Join-Path (Get-BridgeRoot) 'jobs\parallel'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return $dir
}

function Normalize-ParallelId {
  param([string]$Value)
  $safe = ([string]$Value).Trim() -replace '[^A-Za-z0-9_.-]+','-'
  if ([string]::IsNullOrWhiteSpace($safe)) { $safe = [guid]::NewGuid().ToString('N').Substring(0,8) }
  return $safe
}

function Normalize-ParallelFilePath {
  param([string]$Path)
  $p = ([string]$Path).Trim()
  $p = $p.Trim(" `t`r`n""'`.,;")
  if ($p.StartsWith('./') -or $p.StartsWith('.\')) { $p = $p.Substring(2) }
  $p = $p -replace '\\','/'
  while ($p.StartsWith('/')) { $p = $p.Substring(1) }
  return $p.ToLowerInvariant()
}

function Split-ParallelFileList {
  param([string]$Text)
  $items = New-Object System.Collections.Generic.List[string]
  $raw = ([string]$Text).Trim()
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  $raw = $raw -replace '\[\[/?FILES?\]\]',''
  foreach ($part in ($raw -split '[,;]')) {
    $p = ([string]$part).Trim()
    $p = $p -replace '^\s*[-*]\s+',''
    $p = $p.Trim(" `t`r`n""'`.,;")
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if ($p -match '\s+#') { $p = ($p -split '\s+#',2)[0].Trim() }
    $n = Normalize-ParallelFilePath $p
    if (-not [string]::IsNullOrWhiteSpace($n)) { [void]$items.Add($n) }
  }
  return @($items.ToArray() | Sort-Object -Unique)
}

function Get-ParallelFilesFromBody {
  param([string]$Body)
  $files = New-Object System.Collections.Generic.List[string]
  $text = [string]$Body

  foreach ($m in [regex]::Matches($text, '\[\[FILES?:(?<files>[^\]]+)\]\]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    foreach ($f in (Split-ParallelFileList $m.Groups['files'].Value)) { [void]$files.Add($f) }
  }

  $lines = $text -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $line = [string]$lines[$i]
    $m = [regex]::Match($line, '^\s*(?:files?|touches|allowed\s+files|файлы)\s*:\s*(?<files>.*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { continue }
    $tail = ([string]$m.Groups['files'].Value).Trim()
    if (-not [string]::IsNullOrWhiteSpace($tail)) {
      foreach ($f in (Split-ParallelFileList $tail)) { [void]$files.Add($f) }
      continue
    }
    $j = $i + 1
    while ($j -lt $lines.Count) {
      $next = [string]$lines[$j]
      if ([string]::IsNullOrWhiteSpace($next)) { break }
      if ($next -match '^\s*(?:complexity|сложность|body|task|задача)\s*:') { break }
      if ($next -match '^\s*[-*]\s+(?<file>.+)$') {
        foreach ($f in (Split-ParallelFileList $Matches['file'])) { [void]$files.Add($f) }
      } else {
        break
      }
      $j++
    }
  }

  return @($files.ToArray() | Sort-Object -Unique)
}

function Get-ParallelComplexityFromBody {
  # Accepts: simple, moderate, complex, architectural (English) or
  #          простая, умеренная, сложная, архитектурная (Russian, mapped).
  # Default 'moderate' if not specified.
  param([string]$Body)
  $m = [regex]::Match([string]$Body, '^\s*(?:complexity|сложность)\s*:\s*(?<c>simple|moderate|complex|architectural|простая|умеренная|сложная|архитектурная)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)
  if (-not $m.Success) { return 'moderate' }
  $c = $m.Groups['c'].Value.ToLowerInvariant()
  switch ($c) {
    'простая'       { return 'simple' }
    'умеренная'     { return 'moderate' }
    'сложная'       { return 'complex' }
    'архитектурная' { return 'architectural' }
    default         { return $c }
  }
}

function Test-CanParallelize {
  param([string]$PlanText)
  if ([string]::IsNullOrWhiteSpace($PlanText)) { return $null }

  $matches = [regex]::Matches(
    [string]$PlanText,
    '\[\[PARALLEL:(?<id>[A-Za-z0-9_.-]+)\]\](?<body>.*?)\[\[/PARALLEL:\k<id>\]\]',
    [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if ($matches.Count -lt 2) { return $null }

  $streams = New-Object System.Collections.Generic.List[object]
  $owners = @{}
  foreach ($m in $matches) {
    $id = Normalize-ParallelId $m.Groups['id'].Value
    $body = ([string]$m.Groups['body'].Value).Trim()
    $files = @(Get-ParallelFilesFromBody $body)
    if ($files.Count -eq 0) { return $null }

    foreach ($f in $files) {
      if ($owners.ContainsKey($f) -and [string]$owners[$f] -ne $id) { return $null }
      $owners[$f] = $id
    }

    [void]$streams.Add([pscustomobject]@{
      id         = $id
      files      = @($files)
      complexity = Get-ParallelComplexityFromBody $body
      opus       = ([string]$body -match '\[\[OPUS\]\]')
      body       = $body
    })
  }

  if ($streams.Count -lt 2) { return $null }
  return @($streams.ToArray())
}

function Get-ParallelRepoRoot {
  # 2026-05-31 (Foundation #4 scale): the git repo a parallel worker's worktree branches from.
  # PROJECT channel -> its project_root (isolated git) => safe high-fan-out parallelism with no
  # cross-worker conflicts. main/bridge channel -> the bridge root (unchanged behaviour).
  try {
    if (Get-Command Get-EffectiveProjectRoot -ErrorAction SilentlyContinue) {
      $pr = Get-EffectiveProjectRoot
      if (-not [string]::IsNullOrWhiteSpace([string]$pr) -and (Test-Path (Join-Path ([string]$pr) '.git'))) { return [string]$pr }
    }
  } catch {}
  return (Get-BridgeRoot)
}

function Get-ParallelTaskBaseCommit {
  $ErrorActionPreference = 'Continue'
  $base = ''
  try {
    $st = Read-State
    if ($st -and ($st.PSObject.Properties.Name -contains 'task_base_commit')) { $base = [string]$st.task_base_commit }
  } catch {}
  $repoRoot = Get-ParallelRepoRoot
  # 2026-06-01 (Foundation #4): the base commit MUST exist in the repo the worktree branches from.
  # For a PROJECT channel that's project_root, but task_base_commit was set to the BRIDGE HEAD ->
  # 'git worktree add <path> <bridge-sha>' fails ("invalid reference"), which killed EVERY parallel
  # run and forced serial fallback (worktrees=0). Drop a base that doesn't exist in this repo and
  # fall back to its real HEAD.
  if (-not [string]::IsNullOrWhiteSpace($base)) {
    $baseOk = $false
    try { $baseOk = ((& git -C $repoRoot cat-file -t $base 2>$null) -match 'commit') } catch {}
    if (-not $baseOk) { $base = '' }
  }
  if ([string]::IsNullOrWhiteSpace($base)) {
    try { $base = ((& git -C $repoRoot rev-parse HEAD 2>$null) | Select-Object -First 1) } catch {}
  }
  return ([string]$base).Trim()
}
