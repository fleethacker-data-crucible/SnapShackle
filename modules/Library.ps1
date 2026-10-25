# Capture library helpers shared by the HTTP host and the hotkey/tray thread.
# Each capture NAME.png may have a sidecar NAME.png.meta.json: {tags, note, ocr}.
function New-CutterMkCaptureName {
    'CutterMk-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.png'
}
# Writes PNG bytes into the library under a new unique name and returns the name.
function Save-CutterMkCapture([string]$Library, [byte[]]$Bytes) {
    $name = New-CutterMkCaptureName
    [IO.File]::WriteAllBytes((Join-Path $Library $name), $Bytes)
    return $name
}
function Get-CutterMkMetaPath([string]$Library, [string]$Name) { Join-Path $Library ($Name + '.meta.json') }
# Returns tags, note and OCR text for a capture (empty values when there is no sidecar).
function Get-CutterMkMeta([string]$Library, [string]$Name) {
    $meta = @{ tags = @(); note = ''; ocr = '' }
    $path = Get-CutterMkMetaPath $Library $Name
    if ([IO.File]::Exists($path)) {
        try {
            $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json
            $meta.tags = @($saved.tags | Where-Object { $_ } | ForEach-Object { [string]$_ })
            $meta.note = [string]$saved.note
            $meta.ocr = [string]$saved.ocr
        } catch {}
    }
    return $meta
}
# Updates only the fields given; everything else in the sidecar is kept.
function Set-CutterMkMeta([string]$Library, [string]$Name, [hashtable]$Changes) {
    $meta = Get-CutterMkMeta $Library $Name
    foreach ($key in @('tags', 'note', 'ocr')) { if ($Changes.ContainsKey($key)) { $meta[$key] = $Changes[$key] } }
    $tags = @($meta.tags | Select-Object -First 20 | ForEach-Object { $v = [string]$_; $v.Substring(0, [Math]::Min(40, $v.Length)) })
    $note = [string]$meta.note; if ($note.Length -gt 2000) { $note = $note.Substring(0, 2000) }
    $ocr = [string]$meta.ocr; if ($ocr.Length -gt 20000) { $ocr = $ocr.Substring(0, 20000) }
    $json = ConvertTo-Json -InputObject ([ordered]@{ tags = $tags; note = $note; ocr = $ocr }) -Depth 4
    [IO.File]::WriteAllText((Get-CutterMkMetaPath $Library $Name), $json, [Text.UTF8Encoding]::new($false))
}
# Recognises the capture's text and stores it for search. Silent no-op without native OCR.
function Update-CutterMkOcrIndex([string]$Library, [string]$Name, [byte[]]$Bytes) {
    try {
        if (-not (Get-Command Test-CutterMkOcr -ErrorAction SilentlyContinue) -or -not (Test-CutterMkOcr)) { return $false }
        $text = (Invoke-CutterMkOcr $Bytes).text
        Set-CutterMkMeta $Library $Name @{ ocr = [string]$text }
        return $true
    } catch { return $false }
}
# Newest first. A query matches the file name, tags, note, or the text inside the image.
function Get-CutterMkCaptureList([string]$Library, [string]$Query, [string]$Pattern = '(?:CutterMk|Lasso|SnipHero)-[a-zA-Z0-9_.-]+\.png') {
    $search = ([string]$Query).Trim().ToLowerInvariant()
    $items = [Collections.Generic.List[object]]::new()
    $files = [IO.DirectoryInfo]::new($Library).GetFiles('*.png') | Where-Object { $_.Name -match ('^' + $Pattern + '$') } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 2000
    foreach ($file in $files) {
        $meta = Get-CutterMkMeta $Library $file.Name
        $textMatch = $false
        if ($search) {
            $label = ($file.Name + ' ' + $meta.note + ' ' + ($meta.tags -join ' ')).ToLowerInvariant()
            if (-not $label.Contains($search)) {
                if (-not $meta.ocr.ToLowerInvariant().Contains($search)) { continue }
                $textMatch = $true
            }
        }
        $items.Add([pscustomobject]@{ name = $file.Name; bytes = $file.Length; modified = $file.LastWriteTime.ToString('o')
            tags = @($meta.tags); note = $meta.note; hasText = [bool]$meta.ocr; textMatch = $textMatch })
        if ($items.Count -ge 250) { break }
    }
    return ,$items.ToArray()
}
# Studio preferences live in a file, not only in browser storage: the browser keys storage by
# origin, and the origin includes the port, so a port fallback would otherwise reset them.
# stayInTray: keep the tray icon and hotkeys after the studio tab closes (like -Stay; Exit is in the tray menu).
$script:CutterMkSettingDefaults = [ordered]@{ namePrefix = 'CutterMk'; autoLibrary = $false; recordFps = 6; stayInTray = $false; theme = 'dark' }
function Get-CutterMkSettings([string]$Path) {
    $settings = [ordered]@{}
    foreach ($key in $script:CutterMkSettingDefaults.Keys) { $settings[$key] = $script:CutterMkSettingDefaults[$key] }
    $settings.saved = $false
    if ([IO.File]::Exists($Path)) {
        try {
            $file = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
            $clean = ConvertTo-CutterMkSettings $file
            foreach ($key in $clean.Keys) { $settings[$key] = $clean[$key] }
            # The old default prefixes follow the rename; a prefix someone chose is kept.
            if ($settings.namePrefix -in @('Lasso', 'SnipHero')) { $settings.namePrefix = 'CutterMk' }
            $settings.saved = $true
        } catch {}
    }
    return $settings
}
# Keeps only known keys, each coerced to its type and range.
function ConvertTo-CutterMkSettings($Value) {
    $clean = [ordered]@{}
    if ($null -eq $Value) { return $clean }
    $names = @($Value.PSObject.Properties.Name) + @(if ($Value -is [hashtable]) { $Value.Keys })
    if ($names -contains 'namePrefix') {
        $prefix = ([string]$Value.namePrefix) -replace '[^A-Za-z0-9_-]', ''
        if ($prefix.Length -gt 30) { $prefix = $prefix.Substring(0, 30) }
        if ($prefix) { $clean.namePrefix = $prefix }
    }
    if ($names -contains 'autoLibrary') { $clean.autoLibrary = [bool]$Value.autoLibrary }
    if ($names -contains 'stayInTray') { $clean.stayInTray = ($Value.stayInTray -eq $true) }
    if ($names -contains 'recordFps') {
        $fps = 0; if ([int]::TryParse([string]$Value.recordFps, [ref]$fps)) { $clean.recordFps = [Math]::Max(2, [Math]::Min(12, $fps)) }
    }
    if ($names -contains 'theme') {
        $theme = ([string]$Value.theme).ToLowerInvariant()
        if ($theme -in @('dark', 'light', 'system')) { $clean.theme = $theme }
    }
    return $clean
}
function Set-CutterMkSettings([string]$Path, $Changes) {
    $current = Get-CutterMkSettings $Path
    $current.Remove('saved')
    $clean = ConvertTo-CutterMkSettings $Changes
    foreach ($key in $clean.Keys) { $current[$key] = $clean[$key] }
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $current -Depth 3), [Text.UTF8Encoding]::new($false))
    $current.saved = $true
    return $current
}
