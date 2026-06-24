# PROJECT_MAP+PLAN: milestone adversarial deep audit

DecisionId: `dec-20260624-163731-1486a6`
Status: plan gate only, no implementation until architect review and user approval.
Scope: bridge control-plane only.

## 1. Project Map

### Current audit path

- `tools/audit.ps1` is the current top-level audit entrypoint.
- Static daily guard is already separate: `Invoke-BridgeAuditStaticAnalysis` calls `audit-security.ps1` and `audit-functional.ps1`, merges findings, and updates the findings ledger.
- The current deep path is `Invoke-BridgeAuditDeepPhase` in `tools/audit.ps1:1233`. It starts `tools/deep-audit.ps1` as a detached PowerShell subprocess, reads an output JSON file/stdout, and marks the phase as `deep_failed` on timeout, non-zero exit, JSON parse failure, empty output, or wrapper exception.
- `Add-DeepAuditFindingsToBacklog` in `tools/audit.ps1:1441` currently files deep Codex/Claude findings directly through `Add-Idea` before adversarial verification. This must be replaced by `confirmed_only` filing from the new SYNTHESIZE phase.

### Current deep implementation

- `tools/deep-audit.ps1` already has a multi-agent-looking layer, but it is not the target architecture:
  - default models include non-approved providers (`deepseek-*`, `gemini-*`);
  - `Invoke-DeepGeminiClaudeFallback` calls raw `Invoke-LLM`;
  - `Invoke-MultiAgentDeepAudit` uses a static `maxParallelAgents` default of `3`;
  - quorum can abort optional agents early;
  - output is FIND-like only, with no adversarial VERIFY phase.
- `tools/deep-audit-agent.ps1` builds capped source inventories and prompts a single specialist role. It is useful as a reference for inventories and schema validation, but the new audit agents must use Claude CLI and Codex CLI only, not raw model calls.

### Current agent/parallel infrastructure

- `driver/40-agent-invoke.ps1` already demonstrates the correct Claude CLI read-only/advisory shape: `claude -p`, `--add-dir`, `--allowedTools Read,Grep,Glob`.
- `tools/deep-audit.ps1` already demonstrates the correct Codex CLI read-only shape: `codex exec -s read-only -C <root>`.
- `lib/parallel.ps1` currently focuses on coder workers in git worktrees plus merge/cleanup. That path is not suitable for read-only audit fan-out because the audit does not need merges and previous instability is coupled to worktree cleanup, pathspec handling, and sandbox/git metadata.
- `config.json` already has `parallel.maxStreams = 20` and many configured workers, but the pool includes disallowed providers. The adversarial audit must filter to `cli in ('claude','codex')`.

### Required new boundary

Add a read-only audit fan-out substrate alongside the existing coder parallel flow:

- no worktree merge;
- no checkout/cleanup of worker edits;
- per-job temp input/output/error/result files;
- explicit root PID per agent;
- provider-aware retry/rebalance;
- PID timeline proving real active agent concurrency;
- pinned snapshot root so all FIND and VERIFY agents inspect the same code.

## 2. Architecture

The new mode is a rare milestone/on-demand audit:

1. Snapshot: create an immutable audit snapshot and run metadata.
2. FIND: spawn all finder units at once through the read-only pool.
3. Grounding gate: reject findings that do not point to a real file:line in the snapshot.
4. VERIFY: spawn all skeptic units for all grounded findings at once through the same pool.
5. SYNTHESIZE: dedup, rank, render report, and file backlog tasks only for confirmed findings.

The cheap nightly static audit remains unchanged and must never launch the adversarial mode.

## 3. Snapshot Model

The audit must not read a moving working tree.

Default policy:

- record `target_root`, `snapshot_sha`, `git_status_short`, and `snapshot_policy`;
- for bridge control-plane milestone runs, require a clean target unless the operator explicitly chooses `include-uncommitted`;
- create a snapshot directory under `audit/runs/<run_id>/snapshot`;
- copy tracked files from `git ls-files` at the chosen SHA, then optionally overlay current working-tree contents for explicitly included uncommitted files;
- pass only the snapshot directory to Claude/Codex CLIs via read-only flags.

This keeps all finders and skeptics on the same file contents and line numbers while avoiding the existing worktree/merge dispatch path.

## 4. FIND Phase

Finder work unit is not just `dimension`; it is `dimension x perspective`.

Default dimensions for code/control-plane targets:

- correctness;
- security;
- concurrency;
- error-handling;
- resources;
- contracts;
- observability;
- state-persistence;
- scheduler-driver-flow;
- audit-backlog-flow.

Default perspectives:

- `codex-medium`;
- `codex-high`;
- `claude-sonnet`;

The default FIND matrix is therefore large enough to exceed the concurrency floor. Operators can override dimensions and perspectives, but a milestone profile is invalid if the computed FIND unit count is below the configured floor while the user requested floor enforcement.

Finder output schema:

```json
{
  "root_cause": "stable concise root cause",
  "file": "relative/path",
  "line": 123,
  "evidence_snippet": "short exact snippet from snapshot",
  "severity": "critical|high|medium|low|info",
  "why": "why this is a real bug",
  "fix_sketch": "specific repair direction",
  "confidence": 0.0,
  "dimension": "security",
  "agent_id": "find-security-codex-high"
}
```

Malformed output is repaired only when a strict JSON object/array can be recovered. Otherwise the job is logged as `invalid_output` and contributes no finding.

## 5. Grounding Gate

Before VERIFY, every finding is checked deterministically against the snapshot:

- `file` must exist under the snapshot root;
- `line` must be in range;
- `evidence_snippet` must match the target line or nearby context after whitespace normalization;
- severity must be normalized to the accepted set.

Ungrounded findings are marked `rejected_grounding` and never filed to backlog.

## 6. VERIFY Phase

VERIFY is adversarial and also uses the floor.

For every grounded finding, spawn skeptic jobs across provider/model/reasoning variants. Default verifier count per finding is configurable; milestone default should be at least enough that the total VERIFY queue normally exceeds the floor.

Skeptic output schema:

```json
{
  "finding_id": "stable id",
  "vote": "refute|support|abstain",
  "file": "relative/path",
  "line": 123,
  "evidence": "current snapshot evidence for the vote",
  "reason": "why the finding is refuted or still holds"
}
```

Decision rule:

- default state is `unconfirmed`;
- if deterministic grounding failed, final state is `rejected_grounding`;
- after VERIFY, require `valid_votes >= min_valid_votes`;
- if `refute_votes >= ceil(valid_votes / 2)`, final state is `refuted`;
- otherwise require at least one `support` vote with a valid file:line citation, then final state is `confirmed`;
- if quorum is degraded or support is absent, final state is `unverified`.

Only `confirmed` findings reach backlog filing. `refuted`, `unverified`, and `rejected_grounding` findings remain in the report for audit transparency.

## 7. Concurrency Model

The hard floor is width, not total budget.

Config knobs:

- `audit.adversarial.concurrencyFloor = 20`;
- `audit.adversarial.maxActiveAgents >= 20`;
- `audit.adversarial.providerBalance = { codex = 0.5, claude = 0.5 }`;
- `audit.adversarial.totalAgentCap`;
- `audit.adversarial.finderPerspectives`;
- `audit.adversarial.verifiersPerFinding`.

Pool behavior:

- maintain `active_agent_count >= concurrencyFloor` whenever at least that many jobs are launchable;
- launch jobs through a refill queue, not sequential batches;
- backoff/rate-limited jobs return to pending and do not count as active;
- immediately refill open slots from the same provider or the other provider;
- if all providers are capacity-blocked and the floor cannot be sustained while enough work remains, mark the run `failed_capacity_floor` instead of silently lowering concurrency;
- budget exhaustion stops launching new work and lets active jobs drain, but a valid milestone profile must have enough total-agent budget to satisfy the configured floor at phase start.

FIND and VERIFY each record their own `peak_concurrency`, `floor_met`, and `floor_failure_reason`.

## 8. Rate Limit and OOM Strategy

Provider errors are classified from CLI exit code plus stderr/stdout text:

- rate/usage limit: retry with exponential backoff and provider rebalance;
- auth failure: fail that provider family for the run and surface operator action;
- local OOM/process creation failure: stop launching new jobs, preserve artifacts, and fail the run with `capacity_failure`;
- timeout/empty/malformed output: fail only that agent, optionally retry within per-job retry budget.

The retry strategy must never convert a floor requirement into a lower cap. It either refills with other jobs/providers or reports the floor failure explicitly.

## 9. CLI-Only Provider Policy

Allowed audit agent invocations:

- Codex CLI: `codex exec --color never -s read-only -C <snapshot> -o <result> -`;
- Claude CLI: `claude -p --add-dir <snapshot> --allowedTools Read,Grep,Glob --model <model>`.

Disallowed:

- Gemini;
- DeepSeek;
- raw `Invoke-LLM`;
- raw OpenAI/Anthropic API calls;
- write-enabled agent modes.

The audit worker registry may reuse `parallel.workers` metadata but must filter to Claude/Codex entries and reject any configured disallowed provider in adversarial mode.

## 10. Parallelism Proof

Each launched job has a stable `agent_id`, root PID, provider, role, dimension/finding id, and start/end timestamps.

The sampler counts only root agent PIDs registered by the audit harness, not arbitrary child processes. Child PIDs are stored for diagnostics but do not inflate concurrency.

Report fields:

```json
{
  "phase": "find",
  "peak_concurrency": 24,
  "floor": 20,
  "floor_met": true,
  "timeline": [
    {"ts": "2026-06-24T00:00:00Z", "active_root_agents": 24}
  ]
}
```

Tests must use dummy CLI jobs with sleeps long enough that PID sampling can prove a real simultaneous peak.

## 11. SYNTHESIZE and Backlog Filing

SYNTHESIZE input is only grounded and verified data.

Steps:

- normalize/dedup by structural key: `file + normalized evidence snippet hash + category`, not LLM prose alone;
- rank by severity and confidence;
- render JSON and Markdown reports under `audit/runs/<run_id>/`;
- file only `confirmed` findings to backlog;
- use idempotency metadata so reruns do not duplicate tasks;
- for bridge control-plane findings, include `bridge_self_admission` requirements in generated fix atoms when the touch set hits protected files.

The old direct filing in `Add-DeepAuditFindingsToBacklog` must be disabled or routed through `confirmed_only` data from SYNTHESIZE.

## 12. Modes and Triggers

Mode split:

- `static_daily`: current cheap guard, unchanged;
- `adversarial_milestone`: explicit operator/milestone mode only.

Allowed triggers:

- operator command;
- pre-training milestone;
- post-major-pipeline-change milestone.

Forbidden trigger:

- nightly static cron must not call adversarial mode.

The implementation should prefer an explicit new command/switch such as `tools/audit.ps1 -AdversarialDeep` or a separate `tools/adversarial-audit.ps1`, then wire UI/server/operator command only after the core harness tests pass.

## 13. Implementation Plan After Approval

### Phase 1: read-only parallel substrate

Touch set:

- `lib/parallel.ps1`;
- `tools/test-readonly-parallel.ps1`;
- optionally `config.json`.

Build:

- add read-only subprocess pool functions separate from worktree/merge functions;
- add per-job artifacts, timeout tree kill, root PID registry, timeline sampler;
- add dummy-job stress test with at least floor-sized workload.

Acceptance:

- dummy run with more jobs than the floor proves `peak_concurrency >= floor`;
- one dummy timeout/crash/malformed result does not abort the phase;
- no worktree merge/checkout cleanup path is used.

### Phase 2: snapshot and provider layer

Touch set:

- `tools/audit-snapshot.ps1`;
- `tools/adversarial-audit.ps1`;
- `tools/test-audit-snapshot.ps1`;
- `tools/test-adversarial-provider.ps1`.

Build:

- create immutable snapshot root and metadata;
- implement Claude/Codex CLI job builders;
- reject disallowed providers;
- classify rate-limit/auth/OOM/timeout/malformed failures.

Acceptance:

- snapshot metadata pins SHA/status and all agents read the same snapshot root;
- invocation trace contains only Claude/Codex CLI;
- simulated provider limit triggers retry/rebalance without lowering the configured floor.

### Phase 3: FIND and schema gate

Touch set:

- `tools/adversarial-audit.ps1`;
- `tools/test-adversarial-find.ps1`;
- `config.json`.

Build:

- implement dimension x perspective matrix;
- enforce finder JSON schema;
- implement deterministic grounding gate.

Acceptance:

- custom dimensions override defaults;
- default milestone profile produces enough FIND jobs to satisfy the floor;
- ungrounded/malformed findings are rejected and logged.

### Phase 4: VERIFY

Touch set:

- `tools/adversarial-audit.ps1`;
- `tools/test-adversarial-verify.ps1`.

Build:

- spawn all skeptics for all grounded findings through the same pool;
- implement the crisp vote rule from this plan;
- record quorum health per finding.

Acceptance:

- majority refute discards;
- no valid quorum means `unverified`, not backlog;
- confirmed requires grounding plus at least one support citation.

### Phase 5: SYNTHESIZE and backlog

Touch set:

- `tools/adversarial-audit.ps1`;
- `tools/audit.ps1`;
- `tools/test-adversarial-synthesize.ps1`.

Build:

- render JSON/Markdown reports with concurrency telemetry;
- dedup by structural key;
- file only confirmed findings;
- replace old direct `Add-Idea` filing path for deep findings.

Acceptance:

- rerun does not create duplicate backlog tasks;
- unverified/refuted findings stay report-only;
- old Codex/Claude direct filing no longer bypasses VERIFY.

### Phase 6: mode wiring and retirement of old deep path

Touch set:

- `tools/audit.ps1`;
- `tools/deep-audit.ps1` or wrapper replacement;
- `server.ps1` only if operator UI/API command is approved;
- `config.json`;
- smoke/self-test files as needed.

Build:

- keep nightly static unchanged;
- expose adversarial mode only through approved command/milestone hook;
- remove Gemini/DeepSeek/raw `Invoke-LLM` from the adversarial path;
- retire or wrap the old `deep_failed` path.

Acceptance:

- nightly audit cannot start adversarial mode;
- adversarial run has observable FIND, VERIFY, SYNTHESIZE phase boundaries;
- old `deep_failed` failure surface is replaced by structured per-agent/phase statuses.

### Phase 7: end-to-end validation

Touch set:

- tests and docs only unless bugs are found.

Build:

- run a synthetic end-to-end audit with dummy providers;
- run a controlled real-code dry run if operator approves cost;
- verify report, telemetry, backlog idempotency, and trigger separation.

Acceptance:

- `Parser.ParseFile` passes for all touched `.ps1`;
- targeted tests pass;
- `driver.ps1 -SelfTest`, `tools/self_model_smoke.ps1`, and `smoke.ps1` pass for control-plane changes;
- canary/restart stamp rules are followed for any PS1 engine diff.

## 14. Open Questions For Approval

- Exact default milestone budget: total-agent cap and verifier count per finding.
- Whether `include-uncommitted` snapshot mode should ever be allowed for bridge control-plane audits.
- Exact operator command surface: separate script, server endpoint, UI button, or all three.
- Retention policy for `audit/runs/<run_id>` artifacts.
- Whether high-severity but budget-unverified findings should create held planning atoms or remain report-only. This plan defaults to report-only to preserve VERIFY-before-backlog.

## 15. Stop Condition

This document is the Phase 0 deliverable. Implementation must stop here until architect review and explicit user approval.
