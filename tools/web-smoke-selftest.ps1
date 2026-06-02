#Requires -Version 5.1
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $PSScriptRoot 'web-smoke.ps1'
if (-not (Test-Path -LiteralPath $tool)) { throw "web-smoke.ps1 not found: $tool" }

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERT FAILED: $Message" }
}

function Get-FreeTcpPort {
  $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse('127.0.0.1'), 0)
  try {
    $listener.Start()
    return [int]$listener.LocalEndpoint.Port
  } finally {
    try { $listener.Stop() } catch {}
  }
}

$tmp = Join-Path $env:TEMP ('bridge-web-smoke-selftest-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$server = Join-Path $tmp 'tiny-server.ps1'
$port = Get-FreeTcpPort
$serverCode = @'
param([int]$Port)
$ErrorActionPreference = 'Stop'
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Parse('127.0.0.1'), $Port)
$listener.Start()
$deadline = (Get-Date).AddSeconds(45)
try {
  while ((Get-Date) -lt $deadline) {
    if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $buffer = New-Object byte[] 4096
      $read = $stream.Read($buffer, 0, $buffer.Length)
      $request = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
      $status = 404
      $reason = 'Not Found'
      $body = 'missing'
      if ($request -match 'GET\s+/ready\s') { $status = 200; $reason = 'OK'; $body = 'ready' }
      elseif ($request -match 'GET\s+/secret\s') { $status = 401; $reason = 'Unauthorized'; $body = 'Unauthorized' }
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
      $header = "HTTP/1.1 $status $reason`r`nContent-Type: text/plain; charset=utf-8`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
      $headBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
      $stream.Write($headBytes, 0, $headBytes.Length)
      $stream.Write($bytes, 0, $bytes.Length)
      $stream.Flush()
    } finally {
      try { $client.Close() } catch {}
    }
  }
} finally {
  try { $listener.Stop() } catch {}
}
'@
[System.IO.File]::WriteAllText($server, $serverCode, (New-Object System.Text.UTF8Encoding($true)))

try {
  $cmd = 'powershell.exe -NoProfile -File "' + $server + '" -Port ' + $port
  $log = Join-Path $tmp 'server.log'
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tool `
    -ProjectRoot $tmp `
    -StartCommand $cmd `
    -Port $port `
    -ReadyPath '/ready' `
    -Check '/secret=401;/missing=404;/ready=200' `
    -TimeoutSec 30 `
    -LogPath $log 2>&1 | Out-String
  $exit = $LASTEXITCODE
  Write-Host $output
  Assert-True ($exit -eq 0) "web-smoke selftest expected exit 0, got $exit"
  Assert-True ($output -match 'ready:') 'output should include readiness'
  Assert-True ($output -match '/secret.*401.*PASS') 'output should include 401 PASS'
  Assert-True ($output -match 'PASS') 'output should include PASS'
  Write-Host 'OK: web-smoke selftest passed'
} finally {
  try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
}
