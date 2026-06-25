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

function Test-AuditSkepticSchema {
    param(
        [Parameter(Mandatory=$true)][object]$Obj
    )

    $missing = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrWhiteSpace([string]$Obj.finding_id)) {
        $missing.Add('finding_id')
    }

    $validVotes = @('refute','support','abstain')
    $voteVal = [string]$Obj.vote
    if ($voteVal -notin $validVotes) {
        $missing.Add('vote')
    }

    if ([string]::IsNullOrWhiteSpace([string]$Obj.reason)) {
        $missing.Add('reason')
    }

    if ($voteVal -eq 'support') {
        if ([string]::IsNullOrWhiteSpace([string]$Obj.file)) {
            $missing.Add('file')
        }
        $lineVal = $Obj.line
        $lineInt = 0
        $lineValid = [int]::TryParse([string]$lineVal, [ref]$lineInt) -and $lineInt -ge 1
        if (-not $lineValid) {
            $missing.Add('line')
        }
    }

    $isValid = $missing.Count -eq 0
    return [pscustomobject]@{ valid = $isValid; missing = @($missing) }
}

function Resolve-AuditFindingVerdict {
    param(
        [Parameter(Mandatory=$true)][object]$Finding,
        [Parameter(Mandatory=$true)][object[]]$Votes,
        [int]$MinValidVotes = 2
    )

    # Passthrough: already rejected at grounding
    if ([string]$Finding.state -eq 'rejected_grounding') {
        return [pscustomobject]@{
            verdict      = 'rejected_grounding'
            valid_count  = 0
            refute_count = 0
            support_count = 0
        }
    }

    # Filter valid non-abstain votes
    $validVotes = @($Votes | Where-Object {
        $schema = Test-AuditSkepticSchema -Obj $_
        $schema.valid -and ([string]$_.vote) -ne 'abstain'
    })
    $validCount   = $validVotes.Count
    $refuteCount  = @($validVotes | Where-Object { ([string]$_.vote) -eq 'refute' }).Count
    $supportCount = @($validVotes | Where-Object { ([string]$_.vote) -eq 'support' }).Count

    if ($validCount -lt $MinValidVotes) {
        return [pscustomobject]@{
            verdict      = 'unverified'
            valid_count  = $validCount
            refute_count = $refuteCount
            support_count = $supportCount
        }
    }

    $threshold = [math]::Ceiling($validCount / 2)

    if ($refuteCount -ge $threshold) {
        $verdictVal = 'refuted'
    } elseif ($supportCount -ge 1) {
        $verdictVal = 'confirmed'
    } else {
        $verdictVal = 'unverified'
    }

    return [pscustomobject]@{
        verdict      = $verdictVal
        valid_count  = $validCount
        refute_count = $refuteCount
        support_count = $supportCount
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
        $argList = @('--add-dir', $SnapshotRoot, '--allowedTools', 'Read,Grep,Glob', '--model', $Model)
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

function Get-AuditFindMatrix {
    param(
        [string[]]$Dimensions,
        [object[]]$Perspectives
    )

    if (-not $Dimensions) {
        $Dimensions = @('correctness','security','concurrency','error-handling','resources',
                        'contracts','observability','state-persistence','scheduler-driver-flow','audit-backlog-flow')
    }

    if (-not $Perspectives) {
        $Perspectives = @(
            [pscustomobject]@{ provider='codex'; model='gpt-5.5'; tier='medium' },
            [pscustomobject]@{ provider='codex'; model='gpt-5.5'; tier='high' },
            [pscustomobject]@{ provider='claude'; model='claude-sonnet-4-6'; tier='' }
        )
    }

    $result = @()
    foreach ($dim in $Dimensions) {
        foreach ($p in $Perspectives) {
            $tierOrModel = if ($p.tier) { $p.tier } else { $p.model }
            $agentId = "find-$dim-$($p.provider)-$tierOrModel"
            $result += [pscustomobject]@{
                dimension = $dim
                provider  = $p.provider
                model     = $p.model
                tier      = $p.tier
                agent_id  = $agentId
            }
        }
    }
    return $result
}

function Test-AuditFinderSchema {
    param(
        [Parameter(Mandatory=$true)][object]$Obj
    )

    $required = @('root_cause','file','line','evidence_snippet','severity','why','fix_sketch','confidence','dimension','agent_id')
    $missing = @()

    foreach ($field in $required) {
        $val = $Obj.PSObject.Properties[$field]
        if ($null -eq $val) {
            $missing += $field
        }
    }

    if ($missing.Count -gt 0) {
        return [pscustomobject]@{ valid=$false; missing=$missing; reason="missing fields: $($missing -join ', ')" }
    }

    $validSeverities = @('critical','high','medium','low','info')
    if ($Obj.severity -notin $validSeverities) {
        return [pscustomobject]@{ valid=$false; missing=@(); reason="invalid severity: $($Obj.severity)" }
    }

    $lineVal = $Obj.line
    if (-not ($lineVal -is [int] -or $lineVal -is [long] -or $lineVal -is [double])) {
        return [pscustomobject]@{ valid=$false; missing=@(); reason="line must be a number" }
    }
    if ([int]$lineVal -lt 1) {
        return [pscustomobject]@{ valid=$false; missing=@(); reason="line must be a positive integer" }
    }

    $confVal = $Obj.confidence
    if (-not ($confVal -is [decimal] -or $confVal -is [double] -or $confVal -is [int])) {
        return [pscustomobject]@{ valid=$false; missing=@(); reason="confidence must be a number" }
    }
    $confNum = [double]$confVal
    if ($confNum -lt 0 -or $confNum -gt 1) {
        return [pscustomobject]@{ valid=$false; missing=@(); reason="confidence must be 0..1" }
    }

    return [pscustomobject]@{ valid=$true; missing=@(); reason='ok' }
}

function ConvertFrom-AuditFinderOutput {
    param(
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$Text
    )

    # Find first '{' or '[' and try to extract and parse JSON
    $startBrace = $Text.IndexOf('{')
    $startBracket = $Text.IndexOf('[')

    $startIdx = -1
    $isArray = $false

    if ($startBrace -ge 0 -and ($startBracket -lt 0 -or $startBrace -le $startBracket)) {
        $startIdx = $startBrace
        $isArray = $false
    } elseif ($startBracket -ge 0) {
        $startIdx = $startBracket
        $isArray = $true
    }

    if ($startIdx -lt 0) {
        return @()
    }

    # Find matching closing bracket by depth counting
    $openChar = if ($isArray) { '[' } else { '{' }
    $closeChar = if ($isArray) { ']' } else { '}' }
    $depth = 0
    $endIdx = -1
    $inString = $false
    $escape = $false

    for ($i = $startIdx; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($escape) { $escape = $false; continue }
        if ($ch -eq '\' -and $inString) { $escape = $true; continue }
        if ($ch -eq '"') { $inString = -not $inString; continue }
        if ($inString) { continue }
        if ($ch -eq $openChar) { $depth++ }
        elseif ($ch -eq $closeChar) {
            $depth--
            if ($depth -eq 0) { $endIdx = $i; break }
        }
    }

    if ($endIdx -lt 0) {
        return @()
    }

    $jsonStr = $Text.Substring($startIdx, $endIdx - $startIdx + 1)

    try {
        $parsed = $jsonStr | ConvertFrom-Json
    } catch {
        return @()
    }

    # Wrap single object in array
    if ($parsed -isnot [System.Array]) {
        $parsed = @($parsed)
    }

    $valid = @()
    foreach ($item in $parsed) {
        $check = Test-AuditFinderSchema -Obj $item
        if ($check.valid) {
            $valid += $item
        }
    }
    Write-Output -NoEnumerate $valid
}

function Test-AuditFindingGrounded {
    param(
        [Parameter(Mandatory=$true)][object]$Finding,
        [Parameter(Mandatory=$true)][string]$SnapshotRoot
    )

    $findingFile = if ($null -eq $Finding.file) { '' } else { [string]$Finding.file }
    if ([string]::IsNullOrWhiteSpace($findingFile)) {
        return [pscustomobject]@{ grounded=$false; reason='file-missing' }
    }

    try {
        $rootFull = [System.IO.Path]::GetFullPath($SnapshotRoot)
        $rootPath = [System.IO.Path]::GetPathRoot($rootFull)
        if ($rootPath -and $rootFull.Length -gt $rootPath.Length) {
            $rootFull = $rootFull.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        }
        $filePath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($rootFull, $findingFile))
    } catch {
        return [pscustomobject]@{ grounded=$false; reason='file-missing' }
    }

    $dirSep = [string][System.IO.Path]::DirectorySeparatorChar
    $altSep = [string][System.IO.Path]::AltDirectorySeparatorChar
    $rootPrefix = $rootFull
    if (-not ($rootPrefix.EndsWith($dirSep) -or $rootPrefix.EndsWith($altSep))) {
        $rootPrefix = $rootPrefix + $dirSep
    }
    if (-not $filePath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ grounded=$false; reason='file-missing' }
    }

    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        return [pscustomobject]@{ grounded=$false; reason='file-missing' }
    }

    try {
        $resolvedFile = (Resolve-Path -LiteralPath $filePath -ErrorAction Stop).ProviderPath
    } catch {
        return [pscustomobject]@{ grounded=$false; reason='file-missing' }
    }
    if (-not $resolvedFile.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{ grounded=$false; reason='file-missing' }
    }

    $lines = @(Get-Content -LiteralPath $resolvedFile -Encoding UTF8)
    $lineCount = $lines.Count
    $lineNum = 0
    $lineText = if ($null -eq $Finding.line) { '' } else { ([string]$Finding.line).Trim() }
    if (-not [int]::TryParse($lineText, [ref]$lineNum)) {
        return [pscustomobject]@{ grounded=$false; reason='line-out-of-range' }
    }

    if ($lineNum -lt 1 -or $lineNum -gt $lineCount) {
        return [pscustomobject]@{ grounded=$false; reason='line-out-of-range' }
    }

    # Whitespace-normalize: collapse runs of whitespace, trim
    function NormWs([AllowNull()][object]$s) {
        if ($null -eq $s) { return '' }
        return (([string]$s) -replace '\s+', ' ').Trim()
    }

    $snippetNorm = NormWs $Finding.evidence_snippet
    if ([string]::IsNullOrWhiteSpace($snippetNorm)) {
        return [pscustomobject]@{ grounded=$false; reason='evidence-mismatch' }
    }

    $low  = [Math]::Max(0, $lineNum - 1 - 3)
    $high = [Math]::Min($lineCount - 1, $lineNum - 1 + 3)

    for ($i = $low; $i -le $high; $i++) {
        $lineNorm = NormWs $lines[$i]
        if ($lineNorm.Contains($snippetNorm)) {
            return [pscustomobject]@{ grounded=$true; reason='grounded' }
        }
    }

    return [pscustomobject]@{ grounded=$false; reason='evidence-mismatch' }
}

function Invoke-AuditGroundingGate {
    param(
        [Parameter(Mandatory=$true)][object[]]$Findings,
        [Parameter(Mandatory=$true)][string]$SnapshotRoot
    )

    $result = @()
    foreach ($f in $Findings) {
        $check = Test-AuditFindingGrounded -Finding $f -SnapshotRoot $SnapshotRoot
        $fCopy = $f | Select-Object -Property *
        $stateVal = if ($check.grounded) { 'grounded' } else { 'rejected_grounding' }
        $fCopy | Add-Member -NotePropertyName 'state' -NotePropertyValue $stateVal -Force
        $fCopy | Add-Member -NotePropertyName 'grounding_reason' -NotePropertyValue $check.reason -Force
        $result += $fCopy
    }
    Write-Output -NoEnumerate $result
}

function Get-AuditGroundingSummary {
    param(
        [Parameter(Mandatory=$true)][object[]]$Findings
    )

    $grounded = @($Findings | Where-Object { $_.state -eq 'grounded' }).Count
    $rejected = @($Findings | Where-Object { $_.state -eq 'rejected_grounding' }).Count
    return @{ grounded = $grounded; rejected_grounding = $rejected }
}
