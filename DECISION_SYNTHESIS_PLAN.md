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
- Proposers: Codex (`Invoke-Coder`) + Claude (`Invoke-Planner`; Sonnet for Standard, Opus for Deep) + Gemini
  `gemini-2.5-flash` (`Invoke-LLM -Purpose proposer`). NEVER gemini-2.5-pro; gemini-3-flash reserve only.
- Judge by task type: architecture→Claude/Opus; bugfix/refactor/infra→Codex; research/creative→Gemini-flash.
- Control-plane atoms produced by a decision → filed to backlog with needs_operator (no auto-approve).
- Promote-out-of-shadow only after N real synthesis runs show parity/better vs legacy (gate-live-confirmed bar).

## Migration strategy
INCREMENTAL, SHADOW-FIRST, FLAG-GATED. New `task_mode='synthesis'` built ALONGSIDE the live `discuss` path.
Engine (Ch1-11) is pure/testable with ZERO live-loop impact (callable via `[[SYNTH]]` test marker only). The only
risky integration is Ch12 (driver wiring), behind `config.json synthesisMode.enabled` (default false). Ch13 removes
the legacy path after proof. Reuse: `lib/decision-contract.ps1` (validator+shadow template), `Invoke-Planner/Coder/LLM`
(the 3 proposers already exist), `Save-Decision→decisions/*.md→Get-DecisionsRecall` (recall surface), `Add-Idea`
(atom harvest). Net-new: `lib/decision-depth.ps1`, `lib/decision-artifacts.ps1`, `lib/decision-synthesis.ps1`,
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
| 12 | Driver integration behind flag + promote-out-of-shadow | 6 | YES (flag-gated) |
| 13 | Legacy cutover — remove old role-based discuss after proof | ~3 | YES (after proof) |

Rubric (Ch8): correctness .25, feasibility .20, impact .20, simplicity .15, risk_reduction .10, specificity .10;
penalties: unsupported_complexity, contradiction, hidden_dependency, vagueness. Rules: critique optional
("no significant issues" valid); objection needs severity+why+fix+cost; max 1-3 debate topics, ≤2 rounds;
synthesize decisions not texts; every important decision carries a test.

## Acceptance (Ф7) — verify FLOW not green-build
A Deep architecture task runs contract→proposals→atoms→matrix→review→judge→(debate)→synthesis→red-team→record,
producing all artifacts + an approved atom; flag OFF → identical task uses legacy discuss unchanged; a High-Stakes
task halts at the human-approval gate. After Ch13: legacy role-based prompts/ping-pong/convergence-gate are gone.

## BUILD STATUS (2026-06-16) — operator-built, bridge stays on CC
- DONE + committed + PS5.1-tested independently:
  - Ch1 `lib/decision-depth.ps1` (depth router + shadow) — 6/6 cases. (57a2fcb)
  - Ch2 `lib/decision-artifacts.ps1` (7 schemas+validators + Get-ChannelDecisionsDir) — 14/14.
  - Ch3-10 `lib/decision-synthesis.ps1` (full pipeline engine + Invoke-SynthesisPipeline) — 38/38 mock test (Standard+Deep). DORMANT (no driver wiring).
  - config.json `synthesisMode` block (enabled=false).
- REMAINING (the live integration — touches the running driver, do carefully with full smoke):
  - Ch11 record/recall wiring (Save-Decision mirror + Add-Idea harvest on the synthesis-close branch; driver/86 + common.ps1 session-ledger enum).
  - Ch12 driver routing behind `synthesisMode.enabled` (driver/81 route Deep/High-Stakes -> task_mode='synthesis'; 82/83 dispatch to Invoke-SynthesisPipeline; 85/86 close; handle task_mode='synthesis' as pass-through in ALL branches incl doctor.ps1). Flip flag only after shadow proof.
  - Ch13 legacy cutover (remove role-based prompt suffixes / Next-Speaker ping-pong / convergence regex gate) AFTER promotion. Hard cutover per user.
  - Acceptance: a real-LLM Deep run from the bridge env (needs secrets-bootstrap, not operator context) producing all artifacts + a Decision Record.
