function New-AuditFinding {
  param(
    [string]$Severity,
    [string]$Category,
    [string]$Component,
    [string]$Message,
    [string]$Recommendation
  )
  $sev = ([string]$Severity).ToLowerInvariant()
  if (@('critical', 'warning', 'info') -notcontains $sev) { $sev = 'info' }
  return [ordered]@{
    severity = $sev
    category = [string]$Category
    component = [string]$Component
    message = [string]$Message
    recommendation = [string]$Recommendation
  }
}

function Add-AuditFinding {
  param(
    [System.Collections.Generic.List[object]]$Findings,
    [string]$Severity,
    [string]$Category,
    [string]$Component,
    [string]$Message,
    [string]$Recommendation
  )
  [void]$Findings.Add((New-AuditFinding -Severity $Severity -Category $Category -Component $Component -Message $Message -Recommendation $Recommendation))
}

function Limit-AuditText {
  param([AllowNull()][string]$Value, [int]$MaxChars = 500)
  if ($null -eq $Value) { return '' }
  $text = ([string]$Value).Trim()
  if ($MaxChars -le 0 -or $text.Length -le $MaxChars) { return $text }
  return $text.Substring(0, $MaxChars).TrimEnd() + '...'
}

function Read-AuditTextFile {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  try { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) }
  catch { return '' }
}

function Get-AuditRelativePath {
  param([string]$Root, [string]$Path)
  try {
    $trimChars = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd($trimChars)
    $fileFull = [System.IO.Path]::GetFullPath($Path)
    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    if ($fileFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $fileFull.Substring($prefix.Length)
    }
  } catch {}
  return [string]$Path
}

function Test-AuditSkipPath {
  param([string]$Root, [string]$Path)
  $rel = (Get-AuditRelativePath -Root $Root -Path $Path) -replace '\\', '/'
  return ($rel -match '(^|/)(\.git|worktrees|node_modules|memory|control|jobs|screenshots|tmp|temp)(/|$)')
}

function Get-AuditPowerShellFiles {
  param([string]$Root)
  $files = New-Object 'System.Collections.Generic.List[object]'
  try {
    foreach ($file in (Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
      if (Test-AuditSkipPath -Root $Root -Path $file.FullName) { continue }
      [void]$files.Add($file)
    }
  } catch {}
  return @($files.ToArray())
}

function Normalize-AuditApiPath {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
  $p = ([string]$Path).Trim()
  $q = $p.IndexOf('?')
  if ($q -ge 0) { $p = $p.Substring(0, $q) }
  $h = $p.IndexOf('#')
  if ($h -ge 0) { $p = $p.Substring(0, $h) }
  return $p.TrimEnd('/')
}

function Get-AuditApiPathsFromText {
  param([string]$Text)
  $paths = New-Object 'System.Collections.Generic.List[string]'
  if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
  $pattern = '/api/[A-Za-z0-9._~:/?#\[\]@!$&()*+,;=%-]*'
  foreach ($m in [regex]::Matches($Text, $pattern)) {
    $p = Normalize-AuditApiPath -Path $m.Value
    if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$paths.Add($p) }
  }
  return @($paths.ToArray() | Sort-Object -Unique)
}

function Get-AuditServerEndpoints {
  param([string]$ServerPath)
  $endpoints = New-Object 'System.Collections.Generic.List[string]'
  if (-not (Test-Path -LiteralPath $ServerPath -PathType Leaf)) { return @() }
  $lines = @()
  try { $lines = [System.IO.File]::ReadAllLines($ServerPath, [System.Text.Encoding]::UTF8) } catch { return @() }
  foreach ($line in $lines) {
    $trimmed = ([string]$line).TrimStart()
    if ($trimmed.StartsWith('#') -or $trimmed -notmatch '/api/') { continue }
    $looksLikeHandler =
      ($line -match '\$path\s*-eq\s*[''"]/api/') -or
      ($line -match '^\s*[''"]/api/')
    if (-not $looksLikeHandler) { continue }
    foreach ($p in (Get-AuditApiPathsFromText -Text $line)) {
      [void]$endpoints.Add($p)
    }
  }
  return @($endpoints.ToArray() | Sort-Object -Unique)
}

function Add-AuditJsonKeys {
  param(
    [AllowNull()][object]$Node,
    [string]$Prefix,
    [System.Collections.Generic.List[string]]$Keys
  )
  if ($null -eq $Node) { return }

  if ($Node -is [System.Collections.IDictionary]) {
    foreach ($key in $Node.Keys) {
      $name = [string]$key
      $path = if ([string]::IsNullOrWhiteSpace($Prefix)) { $name } else { "$Prefix.$name" }
      [void]$Keys.Add($path)
      Add-AuditJsonKeys -Node $Node[$key] -Prefix $path -Keys $Keys
    }
    return
  }

  if ($Node -is [System.Array]) {
    foreach ($item in @($Node)) {
      if ($item -is [pscustomobject] -or $item -is [System.Collections.IDictionary] -or $item -is [System.Array]) {
        Add-AuditJsonKeys -Node $item -Prefix $Prefix -Keys $Keys
      }
    }
    return
  }

  if ($Node -is [pscustomobject]) {
    foreach ($prop in $Node.PSObject.Properties) {
      $name = [string]$prop.Name
      $path = if ([string]::IsNullOrWhiteSpace($Prefix)) { $name } else { "$Prefix.$name" }
      [void]$Keys.Add($path)
      Add-AuditJsonKeys -Node $prop.Value -Prefix $path -Keys $Keys
    }
  }
}

function Get-AuditConfigKeys {
  param([string]$ConfigPath)
  $keys = New-Object 'System.Collections.Generic.List[string]'
  if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return @() }
  try {
    $obj = (Read-AuditTextFile -Path $ConfigPath) | ConvertFrom-Json
    Add-AuditJsonKeys -Node $obj -Prefix '' -Keys $keys
  } catch {
    return @()
  }
  return @($keys.ToArray() | Sort-Object -Unique)
}

function Get-AuditObjectProperty {
  param([AllowNull()][object]$InputObject, [string]$Name)
  if ($null -eq $InputObject) { return $null }
  if ($InputObject -is [System.Collections.IDictionary]) {
    if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
    try {
      if ($InputObject.ContainsKey($Name)) { return $InputObject[$Name] }
    } catch {}
  }
  try {
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
  } catch {}
  return $null
}

function Get-AuditKeyReferenceCount {
  param([string]$KeyPath, [string[]]$PowerShellTexts)
  if ([string]::IsNullOrWhiteSpace($KeyPath)) { return 0 }
  $leaf = $KeyPath
  if ($KeyPath.Contains('.')) { $leaf = @($KeyPath -split '\.')[-1] }
  $patterns = New-Object 'System.Collections.Generic.List[string]'
  [void]$patterns.Add([regex]::Escape($KeyPath))
  if ($leaf -ne $KeyPath) {
    [void]$patterns.Add(('(?<![\w-])' + [regex]::Escape($leaf) + '(?![\w-])'))
  } else {
    $patterns[0] = '(?<![\w-])' + [regex]::Escape($leaf) + '(?![\w-])'
  }

  $count = 0
  foreach ($text in @($PowerShellTexts)) {
    if ([string]::IsNullOrEmpty($text)) { continue }
    foreach ($pattern in @($patterns.ToArray() | Sort-Object -Unique)) {
      try { $count += [regex]::Matches($text, $pattern).Count } catch {}
    }
  }
  return $count
}

function Get-AuditFunctionRecords {
  param([object[]]$PowerShellFiles, [string]$Root)
  $records = New-Object 'System.Collections.Generic.List[object]'
  foreach ($file in @($PowerShellFiles)) {
    $tokens = $null
    $errors = $null
    try {
      $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
      $funcAsts = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
      foreach ($fn in @($funcAsts)) {
        [void]$records.Add([pscustomobject]@{
          Name = [string]$fn.Name
          File = (Get-AuditRelativePath -Root $Root -Path $file.FullName)
          FullName = [string]$file.FullName
          Line = [int]$fn.Extent.StartLineNumber
          Body = (Normalize-AuditFunctionBody -Body ([string]$fn.Body.Extent.Text))
        })
      }
    } catch {}
  }
  return @($records.ToArray())
}

function Normalize-AuditFunctionBody {
  param([AllowNull()][string]$Body)
  if ([string]::IsNullOrWhiteSpace($Body)) { return '' }
  $lines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($line in ($Body -split "`r?`n")) {
    [void]$lines.Add(([string]$line).TrimEnd())
  }
  return (($lines.ToArray() -join "`n").Trim())
}

function Get-AuditHash {
  param([string]$Text)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
    return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant()
  } finally {
    $sha.Dispose()
  }
}

function Get-AuditFunctionReferenceCount {
  param([string]$Name, [string[]]$PowerShellTexts)
  if ([string]::IsNullOrWhiteSpace($Name)) { return 0 }
  $pattern = '(?<![\w-])' + [regex]::Escape($Name) + '(?![\w-])'
  $count = 0
  foreach ($text in @($PowerShellTexts)) {
    if ([string]::IsNullOrEmpty($text)) { continue }
    try { $count += [regex]::Matches($text, $pattern).Count } catch {}
  }
  return $count
}

function Get-AuditUnusedFunctionCandidates {
  param([object[]]$Functions, [string[]]$PowerShellTexts)
  $out = New-Object 'System.Collections.Generic.List[object]'
  foreach ($fn in @($Functions)) {
    $count = Get-AuditFunctionReferenceCount -Name ([string]$fn.Name) -PowerShellTexts $PowerShellTexts
    if ($count -le 1) {
      [void]$out.Add([pscustomobject]@{
        Name = [string]$fn.Name
        File = [string]$fn.File
        Line = [int]$fn.Line
        References = [int]$count
      })
    }
  }
  return @($out.ToArray())
}

function Add-AuditDuplicateFunctionFindings {
  param(
    [System.Collections.Generic.List[object]]$Findings,
    [object[]]$Functions
  )
  $byHash = @{}
  foreach ($fn in @($Functions)) {
    $body = [string]$fn.Body
    if ([string]::IsNullOrWhiteSpace($body) -or $body.Length -lt 8) { continue }
    $hash = Get-AuditHash -Text $body
    if (-not $byHash.ContainsKey($hash)) {
      $byHash[$hash] = New-Object 'System.Collections.Generic.List[object]'
    }
    [void]$byHash[$hash].Add($fn)
  }

  foreach ($hash in @($byHash.Keys)) {
    $group = @($byHash[$hash].ToArray())
    if ($group.Count -lt 2) { continue }
    $parts = @($group | ForEach-Object { "$($_.Name) ($($_.File):$($_.Line))" })
    $component = Limit-AuditText -Value ($parts -join '; ') -MaxChars 400
    Add-AuditFinding -Findings $Findings -Severity 'info' -Category 'duplicate_code' -Component $component `
      -Message 'Functions have identical normalized bodies.' `
      -Recommendation 'Compare the functions and keep one shared implementation if they are intentionally equivalent.'
  }
}

function Add-AuditDebtFindings {
  param(
    [System.Collections.Generic.List[object]]$Findings,
    [string]$Root,
    [object[]]$Files
  )
  $markers = @('TO' + 'DO', 'FIX' + 'ME', 'HA' + 'CK', 'X' + 'XX', 'BRO' + 'KEN', 'RE' + 'MOVE', 'DEP' + 'RECATED')
  $pattern = '\b(' + (($markers | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\b'
  $regex = New-Object System.Text.RegularExpressions.Regex($pattern)

  foreach ($file in @($Files)) {
    if ($null -eq $file -or -not (Test-Path -LiteralPath $file.FullName -PathType Leaf)) { continue }
    $lineNo = 0
    try {
      foreach ($line in [System.IO.File]::ReadLines($file.FullName, [System.Text.Encoding]::UTF8)) {
        $lineNo++
        $m = $regex.Match([string]$line)
        if (-not $m.Success) { continue }
        $rel = Get-AuditRelativePath -Root $Root -Path $file.FullName
        Add-AuditFinding -Findings $Findings -Severity 'warning' -Category 'debt_marker' -Component "$rel`:$lineNo" `
          -Message ("Debt marker {0}: {1}" -f $m.Value, (Limit-AuditText -Value $line -MaxChars 220)) `
          -Recommendation 'Resolve the marked debt or move it to a tracked issue with clear ownership.'
      }
    } catch {}
  }
}

function Get-AuditGitLog {
  param([string]$Root)
  try {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return '' }
    $lines = @(& git -C $Root log --oneline -10 2>$null)
    return (($lines | ForEach-Object { [string]$_ }) -join "`n")
  } catch {
    return ''
  }
}

function Format-AuditListSection {
  param([string]$Title, [string[]]$Lines, [int]$MaxChars)
  $body = (($Lines | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n")
  if ([string]::IsNullOrWhiteSpace($body)) { $body = '(empty)' }
  return $Title + ":`n" + (Limit-AuditText -Value $body -MaxChars $MaxChars)
}

function New-AuditLlmContext {
  param(
    [object[]]$Functions,
    [string[]]$Endpoints,
    [object[]]$DebtFindings,
    [object[]]$UnusedFunctions,
    [string]$GitLog
  )
  $functionLines = @($Functions | Sort-Object File, Line | ForEach-Object { "- $($_.Name) ($($_.File):$($_.Line))" })
  $endpointLines = @($Endpoints | Sort-Object | ForEach-Object { "- $_" })
  $debtLines = @($DebtFindings | ForEach-Object { "- $($_['component']): $($_['message'])" })
  $unusedLines = @($UnusedFunctions | Sort-Object File, Line | ForEach-Object { "- $($_.Name) ($($_.File):$($_.Line))" })
  $gitLines = @(([string]$GitLog -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { "- $_" })

  $sections = @(
    (Format-AuditListSection -Title 'FUNCTIONS' -Lines $functionLines -MaxChars 2600),
    (Format-AuditListSection -Title 'API_ENDPOINTS' -Lines $endpointLines -MaxChars 1200),
    (Format-AuditListSection -Title 'DEBT_MARKERS' -Lines $debtLines -MaxChars 1800),
    (Format-AuditListSection -Title 'STATIC_UNUSED_FUNCTION_CANDIDATES' -Lines $unusedLines -MaxChars 1400),
    (Format-AuditListSection -Title 'GIT_LOG' -Lines $gitLines -MaxChars 900)
  )
  return (Limit-AuditText -Value ($sections -join "`n`n") -MaxChars 8000)
}

function ConvertFrom-AuditLlmJsonFindings {
  param([AllowNull()][string]$Raw)
  $out = New-Object 'System.Collections.Generic.List[object]'
  if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
  $clean = ([string]$Raw).Trim()
  $clean = $clean -replace '^\s*```(?:json)?\s*', ''
  $clean = $clean -replace '\s*```\s*$', ''
  $start = $clean.IndexOf('[')
  $end = $clean.LastIndexOf(']')
  if ($start -ge 0 -and $end -ge $start) {
    $clean = $clean.Substring($start, $end - $start + 1)
  }

  $items = @()
  try {
    $parsed = $clean | ConvertFrom-Json
    $items = @($parsed)
  } catch { return @() }
  foreach ($item in @($items)) {
    $message = [string](Get-AuditObjectProperty -InputObject $item -Name 'message')
    if ([string]::IsNullOrWhiteSpace($message)) { continue }
    $severity = ([string](Get-AuditObjectProperty -InputObject $item -Name 'severity')).ToLowerInvariant()
    if (@('critical', 'warning', 'info') -notcontains $severity) { $severity = 'info' }
    $category = [string](Get-AuditObjectProperty -InputObject $item -Name 'category')
    $component = [string](Get-AuditObjectProperty -InputObject $item -Name 'component')
    $recommendation = [string](Get-AuditObjectProperty -InputObject $item -Name 'recommendation')
    if ([string]::IsNullOrWhiteSpace($category)) { $category = 'llm' }
    if ([string]::IsNullOrWhiteSpace($component)) { $component = 'llm' }
    if ([string]::IsNullOrWhiteSpace($recommendation)) { $recommendation = 'Review this finding manually.' }
    [void]$out.Add((New-AuditFinding -Severity $severity -Category $category -Component $component -Message $message -Recommendation $recommendation))
  }
  return @($out.ToArray())
}

function Invoke-AuditFunctionalLlm {
  param([string]$Context)
  if ([string]::IsNullOrWhiteSpace($Context)) { return @() }
  $systemPrompt = "Ты аудитор кодовой базы AI-системы 'bridge'. Анализируй список функций, endpoints и debt-маркеров. Найди: (1) фичи которые явно сломаны или устарели, (2) endpoint'ы которые есть в коде но скорее всего больше не нужны, (3) функции которые выглядят как неиспользуемый legacy. Отвечай ТОЛЬКО в формате JSON: [{severity, category, component, message, recommendation}]"
  $prompt = $systemPrompt + "`n`n" + $Context
  $raw = $null
  try {
    if (Get-Command Invoke-LLM -ErrorAction SilentlyContinue) {
      $raw = Invoke-LLM -Purpose 'audit-functional' -Prompt $prompt -TimeoutSec 60 -Temperature 0.2
    }
  } catch {
    $raw = $null
  }
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  return @(ConvertFrom-AuditLlmJsonFindings -Raw $raw)
}

function Invoke-FunctionalAudit {
  param([string]$BridgePath)
  $findings = New-Object 'System.Collections.Generic.List[object]'

  if ([string]::IsNullOrWhiteSpace($BridgePath)) { $BridgePath = (Get-Location).Path }
  try {
    $root = (Resolve-Path -LiteralPath $BridgePath -ErrorAction Stop).Path
  } catch {
    Add-AuditFinding -Findings $findings -Severity 'critical' -Category 'input' -Component 'BridgePath' `
      -Message "BridgePath does not exist: $BridgePath" `
      -Recommendation 'Pass a valid bridge repository path.'
    return (New-AuditResult -Findings $findings)
  }

  $serverPath = Join-Path $root 'server.ps1'
  $indexPath = Join-Path $root 'web\index.html'
  $configPath = Join-Path $root 'config.json'
  $psFiles = @(Get-AuditPowerShellFiles -Root $root)
  $psTexts = @($psFiles | ForEach-Object { Read-AuditTextFile -Path $_.FullName })

  $serverEndpoints = @(Get-AuditServerEndpoints -ServerPath $serverPath)
  $clientEndpoints = @(Get-AuditApiPathsFromText -Text (Read-AuditTextFile -Path $indexPath))
  $clientEndpointSet = @{}
  foreach ($endpoint in @($clientEndpoints)) { $clientEndpointSet[$endpoint] = $true }
  foreach ($endpoint in @($serverEndpoints)) {
    if ($clientEndpointSet.ContainsKey($endpoint)) { continue }
    Add-AuditFinding -Findings $findings -Severity 'info' -Category 'api_endpoint_mapping' -Component $endpoint `
      -Message 'Endpoint is defined in server.ps1 but no matching /api path was found in web/index.html.' `
      -Recommendation 'Verify whether the endpoint is external-only; otherwise remove the handler or wire the UI to it.'
  }

  $configKeys = @(Get-AuditConfigKeys -ConfigPath $configPath)
  foreach ($key in @($configKeys)) {
    $refCount = Get-AuditKeyReferenceCount -KeyPath $key -PowerShellTexts $psTexts
    if ($refCount -ne 0) { continue }
    Add-AuditFinding -Findings $findings -Severity 'info' -Category 'orphaned_config' -Component $key `
      -Message 'Config key has no references in PowerShell sources.' `
      -Recommendation 'Confirm it is not used by external tools or the UI, then remove it from config.json if obsolete.'
  }

  $debtFiles = New-Object 'System.Collections.Generic.List[object]'
  foreach ($file in @($psFiles)) { [void]$debtFiles.Add($file) }
  if (Test-Path -LiteralPath $indexPath -PathType Leaf) { [void]$debtFiles.Add((Get-Item -LiteralPath $indexPath)) }
  Add-AuditDebtFindings -Findings $findings -Root $root -Files @($debtFiles.ToArray())
  $debtFindings = @($findings.ToArray() | Where-Object { $_['category'] -eq 'debt_marker' })

  $functions = @(Get-AuditFunctionRecords -PowerShellFiles $psFiles -Root $root)
  Add-AuditDuplicateFunctionFindings -Findings $findings -Functions $functions
  $unusedFunctions = @(Get-AuditUnusedFunctionCandidates -Functions $functions -PowerShellTexts $psTexts)

  $context = New-AuditLlmContext -Functions $functions -Endpoints $serverEndpoints -DebtFindings $debtFindings `
    -UnusedFunctions $unusedFunctions -GitLog (Get-AuditGitLog -Root $root)
  foreach ($llmFinding in @(Invoke-AuditFunctionalLlm -Context $context)) {
    [void]$findings.Add($llmFinding)
  }

  $scenarioDir = Join-Path $root 'tools\scenarios'
  $scenarioRunner = Join-Path $root 'tools\scenario.ps1'
  if ((Test-Path -LiteralPath $scenarioDir -PathType Container) -and (Test-Path -LiteralPath $scenarioRunner -PathType Leaf)) {
    # Quick reachability check - don't blame audit if the bridge isn't up.
    $serverReachable = $false
    try {
      $resp = Invoke-WebRequest -Uri 'http://localhost:8787/api/health' -Method GET -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
      $serverReachable = ($resp.StatusCode -eq 200)
    } catch { $serverReachable = $false }

    if (-not $serverReachable) {
      Add-AuditFinding -Findings $findings -Severity 'info' -Category 'behavioral_skipped' -Component 'localhost:8787' `
        -Message 'Bridge server is not reachable; behavioral scenarios skipped.' `
        -Recommendation 'If audit runs while bridge is down, this is expected. Otherwise investigate why /api/health failed.'
    } else {
      # 2026-05-28: audit-safety gate. Real incident: user typed "сделай аудит",
      # audit-functional ran ALL scenarios (no filter), including message-send.js
      # which BY DESIGN types into composer + clicks Send -> a "user message"
      # appeared in their chat ("scenario-msg-..."). Also backlog-add.js polluted
      # backlog with test items. From now on each scenario must opt-in via a
      # leading comment "// @audit-safe: yes" -- mutating scenarios stay out of
      # automated audit batch and can only be run manually via tools\scenario.ps1.
      foreach ($scenarioFile in (Get-ChildItem -LiteralPath $scenarioDir -Filter '*.js' -ErrorAction SilentlyContinue)) {
        $scenarioName = [System.IO.Path]::GetFileNameWithoutExtension($scenarioFile.Name)
        # Read first 20 lines of the .js file looking for opt-in marker.
        $auditSafe = $false
        $skipReason = ''
        try {
          $head = Get-Content -LiteralPath $scenarioFile.FullName -TotalCount 20 -Encoding UTF8 -ErrorAction SilentlyContinue
          $headText = ($head -join "`n")
          if ($headText -match '(?im)^\s*//\s*@audit-safe\s*:\s*yes\b') {
            $auditSafe = $true
          } elseif ($headText -match '(?im)^\s*//\s*@audit-safe\s*:\s*no\b') {
            $auditSafe = $false
            $skipReason = 'marked @audit-safe: no (mutates state)'
          } else {
            $auditSafe = $false
            $skipReason = 'no @audit-safe annotation (default safe: skip)'
          }
        } catch { $auditSafe = $false; $skipReason = 'cannot read scenario file' }

        if (-not $auditSafe) {
          Add-AuditFinding -Findings $findings -Severity 'info' -Category 'behavioral_skipped' -Component $scenarioName `
            -Message ("Scenario {0} skipped — {1}." -f $scenarioName, $skipReason) `
            -Recommendation 'Add `// @audit-safe: yes` to the scenario header if it is non-mutating and safe to run in batch audits.'
          continue
        }

        $exitCode = 0
        try {
          $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $scenarioRunner -Name $scenarioName -TimeoutSec 60 2>&1
          $exitCode = $LASTEXITCODE
        } catch {
          $exitCode = 1
          $output = $_.Exception.Message
        }
        if ($exitCode -eq 0) {
          Add-AuditFinding -Findings $findings -Severity 'info' -Category 'behavioral_ok' -Component $scenarioName `
            -Message ("Scenario {0} passed." -f $scenarioName) `
            -Recommendation 'No action required.'
        } else {
          $outSnippet = Limit-AuditText -Value ([string]$output) -MaxChars 400
          Add-AuditFinding -Findings $findings -Severity 'critical' -Category 'broken_feature' -Component $scenarioName `
            -Message ("Scenario {0} failed (exit {1}). Output: {2}" -f $scenarioName, $exitCode, $outSnippet) `
            -Recommendation 'Run tools\scenario.ps1 -Name <scenario> manually to reproduce and inspect control\scenario-results.jsonl.'
        }
      }
    }
  }

  return (New-AuditResult -Findings $findings)
}

function New-AuditResult {
  param([System.Collections.Generic.List[object]]$Findings)
  $summary = [ordered]@{
    critical = 0
    warning = 0
    info = 0
  }
  foreach ($finding in @($Findings.ToArray())) {
    $severity = ''
    if ($finding -is [System.Collections.IDictionary]) { $severity = [string]$finding['severity'] }
    else { $severity = [string](Get-AuditObjectProperty -InputObject $finding -Name 'severity') }
    $severity = $severity.ToLowerInvariant()
    if (-not $summary.Contains($severity)) { continue }
    $summary[$severity] = [int]$summary[$severity] + 1
  }
  return [ordered]@{
    findings = @($Findings.ToArray())
    summary = $summary
  }
}
