<#
.SYNOPSIS
    Deduplicates a backlog.jsonl file by 'id' (last-line-wins), in-place.
.PARAMETER Path
    Path to the backlog.jsonl file.
.PARAMETER ThresholdMB
    Minimum file size in MB to trigger compaction. Default: 10.
.PARAMETER WhatIf
    Dry run: report what would happen without writing.
#>
param(
    [Parameter(Mandatory)][string]$Path,
    [double]$ThresholdMB = 10,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Path)) {
    Write-Host "compact-backlog: file not found: $Path"
    return
}

$info = Get-Item $Path
$sizeMB = [math]::Round($info.Length / 1MB, 2)

if ($info.Length -lt [long]($ThresholdMB * 1MB)) {
    Write-Host "compact-backlog: $($info.Name) ${sizeMB}MB < ${ThresholdMB}MB threshold -- skip"
    return
}

Write-Host "compact-backlog: $($info.Name) ${sizeMB}MB -- scanning for duplicates..."

$order  = [System.Collections.Generic.List[string]]::new()
$seen   = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
$lineCount  = 0
$emptyCount = 0
$noIdCount  = 0

foreach ($line in [System.IO.File]::ReadLines($Path, [System.Text.Encoding]::UTF8)) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrEmpty($trimmed)) { $emptyCount++; continue }

    if ($trimmed -match '"id"\s*:\s*"([^"]+)"') {
        $id = $Matches[1]
    } else {
        $id = "~noid~$lineCount"
        $noIdCount++
    }

    if (-not $seen.ContainsKey($id)) { $order.Add($id) }
    $seen[$id] = $trimmed
    $lineCount++
}

$uniqueCount  = $order.Count
$dupesRemoved = $lineCount - $uniqueCount

Write-Host "compact-backlog: $lineCount lines, $uniqueCount unique, $dupesRemoved dupes ($emptyCount empty, $noIdCount no-id)"

if ($dupesRemoved -eq 0) {
    Write-Host "compact-backlog: no duplicates -- file unchanged"
    return
}

if ($WhatIf) {
    Write-Host "compact-backlog: [WhatIf] would write $uniqueCount lines, remove $dupesRemoved dupes"
    return
}

$tmp = $Path + ".compact.tmp"
try {
    $sw = [System.IO.StreamWriter]::new($tmp, $false, [System.Text.Encoding]::new(65001, $false))
    foreach ($id in $order) { $sw.WriteLine($seen[$id]) }
    $sw.Flush(); $sw.Close(); $sw.Dispose()
    Move-Item -Path $tmp -Destination $Path -Force
    $newInfo = Get-Item $Path
    $newMB   = [math]::Round($newInfo.Length / 1MB, 2)
    Write-Host "compact-backlog: done. ${sizeMB}MB -> ${newMB}MB (saved $([math]::Round($sizeMB - $newMB, 2))MB)"
} catch {
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    throw
}
