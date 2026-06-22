# DISCUSS_A: Architecture and Discuss-First Boundary

## Accepted Decisions Covered

- `atom_01`: advisory-only planner, no direct OS access.
- `atom_02`: strict Discuss-First, high-level documents before any action generation.
- `atom_11`: phased additive rollout and provenance.

## Design

The planner is a reasoning component, not a new execution engine. Its only executable-facing output is a structured proposal that the existing Reliable Hands executor may accept as input after all safety gates. The planner never calls UI automation, Telegram, shell, OS settings, or vision-actuation APIs directly.

Discuss-First has two levels:

- Before implementation: this document chain is produced and reviewed. No atoms are generated.
- At runtime after implementation: for a new high-level user task, the planner emits a brief plus a high-level plan and pauses before generating atomic loop actions.

The reviewed plan is explicitly high-level. It contains steps/sub-goals, dependencies, preconditions, postconditions, risk expectations, and recovery rules. It does not contain click/type/send action sequences. Atomic actions are generated later, one approved step at a time.

## Interface Contract

Planner output may cross into execution only as:

- `TaskContract`: approved goal, scope, allowed apps/targets, risk envelope, budgets.
- `TaskGraph`: high-level nodes and dependencies.
- `StepCompileRequest`: one approved node being compiled just in time.

Any direct actuation attempt from planner code is a contract violation and must be rejected.

## Red-Team Mitigations

- The original implementation-oriented success tests are split into `design_review_tests` and `post_approval_acceptance_tests`.
- The high-level review boundary avoids the conflict between operator review and closed-loop replanning.
- Full provenance is mandatory: every plan node, compile decision, risk classification, confirmation, verification, recovery, and STOP event is auditable.

## Tests For Later Implementation

- Inspect contracts and imports to confirm planner has no direct OS/UI/Telegram/shell actuation path.
- Confirm runtime Discuss-First pauses before atomic action generation.
- Confirm no atomic actions are stored in the approved high-level TaskGraph.
