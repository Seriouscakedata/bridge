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

# Result
if ($failed.Count -eq 0) {
    Write-Output "SMOKE OK ($($ps1s.Count) ps1 ok, endpoints 200)"
    exit 0
} else {
    $failed | ForEach-Object { Write-Output "SMOKE FAIL: $_" }
    exit 1
}
