#Requires -Version 5.1
# parallel-llm-worker.ps1 -- a PARALLEL coder-worker backed by an API LLM (DeepSeek / Gemini) rather
# than an agentic CLI (codex/claude). 2026-06-01 (Foundation #4 scale-out to 20 workers).
# These models have no file-writing CLI, so this wrapper reads the worker prompt, asks the model to
# return FULL file contents in a strict block format, writes them into the worktree, then commits.
# Runs as the repo owner (not a sandbox), so it CAN git commit in the linked worktree.
# ASCII-only on purpose (no BOM dependency on PS 5.1).
#   -Model <deepseek-v4-pro|gemini-2.5-flash|...> -Worktree <path> -InFile <prompt> -MsgFile <out>
param([string]$Model, [string]$Worktree, [string]$InFile, [string]$MsgFile)
$ErrorActionPreference = 'Continue'
$bridge = Split-Path -Parent $PSScriptRoot
try { . (Join-Path $bridge 'lib\common.ps1') } catch { Set-Content $MsgFile ("STATUS: FAILED (lib load: " + $_.Exception.Message + ")") -Encoding UTF8; exit 1 }

$u8 = New-Object System.Text.UTF8Encoding($false)
$prompt = ''
try { $prompt = [System.IO.File]::ReadAllText($InFile, [System.Text.Encoding]::UTF8) } catch {}
if ([string]::IsNullOrWhiteSpace($prompt)) { Set-Content $MsgFile 'STATUS: FAILED (empty prompt)' -Encoding UTF8; exit 1 }

# Give the model the CURRENT content of any declared files (lines that look like "Files: a, b").
$fileBlocks = ''
$declRx = [regex]'(?im)files?\s*:\s*([^\r\n]+)'
foreach ($mm in $declRx.Matches($prompt)) {
  foreach ($f in ($mm.Groups[1].Value -split '[,;\s]+')) {
    $rel = ([string]$f).Trim().Trim('"').Trim("'")
    if ($rel -notmatch '\.\w{1,5}$') { continue }
    $full = Join-Path $Worktree ($rel -replace '/', '\')
    if (Test-Path -LiteralPath $full) {
      $cur = ''
      try { $cur = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8) } catch {}
      $fileBlocks += "`n<<<CURRENT: $rel>>>`n$cur`n<<<END>>>`n"
    }
  }
}

$ask = $prompt + "`n`n=== CURRENT FILE CONTENTS ===`n" + $fileBlocks + @"

=== OUTPUT FORMAT (STRICT, no prose) ===
For EACH file you create or modify, output EXACTLY this block:
<<<FILE: relative/path/from/project/root>>>
<the FULL new file content, no markdown fences>
<<<END>>>
Output nothing except these blocks. Make the very last line: STATUS: DONE
"@

$reply = $null
try { $reply = Invoke-LLM -Model $Model -Prompt $ask -TimeoutSec 600 -Temperature 0.2 } catch { Set-Content $MsgFile ("STATUS: FAILED (LLM: " + $_.Exception.Message + ")") -Encoding UTF8; exit 1 }
if ([string]::IsNullOrWhiteSpace($reply)) { Set-Content $MsgFile 'STATUS: FAILED (empty LLM reply)' -Encoding UTF8; exit 1 }

$rx = [regex]'(?s)<<<FILE:\s*(.+?)>>>\r?\n(.*?)\r?\n<<<END>>>'
$written = 0
foreach ($m in $rx.Matches($reply)) {
  $rel = ($m.Groups[1].Value.Trim() -replace '\\', '/').TrimStart('/')
  if ([string]::IsNullOrWhiteSpace($rel) -or $rel -match '\.\.') { continue }
  $content = $m.Groups[2].Value
  $content = $content -replace '^```[\w-]*\r?\n', '' -replace '\r?\n```\s*$', ''
  $path = Join-Path $Worktree ($rel -replace '/', '\')
  $dir = Split-Path $path -Parent
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  try { [System.IO.File]::WriteAllText($path, $content, $u8); $written++ } catch {}
}
if ($written -eq 0) { Set-Content $MsgFile 'STATUS: FAILED (no FILE blocks returned)' -Encoding UTF8; exit 1 }

$git = if (Get-Command Get-GitExe -ErrorAction SilentlyContinue) { Get-GitExe } else { 'git' }
& $git -C $Worktree add -A 2>$null | Out-Null
& $git -C $Worktree commit -m ("parallel-llm (" + $Model + "): " + $written + " file(s)") 2>$null | Out-Null

Set-Content $MsgFile ("LLM-worker " + $Model + " wrote " + $written + " file(s)`nSTATUS: DONE") -Encoding UTF8
exit 0
