[CmdletBinding()]
param(
  [string]$Url = 'http://localhost:8787',
  [int]$Width = 1920,
  [int]$Height = 1080,
  [switch]$Mobile,
  [string]$OutDir = '',
  [int]$WaitMs = 2500,
  [int]$MaxRetries = 2,
  [switch]$SkipVision
)

$ErrorActionPreference = 'Stop'

if ($Mobile) {
  $Width = 390
  $Height = 844
}
if ($WaitMs -lt 0) { $WaitMs = 0 }
if ($MaxRetries -lt 0) { $MaxRetries = 0 }

$root = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $root 'files\screenshots'
} elseif (-not [System.IO.Path]::IsPathRooted($OutDir)) {
  $OutDir = Join-Path $root $OutDir
}
if (-not (Test-Path $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

function Get-BrowserPath {
  $candidates = @(
    'C:\Program Files\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
    'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
  )
  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) { return $candidate }
  }
  return ''
}

function Get-LocalAuthUrl {
  param(
    [string]$OriginalUrl,
    [string]$BridgeRoot
  )

  try { $uri = [Uri]$OriginalUrl } catch { return $OriginalUrl }
  if ($uri.Scheme -notin @('http', 'https')) { return $OriginalUrl }
  if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo)) { return $OriginalUrl }
  if (-not ($uri.IsLoopback -or $uri.Host -in @('localhost', '127.0.0.1', '::1'))) { return $OriginalUrl }

  # auth.json lives in the protected store outside the bridge (Ф0.4); fall back to legacy in-bridge path.
  $privAuth = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.bridge-private\auth.json' } else { '' }
  $authPath = if ($privAuth -and (Test-Path $privAuth)) { $privAuth } else { Join-Path $BridgeRoot 'auth.json' }
  if (-not (Test-Path $authPath)) { return $OriginalUrl }

  try {
    $auth = Get-Content -LiteralPath $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$auth.user) -or [string]::IsNullOrWhiteSpace([string]$auth.password)) {
      return $OriginalUrl
    }
    $builder = [UriBuilder]$uri
    $builder.UserName = [string]$auth.user
    $builder.Password = [string]$auth.password
    return $builder.Uri.AbsoluteUri
  } catch {
    return $OriginalUrl
  }
}

function New-VisitOutputPath {
  param(
    [string]$Directory,
    [int]$ShotWidth,
    [int]$ShotHeight
  )
  $name = "visit_$(Get-Date -Format 'yyyyMMdd_HHmmss')_${ShotWidth}x${ShotHeight}.png"
  return Join-Path $Directory $name
}

function Invoke-HeadlessScreenshot {
  param(
    [string]$Browser,
    [string]$ShotUrl,
    [string]$OutputPath,
    [int]$ShotWidth,
    [int]$ShotHeight,
    [int]$DelayMs
  )

  if ([string]::IsNullOrWhiteSpace($Browser) -or -not (Test-Path $Browser)) {
    return $false
  }

  $visitRuntimeDir = Join-Path $root 'runtime\visit'
  try { [void](New-Item -ItemType Directory -Path $visitRuntimeDir -Force) } catch { return $false }
  $profileDir = Join-Path $visitRuntimeDir ('visit_' + [guid]::NewGuid().ToString('N').Substring(0,8))
  $crashDir = Join-Path $profileDir 'crash'
  try {
    [void](New-Item -ItemType Directory -Path $profileDir -Force)
    [void](New-Item -ItemType Directory -Path $crashDir -Force)
  } catch { return $false }

  $args = @(
    '--headless=new',
    "--window-size=$ShotWidth,$ShotHeight",
    '--hide-scrollbars'
  )
  if ($DelayMs -gt 0) {
    $args += "--virtual-time-budget=$DelayMs"
  }
  $args += @(
    "--screenshot=$OutputPath",
    '--disable-gpu',
    '--no-sandbox',
    '--disable-breakpad',
    '--disable-crash-reporter',
    '--disable-crashpad',
    "--crash-dumps-dir=$crashDir",
    "--user-data-dir=$profileDir",
    $ShotUrl
  )
  try {
    $process = Start-Process -FilePath $Browser -ArgumentList $args -PassThru -WindowStyle Hidden
    $waitMs = [Math]::Max(5000, $DelayMs + 10000)
    if (-not $process.WaitForExit($waitMs)) {
      try { $process.Kill() | Out-Null } catch {}
      return $false
    }
    if ($process.ExitCode -ne 0 -and -not (Test-Path $OutputPath)) { return $false }
  } catch {
    return $false
  } finally {
    try { Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
  return (Test-Path $OutputPath)
}

function Get-GeminiVisionVerdict {
  param(
    [string]$PngPath,
    [string]$OriginalUrl,
    [string]$BridgeRoot
  )

  if ($SkipVision) { return 'SKIPPED' }
  if (-not (Test-Path $PngPath)) { return 'VISION_ERROR' }

  # secrets.json lives in the protected store outside the bridge (Ф0.4); fall back to legacy in-bridge path.
  $privSec = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.bridge-private\secrets.json' } else { '' }
  $secretsPath = if ($privSec -and (Test-Path $privSec)) { $privSec } else { Join-Path $BridgeRoot 'secrets.json' }
  if (-not (Test-Path $secretsPath)) { return 'SKIPPED' }

  try {
    $secrets = Get-Content -LiteralPath $secretsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $key = [string]$secrets.geminiApiKey
  } catch {
    return 'SKIPPED'
  }
  if ([string]::IsNullOrWhiteSpace($key)) { return 'SKIPPED' }

  try {
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
    $base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($PngPath))
    $prompt = "Это техническая проверка скриншота страницы $OriginalUrl. Верни ОДНО слово из списка: OK, LOADING, CAPTCHA, BLOCKED, ERROR, BLANK, REDIRECT_BAD, NEED_AUTH, NEED_SCROLL, UNKNOWN. OK = страница реально отрисована и видны элементы интерфейса/текст/кнопки, даже если основная область контента пустая. BLANK = почти весь кадр однотонный и без видимых UI-элементов. Только слово, ничего лишнего."
    $bodyObj = @{
      contents = @(
        @{
          parts = @(
            @{
              inlineData = @{
                mimeType = 'image/png'
                data = $base64
              }
            },
            @{ text = $prompt }
          )
        }
      )
      generationConfig = @{
        temperature = 0
      }
    }
    $body = $bodyObj | ConvertTo-Json -Depth 10 -Compress
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes($body)
    $allowed = @('OK', 'LOADING', 'CAPTCHA', 'BLOCKED', 'ERROR', 'BLANK', 'REDIRECT_BAD', 'NEED_AUTH', 'NEED_SCROLL', 'UNKNOWN')
    $models = @('gemini-2.0-flash', 'gemini-2.5-flash')

    foreach ($model in $models) {
      try {
        $endpoint = "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=$key"
        $response = Invoke-RestMethod -Method Post -Uri $endpoint -ContentType 'application/json; charset=utf-8' -Body $bodyBytes -TimeoutSec 30
        $candidate = @($response.candidates)[0]
        $part = @($candidate.content.parts)[0]
        $text = ([string]$part.text).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { return 'UNKNOWN' }

        $first = ([regex]::Match($text.ToUpperInvariant(), '^\s*([A-Z_]+)')).Groups[1].Value
        if ($allowed -contains $first) { return $first }
        return 'UNKNOWN'
      } catch {
        if ($model -eq $models[-1]) { throw }
      }
    }

    return 'VISION_ERROR'
  } catch {
    return 'VISION_ERROR'
  }
}

function Save-VisitResult {
  param(
    [object]$Result,
    [string]$PngPath
  )

  $json = $Result | ConvertTo-Json -Depth 8 -Compress
  $resultPath = "$PngPath.result.json"
  [IO.File]::WriteAllText($resultPath, $json, (New-Object Text.UTF8Encoding($false)))
  return $json
}

$browser = Get-BrowserPath
$shotUrl = Get-LocalAuthUrl -OriginalUrl $Url -BridgeRoot $root
$retriesUsed = 0
$outPath = ''
$verdict = 'UNKNOWN'
$status = 'OK'

while ($true) {
  $outPath = New-VisitOutputPath -Directory $OutDir -ShotWidth $Width -ShotHeight $Height
  $screenshotOk = Invoke-HeadlessScreenshot -Browser $browser -ShotUrl $shotUrl -OutputPath $outPath -ShotWidth $Width -ShotHeight $Height -DelayMs $WaitMs

  if (-not $screenshotOk) {
    $verdict = 'EDGE_FAILED'
    $status = 'ERROR'
    break
  }

  $verdict = Get-GeminiVisionVerdict -PngPath $outPath -OriginalUrl $Url -BridgeRoot $root
  if ($verdict -eq 'LOADING' -and $retriesUsed -lt $MaxRetries) {
    $retriesUsed++
    Start-Sleep -Seconds 3
    continue
  }

  if (@('OK', 'SKIPPED', 'UNKNOWN') -contains $verdict) {
    $status = 'OK'
  } else {
    $status = 'DEGRADED'
  }
  break
}

$result = [ordered]@{
  url = $Url
  width = $Width
  height = $Height
  status = $status
  verdict = $verdict
  path = $outPath
  retries = $retriesUsed
  timestamp = (Get-Date).ToString('o')
}

Write-Output (Save-VisitResult -Result $result -PngPath $outPath)
