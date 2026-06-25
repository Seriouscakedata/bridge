Set-StrictMode -Version 2.0

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "audit-snapshot.ps1")

function Assert-AuditSnapshot {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Invoke-TestGit {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = @(git -C $Root @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join "`n")"
    }
}

$tmpRoot = Join-Path $env:TEMP ("audsnap-{0}" -f ([guid]::NewGuid().ToString("N")))

try {
    New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
    git init $tmpRoot | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "git init failed"
    }

    Invoke-TestGit -Root $tmpRoot -Arguments @("config", "user.email", "test@test.local")
    Invoke-TestGit -Root $tmpRoot -Arguments @("config", "user.name", "Test")
    Invoke-TestGit -Root $tmpRoot -Arguments @("config", "core.autocrlf", "false")
    $excludePath = Join-Path (Join-Path (Join-Path $tmpRoot ".git") "info") "exclude"
    Add-Content -LiteralPath $excludePath -Value "audit/"

    [System.IO.File]::WriteAllText((Join-Path $tmpRoot "file_a.txt"), "hello`n", [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText((Join-Path $tmpRoot "file_b.txt"), "world`n", [System.Text.Encoding]::UTF8)
    Invoke-TestGit -Root $tmpRoot -Arguments @("add", "-A")
    Invoke-TestGit -Root $tmpRoot -Arguments @("commit", "-m", "init")

    $cleanInclude = New-AuditSnapshot -TargetRoot $tmpRoot -RunId "clean_include" -IncludeUncommitted
    Assert-AuditSnapshot -Condition ([bool]$cleanInclude.ok) -Message "include-uncommitted on clean repo did not return ok=true"
    Assert-AuditSnapshot -Condition ([int]$cleanInclude.file_count -eq 2) -Message "include-uncommitted clean file_count should be 2"
    $cleanIncludeMeta = Get-AuditSnapshotMeta -RunDir (Split-Path -Path $cleanInclude.snapshot_root -Parent)
    Assert-AuditSnapshot -Condition ([string]$cleanIncludeMeta.snapshot_policy -eq "include-uncommitted") -Message "include-uncommitted clean policy mismatch"
    Assert-AuditSnapshot -Condition ([string]::IsNullOrWhiteSpace([string]$cleanIncludeMeta.git_status_short)) -Message "include-uncommitted clean status should be empty"

    $duplicateRun = New-AuditSnapshot -TargetRoot $tmpRoot -RunId "clean_include" -IncludeUncommitted
    Assert-AuditSnapshot -Condition (-not [bool]$duplicateRun.ok) -Message "duplicate RunId should return ok=false"
    Assert-AuditSnapshot -Condition ([string]$duplicateRun.reason -eq "snapshot-exists") -Message "duplicate RunId reason should be snapshot-exists"

    $invalidRun = New-AuditSnapshot -TargetRoot $tmpRoot -RunId "..\escape"
    Assert-AuditSnapshot -Condition (-not [bool]$invalidRun.ok) -Message "invalid RunId should return ok=false"
    Assert-AuditSnapshot -Condition ([string]$invalidRun.reason -eq "invalid-run-id") -Message "invalid RunId reason should be invalid-run-id"

    $clean = New-AuditSnapshot -TargetRoot $tmpRoot
    Assert-AuditSnapshot -Condition ([bool]$clean.ok) -Message "clean snapshot did not return ok=true"
    Assert-AuditSnapshot -Condition (Test-Path -LiteralPath $clean.meta_path -PathType Leaf) -Message "snapshot_meta.json was not written"

    $meta = Get-AuditSnapshotMeta -RunDir (Split-Path -Path $clean.snapshot_root -Parent)
    Assert-AuditSnapshot -Condition (-not [string]::IsNullOrWhiteSpace($meta.snapshot_sha)) -Message "snapshot_sha is empty"
    Assert-AuditSnapshot -Condition ([int]$meta.file_count -eq 2) -Message "file_count should be 2"
    Assert-AuditSnapshot -Condition ([int]$clean.file_count -eq 2) -Message "returned file_count should be 2"

    $snapA = Join-Path $clean.snapshot_root "file_a.txt"
    $snapB = Join-Path $clean.snapshot_root "file_b.txt"
    Assert-AuditSnapshot -Condition (Test-Path -LiteralPath $snapA -PathType Leaf) -Message "file_a.txt missing from snapshot"
    Assert-AuditSnapshot -Condition (Test-Path -LiteralPath $snapB -PathType Leaf) -Message "file_b.txt missing from snapshot"
    Assert-AuditSnapshot -Condition ((Get-Content -LiteralPath $snapA -Raw) -eq "hello`n") -Message "file_a.txt content mismatch"
    Assert-AuditSnapshot -Condition ((Get-Content -LiteralPath $snapB -Raw) -eq "world`n") -Message "file_b.txt content mismatch"
    Write-Host "PASS clean-case"

    Add-Content -LiteralPath (Join-Path $tmpRoot "file_a.txt") -Value "dirty"
    $dirtyReject = New-AuditSnapshot -TargetRoot $tmpRoot
    Assert-AuditSnapshot -Condition (-not [bool]$dirtyReject.ok) -Message "dirty snapshot should return ok=false"
    Assert-AuditSnapshot -Condition ([string]$dirtyReject.reason -eq "dirty-target") -Message "dirty snapshot reason should be dirty-target"
    Write-Host "PASS dirty-reject"

    $dirtyInclude = New-AuditSnapshot -TargetRoot $tmpRoot -IncludeUncommitted
    Assert-AuditSnapshot -Condition ([bool]$dirtyInclude.ok) -Message "include-uncommitted snapshot did not return ok=true"
    $dirtySnapA = Join-Path $dirtyInclude.snapshot_root "file_a.txt"
    Assert-AuditSnapshot -Condition (Test-Path -LiteralPath $dirtySnapA -PathType Leaf) -Message "dirty file_a.txt missing from snapshot"
    Assert-AuditSnapshot -Condition (((Get-Content -LiteralPath $dirtySnapA -Raw) -match "dirty")) -Message "dirty content missing from overlay snapshot"
    Write-Host "PASS include-uncommitted"
} finally {
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
