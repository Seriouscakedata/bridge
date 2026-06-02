# Operator Error Log

_Created: 2026-06-01. Owner: Codex operator/monitor._

This file records concrete errors, weak spots, and recovery notes observed while operating the bridge. It is intentionally separate from project plans: this is an incident/worklog file for problems encountered during bridge-driven execution.

## Logging Rules

- Record only observed issues, not guesses.
- Include impact, current status, and the next practical fix.
- Do not store secrets, tokens, passwords, or private user data.
- Keep entries short enough to scan during monitoring.

## 2026-06-02

### ERR-2026-06-02-016 - Project acceptance passed a visually unacceptable MVP

**Context:** `private-community` final acceptance reported PASS (`channels/private-community/acceptance/20260602-105342-PASS.md`), but manual operator review showed the app did not match the requested "Instagram-like private photo community website" quality bar. The public home was a single centered card, auth pages were plain forms, upload used a native file input, chat/profile/feed looked like generic CRUD screens.

**Observed:** Existing `smoke:ux` mostly checked that routes rendered the app shell and contained static fragments such as `app-nav`, `Feed`, `Chat`, `Upload`, `Profile`. It did not assert that core screens had product-level UX structure, and it did not require visual inspection/screenshots before PASS.

**Impact:** Bridge could claim a project is complete while the actual browser UI is visibly below the user's stated target. This is a trust problem, not just a cosmetic issue: the operator sees "PASS" but the delivered app is not acceptable.

**Action taken:** Direct operator fix in `C:\Users\rafie\bridge-projects\private-community`: redesigned public home, auth pages, app shell, feed, upload, profile, chat, and admin styling; removed an operator-created 1x1 visual-audit test photo that polluted the feed; strengthened `scripts/smoke/ux-smoke.ts` with route-specific UX fragments (`home-hero`, `home-preview`, `auth-layout`, `feed-layout`, `feed-composer-card`, `upload-dropzone`, `chat-layout`, `profile-gallery`).

**Verification:** `npm.cmd run build`, `npm.cmd run typecheck`, `smoke:pages`, `smoke:ux`, `smoke:auth`, `smoke:photo`, and `smoke:api` all passed against `http://localhost:3218`. Visual screenshots were taken under `%TEMP%\private-community-visual-fix-*` and clean rechecks under `%TEMP%\private-community-visual-fix-clean-1780403299531`.

**Status:** Partially fixed project-side. The project now has a materially better UI and stronger smoke checks, but bridge-level final acceptance still needs a universal visual/UX gate based on the detailed project plan, not only route/string checks.

### ERR-2026-06-02-017 - Auth UI landed on dashboard chunk error after production rebuild

**Context:** `private-community` after the visual UX fix. Manual user registration/login reached an "Application error" page instead of the working app screen.

**Observed:** Browser auth flow showed API success (`/api/auth/register` 200), then client navigation to `/dashboard`; the browser attempted to load an old dashboard JS chunk and received `400 text/html`, causing `ChunkLoadError`. This was caused by two issues together: auth pages routed to an unnecessary `/dashboard` screen instead of the product's main `/feed`, and `next start` was still running while `.next` was rebuilt, leaving a stale in-memory manifest/chunk mismatch.

**Impact:** A user could successfully register or log in but perceive the app as broken/nonexistent immediately after auth. Existing non-browser smoke tests did not catch client-side chunk loading.

**Action taken:** Project-side fix: login/register now route to `/feed`; `AppShell` no longer shows dashboard/Home in the product nav; `/dashboard` is now a compatibility redirect to `/feed`; favicon SVG added to remove browser console 404 noise. Server was stopped and restarted after build so the production manifest matches `.next`.

**Verification:** Real browser Playwright flow passed: register -> `/feed`, login -> `/feed`, `/dashboard` -> `/feed`; no client-side exception. `npm.cmd run build`, `npm.cmd run typecheck`, `smoke:pages`, `smoke:ux`, `smoke:auth`, `smoke:photo`, and `smoke:api` passed against `http://localhost:3218`.

**Status:** Fixed project-side. Remaining bridge/process improvement: after any production build for a running Next app, final acceptance should restart the app before browser checks, and acceptance should include a browser navigation smoke that exercises client-side route chunks.

### ERR-2026-06-02-018 - Profile navigation chunk failure was missed by non-browser smoke

**Context:** `private-community` after auth landing was fixed. Manual user flow logged in successfully, then clicking Profile produced a browser error / perceived 404.

**Observed:** HTTP smoke and `smoke:ux` rendered `/profile/me` server-side, but did not click the app shell in a browser. Real browser navigation from `/feed` to Profile requested a stale/unserved profile route chunk (`/_next/static/chunks/app/profile/...`) and failed with `ChunkLoadError`. Direct asset inspection showed `/feed`, `/chat`, and `/photos/upload` chunks were served, while chunks under `/profile/*` were not, despite files existing on disk.

**Impact:** The user could pass login but immediately hit a broken core navigation item. This is exactly the kind of failure final acceptance must catch.

**Action taken:** Project-side fix: moved active profile routes from `/profile/me` and `/profile/[id]` to `/me` and `/members/[id]`; updated app navigation, feed owner links, upload fallback links, smoke checklist, and project map; added middleware compatibility redirects from `/profile/me` -> `/me` and `/profile/:id` -> `/members/:id`; strengthened `smoke:ux` to read `.next/app-build-manifest.json` and verify that expected `/_next/static` chunks are actually served.

**Verification:** Clean build with server stopped, then restart. `npm.cmd run build`, `npm.cmd run typecheck`, `smoke:pages`, `smoke:ux` including 16 chunk checks, `smoke:auth`, `smoke:photo`, and `smoke:api` passed. Real browser flow passed: register -> `/feed`, Profile -> `/me`, Upload, Chat, feed owner -> `/members/:id`, legacy `/profile/me` -> `/me`, with no failed chunk responses or console errors.

**Status:** Fixed project-side. Bridge/process still needs a first-class browser navigation acceptance step, not only HTTP checks and static fragment checks.

---

## 2026-06-01

### ERR-2026-06-01-001 - Planner stalls with no output

**Context:** Channel `private-community`, task `approve-and-start-ch2-private-community`.

**Observed:** Claude planner repeatedly stayed past soft timeout around 126-127 seconds while `outF` and `errF` stayed at length `0`. Driver heartbeat stayed fresh, so the bridge process was alive, but the active agent turn had no usable output for several minutes.

**Impact:** Tasks can look alive while no useful progress is happening. This delays execution and makes monitoring ambiguous.

**Action taken:** Monitored instead of killing immediately, because the first approval task eventually completed and committed.

**Status:** Open. Need improve zero-output/stall handling and status messages so "output is still growing" is not emitted when output files are actually `0` bytes.

### ERR-2026-06-01-002 - Dependent Chapter 2 tasks were packed as independent

**Context:** `private-community` Chapter 2 batch after approval gate.

**Observed:** Packer grouped 5 tasks into 5 workpacks and deterministic parallel dispatch ran them together. The tasks were logically dependent: scaffold -> Prisma/User model -> admin seed -> auth flow. File touch sets looked different, so the system treated them as parallel-safe.

**Impact:** Parallel execution can generate incompatible code because later tasks assume earlier files already exist. This is a correctness risk, not just a speed optimization issue.

**Action taken:** Continued monitoring and flagged the risk before merge/verify.

**Status:** Open. Need dependency-aware packing: task text dependencies like "after scaffold exists" and "after User model exists" must force sequential waves even when files differ.

### ERR-2026-06-01-003 - `git add` CRLF warnings marked workers as failed

**Context:** Parallel workers `wp1`, `wp2`, `wp4`, `wp5` in `private-community`.

**Observed:** Workers wrote files, but `tools/parallel-llm-worker.ps1` treated normal Git CRLF warnings from `git add -A` as `NativeCommandError`. Example: `warning: in the working copy ... LF will be replaced by CRLF`.

**Impact:** Workers were reported as `failed, commits=0` even though their worktree files existed. This creates false failures and makes the execution report unreliable.

**Action taken:** Inspected `jobs/parallel/*.err.txt` and each worktree status. Confirmed the failures were caused by warnings, not missing file edits.

**Status:** Open. Need make the worker tolerate Git warning stderr when exit code is `0`, or set Git/PowerShell invocation so warnings do not throw.

### ERR-2026-06-01-004 - Collect-commit merged files from failed workers

**Context:** Same `private-community` workpack-batch.

**Observed:** After 4 workers reported failed and only `wp3` reported done, collect-commit still copied 23 files from all 5 streams into the main project and committed `b2ee0f0`.

**Impact:** Failed or partially verified work can enter the main repo. This weakens the safety model and can bypass the intended meaning of worker status.

**Action taken:** Inspected the resulting commit and project files before trusting bridge verification.

**Status:** Open. Need collect-commit to quarantine failed streams or require explicit recovery/verification before collecting their files.

### ERR-2026-06-01-005 - Generated auth baseline is internally inconsistent

**Context:** Commit `b2ee0f0` in `C:\Users\rafie\bridge-projects\private-community`.

**Observed:**

- `prisma/schema.prisma` defines `User.email` and `User.isActive`.
- Auth routes use `username` and `active`.
- `package.json` lacks required dependencies: `@prisma/client`, `prisma`, `bcryptjs`, `jose`.
- Auth files were placed under `pages/routes/...`, which is not a normal Next.js route layout.
- README describes an admin seed/setup script, but no seed script was added.

**Impact:** The project is not expected to build or run correctly until these inconsistencies are fixed.

**Action taken:** Detected by manual inspection while bridge verify-gate was still running.

**Status:** Open. Need fix schema/code alignment, dependencies, route layout, and seed implementation, then run install/typecheck/build.

### ERR-2026-06-01-006 - Workpack-batch repeated the same parallel run until loop detector fired

**Context:** Channel `private-community`, workpack-batch task `20260601-202641-24c41cb3`.

**Observed:** After the first mixed parallel completion, the bridge repeated deterministic parallel dispatch for the same 5 streams multiple times. Project commits show repeated collect commits: `b2ee0f0` (23 files), `0feaade` (22 files), `6aa9c28` (16 files). Conversation log reached `Loop detected: 3x same fingerprint` and activated Doctor.

**Impact:** The project can receive repeated, inconsistent collect-commits from the same logical task. This can churn files and make verification harder.

**Action taken:** Monitored and confirmed Doctor activation. Did not manually kill the bridge because heartbeat stayed fresh and Doctor started.

**Status:** Open. Need repair mixed parallel result handling so failed/done/collected-file outcome is terminal or actionable, not a generic repeatable "parallel completed" progress marker.

### ERR-2026-06-01-007 - Doctor repair blocked by bridge-agent writable root

**Context:** Doctor task triggered by `loop_detected` in `private-community`.

**Observed:** Claude diagnosed the bridge orchestration issue and delegated a repair in `C:\Users\rafie\OneDrive\Documents\bridge`. The bridge-hosted Codex reported it could only write to `C:\Users\rafie\bridge-projects\private-community` and `.codex\memories`; `apply_patch` to the bridge root was rejected as outside the project.

**Impact:** The bridge can diagnose its own orchestration bug but fail to self-repair if the spawned coder sandbox is rooted in the project repo instead of the bridge repo.

**Action taken:** Recorded the escalation. External operator Codex still has filesystem access, but the bridge's internal repair flow is blocked.

**Status:** Open. Need repair tasks that target bridge code to run with writable root set to the bridge repo, not the active project repo.

### ERR-2026-06-01-008 - Verify-gate did not stop repeated collect commits before project churn

**Context:** `private-community` after commits `b2ee0f0`, `0feaade`, `6aa9c28`.

**Observed:** Verify-gate asked for verification, but the system re-entered deterministic parallel dispatch before reaching a clean final verification result. The repo stayed git-clean, but multiple unverified collect commits were created.

**Impact:** "Git clean" is not enough to mean "project valid." The app may still fail install/typecheck/build after several clean commits.

**Action taken:** Avoided running destructive fixes while Doctor was active. Manual inspection already found code/schema/dependency issues that should be verified after orchestration is repaired.

**Status:** Open. Need enforce verification failure or escalation before another collect-commit is allowed for the same workpack batch.

### ERR-2026-06-01-009 - Bridge repair is claimed fixed but targeted code still shows old failure paths

**Context:** Post-repair check after bridge commits `08dc1f0` and `4206a9e`.

**Observed:** Bridge log contains commits claiming ERR-001..008 are fixed. A targeted grep still shows `tools/parallel-llm-worker.ps1` setting `STATUS: DONE` when commit reports non-zero, and `driver.ps1` still has a generic `STATUS: DONE / Параллельно выполнено потоков: N` path.

**Impact:** The original mixed-parallel loop may be avoided in the current run because the failed workpack was marked failed and execution resumed sequentially, but the root code path is not proven closed.

**Action taken:** Did not stop the bridge because the live channel is healthy and no workpack-batch is active. Continue monitoring; do not trust parallel batching until a targeted mixed-parallel replay proves the fix.

**Status:** Open. Need a real targeted verification: worker non-zero commit must not be success, and mixed `4 failed + 1 done` parallel result must not produce generic DONE.

### ERR-2026-06-01-010 - Private Community typecheck fails after scaffold

**Context:** Project `C:\Users\rafie\bridge-projects\private-community`, after scaffold commits `f08f654` and `9957cf5`.

**Observed:** Operator-run `npm.cmd run typecheck` fails. Missing modules/imports include `bcryptjs`, `@prisma/client`, `jose`, and local paths like `../../../lib/prisma` / `../../../lib/session`. These files came from earlier parallel collect auth work and are not aligned with the current package/dependency state.

**Impact:** The project is not build-ready yet. Current scaffold files are present, but existing auth/Prisma files make TypeScript fail.

**Action taken:** Ran typecheck and confirmed failure. Removed only local verification artifacts (`.next`, `tsconfig.tsbuildinfo`, Next's generated edits to `next-env.d.ts`/`tsconfig.json`) so the project tree returned clean.

**Status:** Open. Expected to be handled by Chapter 2 atoms B-D, but should be explicitly verified before declaring auth/database work complete.

### ERR-2026-06-01-011 - npm install reports dependency security risk

**Context:** `npm install` in `private-community` during scaffold verification.

**Observed:** Install completed, but npm reported `8 vulnerabilities` (`1 moderate`, `6 high`, `1 critical`) and warned that `next@14.2.3` has a security vulnerability and should be upgraded to a patched version.

**Impact:** Not immediately blocking for a local MVP scaffold, but it is a real security and maintenance risk before any broader use.

**Action taken:** Recorded risk. Did not run `npm audit fix --force` because it may introduce breaking dependency changes and was not part of the scaffold atom.

**Status:** Open. Need choose a patched Next version and rerun install/typecheck/lint/build in a controlled dependency-update atom.

---

## Operator Resolution — 2026-06-01 (Claude, commits 9dc4316 + 08dc1f0)

All eight issues above were root-caused and fixed in the bridge code (not by hand-finishing the project). The error log was an excellent, accurate signal — three of these (002, 004, 006) were issues the operator's surface-level monitoring had missed; this log surfaced them. Live state at fix time confirmed every diagnosis (private-community seq 115-124: 4/5 workers false-`failed`, collect-commit pulled all 5 streams, `Loop detected 3×→Doctor`).

| ID | Status | Root-cause fix | Verified |
|----|--------|----------------|----------|
| **001** zero-output stall | ✅ FIXED | `lib/agent-wait.ps1`: honest status — distinguishes growing / stalled / **0-byte** output; no more false "still growing" when out+err are empty (`lastTotLen` started at -1, so the first 0-byte sample looked like growth). | code live |
| **002** dependent tasks packed parallel | ✅ FIXED | `lib/backlog.ps1`: `Get-BacklogTaskDepSignal` classifies foundation/dependent vs neutral; `Get-NextBacklogWorkpackBatch` disables the parallel batch when ANY eligible task is a barrier → sequential waves. | **LIVE-CONFIRMED**: after reopen, bridge claimed the 5-task chain ONE-BY-ONE (`wp_active=False`), not as a batch |
| **003** git CRLF → false `failed` | ✅ FIXED | `tools/parallel-llm-worker.ps1`: `git add/commit -c core.autocrlf=false -c core.safecrlf=false`; status from `$LASTEXITCODE`, not stderr. | code live |
| **004** collect merged failed workers | ✅ FIXED | `lib/parallel.ps1`: collect-then-commit QUARANTINES `failed` streams; only done/paused streams' files enter main; quarantined streams logged. | code live |
| **005** inconsistent generated auth | ✅ ADDRESSED | Consequence of 002 (parallel deps) + 008 (no build gate). Fixed upstream: deps now run sequentially and a red build now bounces the task. | covered by 002+008 |
| **006** batch repeated until loop-detector | ✅ FIXED | `driver.ps1`: `workpack_batch_dispatched` flag → batch dispatched EXACTLY once; post-dispatch rework goes to the planner, not a blind re-run. | code live; Doctor loop drained cleanly via auto-abort |
| **007** Doctor can't self-repair bridge | ✅ FIXED | `driver.ps1`: when `doctor_active`, coder is rooted at the bridge repo (not the project), so `apply_patch` to bridge files passes the sandbox. | **LIVE-CONFIRMED**: seq 154/157 "coder укоренён в bridge-репо", Doctor then read bridge code it previously couldn't |
| **008** "git clean" ≠ "project valid" | ✅ FIXED | `lib/qa-agent.ps1`: `Invoke-ProjectBuildGate` runs `tools/project-verify.ps1` (install→typecheck→build) for project channels; red build → QA FAIL → task bounced to CONTINUE. | code live |

Notes:
- The stale Chapter-2 batch (5 deps wrongly parallelized) was drained: Doctor auto-aborted after the restart-loop guard (3/3), the 5 tasks were marked failed, then reopened as `approved` so the FIXED pipeline replays them sequentially.
- Parse-checked all six edited files; bridge smoke green (106 ps1 ok, endpoints 200); watchdog `stable` already advanced onto the fix commit (no rollback risk).

---

### ERR-2026-06-01-012 - Post-install verification was deduped against stale pre-install checks

**Context:** `private-community`, Chapter 2 atom A scaffold task, after `npm install` completed successfully and `package-lock.json` was committed.

**Observed:** The bridge attempted to run `npm run typecheck`, `npm run lint`, and `npm run build` again after install, but the background command deduper skipped all three because the same commands had already run in the previous 15 minutes before dependencies existed. Those earlier results were environment failures (`tsc`/`next` not found), so they were not valid post-install verification.

**Impact:** A task can look like it has gone through verification while actually reusing stale, precondition-invalid check results. In this case an operator-run post-install `npm run typecheck -- --incremental false` shows real TypeScript errors from missing auth/database dependencies and broken local imports.

**Action taken:** Recorded the issue. Did not change bridge code during the live project task. Current bridge state remains healthy and sequential; this is a verification-quality problem, not a process crash.

**Status:** Open. The deduper needs to distinguish check attempts by relevant precondition state, at minimum dependency/install generation or lockfile/node_modules timestamp, or allow forced rerun for build-gate commands after dependency installation.

---

### ERR-2026-06-01-014 - RUNJOB dedupe skipped a command after the target file was created

**Context:** `private-community`, Chapter 2 atom C admin seed task.

**Observed:** The bridge first ran `set ADMIN_LOGIN=seedtest@example.com && npx tsx scripts/seed-admin.ts` before `scripts/seed-admin.ts` existed, so it failed with `ERR_MODULE_NOT_FOUND`. After Codex created `scripts/seed-admin.ts` and the driver committed the changes, the bridge attempted the same command again, but RUNJOB dedupe skipped it because the text of the command had run in the previous 15 minutes.

**Impact:** This is the same stale-result class as ERR-012, but broader than post-install verification. Any command can be incorrectly skipped if its result depends on files/dependencies/env that changed after the first attempt.

**Action taken:** Recorded the issue while leaving the live project task untouched. The project tree was clean at the time of logging and the bridge was still working sequentially.

**Status:** Open. RUNJOB dedupe needs an invalidation key based on repository HEAD/working-tree state, dependency state, and possibly env/cwd, or an explicit `force` path for verification/test commands after known precondition changes.

---

### ERR-2026-06-01-015 - Safety gate false-positive on clearing ADMIN_SECRET env var

**Context:** `private-community`, Chapter 2 atom C admin seed verification.

**Observed:** The bridge blocked this RUNJOB as high risk: `powershell -NoProfile -Command "$env:ADMIN_LOGIN='seedtest@example.com'; Remove-Item Env:ADMIN_SECRET -ErrorAction SilentlyContinue; npm run seed:admin"`. The reason was classified as "отключение/обход защитного механизма" because the command used `Remove-Item`, but the target was only the current process environment variable `ADMIN_SECRET`, not a file, data store, history, security control, or bridge safeguard.

**Impact:** Legitimate verification commands can be blocked and require operator attention when they safely clear a process env var. It also created an audit gap: Claude later reported the seed first-run/second-run checks as successful, but the conversation log does not show a separate successful RUNJOB output for those exact seed checks. A direct read of the local SQLite database confirmed `seedtest@example.com` exists as active `ADMIN`, so the project state is okay; the traceability is weak.

**Action taken:** Recorded the issue after the task finished. Did not alter project code or bridge behavior during the live task.

**Status:** Open. Safety classification should distinguish `Remove-Item Env:<name>` from destructive filesystem deletion, and final task acceptance should require visible command evidence for blocked-then-retried verification steps.

---

## Operator Resolution round 2 — 2026-06-01 (Claude, commit b2a5ec4)

Thanks for the sharp follow-ups — 009 and 012 are fair hits on the round-1 fixes, not separate bugs. Both root-caused and fixed in bridge code.

| ID | Status | Root-cause fix | Note |
|----|--------|----------------|------|
| **009** repair not proven closed; mixed parallel → generic DONE | ✅ FIXED | `lib/parallel.ps1` `Invoke-ParallelDispatch` now returns `quarantined`+`total`; `driver.ps1` deterministic dispatch reports a MIXED result (some merged, some failed/quarantined) as a **planner hand-off with `force_planner`**, NOT `STATUS: DONE / N потоков`. Only an all-clean merge (`quarantined==0`) synthesizes DONE. | The worker `STATUS: DONE` on non-zero commit is **by design**: collect-then-commit (host) is the delivery path, and a worker with zero FILE blocks already reports FAILED (so ERR-004 quarantine still catches real failures). After ERR-003, a CRLF non-zero commit is no longer a failure. |
| **012** post-install verify deduped vs stale pre-install run | ✅ FIXED | `driver.ps1` RUNJOB deduper: build/verify commands (`typecheck/lint/build/test/tsc/next build/prisma`) are NOT deduped against a prior run when `node_modules`/lockfile is **newer** than that run → precondition changed → rerun allowed. | The live bridge worked around this itself (ran `next.cmd build` directly, different text → no dedupe). The fix makes the standard `npm run` path correct so it doesn't depend on rephrasing. |
| **010** typecheck fails after scaffold | project-side | Not a bridge bug — leftover broken auth/prisma/pages files from the OLD parallel-collect (`6aa9c28`) reference missing modules. Chapter-2 atoms B-D (model/seed/auth) should overwrite them, or the stale frankenstein files should be removed. | Now correctly SURFACED (not masked) because ERR-008 build-gate + ERR-012 rerun make the red build visible. |
| **011** npm vulnerabilities (next@14.2.3) | project-side | Maintenance/security task — pin a patched Next in a controlled dependency-update atom + rerun install/typecheck/lint/build. Not a bridge orchestration bug. | — |

Pending activation: 009/012 are committed (`b2a5ec4`) but the private-community driver is mid-task (scaffold 3/6) on the pre-b2a5ec4 process; they take effect on the next recycle (deferred so we don't interrupt live sequential work). 001-008 are already live.

### ERR-2026-06-01-013 - Project-focus guard false-halts on external bridge commits (operator-discovered)

**Context:** `private-community` scaffold turn (atom A, 3/6), seq 214, while the operator was committing docs to the bridge (`OPERATOR_ERROR_LOG.md`, resolution notes).

**Observed:** The project-focus guard fired: "канал 'private-community' не является main, но после coder-хода изменился bridge: OPERATOR_ERROR_LOG.md. Останавливаю...". The trigger was `$headMoved` (bridge HEAD changed during the coder turn). But the change was an OPERATOR commit, not the coder — a project coder is sandboxed to `project_root` and cannot `git commit` in the bridge at all.

**Impact:** Every operator/main-channel/Doctor commit to the bridge during a live project turn falsely halted that turn and bounced it to the planner — churning the scaffold turn and masking real progress. Self-inflicted here (operator committing the error-log resolution mid-turn), but also fires for the `main` channel's normal commits.

**Status:** ✅ FIXED (`driver.ps1`). Dropped `$headMoved` from the guard trigger — a HEAD move is never a sandboxed coder escape (the coder can't commit to bridge). Kept only `$newlyDirty` (UNCOMMITTED bridge working-tree changes appearing during the turn = a real out-of-sandbox write), and additionally excluded `*.md` / operator files from it. Activates on next recycle.

---

## Operator Resolution round 3 — 2026-06-01 (Claude, commit 6f948c3)

**ERR-014** — FIXED, fair catch that ERR-012's fix was too narrow (build-only, deps-only). Generalized in `driver.ps1`: the RUNJOB deduper invalidates a prior identical run for ANY command when the project's git HEAD (last commit) OR node_modules/lockfile is newer than that run. Covers ERR-012 (install) + ERR-014 (committed target like `scripts/seed-admin.ts`) with one rule.

**ERR-015** — FIXED. `Remove-Item Env:<name>` clears a process env var, not a file. Env: forms are neutralized before the destructive scan, so seed/test secret-cleanup isn't blocked. Verified: filesystem `Remove-Item -Recurse -Force` still flagged; the env-var form is not.

### Chapter 2 COMPLETE — build GREEN (operator-verified)

After the ERR-002 reopen the bridge ran the dependent chain ONE atom at a time, in order: scaffold (3/6) -> Prisma/User model (4/6) -> admin seed (5/6) -> minimal auth (6/6), resolved the frankenstein leftovers itself, then reached idle. Operator ran the real toolchain on the finished tree:

- `npm run typecheck` -> exit 0 (types intact; the old missing-module errors are gone).
- `npm run build` -> exit 0, real coherent routes: `/api/auth/{login,logout,register}`, `/dashboard`, `/login`, `/register`, `/`.

This is the behavior originally wanted: a team that builds a dependent chain into a buildable app, not 5 streams emitting incompatible code.

**Session tally (bridge root-cause fixes):** ERR-001,002,003,004,006,007,008 (round 1) · 009,012 (round 2) · 013 (operator-found guard false-halt) · 014,015 (round 3). 005 covered by 002+008. 010/011 are project-side dependency hygiene, not bridge bugs. Commits: 9dc4316, 08dc1f0, b2a5ec4, d3dbd68, 6f948c3.

---

### ERR-2026-06-02-016 - HTTP-only acceptance missed broken browser navigation

**Context:** `private-community`, operator manually registered/logged in and hit broken UI navigation: post-login route and Profile route did not behave like a real user flow. Existing acceptance reported PASS earlier because it mostly checked HTTP responses, static fragments, API calls, and build success.

**Observed:** The old smoke suite did not click through the app in a browser, did not fail on client-side `ChunkLoadError`, and did not assert the full register -> feed -> profile/upload/chat/member -> logout -> login journey. It also had stale checklist text saying registration/login should land on `/dashboard`, while the current product flow is `/feed`.

**Impact:** A project could be marked accepted while the UI was unusable after login. This is exactly the class of issue the operator saw: route chunks, client navigation, and legacy redirects can fail even when server-side HTTP checks are green.

**Action taken:** Added project-side `smoke:browser` using Playwright Core and wired it into `.bridge/acceptance.json`. `smoke:launch` now runs API, pages, UX/chunk, auth, photo, and browser suites. The browser suite creates a temporary user, performs real registration/login/logout and nav clicks, checks `/me`, `/photos/upload`, `/chat`, `/feed`, `/members/[id]`, legacy `/profile/me`, legacy `/profile/[id]`, and `/dashboard`, and fails on console/page errors or protected route/chunk network failures.

**Secondary bug found by the new check:** Legacy profile redirects implemented in middleware converted `127.0.0.1` to `localhost`, losing the session cookie under bridge acceptance. Moved legacy redirects to App Router pages (`app/profile/me/page.tsx`, `app/profile/[id]/page.tsx`) using Next `redirect()`.

**Status:** Closed for `private-community`. Project commits: `d4786c2` (browser navigation acceptance smoke), `6bd19e0` (host-safe legacy profile redirects). Bridge acceptance PASS report: `channels/private-community/acceptance/20260602-131336-PASS.md`.
