# Refined Self-Improvement Atom Plan

DecisionId: `dec-20260620-071425-784f10`

Status: plan-only, ready for operator review. No runtime code is changed by this artifact.

## Foundation

Foundation #2 holds: reuse existing mechanisms, harden them, and do not introduce new layers, validators, frameworks, or parallel data models.

## Depth-Router Promise Removed

The original Direction-2 speed claim is narrowed.

Standard tasks: no speed promise. The depth router is a Decision Synthesis depth classifier, not a direct controller for `planner_ms` or `verify_ms` on Standard plan-only tasks.

Synthesis-routed DISCUSS tasks: possible speed lever, but only through better route precision and lower synthesis turn-depth. It must be measured before promising a reduction.

Verify phase: no new narrowing atom is accepted yet. `Get-GateRegressionScope` and changed-path calls already exist, so the old `ATOM_017` premise is rejected until `metrics-latency-analysis.md` proves a real residual bottleneck.

Observed current metrics baseline from `metrics.jsonl*`: task-latency rows `145`; `planner_ms n=145 median=276267 p90=1575403 max=8374834`; `verify_ms n=145 median=127 p90=469068 max=1947987`.

## A15 Collision Resolved

A15 is resolved by reuse, not by a new representation.

The accepted representation is the existing duplicate compactor model:

- one representative remains open or approved
- duplicates become `status='rejected'`
- duplicates carry `duplicate_of`, `duplicate_key`, and `resolved_reason='duplicate-of-root-cause'`

No persisted `duplicate_count`, `first_seen`, or `last_seen` fields are added. `Invoke-BacklogDuplicateCompactor` may continue returning `duplicate_count` in its transient summary output; that is not a backlog record schema change.

## A10/A11 Decomposition

Old A10 is decomposed into four atoms:

- `ATOM_007`: stale-start contract tests in `tools/test-audit-launch-guard.ps1`
- `ATOM_008`: stale dead-pid terminalization as `abandoned` in `driver/10-maintenance.ps1`
- `ATOM_014`: `window_incomplete` emission in `driver/10-maintenance.ps1`
- `ATOM_016`: `window_incomplete` reconciliation in `driver/10-maintenance.ps1`

Old A11 is decomposed into two atoms:

- `ATOM_009a`: terminal-aware stale alert tests in `tools/test-auditor-stale-alert.ps1`
- `ATOM_009b`: terminal-aware `Get-StaleAuditLaunchInfo` logic in `lib/auditor.ps1`

Each atom has one concrete file path, one change, and one dedicated test command/assertion in `refined-atom-list.json`.

## Operator Review Gate

After review, implementation should proceed one atom at a time.

Safest first after plan artifacts: `ATOM_003`, `ATOM_005`, `ATOM_007`, `ATOM_009a`.

Behavior changes follow their tests:

- `ATOM_004` after `ATOM_003`
- `ATOM_006` after `ATOM_005`
- `ATOM_008`, `ATOM_014`, `ATOM_016` after `ATOM_007`, in that order
- `ATOM_009b` after `ATOM_009a` and `ATOM_016`

Do not implement any verify_ms narrowing atom until `ATOM_010b` proves a residual bottleneck. The old `ATOM_017` is rejected for now because changed-path gate-regression scope already exists.

## Artifacts

- Machine-readable atom list: `channels/main/decisions/dec-20260620-071425-784f10/refined-atom-list.json`
- Human plan: `channels/main/decisions/dec-20260620-071425-784f10/self-improvement-atom-plan.md`

