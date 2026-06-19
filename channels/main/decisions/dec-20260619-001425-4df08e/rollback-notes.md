# Rollback Notes

Task: relocate DONE action-evidence admission from `driver/85-loop-mode-transitions.ps1` to `driver/86-loop-completion-checks.ps1`.

Rollback plan:

1. If this change is the current HEAD, run:

   ```powershell
   git -C "C:\Users\rafie\OneDrive\Documents\bridge" revert HEAD
   ```

2. If a later commit has landed, revert the specific commit created for this task:

   ```powershell
   git -C "C:\Users\rafie\OneDrive\Documents\bridge" revert <commit-sha>
   ```

3. Re-run the required safety gates:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\driver.ps1" -SelfTest
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\smoke.ps1"
   ```

4. Create a fresh apply restart stamp and `control\restart.flag` only after the revert diff passes ParseFile and smoke.
