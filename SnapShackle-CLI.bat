@echo off
rem SnapShackle command line. Same process-scoped policy as Launch-SnapShackle.bat; nothing is installed.
rem   SnapShackle-CLI.bat commands
rem   SnapShackle-CLI.bat <noun> <verb> [--option value ...] [--json] [--out file] [--yes] [--dry-run]
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
"%POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0snapshackle.ps1" %*
exit /b %ERRORLEVEL%
