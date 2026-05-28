# server.ps1 -- local web UI for the bridge (HttpListener, no admin needed).
. (Join-Path $PSScriptRoot 'lib\common.ps1')
. (Join-Path $PSScriptRoot 'lib\features.ps1')
. (Join-Path $PSScriptRoot 'lib\plan.ps1')
. (Join-Path $PSScriptRoot 'lib\radar.ps1')
. (Join-Path $PSScriptRoot 'lib\metrics.ps1')
. (Join-Path $PSScriptRoot 'lib\replay.ps1')

$cfg  = Get-BridgeConfig
$port = [int]$cfg.port
$root = Get-BridgeRoot
$indexPath = Join-Path $root 'web\index.html'
$filesPath = Get-FilesPath
$maxUploadBytes = 25 * 1024 * 1024

# Authentication (HTTP Basic). Credentials live in auth.json next to config.
$authPath = Join-Path $root 'auth.json'
$authUser = $null; $authPass = $null; $authToken = $null
if (Test-Path $authPath) {
  $a = Get-Content $authPath -Raw -Encoding UTF8 | ConvertFrom-Json
  $authUser = [string]$a.user; $authPass = [string]$a.password
  if ($null -ne $a.PSObject.Properties['token']) { $authToken = [string]$a.token }
}

$null = Initialize-Bridge   # ensure files exist
$serverStartTime = Get-Date
$healthMemoryStamp = [datetime]::MinValue
$healthMemoryCount = 0
$healthConversationStamp = ''
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
function Get-ActiveScopeDto {
  param([string]$Slug = $null)
  if ([string]::IsNullOrWhiteSpace($Slug)) { $Slug = Get-ActiveChannel }
  try {
    $scope = Get-EffectiveScope -Slug $Slug
    return [pscustomobject]@{
      slug         = [string]$scope.slug
      is_bridge    = [bool]$scope.is_bridge
      project_root = [string]$scope.project_root
      bridge_root  = [string]$scope.bridge_root
    }
  } catch {
    return [pscustomobject]@{
      slug         = [string]$Slug
      is_bridge    = ([string]$Slug -eq 'main')
      project_root = if ([string]$Slug -eq 'main') { Get-BridgeRoot } else { '' }
      bridge_root  = Get-BridgeRoot
      error        = [string]$_.Exception.Message
    }
  }
}
function Quote-RunbookProcessArgument {
  param([AllowNull()][string]$Value)
  if ($null -eq $Value) { $Value = '' }
  $s = [string]$Value
  if ($s.Length -eq 0) { return '""' }
  if ($s -notmatch '[\s"]') { return $s }

  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  $slashes = 0
  foreach ($ch in $s.ToCharArray()) {
    if ($ch -eq [char]92) {
      $slashes++
      continue
    }
    if ($ch -eq [char]34) {
      if ($slashes -gt 0) { [void]$sb.Append(('\' * ($slashes * 2))) }
      [void]$sb.Append('\"')
      $slashes = 0
      continue
    }
    if ($slashes -gt 0) {
      [void]$sb.Append(('\' * $slashes))
      $slashes = 0
    }
    [void]$sb.Append($ch)
  }
  if ($slashes -gt 0) { [void]$sb.Append(('\' * ($slashes * 2))) }
  [void]$sb.Append('"')
  return $sb.ToString()
}
function Join-RunbookProcessArguments {
  param([string[]]$ArgsList)
  $parts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($arg in @($ArgsList)) {
    [void]$parts.Add((Quote-RunbookProcessArgument -Value $arg))
  }
  return [string]::Join(' ', $parts.ToArray())
}
function Invoke-RunbookProcess {
  param(
    [string]$FileName,
    [string[]]$ArgsList = @(),
    [string]$WorkingDirectory = '',
    [int]$TimeoutMs = 15000
  )
  $result = [ordered]@{
    fileName = $FileName
    exitCode = $null
    timedOut = $false
    stdout = ''
    stderr = ''
    error = ''
  }
  $proc = New-Object System.Diagnostics.Process
  try {
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) { $WorkingDirectory = Get-BridgeRoot }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = Join-RunbookProcessArguments -ArgsList $ArgsList
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    try { $psi.EnvironmentVariables['BRIDGE_CHANNEL'] = [string](Get-EffectiveChannel) } catch {}
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutMs)) {
      $result.timedOut = $true
      try { $proc.Kill() } catch {}
      try { $proc.WaitForExit(5000) | Out-Null } catch {}
    } else {
      $result.exitCode = $proc.ExitCode
    }
    try {
      if ($stdoutTask.Wait(1000)) { $result.stdout = [string]$stdoutTask.Result }
    } catch {}
    try {
      if ($stderrTask.Wait(1000)) { $result.stderr = [string]$stderrTask.Result }
    } catch {}
  } catch {
    $result.error = [string]$_.Exception.Message
  } finally {
    if ($null -ne $proc) { $proc.Dispose() }
  }
  return [pscustomobject]$result
}
function Convert-RunbookProcessResultToText {
  param($Result)
  if ($null -eq $Result) { return 'ERROR: process did not return a result' }
  $parts = New-Object 'System.Collections.Generic.List[string]'
  if (-not [string]::IsNullOrWhiteSpace([string]$Result.error)) {
    [void]$parts.Add("ERROR: $($Result.error)")
  } elseif ([bool]$Result.timedOut) {
    [void]$parts.Add('ERROR: timeout')
  } elseif ($null -ne $Result.exitCode -and [int]$Result.exitCode -ne 0) {
    [void]$parts.Add("ERROR: exit code $($Result.exitCode)")
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Result.stdout)) {
    [void]$parts.Add(([string]$Result.stdout).TrimEnd())
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$Result.stderr)) {
    [void]$parts.Add("STDERR`r`n$(([string]$Result.stderr).TrimEnd())")
  }
  if ($parts.Count -eq 0) { return '' }
  return [string]::Join("`r`n", $parts.ToArray())
}
function Get-RunbookStateObject {
  $stateObj = $null
  try { $stateObj = Read-State } catch { $stateObj = $null }
  if ($null -ne $stateObj) { return $stateObj }

  $statePath = $null
  try { $statePath = Get-StatePath } catch { $statePath = $null }
  if ([string]::IsNullOrWhiteSpace([string]$statePath)) { return $null }
  if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { return $null }
  try {
    $raw = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
  } catch {
    return $null
  }
}
function Get-RunbookPropertyValue {
  param($InputObject, [string]$Name)
  if ($null -eq $InputObject) { return $null }
  try {
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
  } catch {}
  return $null
}
function ConvertTo-RunbookSummaryValue {
  param($Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [string]) { return [string]$Value }
  if ($Value -is [bool]) { return [bool]$Value }
  if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int] -or $Value -is [long] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) { return $Value }
  if ($Value -is [datetime]) { return ([datetime]$Value).ToString('o') }
  try {
    $json = [string]($Value | ConvertTo-Json -Compress -Depth 4)
    if ([string]::IsNullOrWhiteSpace($json)) { return [string]$Value }
    if ($json.Length -gt 2000) { return ($json.Substring(0, 2000) + '...<truncated>') }
    return $json
  } catch {
    return [string]$Value
  }
}
function Test-Auth {
  param($ctx)
  if (-not $authPass -and -not $authToken) { return $true }   # no credentials configured -> open
  $h = $ctx.Request.Headers['Authorization']
  if ($authToken) {
    if ($h -and $h.StartsWith('Bearer ')) {
      $bearer = $h.Substring(7).Trim()
      if ($bearer -eq $authToken) { return $true }
    }
    $qToken = Get-QueryParamUtf8 $ctx 'token'
    if (-not [string]::IsNullOrWhiteSpace($qToken) -and $qToken -eq $authToken) { return $true }
  }
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

function Test-IsAuthenticated {
  param($ctx)
  $hasTokenAuth = -not [string]::IsNullOrWhiteSpace($script:authToken)
  $hasBasicAuth = (-not [string]::IsNullOrWhiteSpace($script:authUser)) -and (-not [string]::IsNullOrWhiteSpace($script:authPass))
  if (-not $hasTokenAuth -and -not $hasBasicAuth) { return $false }

  $h = $ctx.Request.Headers['Authorization']
  if ($hasTokenAuth) {
    if ($h -and $h.StartsWith('Bearer ')) {
      $bearer = $h.Substring(7).Trim()
      if ($bearer -eq $script:authToken) { return $true }
    }
    $qToken = Get-QueryParamUtf8 $ctx 'token'
    if (-not [string]::IsNullOrWhiteSpace($qToken) -and $qToken -eq $script:authToken) { return $true }
  }
  if ($hasBasicAuth -and $h -and $h.StartsWith('Basic ')) {
    try {
      $raw = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($h.Substring(6)))
      $i = $raw.IndexOf(':')
      if ($i -ge 0) {
        $u = $raw.Substring(0,$i); $p = $raw.Substring($i+1)
        if ($u -eq $script:authUser -and $p -eq $script:authPass) { return $true }
      }
    } catch {
      return $false
    }
  }
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
        $stateObj = $null
        if (Test-Path -LiteralPath $statePath) {
          try {
            $stateText = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8)
            if (-not [string]::IsNullOrWhiteSpace($stateText)) { $stateObj = $stateText | ConvertFrom-Json }
          } catch { $stateObj = $null }
        }
        $hbAge    = 9999
        $hbRaw    = [string](Get-RunbookPropertyValue $stateObj 'heartbeat')
        if (-not [string]::IsNullOrWhiteSpace($hbRaw)) {
          try { $hbAge = [int]([Math]::Floor(($now - [datetime]::Parse($hbRaw)).TotalSeconds)) } catch {}
        }
        $hPaused = $false
        $pausedValue = Get-RunbookPropertyValue $stateObj 'paused'
        if ($null -ne $pausedValue) {
          try { $hPaused = [System.Convert]::ToBoolean($pausedValue) } catch { $hPaused = $false }
        }
        $hStatus = [string](Get-RunbookPropertyValue $stateObj 'status')
        $hLastSeq = 0
        $lastSeqValue = Get-RunbookPropertyValue $stateObj 'lastSeq'
        if ($null -ne $lastSeqValue) { [void][int]::TryParse([string]$lastSeqValue, [ref]$hLastSeq) }
        $psActive = 0
        $parallelStreams = Get-RunbookPropertyValue $stateObj 'parallel_streams'
        foreach ($stream in @($parallelStreams)) {
          if ($null -eq $stream) { continue }
          if ([string](Get-RunbookPropertyValue $stream 'status') -eq 'running') { $psActive++ }
        }
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
          # 2026-05-28: was caching on LastWriteTimeUtc alone. NTFS file-time
          # resolution is ~16ms, so a fast Add-Message + 200ms canary read
          # window could land inside the same tick and the cache check would
          # short-circuit, returning the previous lastSeq. Canary then errored
          # "lastSeq did not advance". Now we also key on file size (changes
          # on every append, no resolution issue).
          $convItem = Get-Item -LiteralPath $convPath
          $convStamp = $convItem.LastWriteTimeUtc
          $convSize = [long]$convItem.Length
          $cacheKey = ([string]$convStamp + '|' + $convSize)
          if ($cacheKey -ne $healthConversationStamp) {
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
            $healthConversationStamp = $cacheKey
            $healthConversationLastSeq = $newLastSeq
            $healthConversationErrorCount = $newErrCount
          }
          if ($healthConversationLastSeq -gt $hLastSeq) { $hLastSeq = $healthConversationLastSeq }
          $errCount = $healthConversationErrorCount
        } else {
          $healthConversationStamp = ''
          $healthConversationLastSeq = 0
          $healthConversationErrorCount = 0
          $errCount = 0
        }
        $hOk = ($hbAge -lt 120) -and (-not $hPaused) -and ($errCount -lt 10)
        $hJson = '{"ok":' + ($hOk.ToString().ToLower()) + `
          ',"uptime_sec":' + $uptimeSec + `
          ',"heartbeat_age_sec":' + $hbAge + `
          ',"paused":' + ($hPaused.ToString().ToLower()) + `
          ',"status":' + (("" + $hStatus) | ConvertTo-Json -Depth 10 -Compress) + `
          ',"lastSeq":' + $hLastSeq + `
          ',"memory_count":' + $memCount + `
          ',"recent_error_count_24h":' + $errCount + `
          ',"git_head":' + (("" + $gitHead) | ConvertTo-Json -Depth 10 -Compress) + `
          ',"parallel_streams_active":' + $psActive + '}'
        $ctx.Response.AddHeader('Access-Control-Allow-Origin', '*')
        if (Test-IsAuthenticated $ctx) {
          Send-Text $ctx $hJson 'application/json; charset=utf-8'
        } else {
          $hJsonPub = '{"ok":' + ($hOk.ToString().ToLower()) + `
            ',"uptime_sec":' + $uptimeSec + `
            ',"heartbeat_age_sec":' + $hbAge + `
            ',"recent_error_count_24h":' + $errCount + '}'
          Send-Text $ctx $hJsonPub 'application/json; charset=utf-8'
        }
        continue
      }
      if (-not (Test-Auth $ctx)) { continue }
      $path   = $ctx.Request.Url.AbsolutePath
      $method = $ctx.Request.HttpMethod

      if ($method -eq 'GET' -and ($path -eq '/' -or $path -eq '/index.html')) {
        $html = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8
        Send-Text $ctx $html 'text/html; charset=utf-8'
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/scenario/result') {
        # 2026-05-28: functional verifier infrastructure. Browser-side scenarios
        # (tools/scenarios/*.js) run inside the headless page after we launch it
        # with ?scenario=<name>. They post their result here. Runner script
        # (tools/scenario.ps1) polls /api/scenario/result?name=X for the answer.
        # This lets us run REAL user-flow tests (click, wait, assert) instead of
        # just static screenshots — directly addresses the "fix didn't actually
        # close the user's complaint" failure mode.
        $body = $null
        try { $body = Read-Body $ctx | ConvertFrom-Json } catch {}
        if (-not $body -or [string]::IsNullOrWhiteSpace([string]$body.name)) {
          Send-Text $ctx '{"ok":false,"error":"name required"}' 'application/json; charset=utf-8' 400
        } else {
          $rec = [ordered]@{
            ts = (Get-Date).ToUniversalTime().ToString('o')
            name = [string]$body.name
            ok = if ($null -ne $body.ok) { [bool]$body.ok } else { $false }
            errors = if ($body.errors) { @($body.errors) } else { @() }
            log = if ($body.log) { @($body.log) } else { @() }
            timings = if ($body.timings) { $body.timings } else { $null }
            user_agent = [string]$ctx.Request.Headers['User-Agent']
          }
          try {
            $resPath = Join-Path $root 'control\scenario-results.jsonl'
            $line = ($rec | ConvertTo-Json -Compress -Depth 6) + "`n"
            [System.IO.File]::AppendAllText($resPath, $line, (New-Object System.Text.UTF8Encoding($false)))
          } catch {}
          Send-Text $ctx '{"ok":true}' 'application/json; charset=utf-8'
        }
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/scenario/result') {
        $name = Get-QueryParamUtf8 $ctx 'name'
        if ([string]::IsNullOrWhiteSpace($name)) {
          Send-Text $ctx '{"ok":false,"error":"name required"}' 'application/json; charset=utf-8' 400
        } else {
          $resPath = Join-Path $root 'control\scenario-results.jsonl'
          if (-not (Test-Path $resPath)) {
            Send-Text $ctx '{"ok":true,"result":null}' 'application/json; charset=utf-8'
          } else {
            $sinceTs = Get-QueryParamUtf8 $ctx 'since'
            $found = $null
            try {
              $lines = @(Get-Content -LiteralPath $resPath -Tail 200 -Encoding UTF8)
              for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                $ln = [string]$lines[$i]
                if ([string]::IsNullOrWhiteSpace($ln)) { continue }
                try {
                  $rec = $ln | ConvertFrom-Json
                  if ([string]$rec.name -ne $name) { continue }
                  if (-not [string]::IsNullOrWhiteSpace($sinceTs)) {
                    try { if ([datetime]$rec.ts -le [datetime]$sinceTs) { continue } } catch {}
                  }
                  $found = $rec; break
                } catch {}
              }
            } catch {}
            if ($found) {
              Send-Text $ctx ('{"ok":true,"result":' + ($found | ConvertTo-Json -Compress -Depth 6) + '}') 'application/json; charset=utf-8'
            } else {
              Send-Text $ctx '{"ok":true,"result":null}' 'application/json; charset=utf-8'
            }
          }
        }
      }
      elseif ($method -eq 'GET' -and $path -match '^/tools/scenarios/[a-z0-9_-]+\.js$') {
        # Serve scenario JS files from tools/scenarios/ to the headless browser.
        $rel = $path.TrimStart('/')
        $full = Join-Path $root ($rel -replace '/', '\')
        if ((Test-Path -LiteralPath $full -PathType Leaf)) {
          try {
            $js = [System.IO.File]::ReadAllText($full, [System.Text.UTF8Encoding]::new($false))
            Send-Text $ctx $js 'application/javascript; charset=utf-8'
          } catch { Send-Text $ctx '// scenario read error' 'application/javascript; charset=utf-8' 500 }
        } else {
          Send-Text $ctx '// not found' 'application/javascript; charset=utf-8' 404
        }
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/messages') {
        # 2026-05-28: ?channel=<slug> reads THAT channel's conversation.jsonl explicitly,
        # bypassing the global active_channel marker. This was the root cause of UI
        # flicker during channel switch: client requested channel X's messages but
        # server returned whatever active_channel happened to be at that moment.
        # Mirrors the /api/status pattern (pin -> read -> unpin in finally).
        $since = 0; [void][int]::TryParse($ctx.Request.QueryString['since'], [ref]$since)
        $chParam = Get-QueryParamUtf8 $ctx 'channel'
        $prevPin = Get-PinnedChannel
        try {
          if (-not [string]::IsNullOrWhiteSpace($chParam)) { Set-PinnedChannel $chParam }
          $msgs = Get-Messages -Since $since
        } finally { Set-PinnedChannel $prevPin }
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
          $reqChannel = Get-ActiveChannel
          $prevPinnedChannel = $script:PinnedChannel
          try {
            $script:PinnedChannel = $reqChannel
            [void](Add-Message -From user -Text $text -Attachments $atts)
          } finally {
            $script:PinnedChannel = $prevPinnedChannel
          }
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
          $result = @{ text = $text } | ConvertTo-Json -Depth 10 -Compress
          Send-Text $ctx $result 'application/json; charset=utf-8'
        } catch {
          $errMsg = @{ error = $_.Exception.Message } | ConvertTo-Json -Depth 10 -Compress
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
        $shotResult = Invoke-RunbookProcess -FileName 'powershell.exe' -ArgsList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$toolPath) -WorkingDirectory $root -TimeoutMs 60000
        if ([bool]$shotResult.timedOut -or -not [string]::IsNullOrWhiteSpace([string]$shotResult.error) -or ($null -ne $shotResult.exitCode -and [int]$shotResult.exitCode -ne 0)) {
          $err = 'screenshot failed: ' + (Convert-RunbookProcessResultToText $shotResult)
          $json = ([ordered]@{ ok = $false; error = $err } | ConvertTo-Json -Compress -Depth 5)
          Send-Text $ctx $json 'application/json; charset=utf-8' 500
          continue
        }
        $shotPath = [string](([string]$shotResult.stdout -split '\r?\n') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Last 1)
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
        # ?channel=<slug> filters items; default follows the effective/pinned channel.
        # ?include_bridge=1 adds bridge-memory records as read-only rows for project channels.
        $chParam = Get-QueryParamUtf8 $ctx 'channel'
        if ([string]::IsNullOrWhiteSpace($chParam)) { $chParam = '__active__' }
        if ($chParam -eq '__active__') { $chParam = (Get-EffectiveChannel) }
        $includeBridgeParam = Get-QueryParamUtf8 $ctx 'include_bridge'
        $includeBridge = ($includeBridgeParam -match '^(1|true|yes|on)$')
        if ($chParam -eq '__all__') { $includeBridge = $false }
        try {
          $memScope = if ($chParam -eq '__all__') { Get-EffectiveScope -Slug (Get-EffectiveChannel) } else { Get-EffectiveScope -Slug $chParam }
        } catch {
          Send-Text $ctx ('{"ok":false,"error":' + (([string]$_.Exception.Message) | ConvertTo-Json -Compress) + '}') 'application/json; charset=utf-8' 400
          continue
        }
        if ([bool]$memScope.is_bridge) { $includeBridge = $false }
        $stats = Get-MemoryStats -Channel $chParam
        $items = @(Get-MemoriesView -Channel $chParam -IncludeBridgeReadonly $includeBridge)
        $mapTxt = ''
        if ($chParam -eq '__all__') {
          $mp = Get-MemoryMapPath
          if (Test-Path $mp) { $mapTxt = [System.IO.File]::ReadAllText($mp, [System.Text.Encoding]::UTF8) }
        } else {
          $perCh = Get-MemoryMapPathForChannel -Slug $chParam
          $shared = Get-MemorySharedMapPath -Slug $chParam
          $parts = New-Object 'System.Collections.Generic.List[string]'
          if (Test-Path $perCh)  { [void]$parts.Add([System.IO.File]::ReadAllText($perCh, [System.Text.Encoding]::UTF8)) }
          if (Test-Path $shared) { [void]$parts.Add([System.IO.File]::ReadAllText($shared, [System.Text.Encoding]::UTF8)) }
          $mapTxt = ($parts -join "`n`n---`n`n")
        }
        $itemsJson = '[' + (($items | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join ',') + ']'
        # ReadAllText returns a plain CLR string, so ConvertTo-Json -Depth 10 cannot serialize
        # PowerShell provider ETS properties as a {"value":...} object.
        $mapJson = (("" + $mapTxt) | ConvertTo-Json -Depth 10 -Compress)
        $activeChJson = (("" + (Get-EffectiveChannel)) | ConvertTo-Json -Depth 10 -Compress)
        $filterJson   = (("" + $chParam) | ConvertTo-Json -Depth 10 -Compress)
        $payload = '{"ok":true,"stats":' + ($stats | ConvertTo-Json -Compress -Depth 6) + ',"map":' + $mapJson + ',"items":' + $itemsJson + ',"activeChannel":' + $activeChJson + ',"filterChannel":' + $filterJson + ',"includeBridge":' + ($includeBridge.ToString().ToLower()) + ',"scope":' + ($memScope | ConvertTo-Json -Compress -Depth 6) + '}'
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
          try {
            Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
              Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$lib -WindowStyle Hidden | Out-Null
            }
          } catch {}
          Send-Text $ctx '{"ok":true}' 'application/json; charset=utf-8'
        } else { Send-Text $ctx '{"ok":false,"error":"librarian.ps1 missing"}' 'application/json; charset=utf-8' 500 }
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/backlog') {
        # 2026-05-27: by default exclude terminal statuses (done/auto-resolved)
        # from the response — they accumulate forever and clutter the UI.
        # Opt-in via ?include=done|archived|all to fetch the full archive.
        # 2026-05-28: ?channel=<slug> pin around Get-Backlog so UI switches
        # don't accidentally show another channel's backlog mid-flight.
        $includeParam = (Get-QueryParamUtf8 $ctx 'include')
        $includeArchived = (-not [string]::IsNullOrWhiteSpace($includeParam)) -and ($includeParam -imatch '^(done|archived|all|true|1)$')
        $chParam = Get-QueryParamUtf8 $ctx 'channel'
        $prevPin = Get-PinnedChannel
        try {
          if (-not [string]::IsNullOrWhiteSpace($chParam)) { Set-PinnedChannel $chParam }
          $allItems = @(Get-Backlog | Sort-Object { [string]$_.ts } -Descending)
        } finally { Set-PinnedChannel $prevPin }
        $archivedCount = 0
        $itemsFiltered = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $allItems) {
          if (-not ($item.PSObject.Properties.Name -contains 'auto_curator')) { $item | Add-Member -NotePropertyName auto_curator -NotePropertyValue $null -Force }
          if (-not ($item.PSObject.Properties.Name -contains 'similar_to')) { $item | Add-Member -NotePropertyName similar_to -NotePropertyValue @() -Force }
          if (-not ($item.PSObject.Properties.Name -contains 'seen_again_count')) { $item | Add-Member -NotePropertyName seen_again_count -NotePropertyValue 0 -Force }
          $st = [string]$item.status
          # 2026-05-28: also hide auto-dropped and rejected by default. These
          # are terminal closed statuses (curator/operator decided NOT to do)
          # and they were accumulating in the visible list — 186 dropped items
          # cluttering the UI even though no work remains on them.
          if (-not $includeArchived -and ($st -eq 'done' -or $st -eq 'auto-resolved' -or $st -eq 'auto-dropped' -or $st -eq 'rejected')) {
            $archivedCount++
            continue
          }
          [void]$itemsFiltered.Add($item)
        }
        $itemsJson = '[' + ((@($itemsFiltered.ToArray()) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join ',') + ']'
        Send-Text $ctx ('{"ok":true,"items":' + $itemsJson + ',"archived_count":' + $archivedCount + ',"total":' + $allItems.Count + '}') 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/plan') {
        # 2026-05-28: ?channel=<slug> mirrors /api/messages and /api/status — explicit
        # channel pin around Get-PlanForApi avoids races with global active_channel.
        $chParam = Get-QueryParamUtf8 $ctx 'channel'
        $prevPin = Get-PinnedChannel
        try {
          if (-not [string]::IsNullOrWhiteSpace($chParam)) { Set-PinnedChannel $chParam }
          $p = Get-PlanForApi
        } finally { Set-PinnedChannel $prevPin }
        Send-Text $ctx ($p | ConvertTo-Json -Compress -Depth 8) 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/code') {
        $q = Get-QueryParamUtf8 $ctx 'q'
        $hits = @(Get-CodeRecallForApi -Query $q -TopK 8)
        $itemsJson = '[' + (($hits | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 4 }) -join ',') + ']'
        Send-Text $ctx ('{"ok":true,"q":' + (("" + $q) | ConvertTo-Json -Depth 10 -Compress) + ',"items":' + $itemsJson + '}') 'application/json; charset=utf-8'
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
          $err = ("" + $_.Exception.Message) | ConvertTo-Json -Depth 10 -Compress
          Send-Text $ctx ('{"ok":false,"error":' + $err + '}') 'application/json; charset=utf-8' 500
        }
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/runbook') {
        try {
          $runbookRoot = Get-BridgeRoot

          $gitStatusShort = Convert-RunbookProcessResultToText (Invoke-RunbookProcess -FileName 'git.exe' -ArgsList @('-C', $runbookRoot, 'status', '-s') -WorkingDirectory $runbookRoot -TimeoutMs 15000)
          if ([string]::IsNullOrWhiteSpace($gitStatusShort)) { $gitStatusShort = '(clean)' }
          $gitLog = Convert-RunbookProcessResultToText (Invoke-RunbookProcess -FileName 'git.exe' -ArgsList @('-C', $runbookRoot, 'log', '--oneline', '-10') -WorkingDirectory $runbookRoot -TimeoutMs 15000)
          $gitStatus = "## git -C <bridgeRoot> status -s`r`n$gitStatusShort`r`n`r`n## git log --oneline -10`r`n$gitLog`r`n"

          $now = Get-Date
          $uptimeSec = [int]([Math]::Floor(($now - $serverStartTime).TotalSeconds))
          $stateObj = Get-RunbookStateObject
          $hbAge = 9999
          $hbRaw = [string](Get-RunbookPropertyValue $stateObj 'heartbeat')
          if (-not [string]::IsNullOrWhiteSpace($hbRaw)) {
            try { $hbAge = [int]([Math]::Floor(($now - [datetime]::Parse($hbRaw)).TotalSeconds)) } catch {}
          }
          $hPaused = $false
          $pausedValue = Get-RunbookPropertyValue $stateObj 'paused'
          if ($null -ne $pausedValue) {
            try { $hPaused = [System.Convert]::ToBoolean($pausedValue) } catch { $hPaused = $false }
          }
          $hStatus = [string](Get-RunbookPropertyValue $stateObj 'status')
          $hLastSeq = 0
          $lastSeqValue = Get-RunbookPropertyValue $stateObj 'lastSeq'
          if ($null -ne $lastSeqValue) { [void][int]::TryParse([string]$lastSeqValue, [ref]$hLastSeq) }
          $healthSnapshot = [ordered]@{
            ok = (($hbAge -lt 120) -and (-not $hPaused))
            uptime_sec = $uptimeSec
            heartbeat_age_sec = $hbAge
            paused = $hPaused
            status = $hStatus
            lastSeq = $hLastSeq
            state_available = ($null -ne $stateObj)
            generated_at = $now.ToString('o')
          }
          $healthJson = $healthSnapshot | ConvertTo-Json -Depth 4

          $smokePath = Join-Path $runbookRoot 'smoke.ps1'
          if (Test-Path -LiteralPath $smokePath -PathType Leaf) {
            $smokeResult = Invoke-RunbookProcess -FileName 'powershell.exe' -ArgsList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$smokePath) -WorkingDirectory $runbookRoot -TimeoutMs 30000
            if ([bool]$smokeResult.timedOut) {
              $smokeSummary = 'SMOKE: timeout'
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$smokeResult.error)) {
              $smokeSummary = "SMOKE: ERROR`r`n$($smokeResult.error)"
            } else {
              $smokeSummary = "ExitCode=$($smokeResult.exitCode)`r`n`r`nSTDOUT`r`n$($smokeResult.stdout)`r`nSTDERR`r`n$($smokeResult.stderr)"
            }
          } else {
            $smokeSummary = 'SMOKE: smoke.ps1 missing'
          }

          $redactLinePattern = '(?i)key|token|secret|password|bearer|authorization|gemini'
          $logsDir = Join-Path $runbookRoot 'logs'
          $logParts = New-Object 'System.Collections.Generic.List[string]'
          if (Test-Path -LiteralPath $logsDir -PathType Container) {
            $logFiles = @(Get-ChildItem -LiteralPath $logsDir -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name)
            if ($logFiles.Count -eq 0) {
              [void]$logParts.Add('No .log files found.')
            } else {
              foreach ($logFile in $logFiles) {
                [void]$logParts.Add("===== $($logFile.Name) =====")
                $tailLines = @(Get-Content -LiteralPath $logFile.FullName -Tail 200 -Encoding UTF8 -ErrorAction SilentlyContinue)
                foreach ($line in $tailLines) {
                  if ([string]$line -notmatch $redactLinePattern) { [void]$logParts.Add([string]$line) }
                }
                [void]$logParts.Add('')
              }
            }
          } else {
            [void]$logParts.Add('logs directory not found.')
          }
          $logsTail = $logParts -join "`r`n"

          $stateSummary = [ordered]@{}
          $stateSummary['state_available'] = ($null -ne $stateObj)
          foreach ($field in @('current_channel','current_task','held_task','status','paused','doctor_active','session_mission')) {
            $value = Get-RunbookPropertyValue $stateObj $field
            $stateSummary[$field] = ConvertTo-RunbookSummaryValue $value
          }
          $stateSummaryJson = $stateSummary | ConvertTo-Json -Depth 4

          $worktrees = Convert-RunbookProcessResultToText (Invoke-RunbookProcess -FileName 'git.exe' -ArgsList @('-C', $runbookRoot, 'worktree', 'list') -WorkingDirectory $runbookRoot -TimeoutMs 15000)

          Add-Type -AssemblyName System.IO.Compression
          $msOut = New-Object System.IO.MemoryStream
          $zip = New-Object System.IO.Compression.ZipArchive($msOut, [System.IO.Compression.ZipArchiveMode]::Create, $true)
          $addZipEntry = {
            param($Zip, [string]$Name, [string]$Content)
            $entry = $Zip.CreateEntry($Name)
            $w = $entry.Open()
            try {
              $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Content)
              $w.Write($bytes, 0, $bytes.Length)
            } finally {
              $w.Close()
            }
          }
          try {
            & $addZipEntry $zip 'git-status.txt' $gitStatus
            & $addZipEntry $zip 'health.json' $healthJson
            & $addZipEntry $zip 'smoke-summary.txt' $smokeSummary
            & $addZipEntry $zip 'logs-tail.txt' $logsTail
            & $addZipEntry $zip 'state-summary.json' $stateSummaryJson
            & $addZipEntry $zip 'worktrees.txt' $worktrees
          } finally {
            $zip.Dispose()
          }
          $zipBytes = $msOut.ToArray()
          $msOut.Dispose()

          $response = $ctx.Response
          $response.ContentType = 'application/zip'
          $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
          $response.Headers.Add('Content-Disposition', "attachment; filename=`"bridge-runbook-${ts}.zip`"")
          $response.ContentLength64 = $zipBytes.Length
          try {
            $response.OutputStream.Write($zipBytes, 0, $zipBytes.Length)
          } catch {
            try { $response.Abort() } catch {}
          } finally {
            try { $response.OutputStream.Close() } catch {}
          }
        } catch {
          $errJson = @{ error = $_.Exception.Message } | ConvertTo-Json -Depth 10 -Compress
          Send-Text $ctx $errJson 'application/json; charset=utf-8' 500
        }
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/metrics') {
        $m = Get-MetricsForApi
        Send-Text $ctx ($m | ConvertTo-Json -Compress -Depth 4) 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/audit/latest') {
        $auditDir = Join-Path $root 'audit'
        if (-not (Test-Path -LiteralPath $auditDir -PathType Container)) {
          Send-Text $ctx '{"error":"no audit available"}' 'application/json; charset=utf-8' 404
        } else {
          $auditFiles = @(Get-ChildItem -LiteralPath $auditDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
          if ($auditFiles.Count -eq 0) {
            Send-Text $ctx '{"error":"no audit available"}' 'application/json; charset=utf-8' 404
          } else {
            try {
              $auditRaw = [System.IO.File]::ReadAllText($auditFiles[0].FullName, [System.Text.Encoding]::UTF8)
              $auditObj = $auditRaw | ConvertFrom-Json
              $date = [System.IO.Path]::GetFileNameWithoutExtension($auditFiles[0].Name)
              $mdPath = Join-Path $auditDir ($date + '.md')
              $reportMd = ''
              if (Test-Path -LiteralPath $mdPath -PathType Leaf) {
                try { $reportMd = [System.IO.File]::ReadAllText($mdPath, [System.Text.Encoding]::UTF8) } catch { $reportMd = '' }
              }
              $sec = $auditObj.security_counts
              $fnc = $auditObj.functional_counts
              $secCritical = if ($null -ne $sec -and $null -ne $sec.critical) { [int]$sec.critical } else { 0 }
              $fncCritical = if ($null -ne $fnc -and $null -ne $fnc.critical) { [int]$fnc.critical } else { 0 }
              $apiObj = [ordered]@{
                date = $date
                security = @{
                  critical = $secCritical
                  warning = if ($null -ne $sec -and $null -ne $sec.warning) { [int]$sec.warning } else { 0 }
                  info = if ($null -ne $sec -and $null -ne $sec.info) { [int]$sec.info } else { 0 }
                }
                functional = @{
                  critical = $fncCritical
                  warning = if ($null -ne $fnc -and $null -ne $fnc.warning) { [int]$fnc.warning } else { 0 }
                  info = if ($null -ne $fnc -and $null -ne $fnc.info) { [int]$fnc.info } else { 0 }
                }
                total_critical = ($secCritical + $fncCritical)
                report_md = $reportMd
                generated_at = [string]$auditObj.generated_at
              }
              Send-Text $ctx ($apiObj | ConvertTo-Json -Compress -Depth 8) 'application/json; charset=utf-8'
            } catch {
              $errJson = @{ error = $_.Exception.Message } | ConvertTo-Json -Depth 10 -Compress
              Send-Text $ctx $errJson 'application/json; charset=utf-8' 500
            }
          }
        }
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/audit/list') {
        $auditDir = Join-Path $root 'audit'
        $dates = New-Object 'System.Collections.Generic.List[string]'
        if (Test-Path -LiteralPath $auditDir -PathType Container) {
          $auditFiles = @(Get-ChildItem -LiteralPath $auditDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
          foreach ($f in $auditFiles) {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            [void]$dates.Add($stem)
          }
        }
        $datesJson = '[' + (($dates.ToArray() | ForEach-Object { (("" + $_) | ConvertTo-Json -Depth 10 -Compress) }) -join ',') + ']'
        Send-Text $ctx ('{"audits":' + $datesJson + '}') 'application/json; charset=utf-8'
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
            Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
              Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$rf -WindowStyle Hidden | Out-Null
            }
            Send-Text $ctx '{"ok":true}' 'application/json; charset=utf-8'
          } catch {
            $err = ("" + $_.Exception.Message) | ConvertTo-Json -Depth 10 -Compress
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
          try {
            Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
              Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',$rf -WindowStyle Hidden | Out-Null
            }
          } catch {}
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
        $payload = '{"ok":true,"settings":' + $sJson + ',"advanced":' + $advJson + ',"workRoot":' + (("" + $cfg2.workRoot) | ConvertTo-Json -Depth 10 -Compress) + '}'
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
          if ($advUpd.Count -gt 0) {
            $advRes = Set-AdvancedSetting -Updates $advUpd
            if ($advRes -and $advRes.rejected -and @($advRes.rejected).Count -gt 0) {
              foreach ($rj in @($advRes.rejected)) {
                try { Add-Message -From system -Text ("⚠ Настройка `"" + $rj.key + "`" отклонена: " + $rj.reason) -Kind event | Out-Null } catch {}
              }
            }
          }
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
        $arr = '[' + (($projs | ForEach-Object { (("" + $_) | ConvertTo-Json -Depth 10 -Compress) }) -join ',') + ']'
        Send-Text $ctx ('{"ok":true,"projects":' + $arr + ',"bridge":' + (("" + (Get-BridgeRoot)) | ConvertTo-Json -Depth 10 -Compress) + '}') 'application/json; charset=utf-8'
      }
      elseif ($method -eq 'GET' -and $path -eq '/api/state') {
        $active = Get-ActiveChannel
        $scopeDto = Get-ActiveScopeDto -Slug $active
        Send-Text $ctx ('{"ok":true,"active":' + (("" + $active) | ConvertTo-Json -Depth 10 -Compress) + ',"is_bridge":' + ([bool]$scopeDto.is_bridge | ConvertTo-Json -Compress) + ',"project_root":' + (("" + [string]$scopeDto.project_root) | ConvertTo-Json -Depth 10 -Compress) + ',"scope":' + ($scopeDto | ConvertTo-Json -Compress -Depth 5) + '}') 'application/json; charset=utf-8'
      }
      # ----- multi-channel endpoints (phase 2) -----
      elseif ($method -eq 'GET' -and $path -eq '/api/channels') {
        # List non-archived channels + which one is active. ?includeArchived=1 includes them too.
        $inclArch = (Get-QueryParamUtf8 $ctx 'includeArchived') -eq '1'
        $list = if ($inclArch) { Get-ChannelList -IncludeArchived } else { Get-ChannelList }
        $active = Get-ActiveChannel
        $activeScope = Get-ActiveScopeDto -Slug $active
        $items = '[' + (($list | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 6 }) -join ',') + ']'
        Send-Text $ctx ('{"ok":true,"active":' + (("" + $active) | ConvertTo-Json -Depth 10 -Compress) + ',"active_scope":' + ($activeScope | ConvertTo-Json -Compress -Depth 5) + ',"items":' + $items + '}') 'application/json; charset=utf-8'
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
            Send-Text $ctx ('{"ok":true,"active":' + (("" + $slug) | ConvertTo-Json -Depth 10 -Compress) + '}') 'application/json; charset=utf-8'
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
      elseif ($method -eq 'GET' -and $path -eq '/api/features') {
        try {
          $features = Get-AllFeatures
          $arr = $features | ConvertTo-Json -Depth 8 -Compress
          if (-not $arr.StartsWith('[')) { $arr = "[$arr]" }
          Send-Text $ctx ('{"ok":true,"features":' + $arr + '}') 'application/json; charset=utf-8'
        } catch {
          Send-Text $ctx ('{"ok":false,"error":' + (($_.ToString()) | ConvertTo-Json -Depth 10 -Compress) + '}') 'application/json; charset=utf-8' 500
        }
      }
      elseif ($method -eq 'GET' -and $path -match '^/api/features/([a-z0-9_-]+)$') {
        $fid = [string]$Matches[1]
        try {
          $f = Get-Feature -Id $fid
          if (-not $f) {
            Send-Text $ctx '{"ok":false,"error":"not found"}' 'application/json; charset=utf-8' 404
          } else {
            Send-Text $ctx ($f | ConvertTo-Json -Depth 8 -Compress) 'application/json; charset=utf-8'
          }
        } catch {
          Send-Text $ctx ('{"ok":false,"error":' + (($_.ToString()) | ConvertTo-Json -Depth 10 -Compress) + '}') 'application/json; charset=utf-8' 500
        }
      }
      elseif ($method -eq 'POST' -and $path -eq '/api/features') {
        try {
          $body = $null
          try { $body = Read-Body $ctx | ConvertFrom-Json } catch { $body = $null }
          if (-not $body -or [string]::IsNullOrWhiteSpace([string]$body.id)) {
            Send-Text $ctx '{"ok":false,"error":"id required"}' 'application/json; charset=utf-8' 400
          } else {
            $sig = $null
            if ($body.activation_signal) { $sig = @{ kind = [string]$body.activation_signal.kind; path = [string]$body.activation_signal.path; regex = [string]$body.activation_signal.regex } }
            $deps = if ($body.dependencies) { @($body.dependencies | ForEach-Object { [string]$_ }) } else { @() }
            $files = if ($body.owner_files) { @($body.owner_files | ForEach-Object { [string]$_ }) } else { @() }
            $triggerVal = if ($body.trigger) { [string]$body.trigger } else { 'on-demand' }
            $frequencyVal = if ($body.expected_frequency) { [string]$body.expected_frequency } else { 'on-demand' }
            $layerVal = if ($body.layer) { [string]$body.layer } else { 'L2' }
            $statusVal = if ($body.status) { [string]$body.status } else { 'active' }
            $newF = Add-Feature `
              -Id ([string]$body.id) `
              -Name ([string]$body.name) `
              -Description ([string]$body.description) `
              -OwnerFiles $files `
              -OwnerFunction ([string]$body.owner_function) `
              -Trigger $triggerVal `
              -ExpectedFrequency $frequencyVal `
              -ActivationSignal $sig `
              -Dependencies $deps `
              -Layer $layerVal `
              -Status $statusVal
            Send-Text $ctx ('{"ok":true,"feature":' + ($newF | ConvertTo-Json -Depth 8 -Compress) + '}') 'application/json; charset=utf-8'
          }
        } catch {
          Send-Text $ctx ('{"ok":false,"error":' + (($_.ToString()) | ConvertTo-Json -Depth 10 -Compress) + '}') 'application/json; charset=utf-8' 500
        }
      }
      elseif ($method -eq 'POST' -and $path -match '^/api/features/([a-z0-9_-]+)/discuss$') {
        $fid = [string]$Matches[1]
        try {
          $f = Get-Feature -Id $fid
          if (-not $f) {
            Send-Text $ctx '{"ok":false,"error":"not found"}' 'application/json; charset=utf-8' 404
          } else {
            $body = $null
            try { $body = Read-Body $ctx | ConvertFrom-Json } catch { $body = $null }
            $note = if ($body -and $body.note) { [string]$body.note } else { '' }
            $idea = "Feature discussion: [$($f.id)] $($f.name) — $($f.description)$(if ($note) { " | Note: $note" })"
            . (Join-Path $PSScriptRoot 'lib\backlog.ps1')
            Add-Idea -Text $idea -From 'feature-discuss' -Tags @('feature','discussion') -Scope 'bridge' | Out-Null
            Send-Text $ctx '{"ok":true}' 'application/json; charset=utf-8'
          }
        } catch {
          Send-Text $ctx ('{"ok":false,"error":' + (($_.ToString()) | ConvertTo-Json -Depth 10 -Compress) + '}') 'application/json; charset=utf-8' 500
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
