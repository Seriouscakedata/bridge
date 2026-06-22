# DISCUSS_E: Risk, Security, Rollout, and Open Questions

## Accepted Decisions Covered

- `atom_06`: deterministic allow/confirm/deny risk gate.
- `atom_10`: screen content is untrusted data; app/target allowlist fences execution.
- `atom_11`: phased rollout with human-in-loop and audit trail.

## Risk Policy

The LLM may propose intent and expected risk, but deterministic policy decides. Policy inputs are the typed action, target app, target identity, effect class, side-effect class, and current TaskContract envelope.

Default behavior:

- Known read-only, in-scope actions may be `allow`.
- Sends, settings changes, destructive operations, credential-adjacent actions, purchases/pay-adjacent actions, and external publication are `confirm` or `deny`.
- Unknown action classes, unknown targets, and policy gaps default to `confirm`.
- Out-of-allowlist targets default to `confirm` or `deny` depending on effect class.

Risk must also be evaluated at sequence level. A chain of individually low-risk steps can become high-risk if it reaches a sensitive effect, exfiltrates data, changes account state, or performs an operator-meaningful external action.

## Scope Fence

The approved TaskContract defines:

- allowed apps
- allowed targets
- allowed effect classes
- denied effect classes
- max risk tier without confirmation
- budgets
- success definition

Replans outside this fence must trigger operator review or STOP. The planner may not self-certify that a scope expansion is safe.

## Phased Rollout

Recommended v1 task classes:

- Open app and read/report visible state.
- Navigate within an explicitly allowed app without external side effects.
- Draft text for operator review without sending.
- Send after confirmation to an explicitly verified target.
- Structured form fill in a test or low-risk environment.

High-risk effects remain human-in-loop until enough audited macros become proven safe.

## Open Questions For Operator

1. Which v1 task classes should be enabled first?
2. What are default STOP budgets: wall-clock, node count, retry count, replan count, token/cost?
3. What confidence threshold should stop or escalate planner and vision decisions?
4. Who owns allow/confirm/deny lists and app/target allowlists?
5. What replan depth is allowed before forced STOP?
6. What counts as material divergence in your workflow?
7. How long should audit screenshots and traces be retained, and where?
8. Should high-risk vision verification require a second model/provider or deterministic cross-check?

## Tests For Later Implementation

- Verify a planner attempt to label a send as low-risk still requires confirmation.
- Verify sequence-level risk catches an emergent high-risk path.
- Verify out-of-allowlist app/target access fails closed.
- Verify audit contains plan, action, risk, confirmation, verification, recovery, and STOP records.
