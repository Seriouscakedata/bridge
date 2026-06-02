# codemem.ps1 -- semantic code memory for per-project PowerShell symbols.
# Dot-sourced after memory.ps1; uses the same embedding and cosine primitives,
# but stores code vectors separately under memory/code/<project>.jsonl.

function Get-ProjectSlug {
  param([string]$Root = '')
  if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Get-BridgeRoot }
  try {
    $full = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $leaf = Split-Path -Leaf $full
  } catch {
    $leaf = [string]$Root
  }
  $slug = ([string]$leaf).ToLowerInvariant() -replace '[^a-z0-9]+','-'
  $slug = $slug.Trim('-')
  if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'bridge' }
  return $slug
}

function Get-CodeMemDir { Join-Path (Get-MemoryDir) 'code' }
function Get-CodeStorePath {
  param([string]$Slug = '')
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = Get-ProjectSlug }
  Join-Path (Get-CodeMemDir) ($Slug + '.jsonl')
}
function Get-CodeManifestPath {
  param([string]$Slug = '')
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = Get-ProjectSlug }
  Join-Path (Get-CodeMemDir) ($Slug + '.manifest.json')
}

function Get-FileSha1 {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  $sha = $null
  try {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $hash = $sha.ComputeHash($bytes)
    return (($hash | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally {
    if ($sha) { $sha.Dispose() }
  }
}

function ConvertTo-CodeRelativePath {
  param([string]$Root, [string]$Path)
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\','/')
  $pathFull = [System.IO.Path]::GetFullPath($Path)
  $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
  if ($pathFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $pathFull.Substring($prefix.Length)
  }
  return [System.IO.Path]::GetFileName($pathFull)
}

function ConvertTo-CodeWords {
  param([string]$Name)
  $s = [string]$Name
  if ([string]::IsNullOrWhiteSpace($s)) { return '' }
  $s = $s -creplace '([a-z0-9])([A-Z])', '$1 $2'
  $s = $s -replace '[-_]+', ' '
  return (($s -replace '\s+', ' ').Trim().ToLowerInvariant())
}

function Get-CodeAstSnippet {
  param($Ast, [int]$MaxChars = 160)
  $text = ''
  try {
    if ($Ast -and $Ast.PSObject.Properties.Name -contains 'Body' -and $Ast.Body) {
      $text = [string]$Ast.Body.Extent.Text
    }
  } catch {}
  if ([string]::IsNullOrWhiteSpace($text)) {
    try { $text = [string]$Ast.Extent.Text } catch { $text = '' }
  }
  $text = ($text -replace '^\s*\{', '' -replace '\}\s*$', '')
  $text = ($text -replace '\s+', ' ').Trim()
  if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars).TrimEnd() + '...' }
  return $text
}

function Get-CodeFunctionSignature {
  param($FunctionAst)
  $names = New-Object 'System.Collections.Generic.List[string]'
  $params = @()
  try { if ($FunctionAst.Parameters) { $params += @($FunctionAst.Parameters) } } catch {}
  try {
    if ($FunctionAst.Body -and $FunctionAst.Body.ParamBlock -and $FunctionAst.Body.ParamBlock.Parameters) {
      $params += @($FunctionAst.Body.ParamBlock.Parameters)
    }
  } catch {}
  foreach ($p in $params) {
    if (-not $p) { continue }
    $n = ''
    try { $n = [string]$p.Name.VariablePath.UserPath } catch {}
    if ([string]::IsNullOrWhiteSpace($n)) { continue }
    $entry = '$' + $n
    if (-not $names.Contains($entry)) { [void]$names.Add($entry) }
  }
  return ([string]$FunctionAst.Name + '(' + ([string]::Join(', ', [string[]]@($names.ToArray()))) + ')')
}

function Get-CodeSymbolsFromFile {
  param([string]$Path, [string]$ProjectRoot)
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
  if ($errors -and $errors.Count -gt 0) {
    throw "Parse errors in $($Path): $($errors.Count)"
  }
  $rel = ConvertTo-CodeRelativePath -Root $ProjectRoot -Path $Path
  $out = New-Object 'System.Collections.Generic.List[object]'

  $funcs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
  foreach ($fn in $funcs) {
    $name = [string]$fn.Name
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $sig = Get-CodeFunctionSignature -FunctionAst $fn
    $line = [int]$fn.Extent.StartLineNumber
    $snippet = Get-CodeAstSnippet -Ast $fn -MaxChars 180
    $words = ConvertTo-CodeWords -Name $name
    $text = "$sig $words - $($rel):$($line). $snippet"
    [void]$out.Add([pscustomobject]@{
      kind = 'function'
      name = $name
      signature = $sig
      file = $rel
      line = $line
      text = $text
    })
  }

  $types = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] }, $true))
  foreach ($type in $types) {
    try { if (-not $type.IsClass) { continue } } catch { continue }
    $name = [string]$type.Name
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $line = [int]$type.Extent.StartLineNumber
    $snippet = Get-CodeAstSnippet -Ast $type -MaxChars 180
    $words = ConvertTo-CodeWords -Name $name
    $sig = "class $name"
    $text = "$sig $words - $($rel):$($line). $snippet"
    [void]$out.Add([pscustomobject]@{
      kind = 'class'
      name = $name
      signature = $sig
      file = $rel
      line = $line
      text = $text
    })
  }

  return @($out.ToArray())
}

function Get-CodeIndexExtensions {
  return @(
    '.ps1','.psm1','.psd1',
    '.js','.jsx','.ts','.tsx',
    '.py','.json','.yaml','.yml',
    '.md','.mdx','.html','.css','.scss',
    '.vue','.svelte','.cs','.java','.go','.rs',
    '.php','.rb','.sql'
  )
}

function Test-CodeIndexPath {
  param([string]$Path, [string]$MemoryPrefix = '')
  if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
  $full = [System.IO.Path]::GetFullPath($Path)
  if (-not [string]::IsNullOrWhiteSpace($MemoryPrefix) -and $full.StartsWith($MemoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
  $parts = @($full -split '[\\/]')
  $blocked = @{
    '.git' = $true; '.hg' = $true; '.svn' = $true
    'node_modules' = $true; 'vendor' = $true; '.venv' = $true; 'venv' = $true
    'dist' = $true; 'build' = $true; 'coverage' = $true; '.next' = $true
    '.turbo' = $true; '.cache' = $true; '__pycache__' = $true
  }
  foreach ($p in $parts) {
    if ($blocked.ContainsKey(([string]$p).ToLowerInvariant())) { return $false }
  }
  $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
  return @((Get-CodeIndexExtensions)) -contains $ext
}

function Get-CodeGenericSymbolName {
  param([string[]]$Lines, [int]$StartIndex, [string]$Fallback)
  $max = [Math]::Min($Lines.Count - 1, $StartIndex + 20)
  for ($i = $StartIndex; $i -le $max; $i++) {
    $l = [string]$Lines[$i]
    foreach ($pat in @(
      '^\s*(export\s+)?(async\s+)?function\s+([A-Za-z_][A-Za-z0-9_]*)',
      '^\s*(export\s+)?class\s+([A-Za-z_][A-Za-z0-9_]*)',
      '^\s*def\s+([A-Za-z_][A-Za-z0-9_]*)',
      '^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)',
      '^\s*(export\s+)?const\s+([A-Za-z_][A-Za-z0-9_]*)\s*=',
      '^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)'
    )) {
      $m = [regex]::Match($l, $pat)
      if ($m.Success) {
        for ($g = $m.Groups.Count - 1; $g -ge 1; $g--) {
          $v = [string]$m.Groups[$g].Value
          if ($v -match '^[A-Za-z_][A-Za-z0-9_]*$') { return $v }
        }
      }
    }
    $h = [regex]::Match($l, '^\s{0,3}#{1,6}\s+(.+)$')
    if ($h.Success) { return (($h.Groups[1].Value -replace '\s+', ' ').Trim()) }
  }
  return $Fallback
}

function Get-CodeGenericSymbolsFromFile {
  param([string]$Path, [string]$ProjectRoot)
  $rel = ConvertTo-CodeRelativePath -Root $ProjectRoot -Path $Path
  $out = New-Object 'System.Collections.Generic.List[object]'
  $item = Get-Item -LiteralPath $Path -ErrorAction Stop
  if ($item.Length -gt 1048576) { return @() }
  $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
  if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
  $lines = [regex]::Split($raw, '\r?\n')
  $chunkSize = 80
  $maxChunks = 24
  $chunkIndex = 0
  for ($start = 0; $start -lt $lines.Count -and $chunkIndex -lt $maxChunks; $start += $chunkSize) {
    $end = [Math]::Min($lines.Count - 1, $start + $chunkSize - 1)
    $slice = @($lines[$start..$end])
    $snippet = (($slice -join "`n") -replace '\s+', ' ').Trim()
    if ([string]::IsNullOrWhiteSpace($snippet)) { continue }
    if ($snippet.Length -gt 700) { $snippet = $snippet.Substring(0, 700).TrimEnd() + '...' }
    $name = Get-CodeGenericSymbolName -Lines $lines -StartIndex $start -Fallback ("chunk" + ($chunkIndex + 1))
    $line = $start + 1
    $sig = "$name@${rel}:$line"
    $words = ConvertTo-CodeWords -Name $name
    $text = "$sig $words - ${rel}:$line. $snippet"
    [void]$out.Add([pscustomobject]@{
      kind = 'chunk'
      name = $name
      signature = $sig
      file = $rel
      line = $line
      text = $text
    })
    $chunkIndex++
  }
  return @($out.ToArray())
}

function Get-CodeManifestMap {
  param([string]$Slug = '')
  $path = Get-CodeManifestPath -Slug $Slug
  $map = @{}
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $map }
  try {
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $map }
    $obj = $raw | ConvertFrom-Json
    $items = @()
    if ($obj -and ($obj.PSObject.Properties.Name -contains 'files')) { $items = @($obj.files) }
    else { $items = @($obj) }
    foreach ($item in $items) {
      if (-not $item) { continue }
      $file = [string]$item.file
      $sha1 = [string]$item.sha1
      if (-not [string]::IsNullOrWhiteSpace($file) -and -not [string]::IsNullOrWhiteSpace($sha1)) {
        $map[$file] = $sha1
      }
    }
  } catch {}
  return $map
}

function Convert-CodeManifestToJson {
  param([hashtable]$Manifest, [string]$Slug)
  $files = @()
  foreach ($k in @($Manifest.Keys | Sort-Object)) {
    $files += [ordered]@{ file = [string]$k; sha1 = [string]$Manifest[$k] }
  }
  return ([ordered]@{
      project = [string]$Slug
      updated = (Get-Date).ToUniversalTime().ToString('o')
      files = @($files)
    } | ConvertTo-Json -Depth 6)
}

function Get-CodeStoreRecords {
  param([string]$Slug = '')
  $path = Get-CodeStorePath -Slug $Slug
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
  $out = New-Object 'System.Collections.Generic.List[object]'
  try {
    $raw = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    foreach ($line in [regex]::Split($raw, "`r?`n")) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      try {
        $rec = $line | ConvertFrom-Json
        if ($rec) { [void]$out.Add($rec) }
      } catch {}
    }
  } catch {}
  return @($out.ToArray())
}

function Write-CodeStoreAndManifest {
  param([string]$Slug, [object[]]$Records, [hashtable]$Manifest)
  $dir = Get-CodeMemDir
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $storePath = Get-CodeStorePath -Slug $Slug
  $manifestPath = Get-CodeManifestPath -Slug $Slug
  $lines = @($Records | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 })
  $content = if ($lines.Count -gt 0) { ($lines -join "`n") + "`n" } else { '' }
  $manifestJson = Convert-CodeManifestToJson -Manifest $Manifest -Slug $Slug
  Use-BridgeLock ({
    Write-AtomicFile -Path $storePath -Content $content
    Write-AtomicFile -Path $manifestPath -Content $manifestJson
  }.GetNewClosure())
}

function Index-CodeBase {
  param([string]$ProjectRoot = '', [string]$Slug = '')
  if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot = Get-BridgeRoot }
  $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\','/')
  if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) { throw "ProjectRoot not found: $rootFull" }
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = Get-ProjectSlug -Root $rootFull }

  $dir = Get-CodeMemDir
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $memoryRoot = [System.IO.Path]::GetFullPath((Get-MemoryDir)).TrimEnd('\','/')
  $memoryPrefix = $memoryRoot + [System.IO.Path]::DirectorySeparatorChar

  $files = @(Get-ChildItem -LiteralPath $rootFull -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
      $full = [System.IO.Path]::GetFullPath($_.FullName)
      return (Test-CodeIndexPath -Path $full -MemoryPrefix $memoryPrefix)
    } |
    Sort-Object FullName)

  $manifest = Get-CodeManifestMap -Slug $Slug
  $newManifest = @{}
  $current = @{}
  $changed = New-Object 'System.Collections.Generic.List[object]'
  $skipped = 0

  foreach ($f in $files) {
    $rel = ConvertTo-CodeRelativePath -Root $rootFull -Path $f.FullName
    $sha1 = Get-FileSha1 -Path $f.FullName
    if ([string]::IsNullOrWhiteSpace($sha1)) { continue }
    $current[$rel] = $sha1
    if ($manifest.ContainsKey($rel) -and [string]$manifest[$rel] -eq $sha1) {
      $newManifest[$rel] = $sha1
      $skipped++
    } else {
      [void]$changed.Add([pscustomobject]@{ File = $f; Rel = $rel; Sha1 = $sha1 })
    }
  }

  $changedSet = @{}
  foreach ($c in @($changed.ToArray())) { $changedSet[[string]$c.Rel] = $true }
  $deletedSet = @{}
  foreach ($k in @($manifest.Keys)) {
    if (-not $current.ContainsKey($k)) { $deletedSet[[string]$k] = $true }
  }

  $existing = @(Get-CodeStoreRecords -Slug $Slug)
  $records = New-Object 'System.Collections.Generic.List[object]'
  $oldByFile = @{}
  foreach ($rec in $existing) {
    $rel = [string]$rec.file
    if ([string]::IsNullOrWhiteSpace($rel)) { continue }
    if (-not $oldByFile.ContainsKey($rel)) { $oldByFile[$rel] = New-Object 'System.Collections.Generic.List[object]' }
    [void]$oldByFile[$rel].Add($rec)
    if ($deletedSet.ContainsKey($rel) -or $changedSet.ContainsKey($rel)) { continue }
    [void]$records.Add($rec)
  }

  $symbols = 0
  $embedded = 0
  $failed = 0
  foreach ($c in @($changed.ToArray())) {
    $fileOk = $true
    $fileRecords = New-Object 'System.Collections.Generic.List[object]'
    try {
      $ext = [System.IO.Path]::GetExtension([string]$c.File.FullName).ToLowerInvariant()
      if (@('.ps1','.psm1','.psd1') -contains $ext) {
        $syms = @(Get-CodeSymbolsFromFile -Path $c.File.FullName -ProjectRoot $rootFull)
      } else {
        $syms = @(Get-CodeGenericSymbolsFromFile -Path $c.File.FullName -ProjectRoot $rootFull)
      }
      $symbols += $syms.Count
      $texts = @($syms | ForEach-Object { [string]$_.text })
      $vecList = New-Object 'System.Collections.Generic.List[object]'
      if ($texts.Count -gt 0) {
        try {
          foreach ($v in (Get-EmbeddingBatch -Texts $texts -TaskType 'RETRIEVAL_DOCUMENT')) { [void]$vecList.Add($v) }
        } catch {}
        if ($vecList.Count -ne $texts.Count) {
          $vecList.Clear()
          foreach ($txt in $texts) { [void]$vecList.Add((Get-Embedding -Text $txt -TaskType 'RETRIEVAL_DOCUMENT')) }
        }
      }
      for ($si = 0; $si -lt $syms.Count; $si++) {
        $sym = $syms[$si]
        $vec = $vecList[$si]
        if (-not $vec) { $fileOk = $false; break }
        $rec = [ordered]@{
          id = [guid]::NewGuid().ToString('N')
          ts = (Get-Date).ToUniversalTime().ToString('o')
          project = [string]$Slug
          kind = [string]$sym.kind
          file = [string]$sym.file
          line = [int]$sym.line
          name = [string]$sym.name
          signature = [string]$sym.signature
          tags = @('code')
          text = [string]$sym.text
          vec = @($vec)
        }
        [void]$fileRecords.Add($rec)
      }
    } catch {
      $fileOk = $false
    }

    if ($fileOk) {
      foreach ($rec in @($fileRecords.ToArray())) { [void]$records.Add($rec) }
      $newManifest[[string]$c.Rel] = [string]$c.Sha1
      $embedded += $fileRecords.Count
    } else {
      $failed++
      if ($manifest.ContainsKey([string]$c.Rel)) { $newManifest[[string]$c.Rel] = [string]$manifest[[string]$c.Rel] }
      if ($oldByFile.ContainsKey([string]$c.Rel)) {
        foreach ($rec in @($oldByFile[[string]$c.Rel].ToArray())) { [void]$records.Add($rec) }
      }
    }
  }

  Write-CodeStoreAndManifest -Slug $Slug -Records @($records.ToArray()) -Manifest $newManifest
  return [pscustomobject]@{
    project = [string]$Slug
    files = [int]$files.Count
    symbols = [int]$records.Count
    changedSymbols = [int]$symbols
    embedded = [int]$embedded
    skipped = [int]$skipped
    failed = [int]$failed
    records = [int]$records.Count
  }
}

function Search-Code {
  param([string]$Query, [int]$TopK = 0, [string]$Slug = '', [double]$MinScore = -1)
  if ([string]::IsNullOrWhiteSpace($Query)) { return @() }
  try {
    $mc = Get-MemoryConfig
    if (-not $mc.enabled) { return @() }
    if ($TopK -le 0) { $TopK = [int]$mc.codeTopK }
    if ($TopK -le 0) { $TopK = 4 }
    if ($MinScore -lt 0) { $MinScore = [double]$mc.codeMinScore }
    if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = Get-ProjectSlug }
    $records = @(Get-CodeStoreRecords -Slug $Slug)
    if ($records.Count -eq 0) { return @() }
    $qvec = Get-Embedding -Text $Query -TaskType 'RETRIEVAL_QUERY'
    if (-not $qvec) { return @() }
    $scored = foreach ($rec in $records) {
      if (-not $rec -or -not $rec.vec) { continue }
      $sim = Get-CosineSimilarity -A $qvec -B $rec.vec
      if ($sim -lt $MinScore) { continue }
      [pscustomobject]@{ Score = [double]$sim; Rec = $rec }
    }
    return @($scored | Sort-Object -Property Score -Descending | Select-Object -First $TopK)
  } catch {
    return @()
  }
}

function Get-CodeRecall {
  param([string]$Query = '', [int]$TopK = 0, [string]$Slug = '')
  if ([string]::IsNullOrWhiteSpace($Query)) { return '' }
  try {
    $mc = Get-MemoryConfig
    if (-not $mc.enabled) { return '' }
    if ($TopK -le 0) { $TopK = [int]$mc.codeTopK }
    $hits = @(Search-Code -Query $Query -TopK $TopK -Slug $Slug -MinScore ([double]$mc.codeMinScore))
    if ($hits.Count -eq 0) { return '' }
    $maxChars = [int]$mc.codeMaxInjectChars
    if ($maxChars -le 0) { $maxChars = 900 }
    $sb = New-Object System.Text.StringBuilder
    foreach ($h in $hits) {
      $r = $h.Rec
      $pct = [int]([Math]::Round([double]$h.Score * 100))
      $txt = ([string]$r.text).Trim() -replace '\s+', ' '
      if ($txt.Length -gt 220) { $txt = $txt.Substring(0, 220).TrimEnd() + '...' }
      $entry = "- ($pct%) $($r.name) - $($r.file):$($r.line) :: $txt"
      if ($sb.Length + $entry.Length + 1 -gt $maxChars) { break }
      [void]$sb.AppendLine($entry)
    }
    $body = $sb.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($body)) { return '' }
    return "=== РЕЛЕВАНТНЫЙ КОД ===`n$body"
  } catch {
    return ''
  }
}

function Get-CodeRecallForApi {
  param([string]$Query = '', [int]$TopK = 8, [string]$Slug = '')
  try {
    $hits = @(Search-Code -Query $Query -TopK $TopK -Slug $Slug)
    $out = foreach ($h in $hits) {
      $r = $h.Rec
      [pscustomobject]@{
        score = [Math]::Round([double]$h.Score, 4)
        name = [string]$r.name
        file = [string]$r.file
        line = [int]$r.line
        project = [string]$r.project
      }
    }
    return @($out)
  } catch {
    return @()
  }
}

function Get-CodeStats {
  param([string]$Slug = '')
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = Get-ProjectSlug }
  $records = @(Get-CodeStoreRecords -Slug $Slug)
  $tagCode = @($records | Where-Object { @($_.tags) -contains 'code' }).Count
  $functions = @($records | Where-Object { [string]$_.kind -eq 'function' }).Count
  $classes = @($records | Where-Object { [string]$_.kind -eq 'class' }).Count
  return [pscustomobject]@{
    project = [string]$Slug
    count = [int]$tagCode
    records = [int]$records.Count
    tag_code = [int]$tagCode
    functions = [int]$functions
    classes = [int]$classes
  }
}
