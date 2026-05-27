# server.ps1 -- local web UI for the bridge (HttpListener, no admin needed).
. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\plan.ps1')
. (Join-Path $PSScriptRoot 'lib\radar.ps1')
. (Join-Path $PSScriptRoot 'lib\metrics.ps1')

$cfg  = Get-BridgeConfig
$port = [int]$cfg.port
$root = Get-BridgeRoot
$indexPath = Join-Path $root 'web\index.html'
$filesPath = Get-FilesPath
$maxUploadBytes = 25 * 1024 * 1024

# Authentication (HTTP Basic). Credentials live in auth.json next to config.
$authPath = Join-Path $root 'auth.json'
$authUser = $null; $authPass = $null
if (Test-Path $authPath) {
  $a = Get-Content $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $authUser = [string]$a.user; $authPass = [string]$a.password
}

$null = Initialize-Bridge   # ensure files exist
$serverStartTime = Get-Date
$healthMemoryStamp = [datetime]::MinValue
$healthMemoryCount = 0
$healthConversationStamp = [datetime]::MinValue
$healthConversationLastSeq = 0
$healthConversationErrorCount = 0
$healthGitStamp = [datetime]::MinValue
$healthGitHead = ''

# Try to listen on ALL interfaces (LAN access). Needs a urlacl reservation
# (see setup-lan.ps1). Fall back to localhost-only if that isn't set up yet.
function New-BridgeListener($prefix) {
  $l = New-Object System.Net.HttpListener
  $l.Prefixes.Add($prefix)
  $l.Start()
  return $l
}
$listener = $null
foreach ($pfx in @("http://+:$port/", "http://localhost:$port/")) {
  try { $listener = New-BridgeListener $pfx; Write-Host "Bridge UI listening on $pfx"; break }
  catch { Write-Host "Cannot bind $pfx ($($_.Exception.Message))" }
}
if (-not $listener) { throw "Could not start HTTP listener on port $port" }

function Send-Bytes {
  param($ctx, [byte[]]$Bytes, [string]$ContentType, [int]$Status = 200)
  $ctx.Response.StatusCode = $Status
  $ctx.Response.ContentType = $ContentType
  $ctx.Response.ContentLength64 = $Bytes.Length
  $ctx.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
  $ctx.Response.OutputStream.Close()
}
function Set-NoStoreHeaders {
  param($ctx)
  $ctx.Response.AddHeader('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
  $ctx.Response.AddHeader('Pragma', 'no-cache')
  $ctx.Response.AddHeader('Expires', '0')
}
function Send-Text {
  param($ctx, [string]$Text, [string]$ContentType = 'text/plain; charset=utf-8', [int]$Status = 200)
  Set-NoStoreHeaders $ctx
  Send-Bytes $ctx ([System.Text.Encoding]::UTF8.GetBytes($Text)) $ContentType $Status
}
function Read-Body {
  param($ctx)
  # Always decode the request body as UTF-8. Browser fetch() sends JSON without a
  # charset, so Request.ContentEncoding can default to CP1251 and mangle Russian.
  $sr = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
  $body = $sr.ReadToEnd(); $sr.Close()
  return $body
}
function Get-QueryParamUtf8 {
  param($ctx, [string]$Name)
  $raw = ''
  try { $raw = [string]$ctx.Request.Url.Query } catch { $raw = '' }
  if ($raw.StartsWith('?')) { $raw = $raw.Substring(1) }
  foreach ($part in @($raw -split '&')) {
    if ([string]::IsNullOrWhiteSpace($part)) { continue }
    $kv = $part.Split([char]'=', 2)
    $k = [System.Net.WebUtility]::UrlDecode($kv[0])
    if ($k -ne $Name) { continue }
    if ($kv.Count -lt 2) { return '' }
    return [System.Net.WebUtility]::UrlDecode($kv[1])
  }
  try { return [string]$ctx.Request.QueryString[$Name] } catch { return '' }
}
function Test-Auth {
  param($ctx)
  if (-not $authPass) { return $true }   # no password configured -> open
  $h = $ctx.Request.Headers['Authorization']
  if ($h -and $h.StartsWith('Basic ')) {
    try {
      $raw = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($h.Substring(6)))
      $i = $raw.IndexOf(':')
      if ($i -ge 0) {
        $u = $raw.Substring(0,$i); $p = $raw.Substring($i+1)
        if ($u -eq $authUser -and $p -eq $authPass) { return $true }
      }
    } catch {}
  }
  $ctx.Response.AddHeader('WWW-Authenticate','Basic realm="AI Bridge"')
  Send-Text $ctx 'Authentication required' 'text/plain; charset=utf-8' 401
  return $false
}

function Send-FileNotFound {
  param($ctx)
  Send-Text $ctx 'not found' 'text/plain; charset=utf-8' 404
}

function Get-SafeServedFilePath {
  param([string]$Name)
  if ([string]::IsNullOrWhiteSpace($Name)) { return $null }
  $rootFull = [System.IO.Path]::GetFullPath($filesPath).TrimEnd('\','/')
  $rootWithSep = $rootFull + [System.IO.Path]::DirectorySeparatorChar
  $candidate = [System.IO.Path]::GetFullPath((Join-Path $filesPath $Name))
  if (-not $candidate.StartsWith($rootWithSep, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
  if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $null }
  return $candidate
}

try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
      $path   = $ctx.Request.Url.AbsolutePath
      $method = $ctx.Request.HttpMethod
      if ($method -eq 'GET' -and $path -eq '/api/health') {
        $now = Get-Date
        $uptimeSec = [int]([Math]::Floor(($now - $serverStartTime).TotalSeconds))
        $statePath = Join-Path $root 'channels\main\state.json'
        $stateRaw = ''
        if (Test-Path -LiteralPath $statePath) {
          try { $stateRaw = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8) } catch {}
        }
        $hbAge    = 9999
        $hbRaw    = ''
        $mHb = [regex]::Match($stateRaw, '"heartbeat"\s*:\s*"([^"]*)"')
        if ($mHb.Success) { $hbRaw = $mHb.Groups[1].Value }
        if (-not [string]::IsNullOrWhiteSpace($hbRaw)) {
          try { $hbAge = [int]([Math]::Floor(($now - [datetime]::Parse($hbRaw)).TotalSeconds)) } catch {}
        }
        $hPaused = $false
        $mPaused = [regex]::Match($stateRaw, '"paused"\s*:\s*(true|false)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($mPaused.Success) { $hPaused = ([string]$mPaused.Groups[1].Value).ToLowerInvariant() -eq 'true' }
        $hStatus = ''
        $mStatus = [regex]::Match($stateRaw, '"status"\s*:\s*"([^"]*)"')
        if ($mStatus.Success) { $hStatus = $mStatus.Groups[1].Value }
        $hLastSeq = 0
        $mStateSeq = [regex]::Match($stateRaw, '"lastSeq"\s*:\s*(\d+)')
        if ($mStateSeq.Success) { [void][int]::TryParse($mStateSeq.Groups[1].Value, [ref]$hLastSeq) }
        $psActive = 0
        foreach ($mRun in [regex]::Matches($stateRaw, '"status"\s*:\s*"running"')) { $psActive++ }
        $gitHead = $healthGitHead
        try {
          $headFile = Join-Path $root '.git\HEAD'
          $gitStamp = if (Test-Path -LiteralPath $headFile) { (Get-Item -LiteralPath $headFile).LastWriteTimeUtc } else { [datetime]::MinValue }
          $refFile = $null
          if ($gitStamp -ne [datetime]::MinValue) {
            $headLine = [System.IO.File]::ReadAllText($headFile, [System.Text.Encoding]::UTF8).Trim()
            if ($headLine -like 'ref: *') {
              $refName = $headLine.Substring(5).Trim() -replace '/', '\'
              $refFile = Join-Path (Join-Path $root '.git') $refName
              if (Test-Path -LiteralPath $refFile) { $gitStamp = (Get-Item -LiteralPath $refFile).LastWriteTimeUtc }
            }
          }
          if ($gitStamp -ne $healthGitStamp) {
            $newHead = ''
            if (Test-Path -LiteralPath $headFile) {
              $headLine = [System.IO.File]::ReadAllText($headFile, [System.Text.Encoding]::UTF8).Trim()
              if ($headLine -like 'ref: *') {
                $refName = $headLine.Substring(5).Trim() -replace '/', '\'
                $refFile = Join-Path (Join-Path $root '.git') $refName
                if (Test-Path -LiteralPath $refFile) {
                  $sha = [System.IO.File]::ReadAllText($refFile, [System.Text.Encoding]::UTF8).Trim()
                  if ($sha.Length -ge 7) { $newHead = $sha.Substring(0,7) }
                }
              } elseif ($headLine.Length -ge 7) {
                $newHead = $headLine.Substring(0,7)
              }
            }
            $healthGitStamp = $gitStamp
            $healthGitHead = $newHead
          }
          $gitHead = $healthGitHead
        } catch { $gitHead = $healthGitHead }
        $memCount = 0
        $memPath  = Join-Path $root 'memory\memory.jsonl'
        if (Test-Path -LiteralPath $memPath) {
          $memStamp = (Get-Item -LiteralPath $memPath).LastWriteTimeUtc
          if ($memStamp -ne $healthMemoryStamp) {
            $newMemCount = 0
            $srMem = $null
            try {
              $srMem = [System.IO.StreamReader]::new($memPath, [System.Text.Encoding]::UTF8)
              while ($null -ne $srMem.ReadLine()) { $newMemCount++ }
              $healthMemoryCount = $newMemCount
              $healthMemoryStamp = $memStamp
            } finally {
              if ($null -ne $srMem) { $srMem.Close(); $srMem.Dispose() }
            }
          }
          $memCount = $healthMemoryCount
        } else {
          $healthMemoryStamp = [datetime]::MinValue
          $healthMemoryCount = 0
        }
        $errCount = $healthConversationErrorCount
        $convPath = Join-Path $root 'channels\main\conversation.jsonl'
        if (Test-Path -LiteralPath $convPath) {
          $convStamp = (Get-Item -LiteralPath $convPath).LastWriteTimeUtc
          if ($convStamp -ne $healthConversationStamp) {
            $newErrCount = 0
            $newLastSeq = 0
            $cutoff24 = $now.AddHours(-24)
            $lines = [System.IO.File]::ReadLines($convPath) | Select-Object -Last 500
            foreach ($ln in $lines) {
              $mSeq = [regex]::Match($ln, '"seq"\s*:\s*(\d+)')
              if ($mSeq.Success) {
                $seqTmp = 0
                if ([int]::TryParse($mSeq.Groups[1].Value, [ref]$seqTmp) -and $seqTmp -gt $newLastSeq) { $newLastSeq = $seqTmp }
              }
              if ($ln.IndexOf('"from":"system"') -lt 0) { continue }
              if ($ln -notmatch '(?:❌|💥)') { continue }
              $mTs = [regex]::Match($ln, '"ts"\s*:\s*"([^"]+)"')
              if (-not $mTs.Success) { $newErrCount++; continue }
              try { if ([datetime]::Parse($mTs.Groups[1].Value) -ge $cutoff24) { $newErrCount++ } } catch { $newErrCount++ }
            }
            $healthConversationStamp = $convStamp
            $healthConversationLastSeq = $newLastSeq
            $healthConversationErrorCount = $newErrCount
          }
          if ($healthConversationLastSeq -gt $hLastSeq) { $hLastSeq = $healthConversationLastSeq }
          $errCount = $healthConversationErrorCount
        } else {
          $healthConversationStamp = [datetime]::MinValue
          $healthConversationLastSeq = 0
          $healthConversationErrorCount = 0
          $errCount = 0
        }
        $hOk = ($hbAge -lt 120) -and (-not $hPaused) -and ($errCount -lt 10)
        $hJson = '{"ok":' + ($hOk.ToString().ToLower()) + `
          ',"uptime_sec":' + $uptimeSec + `
          ',"heartbeat_age_sec":' + $hbAge + `
          ',"paused":' + ($hPaused.ToString().ToLower()) + `
          ',"status":' + (("" + $hStatus) | ConvertTo-Json -Compress) + `
          ',"lastSeq":' + $hLastSeq + `
          ',"memory_count":' + $memCount + `
          ',"recent_error_count_24h":' + $errCount + `
          ',"git_head":' + (("" + $gitHead) | ConvertTo-Json -Compress) + `
          ',"parallel_streams_active":' + $psActive + '}'
        $ctx.Response.AddHeader('Access-Control-Allow-Origin', '*')
        Send-Text $ctx $hJson 'application/json; charset=utf-8'
        continue
      }
      if (-not (Test-Auth $ctx)) { continue }
      $path   = $ctx.Request.Url.AbsolutePath
      $method = $ctx.Request.HttpMethod

      if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
        $html = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8
        Send-Text $ctx $html 'text/html; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/messages') {
        $since = 0; [void][int]::TryParse($ctx.Request.QueryString['since'], [ref]$since)
        $msgs = Get-Messages -Since $since
        $json = '[' + (($msgs | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 10 }) -join ',') + ']'
        Send-Text $ctx $json 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/status') {
        # Phase 3 (full): ?channel=<slug> reads THAT channel's state.json; default = active marker.
        # The driver of each channel writes its own state independently, so this gives UI
        # an accurate per-tab "what's that channel's driver doing right now" view.
        $chParam = Get-QueryParamUtf8 $ctx 'channel'
        $prevPin = Get-PinnedChannel
        try {
          if (-not [string]::IsNullOrWhiteSpace($chParam)) { Set-PinnedChannel $chParam }
          $state = Read-State
        } finally { Set-PinnedChannel $prevPin }
        Send-Text $ctx ($state | ConvertTo-Json -Compress -Depth 10) 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path.StartsWith('/files/')) {
        $name = [System.Uri]::UnescapeDataString($path.Substring('/files/'.Length))
        $filePath = Get-SafeServedFilePath $name
        if (-not $filePath) {
          Send-FileNotFound $ctx
        } else {
          $mime = Get-MimeForExt ([System.IO.Path]::GetExtension($filePath))
          if (-not $mime.StartsWith('image/')) {
            $leaf = [System.IO.Path]::GetFileName($filePath).Replace('"','_')
            $ctx.Response.AddHeader('Content-Disposition', "attachment; filename=""$leaf""")
          }
          Send-Bytes $ctx ([System.IO.File]::ReadAllBytes($filePath)) $mime
        }
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/say') {
        $body = Read-Body $ctx | ConvertFrom-Json
        $text = [string]$body.text
        $atts = @()
        if ($null -ne $body.PSObject.Properties['attachments']) { $atts = @($body.attachments) }
        if (-not [string]::IsNullOrWhiteSpace($text) -or $atts.Count -gt 0) {
          [void](Add-Message -From user -Text $text -Attachments $atts)
        }
        Send-Text $ctx '{"ok":true}' 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/stt') {
        if ($ctx.Request.ContentLength64 -gt ($maxUploadBytes * 2)) {
          Send-Text $ctx '{"error":"audio upload too large"}' 'application/json; charset=utf-8' 413
          continue
        }
        try {
          $body = Read-Body $ctx | ConvertFrom-Json
          $mimeType = [string]$body.mimeType
          # Normalize mobile recorder MIME values before passing audio to Gemini.
          if ($mimeType -match '^([^;]+)') { $mimeType = $Matches[1].Trim().ToLowerInvariant() }
          if ($mimeType -eq 'audio/x-m4a') { $mimeType = 'audio/mp4' }
          if ($mimeType -eq 'audio/mpeg')  { $mimeType = 'audio/mp3' }
          if ([string]::IsNullOrWhiteSpace($mimeType)) { $mimeType = 'audio/mp4' }
          $audioData = [string]$body.data
          if ([string]::IsNullOrWhiteSpace($audioData)) { throw 'no audio data' }
          $audioData = $audioData -replace '\s+', ''
          try {
            $audioBytes = [Convert]::FromBase64String($audioData)
          } catch {
            throw 'bad audio base64'
          }
          if ($audioBytes.Length -lt 256) { throw 'audio data too small or invalid' }
          if ($audioBytes.Length -gt $maxUploadBytes) { throw 'audio upload too large' }

          $sttModel = if ($cfg.sttModel) { [string]$cfg.sttModel } else { 'gemini-2.5-flash' }
          $key = Get-Secret 'geminiApiKey'
          if (-not $key) { throw 'no geminiApiKey configured' }
          $sttUrl = "https://generativelanguage.googleapis.com/v1beta/models/${sttModel}:generateContent?key=$key"
          $sttBody = @{
            contents = @(@{
              parts = @(
                @{ text = 'Transcribe the audio recording. Return only the spoken words, no commentary or formatting.' },
                @{ inlineData = @{ mimeType = $mimeType; data = $audioData } }
              )
            })
            generationConfig = @{ temperature = 0.0 }
          }
          $r = Invoke-GeminiApi -Url $sttUrl -BodyObj $sttBody -TimeoutSec 60
          $parts = @($r.candidates[0].content.parts)
          $text = (($parts | ForEach-Object { [string]$_.text }) -join '').Trim()
          if ([string]::IsNullOrWhiteSpace($text)) { throw 'empty transcription response' }
          $result = @{ text = $text } | ConvertTo-Json -Compress
          Send-Text $ctx $result 'application/json; charset=utf-8'
        } catch {
          $errMsg = @{ error = $_.Exception.Message } | ConvertTo-Json -Compress
          Send-Text $ctx $errMsg 'application/json; charset=utf-8' 500
        }
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/upload') {
        if ($ctx.Request.ContentLength64 -gt ($maxUploadBytes * 2)) {
          Send-Text $ctx '{"ok":false,"error":"upload too large"}' 'application/json; charset=utf-8' 413
          continue
        }
        $body = Read-Body $ctx | ConvertFrom-Json
        $name = [string]$body.name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = 'upload.bin' }
        $text = [string]$body.text
        $data = [string]$body.dataB64
        if ([string]::IsNullOrWhiteSpace($data)) {
          Send-Text $ctx '{"ok":false,"error":"missing dataB64"}' 'application/json; charset=utf-8' 400
          continue
        }
        if ($data.StartsWith('data:')) {
          $comma = $data.IndexOf(',')
          if ($comma -lt 0) {
            Send-Text $ctx '{"ok":false,"error":"bad data url"}' 'application/json; charset=utf-8' 400
            continue
          }
          $data = $data.Substring($comma + 1)
        }
        $data = $data -replace '\s+', ''
        try {
          $bytes = [Convert]::FromBase64String($data)
        } catch {
          Send-Text $ctx '{"ok":false,"error":"bad base64"}' 'application/json; charset=utf-8' 400
          continue
        }
        if ($bytes.Length -gt $maxUploadBytes) {
          Send-Text $ctx '{"ok":false,"error":"upload too large"}' 'application/json; charset=utf-8' 413
          continue
        }
        $meta = Save-AttachmentBytes -Bytes $bytes -Name $name -Caption $text
        [void](Add-Message -From user -Text $text -Attachments @($meta))
        $json = ([ordered]@{ ok = $true; attachment = $meta } | ConvertTo-Json -Compress -Depth 10)
        Send-Text $ctx $json 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/screenshot') {
        $caption = ''
        $postMessage = $true
        if ($ctx.Request.ContentLength64 -gt 0) {
          try {
            $body = Read-Body $ctx | ConvertFrom-Json
            $caption = [string]$body.text
            if ($null -ne $body.PSObject.Properties['post']) { $postMessage = [bool]$body.post }
          } catch {
            $caption = ''
          }
        }
        $toolPath = Join-Path $root 'tools\screenshot.ps1'
        if (-not (Test-Path -LiteralPath $toolPath -PathType Leaf)) {
          Send-Text $ctx '{"ok":false,"error":"screenshot tool missing"}' 'application/json; charset=utf-8' 500
          continue
        }
        $shotOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $toolPath 2>&1)
        if ($LASTEXITCODE -ne 0) {
          $err = 'screenshot failed: ' + (($shotOutput | Out-String).Trim())
          $json = ([ordered]@{ ok = $false; error = $err } | ConvertTo-Json -Compress -Depth 5)
          Send-Text $ctx $json 'application/json; charset=utf-8' 500
          continue
        }
        $shotPath = [string]($shotOutput | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1)
        if (-not $shotPath) {
          Send-Text $ctx '{"ok":false,"error":"screenshot path missing"}' 'application/json; charset=utf-8' 500
          continue
        }
        $meta = Register-AttachmentPath -SourcePath ([string]$shotPath)
        if (-not $meta) {
          Send-Text $ctx '{"ok":false,"error":"screenshot attachment failed"}' 'application/json; charset=utf-8' 500
          continue
        }
        $text = if ([string]::IsNullOrWhiteSpace($caption)) { 'Снимок экрана' } else { $caption }
        $seq = $null
        if ($postMessage) { $seq = Add-Message -From user -Text $text -Attachments @($meta) }
        $json = ([ordered]@{ ok = $true; seq = $seq; attachment = $meta } | ConvertTo-Json -Compress -Depth 10)
        Send-Text $ctx $json 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/control') {
        # Phase 3 (full): control actions (pause/resume/kill/stop) target a SPECIFIC channel's
        # driver via ?channel=<slug> or body.channel; default = active marker. Restart is
        # supervisor-wide (signals all drivers via Kill-Bridge in supervisor.ps1).
        $body = Read-Body $ctx | ConvertFrom-Json
        $action = [string]$body.action
        $chParam = Get-QueryParamUtf8 $ctx 'channel'
        if ([string]::IsNullOrWhiteSpace($chParam) -and $null -ne $body.channel) { $chParam = [string]$body.channel }
        $prevPin = Get-PinnedChannel
        try {
          if (-not [string]::IsNullOrWhiteSpace($chParam)) { Set-PinnedChannel $chParam }
          if ($action -eq 'kill') {
            $apid = (Read-State).agent_pid
            Update-State { param($s) $s.abort = $true } | Out-Null
            if ($apid) { try { Start-Process taskkill -ArgumentList '/PID',([string]$apid),'/F','/T' -NoNewWindow -Wait } catch {} }
            [void](Add-Message -From system -Text "🛑 Стоп-кран нажат пользователем." -Kind event)
          } elseif ($action -eq 'restart') {
            $ctl = Join-Path (Get-BridgeRoot) 'control'
            if (-not (Test-Path $ctl)) { New-Item -ItemType Directory -Path $ctl -Force | Out-Null }
            Set-Content -LiteralPath (Join-Path $ctl 'restart.flag') -Value '1' -Encoding ASCII
            [void](Add-Message -From system -Text "♻ Запрошен перезапуск -- супервизор выполнит его без UAC." -Kind event)
          } else {
            Update-State {
              param($s)
              switch ($action) {
                'pause'  { $s.paused = $true }
                'resume' { $s.paused = $false; $s.stop = $false }
                'stop'   { $s.stop = $true; $s.status = 'stopped' }
              }
            } | Out-Null
            $label = @{pause='⏸ Пауза';resume='▶ Продолжаем';stop='⏹ Полная остановка'}[$action]
            if ($label) { [void](Add-Message -From system -Text "Управление: $label" -Kind event) }
          }
        } finally { Set-PinnedChannel $prevPin }
        Send-Text $ctx '{"ok":true}' 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and ($path -eq '/memory' -or $path -eq '/memory.html')) {
        $memHtmlPath = Join-Path $root 'web\memory.html'
        if (Test-Path $memHtmlPath) {
          Send-Text $ctx (Get-Content -LiteralPath $memHtmlPath -Raw -Encoding UTF8) 'text/html; charset=utf-8'
        } else { Send-FileNotFound $ctx }
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/memory') {
        # Phase 4: ?channel=<slug> filters items; default shows ALL channels so the user can
        # audit/organize. Pass ?channel=__active__ for "what's recallable from the current channel".
        $chParam = Get-QueryParamUtf8 $ctx 'channel'
        if ([string]::IsNullOrWhiteSpace($chParam)) { $chParam = '__all__' }
        elseif ($chParam -eq '__active__') { $chParam = (Get-ActiveChannel) }
        $stats = Get-MemoryStats
        $items = @(Get-MemoriesView -Channel $chParam)
        $mapTxt = ''
        if ($chParam -eq '__all__') {
          $mp = Get-MemoryMapPath
          if (Test-Path $mp) { $mapTxt = [System.IO.File]::ReadAllText($mp, [System.Text.Encoding]::UTF8) }
        } else {
          $perCh = Get-MemoryMapPathForChannel -Slug $chParam
          $shared = Get-MemorySharedMapPath
          $parts = New-Object 'System.Collections.Generic.List[string]'
          if (Test-Path $perCh)  { [void]$parts.Add([System.IO.File]::ReadAllText($perCh, [System.Text.Encoding]::UTF8)) }
          if (Test-Path $shared) { [void]$parts.Add([System.IO.File]::ReadAllText($shared, [System.Text.Encoding]::UTF8)) }
          $mapTxt = ($parts -join "`n`n---`n`n")
        }
        $itemsJson = '[' + (($items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join ',') + ']'
        # ReadAllText returns a plain CLR string, so ConvertTo-Json cannot serialize
        # PowerShell provider ETS properties as a {"value":...} object.
        $mapJson = (("" + $mapTxt) | ConvertTo-Json -Compress)
        $activeChJson = (("" + (Get-ActiveChannel)) | ConvertTo-Json -Compress)
        $filterJson   = (("" + $chParam) | ConvertTo-Json -Compress)
        $payload = '{"ok":true,"stats":' + ($stats | ConvertTo-Json -Compress -Depth 6) + ',"map":' + $mapJson + ',"items":' + $itemsJson + ',"activeChannel":' + $activeChJson + ',"filterChannel":' + $filterJson + '}'
        Send-Text $ctx $payload 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/memory/add') {
        $body = Read-Body $ctx | ConvertFrom-Json
        $text = [string]$body.text
        if ([string]::IsNullOrWhiteSpace($text)) {
          Send-Text $ctx '{"ok":false,"error":"empty text"}' 'application/json; charset=utf-8' 400
        } else {
          $tags = @(); if ($body.tags) { $tags = @($body.tags | ForEach-Object { [string]$_ }) }
          $imp = 0.6; if ($null -ne $body.importance) { try { $imp = [double]$body.importance } catch {} }
          $ch = $null; if ($null -ne $body.channel -and -not [string]::IsNullOrWhiteSpace([string]$body.channel)) { $ch = [string]$body.channel }
          $shared = $false; if ($null -ne $body.shared) { try { $shared = [bool]$body.shared } catch {} }
          $id = Add-Memory -Text $text -Tags $tags -Source 'manual' -Importance $imp -Channel $ch -Shared $shared
          if ($id) { Send-Text $ctx ('{"ok":true,"id":"' + $id + '"}') 'application/json; charset=utf-8' }
          else { Send-Text $ctx '{"ok":false,"error":"embedding failed (check API key/quota)"}' 'application/json; charset=utf-8' 500 }
        }
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/memory/update') {
        $body = Read-Body $ctx | ConvertFrom-Json
        $id = [string]$body.id
        $imp = $null; if ($null -ne $body.importance) { $imp = $body.importance }
        $txt = $null; if ($null -ne $body.text) { $txt = [string]$body.text }
        $pin = $null; if ($null -ne $body.pinned) { $pin = [bool]$body.pinned }
        $sh  = $null; if ($null -ne $body.PSObject.Properties['shared']) { $sh = [bool]$body.shared }
        $ch  = $null; if ($null -ne $body.channel -and -not [string]::IsNullOrWhiteSpace([string]$body.channel)) { $ch = [string]$body.channel }
        $ok = Set-Memory -Id $id -Importance $imp -Text $txt -Pinned $pin -Shared $sh -Channel $ch
        Send-Text $ctx ('{"ok":' + ($ok.ToString().ToLower()) + '}') 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/memory/delete') {
        $body = Read-Body $ctx | ConvertFrom-Json
        $ok = Remove-Memory -Id ([string]$body.id)
        Send-Text $ctx ('{"ok":' + ($ok.ToString().ToLower()) + '}') 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/memory/reindex') {
        $lib = Join-Path $root 'librarian.ps1'
        if (Test-Path $lib) {
          try { Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$lib -WindowStyle Hidden | Out-Null } catch {}
          Send-Text $ctx '{"ok":true}' 'application/json; charset=utf-8'
        } else { Send-Text $ctx '{"ok":false,"error":"librarian.ps1 missing"}' 'application/json; charset=utf-8' 500 }
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/backlog') {
        # 2026-05-27: by default exclude terminal statuses (done/auto-resolved)
        # from the response — they accumulate forever and clutter the UI.
        # Opt-in via ?include=done|archived|all to fetch the full archive.
        $includeParam = (Get-QueryParamUtf8 $ctx 'include')
        $includeArchived = (-not [string]::IsNullOrWhiteSpace($includeParam)) -and ($includeParam -imatch '^(done|archived|all|true|1)$')
        $allItems = @(Get-Backlog | Sort-Object { [string]$_.ts } -Descending)
        $archivedCount = 0
        $itemsFiltered = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $allItems) {
          if (-not ($item.PSObject.Properties.Name -contains 'auto_curator')) { $item | Add-Member -NotePropertyName auto_curator -NotePropertyValue $null -Force }
          if (-not ($item.PSObject.Properties.Name -contains 'similar_to')) { $item | Add-Member -NotePropertyName similar_to -NotePropertyValue @() -Force }
          if (-not ($item.PSObject.Properties.Name -contains 'seen_again_count')) { $item | Add-Member -NotePropertyName seen_again_count -NotePropertyValue 0 -Force }
          $st = [string]$item.status
          if (-not $includeArchived -and ($st -eq 'done' -or $st -eq 'auto-resolved')) {
            $archivedCount++
            continue
          }
          [void]$itemsFiltered.Add($item)
        }
        $itemsJson = '[' + ((@($itemsFiltered.ToArray()) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join ',') + ']'
        Send-Text $ctx ('{"ok":true,"items":' + $itemsJson + ',"archived_count":' + $archivedCount + ',"total":' + $allItems.Count + '}') 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/plan') {
        $p = Get-PlanForApi
        Send-Text $ctx ($p | ConvertTo-Json -Compress -Depth 8) 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/code') {
        $q = Get-QueryParamUtf8 $ctx 'q'
        $hits = @(Get-CodeRecallForApi -Query $q -TopK 8)
        $itemsJson = '[' + (($hits | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 4 }) -join ',') + ']'
        Send-Text $ctx ('{"ok":true,"q":' + (("" + $q) | ConvertTo-Json -Compress) + ',"items":' + $itemsJson + '}') 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/usage') {
        $u = Get-UsageSummary
        Send-Text $ctx ($u | ConvertTo-Json -Compress -Depth 4) 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/architect/run') {
        # 🧭 Manual Architect trigger from UI (or curl). Accepts optional body {"mode":"deep-think"}.
        $mode = 'normal'
        try {
          $body = Read-Body $ctx
          if (-not [string]::IsNullOrWhiteSpace($body)) {
            $bo = $body | ConvertFrom-Json
            if ($bo.mode -eq 'deep-think') { $mode = 'deep-think' }
          }
        } catch {}
        try {
          $r = Invoke-Architect -Mode $mode -MaxIdeas 3
          try { Save-ArchitectMarker } catch {}
          $okFlag = if ([bool]$r.ok) { 'true' } else { 'false' }
          Send-Text $ctx ('{"ok":' + $okFlag + ',"mode":"' + $mode + '","ideas_created":' + [int]$r.count + '}') 'application/json; charset=utf-8'
        } catch {
          $err = ("" + $_.Exception.Message) | ConvertTo-Json -Compress
          Send-Text $ctx ('{"ok":false,"error":' + $err + '}') 'application/json; charset=utf-8' 500
        }
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/metrics') {
        $m = Get-MetricsForApi
        Send-Text $ctx ($m | ConvertTo-Json -Compress -Depth 4) 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/memory/count') {
        $total = @(Get-AllMemories).Count
        Send-Text $ctx ('{"ok":true,"total":' + $total + '}') 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/radar') {
        $r = Get-RadarDigestForApi
        Send-Text $ctx ($r | ConvertTo-Json -Compress -Depth 8) 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/radar/run') {
        $rf = Join-Path $root 'techradar.ps1'
        if (Test-Path -LiteralPath $rf) {
          try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$rf -WindowStyle Hidden | Out-Null
            Send-Text $ctx '{"ok":true}' 'application/json; charset=utf-8'
          } catch {
            $err = ("" + $_.Exception.Message) | ConvertTo-Json -Compress
            Send-Text $ctx ('{"ok":false,"error":' + $err + '}') 'application/json; charset=utf-8' 500
          }
        } else {
          Send-Text $ctx '{"ok":false,"error":"techradar.ps1 missing"}' 'application/json; charset=utf-8' 500
        }
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/radar/backlog') {
        $body = Read-Body $ctx | ConvertFrom-Json
        $res = Add-RadarDigestItemToBacklog -Id ([string]$body.id) -Link ([string]$body.link)
        $status = if ([bool]$res.ok) { 200 } else { 400 }
        Send-Text $ctx ($res | ConvertTo-Json -Compress -Depth 8) 'application/json; charset=utf-8' $status
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/backlog/add') {
        $body = Read-Body $ctx | ConvertFrom-Json
        $text = [string]$body.text
        if ([string]::IsNullOrWhiteSpace($text)) { Send-Text $ctx '{"ok":false,"error":"empty"}' 'application/json; charset=utf-8' 400 }
        else {
          $st = if ($body.status) { [string]$body.status } else { 'new' }
          $id = Add-Idea -Text $text -From 'user' -Tags @('user') -Status $st
          Send-Text $ctx ('{"ok":' + (([bool]$id).ToString().ToLower()) + ',"id":"' + [string]$id + '"}') 'application/json; charset=utf-8'
        }
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/backlog/update') {
        $body = Read-Body $ctx | ConvertFrom-Json
        $st = $null; if ($null -ne $body.status) { $st = [string]$body.status }
        $tx = $null; if ($null -ne $body.text) { $tx = [string]$body.text }
        $clearAuto = $false; if ($null -ne $body.clear_auto_curator) { $clearAuto = [bool]$body.clear_auto_curator }
        $reason = $null; if ($null -ne $body.reason) { $reason = [string]$body.reason }
        $ok = Set-Idea -Id ([string]$body.id) -Status $st -Text $tx -ClearAutoCurator $clearAuto -Reason $reason
        Send-Text $ctx ('{"ok":' + ($ok.ToString().ToLower()) + '}') 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/backlog/delete') {
        $body = Read-Body $ctx | ConvertFrom-Json
        $ok = Remove-Idea -Id ([string]$body.id)
        Send-Text $ctx ('{"ok":' + ($ok.ToString().ToLower()) + '}') 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/reflect') {
        $rf = Join-Path $root 'reflect.ps1'
        if (Test-Path $rf) {
          try { [System.IO.File]::WriteAllText((Join-Path $root 'reflect.last'), '2000-01-01T00:00:00.0000000Z', (New-Object System.Text.UTF8Encoding($false))) } catch {}
          try { Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$rf -WindowStyle Hidden | Out-Null } catch {}
          Send-Text $ctx '{"ok":true}' 'application/json; charset=utf-8'
        } else { Send-Text $ctx '{"ok":false,"error":"reflect.ps1 missing"}' 'application/json; charset=utf-8' 500 }
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/settings') {
        # 2026-05-27v5: now returns BOTH autonomy + advanced settings (dotted-path keys).
        $s = Get-AutonomySettings
        $adv = Get-AdvancedSettings
        $cfg2 = Get-BridgeConfig
        $sJson = ($s | ConvertTo-Json -Compress -Depth 4)
        # Serialize ordered dictionary manually so JSON has stable shape
        $advPairs = New-Object 'System.Collections.Generic.List[string]'
        foreach ($key in $adv.Keys) {
          $val = $adv[$key]
          $jv = ($val | ConvertTo-Json -Compress -Depth 2)
          [void]$advPairs.Add(('"' + ($key -replace '"','\"') + '":' + $jv))
        }
        $advJson = '{' + ([string]::Join(',', $advPairs.ToArray())) + '}'
        $payload = '{"ok":true,"settings":' + $sJson + ',"advanced":' + $advJson + ',"workRoot":' + (("" + $cfg2.workRoot) | ConvertTo-Json -Compress) + '}'
        Send-Text $ctx $payload 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/settings') {
        # Accepts both autonomy fields (flat names) AND advanced fields (under "advanced" key
        # as map of dotted-path -> value).
        $body = Read-Body $ctx | ConvertFrom-Json
        $upd = @{}
        if ($null -ne $body.enabled)                  { $upd['enabled'] = [bool]$body.enabled }
        if ($null -ne $body.requireApproval)          { $upd['requireApproval'] = [bool]$body.requireApproval }
        if ($null -ne $body.idleQuietMinutes)         { $v=0.0; if([double]::TryParse([string]$body.idleQuietMinutes,[ref]$v)){ if($v -lt 0){$v=0}; $upd['idleQuietMinutes'] = $v } }
        if ($null -ne $body.reflectEveryHours)        { $v=0.0; if([double]::TryParse([string]$body.reflectEveryHours,[ref]$v)){ if($v -lt 0.1){$v=0.1}; $upd['reflectEveryHours'] = $v } }
        if ($null -ne $body.maxAutonomousTasksPerDay) { $v=0;   if([int]::TryParse([string]$body.maxAutonomousTasksPerDay,[ref]$v)){ if($v -lt 0){$v=0}; $upd['maxAutonomousTasksPerDay'] = $v } }
        if ($null -ne $body.scope)                    { $sc=[string]$body.scope; if($sc -eq 'bridge' -or $sc -eq 'projects'){ $upd['scope'] = $sc } }
        if ($upd.Count -gt 0) { Set-AutonomySetting -Updates $upd | Out-Null }

        # Advanced fields: body.advanced = { 'parallel.maxStreams': 8, ... }
        if ($null -ne $body.advanced) {
          $advUpd = @{}
          foreach ($p in $body.advanced.PSObject.Properties) {
            $k = [string]$p.Name; $raw = $p.Value
            # Coerce by key type heuristic: enabled-like keys -> bool, *Min*/*Hours*/*Sec*/*MaxX -> int/double
            if ($k -match '\.(enabled|autoDetect)$') {
              try { $advUpd[$k] = [bool]$raw } catch {}
            } elseif ($k -match '(Score|Threshold)$') {
              $d=0.0; if([double]::TryParse([string]$raw,[ref]$d)){ if($d -lt 0){$d=0}; if($d -gt 1){$d=1}; $advUpd[$k] = $d }
            } elseif ($k -match '(Hours|Minutes|Sec|Min|Max|Count|Streams|TopK|Days|Chars|Chunks|Retries|Effort|Per)') {
              $v=0; if([int]::TryParse([string]$raw,[ref]$v)){ if($v -lt 0){$v=0}; $advUpd[$k] = $v }
            } else {
              # Default: try int, then double, then string
              $vi=0; $vd=0.0
              if([int]::TryParse([string]$raw,[ref]$vi)) { $advUpd[$k] = $vi }
              elseif([double]::TryParse([string]$raw,[ref]$vd)) { $advUpd[$k] = $vd }
              else { $advUpd[$k] = [string]$raw }
            }
          }
          if ($advUpd.Count -gt 0) { Set-AdvancedSetting -Updates $advUpd | Out-Null }
        }

        [void](Add-Message -From system -Text "⚙ Настройки моста обновлены пользователем." -Kind event)
        $s2 = Get-AutonomySettings
        $adv2 = Get-AdvancedSettings
        $advPairs2 = New-Object 'System.Collections.Generic.List[string]'
        foreach ($key in $adv2.Keys) { [void]$advPairs2.Add(('"' + ($key -replace '"','\"') + '":' + (($adv2[$key]) | ConvertTo-Json -Compress -Depth 2))) }
        Send-Text $ctx ('{"ok":true,"settings":' + ($s2 | ConvertTo-Json -Compress -Depth 4) + ',"advanced":{' + ([string]::Join(',', $advPairs2.ToArray())) + '}}') 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/projects') {
        $projs = @(Get-ExternalProjects)
        $arr = '[' + (($projs | ForEach-Object { (("" + $_) | ConvertTo-Json -Compress) }) -join ',') + ']'
        Send-Text $ctx ('{"ok":true,"projects":' + $arr + ',"bridge":' + (("" + (Get-BridgeRoot)) | ConvertTo-Json -Compress) + '}') 'application/json; charset=utf-8'
      }
      # ----- multi-channel endpoints (phase 2) -----
      elseif ($method -eq 'GET' -and $path -eq '/api/channels') {
        # List non-archived channels + which one is active. ?includeArchived=1 includes them too.
        $inclArch = (Get-QueryParamUtf8 $ctx 'includeArchived') -eq '1'
        $list = if ($inclArch) { Get-ChannelList -IncludeArchived } else { Get-ChannelList }
        $active = Get-ActiveChannel
        $items = '[' + (($list | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join ',') + ']'
        Send-Text $ctx ('{"ok":true,"active":' + (("" + $active) | ConvertTo-Json -Compress) + ',"items":' + $items + '}') 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/channels') {
        # Create a new channel. Body: { slug, name?, description?, project_root? }
        $body = $null
        try { $body = Read-Body $ctx | ConvertFrom-Json } catch { $body = $null }
        $slug = if ($body) { [string]$body.slug } else { '' }
        $name = if ($body) { [string]$body.name } else { '' }
        $desc = if ($body) { [string]$body.description } else { '' }
        $proj = if ($body -and $body.project_root) { [string]$body.project_root } else { $null }
        if ([string]::IsNullOrWhiteSpace($slug)) {
          Send-Text $ctx '{"ok":false,"error":"slug required"}' 'application/json; charset=utf-8' 400
        } else {
          $cfgNew = New-Channel -Slug $slug -Name $name -Description $desc -ProjectRoot $proj
          if (-not $cfgNew) {
            Send-Text $ctx '{"ok":false,"error":"slug exists or invalid"}' 'application/json; charset=utf-8' 409
          } else {
            [void](Add-Message -From system -Text ("🧵 Создан канал: " + [string]$cfgNew.name + " (" + [string]$cfgNew.slug + ")") -Kind event)
            Send-Text $ctx ('{"ok":true,"channel":' + ($cfgNew | ConvertTo-Json -Compress -Depth 6) + '}') 'application/json; charset=utf-8'
          }
        }
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/channels/active') {
        # Switch the active channel. Body: { slug }
        $body = $null
        try { $body = Read-Body $ctx | ConvertFrom-Json } catch { $body = $null }
        $slug = if ($body) { [string]$body.slug } else { '' }
        if ([string]::IsNullOrWhiteSpace($slug)) {
          Send-Text $ctx '{"ok":false,"error":"slug required"}' 'application/json; charset=utf-8' 400
        } else {
          $ok = Set-ActiveChannel -Slug $slug
          if ($ok) {
            # Post the event into the NEW channel's conversation so the user sees the switch landed.
            [void](Add-Message -From system -Text ("🧵 Активный канал: " + $slug) -Kind event)
            Send-Text $ctx ('{"ok":true,"active":' + (("" + $slug) | ConvertTo-Json -Compress) + '}') 'application/json; charset=utf-8'
          } else {
            Send-Text $ctx '{"ok":false,"error":"channel not found"}' 'application/json; charset=utf-8' 404
          }
        }
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/channels/update') {
        # Edit channel metadata. Body: { slug, name?, description?, project_root? }
        $body = $null
        try { $body = Read-Body $ctx | ConvertFrom-Json } catch { $body = $null }
        $slug = if ($body) { [string]$body.slug } else { '' }
        if ([string]::IsNullOrWhiteSpace($slug)) {
          Send-Text $ctx '{"ok":false,"error":"slug required"}' 'application/json; charset=utf-8' 400
        } else {
          $patch = @{}
          if ($null -ne $body.PSObject.Properties['name'])        { $patch['name'] = [string]$body.name }
          if ($null -ne $body.PSObject.Properties['description']) { $patch['description'] = [string]$body.description }
          if ($null -ne $body.PSObject.Properties['project_root']) {
            $pr = $body.project_root
            $patch['project_root'] = if ($null -eq $pr -or [string]::IsNullOrWhiteSpace([string]$pr)) { $null } else { [string]$pr }
          }
          $ok = Save-ChannelConfig -Slug $slug -Patch $patch
          $cfgUpd = Get-ChannelConfig -Slug $slug
          if ($ok -and $cfgUpd) {
            Send-Text $ctx ('{"ok":true,"channel":' + ($cfgUpd | ConvertTo-Json -Compress -Depth 6) + '}') 'application/json; charset=utf-8'
          } else {
            Send-Text $ctx '{"ok":false,"error":"channel not found"}' 'application/json; charset=utf-8' 404
          }
        }
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/channels/archive') {
        # Archive a channel. Body: { slug }
        $body = $null
        try { $body = Read-Body $ctx | ConvertFrom-Json } catch { $body = $null }
        $slug = if ($body) { [string]$body.slug } else { '' }
        if ([string]::IsNullOrWhiteSpace($slug)) {
          Send-Text $ctx '{"ok":false,"error":"slug required"}' 'application/json; charset=utf-8' 400
        } else {
          $ok = Archive-Channel -Slug $slug
          if ($ok) {
            [void](Add-Message -From system -Text ("🗂 Канал в архив: " + $slug) -Kind event)
            try {
              $purged = Purge-MemoryForChannel -Slug $slug
              if ($purged -gt 0) {
                try { Add-Message -From system -Kind event -Text ("Auto-purge: удалено " + $purged + " memory-записей архивированного канала " + $slug) | Out-Null } catch {}
              }
            } catch {}
            Send-Text $ctx '{"ok":true}' 'application/json; charset=utf-8'
          } else {
            Send-Text $ctx '{"ok":false,"error":"cannot archive (main/active/missing)"}' 'application/json; charset=utf-8' 400
          }
        }
      }
      else {
        Send-Text $ctx 'not found' 'text/plain; charset=utf-8' 404
      }
    } catch {
      try { Send-Text $ctx ("error: " + $_.Exception.Message) 'text/plain; charset=utf-8' 500 } catch {}
    }
  }
} finally {
  $listener.Stop(); $listener.Close()
}
