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
# 2026-06-01: guarantee a STATUS line on ANY terminating failure (incl. the PS 5.1 NativeCommandError
# that fires when a native exe writes to stderr even on exit 0) so the worker is NEVER scored 'failed'
# silently with no reason. Get-WorkerResult defaults to 'failed' when no STATUS is found; this trap
# makes every exit path emit a parseable STATUS with a diagnosable cause.
trap { try { Set-Content $MsgFile ("STATUS: FAILED (trap: " + (($_ | Out-String) -replace '\s+',' ').Trim() + ")") -Encoding UTF8 } catch {}; exit 1 }
$bridge = Split-Path -Parent $PSScriptRoot
try { . (Join-Path $bridge 'lib\common.ps1') } catch { Set-Content $MsgFile ("STATUS: FAILED (lib load: " + $_.Exception.Message + ")") -Encoding UTF8; exit 1 }

$u8 = New-Object System.Text.UTF8Encoding($false)
$prompt = ''
try { $prompt = [System.IO.File]::ReadAllText($InFile, [System.Text.Encoding]::UTF8) } catch {}
if ([string]::IsNullOrWhiteSpace($prompt)) { Set-Content $MsgFile 'STATUS: FAILED (empty prompt)' -Encoding UTF8; exit 1 }

# Give the model the CURRENT content of any declared files (lines that look like "Files: a, b").
$fileBlocks = ''
$allowedEntries = @{}
function Normalize-WorkerRel([string]$Rel) {
  $r = ([string]$Rel).Trim().Trim('"').Trim("'")
  if ([string]::IsNullOrWhiteSpace($r)) { return '' }
  if ([System.IO.Path]::IsPathRooted($r)) { return '' }
  $r = ($r -replace '\\', '/')
  if ($r.StartsWith('/') -or $r -match '^[A-Za-z]:') { return '' }
  $parts = New-Object 'System.Collections.Generic.List[string]'
  foreach ($segment in ($r -split '/+')) {
    if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.') { continue }
    if ($segment -eq '..' -or $segment -match ':') { return '' }
    [void]$parts.Add($segment)
  }
  if ($parts.Count -eq 0) { return '' }
  $normalized = $parts -join '/'
  if ($normalized -eq '.git' -or $normalized.StartsWith('.git/')) { return '' }
  return $normalized
}
function Test-WorkerRelAllowed([string]$Rel, [hashtable]$Allowed) {
  $relNorm = Normalize-WorkerRel $Rel
  if ([string]::IsNullOrWhiteSpace($relNorm)) { return $false }
  if ($relNorm -eq 'control/restart.flag') { return $false }
  if (-not $Allowed -or $Allowed.Count -eq 0) { return $false }
  foreach ($key in @($Allowed.Keys)) {
    $allowedRel = [string]$key
    $isDir = [bool]$Allowed[$key]
    if ($relNorm -eq $allowedRel) { return $true }
    if ($isDir -and $relNorm.StartsWith($allowedRel.TrimEnd('/') + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}
function ConvertTo-WorkerProcessArgument([AllowNull()][string]$Value) {
  if ($null -eq $Value -or $Value.Length -eq 0) { return '""' }
  if ($Value -notmatch '[\s"]') { return $Value }
  $escaped = ([string]$Value) -replace '(\\*)"', '$1$1\"'
  $escaped = $escaped -replace '(\\+)$', '$1$1'
  return '"' + $escaped + '"'
}
function Invoke-WorkerProcess([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSec = 120) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = (@($Arguments) | ForEach-Object { ConvertTo-WorkerProcessArgument ([string]$_) }) -join ' '
  $psi.WorkingDirectory = $WorkingDirectory
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  try { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 } catch {}
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEndAsync()
  $stderr = $proc.StandardError.ReadToEndAsync()
  $timedOut = $false
  if (-not $proc.WaitForExit([Math]::Max(1, $TimeoutSec) * 1000)) {
    $timedOut = $true
    try { $proc.Kill() } catch {}
    try { $proc.WaitForExit(3000) | Out-Null } catch {}
  }
  try { $stdout.Wait(3000) | Out-Null } catch {}
  try { $stderr.Wait(3000) | Out-Null } catch {}
  return [pscustomobject]@{
    ExitCode = if ($timedOut) { 124 } else { [int]$proc.ExitCode }
    TimedOut = $timedOut
    Output   = @(
      if ($stdout.IsCompleted -and -not [string]::IsNullOrEmpty($stdout.Result)) { $stdout.Result }
      if ($stderr.IsCompleted -and -not [string]::IsNullOrEmpty($stderr.Result)) { $stderr.Result }
    )
  }
}
$declRx = [regex]'(?im)files?\s*:\s*([^\r\n]+)'
foreach ($mm in $declRx.Matches($prompt)) {
  foreach ($f in ($mm.Groups[1].Value -split '[,;\s]+')) {
    $rel = Normalize-WorkerRel $f
    if ([string]::IsNullOrWhiteSpace($rel)) { continue }
    $isDir = (([string]$f).Trim().EndsWith('/') -or ([string]$f).Trim().EndsWith('\') -or $rel -notmatch '/?[^/]+\.[^/]+$')
    $allowedEntries[$rel.ToLowerInvariant()] = [bool]$isDir
    $full = Join-Path $Worktree ($rel -replace '/', '\')
    if (Test-Path -LiteralPath $full) {
      $cur = ''
      try { $cur = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8) } catch {}
      $fileBlocks += "`n<<<CURRENT: $rel>>>`n$cur`n<<<END>>>`n"
    }
  }
}
if ($allowedEntries.Count -eq 0) { Set-Content $MsgFile 'STATUS: FAILED (no allowed Files touch-set declared)' -Encoding UTF8; exit 1 }

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
$writtenPaths = @()
$pendingWrites = New-Object 'System.Collections.Generic.List[object]'
$deniedPaths = New-Object 'System.Collections.Generic.List[string]'
foreach ($m in $rx.Matches($reply)) {
  $rawRel = [string]$m.Groups[1].Value
  $rel = Normalize-WorkerRel $rawRel
  if ([string]::IsNullOrWhiteSpace($rel)) { [void]$deniedPaths.Add($rawRel); continue }
  $relKey = $rel.ToLowerInvariant()
  if (-not (Test-WorkerRelAllowed -Rel $relKey -Allowed $allowedEntries)) { [void]$deniedPaths.Add($rel); continue }
  $content = $m.Groups[2].Value
  $content = $content -replace '^```[\w-]*\r?\n', '' -replace '\r?\n```\s*$', ''
  [void]$pendingWrites.Add([pscustomobject]@{ Rel = $rel; Content = $content })
}
if ($deniedPaths.Count -gt 0) {
  Set-Content $MsgFile ("STATUS: FAILED (denied FILE path(s): " + ((@($deniedPaths.ToArray()) | Select-Object -First 12) -join ', ') + ")") -Encoding UTF8
  exit 1
}
foreach ($item in @($pendingWrites.ToArray())) {
  $rel = [string]$item.Rel
  $path = [System.IO.Path]::GetFullPath((Join-Path $Worktree ($rel -replace '/', '\')))
  $worktreeFull = [System.IO.Path]::GetFullPath($Worktree).TrimEnd('\','/')
  $worktreePrefix = $worktreeFull + [System.IO.Path]::DirectorySeparatorChar
  if (-not ($path.Equals($worktreeFull, [System.StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($worktreePrefix, [System.StringComparison]::OrdinalIgnoreCase))) {
    Set-Content $MsgFile ("STATUS: FAILED (resolved path escapes worktree: " + $rel + ")") -Encoding UTF8
    exit 1
  }
  $dir = Split-Path $path -Parent
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  try { [System.IO.File]::WriteAllText($path, [string]$item.Content, $u8); $written++; $writtenPaths += $path } catch {}
}
if ($written -eq 0) { Set-Content $MsgFile 'STATUS: FAILED (no FILE blocks returned)' -Encoding UTF8; exit 1 }

$git = if (Get-Command Get-GitExe -ErrorAction SilentlyContinue) { Get-GitExe } else { 'git' }
$gitAddArgs = @('-c','core.autocrlf=false','-c','core.safecrlf=false','-C',$Worktree,'add','--') + @($writtenPaths)
$gitAdd = Invoke-WorkerProcess -FilePath $git -Arguments $gitAddArgs -WorkingDirectory $Worktree -TimeoutSec 120
$gitCommitArgs = @('-c','core.autocrlf=false','-c','core.safecrlf=false','-C',$Worktree,'commit','-m',("parallel-llm (" + $Model + "): " + $written + " file(s)"))
$gitCommit = Invoke-WorkerProcess -FilePath $git -Arguments $gitCommitArgs -WorkingDirectory $Worktree -TimeoutSec 120
$committed = ($gitAdd.ExitCode -eq 0 -and $gitCommit.ExitCode -eq 0 -and -not $gitAdd.TimedOut -and -not $gitCommit.TimedOut)

# Report wrote-count + a parseable STATUS regardless of CRLF/stderr noise.
$tail = "STATUS: DONE"
if (-not $committed) { $tail = "STATUS: DONE (files written; commit reported non-zero — host collect-then-commit will pick them up)" }
Set-Content $MsgFile ("LLM-worker " + $Model + " wrote " + $written + " file(s)`n" + $tail) -Encoding UTF8
exit 0
