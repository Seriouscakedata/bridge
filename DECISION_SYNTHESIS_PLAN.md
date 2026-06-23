# Decision Synthesis — replacing role-based DISCUSS (FROZEN PLAN, 2026-06-16)

## Intent (user)
Replace the current discussion system (one model PROPOSES → second is FORCED to CRITICIZE → third COMPROMISES).
Problem: mandatory critique manufactures artificial conflict; models drown in dialogue, lose the goal, produce
"smart objections" not better decisions. New system = **Multi-Model Decision Synthesis**: artifacts not chat,
decision-atoms not whole-answers, optional/targeted critique, rubric-scored synthesis (no compromise-mush),
tiered depth, red-team + Decision Record + memory. Core reframe: not "which model is right" but "which decision
atoms to take". Applies EVERYWHERE discussion is invoked (user-triggered, Discuss-First Ф1, autonomous deep-think).

## User decisions (2026-06-16)
1. **Default depth = Smart-router**: Deep for architecture/high-risk, Standard for normal, Simple for trivial.
2. **Hard cutover** (NOT permanent fallback): build shadow-first/flag-gated for safe construction, prove in
   parallel, THEN remove the legacy role-based discuss entirely (Ch13). End state = new pipeline only.
3. **No cost ceiling** on a Deep decision: no auto-downgrade; the smart-router is the cost control (Deep only
   where it matters), within Deep quality is not trimmed.

## Architect decisions (operator-level, respect model policy)
- Proposers: Codex (`Invoke-Coder`, `gpt-5.5`, xhigh, read-only) + Claude (`Invoke-Planner`,
  `claude-opus-4-8`, xhigh) + config-driven LLM proposer C (`deepseek-v4-pro`). NEVER gemini-2.5-pro;
  gemini-3-flash reserve only.
- Cheap/helper synthesis stages use `gemini-2.5-flash`; they do not replace the main decision models.
- Judge by task type: architecture→Claude/Opus; bugfix/refactor/infra→Codex; research/creative→Gemini-flash.
- Control-plane atoms produced by a decision → filed to backlog with needs_operator (no auto-approve).
- Live route is enabled now; Ch13 removes the remaining legacy role-based discuss path after live monitoring.

## Migration strategy
Initial construction was incremental and shadow-first. Current state (2026-06-16): `task_mode='synthesis'` is a
live route when `config.json synthesisMode.enabled=true`. It replaces eligible explicit discuss/deep-think tasks
and smart-router Deep/High-Stakes tasks. Legacy role-based discuss remains only for non-synthesis routes until
Ch13 removes it. Reuse: `lib/decision-contract.ps1` (validator+shadow template), `Invoke-Planner/Coder/LLM`,
`Save-Decision→decisions/*.md→Get-DecisionsRecall` (recall surface), `Add-Idea` (atom harvest follow-up).
Net-new/live: `lib/decision-depth.ps1`, `lib/decision-artifacts.ps1`, `lib/decision-synthesis.ps1`,
per-decision JSON artifacts under `channels/<slug>/decisions/<id>/`, config `synthesisMode` block.

CONTROL-PLANE: every atom touches bridge control-plane → MUST carry `-Tags @('operator', ...)` or it wedges.
commit_famine: 1-file atoms; the engine lib is built additively one function-group atom at a time; each stage
writes its artifact to disk (natural checkpoints) so a Deep run is never one giant uncommitted task.

## Chapters (build in order; ~50 atoms)
| # | Chapter | Atoms | Live-loop risk |
|---|---------|-------|----------------|
| 1 | Depth-mode router (Simple/Standard/Deep/High-Stakes), SHADOW | 3 | none (shadow) |
| 2 | Artifact store + 7 schemas/validators (pure lib) | 8 | none |
| 3 | Task Contract (stage 0) | 4 | none ([[SYNTH]]) |
| 4 | Blind independent proposals (3 models, no roles) | 4 | none |
| 5 | Normalize + decision-atom extraction (stage 2-3) | 4 | none |
| 6 | Consensus / conflict matrix (stage 4) | 3 | none |
| 7 | Targeted cross-review (critique decision, not model) | 3 | none |
| 8 | Judge synthesis + rubric (stage 6) | 4 | none |
| 9 | Micro-debate trigger (1-3 conflicts, ≤2 rounds) | 3 | none |
| 10 | Final synthesis v2 + Red-Team (stages 8-9) | 3 | none |
| 11 | Decision Record + memory + recall wiring | 5 | none |
| 12 | Driver integration live + post-live monitoring | 6 | YES |
| 13 | Legacy cutover — remove old role-based discuss after proof | ~3 | YES (after proof) |

Rubric (Ch8): correctness .25, feasibility .20, impact .20, simplicity .15, risk_reduction .10, specificity .10;
penalties: unsupported_complexity, contradiction, hidden_dependency, vagueness. Rules: critique optional
("no significant issues" valid); objection needs severity+why+fix+cost; max 1-3 debate topics, ≤2 rounds;
synthesize decisions not texts; every important decision carries a test.

## Acceptance (Ф7) — verify FLOW not green-build
A Deep architecture task runs contract→proposals→atoms→matrix→review→judge→(debate)→synthesis→red-team→record,
producing all artifacts + an approved atom; a High-Stakes task produces a needs_operator decision and does not
auto-implement. After Ch13: legacy role-based prompts/ping-pong/convergence-gate are gone.

## BUILD STATUS (2026-06-16) — operator-built, bridge stays on CC
- DONE + committed + PS5.1-tested independently:
  - Ch1 `lib/decision-depth.ps1` (depth router + shadow) — 6/6 cases. (57a2fcb)
  - Ch2 `lib/decision-artifacts.ps1` (7 schemas+validators + Get-ChannelDecisionsDir) — 14/14.
  - Ch3-10 `lib/decision-synthesis.ps1` (full pipeline engine + Invoke-SynthesisPipeline) — 42/42 mock+driver-wrapper test (Standard+Deep). Engine is now wired through `task_mode='synthesis'` when `synthesisMode.enabled=true`.
  - config.json `synthesisMode` block (enabled=true).
- LIVE: the Ch12 synthesis route is in production; the legacy role-based discuss path still co-exists (Ch13 cutover not fully done) — driver/40-agent-invoke.ps1 handles both `discuss` and `synthesis`.
- REMAINING (post-live hardening):
  - Ch11 follow-up: Add-Idea harvest for accepted decision atoms.
  - Ch12 follow-up: run a real-LLM smoke from the bridge runtime, monitor first live synthesis tasks, and add focused regression coverage for driver route/close behavior.
  - Ch13 legacy cutover (remove role-based prompt suffixes / Next-Speaker ping-pong / convergence regex gate) AFTER promotion. Hard cutover per user.
  - Acceptance: a real-LLM Deep run from the bridge env (needs secrets-bootstrap, not operator context) producing all artifacts + a Decision Record.

## LIVE INTEGRATION UPDATE (2026-06-16)
- `synthesisMode.enabled=true`; this is now a live route, not only a test engine.
- `driver/81-loop-idle-claim.ps1` routes explicit discuss/deep-think and smart-router Deep/High-Stakes tasks to `task_mode='synthesis'`.
- `driver/83-loop-agent-turn.ps1` runs `Invoke-SynthesisDriverTurn`.
- If the Decision Record has an implementation plan and no operator gate, `driver/86-loop-completion-checks.ps1` moves the task to normal Codex implementation with the existing verify/critic gates.
- Explicit model roles:
  - Claude synthesis stages use `synthesisMode.claudeModel` / `deepModel` (`claude-opus-4-8`) through `Invoke-Planner` with xhigh on premium Claude.
  - `claude-fable` worker ids currently map to `claude-opus-4-8`; direct `claude-fable-5` is not used because the bridge's Claude CLI subscription returned 404 for that model name.
  - Codex synthesis/discuss uses `coder.model` (`gpt-5.5`) and `model_reasoning_effort=xhigh`; synthesis Codex calls are read-only.
  - Proposer C uses `synthesisMode.proposerModels.C` (`deepseek-v4-pro`).
  - Cheap synthesis stages use `synthesisMode.cheapModel` (`gemini-2.5-flash`).
