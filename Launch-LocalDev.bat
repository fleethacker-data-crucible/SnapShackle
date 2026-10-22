@echo off
setlocal EnableExtensions DisableDelayedExpansion
cd /d "%~dp0" || exit /b 1
where powershell.exe >nul 2>&1 || (echo Windows PowerShell 5.1 is required. & exit /b 1)
echo [SNIPHERO LOCAL DEV] Local browser studio; no CAC or cloud connection.
echo Do not capture sensitive material on an unapproved system.
powershell.exe -NoProfile -NoLogo -STA -File "%~dp0Start-SnipHero.ps1" -Port 8790 %*
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" pause
exit /b %RC%
