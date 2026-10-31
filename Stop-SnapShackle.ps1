<#
.SYNOPSIS
  Stops every running SnapShackle on this computer: server, tray icon and global hotkeys.
.DESCRIPTION
  SnapShackle normally stops itself when its studio tab closes, from End session in the studio, or from
  Exit in the tray menu. This is the fallback when none of those is at hand (a hidden console,
  a -Stay instance without its tray, an old build). It needs no PIDs: it reads the runtime files
  SnapShackle writes to %LOCALAPPDATA%\SnapShackle\logs, then looks for any PowerShell running Start-SnapShackle.ps1.
  Each one is asked to stop so it can remove its tray icon and release its hotkeys; one that does
  not answer within a few seconds is force-stopped. Stale runtime files are removed.
.PARAMETER DataDir
  Look for runtime files under this data folder (the one a run with -DataDir used) instead of %LOCALAPPDATA%.
.PARAMETER Quiet
  Print nothing unless something was stopped.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File Stop-SnapShackle.ps1
#>
[CmdletBinding()]
param([switch]$Quiet, [string]$DataDir)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'modules/Lifecycle.ps1')
[void](Set-SnapShackleDataRoot $DataDir)
# Also %LOCALAPPDATA%\CutterMk\logs, so an instance started by a CutterMk build before the rename is stopped too.
$stopped = @(Stop-SnapShackleProcesses @((Get-SnapShackleRuntimeDir $root), (Get-SnapShackleLegacyRuntimeDir)))
if ($stopped.Count -gt 0) {
    foreach ($id in $stopped) { Write-Host ('Stopped SnapShackle PID ' + $id + '.') -ForegroundColor Yellow }
} elseif (-not $Quiet) {
    Write-Host 'No SnapShackle is running.' -ForegroundColor DarkGray
}
