# Capture library helpers shared by the HTTP host and the hotkey/tray thread.
# Each capture NAME.png may have a sidecar NAME.png.meta.json: {tags, note, ocr}.
function New-SnapShackleCaptureName {
    'SnapShackle-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.png'
}
# Writes PNG bytes into the library under a new unique name and returns the name.
function Save-SnapShackleCapture([string]$Library, [byte[]]$Bytes) {
    $name = New-SnapShackleCaptureName
    [IO.File]::WriteAllBytes((Join-Path $Library $name), $Bytes)
    return $name
}
function Get-SnapShackleMetaPath([string]$Library, [string]$Name) { Join-Path $Library ($Name + '.meta.json') }
# Returns tags, note and OCR text for a capture (empty values when there is no sidecar).
function Get-SnapShackleMeta([string]$Library, [string]$Name) {
    $meta = @{ tags = @(); note = ''; ocr = '' }
    $path = Get-SnapShackleMetaPath $Library $Name
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
function Set-SnapShackleMeta([string]$Library, [string]$Name, [hashtable]$Changes) {
    $meta = Get-SnapShackleMeta $Library $Name
    foreach ($key in @('tags', 'note', 'ocr')) { if ($Changes.ContainsKey($key)) { $meta[$key] = $Changes[$key] } }
    $tags = @($meta.tags | Select-Object -First 20 | ForEach-Object { $v = [string]$_; $v.Substring(0, [Math]::Min(40, $v.Length)) })
    $note = [string]$meta.note; if ($note.Length -gt 2000) { $note = $note.Substring(0, 2000) }
    $ocr = [string]$meta.ocr; if ($ocr.Length -gt 20000) { $ocr = $ocr.Substring(0, 20000) }
    $json = ConvertTo-Json -InputObject ([ordered]@{ tags = $tags; note = $note; ocr = $ocr }) -Depth 4
    [IO.File]::WriteAllText((Get-SnapShackleMetaPath $Library $Name), $json, [Text.UTF8Encoding]::new($false))
}
# Recognises the capture's text and stores it for search. Silent no-op without native OCR.
function Update-SnapShackleOcrIndex([string]$Library, [string]$Name, [byte[]]$Bytes) {
    try {
        if (-not (Get-Command Test-SnapShackleOcr -ErrorAction SilentlyContinue) -or -not (Test-SnapShackleOcr)) { return $false }
        $text = (Invoke-SnapShackleOcr $Bytes).text
        Set-SnapShackleMeta $Library $Name @{ ocr = [string]$text }
        return $true
    } catch { return $false }
}
# Newest first. A query matches the file name, tags, note, or the text inside the image.
function Get-SnapShackleCaptureList([string]$Library, [string]$Query, [string]$Pattern = '(?:SnapShackle|CutterMk|Lasso|SnipHero)-[a-zA-Z0-9_.-]+\.png') {
    $search = ([string]$Query).Trim().ToLowerInvariant()
    $items = [Collections.Generic.List[object]]::new()
    $files = [IO.DirectoryInfo]::new($Library).GetFiles('*.png') | Where-Object { $_.Name -match ('^' + $Pattern + '$') } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 2000
    foreach ($file in $files) {
        $meta = Get-SnapShackleMeta $Library $file.Name
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
# recordAudio: off | system | mic | both. Off leaves screen video silent, as earlier builds did.
# recordCamera: off | on (picture-in-picture camera in screen video), recordCameraCorner: br|bl|tr|tl,
# recordCameraSize: small|medium|large, recordCameraId: optional camera device id. Off leaves video as before.
# recordFormat: webm | mp4. MP4 only where the browser's MediaRecorder can write it; otherwise the recording is WebM.
# recordMicId: optional microphone device id chosen in the studio. Empty uses the browser default.
$script:SnapShackleSettingDefaults = [ordered]@{ namePrefix = 'SnapShackle'; autoLibrary = $false; recordFps = 6; stayInTray = $false; theme = 'dark'; recordAudio = 'off'; recordMicId = ''; recordCamera = 'off'; recordCameraCorner = 'br'; recordCameraSize = 'medium'; recordCameraId = ''; recordFormat = 'webm' }
function Get-SnapShackleSettings([string]$Path) {
    $settings = [ordered]@{}
    foreach ($key in $script:SnapShackleSettingDefaults.Keys) { $settings[$key] = $script:SnapShackleSettingDefaults[$key] }
    $settings.saved = $false
    if ([IO.File]::Exists($Path)) {
        try {
            $file = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
            $clean = ConvertTo-SnapShackleSettings $file
            foreach ($key in $clean.Keys) { $settings[$key] = $clean[$key] }
            # The old default prefixes follow the rename; a prefix someone chose is kept.
            if ($settings.namePrefix -in @('CutterMk', 'Lasso', 'SnipHero')) { $settings.namePrefix = 'SnapShackle' }
            $settings.saved = $true
        } catch {}
    }
    return $settings
}
# Keeps only known keys, each coerced to its type and range.
function ConvertTo-SnapShackleSettings($Value) {
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
    if ($names -contains 'recordAudio') {
        $audio = ([string]$Value.recordAudio).Trim().ToLowerInvariant()
        if ($audio -in @('off', 'system', 'mic', 'both')) { $clean.recordAudio = $audio }
    }
    if ($names -contains 'recordCamera') {
        $camera = ([string]$Value.recordCamera).Trim().ToLowerInvariant()
        if ($camera -in @('off', 'on')) { $clean.recordCamera = $camera }
    }
    if ($names -contains 'recordCameraCorner') {
        $corner = ([string]$Value.recordCameraCorner).Trim().ToLowerInvariant()
        if ($corner -in @('br', 'bl', 'tr', 'tl')) { $clean.recordCameraCorner = $corner }
    }
    if ($names -contains 'recordCameraSize') {
        $size = ([string]$Value.recordCameraSize).Trim().ToLowerInvariant()
        if ($size -in @('small', 'medium', 'large')) { $clean.recordCameraSize = $size }
    }
    if ($names -contains 'recordCameraId') {
        $cameraId = ([string]$Value.recordCameraId).Trim() -replace '[^A-Za-z0-9_+=./-]', ''
        if ($cameraId.Length -gt 256) { $cameraId = $cameraId.Substring(0, 256) }
        $clean.recordCameraId = $cameraId
    }
    if ($names -contains 'recordFormat') {
        $format = ([string]$Value.recordFormat).Trim().ToLowerInvariant()
        if ($format -in @('webm', 'mp4')) { $clean.recordFormat = $format }
    }
    if ($names -contains 'recordMicId') {
        $micId = ([string]$Value.recordMicId).Trim() -replace '[^A-Za-z0-9_+=./-]', ''
        if ($micId.Length -gt 256) { $micId = $micId.Substring(0, 256) }
        $clean.recordMicId = $micId
    }
    return $clean
}
function Set-SnapShackleSettings([string]$Path, $Changes) {
    $current = Get-SnapShackleSettings $Path
    $current.Remove('saved')
    $clean = ConvertTo-SnapShackleSettings $Changes
    foreach ($key in $clean.Keys) { $current[$key] = $clean[$key] }
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $current -Depth 3), [Text.UTF8Encoding]::new($false))
    $current.saved = $true
    return $current
}
