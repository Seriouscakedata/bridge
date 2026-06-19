# Audit Efficiency Review: PROJECT_MAP + PLAN

Date: 2026-06-19
Mode: DISCUSS / design only
Scope: bridge self-audit, no runtime implementation in this pass

## Executive Correction

The initial Decision Synthesis direction is useful only after factual correction. The bridge already has a findings ledger, stable finding ids, root-cause grouping, a regressed lifecycle, usefulness scoring, launch admission, duplicate compaction, and an intake gate with code-evidence checks. Therefore the improvement plan must extend and harden these existing mechanisms, not create parallel ones.

The most current efficiency loss is not "there is no measurement". It is that the existing measurement loop is incomplete and currently stale: the latest main audit report is `audit/2026-06-05.json`, `audit/audit.last` is 2026-06-06, and the launch ledger shows repeated denials on 2026-06-10 with no later completed report. The fix-through rate cannot improve while the audit run itself is not completing and while finding outcomes are not joined back to backlog completion.

## PROJECT_MAP

### 1. Runtime Sensor Auditor

Files:
- `lib/auditor.ps1`
- `lib/doctor.ps1`

Responsibilities:
- Builds a live snapshot of channels, state, git status, heartbeat, agent pid, progress fingerprint, task age, last sequence movement, QA cache, and supervisor restarts.
- Emits operational triggers: `wait_state_stuck`, `empty_reply_streak`, `same_task_too_long`, `critic_pingpong`, `commit_famine`, `working_tree_drift`, `restart_frequency`, `doctor_recidivism`.
- Dispatches remediation through the existing Doctor path.

Current strengths:
- `commit_famine` is already progress-aware: live agent, paused channel, and fresh non-spinning progress are exemptions.
- Runtime sensor catches failures the static audit will never see.

Current gaps:
- Sensor incidents are not consistently promoted into the durable findings lifecycle as auditable findings with later fix outcomes.
- `commit_famine` and Doctor outcomes are operationally visible, but not measured as audit-sourced "found -> fixed / dropped / stale" outcomes.

### 2. Nightly Audit Scheduler

Files:
- `driver/10-maintenance.ps1`
- `tools/audit-runner.ps1`
- `tools/audit.ps1`

Responsibilities:
- Runs the daily audit in the configured window.
- Uses `audit.last`, `audit.waiting`, launch admission lock, and `audit.launches.jsonl`.
- Starts detached `tools/audit-runner.ps1`, waits for idle, then calls `Invoke-BridgeAudit`.

Current strengths:
- The old sliding `floorHours` skip was fixed by anchoring to the current window occurrence.
- Launch admission prevents storms via `maxLaunchAttemptsPerWindow` and `audit.launch.lock`.

Current gaps:
- `audit.launches.jsonl` records `started` and `denied`, but not runner terminal states like `completed_ok`, `completed_partial`, `skipped_not_idle`, `failed`, or `runner_timeout`.
- A run can start and then vanish without a durable terminal ledger entry.
- Latest observed data shows launch admission denying repeatedly after the last started attempts, while no completed report appears after 2026-06-05. This is now a primary efficiency blocker.

### 3. Static Audit

Files:
- `tools/audit.ps1`
- `tools/audit-security.ps1`
- `tools/audit-functional.ps1`
- `tools/audit-signals.ps1`

Responsibilities:
- Runs security and functional subcomponents.
- Collects telemetry signals before LLM phases.
- Normalizes findings, merges duplicates, writes JSON/Markdown reports, updates ledger, files criticals to backlog, writes usefulness.

Current strengths:
- Static security/functional findings are fast and survive deep failures.
- `audit-signals.ps1` already provides incident/speed/cost slices.

Current gaps:
- Coverage is mostly PowerShell/source oriented; scheduled tasks, external runtime assets, DNS/configured endpoints, and bridge control-plane deployment assumptions are weakly represented.
- Static findings are often syntactic. They need better evidence classification so noisy categories are demoted or batched rather than repeatedly entering the queue.

### 4. Deep Audit

Files:
- `tools/audit.ps1`
- `tools/deep-audit.ps1`
- `tools/deep-audit-agent.ps1`

Responsibilities:
- `audit.ps1` launches `deep-audit.ps1` through `Start-Process`, waits with `WaitForExit(timeout)`, kills on timeout, reads explicit JSON output, and records `deep_failed` / `deep_partial` / `ok`.
- `deep-audit.ps1` fans out model agents and returns `agents`, `coverage_gap`, and `required_slices`.
- `deep-audit-agent.ps1` builds role-specific prompt context and calls `Invoke-LLM`.

Current strengths:
- The old `deep_failed agents=0` variable-collision root cause is documented and fixed in `deep-audit.ps1`.
- Required-slice accounting and `deep_partial` exist.
- Agent subprocesses have per-agent timeouts.

Current gaps:
- The current last report shows `deep_failed` with `deep_model_agent_count=0`, `deep_agent_error_count=6`, and required slices failing with `empty_llm_reply`.
- `prompt_truncated` is always false even though context sections are capped; coverage loss due to truncation is therefore underreported.
- Process termination uses `.Kill()` on the direct process; process-tree cleanup is not consistently explicit for deep-agent children.
- Partial agent evidence is preserved structurally, but empty replies from required slices still produce low diagnostic value for repair.

### 5. Findings Ledger and Usefulness

Files:
- `tools/audit.ps1`
- `audit/findings-ledger.jsonl`
- `audit/usefulness.jsonl`

Responsibilities:
- Stable id: `New-FindingId`.
- Root-cause grouping: `New-RootCauseKey`.
- Ledger state machine: `new`, `open`, `fixed`, `suppressed`, `regressed`.
- Usefulness fields include `action_rate`, `resolved_signal_delta`, `incident_capture_rate`, `suppressed_known`, `ledger_open_prev`, and `ledger_open_now`.

Current strengths:
- The core ledger already exists and suppresses known open non-critical findings.
- Reappearance after `fixed`/`suppressed` already becomes `regressed`.

Current gaps:
- The ledger is not yet reliably joined to backlog item ids and final QA/commit evidence.
- `fixed` is not clearly gated by targeted revalidation of the original finding.
- Staleness is implicit via absence from later reports, but there is no deterministic "not re-observed in N relevant audits -> fixed_or_stale / needs triage" transition.
- `resolved_signal_delta` can move, but it is not enough to calculate true fix-through rate by source slice and root cause.

### 6. Findings -> Backlog Intake

Files:
- `tools/audit.ps1`
- `lib/backlog-workpack.ps1`
- `lib/backlog.ps1`

Responsibilities:
- Static critical findings are filed to backlog.
- Deep findings are filed to backlog.
- Intake gate dedupes against open audit findings, verifies cited files and readable code evidence, holds weak security findings, drops some comment-only false positives, and wraps cross-file audit findings with a causal-map requirement.

Current strengths:
- There is already file-existence verification, cited-line reading, security-evidence checking, fail-closed behavior, duplicate compaction, and cross-file causal-map gating.

Current gaps:
- Gate decisions are not measured against later outcomes: approved/fixed, held/real, dropped/regressed, dedup/correct.
- Similarity calibration from operator decisions is not explicit.
- Gate evidence is not fed back into the findings ledger as part of the finding lifecycle.

## Updated Diagnosis: Where Efficiency Is Lost

1. Run completion loss: audits can start but fail to produce a terminal report or completion ledger entry. This makes all downstream metrics stale.
2. Deep signal loss: the old `agents=0` root cause is fixed, but current `empty_llm_reply` and underreported prompt truncation still turn required deep slices into low-value failures.
3. Outcome join loss: findings and backlog items are not joined strongly enough to know which root causes were fixed, rejected, stale, or regressed.
4. Gate feedback loss: intake gate has useful evidence checks, but its precision/recall is not trained against actual operator/backlog outcomes.
5. Staleness loss: known findings persist as open/new without a deterministic relevant-audit absence policy.
6. Coverage loss: static/deep coverage is source-heavy and misses some runtime/control-plane assets and deployment assumptions.
7. Fix batching loss: root-cause grouping exists in the ledger, but work execution still risks fixing duplicates one by one instead of resolving a causal cluster.

## PLAN

### Chapter 1: Restore Run Truth Before Adding Signal

Goal: every audit attempt has a terminal state, and stale launch-denial loops become visible and recoverable.

Atom 1.1: Extend existing launch ledger with terminal runner states.
- Files: `driver/10-maintenance.ps1`, `tools/audit-runner.ps1`, `tools/test-audit-launch-guard.ps1`
- Change: keep `audit.launches.jsonl`, but add entries for `completed_ok`, `completed_partial`, `skipped_not_idle`, `failed`, and `runner_timeout`; include pid, channel, report path when available, runtime, and exit reason.
- Acceptance: a synthetic runner success writes `started` then `completed_ok`; a skipped idle wait writes `skipped_not_idle`; a thrown audit writes `failed`.
- Checks: Parser.ParseFile for touched PS1, targeted launch-guard test, `driver.ps1 -SelfTest`, `smoke.ps1`.
- Risk: medium; touches scheduler/control-plane-adjacent code.

Atom 1.2: Add stale-start reconciliation to launch admission.
- Files: `driver/10-maintenance.ps1`, `tools/test-audit-launch-guard.ps1`
- Change: before denying on `max_attempts_per_window`, discount or mark `started` attempts whose pid is dead and which have no terminal entry after TTL.
- Acceptance: fixture with dead started attempts no longer blocks the next audit forever; live started attempts still block storms.
- Checks: targeted launch tests plus smoke.
- Risk: high; must avoid launch storms.

Atom 1.3: Audit freshness alert.
- Files: `lib/auditor.ps1`, optionally existing auditor tests
- Change: emit an auditor trigger when `audit.last` is older than configured threshold and launch ledger recently denies/starts without completion.
- Acceptance: synthetic stale audit dir produces one actionable trigger with last report age and launch-denial counts.
- Checks: Parser.ParseFile, targeted auditor test, smoke.
- Risk: medium; avoid noisy alerts.

### Chapter 2: Make Deep Failures Actionable, Not Silent

Goal: deep audit failures identify whether the issue is timeout, process-tree leak, empty LLM reply, prompt truncation, missing output, or parse error.

Atom 2.1: Correct deep-agent truncation telemetry.
- Files: `tools/deep-audit-agent.ps1`, `tools/deep-audit.ps1`, relevant deep-audit tests
- Change: propagate per-section truncation and total prompt caps into `prompt_truncated`, `coverage`, and `coverage_gap`.
- Acceptance: a synthetic oversized context sets `prompt_truncated=true` and names truncated sections; normal context stays false.
- Checks: ParseFile, deep-audit no-LLM smoke, smoke.
- Risk: medium.

Atom 2.2: Preserve and summarize required-slice failure reasons.
- Files: `tools/deep-audit.ps1`, `tools/audit.ps1`, tests around `Get-BridgeAuditDeepTruth`
- Change: keep existing `deep_failed/deep_partial`, but add per-required-role reason buckets to report metadata and markdown.
- Acceptance: report metadata distinguishes `empty_llm_reply`, `timeout`, `missing_output_file`, `json_parse_failed`, and `aborted_by_quorum`.
- Checks: existing audit backlog-filing tests plus synthetic deep truth test.
- Risk: low-medium.

Atom 2.3: Process-tree hard kill for deep subprocesses.
- Files: reuse existing process supervision helpers if available; otherwise minimally extend `tools/deep-audit.ps1`
- Change: replace direct `.Kill()` fallback with scoped process-tree termination for deep-agent subprocesses, preserving stdout/stderr/result files.
- Acceptance: forced timeout leaves no child PowerShell/Codex/Claude process for that agent and still records a timeout result.
- Checks: Parser.ParseFile, synthetic timeout test, smoke.
- Risk: high on Windows process ownership; keep scoped by root pid.

### Chapter 3: Close Finding -> Backlog -> Fix Loop

Goal: measure real fix-through rate, not just findings and filed tasks.

Atom 3.1: Extend existing ledger entries with backlog linkage.
- Files: `tools/audit.ps1`, tests for findings ledger / audit backlog filing
- Change: when audit files a backlog item, append/update `backlog_ids`, `last_backlog_status`, and `last_backlog_decision` on the existing root-cause ledger entry.
- Acceptance: filed critical finding has the backlog id attached to its rootCauseKey; repeated same root cause appends no duplicate id.
- Checks: `tools/test-findings-ledger.ps1`, audit backlog-filing test, smoke.
- Risk: medium.

Atom 3.2: Outcome reconciliation from backlog to ledger.
- Files: `tools/audit.ps1` or existing backlog workpack path; tests
- Change: on each audit/usefulness pass, read linked backlog items and set outcome fields: `fix_status=open|fixed|held|dropped|stale|regressed`, `fixed_commit`, `qa_head`, `resolved_at`.
- Acceptance: synthetic done+QA backlog item marks linked ledger entry fixed; rejected/held items do not count as fixed.
- Checks: ledger test with synthetic backlog, smoke.
- Risk: medium.

Atom 3.3: Targeted revalidation before fixed.
- Files: `tools/audit.ps1`, static subcomponent wrappers, tests
- Change: reuse existing static/deep checks to re-check the original root-cause evidence before moving to fixed; if evidence still appears, keep/regress.
- Acceptance: done backlog item with still-present evidence remains open/regressed; absent evidence plus QA pass marks fixed.
- Checks: synthetic fixture with disappearing and still-present findings.
- Risk: medium-high due to false stale if coverage changes.

### Chapter 4: Calibrate Intake Quality With Outcomes

Goal: improve precision/recall without replacing the intake gate.

Atom 4.1: Persist intake gate decision telemetry.
- Files: `lib/backlog-workpack.ps1`, `lib/backlog.ps1`, tests
- Change: when gate returns allow/hold/drop/dedup, attach deterministic `intake_gate` metadata to the backlog record or companion audit trace: action, reason, evidence summary, duplicate key, causal-map missing fields.
- Acceptance: every audit-sourced approved/held/dropped item has inspectable gate metadata.
- Checks: targeted intake-gate tests.
- Risk: low-medium.

Atom 4.2: Outcome-based gate report.
- Files: existing usefulness writer / audit report path
- Change: extend `usefulness.jsonl` with gate outcome metrics by source slice: approved_fixed, approved_unfixed, held_later_fixed, dropped_regressed, dedup_correct.
- Acceptance: synthetic backlog/ledger fixture produces non-zero per-gate outcome counters.
- Checks: usefulness test.
- Risk: low.

Atom 4.3: Threshold and rule calibration from operator outcomes.
- Files: `lib/backlog-workpack.ps1`, config if needed, tests
- Change: adjust existing duplicate/security/causal-map thresholds using historical operator states, but only after telemetry exists.
- Acceptance: no threshold changes happen without a report showing baseline and expected effect.
- Checks: calibration dry-run test.
- Risk: medium; avoid auto-dropping high-severity real issues.

### Chapter 5: Staleness and Coverage

Goal: prevent stale findings from consuming work and close high-value blind spots.

Atom 5.1: Relevant-audit absence policy.
- Files: `tools/audit.ps1`, tests for findings ledger
- Change: add deterministic staleness transition using existing ledger: if a finding is absent for N relevant completed audits of the same slice/profile, move to `fixed_or_stale` or `stale_needs_review`; if it reappears, use existing `regressed`.
- Acceptance: synthetic ledger with absent finding across N reports changes state; irrelevant skipped/deep_failed slices do not count toward absence.
- Checks: findings-ledger test.
- Risk: medium; N requires operator choice.

Atom 5.2: Runtime incidents become findings.
- Files: `tools/audit-signals.ps1`, `tools/audit.ps1`, tests
- Change: promote selected incidents already collected by signals into normalized findings with source `runtime`, rootCauseKey, and backlog filing path.
- Acceptance: synthetic auditor/Doctor incident appears in report and ledger exactly once.
- Checks: audit-signals fixture test.
- Risk: medium.

Atom 5.3: Coverage gap inventory.
- Files: `tools/deep-audit-agent.ps1`, `tools/audit-functional.ps1`, `tools/audit-security.ps1`
- Change: report coverage inventory: scanned file counts, skipped large files, truncated sections, unscanned asset classes. Do not expand scans until gaps are measurable.
- Acceptance: audit metadata lists skipped/truncated classes; large core files are named when truncated.
- Checks: no-LLM audit smoke.
- Risk: low.

## Operator Review Questions

1. Staleness threshold: how many relevant completed audits without re-observation before `fixed_or_stale`?
2. Severity floor: should critical/security findings ever auto-stale, or always require targeted revalidation/operator review?
3. Launch reconciliation TTL: after how long can a `started` audit without terminal entry be marked abandoned?
4. Gate calibration: should `drop` ever be automatic for security findings, or should weak security findings stay `held` by default?
5. Deep timeout policy: should required slices have longer timeout than optional slices?

## Recommended Review Order

1. Approve Chapter 1 first. Without terminal run truth, all other metrics are stale.
2. Approve Chapter 2 next. It turns deep failures from "0 value" into repairable diagnostics.
3. Approve Chapter 3 once run truth is reliable. This creates the real fix-through metric.
4. Approve Chapters 4-5 after baseline metrics exist.

## Non-Goals

- Do not create a second findings ledger.
- Do not replace `Invoke-BacklogIntakeGate`.
- Do not bypass existing backlog/governor safety.
- Do not widen audit scans blindly before coverage gaps are measured.
- Do not implement any of this in the DISCUSS pass.

