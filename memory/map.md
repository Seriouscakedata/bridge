# MOS Bridge Memory Map

This is the clean seed map for the transferable MOS Bridge.

## Identity

MOS Bridge is a local AI-operator system for software projects. It is designed to behave like a small development team: planner, coder workers, auditors, memory, project acceptance, and an operator-facing chat console.

## Core Architecture

- `server.ps1`: local web UI and HTTP API.
- `supervisor.ps1`: starts and supervises server/driver processes.
- `driver.ps1`: main task loop; reads chat/backlog, talks to planner/coder, dispatches work, records events.
- `watchdog.ps1`: independent safety monitor; restarts or rolls back only under strict health rules.
- `lib/`: shared modules for channels, backlog, memory, planning, project foundry, parallel work, audits, QA, metrics, and safety.
- `tools/`: deterministic helpers and test/audit scripts.
- `web/index.html`: operator console.

## Channel Model

- `main` is the bridge itself.
- Each external project should have its own channel.
- A project channel has its own state, backlog, project binding, and project memory.
- Bridge memory can be read by project channels as product/process knowledge; project memory must stay project-local unless explicitly shared.

## Project Creation Flow

1. Operator gives a project idea.
2. The bridge discusses and clarifies the idea.
3. The planner builds a deep project map: UX, UI, client, server, data model, risks, tests, acceptance criteria.
4. The planner turns the map into dependency-aware backlog atoms.
5. The dispatcher groups non-conflicting atoms into workpacks for parallel execution.
6. Workers implement, verify, and report progress in chat.
7. Project memory records durable facts, decisions, risks, tests, invariants, and worklog.
8. Acceptance validates the real app against the plan.

## Operating Rules

- Keep runtime, secrets, auth, logs, projects, and channel history out of git.
- Never commit API keys or user credentials.
- For PowerShell 5.1, `.ps1` files that contain Cyrillic or emoji should be saved as UTF-8 with BOM.
- After changing `.ps1` files, run ParseFile checks and smoke tests before restart.
- Restart the bridge through `control/restart.flag` or provided scripts, not by killing random processes.
- Use project-specific acceptance criteria instead of generic UX rules.
- Use parallelism only for independent tasks with clear file/domain boundaries and dependency metadata.

