# tools/wiring-audit.ps1 -- Read-only static AST wiring audit for bridge. WA1: load graph.
param(
  [string]$BridgeRoot = '',
  [switch]$Json,
  [switch]$WarningOnly = $true
)

$ErrorActionPreference = 'Stop'

function ConvertTo-WiringRelative {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  $comparison = [System.StringComparison]::OrdinalIgnoreCase
  if (-not $fullPath.StartsWith($fullRoot, $comparison)) {
    return ($fullPath -replace '\\', '/')
  }

  $relative = $fullPath.Substring($fullRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
  return ($relative -replace '\\', '/')
}

function Test-WiringExcludedPath {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $relative = ConvertTo-WiringRelative -Path $Path -Root $Root
  $parts = @($relative -split '/')
  return ($parts -contains '.git' -or $parts -contains 'memory' -or $parts -contains 'worktrees')
}

function Resolve-WiringPath {
  param(
    [AllowNull()][string]$Raw,
    [Parameter(Mandatory = $true)][string]$BaseDir,
    [Parameter(Mandatory = $true)][string]$Root
  )

  if ([string]::IsNullOrWhiteSpace($Raw)) {
    return $null
  }

  $candidate = $Raw.Trim()
  if (($candidate.StartsWith('"') -and $candidate.EndsWith('"')) -or ($candidate.StartsWith("'") -and $candidate.EndsWith("'"))) {
    $candidate = $candidate.Substring(1, $candidate.Length - 2)
  }

  try {
    if ([System.IO.Path]::IsPathRooted($candidate)) {
      $full = [System.IO.Path]::GetFullPath($candidate)
    } else {
      $full = [System.IO.Path]::GetFullPath((Join-Path $BaseDir $candidate))
    }
  } catch {
    return $null
  }

  if (-not (Test-Path -LiteralPath $full)) {
    return $null
  }

  $item = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
  if ($null -eq $item -or $item.PSIsContainer) {
    return $null
  }

  return ConvertTo-WiringRelative -Path $item.FullName -Root $Root
}

function ConvertFrom-WiringStringAst {
  param([AllowNull()][object]$Ast)

  if ($null -eq $Ast) { return $null }

  if ($Ast -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
    return [string]$Ast.Value
  }

  if ($Ast -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
    if (@($Ast.NestedExpressions).Count -eq 0) {
      return [string]$Ast.Value
    }
  }

  return $null
}

function ConvertFrom-WiringPathAst {
  param(
    [AllowNull()][object]$Ast,
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$Root
  )

  if ($null -eq $Ast) { return $null }

  $literal = ConvertFrom-WiringStringAst -Ast $Ast
  if ($null -ne $literal) { return $literal }

  if ($Ast -is [System.Management.Automation.Language.VariableExpressionAst]) {
    $name = $Ast.VariablePath.UserPath
    if ($name -eq 'PSScriptRoot') { return $SourceDir }
    if ($name -eq 'root' -or $name -eq 'BridgeRoot') { return $Root }
    if ($name -eq 'PWD') { return $Root }
    return $null
  }

  if ($Ast -is [System.Management.Automation.Language.CommandExpressionAst]) {
    return ConvertFrom-WiringPathAst -Ast $Ast.Expression -SourceDir $SourceDir -Root $Root
  }

  if ($Ast -is [System.Management.Automation.Language.ParenExpressionAst]) {
    return ConvertFrom-WiringPipelinePathAst -PipelineAst $Ast.Pipeline -SourceDir $SourceDir -Root $Root
  }

  if ($Ast -is [System.Management.Automation.Language.ConvertExpressionAst]) {
    return ConvertFrom-WiringPathAst -Ast $Ast.Child -SourceDir $SourceDir -Root $Root
  }

  return $null
}

function ConvertFrom-WiringPipelinePathAst {
  param(
    [AllowNull()][object]$PipelineAst,
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$Root
  )

  if ($null -eq $PipelineAst) { return $null }

  $elements = @($PipelineAst.PipelineElements)
  if ($elements.Count -ne 1) { return $null }

  $element = $elements[0]
  if ($element -is [System.Management.Automation.Language.CommandExpressionAst]) {
    return ConvertFrom-WiringPathAst -Ast $element.Expression -SourceDir $SourceDir -Root $Root
  }

  if ($element -is [System.Management.Automation.Language.CommandAst]) {
    return ConvertFrom-WiringCommandPathAst -CommandAst $element -SourceDir $SourceDir -Root $Root
  }

  return $null
}

function Get-WiringCommandArgumentValue {
  param(
    [Parameter(Mandatory = $true)][object[]]$Elements,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$Root
  )

  for ($i = 1; $i -lt $Elements.Count; $i++) {
    $element = $Elements[$i]
    if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -eq $Name) {
      if ($null -ne $element.Argument) {
        return ConvertFrom-WiringPathAst -Ast $element.Argument -SourceDir $SourceDir -Root $Root
      }
      if (($i + 1) -lt $Elements.Count) {
        return ConvertFrom-WiringPathAst -Ast $Elements[$i + 1] -SourceDir $SourceDir -Root $Root
      }
    }
  }

  return $null
}

function Get-WiringPositionalArguments {
  param([Parameter(Mandatory = $true)][object[]]$Elements)

  $items = New-Object System.Collections.Generic.List[object]
  for ($i = 1; $i -lt $Elements.Count; $i++) {
    $element = $Elements[$i]
    if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
      if ($null -ne $element.Argument) {
        continue
      }
      if (($i + 1) -lt $Elements.Count -and -not ($Elements[$i + 1] -is [System.Management.Automation.Language.CommandParameterAst])) {
        $i++
      }
      continue
    }
    $items.Add($element)
  }

  return @($items.ToArray())
}

function ConvertFrom-WiringCommandPathAst {
  param(
    [Parameter(Mandatory = $true)][System.Management.Automation.Language.CommandAst]$CommandAst,
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $commandName = $CommandAst.GetCommandName()
  if ($commandName -ne 'Join-Path') {
    return $null
  }

  $elements = @($CommandAst.CommandElements)
  $path = Get-WiringCommandArgumentValue -Elements $elements -Name 'Path' -SourceDir $SourceDir -Root $Root
  $childPath = Get-WiringCommandArgumentValue -Elements $elements -Name 'ChildPath' -SourceDir $SourceDir -Root $Root

  $positional = @(Get-WiringPositionalArguments -Elements $elements)
  if ($null -eq $path -and $positional.Count -ge 1) {
    $path = ConvertFrom-WiringPathAst -Ast $positional[0] -SourceDir $SourceDir -Root $Root
  }
  if ($null -eq $childPath -and $positional.Count -ge 2) {
    $childPath = ConvertFrom-WiringPathAst -Ast $positional[1] -SourceDir $SourceDir -Root $Root
  }

  if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($childPath)) {
    return $null
  }

  try {
    return [System.IO.Path]::Combine($path, $childPath)
  } catch {
    return $null
  }
}

function New-WiringLoadEdge {
  param(
    [Parameter(Mandatory = $true)][string]$From,
    [AllowNull()][string]$To,
    [AllowNull()][string]$ToRaw,
    [Parameter(Mandatory = $true)][string]$Kind,
    [Parameter(Mandatory = $true)][int]$Line
  )

  return [pscustomobject][ordered]@{
    from = $From
    to = $To
    to_raw = $ToRaw
    kind = $Kind
    line = $Line
  }
}

function Get-DotSourceEdges {
  param(
    [Parameter(Mandatory = $true)]$Ast,
    [Parameter(Mandatory = $true)][string]$SourceFile,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $sourceDir = Split-Path -Parent $SourceFile
  $from = ConvertTo-WiringRelative -Path $SourceFile -Root $Root
  $commands = $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
  $edges = New-Object System.Collections.Generic.List[object]

  foreach ($command in @($commands)) {
    if ($command.InvocationOperator -ne [System.Management.Automation.Language.TokenKind]::Dot) {
      continue
    }

    $elements = @($command.CommandElements)
    if ($elements.Count -lt 1) {
      continue
    }
    if ($elements[0] -is [System.Management.Automation.Language.VariableExpressionAst]) {
      continue
    }

    $raw = ConvertFrom-WiringPathAst -Ast $elements[0] -SourceDir $sourceDir -Root $Root
    if ([string]::IsNullOrWhiteSpace($raw)) {
      $raw = $elements[0].Extent.Text
    }
    $to = Resolve-WiringPath -Raw $raw -BaseDir $sourceDir -Root $Root
    $edges.Add((New-WiringLoadEdge -From $from -To $to -ToRaw $raw -Kind 'dot_source' -Line $command.Extent.StartLineNumber))
  }

  return @($edges.ToArray())
}

function Test-WiringFileLikeModuleName {
  param([AllowNull()][string]$Name)

  if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
  return ($Name -match '\.psm1$' -or $Name -match '\.psd1$' -or $Name -match '[\\/]')
}

function Get-ImportModuleNameAst {
  param([Parameter(Mandatory = $true)][System.Management.Automation.Language.CommandAst]$CommandAst)

  $elements = @($CommandAst.CommandElements)
  for ($i = 1; $i -lt $elements.Count; $i++) {
    $element = $elements[$i]
    if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -eq 'Name') {
      if ($null -ne $element.Argument) { return $element.Argument }
      if (($i + 1) -lt $elements.Count) { return $elements[$i + 1] }
    }
  }

  foreach ($element in @(Get-WiringPositionalArguments -Elements $elements)) {
    return $element
  }

  return $null
}

function Get-ImportModuleEdges {
  param(
    [Parameter(Mandatory = $true)]$Ast,
    [Parameter(Mandatory = $true)][string]$SourceFile,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $sourceDir = Split-Path -Parent $SourceFile
  $from = ConvertTo-WiringRelative -Path $SourceFile -Root $Root
  $commands = $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
  $edges = New-Object System.Collections.Generic.List[object]

  foreach ($command in @($commands)) {
    $name = $command.GetCommandName()
    if ($name -ne 'Import-Module' -and $name -ne 'ipmo') {
      continue
    }

    $nameAst = Get-ImportModuleNameAst -CommandAst $command
    $raw = ConvertFrom-WiringPathAst -Ast $nameAst -SourceDir $sourceDir -Root $Root
    if ([string]::IsNullOrWhiteSpace($raw) -and $null -ne $nameAst) {
      $raw = $nameAst.Extent.Text
    }
    if (-not (Test-WiringFileLikeModuleName -Name $raw)) {
      continue
    }

    $to = Resolve-WiringPath -Raw $raw -BaseDir $sourceDir -Root $Root
    $edges.Add((New-WiringLoadEdge -From $from -To $to -ToRaw $raw -Kind 'import_module' -Line $command.Extent.StartLineNumber))
  }

  return @($edges.ToArray())
}

function Get-WiringFunctionDefinitions {
  param(
    [Parameter(Mandatory = $true)]$Ast,
    [Parameter(Mandatory = $true)][string]$SourceFile,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $from = ConvertTo-WiringRelative -Path $SourceFile -Root $Root
  $defs = New-Object System.Collections.Generic.List[object]
  $functions = $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)

  foreach ($function in @($functions)) {
    $defs.Add([pscustomobject][ordered]@{
      file = $from
      name = $function.Name
      line = $function.Extent.StartLineNumber
    })
  }

  return @($defs.ToArray())
}

function Get-WiringAllCommandCalls {
  param(
    [Parameter(Mandatory = $true)]$Ast,
    [Parameter(Mandatory = $true)][string]$SourceFile,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $from = ConvertTo-WiringRelative -Path $SourceFile -Root $Root
  $calls = New-Object System.Collections.Generic.List[object]
  $commands = $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)

  foreach ($command in @($commands)) {
    if ($command.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot) {
      continue
    }

    $name = $command.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($name)) {
      continue
    }

    $calls.Add([pscustomobject][ordered]@{
      from = $from
      callee = $name
      line = $command.Extent.StartLineNumber
    })
  }

  return @($calls.ToArray())
}

function Get-WiringDynamicDispatchSites {
  param(
    [Parameter(Mandatory = $true)]$Ast,
    [Parameter(Mandatory = $true)][string]$SourceFile,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $from = ConvertTo-WiringRelative -Path $SourceFile -Root $Root
  $sites = New-Object System.Collections.Generic.List[object]
  $commands = $Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)

  foreach ($command in @($commands)) {
    $elements = @($command.CommandElements)
    $form = $null

    if ($elements.Count -gt 0 -and $elements[0] -is [System.Management.Automation.Language.VariableExpressionAst]) {
      if ($command.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand) {
        $form = '& $var'
      } elseif ($command.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Dot) {
        $form = '. $var'
      }
    }

    $name = $command.GetCommandName()
    if ($null -eq $form -and ($name -eq 'Invoke-Expression' -or $name -eq 'iex')) {
      $form = 'Invoke-Expression'
    }

    if ($null -eq $form) {
      continue
    }

    $sites.Add([pscustomobject][ordered]@{
      file = $from
      form = $form
      line = $command.Extent.StartLineNumber
    })
  }

  return @($sites.ToArray())
}

function Get-WiringLoadedFileClassifications {
  param(
    [Parameter(Mandatory = $true)][object[]]$LoadEdges,
    [Parameter(Mandatory = $true)][object[]]$FunctionDefs,
    [Parameter(Mandatory = $true)][object[]]$StaticCallSites
  )

  $loadedFiles = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($edge in @($LoadEdges)) {
    if (-not [string]::IsNullOrWhiteSpace($edge.to)) {
      [void]$loadedFiles.Add([string]$edge.to)
    }
  }

  $calledFunctions = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($site in @($StaticCallSites)) {
    if (-not [string]::IsNullOrWhiteSpace($site.callee)) {
      [void]$calledFunctions.Add([string]$site.callee)
    }
  }

  $classifications = New-Object System.Collections.Generic.List[object]
  foreach ($loadedFile in @($loadedFiles | Sort-Object)) {
    $fileFunctions = @($FunctionDefs | Where-Object { $_.file -eq $loadedFile } | ForEach-Object { $_.name })
    $isUsed = $false
    foreach ($functionName in $fileFunctions) {
      if ($calledFunctions.Contains([string]$functionName)) {
        $isUsed = $true
        break
      }
    }

    $classification = if ($isUsed) { 'USED' } else { 'LOADED_ONLY' }
    $classifications.Add([pscustomobject][ordered]@{
      file = $loadedFile
      classification = $classification
    })
  }

  return @($classifications.ToArray())
}

function Get-WiringVerifyCoversMap {
  param(
    [Parameter(Mandatory = $true)][string]$Root
  )

  $map = @{}
  $toolsDir = Join-Path $Root 'tools'
  if (-not (Test-Path -LiteralPath $toolsDir)) { return $map }

  $testFiles = @(Get-ChildItem -LiteralPath $toolsDir -Filter 'test-*.ps1' -File -ErrorAction SilentlyContinue |
    Sort-Object Name)

  foreach ($tf in $testFiles) {
    $tfRel = ConvertTo-WiringRelative -Path $tf.FullName -Root $Root
    $lines = [System.IO.File]::ReadAllLines($tf.FullName)
    foreach ($line in $lines) {
      if ($line -match '^\s*#\s*VERIFY-COVERS:\s*(.+)$') {
        $raw = $Matches[1].Trim()
        $resolved = Resolve-WiringPath -Raw $raw -BaseDir $toolsDir -Root $Root
        if ([string]::IsNullOrWhiteSpace($resolved)) { $resolved = ($raw -replace '\\', '/') }
        $key = $resolved.ToLowerInvariant()
        if (-not $map.ContainsKey($key)) { $map[$key] = [System.Collections.Generic.List[string]]::new() }
        if (-not $map[$key].Contains($tfRel)) { $map[$key].Add($tfRel) }
      }
    }
  }

  foreach ($k in @($map.Keys)) {
    $map[$k] = @($map[$k] | Sort-Object)
  }
  return $map
}

function Get-WiringTestNameCoverageMap {
  param(
    [Parameter(Mandatory = $true)][string[]]$FunctionNames,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $map = @{}
  $toolsDir = Join-Path $Root 'tools'
  if (-not (Test-Path -LiteralPath $toolsDir) -or $FunctionNames.Count -eq 0) { return $map }

  $testFiles = @(Get-ChildItem -LiteralPath $toolsDir -Filter 'test-*.ps1' -File -ErrorAction SilentlyContinue |
    Sort-Object Name)

  $nameSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($n in $FunctionNames) { [void]$nameSet.Add($n) }

  $tokenRegex = [regex]'[A-Za-z_][A-Za-z0-9_-]*'
  foreach ($tf in $testFiles) {
    $tfRel = ConvertTo-WiringRelative -Path $tf.FullName -Root $Root
    $content = [System.IO.File]::ReadAllText($tf.FullName)
    $seenInFile = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($match in $tokenRegex.Matches($content)) {
      $token = [string]$match.Value
      if ($nameSet.Contains($token) -and $seenInFile.Add($token)) {
        if (-not $map.ContainsKey($token)) { $map[$token] = [System.Collections.Generic.List[string]]::new() }
        if (-not $map[$token].Contains($tfRel)) { $map[$token].Add($tfRel) }
      }
    }
  }

  foreach ($k in @($map.Keys)) {
    $map[$k] = @($map[$k] | Sort-Object)
  }
  return $map
}

function Build-WiringAstGraph {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [switch]$WarningOnly
  )

  $rootFull = [System.IO.Path]::GetFullPath($Root)
  if (-not (Test-Path -LiteralPath $rootFull)) {
    throw "Bridge root does not exist: $Root"
  }

  $files = @(Get-ChildItem -LiteralPath $rootFull -Filter '*.ps1' -Recurse -File -ErrorAction Stop |
    Where-Object { -not (Test-WiringExcludedPath -Path $_.FullName -Root $rootFull) } |
    Sort-Object @{ Expression = { ConvertTo-WiringRelative -Path $_.FullName -Root $rootFull } })

  $scannedFiles = New-Object System.Collections.Generic.List[string]
  $edges = New-Object System.Collections.Generic.List[object]
  $allFnDefs = New-Object System.Collections.Generic.List[object]
  $allCommandCalls = New-Object System.Collections.Generic.List[object]
  $allDynSites = New-Object System.Collections.Generic.List[object]
  $scanErrors = New-Object System.Collections.Generic.List[object]

  foreach ($file in $files) {
    $relative = ConvertTo-WiringRelative -Path $file.FullName -Root $rootFull
    $scannedFiles.Add($relative)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($null -ne $errors -and $errors.Count -gt 0) {
      $message = (@($errors) | ForEach-Object { $_.Message }) -join '; '
      $scanErrors.Add([pscustomobject][ordered]@{
        file = $relative
        error = $message
      })
      continue
    }

    foreach ($edge in @(Get-DotSourceEdges -Ast $ast -SourceFile $file.FullName -Root $rootFull)) {
      $edges.Add($edge)
    }
    foreach ($edge in @(Get-ImportModuleEdges -Ast $ast -SourceFile $file.FullName -Root $rootFull)) {
      $edges.Add($edge)
    }
    foreach ($def in @(Get-WiringFunctionDefinitions -Ast $ast -SourceFile $file.FullName -Root $rootFull)) {
      $allFnDefs.Add($def)
    }
    foreach ($call in @(Get-WiringAllCommandCalls -Ast $ast -SourceFile $file.FullName -Root $rootFull)) {
      $allCommandCalls.Add($call)
    }
    foreach ($dyn in @(Get-WiringDynamicDispatchSites -Ast $ast -SourceFile $file.FullName -Root $rootFull)) {
      $allDynSites.Add($dyn)
    }
  }

  $orderedScanned = @($scannedFiles.ToArray() | Sort-Object)
  $orderedEdges = @($edges.ToArray() | Sort-Object `
    @{ Expression = { $_.from } }, `
    @{ Expression = { if ($null -eq $_.to) { '' } else { $_.to } } }, `
    @{ Expression = { $_.kind } }, `
    @{ Expression = { $_.line } }, `
    @{ Expression = { $_.to_raw } })
  $knownFns = @{}
  foreach ($def in @($allFnDefs.ToArray())) {
    $knownFns[$def.name] = $def.file
  }
  $staticCallSites = @($allCommandCalls.ToArray() | Where-Object { $knownFns.ContainsKey($_.callee) })
  $fileClassifications = Get-WiringLoadedFileClassifications `
    -LoadEdges $orderedEdges `
    -FunctionDefs @($allFnDefs.ToArray()) `
    -StaticCallSites $staticCallSites

  $vcMap = Get-WiringVerifyCoversMap -Root $rootFull
  $allFnNames = @($allFnDefs.ToArray() | ForEach-Object { $_.name } | Sort-Object -Unique)
  $tnMap = Get-WiringTestNameCoverageMap -FunctionNames $allFnNames -Root $rootFull

  $enrichedClassifications = New-Object System.Collections.Generic.List[object]
  foreach ($entry in @($fileClassifications | Sort-Object @{ Expression = { $_.classification } }, @{ Expression = { $_.file } })) {
    $key = ([string]$entry.file).ToLowerInvariant()
    $vcTests = if ($vcMap.ContainsKey($key)) { @($vcMap[$key] | Sort-Object) } else { @() }

    $fileFns = @($allFnDefs.ToArray() |
      Where-Object { $_.file -eq $entry.file } |
      ForEach-Object { $_.name } |
      Sort-Object -Unique)
    $tnTestsSet = New-Object -TypeName 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::Ordinal)
    foreach ($fn in $fileFns) {
      if ($tnMap.ContainsKey($fn)) {
        foreach ($t in $tnMap[$fn]) { [void]$tnTestsSet.Add($t) }
      }
    }
    $tnTests = @($tnTestsSet | Sort-Object)
    $hasCoverage = ($vcTests.Count -gt 0) -or ($tnTests.Count -gt 0)

    $enrichedClassifications.Add([pscustomobject][ordered]@{
      file = $entry.file
      classification = $entry.classification
      coverage_evidence = [pscustomobject][ordered]@{
        verify_covers_tests = $vcTests
        test_name_matches = $tnTests
        has_coverage = $hasCoverage
      }
    })
  }

  $orderedErrors = @($scanErrors.ToArray() | Sort-Object @{ Expression = { $_.file } }, @{ Expression = { $_.error } })

  return [pscustomobject][ordered]@{
    scanned_files = $orderedScanned
    load_edges = $orderedEdges
    function_defs = @($allFnDefs.ToArray() | Sort-Object @{ Expression = { $_.file } }, @{ Expression = { $_.name } }, @{ Expression = { $_.line } })
    static_call_sites = @($staticCallSites | Sort-Object @{ Expression = { $_.from } }, @{ Expression = { $_.callee } }, @{ Expression = { $_.line } })
    dynamic_dispatch_sites = @($allDynSites.ToArray() | Sort-Object @{ Expression = { $_.file } }, @{ Expression = { $_.line } })
    file_classifications = @($enrichedClassifications.ToArray())
    scan_errors = $orderedErrors
  }
}

function Format-WiringAstGraphText {
  param([Parameter(Mandatory = $true)]$Graph)

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('WIRING AUDIT -- Load Graph + Call Analysis')
  $lines.Add(('Scanned: {0} files' -f @($Graph.scanned_files).Count))
  $lines.Add(('Load edges: {0}' -f @($Graph.load_edges).Count))
  $lines.Add(('Function defs: {0}' -f @($Graph.function_defs).Count))
  $lines.Add(('Static call sites (to known fns): {0}' -f @($Graph.static_call_sites).Count))
  $lines.Add(('Dynamic dispatch sites: {0}' -f @($Graph.dynamic_dispatch_sites).Count))
  $lines.Add(('Scan errors: {0}' -f @($Graph.scan_errors).Count))
  $lines.Add('')
  $lines.Add('LOAD EDGES:')
  foreach ($edge in @($Graph.load_edges)) {
    $target = if ([string]::IsNullOrWhiteSpace($edge.to)) { $edge.to_raw } else { $edge.to }
    $lines.Add(('  {0} -> {1} [{2}:{3}]' -f $edge.from, $target, $edge.kind, $edge.line))
  }
  $lines.Add('')
  $used = @($Graph.file_classifications | Where-Object { $_.classification -eq 'USED' })
  $loadedOnly = @($Graph.file_classifications | Where-Object { $_.classification -eq 'LOADED_ONLY' })
  $lines.Add('LOADED-FILE CLASSIFICATION:')
  $lines.Add(('  USED: {0}  LOADED_ONLY: {1}' -f $used.Count, $loadedOnly.Count))
  $lines.Add('')
  $lines.Add('  USED:')
  foreach ($item in $used) {
    $lines.Add(('    {0}' -f $item.file))
    $ev = $item.coverage_evidence
    if ($null -ne $ev -and $ev.has_coverage) {
      if (@($ev.verify_covers_tests).Count -gt 0) {
        $lines.Add(('      coverage/verify-covers: {0}' -f (@($ev.verify_covers_tests) -join ', ')))
      }
      if (@($ev.test_name_matches).Count -gt 0) {
        $lines.Add(('      coverage/test-name: {0}' -f (@($ev.test_name_matches) -join ', ')))
      }
    }
  }
  $lines.Add('')
  $lines.Add('  LOADED_ONLY:')
  foreach ($item in $loadedOnly) {
    $lines.Add(('    {0}' -f $item.file))
    $ev = $item.coverage_evidence
    if ($null -ne $ev) {
      if (@($ev.verify_covers_tests).Count -gt 0) {
        $lines.Add(('      coverage/verify-covers: {0}' -f (@($ev.verify_covers_tests) -join ', ')))
      }
      if (@($ev.test_name_matches).Count -gt 0) {
        $lines.Add(('      coverage/test-name: {0}' -f (@($ev.test_name_matches) -join ', ')))
      }
      if (-not $ev.has_coverage) {
        $lines.Add('      coverage: NONE')
      }
    }
  }
  $lines.Add('')
  $lines.Add(('DYNAMIC DISPATCH EVIDENCE: {0} sites (UNKNOWN_DYNAMIC)' -f @($Graph.dynamic_dispatch_sites).Count))
  foreach ($site in @($Graph.dynamic_dispatch_sites)) {
    $lines.Add(('  {0} [{1}:{2}]' -f $site.file, $site.form, $site.line))
  }
  $lines.Add('')
  $lines.Add('SCAN ERRORS:')
  foreach ($scanError in @($Graph.scan_errors)) {
    $lines.Add(('  {0}: {1}' -f $scanError.file, $scanError.error))
  }

  return ($lines -join [Environment]::NewLine)
}

function Format-WiringAstGraphJson {
  param([Parameter(Mandatory = $true)]$Graph)

  $stable = [pscustomobject][ordered]@{
    scanned_files = @($Graph.scanned_files)
    load_edges = @($Graph.load_edges | ForEach-Object {
      [pscustomobject][ordered]@{
        from = $_.from
        to = $_.to
        to_raw = $_.to_raw
        kind = $_.kind
        line = $_.line
      }
    })
    function_defs = @($Graph.function_defs | ForEach-Object {
      [pscustomobject][ordered]@{
        file = $_.file
        name = $_.name
        line = $_.line
      }
    })
    static_call_sites = @($Graph.static_call_sites | ForEach-Object {
      [pscustomobject][ordered]@{
        from = $_.from
        callee = $_.callee
        line = $_.line
      }
    })
    dynamic_dispatch_sites = @($Graph.dynamic_dispatch_sites | ForEach-Object {
      [pscustomobject][ordered]@{
        file = $_.file
        form = $_.form
        line = $_.line
      }
    })
    file_classifications = @($Graph.file_classifications | ForEach-Object {
      [pscustomobject][ordered]@{
        file = $_.file
        classification = $_.classification
        coverage_evidence = [pscustomobject][ordered]@{
          verify_covers_tests = @($_.coverage_evidence.verify_covers_tests)
          test_name_matches = @($_.coverage_evidence.test_name_matches)
          has_coverage = $_.coverage_evidence.has_coverage
        }
      }
    })
    scan_errors = @($Graph.scan_errors | ForEach-Object {
      [pscustomobject][ordered]@{
        file = $_.file
        error = $_.error
      }
    })
  }

  return ($stable | ConvertTo-Json -Depth 5)
}

if ($MyInvocation.InvocationName -ne '.') {
  $root = if ([string]::IsNullOrWhiteSpace($BridgeRoot)) {
    [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
  } else {
    [System.IO.Path]::GetFullPath($BridgeRoot)
  }

  $graph = Build-WiringAstGraph -Root $root -WarningOnly:$WarningOnly

  if ($Json) {
    Format-WiringAstGraphJson -Graph $graph
  } else {
    Format-WiringAstGraphText -Graph $graph
  }

  if ($WarningOnly) {
    exit 0
  }
}
