# Transfer Manifest

This repository is a clean MOS Bridge distribution.

## Included

- Product code and tools.
- Clean `main` channel metadata.
- Portable configuration defaults.
- Seed memory about MOS architecture and operating rules.
- Examples for auth and secrets.
- Clean documentation for setup, operator usage, and project workflow.

## Documentation Included

- `README.md`: short overview and quick start.
- `docs/TRANSFER_SETUP.md`: install and first-run setup.
- `docs/OPERATOR_GUIDE.md`: day-to-day operator workflow.
- `docs/PROJECT_WORKFLOW_GUIDE.md`: universal project lifecycle.
- `DEVELOPER_GUIDE.md`: bridge internals and development notes.
- `PROJECT_WORKFLOW.md`: lower-level project workflow notes used by the bridge.

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
