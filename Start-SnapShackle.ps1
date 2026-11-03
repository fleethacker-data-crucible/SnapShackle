<#
 SnapShackle local server. Windows PowerShell 5.1 recommended for native OCR.
 No elevated privileges, remote listening, installers, or online dependencies.
 The studio tab owns the server: closing it stops SnapShackle, its tray icon and hotkeys.
 -Stay (or --stay) keeps SnapShackle in the tray with its hotkeys after the tab closes; Exit is in the tray menu.
 -Replace (or --replace) stops a running SnapShackle without asking. SNAPSHACKLE_AUTO_STOP=0 turns auto-stop off
 (CUTTERMK_AUTO_STOP, the name before the rename, is still read when SNAPSHACKLE_AUTO_STOP is unset).
#>
[CmdletBinding(PositionalBinding=$false)]
param(
    [ValidateRange(1024,65535)][int]$Port=8765,
    [switch]$NoBrowser,
    [ValidateRange(1,500)][int]$PortScanCount=100,
    [switch]$Diagnostics,
    # Skip global hotkeys and the tray icon (tests, or when another tool owns the keys).
    [switch]$NoTray,
    # Stay in the tray with hotkeys after the studio tab closes (Exit in the tray menu stops it).
    [switch]$Stay,
    # If SnapShackle is already running, stop it and start fresh without asking.
    [switch]$Replace,
    # Tests only: skip the single-instance check (a headless -NoTray test host next to a running SnapShackle).
    [switch]$AllowSecondInstance,
    # Keep captures, settings and logs under <DataDir>\SnapShackle, not %LOCALAPPDATA% (a demo or trial run). Also --data-dir.
    [string]$DataDir,
    # Launcher-style options: --stay, --replace, --no-browser, --no-tray.
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    throw 'SnapShackle requires a Windows desktop session.'
}
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'modules/Lifecycle.ps1')
$launch = Read-SnapShackleLaunchOptions $Rest
if ($launch.Stay) { $Stay = $true }
if ($launch.Replace) { $Replace = $true }
if ($launch.NoBrowser) { $NoBrowser = $true }
if ($launch.NoTray) { $NoTray = $true }
if ($launch.DataDir -and -not $DataDir) { $DataDir = $launch.DataDir }
$script:SnapShackleDataRoot = Set-SnapShackleDataRoot $DataDir
if ($script:SnapShackleDataRoot) { Write-Host ('Data folder: ' + $script:SnapShackleDataRoot + '\SnapShackle (not %LOCALAPPDATA%)') -ForegroundColor Yellow }
foreach ($unknown in $launch.Unknown) { Write-Warning ('Ignoring unknown option ' + $unknown) }
. (Join-Path $root 'modules/LocalHttp.ps1')
. (Join-Path $root 'modules/Native.ps1')
. (Join-Path $root 'modules/Ocr.ps1')
. (Join-Path $root 'modules/Router.ps1')
. (Join-Path $root 'modules/Migration.ps1')
. (Join-Path $root 'modules/Library.ps1')
. (Join-Path $root 'modules/Cli.ps1')
. (Join-Path $root 'modules/Actions.ps1')
. (Join-Path $root 'modules/Tray.ps1')
$SnapShackleVersion = ([IO.File]::ReadAllText((Join-Path $root 'VERSION'))).Trim()
$library = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'SnapShackle\Captures' } else { Join-Path $root 'captures' }
$settingsPath = Join-Path (Split-Path -Parent $library) 'settings.json'
# Accept earlier prefixes so CutterMk-, Lasso- and SnipHero-era captures stay visible in the library.
$CaptureNamePattern = '(?:SnapShackle|CutterMk|Lasso|SnipHero)-[a-zA-Z0-9_.-]+\.png'
if ($Diagnostics) {
    Write-Host ('SnapShackle ' + $SnapShackleVersion + ' launcher and host diagnostics') -ForegroundColor Cyan
    Write-Host ('PowerShell: ' + $PSVersionTable.PSVersion.ToString())
    Write-Host ('Process policy: ' + (Get-ExecutionPolicy -Scope Process))
    Write-Host ('Effective policy: ' + (Get-ExecutionPolicy))
    Write-Host 'Machine policy and application-control rules remain in force.'
    $testServer = [SnapShackle.Transport.Server]::new($Port,$PortScanCount)
    try { Write-Host ('Loopback socket bind: PASS (http://127.0.0.1:' + $testServer.Port + '/)') }
    finally { $testServer.Dispose() }
    Write-Host 'Diagnostics passed. No long-running server was started.' -ForegroundColor Green
    return
}
# One instance: a second SnapShackle would fight the first for the hotkeys and the tray.
# A CutterMk build from before the rename writes its runtime files under %LOCALAPPDATA%\CutterMk\logs:
# look there too, so an old instance still running counts (and can be stopped) as well.
$runtimeDir = Get-SnapShackleRuntimeDir $root
$searchDirs = @($runtimeDir, (Get-SnapShackleLegacyRuntimeDir))
$running = @(if (-not $AllowSecondInstance) { Get-SnapShackleProcesses $searchDirs })
if ($running.Count -gt 0) {
    $where = ($running | ForEach-Object { if ($_.Url) { $_.Url + ' (PID ' + $_.Pid + ')' } else { 'PID ' + $_.Pid } }) -join ', '
    Write-Host ('SnapShackle is already running: ' + $where) -ForegroundColor Yellow
    $answer = if ($Replace) { 'y' } else { Read-Host 'Stop it and start fresh? [Y/n]' }
    if ($answer -eq '' -or $answer -match '^[Yy]') {
        foreach ($stoppedPid in Stop-SnapShackleProcesses $searchDirs) { Write-Host ('  stopped PID ' + $stoppedPid) -ForegroundColor DarkGray }
        $still = @(Get-SnapShackleProcesses $searchDirs)
        if ($still.Count -gt 0) {
            $left = ($still | ForEach-Object { 'PID ' + $_.Pid }) -join ', '
            Write-Warning ('SnapShackle is still running (' + $left + ') after the stop request. Not starting another copy.')
            exit 1
        }
    } else {
        Write-Host 'Leaving the running SnapShackle alone. Use End session in its studio, Exit in its tray menu, or Stop-SnapShackle.ps1.' -ForegroundColor DarkGray
        $open = @($running | Where-Object { $_.Url } | Select-Object -First 1)
        if ($open.Count -gt 0 -and -not $NoBrowser) { try { Start-Process $open[0].Url } catch {} }
        exit 0
    }
}
# Data from earlier names keeps working: on first start CutterMk's captures and settings are copied
# forward (the CutterMk folder is left as it is), and Lasso and SnipHero data still left over is moved.
# This runs after any running instance (a CutterMk one included) has been stopped, so its last
# captures are copied too, and before the library folder is created (an existing SnapShackle
# folder means the copy already happened).
Invoke-SnapShackleMigration -BaseDir $env:LOCALAPPDATA -AppDir (Split-Path -Parent $library)
[void][IO.Directory]::CreateDirectory($library)
$sessionToken = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
# Bind directly to 127.0.0.1; no HttpListener URL ACL or admin permissions.
# The socket is held from selection through shutdown: no free-port check/bind race.
$server = [SnapShackle.Transport.Server]::new($Port,$PortScanCount)
$requestedPort = $Port
$Port = $server.Port
if ($requestedPort -ne $Port) {
    Write-Host ("Preferred port $requestedPort is unavailable; using free loopback port $Port instead.") -ForegroundColor Yellow
}
# Port plus a new start id, so the tray can focus this studio and not a stale tab on the same URL.
$script:studioStartId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$script:studioTitle = 'SnapShackle Studio ' + $Port + ' ' + $script:studioStartId

function Send-Response($Context, [byte[]]$Bytes, [string]$ContentType='application/json', [int]$Status=200) {
    $response = $Context.Response
    $response.StatusCode = $Status
    $response.ContentType = $ContentType
    $response.Headers.Add('Cache-Control','no-store')
    $response.Headers.Add('X-Content-Type-Options','nosniff')
    $response.Headers.Add('X-Frame-Options','DENY')
    $response.Headers.Add('Referrer-Policy','no-referrer')
    $response.Headers.Add('Content-Security-Policy',"default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data: blob:; media-src 'self' blob:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'")
    $response.ContentLength64 = $Bytes.Length
    try { $response.SetBody($Bytes) }
    finally { $response.Close() }
}
function Add-CaptureTimingHeaders($Context) {
    $stats=$script:SnapShackleCaptureStats
    if ($null -eq $stats) { return }
    $capture=[math]::Round([double]$stats.acquireMs,1).ToString([Globalization.CultureInfo]::InvariantCulture)
    $encode=[math]::Round([double]$stats.encodeMs,1).ToString([Globalization.CultureInfo]::InvariantCulture)
    $selection=[math]::Round([double]$stats.selectionMs,1).ToString([Globalization.CultureInfo]::InvariantCulture)
    $Context.Response.Headers.Add('Server-Timing',"acquire;dur=$capture, encode;dur=$encode, selection;dur=$selection")
}
function Send-Json($Context, $Payload, [int]$Status=200) {
    $text = ConvertTo-Json -InputObject $Payload -Depth 12 -Compress
    Send-Response $Context ([Text.Encoding]::UTF8.GetBytes($text)) 'application/json; charset=utf-8' $Status
}
function Read-Body($Context, [int]$MaxBytes=20000000) {
    if ($Context.Request.ContentLength64 -gt $MaxBytes) { throw 'Request body is too large' }
    $memory = [IO.MemoryStream]::new()
    try {
        $buffer = New-Object byte[] 8192
        while (($count=$Context.Request.InputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $memory.Write($buffer,0,$count)
            if ($memory.Length -gt $MaxBytes) { throw 'Request body is too large' }
        }
        return ,$memory.ToArray()
    } finally { $memory.Dispose() }
}
function Assert-Png([byte[]]$Bytes) {
    if ($Bytes.Length -lt 28 -or $Bytes[0] -ne 137 -or $Bytes[1] -ne 80 -or $Bytes[2] -ne 78 -or $Bytes[3] -ne 71 -or
        $Bytes[4] -ne 13 -or $Bytes[5] -ne 10 -or $Bytes[6] -ne 26 -or $Bytes[7] -ne 10) { throw 'Valid PNG image required' }
    # IHDR dimensions are network-order at offsets 16 and 20.
    $width = ([long]$Bytes[16] -shl 24) + ([long]$Bytes[17] -shl 16) + ([long]$Bytes[18] -shl 8) + $Bytes[19]
    $height = ([long]$Bytes[20] -shl 24) + ([long]$Bytes[21] -shl 16) + ([long]$Bytes[22] -shl 8) + $Bytes[23]
    if ($width -le 0 -or $height -le 0 -or $width*$height -gt 100000000) { throw 'PNG image dimensions exceed limit' }
}
function Get-SnapShackleDelay($Query) { if ($Query['delay'] -match '^\d{1,2}$') { [Math]::Min(10,[int]$Query['delay']) } else { 0 } }
function Get-MetaPath([string]$Name) { Get-SnapShackleMetaPath $library $Name }
function Get-SafeCapturePath([string]$Name) {
    if ($Name -notmatch ('^' + $CaptureNamePattern + '$')) { throw 'Invalid capture name' }
    Join-Path $library $Name
}
# Keep a small, bounded in-memory thumbnail cache: no persistent duplicate screenshots.
$script:thumbnailCache = [Collections.Generic.Dictionary[string,byte[]]]::new([StringComparer]::Ordinal)
$script:thumbnailOrder = [Collections.Generic.Queue[string]]::new()
function Get-SnapShackleThumbnail([string]$Name) {
    $path=Get-SafeCapturePath $Name
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    if ($script:thumbnailCache.ContainsKey($Name)) { return ,$script:thumbnailCache[$Name] }
    $source=[Drawing.Image]::FromFile($path)
    try {
        if ($source.Width -le 0 -or $source.Height -le 0 -or ([long]$source.Width*$source.Height) -gt 100000000) { throw 'Invalid thumbnail source' }
        $target=[Drawing.Bitmap]::new(216,136)
        $gfx=[Drawing.Graphics]::FromImage($target)
        try {
            $gfx.Clear([Drawing.Color]::FromArgb(24,29,39))
            $gfx.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBilinear
            $scale=[math]::Min(216.0/$source.Width,136.0/$source.Height)
            $width=[math]::Max(1,[int]($source.Width*$scale))
            $height=[math]::Max(1,[int]($source.Height*$scale))
            $left=[int]((216-$width)/2)
            $top=[int]((136-$height)/2)
            $gfx.DrawImage($source,[Drawing.Rectangle]::new($left,$top,$width,$height))
            $m=[IO.MemoryStream]::new()
            try { $target.Save($m,[Drawing.Imaging.ImageFormat]::Jpeg);$bytes=$m.ToArray() }
            finally { $m.Dispose() }
        } finally { $gfx.Dispose();$target.Dispose() }
    } finally { $source.Dispose() }
    # Hard bounds: 64 recent 216x136 thumbnails, maximum 256 KiB per entry.
    if ($bytes.Length -le 262144) {
        while ($script:thumbnailCache.Count -ge 64 -or $script:thumbnailOrder.Count -ge 64) {
            $old=$script:thumbnailOrder.Dequeue()
            [void]$script:thumbnailCache.Remove($old)
        }
        $script:thumbnailCache[$Name]=$bytes
        $script:thumbnailOrder.Enqueue($Name)
    }
    return ,$bytes
}
function Invoke-SnapShackleRequest($Context) {
    $request=$Context.Request; $path=$request.Url.AbsolutePath; $method=$request.HttpMethod
    if (-not [Net.IPAddress]::IsLoopback($request.RemoteEndPoint.Address)) { Send-Json $Context @{error='Local clients only'} 403;return }
    if ($request.Url.Host -ne '127.0.0.1' -or $request.Url.Port -ne $Port) { Send-Json $Context @{error='Invalid host'} 403;return }
    $fetchSite=$request.Headers['Sec-Fetch-Site']
    if ($fetchSite -and $fetchSite -notin @('same-origin','none')) { Send-Json $Context @{error='Cross-site requests denied'} 403;return }
    $origin=$request.Headers['Origin']
    if ($origin -and $origin -ne "http://127.0.0.1:$Port") { Send-Json $Context @{error='Origin is not authorized'} 403;return }
    if ($path -eq '/' -and $method -eq 'GET') {
        $html=[IO.File]::ReadAllText((Join-Path $root 'index.html')).Replace('__SNAPSHACKLE_VERSION__',$SnapShackleVersion).Replace('__STUDIO_TITLE__',$script:studioTitle)
        Send-Response $Context ([Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8';return
    }
    if ($method -eq 'GET' -and $path -match '^/assets/(editor|studio|gif|stitch|redact|icons|theme|audio|webcam|aisuggest|voice)\.js$') {
        $filename=$Matches[1]+'.js'
        $source=[IO.File]::ReadAllText((Join-Path $root ('assets/'+$filename))).Replace('__SESSION_TOKEN__',$sessionToken).Replace('__STUDIO_TITLE__',$script:studioTitle)
        Send-Response $Context ([Text.Encoding]::UTF8.GetBytes($source)) 'application/javascript; charset=utf-8';return
    }
    if ($method -eq 'GET' -and $path -eq '/assets/styles.css') {
        Send-Response $Context ([IO.File]::ReadAllBytes((Join-Path $root 'assets/styles.css'))) 'text/css; charset=utf-8';return
    }
    # Shared Fleet tokens (docs/UNIFIED-UI.md) and the in-app brand art: the emblem with its backdrop
    # made transparent, one per theme, and the icon cut from its circle.
    if ($method -eq 'GET' -and $path -eq '/assets/vendor/fleet/fleet.css') {
        Send-Response $Context ([IO.File]::ReadAllBytes((Join-Path $root 'assets/vendor/fleet/fleet.css'))) 'text/css; charset=utf-8';return
    }
    if ($method -eq 'GET' -and $path -match '^/assets/ui/(emblem-dark|emblem-light|icon-256)\.png$') {
        Send-Response $Context ([IO.File]::ReadAllBytes((Join-Path $root ('assets/ui/'+$Matches[1]+'.png')))) 'image/png';return
    }
    if ($method -eq 'GET' -and ($path -eq '/favicon.ico' -or $path -eq '/assets/ui/favicon.ico')) {
        Send-Response $Context ([IO.File]::ReadAllBytes((Join-Path $root 'assets/ui/favicon.ico'))) 'image/x-icon';return
    }
    if ($path -eq '/api/heartbeat' -and $method -eq 'POST') {
        # navigator.sendBeacon cannot set headers, so on this route alone the token may travel in the
        # JSON body as "session". Never in the query string; the body is never logged.
        $beat=ConvertFrom-SnapShackleHeartbeat ([Text.Encoding]::UTF8.GetString((Read-Body $Context 1024)))
        $headerOk=Test-SnapShackleSecretEquals ([string]$request.Headers['X-SnapShackle-Token']) $sessionToken
        if ($null -eq $beat -or -not ($headerOk -or (Test-SnapShackleSecretEquals $beat.Session $sessionToken))) { Send-Json $Context @{error='Invalid session'} 403;return }
        Register-SnapShacklePresence $presence $beat.Tab $beat.Leaving ([datetime]::UtcNow) $beat.Hidden
        Send-Json $Context @{autoStop=(Test-SnapShackleAutoStop);timeoutSeconds=$presence.HeartbeatTimeout};return
    }
    if ($request.Headers['X-SnapShackle-Token'] -ne $sessionToken) { Send-Json $Context @{error='Invalid session'} 403;return }
    if ($path -eq '/api/actions' -and $method -eq 'GET') { Send-Json $Context (Get-FleetActionDocument); return }
    if ($method -eq 'POST' -and $path -match '^/api/actions/(snapshackle\.[a-z]+\.[a-z]+)$') {
        $actionId = $Matches[1]
        $action = Get-FleetAction $actionId
        if ($null -eq $action) { Send-Json $Context @{error='Unknown action'} 404; return }
        $rawBody = ''
        if ($request.ContentLength64 -gt 0) { $rawBody = [Text.Encoding]::UTF8.GetString((Read-Body $Context 20000000)) }
        $parsed = $null
        if ($rawBody.Trim()) { try { $parsed = $rawBody | ConvertFrom-Json } catch { Send-Json $Context @{error='Action body must be JSON'} 400; return } }
        $actionArgs = ConvertTo-FleetArgumentTable $parsed
        $confirmed = ($request.Headers['X-SnapShackle-Confirm'] -eq 'yes')
        if ($action.destructive -and -not $confirmed) { Send-Json $Context @{error='Confirmation required: send X-SnapShackle-Confirm: yes (CLI: --yes)';confirm=$true} 409; return }
        if ($actionId -eq 'snapshackle.session.stop' -and $request.Headers['X-SnapShackle-Intent'] -ne 'end-session') { Send-Json $Context @{error='Missing intent'} 400; return }
        $source = $(if ($request.Headers['User-Agent'] -like 'SnapShackle-CLI*') { 'cli' } else { 'api' })
        if ($action.destructive) { Write-SnapShackleAudit $runtimeDir ($action.noun + '-' + $action.verb) ([string]$actionArgs.name) $source }
        $ran = Invoke-FleetAction -Id $actionId -Arguments $actionArgs -Context @{ Transport = 'host'; Source = $source; Audited = $true } -Confirmed:$confirmed
        if (-not $ran.Ok) { Send-Json $Context @{error=[string]$ran.Error} 400; return }
        $actionResult = $ran.Result
        $actionStatus = 0
        if ($actionResult -is [hashtable] -and $actionResult.ContainsKey('statusCode')) { $actionStatus = [int]$actionResult.statusCode }
        if ($actionStatus -ge 400) { Send-Json $Context @{error=[string]$actionResult.error} $actionStatus; return }
        if ($actionResult -is [hashtable] -and $actionResult.ContainsKey('png')) { Send-Response $Context ([byte[]]$actionResult.png) 'image/png'; return }
        Send-Json $Context $actionResult
        if ($actionId -eq 'snapshackle.library.save' -and $actionResult -is [hashtable] -and $actionResult.ContainsKey('name') -and $actionArgs.Contains('file') -and $actionArgs.file -and (Test-Path -LiteralPath ([string]$actionArgs.file))) {
            $null = Update-SnapShackleOcrIndex $library ([string]$actionResult.name) ([IO.File]::ReadAllBytes([string]$actionArgs.file))
        }
        return
    }
    if ($path -eq '/api/session/stop' -and $method -eq 'POST') {
        # End session in the studio. The intent header keeps a stray authenticated request from stopping SnapShackle.
        if ($request.Headers['X-SnapShackle-Intent'] -ne 'end-session') { Send-Json $Context @{error='Missing intent'} 400;return }
        $source = $(if ($request.Headers['User-Agent'] -like 'SnapShackle-CLI*') { 'cli' } else { 'studio' })
        Write-SnapShackleAudit $runtimeDir 'session-stop' '' $source
        if ($shared.Busy) { Send-Json $Context @{error='A capture is still being saved; try again in a moment'} 409;return }
        $ran = Invoke-FleetAction -Id 'snapshackle.session.stop' -Arguments @{} -Context @{ Transport = 'host'; Source = $source; Audited = $true } -Confirmed
        if (-not $ran.Ok) { Send-Json $Context @{error=[string]$ran.Error} 400; return }
        Send-Json $Context @{stopped=$true}
        return
    }
    if ($path -eq '/api/commands' -and $method -eq 'GET') {
        $ran = Invoke-FleetAction -Id 'snapshackle.commands.list' -Arguments @{} -Context @{ Transport = 'host' } -Confirmed
        Send-Json $Context $ran.Result; return
    }
    if ($path -eq '/api/health' -and $method -eq 'GET') {
        $ran = Invoke-FleetAction -Id 'snapshackle.app.health' -Arguments @{} -Context @{ Transport = 'host' } -Confirmed
        Send-Json $Context $ran.Result; return
    }
    if ($path -eq '/api/screens' -and $method -eq 'GET') {
        $ran = Invoke-FleetAction -Id 'snapshackle.screen.list' -Arguments @{} -Context @{ Transport = 'host' } -Confirmed
        Send-Json $Context $ran.Result; return
    }
    if ($path -eq '/api/windows' -and $method -eq 'GET') {
        $ran = Invoke-FleetAction -Id 'snapshackle.window.list' -Arguments @{} -Context @{ Transport = 'host' } -Confirmed
        Send-Json $Context $ran.Result; return
    }
    if ($path -eq '/api/capture' -and $method -eq 'GET') {
        $q=$request.QueryString
        $delay = 0
        if ($q['delay'] -match '^\d+$') { $delay = [int]$q['delay'] }
        if ($q['window'] -match '^\d+$') {
            # PrintWindow: the window's own pixels, even where the studio or anything else covers it.
            $ran = Invoke-FleetAction -Id 'snapshackle.capture.window' -Arguments @{ window = [int]$q['window']; delay = $delay } -Context @{ Transport = 'host' } -Confirmed
            if (-not $ran.Ok) { Send-Json $Context @{error=[string]$ran.Error} 400; return }
            $Context.Response.Headers.Add('X-SnapShackle-Capture-Method',[string]$ran.Result.method)
            Add-CaptureTimingHeaders $Context
            Send-Response $Context ([byte[]]$ran.Result.png) 'image/png'; return
        }
        if ($q['x'] -match '^-?\d+$' -and $q['y'] -match '^-?\d+$' -and $q['w'] -match '^\d+$' -and $q['h'] -match '^\d+$') {
            $ran = Invoke-FleetAction -Id 'snapshackle.capture.rect' -Arguments @{ x = [int]$q['x']; y = [int]$q['y']; w = [int]$q['w']; h = [int]$q['h']; delay = $delay } -Context @{ Transport = 'host' } -Confirmed
            if (-not $ran.Ok) { Send-Json $Context @{error=[string]$ran.Error} 400; return }
            Add-CaptureTimingHeaders $Context
            Send-Response $Context ([byte[]]$ran.Result.png) 'image/png'; return
        }
        $screenArgs = @{ delay = $delay }
        if ($q['screen'] -match '^\d+$') { $screenArgs.screen = [int]$q['screen'] }
        $ran = Invoke-FleetAction -Id 'snapshackle.capture.screen' -Arguments $screenArgs -Context @{ Transport = 'host' } -Confirmed
        if (-not $ran.Ok) { Send-Json $Context @{error=[string]$ran.Error} 400; return }
        Add-CaptureTimingHeaders $Context
        Send-Response $Context ([byte[]]$ran.Result.png) 'image/png'; return
    }
    if ($path -eq '/api/settings') {
        if ($method -eq 'GET') {
            $ran = Invoke-FleetAction -Id 'snapshackle.settings.show' -Arguments @{} -Context @{ Transport = 'host' } -Confirmed
            Send-Json $Context $ran.Result; return
        }
        if ($method -eq 'PUT') {
            $changes=[Text.Encoding]::UTF8.GetString((Read-Body $Context 16384)) | ConvertFrom-Json
            $ran = Invoke-FleetAction -Id 'snapshackle.settings.set' -Arguments (ConvertTo-FleetArgumentTable $changes) -Context @{ Transport = 'host' } -Confirmed
            if (-not $ran.Ok) { Send-Json $Context @{error=[string]$ran.Error} 400; return }
            Send-Json $Context $ran.Result; return
        }
    }
    if ($path -eq '/api/events' -and $method -eq 'GET') {
        # Polled by the studio: hotkey captures made while the browser was in the background.
        $since=if ($request.QueryString['since'] -match '^\d{1,9}$') { [int]$request.QueryString['since'] } else { 0 }
        $items=@($shared.Events.ToArray() | Where-Object { $_.id -gt $since })
        Send-Json $Context @{events=$items;latest=$shared.NextId};return
    }
    if ($path -eq '/api/region' -and $method -eq 'GET') {
        if ($shared.Busy) { Send-Json $Context @{error='A capture is already in progress'} 409;return }
        Wait-SnapShackleDelay (Get-SnapShackleDelay $request.QueryString)
        $shared.Busy=$true
        try { $bytes=Get-SnapShackleRegion } finally { $shared.Busy=$false }
        if ($null -eq $bytes) { Send-Json $Context @{cancelled=$true} 409 }
        else { Add-CaptureTimingHeaders $Context; Send-Response $Context $bytes 'image/png' }
        return
    }
    if ($path -eq '/api/ocr' -and $method -eq 'POST') {
        if (-not (Test-SnapShackleOcr)) { Send-Json $Context @{error='Windows native OCR unsupported by this PowerShell environment'} 501;return }
        $bytes=Read-Body $Context 15000000
        Assert-Png $bytes
        $ran = Invoke-FleetAction -Id 'snapshackle.ocr.run' -Arguments @{} -Context @{ Transport = 'host'; PngBytes = $bytes } -Confirmed
        if (-not $ran.Ok) { Send-Json $Context @{error=[string]$ran.Error} 400; return }
        if ($ran.Result -is [hashtable] -and $ran.Result.ContainsKey('statusCode')) { Send-Json $Context @{error=[string]$ran.Result.error} ([int]$ran.Result.statusCode); return }
        Send-Json $Context $ran.Result; return
    }
    if ($path -eq '/api/ai/status' -and $method -eq 'GET') {
        $ran = Invoke-FleetAction -Id 'snapshackle.ai.status' -Arguments @{} -Context @{ Transport = 'host' } -Confirmed
        Send-Json $Context $ran.Result; return
    }
    if (($path -eq '/api/ai/alt-text' -or $path -eq '/api/ai/suggest') -and $method -eq 'POST') {
        $aiSettings=Get-SnapShackleSettings $settingsPath
        if (([string]$aiSettings.aiSuggest) -ne 'on') { Send-Json $Context @{error='AI suggestions are off. Turn them on under Workflows, Settings.'} 409;return }
        $bytes=Read-Body $Context 15000000
        Assert-Png $bytes
        $aiId = $(if ($path -eq '/api/ai/alt-text') { 'snapshackle.ai.describe' } else { 'snapshackle.ai.suggest' })
        $ran = Invoke-FleetAction -Id $aiId -Arguments @{} -Context @{ Transport = 'host'; PngBytes = $bytes } -Confirmed
        if (-not $ran.Ok) { Send-Json $Context @{error=[string]$ran.Error} 502; return }
        if ($ran.Result -is [hashtable] -and $ran.Result.ContainsKey('statusCode')) { Send-Json $Context @{error=[string]$ran.Result.error} ([int]$ran.Result.statusCode); return }
        Send-Json $Context $ran.Result
        return
    }
    if ($path -eq '/api/share' -and $method -eq 'GET') {
        $ran = Invoke-FleetAction -Id 'snapshackle.share.list' -Arguments @{} -Context @{ Transport = 'host' } -Confirmed
        Send-Json $Context $ran.Result; return
    }
    if ($path -eq '/api/share' -and $method -eq 'POST') {
        $share=[Text.Encoding]::UTF8.GetString((Read-Body $Context 16384)) | ConvertFrom-Json
        try { $null = Get-SafeCapturePath ([string]$share.capture) } catch { Send-Json $Context @{error=$_.Exception.Message} 400; return }
        $shareArgs = ConvertTo-FleetArgumentTable $share
        $ran = Invoke-FleetAction -Id 'snapshackle.share.send' -Arguments $shareArgs -Context @{ Transport = 'host' } -Confirmed
        if (-not $ran.Ok) { Send-Json $Context @{error=[string]$ran.Error} 400; return }
        Send-Json $Context $ran.Result
        return
    }
    if ($path -eq '/api/library' -and $method -eq 'GET') {
        # The list comes back as one array object (return ,$array); @(...) around it would nest it as
        # items:[[...]], which the studio rendered as a single broken card ("Invalid Date").
        $ran = Invoke-FleetAction -Id 'snapshackle.library.list' -Arguments @{ q = [string]$request.QueryString['q'] } -Context @{ Transport = 'host' } -Confirmed
        Send-Json $Context $ran.Result; return
    }
    if ($path -eq '/api/library' -and $method -eq 'POST') {
        $bytes=Read-Body $Context 25000000;Assert-Png $bytes
        $ran = Invoke-FleetAction -Id 'snapshackle.library.save' -Arguments @{} -Context @{ Transport = 'host'; PngBytes = $bytes } -Confirmed
        if (-not $ran.Ok) { Send-Json $Context @{error=[string]$ran.Error} 400; return }
        $name = [string]$ran.Result.name
        Send-Json $Context @{name=$name}
        # After the reply has gone out: index the text in the image so the library can search it.
        $null=Update-SnapShackleOcrIndex $library $name $bytes
        return
    }
    if ($method -eq 'GET' -and $path -match ('^/api/thumb/(' + $CaptureNamePattern + ')$')) {
        $thumbnail=Get-SnapShackleThumbnail $Matches[1]
        if ($null -eq $thumbnail) { Send-Json $Context @{error='Missing capture'} 404 }
        else { Send-Response $Context $thumbnail 'image/jpeg' }
        return
    }
    if ($path -match ('^/api/library/(' + $CaptureNamePattern + ')$')) {
        $name=$Matches[1];$capturePath=Get-SafeCapturePath $name
        if ($method -eq 'GET') {
            $ran = Invoke-FleetAction -Id 'snapshackle.library.get' -Arguments @{ name = $name } -Context @{ Transport = 'host' } -Confirmed
            if (-not $ran.Ok) { Send-Json $Context @{error=[string]$ran.Error} 400; return }
            if ($ran.Result -is [hashtable] -and $ran.Result.ContainsKey('statusCode')) { Send-Json $Context @{error=[string]$ran.Result.error} ([int]$ran.Result.statusCode); return }
            Send-Response $Context ([byte[]]$ran.Result.png) 'image/png'
            return
        }
        if (-not (Test-Path -LiteralPath $capturePath)) { Send-Json $Context @{error='Capture not found'} 404;return }
        if ($method -eq 'DELETE') {
            # A delete is acknowledged explicitly (the studio sends this after its own confirm box; the CLI after --yes).
            if ($request.Headers['X-SnapShackle-Confirm'] -ne 'yes') { Send-Json $Context @{error='Confirmation required: send X-SnapShackle-Confirm: yes (CLI: --yes)';confirm=$true} 409;return }
            $source = $(if ($request.Headers['User-Agent'] -like 'SnapShackle-CLI*') { 'cli' } else { 'studio' })
            Write-SnapShackleAudit $runtimeDir 'library-delete' $name $source
            $ran = Invoke-FleetAction -Id 'snapshackle.library.delete' -Arguments @{ name = $name } -Context @{ Transport = 'host'; Source = $source; Audited = $true } -Confirmed
            if (-not $ran.Ok) { Send-Json $Context @{error=[string]$ran.Error} 400; return }
            Send-Json $Context @{deleted=$true};return
        }
        if ($method -eq 'PUT') {
            $metadata=[Text.Encoding]::UTF8.GetString((Read-Body $Context 65536)) | ConvertFrom-Json
            # Merge: tags and note change, indexed OCR text is kept.
            $tagList = @($metadata.tags | ForEach-Object { [string]$_ } | Where-Object { $_ })
            $tagArgs = @{ name = $name; tags = ($tagList -join ','); note = [string]$metadata.note }
            $ran = Invoke-FleetAction -Id 'snapshackle.library.tag' -Arguments $tagArgs -Context @{ Transport = 'host' } -Confirmed
            if (-not $ran.Ok) { Send-Json $Context @{error=[string]$ran.Error} 400; return }
            Send-Json $Context @{updated=$true};return
        }
    }
    Send-Json $Context @{error='Route not found'} 404
}
$script:SnapShackleActionState = @{
    Library = $library; SettingsPath = $settingsPath; RuntimeDir = $runtimeDir
    CaptureNamePattern = $CaptureNamePattern; Version = $SnapShackleVersion; Root = $root
}
$base="http://127.0.0.1:$Port/"
$shared=[hashtable]::Synchronized(@{
    Events=[Collections.ArrayList]::Synchronized([Collections.ArrayList]::new()); NextId=0
    Quit=$false; Busy=$false; Hotkeys=@(); BaseUrl=$base; Server=$server; LastName=$null; TrayReady=$false; TrayIcon=$null
    TrayStopped=$false; StopReason=$null; Stay=$false; StudioTitle=$script:studioTitle; BrowserMessage=$null
})
# Lifecycle: auto-stop is on unless -Stay, SNAPSHACKLE_AUTO_STOP=0 (or the older CUTTERMK_AUTO_STOP=0),
# or the "stay in the tray" preference (which needs a running tray, so there is always a visible Exit).
$autoStopEnv=Test-SnapShackleAutoStopEnv (Get-SnapShackleEnv 'AUTO_STOP')
$script:stayInTraySetting=[bool](Get-SnapShackleSettings $settingsPath).stayInTray
function Test-SnapShackleAutoStop {
    if ($Stay -or -not $autoStopEnv) { return $false }
    if ($script:stayInTraySetting -and $shared.TrayReady) { return $false }
    return $true
}
function Get-SnapShackleLifecycleMode {
    if ($Stay) { return 'stay' }
    if (-not $autoStopEnv) { return 'env' }
    if ($script:stayInTraySetting -and $shared.TrayReady) { return 'tray' }
    return 'tab'
}
# Without a browser to open, nobody is expected to connect, so there is no first-contact limit.
$firstContactBy=if ($NoBrowser) { $null } else { [datetime]::UtcNow.AddSeconds($script:SnapShackleFirstContactTimeout) }
$presence=New-SnapShacklePresence $firstContactBy
$script:stopReason=$null
if ($Stay -and $NoTray) {
    Write-Warning '-Stay keeps SnapShackle in the tray so it can always be exited from there; -NoTray is ignored.'
    $NoTray=$false
}
$shared.Stay=[bool]$Stay
Write-Host "SnapShackle $SnapShackleVersion local server: $base" -ForegroundColor Red
$runtimeFile=$null
# The CLI (snapshackle.ps1) finds the port and the session token here; only the signed-in user can read the file.
$sessionFile=$null
try { $sessionFile=Write-SnapShackleSessionFile (Split-Path -Parent $library) $PID $Port $sessionToken }
catch { Write-Warning ('Could not write the CLI session file: ' + $_.Exception.Message) }
try { $runtimeFile=Write-SnapShackleRuntimeFile $runtimeDir $PID $Port $base ([bool]$Stay) }
catch { Write-Warning ('Could not write the runtime file in ' + $runtimeDir + ': ' + $_.Exception.Message) }
# Stop-SnapShackle.ps1 and the launcher signal this event, so SnapShackle can remove its tray icon and hotkeys itself.
$stopEvent=$null
try { $stopEvent=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,(Get-SnapShackleStopEventName $PID)) }
catch { $stopEvent=$null }
$tray=$null
if (-not $NoTray) {
    try {
        $tray=Start-SnapShackleTray $root $library $shared
        for ($i=0; $i -lt 30 -and -not $shared.TrayReady -and -not $shared.TrayError; $i++) { Start-Sleep -Milliseconds 100 }
        if ($shared.TrayError) { Write-Warning ('Hotkeys and tray unavailable: ' + $shared.TrayError) }
        foreach ($h in $shared.Hotkeys) {
            if ($h.keys) { Write-Host ('  ' + $h.keys + '  capture ' + $h.action) }
            else { Write-Warning ('No free hotkey for ' + $h.action + ' capture; use the tray menu or the studio.') }
        }
    } catch { Write-Warning ('Hotkeys and tray unavailable: ' + $_.Exception.Message) }
}
if ($Stay -and -not $shared.TrayReady) {
    # Staying without a tray would leave a hidden process with no way out: the tab owns SnapShackle after all.
    Write-Warning '-Stay needs the tray icon (it holds Exit), which is unavailable; closing the studio tab will stop SnapShackle.'
    $Stay=$false; $shared.Stay=$false
}
switch (Get-SnapShackleLifecycleMode) {
    'stay' { Write-Host 'Staying in the tray after the studio tab closes (-Stay). Exit in the tray menu, End session in the studio, Stop-SnapShackle.ps1 or Ctrl+C stops it.' }
    'env' { Write-Host 'SNAPSHACKLE_AUTO_STOP=0: SnapShackle keeps running after the studio tab closes. End session, Exit in the tray menu, Stop-SnapShackle.ps1 or Ctrl+C stops it.' }
    'tray' { Write-Host 'Preference "stay in the tray" is on: SnapShackle keeps its hotkeys after the studio tab closes. Exit in the tray menu stops it.' }
    default { Write-Host 'Closing the studio tab stops SnapShackle, its tray icon and hotkeys (start with -Stay to keep them). Ctrl+C, End session or Exit in the tray menu also stop it.' }
}
# The page is served on the accept thread below, so the health check has to run beside it.
# Open the browser only after /api/health answers; a runspace warning would not show here.
$script:SnapShackleOpenBrowser = {
    param($Port, $Token, $Base, $Shared)
    $url = 'http://127.0.0.1:' + $Port + '/api/health'
    $opened = $false
    for ($i = 0; $i -lt 50 -and -not $Shared.Quit -and -not $Shared.BrowserClosed; $i++) {
        $resp = $null
        try {
            $req = [Net.WebRequest]::Create($url)
            $req.Method = 'GET'
            $req.Timeout = 1500
            $req.ReadWriteTimeout = 1500
            try { $req.Proxy = [Net.GlobalProxySelection]::GetEmptyWebProxy() } catch {}
            $req.Headers.Add('X-SnapShackle-Token', [string]$Token)
            try { $req.Host = '127.0.0.1:' + $Port } catch {}
            $resp = $req.GetResponse()
            if ([int]$resp.StatusCode -eq 200) {
                if ($Shared.Quit -or $Shared.BrowserClosed) { break }
                try { Start-Process $Base; $opened = $true }
                catch { $Shared.BrowserMessage = 'Browser did not open automatically: ' + $_.Exception.Message + '. Open ' + $Base + ' manually.' }
                break
            }
        } catch {
            # Not accepting yet, or the request was refused. Try again.
        } finally {
            if ($null -ne $resp) { try { $resp.Close() } catch {} }
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $opened -and -not $Shared.Quit -and -not $Shared.BrowserClosed -and -not $Shared.BrowserMessage) {
        $Shared.BrowserMessage = 'SnapShackle did not answer /api/health before the browser opened. Open ' + $Base + ' manually.'
    }
}
$browserWait = $null
if (-not $NoBrowser) {
    $browserWait = [PowerShell]::Create()
    [void]$browserWait.AddScript($script:SnapShackleOpenBrowser).AddArgument($Port).AddArgument($sessionToken).AddArgument($base).AddArgument($shared)
    [void]$browserWait.BeginInvoke()
}
try {
    while (-not $shared.Quit) {
        $context=$null
        try {
            if ($shared.BrowserMessage) {
                Write-Warning ([string]$shared.BrowserMessage)
                $shared.BrowserMessage = $null
                $presence.FirstContactBy = $null
            }
            if ($null -ne $stopEvent -and $stopEvent.WaitOne(0)) { $script:stopReason='Stop-SnapShackle.ps1 or a new launch asked SnapShackle to stop.'; break }
            # A gap since the last pass (the PC slept, or a long region selection held this thread) means the
            # tabs could not be heard: they get a fresh grace period.
            $gap=Step-SnapShacklePresenceClock $presence ([datetime]::UtcNow)
            # Wait at most half a second for a client, so the checks run (and Ctrl+C is handled) while idle.
            if (-not $server.Listener.Server.Poll(500000,[Net.Sockets.SelectMode]::SelectRead)) {
                # Only when idle: queued heartbeats are always read first. Requests run on this thread, so a
                # studio capture or save is never cut off; a hotkey capture on the tray thread sets Busy.
                if (-not $gap) {
                    $reason=Get-SnapShackleStopReason $presence ([datetime]::UtcNow) ([bool]$shared.Busy) (Test-SnapShackleAutoStop)
                    if ($reason) { $script:stopReason=$reason + ' (Start with -Stay or set SNAPSHACKLE_AUTO_STOP=0 to keep it running.)'; break }
                }
                continue
            }
            $context=$server.Accept()
            Invoke-SnapShackleRequest $context
        } catch [System.IO.InvalidDataException] {
            Write-Warning ('Rejected malformed local HTTP request: ' + $_.Exception.Message)
        } catch {
            if ($shared.Quit) { break }
            Write-Warning ('Local HTTP request failed: ' + $_.Exception.Message)
            if ($null -ne $context) {
                try { if ($context.Response.OutputStream.CanWrite) { Send-Json $context @{error='Request failed'} 500 } } catch {}
            }
        } finally {
            if ($null -ne $context) { $context.Dispose() }
        }
    }
} finally {
    if (-not $script:stopReason -and $shared.StopReason) { $script:stopReason=$shared.StopReason }
    $shared.BrowserClosed = $true
    if ($null -ne $browserWait) {
        try { $browserWait.Stop() } catch {}
        finally { $browserWait.Dispose() }
    }
    # A hotkey capture may still be saving to the library: let it finish (bounded) before the tray goes.
    for ($i=0; $i -lt 300 -and $shared.Busy; $i++) { Start-Sleep -Milliseconds 100 }
    $shared.Quit=$true
    $trayClean=Stop-SnapShackleTray $tray $shared
    try { $server.Dispose() } catch {}
    Remove-SnapShackleRuntimeFile $runtimeFile
    Remove-SnapShackleSessionFile $sessionFile $PID
    if ($null -ne $stopEvent) { $stopEvent.Dispose() }
    if ($script:stopReason) { Write-Host $script:stopReason -ForegroundColor DarkGray }
    Write-Host 'SnapShackle stopped.'
    # A tray thread that did not finish would keep this process alive; it has nothing left to save.
    if (-not $trayClean) { [Environment]::Exit(0) }
}
