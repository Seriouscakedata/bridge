# findings-ledger.ps1 -- stable finding tracking: dedup, state transitions, suppress-known

function Get-FindingRootCauseKey {
  param([object]$Finding)
  $slice    = ([string]$Finding.source).ToLowerInvariant() -replace '[^a-z0-9_-]','_'
  $sigType  = ([string]$Finding.category).ToLowerInvariant() -replace '[^a-z0-9_-]','_'
  $rawScope = if ($Finding.area) { [string]$Finding.area } elseif ($Finding.file) { [string]$Finding.file } else { '' }
  $scope    = ($rawScope -replace ':\d+$','') | Split-Path -Leaf -ErrorAction SilentlyContinue
  if (-not $scope) { $scope = $rawScope -replace ':\d+$','' }
  $scope    = $scope.ToLowerInvariant() -replace '[^a-z0-9._/-]','_'
  if ($scope.Length -gt 60) { $scope = $scope.Substring(0,60) }
  $evKey    = ([string]$Finding.title).ToLowerInvariant() -replace '[^a-z0-9]','_'
  if ($evKey.Length -gt 40) { $evKey = $evKey.Substring(0,40) }
  return "$slice|$sigType|$scope|$evKey"
}

function Read-FindingsLedger {
  param([string]$LedgerPath)
  $result = @{}
  if (-not (Test-Path -LiteralPath $LedgerPath)) { return $result }
  try {
    foreach ($line in [System.IO.File]::ReadAllLines($LedgerPath, [System.Text.Encoding]::UTF8)) {
      $line = $line.Trim()
      if (-not $line) { continue }
      try {
        $entry = $line | ConvertFrom-Json
        if ($entry.rootCauseKey) {
          $result[$entry.rootCauseKey] = $entry
        }
      } catch {}
    }
  } catch {}
  return $result
}

function Update-FindingsLedger {
  param(
    [string]$BridgePath,
    [object[]]$Findings
  )
  $ledgerDir  = Join-Path $BridgePath 'audit'
  $ledgerPath = Join-Path $ledgerDir 'findings-ledger.jsonl'
  if (-not (Test-Path -LiteralPath $ledgerDir)) {
    New-Item -ItemType Directory -Path $ledgerDir -Force | Out-Null
  }
  $ledger = Read-FindingsLedger -LedgerPath $ledgerPath
  $now    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  $stats  = @{ new = 0; known = 0; regressed = 0 }

  foreach ($f in @($Findings)) {
    $key      = Get-FindingRootCauseKey -Finding $f
    $slice    = ([string]$f.source).ToLowerInvariant() -replace '[^a-z0-9_-]','_'
    $sigType  = ([string]$f.category).ToLowerInvariant() -replace '[^a-z0-9_-]','_'
    $rawScope = if ($f.area) { [string]$f.area } elseif ($f.file) { [string]$f.file } else { '' }
    $scope    = ($rawScope -replace ':\d+$','') | Split-Path -Leaf -ErrorAction SilentlyContinue
    if (-not $scope) { $scope = $rawScope -replace ':\d+$','' }

    if ($ledger.ContainsKey($key)) {
      $entry            = $ledger[$key]
      $prevState        = [string]$entry.state
      $entry.lastSeen   = $now
      $entry.seenCount  = [int]$entry.seenCount + 1
      $entry.severity   = [string]$f.severity
      if ($prevState -eq 'fixed' -or $prevState -eq 'suppressed') {
        $entry.state = 'regressed'
        $stats.regressed++
      } else {
        $entry.state = 'open'
        $stats.known++
      }
      $ledger[$key] = $entry
    } else {
      $entry = [pscustomobject]@{
        rootCauseKey = $key
        slice        = $slice
        signal_type  = $sigType
        scope        = $scope
        state        = 'new'
        severity     = [string]$f.severity
        firstSeen    = $now
        lastSeen     = $now
        seenCount    = 1
        title        = [string]$f.title
      }
      $ledger[$key] = $entry
      $stats.new++
    }

    $f | Add-Member -MemberType NoteProperty -Name 'ledgerState'     -Value ([string]$ledger[$key].state)     -Force
    $f | Add-Member -MemberType NoteProperty -Name 'ledgerSeenCount' -Value ([int]$ledger[$key].seenCount)    -Force
    $f | Add-Member -MemberType NoteProperty -Name 'rootCauseKey'    -Value $key                              -Force
  }

  # write ledger sorted by firstSeen
  $lines = @($ledger.Values | Sort-Object firstSeen | ForEach-Object {
    $_ | ConvertTo-Json -Compress -Depth 5
  })
  try {
    $text = $lines -join "`n"
    [System.IO.File]::WriteAllText($ledgerPath, $text, (New-Object System.Text.UTF8Encoding($false)))
  } catch {}

  return @{ stats = $stats }
}

function Get-LedgerVisibleFindings {
  param([object[]]$Findings)
  @($Findings | Where-Object {
    $ls  = [string]$_.ledgerState
    $sev = [string]$_.severity
    ($ls -in @('new','regressed')) -or ($sev -eq 'critical')
  })
}
