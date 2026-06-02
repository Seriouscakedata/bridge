# Transfer Setup

This guide is for installing a clean MOS Bridge copy on another Windows machine.

## 1. Clone

```powershell
git clone https://github.com/Seriouscakedata/bridge.git bridge
cd bridge
```

The repository is intentionally clean. It does not contain the previous operator's chats, projects, logs, credentials, uploads, or runtime state.

## 2. Required Tools

Install and sign in to the tools you want MOS to use:

- Git.
- PowerShell 5.1.
- Codex CLI, if Codex workers should run.
- Claude CLI, if Claude planner/coder workers should run.
- Node.js, if MOS will build or test Node/Next/Vite projects.

MOS auto-detects common Codex and Claude install paths. If detection fails, edit `config.json`:

```json
{
  "codexExe": "C:/path/to/codex.exe",
  "claudeGlob": "C:/path/to/Claude/claude-code/*/claude.exe"
}
```

## 3. First Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1
```

Open:

```text
http://localhost:8787/
```

MOS listens on localhost by default. Do not expose it on LAN until credentials are configured.

First run creates ignored runtime files such as:

- `channels/main/conversation.jsonl`
- `channels/main/state.json`
- `channels/main/backlog.jsonl`
- `control/`
- `runtime/`
- `files/`
- `%USERPROFILE%\.bridge-private`
- `%USERPROFILE%\.bridge-runtime`

## 4. UI Password

The transferred repo does not include credentials.

If local open access is acceptable, do nothing. If you want Basic auth, create:

```powershell
$priv = Join-Path $env:USERPROFILE '.bridge-private'
New-Item -ItemType Directory -Path $priv -Force | Out-Null
@{ user='operator'; password='CHANGE_THIS_PASSWORD'; token='' } |
  ConvertTo-Json |
  Set-Content -LiteralPath (Join-Path $priv 'auth.json') -Encoding UTF8
```

Restart MOS after changing auth.

LAN access is opt-in. To expose the UI to another device on the same network, keep auth enabled and set:

```json
{
  "server": {
    "allowLan": true,
    "requireAuthForLan": true
  }
}
```

If `server.allowLan=true` but no password/token exists, MOS ignores LAN mode and stays local-only.

## 5. API Secrets

Optional model/API features use `%USERPROFILE%\.bridge-private\secrets.json`.

```powershell
$priv = Join-Path $env:USERPROFILE '.bridge-private'
New-Item -ItemType Directory -Path $priv -Force | Out-Null
@{
  geminiApiKey = ''
  deepseekApiKey = ''
  telegramBotToken = ''
  telegramChatId = ''
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $priv 'secrets.json') -Encoding UTF8
```

Use real values only on the local machine. Never commit this file.

## 6. Seed Memory

The repository includes clean seed memory in:

- `memory/map.md`
- `memory/map.shared.md`
- `memory/seed/main.memory.jsonl`

If `geminiApiKey` is configured, import the seed into the vector store:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\import-seed-memory.ps1
```

If no key is configured, MOS still runs. New memory records are still written, but they are marked `embedding_status=pending` and semantic recall is weaker until embeddings are available.

## 7. Basic Health Check

Syntax/self-test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\verify_syntax.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\driver.ps1 -SelfTest
```

Runtime smoke after MOS is running:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\smoke.ps1
```

## 8. Stop And Restart

Stop:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\stop.ps1
```

Start:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1
```

Supervisor-controlled restart:

```powershell
New-Item -ItemType Directory -Path .\control -Force | Out-Null
Set-Content .\control\restart.flag '1' -Encoding ASCII
```

## 9. Autostart

Autostart is optional. Use only after manual start/stop works:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install-autostart.ps1
```

## 10. What To Keep Private

Do not publish or send:

- `%USERPROFILE%\.bridge-private`
- `%USERPROFILE%\.bridge-runtime`
- `auth.json`
- `secrets.json`
- `.env`
- `channels/*/conversation.jsonl`
- `channels/*/backlog.jsonl`
- `channels/*/state.json`
- `projects/`, `worktrees/`, `files/`, `runtime/`, `control/`, `reports/`, `audit/`
