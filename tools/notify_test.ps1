$ErrorActionPreference = 'Stop'
$root = 'C:\Users\rafie\OneDrive\Documents\bridge'
. (Join-Path $root 'lib\common.ps1')

$hasCreds = $false
try {
  $hasCreds = -not [string]::IsNullOrWhiteSpace((Get-Secret 'telegramBotToken')) -and -not [string]::IsNullOrWhiteSpace((Get-Secret 'telegramChatId'))
} catch {
  $hasCreds = $false
}

$stamp = (Get-Date).ToUniversalTime().ToString('o')
foreach ($kind in @('done','need_you','gate')) {
  $ok = Send-PushEvent -Kind $kind -Text "notify_test $kind $stamp"
  if ($ok) {
    Write-Output "$kind delivered"
  } elseif (-not $hasCreds) {
    Write-Output "$kind skipped: no creds"
  } else {
    Write-Output "$kind skipped-or-failed"
  }
}

$log = Get-NotifyLogPath
if (Test-Path -LiteralPath $log) {
  Write-Output 'notify.log tail:'
  Get-Content -LiteralPath $log -Encoding UTF8 -Tail 10
} else {
  Write-Output 'notify.log tail: <missing>'
}
