Set-StrictMode -Version Latest

function Invoke-SecurityAudit {
  param(
    [string]$BridgePath,
    [string]$TargetRoot = $null,
    [string]$AuditKind = 'bridge'
  )

  $results = @{
    findings = @()
    summary = @{
      critical = 0
      warning = 0
      info = 0
    }
  }

  function Add-Finding {
    param(
      [ValidateSet('critical','warning','info')][string]$Severity,
      [string]$Category,
      [string]$File,
      [int]$Line,
      [string]$Message
    )
    $results.findings += @{
      severity = $Severity
      category = $Category
      file = $File
      line = $Line
      message = $Message
    }
    $results.summary[$Severity] = [int]$results.summary[$Severity] + 1
  }

  function Get-FullPathSafe {
    param([string]$Path)
    try { return [System.IO.Path]::GetFullPath($Path) } catch { return $null }
  }

  function Get-RelativePath {
    param(
      [string]$Root,
      [string]$Path
    )
    $full = Get-FullPathSafe $Path
    if (-not $full) { return $Path }
    if ($full.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $full.Substring($Root.Length).TrimStart('\','/')
    }
    return $full
  }

  function Get-TextLines {
    param([string]$Path)
    try { return [System.IO.File]::ReadAllLines($Path) } catch { return @() }
  }

  function Get-TextRaw {
    param([string]$Path)
    try { return [System.IO.File]::ReadAllText($Path) } catch { return '' }
  }

  function Test-UserSuppliedContext {
    param(
      [string[]]$Lines,
      [int]$Index,
      [int]$Radius = 3
    )
    $start = [Math]::Max(0, $Index - $Radius)
    $end = [Math]::Min($Lines.Count - 1, $Index + $Radius)
    if ($end -lt $start) { return $false }
    $context = ($Lines[$start..$end] -join "`n")
    return ($context -match '(\$req\.|\$request\.|\$ctx\.Request|\$body\.|\$params\.|\$query\.|Get-Q\b|Get-Body\b|Url\.|QueryString|InputStream)')
  }

  function Test-PathValidationContext {
    param(
      [string[]]$Lines,
      [int]$Index
    )
    $start = [Math]::Max(0, $Index - 8)
    $end = [Math]::Min($Lines.Count - 1, $Index + 2)
    if ($end -lt $start) { return $false }
    $context = ($Lines[$start..$end] -join "`n")
    return ($context -match '\[System\.IO\.Path\]::GetFullPath|\[IO\.Path\]::GetFullPath|::GetFullPath' -and $context -match 'StartsWith\s*\(\s*\$BridgePath|StartsWith\s*\(\s*\$root|StartsWith\s*\(\s*\$repo|StartsWith\s*\(')
  }

  function Test-ExcludedAuditPath {
    param(
      [string]$Root,
      [string]$Path
    )
    $relative = Get-RelativePath -Root $Root -Path $Path
    return ($relative -match '^(?:\.git|worktrees|node_modules|\.venv|venv|tmp|temp|logs|artifacts)[\\/]')
  }

  function Get-PowerShellAst {
    param([string]$Path)
    try {
      $tokens = $null
      $parseErrors = $null
      return [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    } catch {
      return $null
    }
  }

  function Test-SecretName {
    param([string]$Name)
    return ([string]$Name -match '(?i)(key|token|password|passwd|secret|api[-_]?key|apikey|credential)')
  }

  function Test-SecretLiteralValue {
    param([object]$Value)
    if ($null -eq $Value) { return $false }
    $text = [string]$Value
    return ($text -match '^[A-Za-z0-9_\-]{10,}$')
  }

  function Get-StaticStringValue {
    param([object]$Ast)
    if ($null -eq $Ast) { return $null }
    if ($Ast -is [System.Management.Automation.Language.CommandExpressionAst]) {
      return Get-StaticStringValue -Ast $Ast.Expression
    }
    if ($Ast -is [System.Management.Automation.Language.ParenExpressionAst]) {
      return Get-StaticStringValue -Ast $Ast.Pipeline
    }
    if ($Ast -is [System.Management.Automation.Language.PipelineAst] -and @($Ast.PipelineElements).Count -eq 1) {
      return Get-StaticStringValue -Ast @($Ast.PipelineElements)[0]
    }
    if ($Ast -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
      return [string]$Ast.Value
    }
    if ($Ast -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
      if (@($Ast.NestedExpressions).Count -eq 0) { return [string]$Ast.Value }
    }
    return $null
  }

  function Get-AssignmentName {
    param([object]$LeftAst)
    if ($null -eq $LeftAst) { return '' }
    if ($LeftAst -is [System.Management.Automation.Language.VariableExpressionAst]) {
      return [string]$LeftAst.VariablePath.UserPath
    }
    return ([string]$LeftAst.Extent.Text).Trim().TrimStart('$')
  }

  function Add-AstSecurityFindings {
    param(
      [object]$Ast,
      [string[]]$Lines,
      [string]$RelativePath,
      [string]$FileName
    )
    if ($null -eq $Ast) { return }

    $dynamicCommands = @($Ast.FindAll({
      param($node)
      if (-not ($node -is [System.Management.Automation.Language.CommandAst])) { return $false }
      $name = [string]$node.GetCommandName()
      return ($name -match '^(?i:Invoke-Expression|iex)$')
    }, $true))
    foreach ($cmd in $dynamicCommands) {
      $lineNumber = [int]$cmd.Extent.StartLineNumber
      $source = if (Test-UserSuppliedContext -Lines $Lines -Index ($lineNumber - 1)) { ' user-supplied request data appears nearby' } else { '' }
      Add-Finding -Severity critical -Category 'command-injection' -File $RelativePath -Line $lineNumber -Message "Dynamic command execution via Invoke-Expression/iex.${source}"
    }

    if ($FileName -in @('secrets.json','.gitignore')) { return }

    $assignments = @($Ast.FindAll({
      param($node)
      return ($node -is [System.Management.Automation.Language.AssignmentStatementAst])
    }, $true))
    foreach ($assignment in $assignments) {
      $name = Get-AssignmentName -LeftAst $assignment.Left
      $value = Get-StaticStringValue -Ast $assignment.Right
      if ((Test-SecretName -Name $name) -and (Test-SecretLiteralValue -Value $value)) {
        Add-Finding -Severity critical -Category 'hardcoded-credentials' -File $RelativePath -Line ([int]$assignment.Extent.StartLineNumber) -Message 'Possible hardcoded credential in PowerShell source.'
      }
    }

    $hashtables = @($Ast.FindAll({
      param($node)
      return ($node -is [System.Management.Automation.Language.HashtableAst])
    }, $true))
    foreach ($hashtable in $hashtables) {
      foreach ($pair in @($hashtable.KeyValuePairs)) {
        $key = Get-StaticStringValue -Ast $pair.Item1
        if ([string]::IsNullOrWhiteSpace($key)) { $key = ([string]$pair.Item1.Extent.Text).Trim().Trim("'`"") }
        $value = Get-StaticStringValue -Ast $pair.Item2
        if ((Test-SecretName -Name $key) -and (Test-SecretLiteralValue -Value $value)) {
          Add-Finding -Severity critical -Category 'hardcoded-credentials' -File $RelativePath -Line ([int]$pair.Item1.Extent.StartLineNumber) -Message 'Possible hardcoded credential in PowerShell source.'
        }
      }
    }
  }

  if ([string]$AuditKind -eq 'project' -and [string]::IsNullOrWhiteSpace($TargetRoot)) {
    Add-Finding -Severity critical -Category 'configuration' -File '' -Line 0 -Message 'Project audit target root is empty.'
    Write-Host "Security scan: $($results.summary.critical) critical, $($results.summary.warning) warning, $($results.summary.info) info"
    return $results
  }

  $bridgeRoot = if ([string]::IsNullOrWhiteSpace($BridgePath)) { (Get-Location).Path } else { $BridgePath }
  $root = if ([string]::IsNullOrWhiteSpace($TargetRoot)) { $bridgeRoot } else { $TargetRoot }
  $bridgeFull = Get-FullPathSafe $bridgeRoot
  $selfWhitelist = @(
    'tools\audit-security.ps1',
    'tools\wave-a-helper-tests.ps1',
    'tools\wave-b-tests.ps1',
    'tools\wave-c-tests.ps1'
  )
  $root = Get-FullPathSafe $root
  if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
    Add-Finding -Severity critical -Category 'configuration' -File '' -Line 0 -Message "Audit target root does not exist: $TargetRoot"
    Write-Host "Security scan: $($results.summary.critical) critical, $($results.summary.warning) warning, $($results.summary.info) info"
    return $results
  }
  $root = $root.TrimEnd('\','/')
  if ($bridgeFull) { $bridgeFull = $bridgeFull.TrimEnd('\','/') }
  $isBridgeScan = ([string]$AuditKind -eq 'bridge' -or ($bridgeFull -and [string]::Equals($root, $bridgeFull, [System.StringComparison]::OrdinalIgnoreCase)))

  $psFiles = @()
  try {
    $psFiles = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1' -ErrorAction SilentlyContinue |
      Where-Object { -not (Test-ExcludedAuditPath -Root $root -Path $_.FullName) })
  } catch {
    $psFiles = @()
  }

  $contentByPath = @{}
  $linesByPath = @{}
  foreach ($file in $psFiles) {
    $linesByPath[$file.FullName] = @(Get-TextLines $file.FullName)
    $contentByPath[$file.FullName] = [string](Get-TextRaw $file.FullName)
  }

  foreach ($file in $psFiles) {
    $relative = Get-RelativePath -Root $root -Path $file.FullName
    if ($isBridgeScan -and $selfWhitelist -contains $relative) { continue }
    $lines = @($linesByPath[$file.FullName])
    $raw = [string]$contentByPath[$file.FullName]
    $ast = Get-PowerShellAst -Path $file.FullName

    try {
      $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
      $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
      if (-not $hasBom) {
        Add-Finding -Severity warning -Category 'bom' -File $relative -Line 1 -Message 'PowerShell file is missing UTF-8 BOM; Windows PowerShell 5.1 can break on non-ASCII text.'
      }
    } catch {}

    Add-AstSecurityFindings -Ast $ast -Lines $lines -RelativePath $relative -FileName ([System.IO.Path]::GetFileName($file.FullName))

    for ($i = 0; $i -lt $lines.Count; $i++) {
      $line = [string]$lines[$i]
      $lineNumber = $i + 1

      if ($line -match '&\s*"\s*\$[A-Za-z_][A-Za-z0-9_:.]*\s*"') {
        Add-Finding -Severity critical -Category 'command-injection' -File $relative -Line $lineNumber -Message 'Call operator executes a variable-derived command path.'
      }

      if ($line -match '`\$command|`"\s*\$command|"\s*\$command\s*"') {
        if (Test-UserSuppliedContext -Lines $lines -Index $i) {
          Add-Finding -Severity critical -Category 'command-injection' -File $relative -Line $lineNumber -Message 'Command string from request context appears to reach shell execution.'
        }
      }

      if ($line -match '(?i)\bStart-Process\b' -and (Test-UserSuppliedContext -Lines $lines -Index $i -Radius 4)) {
        Add-Finding -Severity critical -Category 'command-injection' -File $relative -Line $lineNumber -Message 'Start-Process is used with request-derived data in the surrounding block.'
      }

      if ($line -match '(?i)\b(Get-Content|Set-Content)\b|\[System\.IO\.File\]::ReadAllText|\[IO\.File\]::ReadAllText') {
        $safeStaticServerRead = ($relative -eq 'server.ps1' -and $line -match '(?i)\bGet-Content\b' -and $line -match '(?i)-LiteralPath\s+\$indexPath\b')
        if ((Test-UserSuppliedContext -Lines $lines -Index $i -Radius 5) -and -not (Test-PathValidationContext -Lines $lines -Index $i) -and -not $safeStaticServerRead) {
          Add-Finding -Severity critical -Category 'path-traversal' -File $relative -Line $lineNumber -Message 'File read/write uses request-derived path without nearby GetFullPath and root StartsWith validation.'
        }
      }

      if ($line -match '(?i)\bConvertTo-Json\b' -and $line -notmatch '(?i)-Depth\b') {
        Add-Finding -Severity warning -Category 'unsafe-json' -File $relative -Line $lineNumber -Message 'ConvertTo-Json is used without -Depth; default depth can truncate nested data.'
      }

      if ($line -match '(?i)\bAdd-Content\b' -and $line -match '\.jsonl\b' -and $line -notmatch '(?i)-Encoding\s+UTF8') {
        Add-Finding -Severity warning -Category 'unsafe-json' -File $relative -Line $lineNumber -Message 'Add-Content writes .jsonl without explicit -Encoding UTF8.'
      }

      if ($relative -ne 'server.ps1') { continue }

      if ($line -match '(?i)\$request\.Url\.PathAndQuery\s+-match\s+[''"]/api/|PathAndQuery.*?/api/|\b/api/[A-Za-z0-9_/\-{}]*') {
        $end = [Math]::Min($lines.Count - 1, $i + 40)
        $context = if ($end -ge $i) { ($lines[$i..$end] -join "`n") } else { $line }
        if ($context -notmatch '(?i)\b(Test-Auth|Assert-Auth|Require-Auth|Authenticate|Authorization|authToken|authPassword)\b') {
          $handlerStart = [Math]::Max(0, $i - 5)
          $handlerEnd = [Math]::Min($lines.Count - 1, $i + 5)
          $handlerContext = if ($handlerEnd -ge $handlerStart) { ($lines[$handlerStart..$handlerEnd] -join "`n") } else { $line }
          if ($handlerContext -notmatch '(\$method\s*-eq|\$path\s*-eq)') { continue }
          Add-Finding -Severity critical -Category 'authentication-bypass' -File $relative -Line $lineNumber -Message 'API route block does not include an obvious authentication check.'
        }
      }
    }

    if ($raw -match '(?is)\$mutex\.WaitOne\s*\([^)]*\)(?!.*?finally\s*\{.*?\$mutex\.ReleaseMutex\s*\()') {
      $m = [regex]::Match($raw, '(?is)\$mutex\.WaitOne\s*\(')
      $line = if ($m.Success) { ($raw.Substring(0, $m.Index) -split "`r?`n").Count } else { 1 }
      Add-Finding -Severity warning -Category 'abandoned-mutex' -File $relative -Line $line -Message 'Mutex WaitOne appears without a nearby finally block that releases it.'
    }

    if ($raw -match '(?is)\[Threading\.Mutex\]::new|\[System\.Threading\.Mutex\]::new') {
      if ($raw -notmatch '(?is)finally\s*\{.*?ReleaseMutex\s*\(') {
        $m = [regex]::Match($raw, '(?is)\[Threading\.Mutex\]::new|\[System\.Threading\.Mutex\]::new')
        $line = if ($m.Success) { ($raw.Substring(0, $m.Index) -split "`r?`n").Count } else { 1 }
        Add-Finding -Severity warning -Category 'abandoned-mutex' -File $relative -Line $line -Message 'Mutex is created without an obvious ReleaseMutex call in finally.'
      }
    }
  }

  $functionDefs = @()
  foreach ($file in $psFiles) {
    foreach ($fn in [regex]::Matches([string]$contentByPath[$file.FullName], '(?im)^\s*function\s+([A-Za-z_][A-Za-z0-9_-]*)\b')) {
      $functionDefs += @{
        name = $fn.Groups[1].Value
        file = $file.FullName
        line = (($contentByPath[$file.FullName].Substring(0, $fn.Index) -split "`r?`n").Count)
      }
    }
  }

  $allPsBuilder = [System.Text.StringBuilder]::new()
  foreach ($file in $psFiles) {
    [void]$allPsBuilder.AppendLine([string]$contentByPath[$file.FullName])
  }
  $allPsText = $allPsBuilder.ToString()
  $identifierCounts = @{}
  foreach ($m in [regex]::Matches($allPsText, '(?<![\w-])([A-Za-z_][A-Za-z0-9_-]*)(?![\w-])')) {
    $identifier = $m.Groups[1].Value
    if ($identifierCounts.ContainsKey($identifier)) {
      $identifierCounts[$identifier] = [int]$identifierCounts[$identifier] + 1
    } else {
      $identifierCounts[$identifier] = 1
    }
  }
  $exportedNames = @{}
  foreach ($m in [regex]::Matches($allPsText, '(?im)\bExport-ModuleMember\b[^\r\n]*-Function\s+([A-Za-z0-9_\-\*, ]+)')) {
    foreach ($part in ($m.Groups[1].Value -split '[,\s]+')) {
      if (-not [string]::IsNullOrWhiteSpace($part)) { $exportedNames[$part.Trim()] = $true }
    }
  }
  $entryPointNames = @(
    'main','Invoke-Main','Start-Bridge','Stop-Bridge','Invoke-SecurityAudit',
    'Test-Auth','Send-Json','Send-Text','Get-Q','Read-BodyJson'
  )

  foreach ($fn in $functionDefs) {
    $name = [string]$fn.name
    if ($entryPointNames -contains $name -or $exportedNames.ContainsKey($name) -or $exportedNames.ContainsKey('*')) { continue }
    $count = if ($identifierCounts.ContainsKey($name)) { [int]$identifierCounts[$name] } else { 0 }
    $keepAlive = @(
      'Invoke-CanaryRun', 'Save-StateSnapshot', 'Recover-ZombieJobs',
      'Activate-Doctor', 'Test-CoderClaims', 'Test-CliFlagsInDiff',
      'Test-Auth', 'Send-Json', 'Send-Text', 'Get-Q', 'Read-BodyJson',
      'Wait-BridgeIdle', 'Wait-AgentProcess', 'Format-Transcript'
    )
    if ($keepAlive -contains $name) { continue }
    if ($name -like 'Test-*') { continue }
    $fileRel = (Get-RelativePath -Root $root -Path $fn.file)
    if ($fileRel -match '^lib[\\/]doctor\.ps1$') { continue }
    if ($count -le 1) {
      Add-Finding -Severity info -Category 'dead-function' -File (Get-RelativePath -Root $root -Path $fn.file) -Line ([int]$fn.line) -Message "Function '$name' appears to have no call sites."
    }
  }

  $referenceFiles = @()
  foreach ($name in @('driver.ps1','server.ps1','supervisor.ps1')) {
    $path = Join-Path $root $name
    if (Test-Path -LiteralPath $path -PathType Leaf) { $referenceFiles += $path }
  }
  $webIndex = Join-Path $root 'web\index.html'
  if (Test-Path -LiteralPath $webIndex -PathType Leaf) { $referenceFiles += $webIndex }
  $referenceText = ''
  foreach ($path in $referenceFiles) {
    $referenceText += "`n" + (Get-TextRaw $path)
  }

  $toolsPath = Join-Path $root 'tools'
  if (Test-Path -LiteralPath $toolsPath -PathType Container) {
    $toolFiles = @(Get-ChildItem -LiteralPath $toolsPath -File -Filter '*.ps1' -ErrorAction SilentlyContinue)
    foreach ($tool in $toolFiles) {
      $rel = Get-RelativePath -Root $root -Path $tool.FullName
      $slashRel = $rel -replace '\\','/'
      $name = [System.IO.Path]::GetFileName($tool.FullName)
      if ($referenceText -notmatch [regex]::Escape($rel) -and
          $referenceText -notmatch [regex]::Escape($slashRel) -and
          $referenceText -notmatch [regex]::Escape($name)) {
        Add-Finding -Severity info -Category 'orphaned-file' -File $rel -Line 1 -Message 'Tool script is not referenced by driver.ps1, server.ps1, supervisor.ps1, or web/index.html.'
      }
    }
  }

  Write-Host "Security scan: $($results.summary.critical) critical, $($results.summary.warning) warning, $($results.summary.info) info"
  return $results
}

try { Export-ModuleMember -Function Invoke-SecurityAudit -ErrorAction SilentlyContinue } catch {}
