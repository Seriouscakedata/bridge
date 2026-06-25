function Test-AuditJsonParsable {
    param(
        [string]$Text
    )

    try {
        $null = $Text | ConvertFrom-Json
        return $true
    } catch {
        return $false
    }
}

function New-AuditCliJobSpec {
    param(
        [Parameter(Mandatory=$true)][string]$Provider,
        [Parameter(Mandatory=$true)][string]$SnapshotRoot,
        [Parameter(Mandatory=$true)][string]$Prompt,
        [string]$Model = 'claude-sonnet-4-6',
        [string]$ResultPath = ''
    )

    if ($Provider -ne 'codex' -and $Provider -ne 'claude') {
        throw "disallowed audit provider: $Provider"
    }

    if ($Provider -eq 'codex') {
        $filePath = 'codex'
        $argList = @('exec', '--color', 'never', '-s', 'read-only', '-C', $SnapshotRoot, '-o', $ResultPath, '-')
    } else {
        $filePath = 'claude'
        $argList = @('-p', '--add-dir', $SnapshotRoot, '--allowedTools', 'Read,Grep,Glob', '--model', $Model)
    }

    [pscustomobject]@{
        provider     = $Provider
        filePath     = $filePath
        argumentList = @($argList)
        inputText    = $Prompt
        resultPath   = $ResultPath
    }
}

function Get-AuditProviderErrorClass {
    param(
        [Parameter(Mandatory=$true)][int]$ExitCode,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$StdErr,
        [AllowEmptyString()][string]$StdOut = ''
    )

    $combined = "$StdErr`n$StdOut"

    if ($combined -match '(?i)(rate.?limit|429|usage limit|quota|overloaded|too many requests)') {
        return 'rate_limit'
    }

    if ($combined -match '(?i)(unauthorized|401|invalid api key|not logged in|authentication)') {
        return 'auth'
    }

    if ($combined -match '(?i)(out of memory|oom|cannot allocate|insufficient memory|process creation failed)') {
        return 'oom'
    }

    if ($ExitCode -eq 124 -or $combined -match '(?i)(timed out|timeout)') {
        return 'timeout'
    }

    if ($StdOut -ne '' -and $ExitCode -eq 0 -and -not (Test-AuditJsonParsable -Text $StdOut)) {
        return 'malformed'
    }

    if ($ExitCode -eq 0) {
        return 'ok'
    }

    return 'unknown'
}
