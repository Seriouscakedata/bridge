@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bridge.ps1" %*
exit /b %ERRORLEVEL%
