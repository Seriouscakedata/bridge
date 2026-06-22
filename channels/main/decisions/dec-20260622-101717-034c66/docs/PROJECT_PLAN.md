# PROJECT_PLAN: LAPA Planner Layer

## Current Gate

Status: `DRAFT_FOR_OPERATOR_REVIEW`.

No executable atoms, code implementation, or runtime action generation is authorized by this plan. The next required step is operator review of this document and `CONTRACT.json`.

## Phase 0: Design Approval

Deliverables:

- `PROJECT_BRIEF.md`
- `DISCUSS_A_architecture_and_discuss_first.md`
- `DISCUSS_B_taskgraph_jit_execution.md`
- `DISCUSS_C_verification_recovery_stop.md`
- `DISCUSS_D_vision_in_planning.md`
- `DISCUSS_E_risk_security_rollout.md`
- `PROJECT_MAP.md`
- `PROJECT_PLAN.md`
- `CONTRACT.json`

Acceptance:

- The document sequence exists.
- It covers all accepted decisions `atom_01` through `atom_12`.
- It addresses red-team issues: missing docs, implementation-test conflict, scope-fence enforcement, non-idempotent retries, TOCTOU, and vision false positives.
- Operator approval is pending, not assumed.

## Phase 1: Contracts and Schemas

Post-approval only.

Build:

- `TaskContract` schema.
- high-level `TaskGraph` schema.
- node postcondition schema.
- recovery ladder schema.
- typed action vocabulary contract.
- audit event schema.

Tests:

- Reject TaskGraph nodes without postconditions.
- Reject atomic-action lists embedded in approved high-level graph.
- Reject trivially true or unobservable postconditions.
- Reject actions not in typed declared capability vocabulary.

## Phase 2: Planner and JIT Compiler Boundary

Post-approval only.

Build:

- advisory-only planner adapter.
- high-level DAG decomposition.
- one-node-at-a-time JIT step compiler.
- material-divergence detector that is not self-certified by the planner.

Tests:

- Planner has no direct OS/UI/Telegram/shell actuation imports or calls.
- Runtime pauses for operator approval before atomic generation.
- JIT compiler generates actions only for one approved node.
- Material scope/risk changes route to operator review or STOP.

## Phase 3: Risk, Scope, and Security

Post-approval only.

Build:

- deterministic allow/confirm/deny policy.
- action-level and sequence-level risk checks.
- app/target allowlist.
- screen-content quarantine.
- confirmation gate for sends/settings/destructive/unknown effects.

Tests:

- LLM risk mislabel cannot bypass policy.
- Unknown action class defaults to confirm.
- Emergent sequence-level high-risk path is blocked.
- Screen prompt-injection text is ignored as instruction.

## Phase 4: Perception, Vision, Verification

Post-approval only.

Build:

- cheap-perception-first escalation.
- vision context scan before decomposition when needed.
- obstacle/anomaly detection.
- postcondition verification with cross-checks.
- final goal-level verifier.

Tests:

- Canvas/ambiguous UI escalates to vision.
- Failed or conflicting verification fails closed.
- Confident but cross-check-inconsistent vision cannot advance high-risk nodes.
- Final goal-level verification can fail even when node checks pass.

## Phase 5: Recovery and STOP

Post-approval only.

Build:

- bounded recovery ladder.
- non-idempotent retry guard.
- STOP checks before every gate and before recovery/replan.
- safe-freeze-and-report diagnostic.
- partial-state and irreversible-effect reporting.

Tests:

- Recovery caps prevent infinite loops.
- Non-idempotent action is not repeated after uncertain verification.
- STOP produces diagnostic state instead of silent abort.
- STOP does not falsely claim rollback of irreversible effects.

## Phase 6: Phased Rollout

Post-approval only.

Start with low-risk task classes:

- read/report visible state.
- navigate allowed app with no external side effects.
- draft without send.
- send only after explicit confirmation to verified target.

Promotion criteria:

- audited success on low-risk tasks.
- no policy bypass.
- low false-positive verification rate.
- operator approval for broader task classes.

## Blocking Operator Questions

The plan cannot become implementation work until the operator answers or accepts defaults for:

- v1 task classes.
- budgets and confidence thresholds.
- replan-depth and material-divergence limits.
- policy ownership and change-control.
- audit retention and screenshot handling.
- independent cross-check requirements for high-risk vision verification.
