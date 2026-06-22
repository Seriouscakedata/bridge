# PROJECT_PLAN: LAPA Planner Layer

Status: `DRAFT_FOR_OPERATOR_REVIEW`
Gate: implementation blocked until operator approves this plan and `CONTRACT.json`.

## Phase 0: Review Gate

Deliver this Discuss-First package:

- `PROJECT_BRIEF.md`
- `DISCUSS_A_decomposition_and_vocabulary.md`
- `DISCUSS_B_verification_recovery.md`
- `DISCUSS_C_vision_in_planning.md`
- `DISCUSS_D_risk_stop_governance.md`
- `DISCUSS_E_open_questions.md`
- `PROJECT_MAP.md`
- `PROJECT_PLAN.md`
- `CONTRACT.json`

No executable atoms are generated in this phase.

## Phase 1: Foundations

Build after approval:

- action vocabulary registry and JSON schema;
- task graph schema;
- postcondition schema and template library;
- deterministic risk policy with sequence-level path risk;
- audit event schema;
- prompt boundary for untrusted screen content.

Acceptance:

- invalid action is rejected;
- missing/trivial postcondition is rejected;
- unknown risk defaults to critical;
- screen prompt-injection text cannot lower risk or change policy;
- generated graph validates against schema.

## Phase 2: Planner Core

Build:

- high-level intent to task graph decomposition;
- ready-node selection;
- envelope-bounded replanning;
- missing-capability STOP;
- dry-run preview of planned path, risk envelope, expected confirmations, and open assumptions.

Acceptance:

- planner emits only declared actions;
- replan inside same app/target/risk budget proceeds;
- replan to new target app, new high-risk class, or budget overrun asks operator or stops;
- dry-run produces reviewable TaskContract without executing.

## Phase 3: Verification And Recovery

Build:

- precondition verifier;
- postcondition verifier;
- final goal-level verifier;
- generator-verifier separation in audit;
- bounded recovery controller.

Acceptance:

- execute-without-effect fails postcondition and enters recovery;
- wrong final target fails goal-level verification;
- retry/replan caps are enforced;
- ambiguous verification asks operator or stops;
- high-risk success uses stronger evidence where available.

## Phase 4: Vision-Aware World Model

Build:

- cheap-perception-first world model;
- vision escalation triggers;
- mismatch/stuck/oscillation detection;
- vision-as-judge for postconditions that UI tree cannot verify.

Acceptance:

- UI tree is used when sufficient;
- canvas/non-accessible UI escalates to vision;
- stalled or oscillating state escalates or stops;
- vision evidence is logged;
- cost budget produces ask/stop instead of runaway calls.

## Phase 5: Risk, Confirmation, And STOP

Build:

- independent risk policy integration before each executable node;
- synchronous confirmation for high-risk effects;
- post-confirm re-prove of target/payload/state;
- STOP checkpoints before gates, recovery, and replan;
- partial-state diagnostic report.

Acceptance:

- planner cannot downgrade high-risk action;
- sequence-level emergent risk escalates;
- target changes after confirmation invalidate approval;
- STOP before recovery halts and reports known/unknown/irreversible state;
- irreversible effects are disclosed, not claimed rollbacked.

## Phase 6: Pilot Rollout

Enable only low-risk read-only and reversible tasks first.

Pilot order:

1. open and inspect app/window;
2. navigate to a non-sensitive screen;
3. fill draft field without sending;
4. operator-confirmed send in controlled test chat;
5. system setting/destructive flows remain disabled until separate approval.

Acceptance:

- audit traces are complete;
- failure cases stop cleanly;
- operator can inspect dry-run and final diagnostic;
- no high-risk action proceeds without confirmation and post-confirm re-prove.

## Blocking Open Questions

Implementation should not begin until the operator accepts or edits defaults in `DISCUSS_E_open_questions.md`, especially envelope boundaries, budgets, verifier independence, STOP reporting, vision budget, and missing-capability behavior.

## Decision Coverage

- DA001: Phase 1-2 schemas and loop adapter boundary.
- DA002: Phase 3 execution trace discipline.
- DA003: Phase 2 task graph and replanning.
- DA004: Phase 1 and Phase 3 postconditions.
- DA005: Phase 4 vision roles.
- DA006: Phase 1 and Phase 5 risk policy.
- DA007: Phase 5 STOP.
- DA008: Phase 3 recovery ladder.
- DA009: Phase 0 review gate and Phase 2 dry-run/audit.
- DA010: Phase 1 action vocabulary.
- DA011: Phase 3 generator-verifier separation.
- DA012: Phase 4 cheap-perception-first escalation.
