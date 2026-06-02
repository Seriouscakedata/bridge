# Project Workflow Guide

This document describes the intended universal workflow for projects built through MOS Bridge.

## Principle

Do not jump from idea directly into coding. MOS should first build enough shared understanding to avoid shallow implementation, forgotten context, and weak acceptance.

The project flow is:

```text
Idea -> Discussion -> Deep Plan -> Backlog Atoms -> Parallel Workpacks -> Implementation -> Verification -> Acceptance -> Memory
```

## 1. Idea

The operator gives a rough idea:

```text
I want a private community website with registration, chat, image feed, profiles, and an admin panel.
```

MOS should not immediately code. It should ask or infer enough to define the product.

## 2. Discussion

Discussion should cover separate domains while preserving shared context:

- Product goal.
- Users and roles.
- UX and routes.
- UI style.
- Client architecture.
- Server architecture.
- Data model.
- Storage.
- Security and abuse risks.
- Testing and acceptance.

Each domain should know the conclusions from previous domains. For example, server planning should know the UX routes and data needs; acceptance should know all product promises.

## 3. Deep Plan

A good project plan should include:

- Product summary.
- User roles.
- Route map.
- Screen/state map.
- Main user flows.
- Admin flows.
- Data model.
- API contract.
- File/module plan.
- Security notes.
- Performance target.
- Test plan.
- Acceptance criteria.
- Risks and open questions.

If the plan is shallow, implementation will be shallow too.

## 4. Backlog Atoms

The planner should convert the plan into small tasks. Each atom should have:

- `slug`
- `title`
- `task`
- `files`
- `depends_on`
- `severity`
- expected verification

Good atoms are independent enough to implement and test.

Bad atoms are vague:

- "Improve UI."
- "Finish backend."
- "Make project better."

## 5. Dependency And Conflict Model

Before parallel work, MOS should classify atoms by:

- Domain: UI, API, data, auth, tests, docs, config.
- Files touched.
- Shared resources.
- Dependencies.
- Risk.

Two tasks can run in parallel when they do not modify the same shared files and one does not depend on the other.

## 6. Workpack Grouping

Workpacks are groups of compatible atoms.

Example:

- Workpack A: auth pages and auth API.
- Workpack B: gallery upload UI and storage API.
- Workpack C: admin dashboard UI.
- Workpack D: tests and acceptance harness.

The dispatcher should post visible chat events:

- what workpacks were created;
- which tasks went into each workpack;
- which workers started;
- which workpack passed or failed;
- what was merged;
- what remains.

## 7. Implementation

Workers should implement real behavior, not only scaffolding. They should produce verifiable changes and report:

- files changed;
- commands run;
- actual results;
- limitations;
- follow-up tasks if needed.

## 8. Verification

Verification should be concrete:

- Build command.
- Typecheck/lint if available.
- Unit/integration/e2e tests if available.
- HTTP checks for APIs.
- Browser checks for UI routes.
- Screenshots for visual acceptance when relevant.

Claims like "looks good" or "should work" are not enough.

## 9. Acceptance

Acceptance is project-specific and should come from the plan.

For a web app, acceptance normally includes:

- registration/login/logout;
- route navigation;
- primary user flow;
- admin flow;
- persistence after refresh;
- error states;
- mobile and desktop checks;
- build/test pass.

If acceptance fails, MOS should create follow-up backlog items and continue unless operator approval is required.

## 10. Memory

After major steps, MOS should record:

- decisions;
- durable facts;
- risks;
- tests;
- invariants;
- open questions;
- worklog entries.

Memory should help future turns understand what the project is, what has already been decided, and how to verify it.

## Operator Control Points

The operator should explicitly approve:

- the deep plan;
- the generated backlog;
- destructive or security-sensitive actions;
- final acceptance.

The operator should not have to manually feed one task at a time. Once the plan/backlog are accepted, MOS should work through the backlog autonomously and report progress.

