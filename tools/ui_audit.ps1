# ui_audit.ps1 -- structural DOM audit for bridge UI. Bridge agents use this to PROVE a UI
# change is reachable (the gap that let "no plan board on mobile" ship: HTML had the element
# but it was buried inside `btns-secondary` behind the `⋮` menu). Checks structural invariants
# that survive CSS without needing a real browser. Optional headless-screenshot for visual proof.
# Usage:
#   .\tools\ui_audit.ps1 -RequireId planToggle -RequireOutside btnsSecondary
#   .\tools\ui_audit.ps1 -RequireId panelsToggleMobile,pauseToggleMobile -RequireInside btnsSecondary
#   .\tools\ui_audit.ps1 -Path /memory -RequireText 'Радар' -RequireId tabRadar
#   .\tools\ui_audit.ps1 -Screenshot mobile.png -Width 390 -Height 844
[CmdletBinding()]
param(
  [string]$Path = '/',
  [string[]]$RequireId = @(),
  [string[]]$RequireText = @(),
  [string]$RequireOutside = '',     # id MUST NOT be inside this container id (e.g. btnsSecondary)
  [string]$RequireInside = '',      # id MUST be inside this container id
  [int]$MaxHeaderButtons = 0,       # max visible direct buttons in #btnsPrimary for the requested Width
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
  # auth.json lives in the protected store outside the bridge (Ф0.4); fall back to legacy in-bridge path.
  $privAuth = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.bridge-private\auth.json' } else { '' }
  $authP = if ($privAuth -and (Test-Path $privAuth)) { $privAuth } else { Join-Path $root 'auth.json' }
  $a = Get-Content $authP -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($a.password) { $auth = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(($a.user + ':' + $a.password))) } }
} catch {}

try { $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 12 -Headers $auth }
catch { Write-Output ("FAIL fetch: " + $_.Exception.Message); exit 1 }
if ($r.StatusCode -ne 200) { Write-Output ("FAIL HTTP " + $r.StatusCode); exit 1 }
$html = [string]$r.Content
$problems = @()

function Get-DivSlice {
  param(
    [string]$Html,
    [string]$Id
  )
  $openIdx = $Html.IndexOf('id="' + $Id + '"')
  if ($openIdx -lt 0) { return $null }
  $tagStart = $Html.LastIndexOf('<', $openIdx)
  if ($tagStart -lt 0) { return $null }
  $depth = 0; $i = $tagStart; $sliceEnd = -1
  while ($i -lt $Html.Length) {
    $next = [regex]::Match($Html.Substring($i), '<(/?)div\b')
    if (-not $next.Success) { break }
    $i += $next.Index
    if ($next.Groups[1].Value -eq '/') {
      $depth--
      if ($depth -le 0) { $sliceEnd = $i + $next.Length; break }
    } else {
      $depth++
    }
    $i += $next.Length
  }
  if ($sliceEnd -gt $tagStart) { return $Html.Substring($tagStart, $sliceEnd - $tagStart) }
  return $null
}

foreach ($id in $RequireId) {
  if ($html -notmatch ('id="' + [regex]::Escape($id) + '"')) { $problems += "missing id '$id'"; continue }
  $tag = [regex]::Match($html, '<[^>]*id="' + [regex]::Escape($id) + '"[^>]*>')
  if ($tag.Success -and $tag.Value -match 'style="[^"]*display\s*:\s*none') { $problems += "id '$id' has inline display:none" }
}

if ($RequireOutside -and $RequireId.Count -gt 0) {
  # For each required id, ensure the parent container with id=$RequireOutside does NOT contain it.
  # We slice from the container open-tag to its corresponding close (via depth-counting on <div>).
  $slice = Get-DivSlice -Html $html -Id $RequireOutside
  if ($null -ne $slice) {
    foreach ($id in $RequireId) {
      if ($slice -match ('id="' + [regex]::Escape($id) + '"')) {
        $problems += "id '$id' is inside container '$RequireOutside' (must be OUTSIDE for mobile reachability)"
      }
    }
  }
}

if ($RequireInside -and $RequireId.Count -gt 0) {
  $slice = Get-DivSlice -Html $html -Id $RequireInside
  if ($null -eq $slice) {
    $problems += "container '$RequireInside' not found"
  } else {
    foreach ($id in $RequireId) {
      if ($slice -notmatch ('id="' + [regex]::Escape($id) + '"')) {
        $problems += "id '$id' is not inside container '$RequireInside'"
      }
    }
  }
}

foreach ($t in $RequireText) {
  if ($html -notmatch [regex]::Escape($t)) { $problems += "missing text '$t'" }
}

if ($MaxHeaderButtons -gt 0) {
  $primary = Get-DivSlice -Html $html -Id 'btnsPrimary'
  if ($null -eq $primary) {
    $problems += "container 'btnsPrimary' not found"
  } else {
    $secondaryIdx = $primary.IndexOf('id="btnsSecondary"')
    if ($secondaryIdx -ge 0) { $primary = $primary.Substring(0, $secondaryIdx) }
    $visible = @()
    foreach ($m in [regex]::Matches($primary, '<button\b[^>]*>')) {
      $tag = $m.Value
      $idMatch = [regex]::Match($tag, 'id="([^"]+)"')
      $id = if ($idMatch.Success) { $idMatch.Groups[1].Value } else { '<button>' }
      $classMatch = [regex]::Match($tag, 'class="([^"]*)"')
      $classes = if ($classMatch.Success) { $classMatch.Groups[1].Value } else { '' }
      $inlineHidden = $tag -match 'style="[^"]*display\s*:\s*none'
      $hiddenByWidth = (($Width -le 640) -and ($classes -match '(^|\s)hbtn-desktop-only(\s|$)')) -or (($Width -ge 641) -and ($classes -match '(^|\s)hbtn-mobile-only(\s|$)'))
      if (-not $inlineHidden -and -not $hiddenByWidth) { $visible += $id }
    }
    if ($visible.Count -gt $MaxHeaderButtons) {
      $problems += "visible header buttons $($visible.Count) > ${MaxHeaderButtons}: $($visible -join ',')"
    }
  }
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
$insideTag = ''
if ($RequireInside) { $insideTag = " inside=$RequireInside" }
$maxTag = ''
if ($MaxHeaderButtons -gt 0) { $maxTag = " maxHeaderButtons=$MaxHeaderButtons" }
Write-Output ("OK " + $Path + " | id=" + ($RequireId -join ',') + " text=" + ($RequireText -join ',') + $outsideTag + $insideTag + $maxTag + " | html=" + [int]($html.Length/1KB) + "KB")
exit 0
