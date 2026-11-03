<#
  Hand-off helper: lists SnapShackle captures, or copies chosen ones to a folder with a manifest, for the apps that
  take screenshots from SnapShackle (Bowerbird renames them from their text; Capstan and Scrimshaw import them).
  It reads the capture folder directly (no SnapShackle needs to be running, no network) and never changes a capture.

    powershell -NoProfile -ExecutionPolicy Bypass -File tools\handoff.ps1 -Mode list   [-Query text] [-Tag name] [-Since 2026-10-01] [-Name a.png,b.png] [-IncludeText] [-Json]
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\handoff.ps1 -Mode export -OutDir C:\handoff [same filters] [-IncludeText] [-DryRun]

  -Library        Capture folder (default %LOCALAPPDATA%\SnapShackle\Captures).
  -Max            Most captures to list or export (default 200, at most 250: the library list's own limit).
  -IncludeText    Put the OCR text of each capture in the output / manifest (otherwise only its length).
  -Json           List as one JSON document (schema snapshackle.handoff/1) instead of a table.
  export copies each PNG and its .meta.json sidecar into -OutDir and writes handoff.json there (an earlier
  handoff.json keeps its entries; each run adds only its own captures). An existing file in
  -OutDir is never overwritten: it is reported as skipped. -DryRun reports what would be copied and writes nothing.
  Exit codes: 0 done, 1 failed, 2 wrong arguments.
#>
param(
    [ValidateSet('list', 'export')][string]$Mode = 'list',
    [string]$Library,
    [string]$OutDir,
    [string]$Query,
    [string]$Tag,
    [string]$Since,
    [string[]]$Name,
    [int]$Max = 200,
    [switch]$IncludeText,
    [switch]$Json,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'modules\Library.ps1')
. (Join-Path $root 'modules\Handoff.ps1')

$result = Invoke-SnapShackleHandoff -Mode $Mode -Library $Library -OutDir $OutDir -Query $Query -Tag $Tag -Since $Since -Name $Name -Max $Max -IncludeText:([bool]$IncludeText) -DryRun:([bool]$DryRun) -Root $root
if (-not $result.Ok) { [Console]::Error.WriteLine('handoff: ' + $result.Error); exit $result.Exit }
if ($result.Mode -eq 'list') {
    if ($Json) { ConvertTo-Json -InputObject $result.Document -Depth 6 }
    else {
        if (@($result.Entries).Count -eq 0) { Write-Host 'No captures match.' }
        else { $result.Entries | ForEach-Object { '{0}  {1,9} bytes  {2}  tags: {3}  text: {4} chars' -f $_.name, $_.bytes, $_.modified.Substring(0, 19), (@($_.tags) -join ','), $_.ocrChars } }
    }
    exit 0
}
if ($Json) { ConvertTo-Json -InputObject $result.Summary -Compress }
else { Write-Host ($(if ($result.DryRun) { 'Would copy ' } else { 'Copied ' }) + $result.Copied + ' capture(s) to ' + $result.OutDir + '; skipped ' + $result.Skipped + '.') }
exit 0
