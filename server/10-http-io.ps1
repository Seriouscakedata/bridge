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
