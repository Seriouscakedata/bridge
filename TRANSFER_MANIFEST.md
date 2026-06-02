# Transfer Manifest

This repository is a clean MOS Bridge distribution.

## Included

- Product code and tools.
- Clean `main` channel metadata.
- Portable configuration defaults.
- Seed memory about MOS architecture and operating rules.
- Examples for auth and secrets.

## Removed From The Original Operator Machine

- Private channels and archived channels.
- External projects.
- Chat history, backlog history, state files, checkpoints, snapshots.
- Uploaded files, screenshots, reports, audit output.
- Runtime directories and worktrees.
- Credentials, API keys, notification tokens, HTTP auth.
- Personal documentation that described the previous operator's local paths and project history.

## First-Run Runtime Files

The bridge creates runtime files on first start:

- `channels/main/conversation.jsonl`
- `channels/main/state.json`
- `channels/main/backlog.jsonl`
- `channels/main/plan.jsonl`
- `runtime/`
- `control/`
- `files/`
- `%USERPROFILE%\.bridge-private`
- `%USERPROFILE%\.bridge-runtime`

Those files are intentionally ignored by git.

