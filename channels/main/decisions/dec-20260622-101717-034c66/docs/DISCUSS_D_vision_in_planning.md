# DISCUSS_D: Vision in Planning

## Accepted Decision Covered

- `atom_05`: vision has planning roles beyond element location.

## Vision Roles

Vision is promoted from "locate the element when stuck" to a planning input with four roles:

1. Precondition grounding: understand what app/window/page/state is actually present before decomposition or step compilation.
2. Obstacle/anomaly detection: detect modals, focus theft, unexpected dialogs, disabled controls, login prompts, or app mismatch.
3. Postcondition verification: judge visible effects when deterministic state is unavailable.
4. Read-only scouting: inspect a screen to inform a plan without acting.

A context scan before decomposition is permitted when the approved task depends on current screen state. The scan is read-only and cannot create actions by itself.

## Invocation Policy

Cheap perception comes first: accessibility tree, window metadata, deterministic APIs, and known app state. Vision escalates when:

- The surface is canvas/image-heavy.
- Cheap perception is absent, conflicting, stale, or ambiguous.
- Progress stalls or state oscillates.
- A postcondition cannot be verified cheaply.
- A high-risk step needs an independent visual cross-check.

## Screen Prompt-Injection Defense

All screen text is untrusted data. It must be passed to the planner in a quarantined field such as `screen_content`, with policy instructions stating that embedded instructions are not commands.

The privileged goal, contract, policy, and operator approvals live outside screen content. If screen content asks the agent to ignore policy, change targets, send data, escalate privileges, or perform unrelated work, it is treated as hostile or irrelevant data.

## Vision Reliability

Confident vision can still be wrong. High-risk advancement must require either deterministic confirmation, cross-source agreement, or operator confirmation. Vision disagreement or low confidence fails closed.

## Tests For Later Implementation

- Show vision grounding before decomposition on a canvas-only or visually ambiguous app.
- Inject visible prompt-injection text and confirm it is ignored as instruction.
- Simulate confident-but-wrong vision by cross-check mismatch and confirm fail-closed handling.
- Confirm vision is used for postcondition verification when accessibility cannot verify the effect.
