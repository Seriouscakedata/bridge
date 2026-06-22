# Rollback Notes

Task: `bf6ab48ff3c2495a95cd77ee15f638ad`

Scope:
- `lib/jobs.ps1`
- `tools/test-jobs-timeout.ps1`
- `driver.ps1`

Pre-change baseline: `691b85e`

Rollback procedure, executable outside the patched bridge runtime:

1. Stop new autonomous bridge work from the operator console if the canary reports hangs, failed `driver.ps1 -SelfTest`, failed `smoke.ps1`, or missing job output.
2. From `C:\Users\rafie\OneDrive\Documents\bridge`, run:

   ```powershell
   git -c safe.directory='C:/Users/rafie/OneDrive/Documents/bridge' restore --source 691b85e -- lib/jobs.ps1 tools/test-jobs-timeout.ps1 driver.ps1
   ```

3. Verify the rollback syntax:

   ```powershell
   powershell -NoProfile -Command "$files=@('lib\jobs.ps1','tools\test-jobs-timeout.ps1','driver.ps1'); foreach($f in $files){$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f).Path,[ref]$t,[ref]$e)|Out-Null;if($e.Count){throw \"Parse failed: $f\"}}"
   ```

4. Commit the rollback:

   ```powershell
   git -c safe.directory='C:/Users/rafie/OneDrive/Documents/bridge' add lib/jobs.ps1 tools/test-jobs-timeout.ps1 driver.ps1
   git -c safe.directory='C:/Users/rafie/OneDrive/Documents/bridge' commit -m "revert(jobs): rollback native reader cleanup canary"
   ```

5. Create the normal bridge restart stamp and `control\restart.flag` only after the rollback commit verifies, because the rollback touches `.ps1` control-plane files.

Expected restored behavior:
- Bridge returns to the `691b85e` native job runner behavior.
- The new runtime regression is removed from `driver.ps1 -SelfTest`.
- Previous watchdog rollback rails can operate without depending on the patched native cleanup path.
