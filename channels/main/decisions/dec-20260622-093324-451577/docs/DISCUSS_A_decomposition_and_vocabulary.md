# DISCUSS_A: Decomposition And Typed Vocabulary

Status: `DRAFT_FOR_OPERATOR_REVIEW`
Related decisions: DA001, DA003, DA010

## Decision

Use LLM-based hierarchical decomposition, but constrain its output to a schema-validated mutable task graph. The LLM may propose goals, dependencies, preconditions, recovery paths, and postconditions, but it may not invent executable primitives.

Every executable node must compile to one declared loop-action in the existing LAPA capability vocabulary.

## Task Graph Shape

Required fields for each node:

- `id`: stable node id.
- `goal`: natural-language local objective.
- `action`: one declared action from the vocabulary, or `null` for grouping nodes.
- `depends_on`: node ids that must be complete first.
- `preconditions`: machine-checkable state requirements before execution.
- `postcondition`: machine-checkable success condition required by DA004.
- `risk_hint`: planner-supplied hint only, never authoritative.
- `recovery`: bounded recovery plan or reference to the global recovery ladder.
- `status`: `planned | ready | running | verified | failed | blocked | stopped`.

## Initial Action Vocabulary

The planner can only emit declared capabilities:

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

The vocabulary is intentionally narrow. If a high-level task requires an undeclared skill, the planner must either replan using declared actions inside the approved envelope or self-STOP with a missing-capability diagnostic. It must not generate code, shell commands, UI scripts, or free-form OS automation.

## Envelope-Bounded Replanning

Replanning is autonomous only while it remains inside the approved TaskContract envelope:

- same target app or explicitly approved app set;
- same target entity, account, file, chat, or user-visible object;
- no new high-risk effect class;
- no increase in risk tier;
- no expansion beyond approved step/time/retry budget;
- no attempt to use undeclared capability;
- no change to the operator's original success criterion.

Crossing any boundary routes to `ask_operator` or `stop_with_diagnostic`.

## Test Criteria

- Validate generated graph against schema.
- Reject a node without `postcondition`.
- Reject any executable action outside vocabulary.
- Force a replan to a new app or higher risk tier and verify it asks for approval or stops.
- Confirm every planner emission is only an input to the 5-gate loop, never a direct actuator.
