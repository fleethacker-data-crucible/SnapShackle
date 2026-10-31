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
  export copies each PNG and its .meta.json sidecar into -OutDir and writes handoff.json there. An existing file in
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
$script:HandoffSchema = 'snapshackle.handoff/1'
$script:NamePattern = '(?:SnapShackle|CutterMk|Lasso|SnipHero)-[a-zA-Z0-9_.-]+\.png'

function Stop-Usage([string]$Message) { [Console]::Error.WriteLine('handoff: ' + $Message); exit 2 }
function Stop-Failed([string]$Message) { [Console]::Error.WriteLine('handoff: ' + $Message); exit 1 }
function Get-Sha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ((($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

if (-not $Library) { $Library = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'SnapShackle\Captures' } else { Join-Path $root 'captures' } }
if ($Max -lt 1 -or $Max -gt 250) { Stop-Usage '-Max must be between 1 and 250' }
if (-not [IO.Directory]::Exists($Library)) { Stop-Failed ('the capture folder was not found: ' + $Library) }
$library = [IO.Path]::GetFullPath($Library)
$sinceDate = $null
if ($Since) { try { $sinceDate = [datetime]::Parse($Since, [Globalization.CultureInfo]::InvariantCulture) } catch { Stop-Usage ('-Since is not a date: ' + $Since) } }
$wanted = @($Name | Where-Object { $_ })
foreach ($n in $wanted) { if ($n -notmatch ('^' + $script:NamePattern + '$')) { Stop-Usage ('not a capture name: ' + $n) } }
if ($Mode -eq 'export') {
    if (-not $OutDir) { Stop-Usage 'export needs -OutDir' }
    $out = [IO.Path]::GetFullPath($OutDir)
    if ($out.TrimEnd('\') -ieq $library.TrimEnd('\') -or $out.StartsWith($library.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { Stop-Usage '-OutDir must not be the capture folder or inside it' }
}

# Newest first, same rules as the library (name pattern, search over name, tags, note and OCR text).
# The function returns one array object (return ,$array); wrapping it in @() would nest it.
[object[]]$items = Get-SnapShackleCaptureList $library $Query $script:NamePattern
if ($Tag) { $items = @($items | Where-Object { @($_.tags) -contains $Tag }) }
if ($sinceDate) { $items = @($items | Where-Object { [datetime]::Parse($_.modified, [Globalization.CultureInfo]::InvariantCulture) -ge $sinceDate }) }
if ($wanted.Count -gt 0) { $items = @($items | Where-Object { $wanted -contains $_.name }) }
$items = @($items | Select-Object -First $Max)

$entries = foreach ($item in $items) {
    $meta = Get-SnapShackleMeta $library $item.name
    $png = Join-Path $library $item.name
    $entry = [ordered]@{
        name = $item.name; file = $item.name; bytes = [long]$item.bytes; modified = $item.modified
        sha256 = (Get-Sha256 $png); tags = @($meta.tags); note = [string]$meta.note
        sidecar = [IO.File]::Exists((Get-SnapShackleMetaPath $library $item.name)); ocrChars = ([string]$meta.ocr).Length
    }
    if ($IncludeText) { $entry.ocr = [string]$meta.ocr }
    $entry
}
$entries = @($entries)

if ($Mode -eq 'list') {
    if ($Json) {
        ConvertTo-Json -InputObject ([ordered]@{ schema = $script:HandoffSchema; source = 'SnapShackle'; count = $entries.Count; captures = $entries }) -Depth 6
    } else {
        if ($entries.Count -eq 0) { Write-Host 'No captures match.' }
        else { $entries | ForEach-Object { '{0}  {1,9} bytes  {2}  tags: {3}  text: {4} chars' -f $_.name, $_.bytes, $_.modified.Substring(0, 19), (@($_.tags) -join ','), $_.ocrChars } }
    }
    exit 0
}

# export
$copied = New-Object System.Collections.Generic.List[object]
$skipped = New-Object System.Collections.Generic.List[object]
if (-not $DryRun) { [void][IO.Directory]::CreateDirectory($out) }
foreach ($e in $entries) {
    $target = Join-Path $out $e.name
    if ([IO.File]::Exists($target)) { $skipped.Add([ordered]@{ name = $e.name; reason = 'a file with that name is already in the output folder' }); continue }
    if (-not $DryRun) {
        [IO.File]::Copy((Join-Path $library $e.name), $target, $false)
        if ($e.sidecar) { [IO.File]::Copy((Get-SnapShackleMetaPath $library $e.name), ($target + '.meta.json'), $false) }
    }
    $copied.Add($e)
}
$manifest = [ordered]@{ schema = $script:HandoffSchema; source = 'SnapShackle'; createdAt = (Get-Date).ToString('o'); count = $copied.Count; captures = $copied.ToArray(); skipped = $skipped.ToArray() }
if (-not $DryRun) {
    $manifestPath = Join-Path $out 'handoff.json'
    $tmp = $manifestPath + '.tmp'
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $manifest -Depth 6), [Text.UTF8Encoding]::new($false))
    if ([IO.File]::Exists($manifestPath)) { [IO.File]::Delete($manifestPath) }
    [IO.File]::Move($tmp, $manifestPath)
}
if ($Json) { ConvertTo-Json -InputObject (@{ dryRun = [bool]$DryRun; copied = $copied.Count; skipped = $skipped.Count; manifest = $(if ($DryRun) { $null } else { 'handoff.json' }) }) -Compress }
else { Write-Host ($(if ($DryRun) { 'Would copy ' } else { 'Copied ' }) + $copied.Count + ' capture(s) to ' + $out + '; skipped ' + $skipped.Count + '.') }
exit 0
