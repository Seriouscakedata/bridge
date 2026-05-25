# server.ps1 -- local web UI for the bridge (HttpListener, no admin needed).
. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\plan.ps1')
. (Join-Path $PSScriptRoot 'lib\radar.ps1')

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
        $state = Read-State
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
        if (-not [string]::IsNullOrWhiteSpace($text)) { [void](Add-Message -From user -Text $text) }
        Send-Text $ctx '{"ok":true}' 'application/json; charset=utf-8'
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
        $body = Read-Body $ctx | ConvertFrom-Json
        $action = [string]$body.action
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
        Send-Text $ctx '{"ok":true}' 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and ($path -eq '/memory' -or $path -eq '/memory.html')) {
        $memHtmlPath = Join-Path $root 'web\memory.html'
        if (Test-Path $memHtmlPath) {
          Send-Text $ctx (Get-Content -LiteralPath $memHtmlPath -Raw -Encoding UTF8) 'text/html; charset=utf-8'
        } else { Send-FileNotFound $ctx }
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/memory') {
        $stats = Get-MemoryStats
        $items = @(Get-MemoriesView)
        $mapTxt = ''
        $mp = Get-MemoryMapPath
        if (Test-Path $mp) { $mapTxt = Get-Content -LiteralPath $mp -Raw -Encoding UTF8 }
        $itemsJson = '[' + (($items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join ',') + ']'
        # ("" + $mapTxt) strips ETS NoteProperties that Get-Content -Raw attaches, so
        # ConvertTo-Json emits a plain JSON string instead of a {"value":...} object.
        $mapJson = (("" + $mapTxt) | ConvertTo-Json -Compress)
        $payload = '{"ok":true,"stats":' + ($stats | ConvertTo-Json -Compress -Depth 6) + ',"map":' + $mapJson + ',"items":' + $itemsJson + '}'
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
          $id = Add-Memory -Text $text -Tags $tags -Source 'manual' -Importance $imp
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
        $ok = Set-Memory -Id $id -Importance $imp -Text $txt -Pinned $pin
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
        $items = @(Get-Backlog | Sort-Object { [string]$_.ts } -Descending)
        $itemsJson = '[' + (($items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join ',') + ']'
        Send-Text $ctx ('{"ok":true,"items":' + $itemsJson + '}') 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/plan') {
        $p = Get-PlanForApi
        Send-Text $ctx ($p | ConvertTo-Json -Compress -Depth 8) 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/code') {
        $q = [string]$ctx.Request.QueryString['q']
        $hits = @(Get-CodeRecallForApi -Query $q -TopK 8)
        $itemsJson = '[' + (($hits | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 4 }) -join ',') + ']'
        Send-Text $ctx ('{"ok":true,"q":' + (("" + $q) | ConvertTo-Json -Compress) + ',"items":' + $itemsJson + '}') 'application/json; charset=utf-8'
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
        $ok = Set-Idea -Id ([string]$body.id) -Status $st -Text $tx
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
        $s = Get-AutonomySettings
        $cfg2 = Get-BridgeConfig
        $sJson = ($s | ConvertTo-Json -Compress -Depth 4)
        $payload = '{"ok":true,"settings":' + $sJson + ',"workRoot":' + (("" + $cfg2.workRoot) | ConvertTo-Json -Compress) + '}'
        Send-Text $ctx $payload 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/settings') {
        $body = Read-Body $ctx | ConvertFrom-Json
        $upd = @{}
        if ($null -ne $body.enabled)                  { $upd['enabled'] = [bool]$body.enabled }
        if ($null -ne $body.requireApproval)          { $upd['requireApproval'] = [bool]$body.requireApproval }
        if ($null -ne $body.idleQuietMinutes)         { $v=0.0; if([double]::TryParse([string]$body.idleQuietMinutes,[ref]$v)){ if($v -lt 0){$v=0}; $upd['idleQuietMinutes'] = $v } }
        if ($null -ne $body.reflectEveryHours)        { $v=0.0; if([double]::TryParse([string]$body.reflectEveryHours,[ref]$v)){ if($v -lt 0.1){$v=0.1}; $upd['reflectEveryHours'] = $v } }
        if ($null -ne $body.maxAutonomousTasksPerDay) { $v=0;   if([int]::TryParse([string]$body.maxAutonomousTasksPerDay,[ref]$v)){ if($v -lt 0){$v=0}; $upd['maxAutonomousTasksPerDay'] = $v } }
        if ($null -ne $body.scope)                    { $sc=[string]$body.scope; if($sc -eq 'bridge' -or $sc -eq 'projects'){ $upd['scope'] = $sc } }
        if ($upd.Count -gt 0) { Set-AutonomySetting -Updates $upd | Out-Null }
        [void](Add-Message -From system -Text "⚙ Настройки автономии обновлены пользователем." -Kind event)
        $s2 = Get-AutonomySettings
        Send-Text $ctx ('{"ok":true,"settings":' + ($s2 | ConvertTo-Json -Compress -Depth 4) + '}') 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/projects') {
        $projs = @(Get-ExternalProjects)
        $arr = '[' + (($projs | ForEach-Object { (("" + $_) | ConvertTo-Json -Compress) }) -join ',') + ']'
        Send-Text $ctx ('{"ok":true,"projects":' + $arr + ',"bridge":' + (("" + (Get-BridgeRoot)) | ConvertTo-Json -Compress) + '}') 'application/json; charset=utf-8'
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
