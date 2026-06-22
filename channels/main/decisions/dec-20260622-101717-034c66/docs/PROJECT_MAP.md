# PROJECT_MAP: LAPA Planner Layer

## Components

### Operator Interface

Receives high-level user goals and returns review artifacts:

- `PROJECT_BRIEF`
- high-level `PROJECT_PLAN`
- `TaskContract`
- dry-run preview
- open questions

### Planner

Advisory-only reasoning component. It produces a high-level TaskGraph and later proposes one node for JIT compilation. It has no direct OS/UI/Telegram/file/settings actuation path.

### TaskContract Store

Stores the approved goal envelope:

- goal and success criteria
- allowed apps/targets
- denied targets/effects
- risk envelope
- budgets
- approval state
- audit settings

### TaskGraph Store

Stores high-level nodes, dependencies, postconditions, recovery ladders, and verification requirements. It must not store pre-generated atomic action sequences.

### JIT Step Compiler

Transforms one eligible approved node into typed loop-action proposals immediately before execution. It runs only after scope, STOP, and risk prechecks.

### Existing Reliable Hands Executor

The existing five-gate loop remains the only execution chokepoint. It owns actuation and safety gates for open/type/telegram/vision-assisted actions.

### Deterministic Risk Policy

Independent policy engine with allow/confirm/deny outcomes. It evaluates action-level and sequence-level risk and cannot be overridden by the planner.

### Perception and Vision Layer

Provides cheap perception first, vision escalation, context scans, obstacle detection, postcondition verification, and read-only scouting. Screen text is untrusted data.

### Verifier

Checks node postconditions and final goal-level success. It uses deterministic sources where possible and cross-checks vision for ambiguous/high-risk cases.

### Recovery and STOP Controller

Owns bounded recovery and safe-freeze-and-report. STOP is checked before every gate and before recovery/replan.

### Audit Trail

Records the complete provenance from operator goal to plan, compile, action, risk decision, confirmation, verification, recovery, and STOP.

## Data Flow

1. Operator submits high-level goal.
2. Planner performs read-only context scan if allowed.
3. Planner emits brief, TaskGraph, plan, and contract draft.
4. Operator approves or revises.
5. Runtime selects next eligible node.
6. Scope/risk/STOP prechecks run.
7. JIT compiler emits typed action proposal for one node.
8. Existing five-gate loop executes or blocks.
9. Verifier checks node postcondition.
10. Recovery, replan, continue, or STOP.
11. Final goal-level verifier checks the original intent.

## Boundaries

- Planner may read approved contract, graph, and quarantined perception summaries.
- Planner may not call OS/UI/Telegram/settings APIs.
- Executor may not accept free-form actions; only typed declared capabilities.
- Risk policy is deterministic and independent of planner claims.
- Vision output is evidence, not policy.
- Screen content is data, not instruction.
