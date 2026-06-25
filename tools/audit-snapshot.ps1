Set-StrictMode -Version 2.0

$ErrorActionPreference = "Stop"

function ConvertTo-AuditSnapshotCommandLineArgument {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    if ($Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }

        if ($ch -eq '"') {
            [void]$builder.Append('\' * (($backslashes * 2) + 1))
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }

        if ($backslashes -gt 0) {
            [void]$builder.Append('\' * $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($ch)
    }

    if ($backslashes -gt 0) {
        [void]$builder.Append('\' * ($backslashes * 2))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-AuditSnapshotGit {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(git -C $Root @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if (($exitCode -ne 0) -and -not $AllowFailure) {
        $message = ($output | ForEach-Object { [string]$_ }) -join "`n"
        throw "git $($Arguments -join ' ') failed with exit $exitCode in $Root`n$message"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = @($output | ForEach-Object { [string]$_ })
    }
}

function Copy-AuditSnapshotGitBlob {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Sha,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $tempPath = Join-Path ([System.IO.Path]::GetTempPath()) ("audit-snapshot-blob-{0}.tmp" -f ([guid]::NewGuid().ToString("N")))
    try {
        $showSpec = ("{0}:{1}" -f $Sha, $Path)
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = "git"
        $processInfo.Arguments = (@("-C", $Root, "show", $showSpec) | ForEach-Object { ConvertTo-AuditSnapshotCommandLineArgument -Value $_ }) -join " "
        $processInfo.UseShellExecute = $false
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo
        [void]$process.Start()
        $fileStream = [System.IO.File]::Open($tempPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $process.StandardOutput.BaseStream.CopyTo($fileStream)
        } finally {
            $fileStream.Dispose()
        }
        $errText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "git show $showSpec failed with exit $($process.ExitCode)`n$errText"
        }

        Copy-Item -LiteralPath $tempPath -Destination $Destination -Force
    } finally {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-AuditSnapshotDirtyFiles {
    param(
        [Parameter(Mandatory = $true)][string[]]$StatusLines
    )

    $dirty = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($line in $StatusLines) {
        if ([string]::IsNullOrWhiteSpace($line) -or ($line.Length -lt 4)) {
            continue
        }

        $pathPart = $line.Substring(3).Trim()
        if ($pathPart -match '^(.+?)\s+->\s+(.+)$') {
            [void]$dirty.Add($matches[1].Trim().Trim('"'))
            [void]$dirty.Add($matches[2].Trim().Trim('"'))
        } else {
            [void]$dirty.Add($pathPart.Trim('"'))
        }
    }

    return $dirty
}

function New-AuditSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$TargetRoot,
        [string]$Sha,
        [string]$RunId,
        [switch]$IncludeUncommitted
    )

    $rootPath = (Resolve-Path -LiteralPath $TargetRoot).ProviderPath

    if ([string]::IsNullOrWhiteSpace($Sha)) {
        $head = Invoke-AuditSnapshotGit -Root $rootPath -Arguments @("rev-parse", "HEAD")
        $Sha = ([string]$head.Output[0]).Trim()
    } else {
        $Sha = $Sha.Trim()
    }

    $status = Invoke-AuditSnapshotGit -Root $rootPath -Arguments @("status", "--short")
    $statusLines = @($status.Output | Where-Object { $_ -match '\S' })
    $isDirty = ($statusLines.Count -gt 0)

    if ($isDirty -and -not $IncludeUncommitted) {
        return [pscustomobject]@{
            ok     = $false
            reason = "dirty-target"
        }
    }

    if ([string]::IsNullOrWhiteSpace($RunId)) {
        $utc = (Get-Date).ToUniversalTime()
        $RunId = "audit_$($utc.ToString('yyyyMMddTHHmmss'))Z"
    }

    $runDir = Join-Path $rootPath (Join-Path "audit\runs" $RunId)
    $snapshotDir = Join-Path $runDir "snapshot"
    New-Item -ItemType Directory -Force -Path $snapshotDir | Out-Null

    $tracked = Invoke-AuditSnapshotGit -Root $rootPath -Arguments @("ls-files")
    $trackedFiles = @($tracked.Output | Where-Object { $_ -match '\S' })
    $dirtyFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if ($IncludeUncommitted) {
        $dirtyFiles = Get-AuditSnapshotDirtyFiles -StatusLines $statusLines
    }

    $fileCount = 0
    foreach ($file in $trackedFiles) {
        $dest = Join-Path $snapshotDir $file
        $destDir = Split-Path -Path $dest -Parent
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
        }

        if ($IncludeUncommitted -and $dirtyFiles.Contains($file)) {
            $src = Join-Path $rootPath $file
            if (Test-Path -LiteralPath $src -PathType Leaf) {
                Copy-Item -LiteralPath $src -Destination $dest -Force
                $fileCount++
            }
            continue
        }

        Copy-AuditSnapshotGitBlob -Root $rootPath -Sha $Sha -Path $file -Destination $dest
        $fileCount++
    }

    $created = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $policy = "clean"
    if ($IncludeUncommitted) {
        $policy = "include-uncommitted"
    }

    $metaPath = Join-Path $runDir "snapshot_meta.json"
    $meta = [pscustomobject]@{
        run_id            = $RunId
        target_root       = $rootPath
        snapshot_sha      = $Sha
        snapshot_policy   = $policy
        git_status_short  = ($statusLines -join "`n")
        file_count        = $fileCount
        created           = $created
    }
    $json = $meta | ConvertTo-Json -Depth 5
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($metaPath, $json, $utf8NoBom)

    return [pscustomobject]@{
        ok            = $true
        run_id        = $RunId
        snapshot_root = $snapshotDir
        snapshot_sha  = $Sha
        file_count    = $fileCount
        meta_path     = $metaPath
    }
}

function Get-AuditSnapshotMeta {
    param(
        [Parameter(Mandatory = $true)][string]$RunDir
    )

    $metaPath = Join-Path $RunDir "snapshot_meta.json"
    return Get-Content -LiteralPath $metaPath -Raw | ConvertFrom-Json
}
