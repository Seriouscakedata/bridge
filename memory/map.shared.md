# Shared Seed Memory

Shared knowledge that should be visible across MOS project channels.

## Product Principles

- A new tab/channel is a separate project context.
- Project plans must be deep before execution: UX map, UI routes/states, client/server/data responsibilities, security, tests, and acceptance.
- Planning should support discussion by domain: product/UX, UI, client, server, data, operations, risks, and tests.
- Backlog atoms should be small, dependency-aware, and suitable for parallel grouping when they do not conflict.
- Chat must show the work in progress: planning decisions, backlog generation, worker dispatch, verification evidence, acceptance results, and blockers.
- Memory is part of the product, not a side log. Important facts and decisions should be written as durable typed memory.

## Safety Principles

- Operator approval should be required for destructive, credential, billing, repository force-push, or security-sensitive actions.
- Runtime files are local to each installation and should not be transferred as product state.
- The bridge should improve existing modules when possible; new layers are justified only when they clarify responsibilities or remove real coupling.

