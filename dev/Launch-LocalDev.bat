@echo off
setlocal EnableExtensions DisableDelayedExpansion
rem Development-only launcher. Not included in release zips.
cd /d "%~dp0.." || exit /b 1
where powershell.exe >nul 2>&1 || (echo Windows PowerShell 5.1 is required. & exit /b 1)
echo [SNAPSHACKLE LOCAL DEV] Local browser studio; no CAC or cloud connection.
echo Do not capture sensitive material on an unapproved system.
rem -Replace: stop any running SnapShackle first (it says which PID it stopped), so a dev run always serves this code.
powershell.exe -NoProfile -NoLogo -STA -File "%~dp0..\Start-SnapShackle.ps1" -Port 8790 -Replace %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
