# DISCUSS_B: Verification, Recovery, And Goal Success

Status: `DRAFT_FOR_OPERATOR_REVIEW`
Related decisions: DA002, DA004, DA008, DA011

## Decision

Each executable task-graph node follows one discipline:

1. Plan a typed action.
2. Pre-verify that its preconditions still hold.
3. Execute through the existing 5-gate loop.
4. Post-verify the declared postcondition using perception, escalating to vision when needed.
5. Recover only through the bounded ladder.

The system must never equate "action was emitted" with "effect was achieved".

## Machine-Checkable Postconditions

Postconditions must be generated from templates and validated by schema, not accepted as arbitrary LLM text. A postcondition is machine-checkable only when it names:

- observation source: UI tree, screenshot/vision, app state, or operator confirmation;
- expected evidence: visible text, selected target identity, URL/window title, message draft content, sent state, file path, or equivalent;
- comparator: exact match, contains, target id match, state transition, absence/presence;
- failure behavior: retry, local replan, ask operator, or stop.

Trivially true postconditions such as `action completed`, `no error`, or `looks fine` are invalid.

## Independent Verification

The planner proposes. A separate verifier validates:

- schema correctness;
- preconditions;
- postcondition evidence;
- goal-level success after all steps;
- mismatch between predicted and observed state.

The verifier should use independent prompts/components where models are needed and deterministic checks where possible. Correlated sensory failures are handled by requiring a second evidence source for high-risk or ambiguous success.

## Goal-Level Verification

After all step postconditions pass, the planner must verify the original operator intent as a whole. Examples:

- "message sent to Ivan" verifies chat identity and final sent payload, not just that a send button was clicked;
- "open settings page" verifies the final page/window corresponds to the requested setting;
- "fill form" verifies the target form and final field values.

If goal-level verification fails, the task is not done even when every local step passed.

## Recovery Ladder

Recovery is bounded:

1. Diagnose mismatch from latest perception.
2. Retry the same action within retry budget.
3. Locally replan inside the approved envelope.
4. Ask operator when the issue is ambiguous or risk changes.
5. Stop with diagnostic when budgets are exhausted or state is unsafe/unknown.

No infinite correction loop is allowed.

## Test Criteria

- Inject execute-without-effect and verify recovery, not advancement.
- Reject trivially true postconditions.
- Simulate local step success but wrong final target and verify goal-level failure.
- Verify recovery caps enforce stop/ask rather than repeated replans.
- Verify generator and verifier outputs are separately recorded in audit trace.
