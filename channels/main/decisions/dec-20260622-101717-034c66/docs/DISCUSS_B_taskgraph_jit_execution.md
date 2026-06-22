# DISCUSS_B: TaskGraph and Just-In-Time Execution

## Accepted Decisions Covered

- `atom_03`: compile approved plan steps just in time.
- `atom_09`: closed-loop interleaved planning during execution.
- `atom_12`: LLM decomposes into a high-level TaskGraph DAG, not atomic sequences.

## TaskGraph Shape

The TaskGraph is a DAG of high-level nodes. Each node describes a sub-goal, not a raw click/type/send sequence.

Required node fields:

- `node_id`
- `title`
- `goal`
- `depends_on`
- `allowed_apps`
- `allowed_targets`
- `preconditions`
- `postcondition`
- `risk_expectation`
- `recovery_ladder`
- `verification_methods`
- `max_retries`
- `material_divergence_rules`

## Closed-Loop Runtime

After the operator approves the high-level plan, execution is interleaved:

1. Perceive current state.
2. Select the next eligible node.
3. Re-check scope and STOP.
4. Compile that one node into typed actions.
5. Run each action through the five-gate loop.
6. Verify the node postcondition.
7. Continue, recover, or stop.

Replanning is allowed only inside the approved plan envelope. A replan is material and must trigger operator review or STOP when it changes app/target allowlist, adds a new high-level sub-goal, raises risk tier, exceeds budgets, changes the success definition, or requires a new side-effect class.

## Non-Idempotent Action Guard

Retries are not allowed blindly for side-effecting actions. If a postcondition cannot be verified after a potentially successful side effect, the system must not repeat the action until it proves non-occurrence or obtains operator confirmation.

Examples:

- Do not resend a message just because verification is uncertain.
- Do not submit a form twice if a confirmation page is ambiguous.
- Do not repeat destructive or settings actions without explicit confirmation.

## TOCTOU Guard

Before any UI action compiled from perception, the executor must re-ground focus, target identity, and action coordinates/selector freshness. If the state changed between perception and act, fail closed into recovery or STOP.

## Tests For Later Implementation

- Verify TaskGraph contains high-level nodes and no pre-baked atomic action list.
- Verify atomic actions are generated per node immediately before execution.
- Force a material replan and confirm it re-enters operator review or STOP.
- Simulate stale perception and confirm the action is blocked before actuation.
