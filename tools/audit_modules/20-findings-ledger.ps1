function Get-AuditFindingField {
  param($Raw, [string[]]$Names)
  if ($null -eq $Raw) { return $null }
  foreach ($name in $Names) {
    try {
      if ($Raw -is [System.Collections.IDictionary] -and $Raw.Contains($name) -and $null -ne $Raw[$name]) {
        return $Raw[$name]
      }
      if ($Raw.PSObject -and ($Raw.PSObject.Properties.Name -contains $name) -and $null -ne $Raw.$name) {
        return $Raw.$name
      }
    } catch {}
  }
  return $null
}

function Format-AuditFindings {
  # Normalize a raw finding (hashtable or PSObject) into a flat object with known fields.
  param($Source, $Raw)
  $sev = 'info'
  $category = ''
  $component = ''
  $file = ''
  $title = ''
  $detail = ''
  $area = ''
  try {
    if ($Raw -is [string]) {
      $title = [string]$Raw
    } else {
      $rawSev = Get-AuditFindingField -Raw $Raw -Names @('severity','sev','level')
      if ($rawSev) { $sev = ([string]$rawSev).ToLowerInvariant() }

      $rawCategory = Get-AuditFindingField -Raw $Raw -Names @('category','kind','type')
      if ($rawCategory) { $category = ([string]$rawCategory).ToLowerInvariant() }

      $rawTitle = Get-AuditFindingField -Raw $Raw -Names @('title','name','summary','rule','category')
      if ($rawTitle) { $title = [string]$rawTitle }

      $rawDetail = Get-AuditFindingField -Raw $Raw -Names @('detail','message','description','msg')
      if ($rawDetail) { $detail = [string]$rawDetail }
      $rawRecommendation = Get-AuditFindingField -Raw $Raw -Names @('recommendation')
      if ($rawRecommendation) {
        if ($detail) { $detail += " Recommendation: $rawRecommendation" }
        else { $detail = [string]$rawRecommendation }
      }

      $rawComponent = Get-AuditFindingField -Raw $Raw -Names @('component')
      if ($rawComponent) { $component = [string]$rawComponent }

      $rawFile = Get-AuditFindingField -Raw $Raw -Names @('file','path','target')
      if ($rawFile) { $file = [string]$rawFile }

      $rawArea = Get-AuditFindingField -Raw $Raw -Names @('area','path','file','target','component')
      if ($rawArea) { $area = [string]$rawArea }
      if (-not $component -and $rawArea) { $component = [string]$rawArea }
      if (-not $file -and $rawFile) { $file = [string]$rawFile }
      $rawLine = Get-AuditFindingField -Raw $Raw -Names @('line','lineno','line_number')
      if ($rawLine -and $area -and $area -notmatch ':\d+$') { $area += ":$rawLine" }
    }
  } catch {}
  if ($sev -notin @('critical','warning','info')) {
    switch ($sev) {
      'high'   { $sev = 'critical' }
      'err'    { $sev = 'critical' }
      'error'  { $sev = 'critical' }
      'warn'   { $sev = 'warning' }
      'medium' { $sev = 'warning' }
      'low'    { $sev = 'info' }
      default  { $sev = 'info' }
    }
  }
  if ([string]::IsNullOrWhiteSpace($title)) { $title = '(no title)' }
  return [pscustomobject]@{
    source   = [string]$Source
    severity = $sev
    category = $category
    component = $component
    file = $file
    title    = $title
    detail   = $detail
    area     = $area
  }
}

function Get-AuditSeverityCounts {
  param($Findings)
  $c = @{ critical = 0; warning = 0; info = 0 }
  foreach ($f in @($Findings)) {
    $s = [string]$f.severity
    if ($c.ContainsKey($s)) { $c[$s] = $c[$s] + 1 } else { $c.info = $c.info + 1 }
  }
  return $c
}

function Merge-AuditFindings {
  param($Findings)
  $deduped = New-Object 'System.Collections.Generic.List[object]'
  $seen = @{}
  foreach ($f in @($Findings)) {
    $cat = [string](Get-AuditFindingField -Raw $f -Names @('category'))
    if ($cat) { $cat = $cat.ToLowerInvariant() }
    $normalizedCat = $cat -replace '_', '-'
    if ($normalizedCat -eq 'orphaned-files') { $normalizedCat = 'orphaned-file' }
    $key = ''
    if ($normalizedCat -match '(dead|orphan)') {
      $component = [string](Get-AuditFindingField -Raw $f -Names @('component'))
      $file = [string](Get-AuditFindingField -Raw $f -Names @('file'))
      $key = "$normalizedCat|$component|$file"
    }
    if ($key -and $seen.ContainsKey($key)) { continue }
    if ($key) { $seen[$key] = $true }
    [void]$deduped.Add($f)
  }
  return @($deduped.ToArray())
}

function Normalize-AuditLedgerToken {
  param([string]$Value, [string]$Fallback = 'unknown')
  $s = ([string]$Value).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($s)) { $s = $Fallback }
  $s = $s -replace '[\s_]+', '-'
  $s = $s -replace '[^a-z0-9.\-]+', '-'
  $s = $s.Trim('-')
  if ([string]::IsNullOrWhiteSpace($s)) { return $Fallback }
  return $s
}

function Normalize-AuditLedgerPathScope {
  param([string]$Value, [switch]$KeepLine)
  $s = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($s)) { return '' }

  $lineSuffix = ''
  if ($s -match ':(\d+)$') {
    $lineSuffix = ":$($Matches[1])"
    $s = $s -replace ':\d+$', ''
  }

  $s = $s -replace '\\', '/'
  $s = $s -replace '^[A-Za-z]:', ''
  $s = $s.Trim('/')
  if ($s -match '/') {
    $parts = $s -split '/'
    $s = $parts[$parts.Length - 1]
  }
  $s = $s.Trim()
  if ([string]::IsNullOrWhiteSpace($s)) { return '' }
  if ($KeepLine -and $lineSuffix) { return "$s$lineSuffix" }
  return $s
}

function Normalize-AuditLedgerTitle {
  param([string]$Value)
  $s = ([string]$Value).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($s)) { return 'unknown' }
  $s = $s -replace '\d+', '#'
  $s = $s -replace '\s+', ' '
  $s = $s.Trim()
  if ($s.Length -gt 120) { $s = $s.Substring(0, 120) }
  return (Normalize-AuditLedgerToken -Value $s -Fallback 'unknown')
}

function Get-AuditLedgerScope {
  param($Finding, [switch]$KeepLine)
  $scope = [string](Get-AuditFindingField -Raw $Finding -Names @('file'))
  if ([string]::IsNullOrWhiteSpace($scope)) {
    $scope = [string](Get-AuditFindingField -Raw $Finding -Names @('component'))
  }
  if ([string]::IsNullOrWhiteSpace($scope)) {
    $scope = [string](Get-AuditFindingField -Raw $Finding -Names @('area'))
  }
  $normalized = Normalize-AuditLedgerPathScope -Value $scope -KeepLine:$KeepLine
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    $normalized = Normalize-AuditLedgerTitle -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('title')))
  }
  return (Normalize-AuditLedgerToken -Value $normalized -Fallback 'unknown')
}

function Get-AuditLedgerEvidenceKey {
  param($Finding)
  $evidence = [string](Get-AuditFindingField -Raw $Finding -Names @('area'))
  if ([string]::IsNullOrWhiteSpace($evidence)) {
    $evidence = [string](Get-AuditFindingField -Raw $Finding -Names @('file'))
  }
  if ([string]::IsNullOrWhiteSpace($evidence)) {
    $evidence = [string](Get-AuditFindingField -Raw $Finding -Names @('component'))
  }
  $normalized = Normalize-AuditLedgerPathScope -Value $evidence -KeepLine
  if ([string]::IsNullOrWhiteSpace($normalized)) {
    $normalized = Normalize-AuditLedgerTitle -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('title')))
  }
  return (Normalize-AuditLedgerToken -Value $normalized -Fallback 'unknown')
}

function New-FindingId {
  param($Finding)
  $source = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('source'))) -Fallback 'unknown'
  $category = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('category'))) -Fallback 'uncategorized'
  $scope = Get-AuditLedgerScope -Finding $Finding
  $evidenceKey = Get-AuditLedgerEvidenceKey -Finding $Finding
  return "$source|$category|$scope|$evidenceKey"
}

function New-RootCauseKey {
  param($Finding)
  $category = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('category'))) -Fallback 'uncategorized'
  $component = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('component'))) -Fallback ''
  $file = Normalize-AuditLedgerToken -Value (Normalize-AuditLedgerPathScope -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('file'))) -KeepLine) -Fallback ''
  $area = Normalize-AuditLedgerToken -Value (Normalize-AuditLedgerPathScope -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('area'))) -KeepLine) -Fallback ''
  $evidence = $area
  if ([string]::IsNullOrWhiteSpace($evidence)) { $evidence = $file }
  if ([string]::IsNullOrWhiteSpace($component) -and [string]::IsNullOrWhiteSpace($evidence)) {
    $title = Normalize-AuditLedgerTitle -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('title')))
    return "$category|$title"
  }
  if ([string]::IsNullOrWhiteSpace($evidence)) { $evidence = Get-AuditLedgerEvidenceKey -Finding $Finding }
  if ([string]::IsNullOrWhiteSpace($component)) { $component = Get-AuditLedgerScope -Finding $Finding }
  return "$category|$component|$evidence"
}

function Read-FindingsLedger {
  param([string]$LedgerPath)
  $ledger = @{}
  if (-not (Test-Path -LiteralPath $LedgerPath)) { return $ledger }
  foreach ($line in @(Get-Content -LiteralPath $LedgerPath -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $entry = $line | ConvertFrom-Json
      if ($entry -and $entry.rootCauseKey) {
        $ledger[[string]$entry.rootCauseKey] = $entry
      }
    } catch {
      Write-Warning "Skipping malformed findings-ledger line in ${LedgerPath}: $($_.Exception.Message)"
    }
  }
  return $ledger
}

function Set-AuditLedgerEntryValue {
  param($Entry, [string]$Name, $Value)
  if ($Entry.PSObject.Properties.Name -contains $Name) {
    $Entry.$Name = $Value
  } else {
    $Entry | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function New-AuditLedgerEntry {
  param($Finding, [string]$RootCauseKey, [string]$FindingId, [string]$NowText)
  $category = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('category'))) -Fallback 'uncategorized'
  $severity = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('severity'))) -Fallback 'info'
  if ($severity -notin @('critical','warning','info')) { $severity = 'info' }
  $slice = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $Finding -Names @('source'))) -Fallback 'unknown'
  return [pscustomobject][ordered]@{
    id = $FindingId
    rootCauseKey = $RootCauseKey
    slice = $slice
    category = $category
    severity = $severity
    firstSeen = $NowText
    lastSeen = $NowText
    seenCount = 1
    state = 'new'
    title = [string](Get-AuditFindingField -Raw $Finding -Names @('title'))
  }
}

function Update-FindingsLedger {
  param($CurrentFindings, $Ledger, [datetime]$Now)
  if ($null -eq $Ledger) { $Ledger = @{} }
  $reportFindings = New-Object 'System.Collections.Generic.List[object]'
  $seenThisRun = @{}
  $suppressedCount = 0
  $nowText = $Now.ToUniversalTime().ToString('o')

  foreach ($f in @($CurrentFindings)) {
    $rck = New-RootCauseKey -Finding $f
    $fid = New-FindingId -Finding $f
    if ([string]::IsNullOrWhiteSpace($rck)) { $rck = $fid }
    $seenThisRun[$rck] = $true
    $severity = Normalize-AuditLedgerToken -Value ([string](Get-AuditFindingField -Raw $f -Names @('severity'))) -Fallback 'info'
    $isCritical = ($severity -eq 'critical')

    if (-not $Ledger.ContainsKey($rck)) {
      $entry = New-AuditLedgerEntry -Finding $f -RootCauseKey $rck -FindingId $fid -NowText $nowText
      $Ledger[$rck] = $entry
      [void]$reportFindings.Add($f)
      continue
    }

    $entry = $Ledger[$rck]
    $state = Normalize-AuditLedgerToken -Value ([string]$entry.state) -Fallback 'open'
    $seenCount = 0
    try { $seenCount = [int]$entry.seenCount } catch { $seenCount = 0 }
    Set-AuditLedgerEntryValue -Entry $entry -Name 'id' -Value $fid
    Set-AuditLedgerEntryValue -Entry $entry -Name 'lastSeen' -Value $nowText
    Set-AuditLedgerEntryValue -Entry $entry -Name 'seenCount' -Value ($seenCount + 1)
    Set-AuditLedgerEntryValue -Entry $entry -Name 'severity' -Value $severity
    Set-AuditLedgerEntryValue -Entry $entry -Name 'title' -Value ([string](Get-AuditFindingField -Raw $f -Names @('title')))

    if ($state -in @('fixed','suppressed')) {
      Set-AuditLedgerEntryValue -Entry $entry -Name 'state' -Value 'regressed'
      [void]$reportFindings.Add($f)
      continue
    }

    if ($state -eq 'regressed') {
      [void]$reportFindings.Add($f)
      continue
    }

    if ($state -eq 'new') {
      Set-AuditLedgerEntryValue -Entry $entry -Name 'state' -Value 'open'
    }

    if ($isCritical) {
      [void]$reportFindings.Add($f)
    } else {
      $suppressedCount++
    }
  }

  return @{
    ledger = $Ledger
    reportFindings = @($reportFindings.ToArray())
    suppressedCount = $suppressedCount
  }
}

function Write-FindingsLedger {
  param([string]$LedgerPath, $Ledger)
  $entries = @($Ledger.Values | Sort-Object @{ Expression = { [string]$_.firstSeen } }, @{ Expression = { [string]$_.rootCauseKey } })
  $lines = New-Object 'System.Collections.Generic.List[string]'
  foreach ($entry in $entries) {
    [void]$lines.Add(($entry | ConvertTo-Json -Compress -Depth 8))
  }
  $content = [string]::Join("`n", $lines.ToArray())
  if ($content.Length -gt 0) { $content += "`n" }
  Write-AuditAtomicFile -Path $LedgerPath -Content $content
}
