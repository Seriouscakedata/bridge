# ui_audit.ps1 -- structural DOM audit for bridge UI. Bridge agents use this to PROVE a UI
# change is reachable (the gap that let "no plan board on mobile" ship: HTML had the element
# but it was buried inside `btns-secondary` behind the `⋮` menu). Checks structural invariants
# that survive CSS without needing a real browser. Optional headless-screenshot for visual proof.
# Usage:
#   .\tools\ui_audit.ps1 -RequireId planToggle -RequireOutside btnsSecondary
#   .\tools\ui_audit.ps1 -Path /memory -RequireText 'Радар' -RequireId tabRadar
#   .\tools\ui_audit.ps1 -Screenshot mobile.png -Width 390 -Height 844
[CmdletBinding()]
param(
  [string]$Path = '/',
  [string[]]$RequireId = @(),
  [string[]]$RequireText = @(),
  [string]$RequireOutside = '',     # id MUST NOT be inside this container id (e.g. btnsSecondary)
  [string]$Screenshot = '',
  [int]$Width = 390,
  [int]$Height = 844,
  [int]$Port = 8787
)
$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$url = "http://localhost:${Port}${Path}"
$auth = @{}
try {
  $a = Get-Content (Join-Path $root 'auth.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($a.password) { $auth = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(($a.user + ':' + $a.password))) } }
} catch {}

try { $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 12 -Headers $auth }
catch { Write-Output ("FAIL fetch: " + $_.Exception.Message); exit 1 }
if ($r.StatusCode -ne 200) { Write-Output ("FAIL HTTP " + $r.StatusCode); exit 1 }
$html = [string]$r.Content
$problems = @()

foreach ($id in $RequireId) {
  if ($html -notmatch ('id="' + [regex]::Escape($id) + '"')) { $problems += "missing id '$id'"; continue }
  $tag = [regex]::Match($html, '<[^>]*id="' + [regex]::Escape($id) + '"[^>]*>')
  if ($tag.Success -and $tag.Value -match 'style="[^"]*display\s*:\s*none') { $problems += "id '$id' has inline display:none" }
}

if ($RequireOutside -and $RequireId.Count -gt 0) {
  # For each required id, ensure the parent container with id=$RequireOutside does NOT contain it.
  # We slice from the container open-tag to its corresponding close (via depth-counting on <div>).
  $openIdx = $html.IndexOf('id="' + $RequireOutside + '"')
  if ($openIdx -ge 0) {
    $tagStart = $html.LastIndexOf('<', $openIdx)
    if ($tagStart -ge 0) {
      $depth = 0; $i = $tagStart; $sliceEnd = -1
      while ($i -lt $html.Length) {
        $next = [regex]::Match($html.Substring($i), '<(/?)div\b')
        if (-not $next.Success) { break }
        $i += $next.Index
        if ($next.Groups[1].Value -eq '/') {
          $depth--; if ($depth -le 0) { $sliceEnd = $i + $next.Length; break }
        } else { $depth++ }
        $i += $next.Length
      }
      if ($sliceEnd -gt $tagStart) {
        $slice = $html.Substring($tagStart, $sliceEnd - $tagStart)
        foreach ($id in $RequireId) {
          if ($slice -match ('id="' + [regex]::Escape($id) + '"')) {
            $problems += "id '$id' is inside container '$RequireOutside' (must be OUTSIDE for mobile reachability)"
          }
        }
      }
    }
  }
}

foreach ($t in $RequireText) {
  if ($html -notmatch [regex]::Escape($t)) { $problems += "missing text '$t'" }
}

if ($Screenshot) {
  $edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
  if (-not (Test-Path $edge)) { $edge = 'C:\Program Files\Microsoft\Edge\Application\msedge.exe' }
  if (-not (Test-Path $edge)) {
    foreach ($p in 'C:\Program Files\Google\Chrome\Application\chrome.exe','C:\Program Files (x86)\Google\Chrome\Application\chrome.exe') {
      if (Test-Path $p) { $edge = $p; break }
    }
  }
  if (Test-Path $edge) {
    $outPath = if ([System.IO.Path]::IsPathRooted($Screenshot)) { $Screenshot } else { Join-Path $root $Screenshot }
    $outDir = Split-Path $outPath -Parent
    if ($outDir -and -not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $shotUrl = $url
    if ($auth.Count -gt 0) {
      $authUserPass = ($a.user + ':' + $a.password)
      $shotUrl = "http://${authUserPass}@localhost:${Port}${Path}"
    }
    $shotArgs = @('--headless=new', "--window-size=${Width},${Height}", '--hide-scrollbars', "--screenshot=$outPath", '--disable-gpu', '--no-sandbox', $shotUrl)
    & $edge @shotArgs 2>$null | Out-Null
    if (Test-Path $outPath) { Write-Output ("screenshot: " + $outPath + " (" + [int]((Get-Item $outPath).Length/1KB) + "KB)") }
    else { $problems += "screenshot failed (Edge/Chrome ran but no file)" }
  } else { $problems += "screenshot skipped: no Edge/Chrome found" }
}

if ($problems.Count -gt 0) {
  Write-Output ("FAIL " + ($problems -join '; '))
  exit 1
}
$outsideTag = ''
if ($RequireOutside) { $outsideTag = " outside=$RequireOutside" }
Write-Output ("OK " + $Path + " | id=" + ($RequireId -join ',') + " text=" + ($RequireText -join ',') + $outsideTag + " | html=" + [int]($html.Length/1KB) + "KB")
exit 0
