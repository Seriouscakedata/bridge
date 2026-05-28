@echo off
setlocal
if /I "%~1"=="replay" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\replay-cli.ps1" %2 %3 %4 %5 %6 %7 %8 %9
  exit /b %ERRORLEVEL%
)
echo Unknown subcommand: %~1
echo Available: replay
exit /b 1
