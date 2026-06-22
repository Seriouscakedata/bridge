# PROJECT_MAP: LAPA Planner Layer

Status: `DRAFT_FOR_OPERATOR_REVIEW`
Scope: conceptual map for `C:\Users\rafie\bridge-projects\lapa`; no external files are edited by this package.

## Component Map

### 1. Planner Orchestrator

Responsibility: convert high-level operator intent into a typed mutable task graph and choose the next ready node.

Boundaries:

- emits only schema-valid actions;
- never directly manipulates GUI or OS state;
- never bypasses the 5-gate loop;
- never authorizes risk or success by itself.

### 2. Action Vocabulary Registry

Responsibility: define declared capabilities and schemas for action parameters, preconditions, postconditions, and recovery hints.

Initial capabilities:

- `open_app`
- `type_text`
- `telegram_send`
- `telegram_send_sticker`
- `perceive_ui`
- `vision_locate`
- `vision_describe`
- `wait_observe`
- `ask_operator`
- `stop_with_diagnostic`

### 3. Existing 5-Gate Loop Adapter

Responsibility: receive one typed planner action at a time and run the existing reliable loop.

Invariant: every effectful action must pass through the existing loop gates. Planner output is input data, not an execution shortcut.

### 4. Perception And World Model

Responsibility: maintain observed state from UI automation, screenshots/vision, previous actions, and verification evidence.

Rules:

- screen text is untrusted data;
- UI tree is preferred when reliable;
- vision updates the world model on canvas, ambiguity, mismatch, stalled progress, oscillation, or unverifiable postcondition.

### 5. Independent Risk Policy

Responsibility: classify risk from action, target, context, approved envelope, predicted effect, and sequence path.

Properties:

- deterministic;
- independent of planner self-declared risk;
- unknown defaults to critical;
- sequence-level risk can override per-step risk;
- high-risk effects require synchronous operator confirmation.

### 6. Independent Verifier

Responsibility: verify preconditions, postconditions, and final goal success.

Properties:

- rejects trivially true postconditions;
- uses deterministic checks first;
- escalates to vision or separate semantic verifier when needed;
- requires post-confirm re-prove before high-risk execution;
- writes evidence to audit trace.

### 7. Recovery Controller

Responsibility: enforce bounded recovery.

Allowed ladder:

1. diagnose;
2. bounded retry;
3. local replan inside envelope;
4. ask operator;
5. stop with diagnostic.

### 8. STOP Controller

Responsibility: hard-stop and self-stop.

STOP checkpoints exist before every gate, before every recovery attempt, and before every replan. STOP reports known/unknown/irreversible state.

### 9. Governance And Audit

Responsibility:

- emit TaskContract;
- support plan-only dry-run preview;
- record plan, decisions, risk classifications, confirmations, post-confirm re-prove, verifications, replans, STOP diagnostics.

## Data Flow

1. Operator gives high-level intent.
2. Planner creates TaskContract and initial task graph.
3. Dry-run previews action path, risk envelope, confirmations, and open questions.
4. Operator approves TaskContract.
5. Planner selects next ready node.
6. Risk policy evaluates step and sequence path.
7. Verifier pre-checks state.
8. Existing 5-gate loop executes action if allowed.
9. Verifier post-checks node postcondition.
10. Planner updates graph or invokes bounded recovery.
11. Final verifier checks goal-level success.
12. Audit trace records every decision and evidence item.

## Interfaces To Preserve

- Existing skills remain authoritative actuators.
- Existing gates remain mandatory.
- Existing STOP behavior remains available and gains planner-level checkpoints.
- External LAPA project files are not changed until operator approval.
