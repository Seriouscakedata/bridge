param([switch]$DryRun)
# 2026-06-30 one-time migration: move inline `embedding` vectors out of every channel's backlog.jsonl
# into a sibling backlog-embeddings.jsonl sidecar. The inline vectors were ~88% of a 26MB backlog, so
# every locked read-modify-write parsed+serialized ~22MB and storm-wedged the global bridge lock.
# Held under the global bridge mutex so no concurrent driver write is lost. Idempotent: re-running on an
# already-slim backlog is a no-op. Run BEFORE deploying the sidecar code (restart.flag); the populated
# sidecar means the new code never has to mass-recompute embeddings.
$ErrorActionPreference = 'Stop'
$bridge = 'C:\Users\rafie\OneDrive\Documents\bridge'
$channelsDir = Join-Path $bridge 'channels'
$backlogs = @(Get-ChildItem -LiteralPath $channelsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
  $p = Join-Path $_.FullName 'backlog.jsonl'
  if (Test-Path -LiteralPath $p) { $p }
}) | Where-Object { $_ }

function Convert-Channel {
  param([string]$Backlog)
  $side = Join-Path (Split-Path -Parent $Backlog) 'backlog-embeddings.jsonl'
  $lines = [System.IO.File]::ReadAllLines($Backlog)
  $slim = New-Object 'System.Collections.Generic.List[string]'
  $emb  = New-Object 'System.Collections.Generic.List[string]'
  $moved = 0
  foreach ($l in $lines) {
    if ([string]::IsNullOrWhiteSpace($l)) { continue }
    $o = $null
    try { $o = $l | ConvertFrom-Json } catch { $slim.Add($l); continue }   # keep unparseable line verbatim
    $id = ''
    try { $id = [string]$o.id } catch {}
    if (($o.PSObject.Properties.Name -contains 'embedding') -and ($null -ne $o.embedding) -and -not [string]::IsNullOrWhiteSpace($id)) {
      $emb.Add( ([pscustomobject]@{ id = $id; embedding = @($o.embedding) } | ConvertTo-Json -Compress -Depth 4) )
      $o = $o | Select-Object -Property * -ExcludeProperty embedding
      $moved++
    }
    $slim.Add( ($o | ConvertTo-Json -Compress -Depth 6) )
  }
  return [pscustomobject]@{ backlog=$Backlog; side=$side; slim=$slim; emb=$emb; moved=$moved; total=$slim.Count
    sizeBeforeMB=[math]::Round((Get-Item $Backlog).Length/1MB,2) }
}

# ---- Build everything in memory FIRST (read is fast; do heavy work, then swap under the lock) -------
$plans = @()
foreach ($b in $backlogs) {
  $p = Convert-Channel -Backlog $b
  $plans += $p
  Write-Host ("PLAN " + (Split-Path (Split-Path $b -Parent) -Leaf) + ": items=" + $p.total + " moved_embeddings=" + $p.moved + " sizeBefore=" + $p.sizeBeforeMB + "MB")
}
if ($DryRun) { Write-Host 'DRY RUN -- no files written'; return }

# ---- Acquire the global bridge mutex and re-read+swap atomically (avoid lost updates) ---------------
$mutex = New-Object System.Threading.Mutex($false, 'Global\ClaudeCodexBridgeLock')
$got = $false
try { $got = $mutex.WaitOne(25000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
if (-not $got) { Write-Host 'LOCK_FAIL: could not acquire bridge lock in 25s'; exit 1 }
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
  foreach ($b in $backlogs) {
    # Re-convert under the lock from the CURRENT file (a driver may have written between plan + now).
    $p = Convert-Channel -Backlog $b
    if ($p.moved -eq 0) { Write-Host ("SKIP " + $b + " (no inline embeddings)"); continue }
    # 1) append extracted embeddings to the sidecar (bulk)
    $embContent = ($p.emb -join "`n") + "`n"
    Add-Content -LiteralPath $p.side -Value ($p.emb -join "`n") -Encoding UTF8
    # 2) write the slim backlog atomically (tmp + move)
    $slimContent = if ($p.slim.Count) { ($p.slim -join "`n") + "`n" } else { '' }
    $tmp = "$($p.backlog).migrate.tmp"
    [System.IO.File]::WriteAllText($tmp, $slimContent, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $p.backlog -Force
    $afterMB = [math]::Round((Get-Item $p.backlog).Length/1MB,2)
    $sideMB  = [math]::Round((Get-Item $p.side).Length/1MB,2)
    Write-Host ("DONE " + (Split-Path (Split-Path $p.backlog -Parent) -Leaf) + ": moved=" + $p.moved + " backlog_now=" + $afterMB + "MB sidecar=" + $sideMB + "MB")
  }
} finally {
  $sw.Stop()
  $mutex.ReleaseMutex(); $mutex.Dispose()
  Write-Host ("lock_held_ms=" + $sw.ElapsedMilliseconds)
}
Write-Host 'MIGRATION COMPLETE'
