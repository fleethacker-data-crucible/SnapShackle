<#
.SYNOPSIS
  Stops every running CutterMk on this computer: server, tray icon and global hotkeys.
.DESCRIPTION
  CutterMk normally stops itself when its studio tab closes, from End session in the studio, or from
  Exit in the tray menu. This is the fallback when none of those is at hand (a hidden console,
  a -Stay instance without its tray, an old build). It needs no PIDs: it reads the runtime files
  CutterMk writes to %LOCALAPPDATA%\CutterMk\logs, then looks for any PowerShell running Start-CutterMk.ps1.
  Each one is asked to stop so it can remove its tray icon and release its hotkeys; one that does
  not answer within a few seconds is force-stopped. Stale runtime files are removed.
.PARAMETER Quiet
  Print nothing unless something was stopped.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File Stop-CutterMk.ps1
#>
[CmdletBinding()]
param([switch]$Quiet)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'modules/Lifecycle.ps1')
$stopped = @(Stop-CutterMkProcesses (Get-CutterMkRuntimeDir $root))
if ($stopped.Count -gt 0) {
    foreach ($id in $stopped) { Write-Host ('Stopped CutterMk PID ' + $id + '.') -ForegroundColor Yellow }
} elseif (-not $Quiet) {
    Write-Host 'No CutterMk is running.' -ForegroundColor DarkGray
}
