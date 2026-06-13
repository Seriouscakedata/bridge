param(
  [string]$Task,
  [int]$TimeoutMs = 5000,
  [switch]$Worker
)

$ProgressPreference = 'SilentlyContinue'


if (-not $Worker) {
  $proc = $null
  try {
    $taskLiteral = ([string]$Task) -replace "'","''"
    $pathLiteral = ([string]$PSCommandPath) -replace "'","''"
    $workerCommand = "& '$pathLiteral' -Worker -TimeoutMs $TimeoutMs -Task '$taskLiteral'"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($workerCommand))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit($TimeoutMs)) {
      try { $proc.Kill() } catch { Write-Output ('{"ok":false,"message":"computer-use timeout; kill failed: ' + ($_.Exception.Message -replace '"','\"') + '","logs":["hard timeout ' + [string]$TimeoutMs + 'ms"]}'); exit 124 }
      Write-Output ('{"ok":false,"message":"computer-use timeout","logs":["hard timeout ' + [string]$TimeoutMs + 'ms"]}')
      exit 124
    }
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { Write-Output $stdout.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { Write-Output $stderr.Trim() }
    exit $proc.ExitCode
  } catch {
    Write-Output ('{"ok":false,"message":"computer-use launcher failed: ' + ($_.Exception.Message -replace '"','\"') + '","logs":[]}')
    exit 1
  }
}

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Logs = New-Object 'System.Collections.Generic.List[string]'
$script:StartedAt = [DateTime]::UtcNow
$script:BeforeShot = ''

try {
  $shotScript = Join-Path $PSScriptRoot 'screenshot.ps1'
  $bridgeRt2 = Split-Path $PSScriptRoot -Parent
  $shotDir2 = Join-Path $bridgeRt2 'control\cu-screenshots'
  if (-not (Test-Path -LiteralPath $shotDir2)) { [void](New-Item -ItemType Directory -Path $shotDir2 -Force) }
  $ts2 = $script:StartedAt.ToString('yyyyMMddHHmmss')
  $tmpB = (& $shotScript | Select-Object -Last 1)
  if (-not [string]::IsNullOrWhiteSpace($tmpB) -and (Test-Path -LiteralPath $tmpB)) {
    $beforeName = "cu-${ts2}-before.png"
    Copy-Item -LiteralPath $tmpB -Destination (Join-Path $shotDir2 $beforeName) -Force
    $script:BeforeShot = $beforeName
  }
} catch {}

function Write-CuHistory {
  param([bool]$Ok,[string]$Message,[string]$Layer)
  try {
    $bridgeRt = Split-Path $PSScriptRoot -Parent
    $shotDir = Join-Path $bridgeRt 'control\cu-screenshots'
    if (-not (Test-Path -LiteralPath $shotDir)) { [void](New-Item -ItemType Directory -Path $shotDir -Force) }
    $ts = $script:StartedAt.ToString('yyyyMMddHHmmss')
    $afterName = ''
    try {
      $tmpShot = (& (Join-Path $PSScriptRoot 'screenshot.ps1') | Select-Object -Last 1)
      if (-not [string]::IsNullOrWhiteSpace($tmpShot) -and (Test-Path -LiteralPath $tmpShot)) {
        $afterName = "cu-${ts}-after.png"
        Copy-Item -LiteralPath $tmpShot -Destination (Join-Path $shotDir $afterName) -Force
      }
    } catch {}
    $record = [ordered]@{
      ts         = $script:StartedAt.ToString('o')
      task       = [string]$Task
      ok         = [bool]$Ok
      message    = [string]$Message
      layer      = [string]$Layer
      latencyMs  = [int]([DateTime]::UtcNow - $script:StartedAt).TotalMilliseconds
      beforeShot = [string]$script:BeforeShot
      afterShot  = [string]$afterName
    }
    $line = ($record | ConvertTo-Json -Compress -Depth 4)
    $histFile = Join-Path $bridgeRt 'control\cu-history.jsonl'
    $existing = @()
    if (Test-Path -LiteralPath $histFile) { $existing = @(Get-Content -LiteralPath $histFile -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
    $newLines = @(@($existing | Select-Object -Last 19) + @($line))
    [System.IO.File]::WriteAllText($histFile, ($newLines -join "`n"), (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

function Add-ComputerUseLog {
  param([string]$Text)
  if (-not [string]::IsNullOrWhiteSpace($Text)) { [void]$script:Logs.Add($Text) }
}

function Complete-ComputerUse {
  param([bool]$Ok, [string]$Message, [hashtable]$Extra = $null)
  $result = [ordered]@{
    ok = [bool]$Ok
    message = [string]$Message
    logs = @($script:Logs.ToArray())
  }
  if ($Extra) {
    foreach ($k in $Extra.Keys) { $result[$k] = $Extra[$k] }
  }
  $json = ($result | ConvertTo-Json -Compress -Depth 8)
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $json.ToCharArray()) {
    $code = [int][char]$ch
    if ($code -ge 32 -and $code -le 126) { [void]$sb.Append($ch) }
    elseif ($code -eq 10) { [void]$sb.Append('\n') }
    elseif ($code -eq 13) { [void]$sb.Append('\r') }
    elseif ($code -eq 9) { [void]$sb.Append('\t') }
    else { [void]$sb.Append(('\u{0:x4}' -f $code)) }
  }
  Write-Output ([string]$sb.ToString())
  if ($Ok) { exit 0 }
  exit 1
}

function Add-ComputerUseUser32 {
  if ('BridgeComputerUse.User32' -as [type]) { return }
  Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace BridgeComputerUse {
  public static class User32 {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, UInt32 Msg, IntPtr wParam, IntPtr lParam);
  }
}
"@
}

function Get-ForegroundWindowHandle {
  Add-ComputerUseUser32
  return [BridgeComputerUse.User32]::GetForegroundWindow()
}

function Get-WindowTitle {
  param([IntPtr]$Handle)
  Add-ComputerUseUser32
  if ($Handle -eq [IntPtr]::Zero) { return '' }
  $sb = New-Object System.Text.StringBuilder 512
  [void][BridgeComputerUse.User32]::GetWindowText($Handle, $sb, $sb.Capacity)
  return [string]$sb.ToString()
}

function Get-TaskTokens {
  param([string]$Text)
  $stop = @('нажми','нажать','кликни','кликнуть','закрой','закрыть','окно','это','то','button','click','press','close','window','mouse','ok','ок')
  $tokens = New-Object 'System.Collections.Generic.List[string]'
  foreach ($m in [regex]::Matches(([string]$Text).ToLowerInvariant(), '[\p{L}\p{Nd}]{3,}')) {
    $v = [string]$m.Value
    if ($stop -notcontains $v) { [void]$tokens.Add($v) }
  }
  if ([string]$Text -match '(?i)teamviewer|тимвив') { [void]$tokens.Add('teamviewer') }
  return @($tokens.ToArray() | Select-Object -Unique)
}

function Get-ButtonNamesForTask {
  param([string]$Text)
  $names = New-Object 'System.Collections.Generic.List[string]'
  $t = ([string]$Text).ToLowerInvariant()
  if ($t -match '(?i)\bok\b|(^|[^а-яё])ок([^а-яё]|$)|\bоk\b') { foreach ($n in @('OK','Ok','ОК','Ок')) { [void]$names.Add($n) } }
  if ($t -match '(?i)закр|close') { foreach ($n in @('Close','Закрыть','OK','ОК')) { [void]$names.Add($n) } }
  if ($t -match '(?i)cancel|отмен') { foreach ($n in @('Cancel','Отмена','Отменить')) { [void]$names.Add($n) } }
  if ($names.Count -eq 0) { foreach ($n in @('OK','ОК','Close','Закрыть')) { [void]$names.Add($n) } }
  return @($names.ToArray() | Select-Object -Unique)
}

function Invoke-UIAutomationLayer {
  param([string]$TaskText)
  Add-ComputerUseLog 'layer1: UIAutomation start'
  Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
  Add-ComputerUseUser32
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $windows = @($root.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition))
  $buttonNames = @(Get-ButtonNamesForTask -Text $TaskText)
  $tokens = @(Get-TaskTokens -Text $TaskText)
  $candidates = New-Object System.Collections.ArrayList
  $buttonCondition = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)

  foreach ($win in $windows) {
    $title = ''
    try { $title = [string]$win.Current.Name } catch { $title = '' }
    if ([string]::IsNullOrWhiteSpace($title)) { continue }
    $titleLower = $title.ToLowerInvariant()
    $titleScore = 0
    foreach ($tok in $tokens) {
      if (-not [string]::IsNullOrWhiteSpace($tok) -and $titleLower.Contains(([string]$tok).ToLowerInvariant())) { $titleScore += 20 }
    }
    $buttons = @()
    try { $buttons = @($win.FindAll([System.Windows.Automation.TreeScope]::Descendants, $buttonCondition)) } catch { $buttons = @() }
    foreach ($btn in $buttons) {
      $name = ''
      $enabled = $false
      try { $name = [string]$btn.Current.Name; $enabled = [bool]$btn.Current.IsEnabled } catch { $enabled = $false }
      if (-not $enabled -or [string]::IsNullOrWhiteSpace($name)) { continue }
      $score = $titleScore
      foreach ($want in $buttonNames) {
        if ($name -ieq $want) { $score += 100 }
        elseif ($name.ToLowerInvariant().Contains(([string]$want).ToLowerInvariant())) { $score += 60 }
      }
      if ($score -ge 60) {
        [void]$candidates.Add([pscustomobject]@{ Window=$win; Button=$btn; Name=$name; Title=$title; Score=$score })
      }
    }
  }

  $best = @($candidates | Sort-Object Score -Descending | Select-Object -First 1)
  if ($best.Count -gt 0) {
    $b = $best[0]
    Add-ComputerUseLog ("layer1: invoking button '" + [string]$b.Name + "' in '" + [string]$b.Title + "'")
    try {
      $pattern = $b.Button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
      $pattern.Invoke()
      Start-Sleep -Milliseconds 350
      return [pscustomobject]@{ ok=$true; message=("UIAutomation invoked '" + [string]$b.Name + "' in '" + [string]$b.Title + "'"); verified=$true }
    } catch {
      Add-ComputerUseLog ('layer1: invoke failed: ' + $_.Exception.Message)
    }
  }

  if ([regex]::IsMatch($TaskText, '(?i)закр|close')) {
    foreach ($win in $windows) {
      $title = ''
      $handle = [IntPtr]::Zero
      try { $title = [string]$win.Current.Name; $handle = [IntPtr]([int]$win.Current.NativeWindowHandle) } catch { $handle = [IntPtr]::Zero }
      if ($handle -eq [IntPtr]::Zero -or [string]::IsNullOrWhiteSpace($title)) { continue }
      $titleLower = $title.ToLowerInvariant()
      $matched = $false
      foreach ($tok in $tokens) {
        if (-not [string]::IsNullOrWhiteSpace($tok) -and $titleLower.Contains(([string]$tok).ToLowerInvariant())) { $matched = $true; break }
      }
      if ($matched) {
        Add-ComputerUseLog ("layer1: WM_CLOSE '" + $title + "'")
        [void][BridgeComputerUse.User32]::SendMessage($handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 500
        $visible = [BridgeComputerUse.User32]::IsWindowVisible($handle)
        return [pscustomobject]@{ ok=((-not $visible)); message=("WM_CLOSE sent to '" + $title + "'"); verified=(-not $visible) }
      }
    }
  }

  return [pscustomobject]@{ ok=$false; message='UIAutomation did not find a safe target'; verified=$false }
}

function Invoke-MouseClick {
  param([int]$X, [int]$Y)
  Add-ComputerUseUser32
  [void][BridgeComputerUse.User32]::SetCursorPos($X, $Y)
  Start-Sleep -Milliseconds 80
  [BridgeComputerUse.User32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds 80
  [BridgeComputerUse.User32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function ConvertFrom-ComputerUseJson {
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $clean = ($Text -replace '```(?:json)?','' -replace '```','').Trim()
  $m = [regex]::Match($clean, '(?s)\{.*\}')
  if (-not $m.Success) { return $null }
  try { return ($m.Value | ConvertFrom-Json) } catch { return $null }
}

function Invoke-VisionLayer {
  param([string]$TaskText)
  Add-ComputerUseLog 'layer2: vision start'
  $secretPath = 'C:\Users\rafie\.bridge-private\secrets.json'
  if (-not (Test-Path -LiteralPath $secretPath)) { return [pscustomobject]@{ ok=$false; message='Gemini secret file not found'; verified=$false } }
  $key = ''
  try {
    $secrets = Get-Content -LiteralPath $secretPath -Raw | ConvertFrom-Json
    foreach ($name in @('geminiApiKey','googleApiKey','GeminiApiKey','GEMINI_API_KEY')) {
      if ($secrets.PSObject.Properties.Name -contains $name -and -not [string]::IsNullOrWhiteSpace([string]$secrets.$name)) { $key = [string]$secrets.$name; break }
    }
  } catch {
    Add-ComputerUseLog ('layer2: secret read failed: ' + $_.Exception.Message)
  }
  if ([string]::IsNullOrWhiteSpace($key)) { return [pscustomobject]@{ ok=$false; message='Gemini API key not found'; verified=$false } }

  $shot = ''
  try { $shot = (& (Join-Path $PSScriptRoot 'screenshot.ps1') | Select-Object -Last 1) } catch { Add-ComputerUseLog ('layer2: screenshot failed: ' + $_.Exception.Message) }
  if ([string]::IsNullOrWhiteSpace($shot) -or -not (Test-Path -LiteralPath $shot)) { return [pscustomobject]@{ ok=$false; message='screenshot failed'; verified=$false } }

  Add-Type -AssemblyName System.Drawing
  $width = 0; $height = 0
  $bmp = $null
  try {
    $bmp = [System.Drawing.Bitmap]::FromFile($shot)
    $width = [int]$bmp.Width
    $height = [int]$bmp.Height
  } finally {
    if ($bmp) { $bmp.Dispose() }
  }
  $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($shot))
  $prompt = @"
You control a Windows desktop by returning one bounded action.
Screen size: width=$width height=$height.
Task: $TaskText
Return STRICT JSON only:
{"action":"click","x":0,"y":0,"confidence":0.0,"reason":""}
Only choose a click if the target is visible and unambiguous. Otherwise confidence below 0.7.
"@
  $body = @{
    contents = @(@{
      role = 'user'
      parts = @(
        @{ text = $prompt },
        @{ inline_data = @{ mime_type = 'image/png'; data = $b64 } }
      )
    })
    generationConfig = @{ temperature = 0; response_mime_type = 'application/json' }
  } | ConvertTo-Json -Depth 12 -Compress
  $uri = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key=' + [uri]::EscapeDataString($key)
  $raw = ''
  try {
    $resp = Invoke-WebRequest -Method Post -Uri $uri -ContentType 'application/json' -Body $body -UseBasicParsing -TimeoutSec 3
    $json = $resp.Content | ConvertFrom-Json
    $raw = [string]$json.candidates[0].content.parts[0].text
  } catch {
    return [pscustomobject]@{ ok=$false; message=('Gemini vision failed: ' + $_.Exception.Message); verified=$false }
  }
  $act = ConvertFrom-ComputerUseJson -Text $raw
  if (-not $act) { return [pscustomobject]@{ ok=$false; message='Gemini returned non-JSON action'; verified=$false; raw=$raw } }
  $confidence = 0.0
  try { $confidence = [double]$act.confidence } catch { $confidence = 0.0 }
  if ($confidence -lt 0.7) { return [pscustomobject]@{ ok=$false; message=('low confidence: ' + ('{0:N2}' -f $confidence)); verified=$false; raw=$raw } }
  $x = 0; $y = 0
  try { $x = [int]$act.x; $y = [int]$act.y } catch { return [pscustomobject]@{ ok=$false; message='invalid coordinates'; verified=$false; raw=$raw } }
  if ($x -lt 0) { $x = 0 }
  if ($y -lt 0) { $y = 0 }
  if ($x -ge $width) { $x = $width - 1 }
  if ($y -ge $height) { $y = $height - 1 }
  $before = Get-ForegroundWindowHandle
  Invoke-MouseClick -X $x -Y $y
  Start-Sleep -Milliseconds 400
  $after = Get-ForegroundWindowHandle
  $changed = ($before -ne $after)
  return [pscustomobject]@{ ok=$true; message=("vision click x=$x y=$y confidence=" + ('{0:N2}' -f $confidence)); verified=$changed; raw=$raw }
}

if ([string]::IsNullOrWhiteSpace($Task)) {
  Complete-ComputerUse -Ok $false -Message 'Task is empty'
}

try {
  $layer1 = Invoke-UIAutomationLayer -TaskText $Task
  if ($layer1 -and [bool]$layer1.ok) {
    Write-CuHistory -Ok $true -Message ([string]$layer1.message) -Layer 'uia'
    Complete-ComputerUse -Ok $true -Message ([string]$layer1.message) -Extra @{ layer='uia'; verified=[bool]$layer1.verified }
  }
  Add-ComputerUseLog ('layer1: ' + [string]$layer1.message)
  $layer2 = Invoke-VisionLayer -TaskText $Task
  if ($layer2 -and [bool]$layer2.ok) {
    Write-CuHistory -Ok $true -Message ([string]$layer2.message) -Layer 'vision'
    Complete-ComputerUse -Ok $true -Message ([string]$layer2.message) -Extra @{ layer='vision'; verified=[bool]$layer2.verified }
  }
  Write-CuHistory -Ok $false -Message ([string]$layer2.message) -Layer 'none'
  Complete-ComputerUse -Ok $false -Message ([string]$layer2.message) -Extra @{ layer='none'; verified=$false }
} catch {
  Add-ComputerUseLog ('fatal: ' + $_.Exception.Message)
  Write-CuHistory -Ok $false -Message ('computer-use failed: ' + $_.Exception.Message) -Layer 'error'
  Complete-ComputerUse -Ok $false -Message ('computer-use failed: ' + $_.Exception.Message)
}
