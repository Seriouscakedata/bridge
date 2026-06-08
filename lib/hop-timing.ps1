function Write-HopTiming {
    param(
        [string]$HopId,
        [double]$DurationMs,
        [string]$Source,
        [string]$Status
    )

    try {
        $path = Join-Path $env:USERPROFILE '.bridge-runtime\hop-timing.jsonl'
        $directory = Split-Path -Parent $path

        if (-not [string]::IsNullOrWhiteSpace($directory)) {
            [System.IO.Directory]::CreateDirectory($directory) | Out-Null
        }

        if (-not [System.IO.File]::Exists($path)) {
            [System.IO.File]::WriteAllLines($path, [string[]]@())
        }

        $entry = [ordered]@{
            timestamp   = (Get-Date).ToString('o')
            hop_id      = $HopId
            duration_ms = $DurationMs
            source      = $Source
            status      = $Status
        }

        $jsonLine = $entry | ConvertTo-Json -Compress -Depth 3
        $mutex = New-Object System.Threading.Mutex($false, 'BridgeHopTimingFileMutex')
        $hasHandle = $false

        try {
            $hasHandle = $mutex.WaitOne()

            if ([System.IO.File]::Exists($path)) {
                $existingLines = [System.IO.File]::ReadAllLines($path)
            }
            else {
                [System.IO.File]::WriteAllLines($path, [string[]]@($jsonLine))
                return
            }

            if ($existingLines.Count -gt 9999) {
                $existingLines = $existingLines[($existingLines.Count - 9999)..($existingLines.Count - 1)]
            }

            $updatedLines = [System.Collections.Generic.List[string]]::new()
            foreach ($line in $existingLines) {
                $updatedLines.Add($line)
            }

            $updatedLines.Add($jsonLine)
            [System.IO.File]::WriteAllLines($path, $updatedLines.ToArray())
        }
        finally {
            if ($hasHandle) {
                $mutex.ReleaseMutex()
            }

            $mutex.Dispose()
        }
    }
    catch {
    }
}

function Get-HopTimingSummary {
    param([int]$Top = 10)

    try {
        $path = Join-Path $env:USERPROFILE '.bridge-runtime\hop-timing.jsonl'

        if (-not [System.IO.File]::Exists($path)) {
            return @()
        }

        $lines = [System.IO.File]::ReadAllLines($path)
        if (-not $lines -or $lines.Count -eq 0) {
            return @()
        }

        if ($Top -le 0) {
            return @()
        }

        $records = [System.Collections.Generic.List[object]]::new()
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }

            try {
                $record = $line | ConvertFrom-Json -ErrorAction Stop
                if ($null -ne $record.source -and $null -ne $record.duration_ms) {
                    $records.Add($record)
                }
            }
            catch {
            }
        }

        if ($records.Count -eq 0) {
            return @()
        }

        $summaries = foreach ($group in ($records | Group-Object -Property source)) {
            $durations = @($group.Group | ForEach-Object { [double]$_.duration_ms } | Sort-Object)
            $count = $durations.Count

            if ($count -eq 0) {
                continue
            }

            $average = ($durations | Measure-Object -Average).Average
            $p95Index = [Math]::Max(([int][Math]::Ceiling(0.95 * $count) - 1), 0)

            [pscustomobject]@{
                source = $group.Name
                count  = $count
                avg_ms = $average
                p95_ms = $durations[$p95Index]
            }
        }

        return @($summaries | Sort-Object -Property count -Descending | Select-Object -First $Top)
    }
    catch {
        return @()
    }
}
