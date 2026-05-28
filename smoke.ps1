# smoke.ps1 -- pre-promote health check. Exit 0 = OK, Exit 1 = failures.
# Checks: PS1 parse, /api/status, /api/memory, /api/messages
$b = 'C:\Users\rafie\OneDrive\Documents\bridge'
$failed = @()

# 1. Parse-check all .ps1 files
$ps1s = Get-ChildItem $b -Recurse -Filter *.ps1 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '\\\.' }
foreach ($f in $ps1s) {
    $tokens = $null
    $errs = $null
    [void]([System.Management.Automation.Language.Parser]::ParseFile(
        $f.FullName, [ref]$tokens, [ref]$errs))
    if ($errs.Count -gt 0) { $failed += "PARSE: $($f.Name) ($($errs.Count) err)" }
}

# 1b. Footgun lint -- ETS string -> ConvertTo-Json -Depth 10 OOM (the /api/radar incident, 2026-05-25).
#     `Get-Content -Raw` attaches ETS PSProvider/PSDrive note-props to the returned string;
#     serializing it with a high ConvertTo-Json -Depth recurses into provider object graphs and
#     OOM-crashes the host (~70GB zombie powershell). Convention: read JSON-bound text with
#     [IO.File]::ReadAllText (or "" + $s), return flat DTOs, keep ConvertTo-Json -Depth <= 10.
$lintFiles = @(Get-ChildItem (Join-Path $b 'lib') -Filter *.ps1 -ErrorAction SilentlyContinue)
$lintFiles += @(Get-ChildItem $b -Filter *.ps1 -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'smoke.ps1' })
foreach ($lf in ($lintFiles | Sort-Object FullName -Unique)) {
    $lines = @()
    try { $lines = [System.IO.File]::ReadAllLines($lf.FullName) } catch {}
    foreach ($ln in $lines) {
        if ($ln.TrimStart().StartsWith('#')) { continue }   # skip comment lines (docs may mention the pattern)
        $dm = [regex]::Match($ln, 'ConvertTo-Json[^|]*?-Depth\s+(\d+)')
        if ($dm.Success -and [int]$dm.Groups[1].Value -ge 12) { $failed += "LINT: $($lf.Name): ConvertTo-Json -Depth $($dm.Groups[1].Value) (>=12 OOM risk; use <=10 + flat DTO)" }
        if ($ln -match 'Get-Content[^|]*-Raw[^|]*\|\s*ConvertTo-Json -Depth 10') { $failed += "LINT: $($lf.Name): Get-Content -Raw piped into ConvertTo-Json -Depth 10 (ETS OOM; use ReadAllText)" }
    }
}

# 2. Auth (same pattern as watchdog)
$pw = $null
$usr = 'timur'
try {
    $a = Get-Content (Join-Path $b 'auth.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $pw = [string]$a.password
    $usr = [string]$a.user
} catch {}
$cred = $null
if ($pw) {
    $cred = New-Object System.Management.Automation.PSCredential(
        $usr, (ConvertTo-SecureString $pw -AsPlainText -Force))
}

function Probe($url) {
    try {
        $p = @{ UseBasicParsing = $true; Uri = $url; TimeoutSec = 8 }
        if ($cred) { $p.Credential = $cred }
        return (Invoke-WebRequest @p).StatusCode
    } catch {
        return 0
    }
}

# 3. /api/status
$s = Probe 'http://localhost:8787/api/status'
if ($s -ne 200) { $failed += "HTTP /api/status = $s" }

# 4. /api/memory
$m = Probe 'http://localhost:8787/api/memory'
if ($m -ne 200) { $failed += "HTTP /api/memory = $m" }

# 5. Mini-task: /api/messages (exercises conversation store, read-only)
$ms = Probe 'http://localhost:8787/api/messages'
if ($ms -ne 200) { $failed += "HTTP /api/messages = $ms" }

# 6. /api/radar + /api/plan -- the endpoints that crashed the host; a fast 200 proves no OOM hang
$rd = Probe 'http://localhost:8787/api/radar'
if ($rd -ne 200) { $failed += "HTTP /api/radar = $rd" }
$pl = Probe 'http://localhost:8787/api/plan'
if ($pl -ne 200) { $failed += "HTTP /api/plan = $pl" }

# 7. Mobile UI invariant -- planToggle must be REACHABLE on mobile (NOT buried inside the
# `⋮`-menu secondary group). Catches the regression where "no plan board on mobile" shipped
# 2026-05-26 even though the button was in the DOM (commit claimed done; UX was broken).
$auditScript = Join-Path $b 'tools\ui_audit.ps1'
if (Test-Path $auditScript) {
    $auditOut = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $auditScript -RequireId planToggle -RequireOutside btnsSecondary -Width 390 2>&1
    if ($LASTEXITCODE -ne 0) { $failed += ("UI-AUDIT: " + ($auditOut -join '; ')) }
}

# 8. Pre-flight gate -- verify Get-PreflightBlockers loads and returns valid {Hard,Soft}.
# git mid-op markers in Hard always fail smoke; codex.lock / doctor_active are transient
# (active coder session, doctor working) and tolerated -- not a sign of unhealthy code.
$pfScript = Join-Path $b 'lib\common.ps1'
if (Test-Path $pfScript) {
    $pfArg = $pfScript -replace "'","''"
    $pfRaw = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "
        `$ErrorActionPreference = 'SilentlyContinue'
        . '$pfArg'
        if (Get-Command Get-PreflightBlockers -ErrorAction SilentlyContinue) {
            `$r = Get-PreflightBlockers
            [pscustomobject]@{ ok=`$true; hard=@(`$r.Hard); soft=@(`$r.Soft) } | ConvertTo-Json -Compress -Depth 5
        } else {
            [pscustomobject]@{ ok=`$false; hard=@('Get-PreflightBlockers not found'); soft=@() } | ConvertTo-Json -Compress -Depth 5
        }
    " 2>&1
    $pfText = ($pfRaw | ForEach-Object { [string]$_ }) -join "`n"
    $pfStart = $pfText.IndexOf('{')
    $pfEnd = $pfText.LastIndexOf('}')
    if ($pfStart -lt 0 -or $pfEnd -le $pfStart) {
        $failed += "PREFLIGHT: невалидный вывод Get-PreflightBlockers: $pfText"
    } else {
        try {
            $pfObj = $pfText.Substring($pfStart, $pfEnd - $pfStart + 1) | ConvertFrom-Json
            if (-not [bool]$pfObj.ok) {
                $hardStr = @($pfObj.hard | ForEach-Object { [string]$_ }) -join '; '
                $failed += "PREFLIGHT: функция не загрузилась ($hardStr)"
            } else {
                $gitHard = @($pfObj.hard | Where-Object { [string]$_ -match 'git mid-op' })
                foreach ($h in $gitHard) { $failed += "PREFLIGHT-HARD: $h" }
                if (-not $pfObj.PSObject.Properties['soft']) { $failed += "PREFLIGHT: .Soft отсутствует в ответе" }
                if (-not $pfObj.PSObject.Properties['hard']) { $failed += "PREFLIGHT: .Hard отсутствует в ответе" }
            }
        } catch {
            $failed += "PREFLIGHT: не удалось разобрать JSON: $($_.Exception.Message)"
        }
    }
} else {
    $failed += "PREFLIGHT: lib\common.ps1 не найден"
}

# Result
if ($failed.Count -eq 0) {
    Write-Output "SMOKE OK ($($ps1s.Count) ps1 ok, endpoints 200)"
    exit 0
} else {
    $failed | ForEach-Object { Write-Output "SMOKE FAIL: $_" }
    exit 1
}
