@echo off
setlocal
rem CutterMk launcher for approved Windows environments.
rem -ExecutionPolicy Bypass applies ONLY to this PowerShell process.
rem It does not change the machine policy, require admin rights,
rem or override Group Policy, AppLocker, WDAC, or enterprise controls.
rem Closing the studio tab stops CutterMk (server, tray icon and hotkeys). Options are passed through:
rem   --stay      keep CutterMk in the tray with its hotkeys after the tab closes (Exit in the tray menu)
rem   --replace   if CutterMk is already running, stop it and start fresh without asking
rem   -NoBrowser, -Port 9000, -Diagnostics, -NoTray
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL%" (
  echo [CutterMk] Windows PowerShell 5.1 was not found.
  pause
  exit /b 1
)
echo [CutterMk] Starting local-only studio, process-scoped PowerShell policy.
echo [CutterMk] Existing local applications and their ports will not be disturbed.
"%POWERSHELL%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Start-CutterMk.ps1" %*
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
  echo.
  echo [CutterMk] Startup failed ^(exit code %RESULT%^).
  echo [CutterMk] Check the error above. Organization policy may restrict scripts even with a process-level switch.
  pause
)
exit /b %RESULT%