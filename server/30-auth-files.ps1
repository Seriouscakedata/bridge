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
