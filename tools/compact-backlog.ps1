<#
.SYNOPSIS
    Deduplicates a backlog.jsonl file by 'id' (last-line-wins), in-place.
.DESCRIPTION
    Streams the target file, keeps the last line for each id, and atomically
    replaces the original file only when the size threshold is reached and
    duplicate ids are found.
.PARAMETER Path
    Path to the backlog.jsonl file.
.PARAMETER ThresholdMB
    Minimum file size in MB to trigger compaction. Default: 10.
    Must be non-negative. Use 0 to force a scan.
.PARAMETER WhatIf
    Dry run: report what would happen without writing.
.EXAMPLE
    .\tools\compact-backlog.ps1 -Path .\channels\main\backlog.jsonl -WhatIf

    Scans the main backlog and reports whether duplicates would be removed.
.EXAMPLE
    .\tools\compact-backlog.ps1 -Path .\channels\main\backlog.jsonl

    Compacts the main backlog only when it is at least 10 MB and duplicate ids exist.
#>
param(
    [Parameter(Mandatory)][string]$Path,
    [double]$ThresholdMB = 10,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

if ($ThresholdMB -lt 0) {
    throw "compact-backlog: ThresholdMB must be non-negative"
}

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Host "compact-backlog: file not found: $Path"
    return
}

$fullPath = [System.IO.Path]::GetFullPath($Path)
$info = Get-Item -LiteralPath $fullPath
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

foreach ($line in [System.IO.File]::ReadLines($fullPath, [System.Text.Encoding]::UTF8)) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrEmpty($trimmed)) { $emptyCount++; continue }

    if ($trimmed -match '"id"\s*:\s*"([^"]+)"') {
        $id = "id:$($Matches[1])"
    } else {
        $id = "noid:$lineCount"
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

$tmp = $fullPath + ".compact.tmp"
$sw = $null
try {
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $sw = [System.IO.StreamWriter]::new($tmp, $false, $utf8NoBom)
    foreach ($id in $order) { $sw.WriteLine($seen[$id]) }
    $sw.Flush(); $sw.Close(); $sw.Dispose()
    $sw = $null
    Move-Item -LiteralPath $tmp -Destination $fullPath -Force
    $newInfo = Get-Item -LiteralPath $fullPath
    $newMB   = [math]::Round($newInfo.Length / 1MB, 2)
    Write-Host "compact-backlog: done. ${sizeMB}MB -> ${newMB}MB (saved $([math]::Round($sizeMB - $newMB, 2))MB)"
} catch {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    throw
} finally {
    if ($null -ne $sw) { $sw.Dispose() }
}
