# MOS Bridge

MOS Bridge is a local operator console for AI-assisted software work. It runs a web UI, a supervisor, one driver per active channel, long-running job helpers, project memory, audits, and a parallel worker layer for larger project plans.

This repository is the clean transferable version. It intentionally does not include the original operator's private channels, chats, projects, logs, API keys, credentials, uploads, worktrees, or runtime state.

## Quick Start

Prerequisites:

- Python 3.10+ for portable `bridgectl.py` status/control.
- Windows + PowerShell 5.1 for the current legacy engine.
- Git.
- Codex CLI and/or Claude CLI installed and logged in if you want the bridge to execute AI work.
- Optional API keys for Gemini/DeepSeek if you want embeddings, audits, librarian, and API-model workers.

Run locally:

```powershell
git clone https://github.com/Seriouscakedata/bridge.git bridge
cd bridge
py .\bridgectl.py doctor
py .\bridgectl.py start
```

On macOS/Linux use `python3 ./bridgectl.py status` for portable inspection. The long-running legacy engine is still Windows-first until the next porting phases replace the PowerShell driver/server.

Portable control examples:

```powershell
py .\bridgectl.py channel list
py .\bridgectl.py message send "Status please" --channel main
py .\bridgectl.py backlog add "Review the project plan" --channel main --status new
```

Open:

```text
http://localhost:8787/
```

By default the UI listens on localhost only. To protect it with Basic auth, create:

```powershell
$priv = Join-Path $env:USERPROFILE '.bridge-private'
New-Item -ItemType Directory -Path $priv -Force | Out-Null
@{ user='operator'; password='YOUR_PASSWORD'; token='' } |
  ConvertTo-Json |
  Set-Content -LiteralPath (Join-Path $priv 'auth.json') -Encoding UTF8
```

LAN access is disabled by default. To expose MOS on the local network, first configure `auth.json`, then set `server.allowLan=true` in `config.json` or a local override. MOS refuses unauthenticated LAN exposure by default.

Optional API secrets live outside the repo too:

```powershell
$priv = Join-Path $env:USERPROFILE '.bridge-private'
@{
  geminiApiKey = '...'
  deepseekApiKey = '...'
  telegramBotToken = ''
  telegramChatId = ''
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $priv 'secrets.json') -Encoding UTF8
```

After adding `geminiApiKey`, you can import the clean seed memory into the vector store:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\import-seed-memory.ps1
```

If embeddings are unavailable, MOS still stores new memory records durably with `embedding_status=pending`; semantic recall is weaker until embeddings are later available.

## Documentation

- [Transfer setup](docs/TRANSFER_SETUP.md): install, first run, auth, secrets, seed memory, autostart.
- [Operator guide](docs/OPERATOR_GUIDE.md): how to use the bridge day to day.
- [Project workflow](docs/PROJECT_WORKFLOW_GUIDE.md): how a new project should move from idea to acceptance.
- [Cross-platform layer](docs/CROSS_PLATFORM_ARCHITECTURE.md): Python control layer, adapters, and porting boundary.
- [Transfer manifest](TRANSFER_MANIFEST.md): what is included and what is intentionally excluded.
- [Developer guide](DEVELOPER_GUIDE.md): internal architecture and development notes.

## What Is Included

- Bridge engine scripts: `driver.ps1`, `server.ps1`, `supervisor.ps1`, `start.ps1`, `stop.ps1`.
- Core libraries under `lib/`.
- Web console under `web/`.
- Tools under `tools/`.
- Clean `main` channel descriptor under `channels/main/channel.json`.
- Clean seed memory under `memory/seed/`, `memory/map.md`, and `memory/map.shared.md`.
- Portable `config.json` and `config.example.json`.

## What Is Not Included

- Personal project channels.
- Chat history and task history.
- Backlog/runtime state.
- Uploaded files, screenshots, logs, reports, worktrees, generated projects.
- `auth.json`, `secrets.json`, `.env`, local databases, tokens, or API keys.

## How Projects Work

The bridge treats each project as a channel. `main` is the bridge itself. New external projects should get their own channel with its own project root, backlog, state, and memory. The intended flow is:

1. Operator describes the idea in chat.
2. Discussion/planning produces a deep project map, UX map, server/client/data plan, risks, tests, and acceptance criteria.
3. The planner turns that plan into independent backlog atoms with dependencies.
4. The dispatcher groups compatible atoms into parallel workpacks.
5. Workers execute isolated pieces, collect results, merge, test, and report status in chat.
6. Project memory records facts, decisions, tests, risks, invariants, and worklog entries.
7. Acceptance checks verify the finished product against the project plan, not against generic hardcoded rules.

## Configuration Notes

`config.json` is committed as a portable default. For local overrides use ignored `settings.json` or edit your local `config.json`.

Important defaults:

- `port`: `8787`
- `workRoot`: `projects`
- `autonomy.autonomyDisabledChannels`: `["main"]`
- `parallel.maxStreams`: `6`
- `supervisor.maxConcurrentDrivers`: `6`
- `autonomy.operatorMode`: `autopilot` (`copilot` pauses autonomous backlog claiming)
- `server.allowLan`: `false`
- `server.requireAuthForLan`: `true`
- `notify.enabled`: `false`

Codex/Claude executable paths are auto-detected from the current Windows user profile. If auto-detection fails, set `codexExe` or `claudeGlob` in `config.json`.

## Safety

Do not commit:

- `.bridge-private` contents.
- `auth.json`, `secrets.json`, `.env`.
- `channels/*/conversation.jsonl`, `backlog.jsonl`, `state.json`.
- `projects/`, `worktrees/`, `runtime/`, `control/`, `files/`, `reports/`, `audit/`.

These are ignored by `.gitignore`.
