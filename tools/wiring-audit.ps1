# tools/wiring-audit.ps1 -- Read-only static AST wiring audit for bridge. WA1: load graph.
param(
  [string]$BridgeRoot = '',
  [switch]$Json
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

function Build-WiringAstGraph {
  param([Parameter(Mandatory = $true)][string]$Root)

  $rootFull = [System.IO.Path]::GetFullPath($Root)
  if (-not (Test-Path -LiteralPath $rootFull)) {
    throw "Bridge root does not exist: $Root"
  }

  $files = @(Get-ChildItem -LiteralPath $rootFull -Filter '*.ps1' -Recurse -File -ErrorAction Stop |
    Where-Object { -not (Test-WiringExcludedPath -Path $_.FullName -Root $rootFull) } |
    Sort-Object @{ Expression = { ConvertTo-WiringRelative -Path $_.FullName -Root $rootFull } })

  $scannedFiles = New-Object System.Collections.Generic.List[string]
  $edges = New-Object System.Collections.Generic.List[object]
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
  }

  $orderedScanned = @($scannedFiles.ToArray() | Sort-Object)
  $orderedEdges = @($edges.ToArray() | Sort-Object `
    @{ Expression = { $_.from } }, `
    @{ Expression = { if ($null -eq $_.to) { '' } else { $_.to } } }, `
    @{ Expression = { $_.kind } }, `
    @{ Expression = { $_.line } }, `
    @{ Expression = { $_.to_raw } })
  $orderedErrors = @($scanErrors.ToArray() | Sort-Object @{ Expression = { $_.file } }, @{ Expression = { $_.error } })

  return [pscustomobject][ordered]@{
    scanned_files = $orderedScanned
    load_edges = $orderedEdges
    scan_errors = $orderedErrors
  }
}

function Format-WiringAstGraphText {
  param([Parameter(Mandatory = $true)]$Graph)

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('WIRING AUDIT -- Load Graph')
  $lines.Add(('Scanned: {0} files' -f @($Graph.scanned_files).Count))
  $lines.Add(('Load edges: {0}' -f @($Graph.load_edges).Count))
  $lines.Add(('Scan errors: {0}' -f @($Graph.scan_errors).Count))
  $lines.Add('')
  $lines.Add('LOAD EDGES:')
  foreach ($edge in @($Graph.load_edges)) {
    $target = if ([string]::IsNullOrWhiteSpace($edge.to)) { $edge.to_raw } else { $edge.to }
    $lines.Add(('  {0} -> {1} [{2}:{3}]' -f $edge.from, $target, $edge.kind, $edge.line))
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

  $graph = Build-WiringAstGraph -Root $root

  if ($Json) {
    Format-WiringAstGraphJson -Graph $graph
  } else {
    Format-WiringAstGraphText -Graph $graph
  }
}
