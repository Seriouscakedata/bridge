# Operator Guide

MOS Bridge is controlled from the local web UI:

```text
http://localhost:8787/
```

The operator's job is to give goals, watch progress, approve sensitive actions, and decide whether delivered work is good enough.

## Mental Model

- `main` is the MOS Bridge product itself.
- Every external software project should be a separate channel.
- A channel has its own chat, backlog, state, project binding, and project memory.
- The bridge can discuss, plan, split work, dispatch workers, run checks, and report results.
- Runtime state is local. Git contains the product, not the operator's private history.

## Daily Commands

Start:

```powershell
py .\bridgectl.py start
```

Stop:

```powershell
py .\bridgectl.py stop
```

Status:

```powershell
py .\bridgectl.py status
```

Self-test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\driver.ps1 -SelfTest
```

Smoke test while running:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\smoke.ps1
```

## Using The UI

Use chat for normal work. Good requests are concrete:

- "Create a new project for ..."
- "Study this repo and build a project map."
- "Implement the accepted backlog until the project is complete."
- "Run acceptance and tell me what failed."
- "Audit the bridge for reliability issues."

Ask for status when needed:

- "What is currently running?"
- "What worker is active?"
- "What is blocked?"
- "How many backlog tasks remain?"
- "What changed since the last report?"

## Creating A New Project

The intended flow:

1. Give MOS the project idea.
2. Let it discuss and clarify.
3. Require a deep project plan before implementation.
4. Let it generate a dependency-aware backlog.
5. Let it group compatible work into parallel workpacks.
6. Let workers implement and verify.
7. Run final acceptance against the project plan.

Do not run large projects in `main`. `main` should be used for the bridge itself.

## Good Project Request Template

```text
Create a new project:

Goal:
...

Users:
...

Must-have features:
...

Data/storage:
...

Auth/roles:
...

Design direction:
...

Acceptance:
The app is not complete until MOS has tested registration/login/navigation,
main user flows, admin flows, build, and project-specific UX criteria.
```

## Parallel Work

Parallelism should happen after planning, not before. MOS should first know:

- Files or domains each task touches.
- Dependencies between tasks.
- Which tasks can run independently.
- Verification required for each task.

Parallel work is useful for:

- Independent UI screens.
- Separate API routes.
- Tests/docs/tooling that do not touch the same files.
- Backlog atoms with clear dependencies.

Parallel work is risky for:

- Shared auth/session code.
- Global schema migrations.
- App-wide styling or routing.
- Large refactors without a strong plan.

Each parallel stream should declare its expected touch-set. During collection MOS now refuses to merge a stream that changed files outside that declared area. The operator will see a quarantine message in chat; that stream needs re-dispatch or manual review instead of being silently merged.

## Memory

MOS has bridge memory and project memory.

Bridge memory stores durable facts about MOS itself: architecture, rules, safety lessons, and operating procedures.

Project memory stores durable facts about one project: decisions, risks, tests, invariants, open questions, and worklog.

Memory is durable-first. If the embedding API key is missing or the provider is unavailable, MOS still stores the record with `embedding_status=pending`. It will not be as searchable semantically until embeddings are available, but the fact is not lost.

Useful operator instruction:

```text
Remember this as project memory: ...
```

or:

```text
Record this as a project decision: ...
```

## Approvals And Safety

The operator should approve or reject actions that involve:

- Deleting data.
- Force-pushing or rewriting public repository history.
- Credentials, billing, tokens, or external account changes.
- Security-sensitive changes.
- Running unknown downloaded code.
- Modifying watchdog/supervisor/autostart behavior.

For normal implementation inside a project channel, MOS should be able to continue autonomously once the plan and backlog are accepted.

## Operator Modes

`autopilot` is the default long-running mode. MOS may claim approved backlog after quiet time and keep moving.

```powershell
py .\bridgectl.py mode set autopilot
```

`copilot` is the supervised mode. MOS still responds to direct chat messages, but it does not autonomously claim backlog.

```powershell
py .\bridgectl.py mode set copilot
```

Use `copilot` when an experienced developer wants frequent review points or when the project direction is uncertain.

## Quality Bar

Do not accept "diff looks correct" as final proof.

A finished web project should normally include:

- Build passes.
- Auth flows tested if auth exists.
- Main navigation tested.
- Main user flows tested.
- Admin flows tested if admin exists.
- Data persistence tested.
- Visual/UX acceptance checked against the project plan.
- Known limitations reported clearly.

## Troubleshooting

If the UI does not open:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\driver.ps1 -SelfTest
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1
```

If the port is busy:

```powershell
Get-NetTCPConnection -State Listen -LocalPort 8787 -ErrorAction SilentlyContinue
```

If MOS looks stuck, ask in chat:

```text
Report current state: active task, active worker, channel, backlog count, last error, and what should happen next.
```

If a project is poor quality, do not manually patch everything. Ask MOS to run acceptance against the project plan and generate follow-up backlog items.

## Git Hygiene

Commit product code, docs, and clean seed memory.

Do not commit:

- Runtime channel files.
- Local projects.
- Worktrees.
- Uploads/screenshots.
- Secrets/auth.
- Local databases.
