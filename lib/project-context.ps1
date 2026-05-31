# project-context.ps1 -- evidence-backed per-project memory layer.
#
# This file intentionally builds on memory.ps1 + codemem.ps1 instead of creating
# a second knowledge store. Each channel remains its own project scope; main is
# the bridge project.

function Get-ProjectContextScope {
  param([string]$Channel = $null)
  try {
    if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-CurrentMemoryChannel }
    if (Get-Command Get-EffectiveScope -ErrorAction SilentlyContinue) {
      return (Get-EffectiveScope -Slug $Channel)
    }
  } catch {}
  $root = Get-BridgeRoot
  return [pscustomobject]@{
    slug         = $(if ([string]::IsNullOrWhiteSpace($Channel)) { 'main' } else { [string]$Channel })
    is_bridge    = $true
    project_root = $root
    memory_root  = (Join-Path $root 'memory')
    memory_store = (Join-Path $root 'memory\memory.jsonl')
  }
}

function Resolve-ProjectEvidencePath {
  param($Evidence, [string]$ProjectRoot)
  if (-not $Evidence) { return '' }
  $file = ''
  try {
    if ($Evidence.PSObject.Properties['file']) { $file = [string]$Evidence.file }
  } catch {}
  if ([string]::IsNullOrWhiteSpace($file)) { return '' }
  try {
    if ([System.IO.Path]::IsPathRooted($file)) { return [System.IO.Path]::GetFullPath($file) }
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
      return [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $file))
    }
  } catch {}
  return $file
}

function Get-ProjectFileSha1 {
  param([string]$Path)
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
  if (Get-Command Get-FileSha1 -ErrorAction SilentlyContinue) {
    try { return [string](Get-FileSha1 -Path $Path) } catch {}
  }
  $sha = $null
  try {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally {
    if ($sha) { $sha.Dispose() }
  }
}

function Test-ProjectMemoryFreshness {
  param($MemoryRecord, [string]$Channel = $null)
  $scope = Get-ProjectContextScope -Channel $Channel
  $ev = $null
  try { if ($MemoryRecord.PSObject.Properties['evidence']) { $ev = $MemoryRecord.evidence } } catch {}
  if (-not $ev) { return [pscustomobject]@{ fresh = $true; reason = 'no-evidence'; path = ''; expected_sha1 = ''; actual_sha1 = '' } }
  $path = Resolve-ProjectEvidencePath -Evidence $ev -ProjectRoot ([string]$scope.project_root)
  if ([string]::IsNullOrWhiteSpace($path)) { return [pscustomobject]@{ fresh = $true; reason = 'no-file-evidence'; path = ''; expected_sha1 = ''; actual_sha1 = '' } }
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    return [pscustomobject]@{ fresh = $false; reason = 'file-missing'; path = $path; expected_sha1 = ''; actual_sha1 = '' }
  }
  $expected = ''
  try { if ($ev.PSObject.Properties['sha1']) { $expected = [string]$ev.sha1 } } catch {}
  if ([string]::IsNullOrWhiteSpace($expected)) {
    return [pscustomobject]@{ fresh = $true; reason = 'no-sha1'; path = $path; expected_sha1 = ''; actual_sha1 = '' }
  }
  $actual = Get-ProjectFileSha1 -Path $path
  $ok = ($actual -eq $expected)
  return [pscustomobject]@{ fresh = [bool]$ok; reason = $(if ($ok) { 'sha1-ok' } else { 'sha1-mismatch' }); path = $path; expected_sha1 = $expected; actual_sha1 = $actual }
}

function Format-ProjectMemoryEvidence {
  param($MemoryRecord)
  $ev = $null
  try { if ($MemoryRecord.PSObject.Properties['evidence']) { $ev = $MemoryRecord.evidence } } catch {}
  if (-not $ev) { return '' }
  $bits = New-Object 'System.Collections.Generic.List[string]'
  foreach ($k in @('file','line','commit','sha1')) {
    try {
      if ($ev.PSObject.Properties[$k] -and -not [string]::IsNullOrWhiteSpace([string]$ev.$k)) {
        [void]$bits.Add("$k=$([string]$ev.$k)")
      }
    } catch {}
  }
  if ($bits.Count -eq 0) { return '' }
  return " [" + (($bits.ToArray()) -join '; ') + "]"
}

function Format-ProjectMemoryHits {
  param($Hits, [string]$Channel = $null, [int]$MaxChars = 800, [switch]$RequireFresh)
  if (-not $Hits -or @($Hits).Count -eq 0) { return '' }
  $sb = New-Object System.Text.StringBuilder
  foreach ($h in @($Hits)) {
    $m = $h.Mem
    if ($RequireFresh) {
      $fresh = Test-ProjectMemoryFreshness -MemoryRecord $m -Channel $Channel
      if (-not [bool]$fresh.fresh) { continue }
    }
    $trust = Get-MemoryTrust $m
    $kind = Get-MemoryKind $m
    $pct = [int]([Math]::Round([double]$h.Score * 100))
    $txt = ([string]$m.text).Trim() -replace '\s+', ' '
    if ($txt.Length -gt 260) { $txt = $txt.Substring(0, 260).TrimEnd() + '...' }
    $ev = Format-ProjectMemoryEvidence -MemoryRecord $m
    $line = "- ($pct%) [$kind/$trust] $txt$ev"
    if ($sb.Length + $line.Length + 1 -gt $MaxChars) { break }
    [void]$sb.AppendLine($line)
  }
  return $sb.ToString().Trim()
}

function Get-ProjectMapSnippet {
  param([string]$Channel = $null, [int]$MaxChars = 700)
  try {
    $scope = Get-ProjectContextScope -Channel $Channel
    $slug = [string]$scope.slug
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $root = [string]$scope.project_root
    if (-not [string]::IsNullOrWhiteSpace($root)) {
      [void]$candidates.Add((Join-Path $root 'PROJECT_MAP.md'))
      [void]$candidates.Add((Join-Path $root 'docs\PROJECT_MAP.md'))
    }
    [void]$candidates.Add((Get-MemoryMapPath -Slug $slug))
    foreach ($path in @($candidates.ToArray())) {
      if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
      $txt = ([System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)).Trim()
      if ([string]::IsNullOrWhiteSpace($txt)) { continue }
      if ($txt.Length -gt $MaxChars) { $txt = $txt.Substring(0, $MaxChars).TrimEnd() + "`n...[truncated]" }
      return $txt
    }
  } catch { return '' }
  return ''
}

function Test-ProjectReadiness {
  param([string]$TaskText = '', [string]$Channel = $null)
  $scope = Get-ProjectContextScope -Channel $Channel
  $slug = [string]$scope.slug
  $mems = @(Get-AllMemories -Channel $slug)
  $active = @($mems | Where-Object { (Get-MemoryStatus $_) -eq 'active' })
  $facts = @($active | Where-Object { (Get-MemoryKind $_) -eq 'project_fact' })
  $tests = @($active | Where-Object { (Get-MemoryKind $_) -eq 'project_test' })
  $risks = @($active | Where-Object { @('project_risk','project_invariant') -contains (Get-MemoryKind $_) })
  $mapPath = ''
  try { $mapPath = Get-MemoryMapPath -Slug $slug } catch {}
  $hasMap = (-not [string]::IsNullOrWhiteSpace($mapPath) -and (Test-Path -LiteralPath $mapPath -PathType Leaf) -and ((Get-Item -LiteralPath $mapPath).Length -gt 20))
  $codeRecords = 0
  try {
    if (Get-Command Get-CodeStats -ErrorAction SilentlyContinue) {
      $cs = Get-CodeStats -Slug (Get-ProjectSlug -Root ([string]$scope.project_root))
      $codeRecords = [int]$cs.records
    }
  } catch {}
  $stale = 0
  foreach ($m in @($facts | Select-Object -First 25)) {
    try { if (-not [bool](Test-ProjectMemoryFreshness -MemoryRecord $m -Channel $slug).fresh) { $stale++ } } catch {}
  }

  $score = 0
  $reasons = New-Object 'System.Collections.Generic.List[string]'
  if ($hasMap) { $score += 25 } else { [void]$reasons.Add('нет project map') }
  if ($facts.Count -ge 3) { $score += 25 } else { [void]$reasons.Add('мало проверяемых project_fact') }
  if ($tests.Count -ge 1) { $score += 20 } else { [void]$reasons.Add('неизвестны project_test/проверки') }
  if ($codeRecords -gt 0) { $score += 20 } else { [void]$reasons.Add('codemem индекс пуст или не найден') }
  if ($risks.Count -gt 0) { $score += 10 } else { [void]$reasons.Add('нет project_risk/project_invariant') }
  if ($stale -gt 0) { $score -= [Math]::Min(20, $stale * 4); [void]$reasons.Add("есть stale evidence: $stale") }
  if ($score -lt 0) { $score = 0 }
  if ($score -gt 100) { $score = 100 }
  $level = if ($score -ge 75) { 'green' } elseif ($score -ge 45) { 'yellow' } else { 'red' }
  return [pscustomobject]@{
    channel = $slug
    project_root = [string]$scope.project_root
    level = $level
    score = [int]$score
    facts = [int]$facts.Count
    tests = [int]$tests.Count
    risks = [int]$risks.Count
    code_records = [int]$codeRecords
    stale_checked = [int][Math]::Min(25, $facts.Count)
    stale = [int]$stale
    reasons = @($reasons.ToArray())
  }
}

function Get-ProjectContextPack {
  param([string]$TaskText = '', [string]$Channel = $null, [int]$MaxChars = 3200, [switch]$IncludeCode)
  if ([string]::IsNullOrWhiteSpace($TaskText)) { return '' }
  if ([string]::IsNullOrWhiteSpace($Channel)) { $Channel = Get-CurrentMemoryChannel }
  $scope = Get-ProjectContextScope -Channel $Channel
  $ready = Test-ProjectReadiness -TaskText $TaskText -Channel $Channel
  $map = Get-ProjectMapSnippet -Channel $Channel -MaxChars 650

  $facts = @(Search-ProjectMemory -Query $TaskText -Kind @('project_fact') -Status @('active') -TopK 6 -MinScore 0.45 -Channel $Channel)
  $risks = @(Search-ProjectMemory -Query $TaskText -Kind @('project_risk','project_invariant') -Status @('active') -TopK 4 -MinScore 0.42 -Channel $Channel)
  $tests = @(Search-ProjectMemory -Query $TaskText -Kind @('project_test') -Status @('active') -TopK 4 -MinScore 0.42 -Channel $Channel)
  $work = @(Search-ProjectMemory -Query $TaskText -Kind @('project_worklog','project_decision') -Status @('active') -TopK 4 -MinScore 0.42 -Channel $Channel)
  $questions = @(Search-ProjectMemory -Query $TaskText -Kind @('project_open_question') -Status @('active') -TopK 3 -MinScore 0.42 -Channel $Channel)

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('=== PROJECT CONTEXT PACK (typed memory v2) ===')
  [void]$sb.AppendLine("channel=$($ready.channel) readiness=$($ready.level) score=$($ready.score) root=$([string]$scope.project_root)")
  if ($ready.reasons -and @($ready.reasons).Count -gt 0) { [void]$sb.AppendLine('readiness_notes=' + ((@($ready.reasons) | Select-Object -First 4) -join '; ')) }
  if (-not [string]::IsNullOrWhiteSpace($map)) {
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- PROJECT MAP ---')
    [void]$sb.AppendLine($map)
  }
  $sections = @(
    @{ title='VERIFIED / OBSERVED FACTS'; text=(Format-ProjectMemoryHits -Hits $facts -Channel $Channel -MaxChars 700 -RequireFresh) },
    @{ title='RISKS / INVARIANTS'; text=(Format-ProjectMemoryHits -Hits $risks -Channel $Channel -MaxChars 550 -RequireFresh) },
    @{ title='TESTS TO RUN'; text=(Format-ProjectMemoryHits -Hits $tests -Channel $Channel -MaxChars 450 -RequireFresh) },
    @{ title='PAST WORK / DECISIONS'; text=(Format-ProjectMemoryHits -Hits $work -Channel $Channel -MaxChars 550 -RequireFresh) },
    @{ title='OPEN QUESTIONS'; text=(Format-ProjectMemoryHits -Hits $questions -Channel $Channel -MaxChars 350) }
  )
  foreach ($s in $sections) {
    if (-not [string]::IsNullOrWhiteSpace([string]$s.text)) {
      [void]$sb.AppendLine('')
      [void]$sb.AppendLine('--- ' + [string]$s.title + ' ---')
      [void]$sb.AppendLine([string]$s.text)
    }
  }
  if ($IncludeCode) {
    try {
      $code = Get-CodeRecall -Query $TaskText -TopK 4 -Slug (Get-ProjectSlug -Root ([string]$scope.project_root))
      if (-not [string]::IsNullOrWhiteSpace($code)) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine($code)
      }
    } catch {}
  }
  $out = $sb.ToString().Trim()
  if ($out.Length -gt $MaxChars) { $out = $out.Substring(0, $MaxChars).TrimEnd() + "`n...[project-context truncated]" }
  return $out
}

function ConvertFrom-ProjectMemoryMarker {
  param([string]$Kind, [string]$RawText)
  $parts = @(([string]$RawText) -split '\s+\|\s+')
  $text = if ($parts.Count -gt 0) { [string]$parts[0] } else { [string]$RawText }
  $evidence = [ordered]@{}
  $meta = [ordered]@{}
  $trust = 'observed'
  foreach ($p in @($parts | Select-Object -Skip 1)) {
    $kv = [string]$p
    $idx = $kv.IndexOf('=')
    if ($idx -le 0) { continue }
    $k = $kv.Substring(0, $idx).Trim().ToLowerInvariant()
    $v = $kv.Substring($idx + 1).Trim()
    if ($k -eq 'trust') { $trust = $v; continue }
    if (@('file','line','commit','sha1') -contains $k) { $evidence[$k] = $v; continue }
    $meta[$k] = $v
  }
  return [pscustomobject]@{
    kind = $Kind
    text = $text.Trim()
    trust = $trust
    evidence = $(if ($evidence.Count -gt 0) { [pscustomobject]$evidence } else { $null })
    meta = $(if ($meta.Count -gt 0) { [pscustomobject]$meta } else { $null })
  }
}

function Add-ProjectMemoryFromMarker {
  param([string]$Kind, [string]$RawText, [string]$Channel = $null, [string]$Source = 'marker')
  $m = ConvertFrom-ProjectMemoryMarker -Kind $Kind -RawText $RawText
  if (-not $m -or [string]::IsNullOrWhiteSpace([string]$m.text)) { return $null }
  return (Add-ProjectMemory -Text ([string]$m.text) -Kind ([string]$m.kind) -Trust ([string]$m.trust) -Evidence $m.evidence -Meta $m.meta -Channel $Channel -Source $Source -Importance 0.75)
}

function Update-ProjectMemoryAfterTask {
  param([string]$TaskText, [string]$Outcome, [string]$Channel = $null, [string]$Commit = '')
  if ([string]::IsNullOrWhiteSpace($TaskText) -or [string]::IsNullOrWhiteSpace($Outcome)) { return $null }
  $out = ([string]$Outcome -replace '\s+', ' ').Trim()
  if ($out.Length -gt 700) { $out = $out.Substring(0, 700).TrimEnd() + '...' }
  $task = ([string]$TaskText -replace '\s+', ' ').Trim()
  if ($task.Length -gt 240) { $task = $task.Substring(0, 240).TrimEnd() + '...' }
  $meta = [ordered]@{ task = $task }
  if (-not [string]::IsNullOrWhiteSpace($Commit)) { $meta.commit = $Commit }
  return (Add-ProjectMemory -Text ("Task completed: $task | Outcome: $out") -Kind 'project_worklog' -Trust 'observed' -Tags @('worklog') -Source 'task-worklog' -Importance 0.55 -Channel $Channel -Meta ([pscustomobject]$meta))
}
