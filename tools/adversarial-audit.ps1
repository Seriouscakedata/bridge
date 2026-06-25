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

# ---------------------------------------------------------------------------
# Phase 5 — Idempotent confirmed-only backlog filing
# ---------------------------------------------------------------------------

function Get-AuditFindingFingerprint {
    param([Parameter(Mandatory=$true)][object]$Finding)
    return Get-AuditFindingStructuralKey -Finding $Finding
}

function Build-AuditFixAtom {
    param(
        [Parameter(Mandatory=$true)][object]$Finding,
        [Parameter(Mandatory=$true)][string]$RunId
    )

    $fp       = Get-AuditFindingFingerprint -Finding $Finding
    $filePath = [string]$Finding.file
    $category = [string]$Finding.category
    $evidence = [string]$Finding.evidence_snippet
    $line     = [string]$Finding.line
    $sev      = [string]$Finding.severity

    $text = "Fix [$category] at $($filePath):$line -- $evidence (severity: $sev; run: $RunId)"

    $tags = [System.Collections.Generic.List[string]]::new()
    [void]$tags.Add('audit')
    [void]$tags.Add('adversarial-confirmed')

    $cpPattern = 'driver|supervisor|watchdog|circuit|secret|server\.ps1|backlog[^/\\]*\.ps1|parallel\.ps1'
    $requiresAdmission = $false
    if ($filePath -match $cpPattern) {
        $requiresAdmission = $true
        [void]$tags.Add('operator')
    }

    return [pscustomobject]@{
        text               = $text
        tags               = $tags.ToArray()
        audit_fingerprint  = $fp
        run_id             = $RunId
        severity           = $sev
        file               = $filePath
        line               = $line
        requires_admission = $requiresAdmission
    }
}

function Invoke-AuditFileConfirmed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$ConfirmedFindings,
        [Parameter(Mandatory=$true)][string]$RunId,
        [AllowEmptyCollection()][string[]]$ExistingFingerprints = @(),
        [scriptblock]$Filer = $null
    )

    $filed   = [System.Collections.Generic.List[object]]::new()
    $skipped = [System.Collections.Generic.List[object]]::new()

    $fpSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($fp in $ExistingFingerprints) { [void]$fpSet.Add($fp) }

    foreach ($finding in $ConfirmedFindings) {
        if ($null -eq $finding) { continue }
        if ([string]$finding.verdict -ne 'confirmed') {
            throw "POLICY VIOLATION: Invoke-AuditFileConfirmed accepts only verdict=confirmed findings. Use Invoke-AuditSynthesize.confirmed_deduped."
        }
        $fp = Get-AuditFindingFingerprint -Finding $finding
        if ($fpSet.Contains($fp)) {
            [void]$skipped.Add($finding)
            continue
        }
        $atom = Build-AuditFixAtom -Finding $finding -RunId $RunId
        if ($null -ne $Filer) {
            & $Filer $atom
        } else {
            if (-not (Get-Command Add-Idea -ErrorAction SilentlyContinue)) {
                throw "Add-Idea is unavailable; cannot file confirmed audit finding."
            }
            $ideaId = Add-Idea -Text $atom.text -Tags $atom.tags -From 'adversarial-audit' -SkipCurator
            if ([string]::IsNullOrWhiteSpace([string]$ideaId)) {
                throw "Add-Idea returned an empty id; confirmed audit finding was not filed."
            }
            $atom | Add-Member -NotePropertyName backlog_id -NotePropertyValue ([string]$ideaId) -Force
        }
        [void]$fpSet.Add($fp)
        [void]$filed.Add($atom)
    }

    return [pscustomobject]@{
        filed            = $filed.ToArray()
        skipped_existing = $skipped.ToArray()
        counts           = [pscustomobject]@{
            filed   = $filed.Count
            skipped = $skipped.Count
        }
    }
}

# TODO Phase 6: Neutralize Add-DeepAuditFindingsToBacklog in tools/audit.ps1:1441.
# That function files un-verified deep findings directly to the backlog, bypassing
# the confirmed-only gate. It must be converted to route ONLY confirmed_deduped output
# from Invoke-AuditSynthesize through Invoke-AuditFileConfirmed.
function Assert-NoDirectDeepFiling {
    param([string]$Caller = 'unknown')
    throw "POLICY VIOLATION: Direct deep-audit filing is prohibited. Use Invoke-AuditFileConfirmed with confirmed-only findings from Invoke-AuditSynthesize. Caller: $Caller"
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
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][object[]]$Votes,
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

function Build-AuditSkepticJobSpec {
    param(
        [Parameter(Mandatory=$true)][object]$Finding,
        [Parameter(Mandatory=$true)][string]$SnapshotRoot,
        [Parameter(Mandatory=$true)][string]$Provider,
        [Parameter(Mandatory=$true)][int]$Index
    )

    if ($Provider -notin @('claude','codex')) {
        throw "Invalid provider '$Provider'. Must be 'claude' or 'codex'."
    }

    $fid = $Finding.finding_id
    $file = $Finding.file
    $line = $Finding.line
    $desc = $Finding.description
    $prompt = "You are an independent skeptic reviewing a security/quality finding. Check the finding against the cited file and line in the snapshot. Return STRICT JSON only (no extra text): { `"finding_id`": `"$fid`", `"vote`": `"refute|support|abstain`", `"reason`": `"...`", `"file`": `"...`", `"line`": <int> }. Finding: id=$fid file=$file line=$line description=$desc. Snapshot root: $SnapshotRoot"

    return [pscustomobject]@{
        finding_id    = $fid
        provider      = $Provider
        index         = $Index
        prompt        = $prompt
        snapshot_root = $SnapshotRoot
    }
}

function Invoke-AuditVerifyStage {
    param(
        [Parameter(Mandatory=$true)][object[]]$Findings,
        [Parameter(Mandatory=$true)][string]$SnapshotRoot,
        [int]$SkepticsPerFinding = 3,
        [int]$MinValidVotes = 2,
        [scriptblock]$VoteCollector = $null
    )

    $allJobSpecs = @()
    foreach ($finding in $Findings) {
        if ([string]$finding.state -ne 'grounded') {
            continue
        }

        for ($i = 0; $i -lt $SkepticsPerFinding; $i++) {
            $provider = if ($i % 2 -eq 0) { 'claude' } else { 'codex' }
            $allJobSpecs += Build-AuditSkepticJobSpec -Finding $finding -SnapshotRoot $SnapshotRoot -Provider $provider -Index $i
        }
    }

    $allVotes = @()
    if ($VoteCollector) {
        $collected = & $VoteCollector $allJobSpecs
        if ($null -ne $collected) {
            $allVotes = @($collected)
        }
    } else {
        if (-not (Get-Command -Name Start-ReadOnlyAuditJob -ErrorAction SilentlyContinue) -or
            -not (Get-Command -Name Wait-ReadOnlyAuditPoolDrain -ErrorAction SilentlyContinue)) {
            $parallelPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\lib\parallel.ps1'))
            if (-not (Test-Path -LiteralPath $parallelPath -PathType Leaf)) {
                throw "Missing lib/parallel.ps1 at $parallelPath"
            }
            . $parallelPath
        }

        $jobRecords = @()
        foreach ($jobSpec in $allJobSpecs) {
            $resultPath = Join-Path ([System.IO.Path]::GetTempPath()) ("audit-skeptic-" + [guid]::NewGuid().ToString('N') + '.json')
            $cliSpec = New-AuditCliJobSpec -Provider $jobSpec.provider -SnapshotRoot $jobSpec.snapshot_root -Prompt $jobSpec.prompt -ResultPath $resultPath
            $jobRecords += Start-ReadOnlyAuditJob `
                -FilePath $cliSpec.filePath `
                -ArgumentList $cliSpec.argumentList `
                -WorkingDirectory $jobSpec.snapshot_root `
                -InputText $cliSpec.inputText `
                -Metadata @{
                    finding_id = $jobSpec.finding_id
                    provider   = $jobSpec.provider
                    index      = $jobSpec.index
                }
        }

        if ($jobRecords.Count -gt 0) {
            Wait-ReadOnlyAuditPoolDrain
        }

        foreach ($record in $jobRecords) {
            $stdout = ''
            try {
                if ($record.outputPath -and (Test-Path -LiteralPath $record.outputPath -PathType Leaf)) {
                    $stdout = [System.IO.File]::ReadAllText($record.outputPath)
                }
            } catch {
                $stdout = ''
            }

            $parsedVotes = @()
            try {
                if (-not [string]::IsNullOrWhiteSpace($stdout)) {
                    $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop
                    $parsedVotes = @($parsed)
                }
            } catch {
                $parsedVotes = @()
            }

            if ($parsedVotes.Count -eq 0) {
                $allVotes += [pscustomobject]@{
                    finding_id = [string]$record.metadata.finding_id
                    vote       = 'abstain'
                    reason     = 'stdout-json-parse-failed'
                    file       = ''
                    line       = 0
                }
                continue
            }

            $allVotes += $parsedVotes
        }
    }

    $result = @()
    foreach ($f in $Findings) {
        $fCopy = $f | Select-Object -Property *
        if ([string]$f.state -eq 'rejected_grounding') {
            $resolved = Resolve-AuditFindingVerdict -Finding $f -Votes @() -MinValidVotes $MinValidVotes
            $fCopy | Add-Member -NotePropertyName 'verdict' -NotePropertyValue $resolved.verdict -Force
            $fCopy | Add-Member -NotePropertyName 'quorum' -NotePropertyValue @{
                valid_count        = 0
                refute_count       = 0
                support_count      = 0
                skeptics_requested = 0
                votes_received     = 0
            } -Force
            $result += $fCopy
            continue
        }

        $votesForF = @($allVotes | Where-Object { [string]$_.finding_id -eq [string]$f.finding_id })
        $resolved = Resolve-AuditFindingVerdict -Finding $f -Votes $votesForF -MinValidVotes $MinValidVotes
        $validVotes = @($votesForF | Where-Object { (Test-AuditSkepticSchema -Obj $_).valid })
        $refuteCount = @($validVotes | Where-Object { [string]$_.vote -eq 'refute' }).Count
        $supportCount = @($validVotes | Where-Object { [string]$_.vote -eq 'support' }).Count

        $fCopy | Add-Member -NotePropertyName 'verdict' -NotePropertyValue $resolved.verdict -Force
        $fCopy | Add-Member -NotePropertyName 'quorum' -NotePropertyValue @{
            valid_count        = @($validVotes).Count
            refute_count       = $refuteCount
            support_count      = $supportCount
            skeptics_requested = if ([string]$f.state -eq 'grounded') { $SkepticsPerFinding } else { 0 }
            votes_received     = @($votesForF).Count
        } -Force
        $result += $fCopy
    }

    $result
}

function Get-AuditVerifySummary {
    param([Parameter(Mandatory=$true)][object[]]$Findings)
    return @{
        confirmed          = @($Findings | Where-Object { $_.verdict -eq 'confirmed' }).Count
        refuted            = @($Findings | Where-Object { $_.verdict -eq 'refuted' }).Count
        unverified         = @($Findings | Where-Object { $_.verdict -eq 'unverified' }).Count
        rejected_grounding = @($Findings | Where-Object { $_.verdict -eq 'rejected_grounding' }).Count
    }
}

function Get-AuditFindingStructuralKey {
    param([Parameter(Mandatory=$true)][object]$Finding)

    $filePart = ([string]$Finding.file).ToLower()
    $catPart  = [string]$Finding.category

    $raw = ([string]$Finding.evidence_snippet).Trim().ToLower()
    $normalized = [System.Text.RegularExpressions.Regex]::Replace($raw, '\s+', ' ')

    $bytes  = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $sha1   = [System.Security.Cryptography.SHA1]::Create()
    $hash   = $sha1.ComputeHash($bytes)
    $sha1.Dispose()
    $hashHex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''

    return "$filePart|$catPart|$hashHex"
}

function Invoke-AuditSynthesize {
    param(
        [Parameter(Mandatory=$true)][object[]]$Findings,
        [Parameter(Mandatory=$true)][string]$RunId,
        [Parameter(Mandatory=$true)][string]$OutRoot,
        [object]$Telemetry = $null
    )

    $severityOrder = @{ 'critical' = 4; 'high' = 3; 'medium' = 2; 'low' = 1 }

    $cntConfirmed   = @($Findings | Where-Object { $_.verdict -eq 'confirmed' }).Count
    $cntRefuted     = @($Findings | Where-Object { $_.verdict -eq 'refuted' }).Count
    $cntUnverified  = @($Findings | Where-Object { $_.verdict -eq 'unverified' }).Count
    $cntRejected    = @($Findings | Where-Object { $_.verdict -eq 'rejected_grounding' }).Count

    # Dedup confirmed by structural key; on collision keep highest severity (tie → first)
    $confirmedList = @($Findings | Where-Object { $_.verdict -eq 'confirmed' })
    $dedupMap = @{}
    foreach ($f in $confirmedList) {
        $key = Get-AuditFindingStructuralKey -Finding $f
        if (-not $dedupMap.ContainsKey($key)) {
            $dedupMap[$key] = $f
        } else {
            $existSev = $severityOrder[[string]$dedupMap[$key].severity]
            if ($null -eq $existSev) { $existSev = 0 }
            $newSev = $severityOrder[[string]$f.severity]
            if ($null -eq $newSev) { $newSev = 0 }
            if ($newSev -gt $existSev) { $dedupMap[$key] = $f }
        }
    }
    $confirmedDeduped = @($dedupMap.Values)

    $outDir = Join-Path $OutRoot $RunId
    if (-not (Test-Path -LiteralPath $outDir -PathType Container)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    $counts = [pscustomobject]@{
        confirmed             = $cntConfirmed
        refuted               = $cntRefuted
        unverified            = $cntUnverified
        rejected_grounding    = $cntRejected
        confirmed_after_dedup = $confirmedDeduped.Count
    }

    $reportObj = [pscustomobject]@{
        run_id            = $RunId
        counts            = $counts
        telemetry         = $Telemetry
        all_findings      = $Findings
        confirmed_deduped = $confirmedDeduped
    }

    $jsonPath = Join-Path $outDir 'report.json'
    $reportObj | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8

    $mdLines = [System.Collections.Generic.List[string]]::new()
    [void]$mdLines.Add("# Audit Report: $RunId")
    [void]$mdLines.Add("")
    [void]$mdLines.Add("**Verdict counts:** confirmed=$cntConfirmed, refuted=$cntRefuted, unverified=$cntUnverified, rejected_grounding=$cntRejected (after dedup: $($confirmedDeduped.Count))")
    [void]$mdLines.Add("")
    [void]$mdLines.Add("## Confirmed Findings (deduped)")
    [void]$mdLines.Add("")
    foreach ($f in $confirmedDeduped) {
        [void]$mdLines.Add("### $($f.category) — $($f.file):$($f.line)")
        [void]$mdLines.Add("- **Severity:** $($f.severity)")
        [void]$mdLines.Add("- **Evidence:** $($f.evidence_snippet)")
        [void]$mdLines.Add("")
    }
    ($mdLines -join "`n") | Set-Content -Path (Join-Path $outDir 'report.md') -Encoding UTF8
    $mdPath = Join-Path $outDir 'report.md'

    return [pscustomobject]@{
        confirmed_deduped = $confirmedDeduped
        report_json_path  = $jsonPath
        report_md_path    = $mdPath
        counts            = $counts
    }
}

# Mode / Trigger gate (Phase 6)

$Script:_AdversarialAllowedTriggers = @('operator', 'milestone-pretraining', 'milestone-postpipeline')
$Script:_AdversarialDeniedTriggers = @('nightly_cron', 'static_daily')

function Test-AuditAdversarialTriggerAllowed {
    param([string]$Trigger)

    if ([string]::IsNullOrWhiteSpace($Trigger)) {
        return [pscustomobject]@{ allowed = $false; reason = 'denied:empty-trigger-cannot-start-adversarial' }
    }

    if ($Script:_AdversarialAllowedTriggers -contains $Trigger) {
        return [pscustomobject]@{ allowed = $true; reason = 'operator-trigger-ok' }
    }

    if ($Script:_AdversarialDeniedTriggers -contains $Trigger) {
        $reasonTrigger = $Trigger -replace '_', '-'
        return [pscustomobject]@{ allowed = $false; reason = "denied:$reasonTrigger-cannot-start-adversarial" }
    }

    return [pscustomobject]@{ allowed = $false; reason = 'denied:unknown-trigger-cannot-start-adversarial' }
}

function Assert-AuditAdversarialAllowed {
    param([string]$Trigger)

    $r = Test-AuditAdversarialTriggerAllowed -Trigger $Trigger
    if (-not $r.allowed) {
        throw "adversarial audit blocked for trigger '$Trigger': $($r.reason)"
    }
}

function Get-AuditMode {
    param([string]$Trigger)

    if ($Script:_AdversarialAllowedTriggers -contains $Trigger) {
        return 'adversarial_milestone'
    }

    return 'static_daily'
}
