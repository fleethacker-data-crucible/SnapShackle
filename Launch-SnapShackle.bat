@echo off
setlocal
rem SnapShackle launcher for approved Windows environments.
rem -ExecutionPolicy Bypass applies ONLY to this PowerShell process.
rem It does not change the machine policy, require admin rights,
rem or override Group Policy, AppLocker, WDAC, or enterprise controls.
rem Closing the studio tab stops SnapShackle (server, tray icon and hotkeys). Options are passed through:
rem   --stay      keep SnapShackle in the tray with its hotkeys after the tab closes (Exit in the tray menu)
rem   --replace   if SnapShackle is already running, stop it and start fresh without asking
rem   -NoBrowser, -Port 9000, -Diagnostics, -NoTray
set "POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL%" (
  echo [SnapShackle] Windows PowerShell 5.1 was not found.
  pause
  exit /b 1
)
echo [SnapShackle] Starting local-only studio, process-scoped PowerShell policy.
echo [SnapShackle] Existing local applications and their ports will not be disturbed.
"%POWERSHELL%" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Start-SnapShackle.ps1" %*
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
  echo.
  echo [SnapShackle] Startup failed ^(exit code %RESULT%^).
  echo [SnapShackle] Check the error above. Organization policy may restrict scripts even with a process-level switch.
  pause
)
exit /b %RESULT%