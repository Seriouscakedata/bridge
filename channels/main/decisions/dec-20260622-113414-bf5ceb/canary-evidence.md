# Canary Evidence

Task: `bf6ab48ff3c2495a95cd77ee15f638ad`

Patched files:
- `lib/jobs.ps1`
- `tools/test-jobs-timeout.ps1`
- `driver.ps1`

Baseline before patch: `691b85e`

Implementation note:
- Reader cleanup now uses a single shared `ReaderJoinTimeoutMs=5000` deadline after process exit/timeout.
- Recovery terminates the Job Object before reader joins, then on reader deadline uses `CancelSynchronousIo` for the registered native reader thread before closing the read handle.
- `Thread.Abort` is not used.

Sandbox note:
- Direct `git add` / `git commit` from the Codex sandbox failed because this worktree's `.git` points to `C:\Users\rafie\.bridge-runtime\bridge-git`, outside the writable sandbox roots.
- The bridge driver auto-commit path is expected to create the final commit from the same working tree after this turn.

Checks run from `C:\Users\rafie\OneDrive\Documents\bridge`:

```text
Parser.ParseFile:
OK lib\jobs.ps1
OK tools\test-jobs-timeout.ps1
OK driver.ps1
```

```text
tools\test-jobs-timeout.ps1:
RESULT: 26 PASS, 0 FAIL
```

```text
driver.ps1 -SelfTest:
driver pinned to channel: claude
DRIVER SELFTEST OK
```

```text
tools\self_model_smoke.ps1:
{"testPassed":true,"packBytes":2707,"registryUnchanged":true,"stateUnchanged":true,"runtimeCacheUnchanged":true,"memoryMapUnchanged":true,"activeChannelUnchanged":true,"channelBacklogUnchanged":true,"modulesSection":true,"ideaSourcesSection":true,"deliveryModeScanned":true,"selfModelScanned":true,"ownerFileHits":2}
```

```text
smoke.ps1:
SMOKE OK (585 ps1 ok, endpoints 200)
```
