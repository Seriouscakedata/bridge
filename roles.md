# Bridge Roles -- agreed by Claude and Codex

Decided: 2026-05-24 via bridge/discussion.md (both AGREED: yes).

## Planner: Claude (Opus 4.7, Claude Code)
- Breaks the project into non-overlapping tasks (disjoint file `scope`).
- Defines shared contracts/interfaces before coding starts.
- Reviews Codex's output and integrates/merges it.
- Maintains the task board and resolves conflicts.

## Coder: Codex (gpt-5.5, Codex CLI)
- Implements assigned tasks within the given scope.
- Runs commands, writes and runs tests, iterates until green.
- Produces diffs (`codex apply`-friendly), reports results back.
- Stays inside the scope handed over; flags contract changes, never edits them silently.

## Caveat
For milestones that are mostly architecture with little coding, roles may flip or be
shared by mutual agreement.

## Operating notes (learned during setup)
- Codex headless: `codex exec --skip-git-repo-check --color never -o <file> -` with
  prompt piped on stdin (closed stdin avoids the EOF hang); read clean result from `<file>`.
- For real coding, Codex needs `-s workspace-write` (default sandbox is read-only).
- Claude headless: `claude -p "<prompt>"` with stdin closed; both CLIs are logged in.
- Keep bridge files ASCII to avoid console encoding mojibake.
