# Share destinations. Everything stays on this computer or on a folder the person names:
#   folder     copy the capture into a configured folder (a OneDrive or SharePoint sync folder, an SMB share, a USB drive)
#   clipboard  put the capture on the clipboard as a file, so Ctrl+V pastes it as an attachment in Outlook, Teams or Slack
#   reveal     show the capture in Explorer
#   open       open the capture in the default image app
# No network calls, no tokens, no uploads from SnapShackle itself: a cloud service only sees a file after its own
# desktop app (OneDrive, Teams, ...) picks it up. A folder is never created or cleared, and a copy never overwrites.
$script:SnapShackleShareKinds = @('folder', 'clipboard', 'reveal', 'open')
$script:SnapShackleMaxShareFolders = 8

# Returns the folder path in a clean form, or $null when it is not a plain drive-letter or UNC folder path.
function ConvertTo-SnapShackleSharePath($Value) {
    $text = ([string]$Value).Trim().Trim('"')
    if ($text.Length -lt 3 -or $text.Length -gt 260) { return $null }
    if ($text -match '[<>"|?*\x00-\x1f]') { return $null }
    $drive = $text -match '^[A-Za-z]:[\\/]'
    $unc = $text -match '^\\\\[^\\/.?][^\\/?]*[\\/][^\\/]+'
    if (-not ($drive -or $unc)) { return $null }
    # Device paths (\\.\ and \\?\) were refused above by the UNC pattern; a drive path must not climb out of itself either.
    foreach ($part in ($text -split '[\\/]')) { if ($part -eq '..' -or $part -eq '.') { return $null } }
    $clean = $text.Replace('/', '\')
    if ($clean.Length -gt 3) { $clean = $clean.TrimEnd('\') }
    return $clean
}
# Name 1-40 chars of letters, digits, space, dot, dash, underscore. Returns $null if unusable.
function ConvertTo-SnapShackleShareName($Value) {
    $name = (([string]$Value) -replace '[^A-Za-z0-9 ._-]', '').Trim()
    if ($name.Length -gt 40) { $name = $name.Substring(0, 40).Trim() }
    if ($name.Length -eq 0 -or $name -in @('clipboard', 'reveal', 'open')) { return $null }
    return $name
}
# Keeps at most 8 { name, path } pairs, drops anything unusable and later duplicates of a name.
function ConvertTo-SnapShackleShareFolders($Value) {
    $folders = [Collections.Generic.List[object]]::new()
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }
        $name = ConvertTo-SnapShackleShareName $item.name
        $path = ConvertTo-SnapShackleSharePath $item.path
        if ($null -eq $name -or $null -eq $path) { continue }
        if (@($folders | Where-Object { $_.name -ieq $name }).Count -gt 0) { continue }
        $folders.Add([ordered]@{ name = $name; path = $path })
        if ($folders.Count -ge $script:SnapShackleMaxShareFolders) { break }
    }
    return ,$folders.ToArray()
}
function Get-SnapShackleShareDestinations($Settings) {
    $items = [Collections.Generic.List[object]]::new()
    foreach ($folder in @($Settings.shareFolders)) {
        if ($null -eq $folder) { continue }
        $items.Add([ordered]@{ kind = 'folder'; name = [string]$folder.name; path = [string]$folder.path
            available = [bool](Test-Path -LiteralPath ([string]$folder.path) -PathType Container -ErrorAction SilentlyContinue) })
    }
    foreach ($kind in @('clipboard', 'reveal', 'open')) { $items.Add([ordered]@{ kind = $kind; name = $kind; path = ''; available = $true }) }
    return ,$items.ToArray()
}
# First free name in the folder: NAME.png, then NAME (2).png, NAME (3).png. Never overwrites.
function Get-SnapShackleFreeName([string]$Folder, [string]$Name) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($Name); $ext = [IO.Path]::GetExtension($Name)
    $candidate = $Name; $n = 2
    while ([IO.File]::Exists((Join-Path $Folder $candidate))) {
        $candidate = $stem + ' (' + $n + ')' + $ext; $n++
        if ($n -gt 999) { throw 'Too many files with this name in the destination folder' }
    }
    return $candidate
}
function Set-SnapShackleClipboardFile([string]$Path) {
    Add-Type -AssemblyName System.Windows.Forms
    $list = [Collections.Specialized.StringCollection]::new()
    [void]$list.Add($Path)
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -eq [Threading.ApartmentState]::STA) {
        [Windows.Forms.Clipboard]::SetFileDropList($list); return
    }
    # The clipboard needs an STA thread; the host normally is one (the launcher passes -STA), tests may not be.
    $space = [RunspaceFactory]::CreateRunspace()
    $space.ApartmentState = [Threading.ApartmentState]::STA
    $space.Open()
    try {
        $ps = [PowerShell]::Create(); $ps.Runspace = $space
        [void]$ps.AddScript({ param($p) Add-Type -AssemblyName System.Windows.Forms; $l = [Collections.Specialized.StringCollection]::new(); [void]$l.Add($p); [Windows.Forms.Clipboard]::SetFileDropList($l) }).AddArgument($Path)
        [void]$ps.Invoke()
        if ($ps.HadErrors) { throw $ps.Streams.Error[0].Exception.Message }
    } finally { $space.Dispose() }
}
function Open-SnapShackleFile([string]$Path, [bool]$InExplorer) {
    if ($InExplorer) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $Path + '"') }
    else { Start-Process -FilePath $Path }
}
# Shares one library capture. Returns @{ kind; name; path; message }. Throws a plain-language error on bad input.
# -ClipboardAction and -OpenAction exist so tests never touch the real clipboard or launch programs.
function Invoke-SnapShackleShare {
    param(
        [string]$Library, [string]$CapturePath, $Settings, [string]$Kind, [string]$Destination,
        [scriptblock]$ClipboardAction = { param($p) Set-SnapShackleClipboardFile $p },
        [scriptblock]$OpenAction = { param($p, $inExplorer) Open-SnapShackleFile $p $inExplorer }
    )
    if ($Kind -notin $script:SnapShackleShareKinds) { throw 'Unknown share kind' }
    if (-not [IO.File]::Exists($CapturePath)) { throw 'Capture not found' }
    $name = [IO.Path]::GetFileName($CapturePath)
    switch ($Kind) {
        'folder' {
            $match = @($Settings.shareFolders | Where-Object { $null -ne $_ -and [string]$_.name -ieq $Destination }) | Select-Object -First 1
            if ($null -eq $match) { throw 'Unknown share folder. Add it under Workflows, Settings, Share folders.' }
            $folder = ConvertTo-SnapShackleSharePath $match.path
            if ($null -eq $folder) { throw 'The share folder path is not usable' }
            if (-not (Test-Path -LiteralPath $folder -PathType Container)) { throw ('The folder ' + $folder + ' was not found or is offline') }
            $target = Get-SnapShackleFreeName $folder $name
            try { [IO.File]::Copy($CapturePath, (Join-Path $folder $target), $false) }
            catch { throw ('Could not copy to ' + $folder + ': ' + $_.Exception.Message) }
            return @{ kind = 'folder'; name = $target; path = (Join-Path $folder $target); message = ('Copied to ' + $match.name) }
        }
        'clipboard' {
            & $ClipboardAction $CapturePath
            return @{ kind = 'clipboard'; name = $name; path = $CapturePath; message = 'File copied to the clipboard. Paste it into the message or chat.' }
        }
        'reveal' {
            & $OpenAction $CapturePath $true
            return @{ kind = 'reveal'; name = $name; path = $CapturePath; message = 'Shown in Explorer' }
        }
        'open' {
            & $OpenAction $CapturePath $false
            return @{ kind = 'open'; name = $name; path = $CapturePath; message = 'Opened in the default image app' }
        }
    }
}
