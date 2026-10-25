<#
.SYNOPSIS
  Stops every running Lasso on this computer: server, tray icon and global hotkeys.
.DESCRIPTION
  Lasso normally stops itself when its studio tab closes, from End session in the studio, or from
  Exit in the tray menu. This is the fallback when none of those is at hand (a hidden console,
  a -Stay instance without its tray, an old build). It needs no PIDs: it reads the runtime files
  Lasso writes to %LOCALAPPDATA%\Lasso\logs, then looks for any PowerShell running Start-Lasso.ps1.
  Each one is asked to stop so it can remove its tray icon and release its hotkeys; one that does
  not answer within a few seconds is force-stopped. Stale runtime files are removed.
.PARAMETER Quiet
  Print nothing unless something was stopped.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File Stop-Lasso.ps1
#>
[CmdletBinding()]
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'modules/Lifecycle.ps1')
$stopped = @(Stop-LassoProcesses (Get-LassoRuntimeDir $root))
if ($stopped.Count -gt 0) {
    foreach ($id in $stopped) { Write-Host ('Stopped Lasso PID ' + $id + '.') -ForegroundColor Yellow }
} elseif (-not $Quiet) {
    Write-Host 'No Lasso is running.' -ForegroundColor DarkGray
}
