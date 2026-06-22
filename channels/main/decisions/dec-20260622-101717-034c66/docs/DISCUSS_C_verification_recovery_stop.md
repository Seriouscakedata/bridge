# DISCUSS_C: Verification, Recovery, and STOP

## Accepted Decisions Covered

- `atom_04`: every node has a postcondition and bounded recovery ladder.
- `atom_07`: multi-layer STOP with freeze-and-report.
- `atom_08`: fail-closed defaults.

## Postconditions

Every TaskGraph node needs a machine-checkable postcondition. A node is not complete because an action was attempted; it is complete only when the postcondition is positively verified.

Postcondition checks may use:

- Accessibility/UI tree.
- Deterministic app state or API response, when available.
- Vision/OCR as fallback or as the primary method for canvas-only surfaces.
- Cross-checks between perception sources for high-risk or ambiguous cases.

LLM-authored postconditions must be schema-validated and rejected when trivially true, self-referential, unobservable, or disconnected from the node goal.

## Recovery Ladder

Recovery is bounded:

1. Diagnose: identify what failed and what evidence is missing.
2. Retry: allowed only for idempotent or proven-safe actions.
3. Re-ground via vision/perception.
4. Local replan within the approved envelope.
5. Escalate to operator or STOP.

No unbounded loops. Repeated verification failure, oscillation, or confidence collapse triggers self-STOP.

## STOP Semantics

STOP means safe-freeze-and-report, not a promise that already emitted OS effects are rolled back. The report must distinguish:

- `known_state`
- `unknown_state`
- `last_completed_node`
- `current_node`
- `irreversible_effects`
- `pending_confirmations`
- `recommended_operator_action`

For irreversible effects, the system must checkpoint before actuation and disclose partial-state risk if STOP occurs afterward.

## Goal-Level Verification

Per-node verification is necessary but insufficient. The final plan must include a goal-level postcondition that checks whether the original operator intent was achieved, not merely whether all nodes passed locally.

## Tests For Later Implementation

- Inject action-succeeded-but-verification-failed cases and confirm bounded recovery, not silent advance.
- Confirm non-idempotent retries are blocked unless non-occurrence is proven or operator confirms.
- Trigger STOP at multiple gates and verify partial-state diagnostics.
- Confirm final goal-level verification runs after node completion.
