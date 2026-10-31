# CLI and API parity (Fleet CLI parity proposal). One registry names every command; the host serves it at GET /api/commands
# and snapshackle.ps1 reads it, so the studio, the CLI and the local API cannot drift apart. tests/commands_test.ps1 fails when
# a host route or a studio button has no command (or a listed reason), or a command names a route the host lacks.
$script:SnapShackleCommandsSchema = 'snapshackle.commands/1'

function New-SnapShackleOption([string]$Name, [string]$Type = 'string', [bool]$Required = $false, [string]$In = 'query', [string]$Help = '', [string[]]$Values = @()) {
    $o = [ordered]@{ name = $Name; type = $Type; required = $Required; in = $In; help = $Help }
    if ($Values.Count -gt 0) { $o.allowed = @($Values) }
    return $o
}
function New-SnapShackleCommand([string]$Name, [string]$Summary, [string]$Method, [string]$Route, $Options = @(), [string]$Request = 'none', [string]$Response = 'json', [bool]$Destructive = $false, [string[]]$Gui = @(), [string]$Kind = 'api') {
    return [ordered]@{ name = $Name; summary = $Summary; kind = $Kind; method = $Method; route = $Route; options = @($Options); request = $Request; response = $Response; destructive = $Destructive; gui = @($Gui) }
}
$script:SnapShackleCommands = @(
    (New-SnapShackleCommand 'app health' 'Check that SnapShackle answers: version, capture and OCR support, DPI mode, lifecycle mode.' 'GET' '/api/health')
    (New-SnapShackleCommand 'app start' 'Start SnapShackle headless (no browser, no tray) and wait until it answers. Not needed if it is already running.' '' '' @((New-SnapShackleOption 'port' 'int' $false 'local' 'Preferred loopback port (default 8765).')) 'none' 'json' $false @() 'local')
    (New-SnapShackleCommand 'screen list' 'The monitors with their bounds.' 'GET' '/api/screens' @() 'none' 'json' $false @('display'))
    (New-SnapShackleCommand 'window list' 'Visible application windows (id and title) that capture window can take.' 'GET' '/api/windows' @() 'none' 'json' $false @('windows', 'refreshWindows'))
    (New-SnapShackleCommand 'capture screen' 'Capture the whole desktop or one monitor to a PNG file.' 'GET' '/api/capture' @(
        (New-SnapShackleOption 'screen' 'int' $false 'query' 'Monitor index from screen list (default: all displays).'),
        (New-SnapShackleOption 'delay' 'int' $false 'query' 'Seconds to wait first, 0-10.'),
        (New-SnapShackleOption 'out' 'file' $true 'local' 'PNG file to write.')) 'none' 'png' $false @('capture'))
    (New-SnapShackleCommand 'capture window' 'Capture one window by id with PrintWindow, even where something covers it.' 'GET' '/api/capture' @(
        (New-SnapShackleOption 'window' 'int' $true 'query' 'Window id from window list.'),
        (New-SnapShackleOption 'delay' 'int' $false 'query' 'Seconds to wait first, 0-10.'),
        (New-SnapShackleOption 'out' 'file' $true 'local' 'PNG file to write.')) 'none' 'png' $false @('windowCapture'))
    (New-SnapShackleCommand 'capture rect' 'Capture a fixed screen rectangle to a PNG file (the headless form of drag-to-select).' 'GET' '/api/capture' @(
        (New-SnapShackleOption 'x' 'int' $true 'query' 'Left edge in screen pixels.'), (New-SnapShackleOption 'y' 'int' $true 'query' 'Top edge.'),
        (New-SnapShackleOption 'w' 'int' $true 'query' 'Width in pixels.'), (New-SnapShackleOption 'h' 'int' $true 'query' 'Height in pixels.'),
        (New-SnapShackleOption 'out' 'file' $true 'local' 'PNG file to write.')) 'none' 'png' $false @())
    (New-SnapShackleCommand 'ocr run' 'Read the text in a PNG with Windows OCR (lines with word boxes). Fails with a clear error where OCR is unavailable.' 'POST' '/api/ocr' @(
        (New-SnapShackleOption 'file' 'file' $false 'local' 'PNG file to read.'), (New-SnapShackleOption 'name' 'string' $false 'local' 'Or the name of a library capture.')) 'png' 'json' $false @('ocr'))
    (New-SnapShackleCommand 'library list' 'Saved captures, newest first, with tags and notes. A query matches names, tags, notes and text in the images.' 'GET' '/api/library' @(
        (New-SnapShackleOption 'q' 'string' $false 'query' 'Search text.')) 'none' 'json' $false @('libraryRefresh', 'librarySearch'))
    (New-SnapShackleCommand 'library get' 'Write one saved capture to a PNG file.' 'GET' '/api/library/{name}' @(
        (New-SnapShackleOption 'name' 'string' $true 'path' 'Capture name from library list.'), (New-SnapShackleOption 'out' 'file' $true 'local' 'PNG file to write.')) 'none' 'png')
    (New-SnapShackleCommand 'library save' 'Save a PNG file into the library and index its text.' 'POST' '/api/library' @(
        (New-SnapShackleOption 'file' 'file' $true 'local' 'PNG file to save.')) 'png' 'json' $false @('librarySave', 'import'))
    (New-SnapShackleCommand 'library tag' 'Set the tags and note of a saved capture (the indexed text is kept).' 'PUT' '/api/library/{name}' @(
        (New-SnapShackleOption 'name' 'string' $true 'path' 'Capture name.'), (New-SnapShackleOption 'tags' 'string' $false 'body' 'Comma-separated tags (replaces the old ones).'),
        (New-SnapShackleOption 'note' 'string' $false 'body' 'Note text (replaces the old one).')) 'json' 'json' $false @('metadataSave'))
    (New-SnapShackleCommand 'library delete' 'Delete a saved capture permanently. Needs --yes; every delete is written to the audit log.' 'DELETE' '/api/library/{name}' @(
        (New-SnapShackleOption 'name' 'string' $true 'path' 'Capture name.')) 'none' 'json' $true @('libraryDelete'))
    (New-SnapShackleCommand 'share list' 'The places a saved capture can be shared to: the folders set under Share folders, the clipboard, Explorer and the default app.' 'GET' '/api/share')
    (New-SnapShackleCommand 'share send' 'Share a saved capture: copy it into a share folder (never overwrites), put the file on the clipboard, show it in Explorer, or open it in the default app. Local only; nothing is uploaded.' 'POST' '/api/share' @(
        (New-SnapShackleOption 'capture' 'string' $true 'body' 'Capture name from library list.'),
        (New-SnapShackleOption 'kind' 'string' $true 'body' 'Where to: folder, clipboard, reveal (Explorer) or open (default app).' @('folder', 'clipboard', 'reveal', 'open')),
        (New-SnapShackleOption 'destination' 'string' $false 'body' 'Share folder name from share list (needed for folder).')) 'json' 'json' $false @('shareSelected', 'shareCurrent'))
    (New-SnapShackleCommand 'settings show' 'The saved preferences.' 'GET' '/api/settings')
    (New-SnapShackleCommand 'settings set' 'Change preferences: one --key with --value, or a JSON file of keys. Unknown keys are ignored by the host.' 'PUT' '/api/settings' @(
        (New-SnapShackleOption 'key' 'string' $false 'local' 'Preference name, for example namePrefix, autoLibrary, recordFps, theme.'),
        (New-SnapShackleOption 'value' 'string' $false 'local' 'New value (true, false and numbers are typed).'),
        (New-SnapShackleOption 'file' 'file' $false 'local' 'JSON file of preferences.')) 'json' 'json' $false @('settingsSave'))
    (New-SnapShackleCommand 'session stop' 'Stop SnapShackle, its tray icon and hotkeys. Needs --yes.' 'POST' '/api/session/stop' @() 'none' 'json' $true @('endSession'))
    (New-SnapShackleCommand 'commands list' 'This list: every command, its route and options.' 'GET' '/api/commands' @() 'none' 'json')
)
# Studio buttons and controls that are not commands, each with the reason. A new button must be in a command's gui list or here.
$script:SnapShackleGuiOnly = [ordered]@{
    region = 'Drag-to-select needs a person at the overlay; capture rect is the headless form'
    browserCapture = 'Browser share prompt (getDisplayMedia) needs a person'
    record = 'Browser screen recording (getDisplayMedia, MediaRecorder) needs a person'
    gif = 'Browser screen recording (getDisplayMedia) needs a person'
    scrollAdd = 'Scrolling-capture tiles are stitched in the browser'; scrollFinish = 'Scrolling-capture tiles are stitched in the browser'; scrollAuto = 'Browser share prompt needs a person'
    copy = 'Clipboard of the browser page'; copyOcr = 'Clipboard of the browser page'
    png = 'Browser export of the annotated canvas'; jpg = 'Browser export of the annotated canvas'
    projectSave = 'Editable project JSON is downloaded by the browser (open JSON, any tool can write one)'; projectOpen = 'Editable project JSON is opened by the browser file picker'
    undo = 'Annotation editor'; redo = 'Annotation editor'; editText = 'Annotation editor'; duplicate = 'Annotation editor'; forward = 'Annotation editor'; backward = 'Annotation editor'
    deleteObject = 'Annotation editor'; crop = 'Annotation editor'; zoomFit = 'View only'; clear = 'Annotation editor'
    redactFind = 'Annotation editor (OCR plus boxes on the open image)'; redactApply = 'Annotation editor'; redactTermApply = 'Annotation editor'
    tabLibrary = 'View only (panel tab)'; tabLayers = 'View only (panel tab)'; tabWorkflows = 'View only (panel tab)'
    themeToggle = 'View only (also saved by settings set)'; helpButton = 'View only'; closeHelp = 'View only'
    recordMicRefresh = 'Browser microphone permission prompt'
    recordCameraRefresh = 'Browser camera permission prompt'
}

function Get-SnapShackleCommandsDocument {
    return [ordered]@{ schema = $script:SnapShackleCommandsSchema; commands = @($script:SnapShackleCommands) }
}

# --- Per-session token file for the CLI (Fleet CLI parity requirement 9) -------------------------------------------
# %LOCALAPPDATA%\SnapShackle\api-session.json: port, token, pid. Only the signed-in user can read it (explicit ACL, no
# inheritance). Replaced on every start, removed on clean shutdown. The runtime file in logs\ never holds the token.
function Get-SnapShackleSessionFilePath([string]$AppDir) { Join-Path $AppDir 'api-session.json' }
function Protect-SnapShackleFile([string]$Path) {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [Security.AccessControl.FileSecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($user, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
    [IO.File]::SetAccessControl($Path, $acl)
}
function Write-SnapShackleSessionFile([string]$AppDir, [int]$ProcessId, [int]$Port, [string]$Token) {
    [void][IO.Directory]::CreateDirectory($AppDir)
    $path = Get-SnapShackleSessionFilePath $AppDir
    [IO.File]::Delete($path)
    # Empty file first, locked to this user, and only then the token goes in.
    [IO.File]::WriteAllBytes($path, [byte[]]@())
    Protect-SnapShackleFile $path
    $info = [ordered]@{ pid = $ProcessId; port = $Port; token = $Token; startedAt = (Get-Date).ToString('o') }
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $info -Compress), [Text.UTF8Encoding]::new($false))
    return $path
}
function Remove-SnapShackleSessionFile([string]$Path, [int]$ProcessId) {
    if (-not $Path) { return }
    try {
        # Only remove our own: a newer instance may have replaced it.
        $saved = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        if ([int]$saved.pid -eq $ProcessId) { [IO.File]::Delete($Path) }
    } catch {}
}
# One line per destructive action, kept small (the file is cut to its last 500 lines past 1 MB).
function Write-SnapShackleAudit([string]$Dir, [string]$Action, [string]$Target, [string]$Source) {
    try {
        [void][IO.Directory]::CreateDirectory($Dir)
        $path = Join-Path $Dir 'snapshackle-audit.log'
        if ([IO.File]::Exists($path) -and ([IO.FileInfo]::new($path)).Length -gt 1MB) {
            $keep = @([IO.File]::ReadAllLines($path) | Select-Object -Last 500)
            [IO.File]::WriteAllLines($path, $keep, [Text.UTF8Encoding]::new($false))
        }
        $safeTarget = ($Target -replace '[^A-Za-z0-9._ -]', '')
        [IO.File]::AppendAllText($path, ((Get-Date).ToString('o') + ' ' + $Action + ' ' + $safeTarget + ' via ' + $Source + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    } catch {}
}
