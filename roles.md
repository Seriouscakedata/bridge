# Bridge Roles -- agreed by Claude and Codex

Decided: 2026-05-24 via bridge/discussion.md (both AGREED: yes).

## Planner: Claude (Opus 4.8, Claude Code)
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

This is now realized concretely by **Multi-Model Decision Synthesis** (`task_mode='synthesis'`,
`synthesisMode.enabled=true` in config.json; engine `lib/decision-synthesis.ps1`). For
Deep / High-Stakes decisions the depth router (`lib/decision-depth.ps1`) replaces the single-planner
flow with blind proposals from all three models (A=Codex gpt-5.5, B=Claude opus, C=deepseek), then a
judge selected by task type (`synthesisMode.judgeByTaskType`: architecture->claude, bugfix/refactor/
infra->codex, research/creative->gemini). So for architecture-heavy work the planner/coder split
genuinely dissolves into a peer panel. High-Stakes outcomes are marked `needs_operator` and never
auto-implement.

## Operating notes (learned during setup)
- Codex headless: `codex exec --skip-git-repo-check --color never -o <file> -` with
  prompt piped on stdin (closed stdin avoids the EOF hang); read clean result from `<file>`.
- For real coding, Codex needs `-s workspace-write` (CLI default sandbox is read-only). The bridge's
  live default is `workspace-write` (Gate A, confines writes to the `-C` cwd / project root); fails
  CLOSED on missing config. Operator escape-hatch is `coder.sandboxMode='danger-full-access'` (or
  per-channel `coder.sandboxModeByChannel`) in settings.json — the autonomy loop cannot self-escalate.
- The live coder invocation is `codex exec --color never --skip-git-repo-check -m <model> -c
  model_reasoning_effort="<effort>" -s <sandbox> -C <cwd> -o <file> -` (model/effort/sandbox/cwd are
  resolved per turn; the `-o <file>` + closed-stdin pattern below is unchanged).
- Claude headless: `claude -p "<prompt>"` with stdin closed; both CLIs are logged in.
- Keep bridge files ASCII to avoid console encoding mojibake.
