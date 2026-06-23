# OKO e5 integration smoke evidence

Task: `oko-e5-integration-smoke`
Date: 2026-06-23

Implemented in external repo:

- Repo: `C:\Users\rafie\bridge-projects\oko`
- Commit: `943fa51 test(integration): autotrain end-to-end pipeline smoke`
- File: `tests/test_autotrain_integration.py`

Observed checks:

```text
git -C C:\Users\rafie\bridge-projects\oko show --stat --oneline --name-only 943fa51
943fa51 test(integration): autotrain end-to-end pipeline smoke
tests/test_autotrain_integration.py
```

```text
Select-String -Path C:\Users\rafie\bridge-projects\oko\tests\test_autotrain_integration.py -Pattern 'assert ' | Measure-Object
Count: 11
```

Driver RUNJOB completed with exit code 0 after copy, focused integration test,
external commit, and final suite run.

```text
python -m pytest tests/ -v --tb=short
432 passed in 7.13s
```

Additional sandbox note:

Direct Codex reruns of pytest from the sandbox hit ACL failures creating pytest
temporary directories under `C:\Users\rafie\AppData\Local\Temp\pytest-of-rafie`
and `C:\tmp`; this is an execution-environment permission issue, not a test
failure. The driver RUNJOB above ran in the normal project environment and
passed.
