# paste-to-window.ps1 -- reliably paste text into another app's focused input.
# Targets by PROCESS NAME (window title is unreliable -- e.g. Claude Code shows the
# chat name). Puts text on the clipboard, activates the app's window, sends Ctrl+V.
#   -ProcessName  e.g. 'claude' (Claude Code), 'Codex'
#   -Text / -TextFile  the text (TextFile is UTF-8, preferred for long/multiline)
#   -Send  also press Enter after pasting
param(
  [Parameter(Mandatory)][string]$ProcessName,
  [string]$Text = '',
  [string]$TextFile = '',
  [switch]$Send,
  [int]$DelayMs = 600
)
$ErrorActionPreference = 'Stop'
if ($TextFile -and (Test-Path $TextFile)) {
  $Text = [System.IO.File]::ReadAllText($TextFile, (New-Object System.Text.UTF8Encoding($false)))
}
if ([string]::IsNullOrEmpty($Text)) { Write-Output 'ERROR: empty text'; exit 1 }

Set-Clipboard -Value $Text

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
  Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle } |
  Select-Object -First 1
if (-not $proc) { Write-Output "ERROR: no visible window for process '$ProcessName'"; exit 2 }

$wsh = New-Object -ComObject WScript.Shell
$activated = $false
for ($i = 0; $i -lt 6 -and -not $activated; $i++) { $activated = $wsh.AppActivate($proc.Id); Start-Sleep -Milliseconds 200 }
Start-Sleep -Milliseconds $DelayMs
$wsh.SendKeys('^v')
if ($Send) { Start-Sleep -Milliseconds 400; $wsh.SendKeys('{ENTER}') }
Write-Output ("OK: pasted into " + $proc.Name + " '" + $proc.MainWindowTitle + "' (pid " + $proc.Id + "), activated=" + $activated)
