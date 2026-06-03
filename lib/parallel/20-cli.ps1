# --- Per-CLI invocation functions ---

function Invoke-ParallelCodexCli {
  # Launch codex.exe with -m <model> -c model_reasoning_effort="<level>".
  param([object]$Worker, [string]$Worktree, [string]$InFile, [string]$MsgFile, [string]$OutFile, [string]$ErrFile)
  $cfg = Get-BridgeConfig
  $codex = Resolve-CodexExe $cfg
  $model = [string]$Worker.model
  $effort = [string]$Worker.reasoning
  if ([string]::IsNullOrWhiteSpace($model)) { $model = 'gpt-5.5' }
  if ([string]::IsNullOrWhiteSpace($effort)) { $effort = 'high' }
  # SECURITY (Ф2): parallel/foundry workers used to hardcode -s danger-full-access, which fully
  # disables Codex's own command guards. Honor the same config-driven sandbox as the serial coder
  # (Get-CoderSandboxMode -> default 'workspace-write', fail-closed). EMPIRICAL CORRECTION
  # (Gate C, 2026-05-29 -- supersedes an earlier wrong note that said "not OS-enforced on Windows"):
  # workspace-write IS OS-enforced on this Windows host. Codex runs shell commands as a SEPARATE
  # restricted user account 'CodexSandboxOffline' (SID ...-1003), distinct from the repo owner
  # the repo owner. Consequence for LINKED worktrees: even though --add-dir puts the shared
  # <project>/.git in Codex's writable-roots, the NTFS ACL still denies the sandbox user write to
  # .git/worktrees/<id>/, so it cannot create index.lock and therefore cannot 'git add'/'git commit'
  # (verified: jobs/parallel/worker_s1_*.err.txt -> "Unable to create ...index.lock: Permission
  # denied"). FIX: Project Foundry workers run in HOST-MANAGED-COMMIT mode -- the worker only PRODUCES
  # files in its worktree cwd (which the sandbox CAN write) and the trusted host (repo owner) does the
  # git add/commit afterwards (see Get-FoundryDefaultOps Result Op + Spawn-Worker -HostManagedCommit).
  # --add-dir below stays: harmless for the host-commit path, and still useful where the sandbox CAN
  # write git metadata (Temp-rooted repos / Linux/macOS), so workers there can still commit directly.
  $sandbox = 'workspace-write'
  try { if (Get-Command Get-CoderSandboxMode -ErrorAction SilentlyContinue) { $sandbox = [string](Get-CoderSandboxMode) } } catch {}
  if ([string]::IsNullOrWhiteSpace($sandbox)) { $sandbox = 'workspace-write' }
  $cliArgs = @(
    'exec','--color','never','--skip-git-repo-check',
    '-c', "model=`"$model`"",
    '-c', "model_reasoning_effort=`"$effort`"",
    '-s', $sandbox
  )
  if ($sandbox -eq 'workspace-write') {
    $gitDir = $null
    try { if (Get-Command Get-WorktreeGitDir -ErrorAction SilentlyContinue) { $gitDir = Get-WorktreeGitDir $Worktree } } catch {}
    if ($gitDir) { $cliArgs += @('--add-dir', $gitDir) }
  }
  $cliArgs += @('-C',$Worktree,'-o',$MsgFile,'-')
  return Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
    Start-Process -FilePath $codex -ArgumentList $cliArgs `
      -RedirectStandardInput $InFile -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile `
      -NoNewWindow -PassThru
  }
}

function Invoke-ParallelClaudeCli {
  # Launch claude.exe in the worktree. Claude CLI has NO --cwd flag; use
  # Start-Process -WorkingDirectory to set the process cwd, then --add-dir
  # to grant tool access to that path (in case CLAUDE.md/AGENTS.md lookup
  # cares). 2026-05-27 fix: previous version used --cwd which Claude CLI
  # rejected with "unknown option" → every claude-* worker failed silently.
  param([object]$Worker, [string]$Worktree, [string]$InFile, [string]$MsgFile, [string]$OutFile, [string]$ErrFile)
  $cfg = Get-BridgeConfig
  $claude = Resolve-ClaudeExe $cfg
  $model = [string]$Worker.model
  if ([string]::IsNullOrWhiteSpace($model)) { $model = 'sonnet' }
  $cliArgs = @(
    '-p','--permission-mode','acceptEdits',
    '--add-dir', $Worktree,
    '--allowedTools','Read','Grep','Glob','Bash','Edit','MultiEdit','Write',
    '--model', $model
  )
  return Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
    Start-Process -FilePath $claude -ArgumentList $cliArgs `
      -WorkingDirectory $Worktree `
      -RedirectStandardInput $InFile -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile `
      -NoNewWindow -PassThru
  }
}

function Invoke-ParallelLLMCli {
  # 2026-06-01 (Foundation #4 scale): parallel worker backed by an API LLM (DeepSeek/Gemini) which has
  # NO agentic CLI. Launches a powershell process running tools/parallel-llm-worker.ps1 — it asks the
  # model for full file contents, writes them into the worktree, and commits. Same contract as the
  # codex/claude CLIs (returns System.Diagnostics.Process).
  param([object]$Worker, [string]$Worktree, [string]$InFile, [string]$MsgFile, [string]$OutFile, [string]$ErrFile)
  $model = [string]$Worker.model
  if ([string]::IsNullOrWhiteSpace($model)) { $model = 'deepseek-v4-pro' }
  $script = Join-Path (Get-BridgeRoot) 'tools\parallel-llm-worker.ps1'
  $cliArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Model', $model, '-Worktree', $Worktree, '-InFile', $InFile, '-MsgFile', $MsgFile)
  return Invoke-WithChannelEnv -Slug (Get-EffectiveChannel) -Action {
    Start-Process -FilePath 'powershell.exe' -ArgumentList $cliArgs `
      -RedirectStandardOutput $OutFile -RedirectStandardError $ErrFile -NoNewWindow -PassThru
  }.GetNewClosure()
}

# To add another CLI/LLM: implement Invoke-ParallelXxxCli with the same signature
# (returns System.Diagnostics.Process), then add to $Script:ParallelCliRegistry above
# and add worker entries to config.json.
