function Start-ReplayForStateTask {
  param(
    [object]$State,
    [string]$TaskText,
    [string]$ChannelName
  )
  if ($null -eq $State -or [string]::IsNullOrWhiteSpace($TaskText)) { return }
  try {
    $hash = Get-ReplayTaskHash -TaskText $TaskText
    $taskId = [string]$State.current_task_id
    if ([string]::IsNullOrWhiteSpace($taskId) -or -not $taskId.EndsWith("-$hash")) {
      $taskId = New-ReplayTaskId -TaskText $TaskText
      $State | Add-Member -NotePropertyName current_task_id -NotePropertyValue $taskId -Force
      Save-ReplayTaskMeta -TaskId $taskId -Meta @{
        task_text      = $TaskText
        started_at     = (Get-Date).ToString('o')
        finished_at    = $null
        status         = 'in_progress'
        channel        = $ChannelName
        turn_count     = 0
        total_cost_usd = 0
      }
      return
    }
    $State | Add-Member -NotePropertyName current_task_id -NotePropertyValue $taskId -Force
    $turnCount = 0
    try { $turnCount = [int]$State.task_turn } catch {}
    Save-ReplayTaskMeta -TaskId $taskId -Meta @{
      task_text  = $TaskText
      status     = 'in_progress'
      channel    = $ChannelName
      turn_count = $turnCount
    }
  } catch {
    try { Write-ReplayInternalError ("Start-ReplayForStateTask: " + $_.Exception.Message) } catch {}
  }
}

function Close-ReplayForStateTask {
  param(
    [object]$State,
    [string]$Status = 'done'
  )
  if ($null -eq $State) { return }
  try {
    $taskId = [string]$State.current_task_id
    if (-not [string]::IsNullOrWhiteSpace($taskId)) {
      $turnCount = 0
      try { $turnCount = [int]$State.task_turn } catch {}
      Save-ReplayTaskMeta -TaskId $taskId -Meta @{
        finished_at = (Get-Date).ToString('o')
        status      = $Status
        turn_count  = $turnCount
      }
    }
  } catch {
    try { Write-ReplayInternalError ("Close-ReplayForStateTask: " + $_.Exception.Message) } catch {}
  } finally {
    try { $State | Add-Member -NotePropertyName current_task_id -NotePropertyValue $null -Force } catch {}
  }
}

function Test-DriverCoordinatorTaskText {
  # 2026-07-02 planner-speed: pure shape-check for a project-autopilot coordinator task text
  # (same shape lib/backlog-autopilot.ps1 Test-ProjectAutopilotCoordinatorText matches; duplicated
  # here so driver routing has no lib load-order dependency). Used for explicit deep-model routing
  # and the coordinator effort override -- unit-tested in tools\test-coordinator-routing.ps1.
  param([AllowNull()][string]$TaskText)
  $t = [string]$TaskText
  if ([string]::IsNullOrWhiteSpace($t)) { return $false }
  if ($t -notmatch '\[project-autopilot\s+[^\]]+\]') { return $false }
  if ($t -notmatch 'Project Autopilot coordinator for channel') { return $false }
  return $true
}

function Get-PlannerModel {
  param([string]$TaskText, [string]$Mode)

  $cfgR = $null
  try { $cfgR = Get-BridgeConfig } catch {}
  $pr = $null
  if ($cfgR -and ($cfgR.PSObject.Properties.Name -contains 'plannerRouting')) { $pr = $cfgR.plannerRouting }
  $opusOnLong = if ($pr -and ($pr.PSObject.Properties.Name -contains 'opusOnLongPrompts') -and $null -ne $pr.opusOnLongPrompts) { [bool]$pr.opusOnLongPrompts } else { $false }
  $opusOnDisc = if ($pr -and ($pr.PSObject.Properties.Name -contains 'opusOnDiscuss') -and $null -ne $pr.opusOnDiscuss) { [bool]$pr.opusOnDiscuss } else { $false }
  $opusOnStudy = if ($pr -and ($pr.PSObject.Properties.Name -contains 'opusOnStudy') -and $null -ne $pr.opusOnStudy) { [bool]$pr.opusOnStudy } else { $true }
  $complexKeywords = @('архитектур','рефактор','перераб','redesign','мигр','интеграц','масштаб','overhaul','сложн','многошаг','разбер','исследуй','спроектируй','design','refactor')
  if ($pr -and ($pr.PSObject.Properties.Name -contains 'opusKeywords') -and $pr.opusKeywords) {
    $complexKeywords = @($pr.opusKeywords | ForEach-Object { [string]$_ })
  }
  $text = if ($null -eq $TaskText) { '' } else { [string]$TaskText }

  if ($text -imatch '(^|[^\p{L}\p{N}_])(opus|опус|fable|фейбл)([^\p{L}\p{N}_]|$)') { return $deepModel }
  if ($text -match '\[\[(DEEP-THINK|FABLE)\]\]') { return $deepModel }

  if ($Mode -eq 'study' -and $opusOnStudy) { return $deepModel }
  if ($Mode -eq 'discuss' -and $opusOnDisc) { return $deepModel }
  if ($Mode -eq 'synthesis') { return $deepModel }

  if ($opusOnLong) {
    $wordCount = ($text -split '\s+' | Where-Object { $_ }).Count
    if ($wordCount -gt 300) { return $deepModel }
  }

  # FIX 2026-05-27 (root-cause): removed numberedSteps + stageWords triggers.
  # Structure of a task spec (numbered points, "wave 1/2/3", "phase A/B") does NOT mean it
  # needs Opus -- it just means it's well-organized. A clear 10-step implementation spec
  # is EASIER for Sonnet, not harder. These triggers were the main reason every "structured"
  # task was getting routed to Opus + discuss-mode + xhigh reasoning, burning prepaid quota.
  # Use opusKeywords (architectural intent; legacy name) and explicit [[OPUS]] / [[FABLE]] /
  # [[DEEP-THINK]] markers for premium-model routing.
  # for routing instead.

  # 2026-07-02 planner-speed: coordinator turns explicitly use the deep model (was accidental via the word refactor in its own template)
  if (Test-DriverCoordinatorTaskText -TaskText $text) { return $deepModel }

  foreach ($kw in $complexKeywords) {
    if ($kw -and ($text -imatch [regex]::Escape($kw))) { return $deepModel }
  }

  return $triageModel
}

function Get-ChunkingSettings {
  $out = @{ enabled = $true; maxChunksPerTask = 10 }
  try {
    $cfgC = Get-BridgeConfig
    if ($cfgC -and ($cfgC.PSObject.Properties.Name -contains 'chunking') -and $cfgC.chunking) {
      $ch = $cfgC.chunking
      if (($ch.PSObject.Properties.Name -contains 'enabled') -and $null -ne $ch.enabled) { $out.enabled = [bool]$ch.enabled }
      if (($ch.PSObject.Properties.Name -contains 'maxChunksPerTask') -and $ch.maxChunksPerTask) { $out.maxChunksPerTask = [int]$ch.maxChunksPerTask }
    }
  } catch {}
  if ([int]$out.maxChunksPerTask -le 0) { $out.maxChunksPerTask = 10 }
  return $out
}

$Script:CliHelpCache = @{}

function Get-CliHelpText {
  # Cached --help fetcher. Returns lowercase help text (we match
  # case-insensitively) or '' if CLI not resolvable / failed.
  param([string]$Cli)
  if ($Script:CliHelpCache.ContainsKey($Cli)) { return $Script:CliHelpCache[$Cli] }
  $text = ''
  try {
    $cfg = Get-BridgeConfig
    if ($Cli -eq 'claude') {
      $exe = Resolve-ClaudeExe $cfg
      if ($exe -and (Test-Path -LiteralPath $exe)) {
        $text = (& $exe --help 2>$null | Out-String).ToLowerInvariant()
      }
    } elseif ($Cli -eq 'codex') {
      $exe = Resolve-CodexExe $cfg
      if ($exe -and (Test-Path -LiteralPath $exe)) {
        $main = (& $exe --help 2>$null | Out-String)
        $execHelp = (& $exe exec --help 2>$null | Out-String)
        $text = ($main + "`n" + $execHelp).ToLowerInvariant()
      }
    }
  } catch { $text = '' }
  $Script:CliHelpCache[$Cli] = $text
  return $text
}

function Test-CliFlagDiffLineLooksLikeInvocation {
  # The flag checker validates executable CLI calls, not prose inside JSON,
  # markdown, or critic artifacts. Keep this narrow enough to avoid treating
  # words like "codex" near unrelated commands (for example git --stat) as
  # a codex.exe invocation.
  param(
    [string]$Line,
    [string]$Cli
  )

  if ([string]::IsNullOrWhiteSpace($Line) -or [string]::IsNullOrWhiteSpace($Cli)) { return $false }
  $trim = ([string]$Line).Trim()
  if ([string]::IsNullOrWhiteSpace($trim)) { return $false }

  # JSON/YAML/markdown artifact text is not an executable invocation.
  if ($trim -match '^\s*["'']?[A-Za-z0-9_.-]+["'']?\s*:\s*["'']') { return $false }
  if ($trim -match '^\s*[-*]\s+') { return $false }

  $direct = ''
  $varOrResolver = ''
  $wrapper = ''
  if ($Cli -eq 'claude') {
    $direct = 'claude(?:\.exe)?'
    $varOrResolver = '\$claude\b|\$claudeExe\b|claudeExe|Resolve-ClaudeExe|Invoke-ParallelClaudeCli'
    $wrapper = 'Invoke-ParallelClaudeCli'
  } elseif ($Cli -eq 'codex') {
    $direct = 'codex(?:\.exe)?'
    $varOrResolver = '\$codex\b|\$codexExe\b|codexExe|Resolve-CodexExe|Invoke-ParallelCodexCli'
    $wrapper = 'Invoke-ParallelCodexCli'
  } else {
    return $false
  }

  $target = '(?:' + $direct + '|' + $varOrResolver + ')'

  # Direct shell/PowerShell execution: codex ..., & codex ..., ; & $codex ...
  if ($trim -match ('(?i)^\s*(?:&\s*)?' + $direct + '\b')) { return $true }
  if ($trim -match ('(?i)(?:^|[;&|({]\s*)&\s*' + $target + '\b')) { return $true }

  # Process-launch APIs that name the CLI on the same line.
  if ($trim -match ('(?i)\bStart-Process\b.*(?:-FilePath\s+)?' + $target + '\b')) { return $true }
  if ($trim -match ('(?i)\b(?:FileName|FilePath)\s*=\s*["'']?' + $target + '\b')) { return $true }

  # String-built commands are executable only when assigned to an invocation-ish
  # variable/property, not when embedded as arbitrary prose.
  if ($trim -match ('(?i)\b(?:cmd|command|commandline|cliargs|argumentlist|arguments)\b\s*(?:=|:).*\b' + $direct + '\b')) { return $true }

  # Wrapper calls are executable bridge code; resolver mentions alone are not
  # CLI invocations and must not make unrelated flags look like CLI args.
  if ($trim -match ('(?i)^\s*(?:&\s*)?' + $wrapper + '\b')) { return $true }

  return $false
}

function Test-CliFlagsInDiff {
  # Deterministic pre-critic check: scan ADDED lines in a git diff for
  # claude.exe / codex.exe invocations and verify every --flag actually
  # exists in the CLI's --help output. Returns @() if clean, or array of
  # @{ cli; flag; sample } describing unknown flags. The 2026-05-27 --cwd
  # incident (the LLM critic approved a non-existent Claude flag) is the
  # reason this guard exists: deterministic checks where the LLM cannot
  # hallucinate. To extend (gemini, deepseek): add a case in Get-CliHelpText
  # and a detection pattern below.
  param([string]$Diff)
  if ([string]::IsNullOrWhiteSpace($Diff)) { return @() }

  $issues = New-Object 'System.Collections.Generic.List[object]'

  # Per-CLI detection: each tuple = @{ name; linePattern; }. linePattern
  # decides whether a diff line is "calling" this CLI.
  $cliDetectors = @(
    @{ name = 'claude'; linePattern = '(?i)claude(?:\.exe)?|Resolve-ClaudeExe|\$claude\b|claudeExe|claudeGlob|Invoke-ParallelClaudeCli' },
    @{ name = 'codex';  linePattern = '(?i)codex(?:\.exe)?|Resolve-CodexExe|\$codex\b|codexExe|Invoke-ParallelCodexCli' }
  )

  $flagRegex = [regex]'(--[A-Za-z][A-Za-z0-9-]+)'

  # Track seen flags per CLI to dedupe; also keep one example line per flag
  $seen = @{}
  foreach ($det in $cliDetectors) { $seen[$det.name] = @{} }

  foreach ($rawLine in @($Diff -split "`r?`n")) {
    # Only ADDED lines (start with single + but not +++ which is the file header).
    if ($rawLine.Length -lt 2 -or $rawLine[0] -ne '+' -or $rawLine[1] -eq '+') { continue }
    $line = $rawLine.Substring(1)

    # Skip comment lines (PowerShell # comments) -- the CLI exe name in a
    # comment is not a real invocation. Be conservative: only skip if the
    # line starts with optional whitespace + '#'.
    if ($line -match '^\s*#') { continue }

    # CSS custom properties look like long CLI flags (`--codex`) in git diffs,
    # but they are not process arguments. Ignore both declarations and var()
    # usages before applying CLI-specific detectors.
    if ($line -match '^\s*--[A-Za-z][A-Za-z0-9-]*\s*:' -or
        $line -match '\bvar\(\s*--[A-Za-z][A-Za-z0-9-]*\s*\)') {
      continue
    }

    foreach ($det in $cliDetectors) {
      if ($line -notmatch $det.linePattern) { continue }
      if (-not (Test-CliFlagDiffLineLooksLikeInvocation -Line $line -Cli $det.name)) { continue }
      foreach ($fm in $flagRegex.Matches($line)) {
        $flag = $fm.Groups[1].Value
        if ($seen[$det.name].ContainsKey($flag)) { continue }
        $seen[$det.name][$flag] = $line.Trim()
      }
    }
  }

  foreach ($det in $cliDetectors) {
    if ($seen[$det.name].Count -eq 0) { continue }
    $help = Get-CliHelpText -Cli $det.name
    if ([string]::IsNullOrWhiteSpace($help)) {
      # CLI not resolvable -- skip silently, can't validate.
      continue
    }
    foreach ($flag in $seen[$det.name].Keys) {
      $flagLow = $flag.ToLowerInvariant()
      # Flag must appear in help with a word boundary AFTER it -- followed
      # by space, newline, '<' (for "<arg>"), '=' or end of string. Without
      # this we'd false-pass '--add' when only '--add-dir' exists.
      $needle = [regex]::Escape($flagLow)
      $ok = ($help -match ($needle + '(?:[\s<=,]|$)'))
      if (-not $ok) {
        [void]$issues.Add(@{
          cli    = $det.name
          flag   = $flag
          sample = $seen[$det.name][$flag]
        })
      }
    }
  }

  return @($issues.ToArray())
}

function Test-QualityBypassDiffLineIsCommentOnly {
  param([string]$Line)
  if ($null -eq $Line) { return $false }

  $trimmed = $Line.TrimStart()
  if ($trimmed.Length -eq 0) { return $false }

  return ($trimmed -match '^(#|//|/\*|\*|<!--|<#)')
}

function Test-QualityBypassesInDiff {
  # Deterministic project-quality guard: reject added lines that disable build,
  # type, or lint gates instead of fixing the code. This is intentionally narrow:
  # only obvious bypass switches are blocked; normal config changes still go to
  # the LLM critic and project build gate.
  # Security note: the regex below matches the literal Next.js config key
  # "ignoreBuildErrors: true". It is a policy signature, not a credential,
  # secret, token, or auth value, so hardcoded-credentials scanners can treat
  # this spot as a false positive.
  param([string]$Diff)
  if ([string]::IsNullOrWhiteSpace($Diff)) { return @() }

  $issues = New-Object 'System.Collections.Generic.List[object]'
  $patterns = @(
    @{ key='next-ignore-build-errors'; pattern='(?i)\bignoreBuildErrors\s*:\s*true\b'; reason='Next.js TypeScript build errors are disabled' },
    @{ key='next-ignore-lint';         pattern='(?i)\bignoreDuringBuilds\s*:\s*true\b'; reason='Next.js lint failures are disabled during build' },
    @{ key='ts-nocheck';               pattern='(?i)@ts-nocheck\b'; reason='TypeScript checking is disabled for a file' },
    @{ key='swallow-verify-failure';   pattern='(?i)(npm\s+run\s+(?:typecheck|build|lint)|\btsc\b|\bnext\s+build\b|\bnext\s+lint\b).*(\|\|\s*(?:true|exit\s+0)|;\s*exit\s+0)'; reason='verification command failure is swallowed' }
  )
  $seen = @{}

  foreach ($rawLine in @($Diff -split "`r?`n")) {
    if ($rawLine.Length -lt 2 -or $rawLine[0] -ne '+' -or $rawLine[1] -eq '+') { continue }
    $line = $rawLine.Substring(1)
    if (Test-QualityBypassDiffLineIsCommentOnly -Line $line) { continue }
    foreach ($pat in $patterns) {
      if ($line -match $pat.pattern) {
        $key = [string]$pat.key
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$issues.Add([pscustomobject]@{
          key    = $key
          reason = [string]$pat.reason
          sample = $line.Trim()
        })
      }
    }
  }

  return @($issues.ToArray())
}

function Test-CoderClaims {
  # Deterministic gate: scan Codex reply for verifiable claims (HTTP status,
  # ParseFile OK assertions, git SHA references) and check each against ground
  # truth (actually call endpoint, actually parse file, actually look up SHA).
  # Returns @{ violations=@(); checks=@() } — mismatches go to violations,
  # confirmed claims to checks. Output is purely informational (synthesized
  # into a system message for the next planner turn) — NEVER blocks the flow.
  # Born from curator-задача 2026-05-27: Codex 3x claimed "backfill для 51"
  # at actual 3/19/35. With this gate, planner would see the discrepancy on
  # the same turn instead of after a 30s LLM verify round.
  # To extend: add new claim-class patterns + verifier blocks below.
  param([string]$Reply, [string]$BridgeRoot, [string]$ProjectRoot = '')

  $violations = New-Object 'System.Collections.Generic.List[object]'
  $checks = New-Object 'System.Collections.Generic.List[object]'
  $result = @{ violations = @(); checks = @() }
  if ([string]::IsNullOrWhiteSpace($Reply) -or [string]::IsNullOrWhiteSpace($BridgeRoot)) { return $result }

  # --- 1. HTTP status claims ---
  # Patterns: "/api/foo → 200", "GET /api/foo  200", "HTTP 200 from /api/foo".
  # Separator class permits arrows (->, =>, →), pipes, colons, and whitespace.
  # The "+" makes it match the whole " -> " sequence in one shot.
  $httpPatterns = @(
    '(?im)(/api/[A-Za-z0-9_/-]+)(?:[\s\-=→>|:])+(?:HTTP\s+|status\s*[:=]?\s*)?(\d{3})\b',
    '(?im)HTTP\s+(\d{3})\s+(?:from|on|по)?\s*(/api/[A-Za-z0-9_/-]+)',
    '(?im)`?Invoke-WebRequest[^\n]*?(/api/[A-Za-z0-9_/-]+)[^\n]*?(?:StatusCode|статус)\s*[=:]\s*(\d{3})'
  )
  $httpClaims = @{}
  foreach ($pat in $httpPatterns) {
    foreach ($m in [regex]::Matches($Reply, $pat)) {
      # Need to handle pattern with endpoint-first vs status-first
      $g1 = $m.Groups[1].Value; $g2 = $m.Groups[2].Value
      if ($g1 -match '^/api/') { $endpoint = $g1; $status = $g2 }
      else                       { $endpoint = $g2; $status = $g1 }
      $tmpInt = 0
      if (-not [int]::TryParse($status, [ref]$tmpInt)) { continue }
      $key = "$endpoint=$status"
      if ($httpClaims.ContainsKey($key)) { continue }
      $httpClaims[$key] = $true
    }
  }
  if ($httpClaims.Count -gt 0) {
    $auth = $null
    # Credentials are loaded at runtime from Get-AuthPath/auth.json (gitignored
    # private storage), then only used to probe claimed HTTP statuses.
    try { $authP = if (Get-Command Get-AuthPath -ErrorAction SilentlyContinue) { Get-AuthPath } else { Join-Path $BridgeRoot 'auth.json' }; $auth = Get-Content $authP -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    $basic = ''
    if ($auth) { try { $basic = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($auth.user + ':' + $auth.password)) } catch {} }
    foreach ($key in $httpClaims.Keys) {
      $parts = $key -split '='; $endpoint = $parts[0]; $claimed = [int]$parts[1]
      $url = "http://localhost:8787$endpoint"
      $actualStatus = 0
      try {
        $headers = if ($basic) { @{ Authorization = "Basic $basic" } } else { @{} }
        $resp = Invoke-WebRequest -Uri $url -Headers $headers -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        $actualStatus = [int]$resp.StatusCode
      } catch {
        try { $actualStatus = [int]$_.Exception.Response.StatusCode } catch {}
      }
      if ($actualStatus -eq $claimed) {
        [void]$checks.Add(@{ kind='http-status'; claim="$endpoint → $claimed"; actual="$actualStatus" })
      } else {
        $actualText = if ($actualStatus -gt 0) { "$actualStatus" } else { 'no response' }
        [void]$violations.Add(@{ kind='http-status'; claim="$endpoint → $claimed"; actual=$actualText })
      }
    }
  }

  # --- 2. ParseFile OK claims ---
  # Patterns: "ParseFile lib/foo.ps1 → OK", "ParseFile `lib/foo.ps1`: OK".
  $parseClaims = @{}
  foreach ($m in [regex]::Matches($Reply, '(?im)ParseFile\s+[`"'']*([A-Za-z0-9_./\\-]+\.ps1)[`"'']*\s*(?:[→\->|→]|:)?\s*(?:OK|УСПЕХ|✓|без\s+ошибок)\b')) {
    $f = ($m.Groups[1].Value -replace '\\','/').Trim('"','''','`')
    if (-not $parseClaims.ContainsKey($f)) { $parseClaims[$f] = $true }
  }
  foreach ($f in $parseClaims.Keys) {
    $fullPath = if ([System.IO.Path]::IsPathRooted($f)) { $f } else { Join-Path $BridgeRoot $f }
    if (-not (Test-Path -LiteralPath $fullPath)) {
      [void]$violations.Add(@{ kind='parse-file'; claim="$f = OK"; actual='файл не найден' })
      continue
    }
    $pTokens = $null; $pErrs = $null
    try {
      [void][System.Management.Automation.Language.Parser]::ParseFile($fullPath, [ref]$pTokens, [ref]$pErrs)
      if ($pErrs -and $pErrs.Count -gt 0) {
        $first = $pErrs[0]
        [void]$violations.Add(@{ kind='parse-file'; claim="$f = OK"; actual="$($pErrs.Count) ошибок (например: " + ([string]$first.Message).Substring(0,[Math]::Min(80,([string]$first.Message).Length)) + ')' })
      } else {
        [void]$checks.Add(@{ kind='parse-file'; claim="$f = OK"; actual='действительно OK' })
      }
    } catch {
      [void]$violations.Add(@{ kind='parse-file'; claim="$f = OK"; actual="parse failed: " + $_.Exception.Message })
    }
  }

  # --- 3. Git SHA references ---
  # Patterns: "commit abc1234", "коммит abc1234", "merged abc1234", "HEAD abc1234".
  # Only flag short-hexes adjacent to commit/sha keywords (avoid noise from
  # random hex like file hashes or numbers).
  $shaClaims = @{}
  foreach ($m in [regex]::Matches($Reply, '(?i)(?:commit|коммит|merge[ds]?|HEAD|SHA|hash)\s*[:=]?\s*[`"'']?([0-9a-f]{7,40})[`"'']?\b')) {
    $sha = $m.Groups[1].Value.ToLowerInvariant()
    # Skip all-digit "shas" (e.g. years like "2026")
    if ($sha -match '^\d+$') { continue }
    if (-not $shaClaims.ContainsKey($sha)) { $shaClaims[$sha] = $true }
  }
  # Project atoms commit to the PROJECT repo (bridge-projects/<slug>), not the bridge repo.
  # Use the explicitly-passed repo root so SHA checks are independent of process CWD.
  $shaRepoRoot = $ProjectRoot
  if ([string]::IsNullOrWhiteSpace($shaRepoRoot)) { $shaRepoRoot = $BridgeRoot }
  if (-not [string]::IsNullOrWhiteSpace($shaRepoRoot) -and -not (Test-Path -LiteralPath $shaRepoRoot)) {
    $shaRepoRoot = $BridgeRoot
  }
  foreach ($sha in $shaClaims.Keys) {
    $exists = $false
    try {
      $null = & git -C $shaRepoRoot cat-file -e $sha 2>$null
      $exists = ($LASTEXITCODE -eq 0)
    } catch {}
    # B4 (2026-06-21): a sha may live in the OTHER repo (project atoms commit to the project
    # repo, bridge tasks to the bridge repo). Retry the bridge root before declaring a phantom
    # violation; only a violation if BOTH repos miss it. Prevents false dispute loops.
    if (-not $exists -and -not [string]::IsNullOrWhiteSpace($BridgeRoot) -and $shaRepoRoot -ne $BridgeRoot) {
      try {
        $null = & git -C $BridgeRoot cat-file -e $sha 2>$null
        $exists = ($LASTEXITCODE -eq 0)
      } catch {}
    }
    if ($exists) {
      [void]$checks.Add(@{ kind='git-sha'; claim="commit $sha"; actual='существует' })
    } else {
      [void]$violations.Add(@{ kind='git-sha'; claim="commit $sha"; actual='нет такого объекта в репо' })
    }
  }

  $result.violations = @($violations.ToArray())
  $result.checks = @($checks.ToArray())
  return $result
}

function Set-FastLaneFlags {
  param($State, [string]$Reason = '')
  if (-not $State) { return }
  $State | Add-Member -NotePropertyName skip_planner -NotePropertyValue $true -Force
  $State | Add-Member -NotePropertyName skip_critic -NotePropertyValue $true -Force
  $State | Add-Member -NotePropertyName skip_reflect -NotePropertyValue $true -Force
  $State | Add-Member -NotePropertyName fast_lane_reason -NotePropertyValue ([string]$Reason) -Force
}

function Clear-FastLaneFlags {
  param($State, [switch]$PreserveReflectSkip)
  if (-not $State) { return }
  $lastSkip = $false
  try { $lastSkip = [bool]$State.skip_reflect } catch {}
  if ($PreserveReflectSkip) {
    $State | Add-Member -NotePropertyName last_task_skip_reflect -NotePropertyValue $lastSkip -Force
  } else {
    $State | Add-Member -NotePropertyName last_task_skip_reflect -NotePropertyValue $false -Force
  }
  $State | Add-Member -NotePropertyName skip_planner -NotePropertyValue $false -Force
  $State | Add-Member -NotePropertyName skip_critic -NotePropertyValue $false -Force
  $State | Add-Member -NotePropertyName skip_reflect -NotePropertyValue $false -Force
  $State | Add-Member -NotePropertyName fast_lane_reason -NotePropertyValue '' -Force
}

function Clear-ChunkingState {
  param($State)
  if (-not $State) { return }
  $State | Add-Member -NotePropertyName chunk_progress -NotePropertyValue '' -Force
  $State | Add-Member -NotePropertyName chunk_base_commit -NotePropertyValue '' -Force
  $State | Add-Member -NotePropertyName force_coder -NotePropertyValue $false -Force
}
$null = Initialize-Bridge

$script:CuratorLibPath = 'C:\Users\rafie\OneDrive\Documents\bridge\lib\backlog.ps1'
$script:CuratorControlPath = 'C:\Users\rafie\OneDrive\Documents\bridge\control'
$script:CuratorLogPath = Join-Path $script:CuratorControlPath 'curator.log'
$script:CuratorDecisionsPath = Join-Path $script:CuratorControlPath 'curator-decisions.jsonl'
$script:LastAddIdeaPath = Join-Path $script:CuratorControlPath 'last-add-idea.json'
$script:CuratorDecisionLineCount = 0

# ---------- helpers ----------
