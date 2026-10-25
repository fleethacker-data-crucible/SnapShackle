<#
 Lasso local server. Windows PowerShell 5.1 recommended for native OCR.
 No elevated privileges, remote listening, installers, or online dependencies.
 The studio tab owns the server: closing it stops Lasso, its tray icon and hotkeys.
 -Stay (or --stay) keeps Lasso in the tray with its hotkeys after the tab closes; Exit is in the tray menu.
 -Replace (or --replace) stops a running Lasso without asking. LASSO_AUTO_STOP=0 turns auto-stop off.
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
    # If Lasso is already running, stop it and start fresh without asking.
    [switch]$Replace,
    # Tests only: skip the single-instance check (a headless -NoTray test host next to a running Lasso).
    [switch]$AllowSecondInstance,
    # Launcher-style options: --stay, --replace, --no-browser, --no-tray.
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    throw 'Lasso requires a Windows desktop session.'
}
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'modules/Lifecycle.ps1')
$launch = Read-LassoLaunchOptions $Rest
if ($launch.Stay) { $Stay = $true }
if ($launch.Replace) { $Replace = $true }
if ($launch.NoBrowser) { $NoBrowser = $true }
if ($launch.NoTray) { $NoTray = $true }
foreach ($unknown in $launch.Unknown) { Write-Warning ('Ignoring unknown option ' + $unknown) }
. (Join-Path $root 'modules/LocalHttp.ps1')
. (Join-Path $root 'modules/Native.ps1')
. (Join-Path $root 'modules/Ocr.ps1')
. (Join-Path $root 'modules/Migration.ps1')
. (Join-Path $root 'modules/Library.ps1')
. (Join-Path $root 'modules/Tray.ps1')
$LassoVersion = ([IO.File]::ReadAllText((Join-Path $root 'VERSION'))).Trim()
$library = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Lasso\Captures' } else { Join-Path $root 'captures' }
# Captures from SnipHero builds keep working: they are moved (never copied or deleted) on first start.
$legacyLibrary = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'SnipHero\Captures' } else { $null }
$null = Move-LassoLegacyLibrary -Legacy $legacyLibrary -Target $library
[void][IO.Directory]::CreateDirectory($library)
$settingsPath = Join-Path (Split-Path -Parent $library) 'settings.json'
# Accept both prefixes so SnipHero-era captures stay visible in the library.
$CaptureNamePattern = '(?:Lasso|SnipHero)-[a-zA-Z0-9_.-]+\.png'
if ($Diagnostics) {
    Write-Host ('Lasso ' + $LassoVersion + ' launcher and host diagnostics') -ForegroundColor Cyan
    Write-Host ('PowerShell: ' + $PSVersionTable.PSVersion.ToString())
    Write-Host ('Process policy: ' + (Get-ExecutionPolicy -Scope Process))
    Write-Host ('Effective policy: ' + (Get-ExecutionPolicy))
    Write-Host 'Machine policy and application-control rules remain in force.'
    $testServer = [Lasso.Transport.Server]::new($Port,$PortScanCount)
    try { Write-Host ('Loopback socket bind: PASS (http://127.0.0.1:' + $testServer.Port + '/)') }
    finally { $testServer.Dispose() }
    Write-Host 'Diagnostics passed. No long-running server was started.' -ForegroundColor Green
    return
}
# One instance: a second Lasso would fight the first for the hotkeys and the tray.
$runtimeDir = Get-LassoRuntimeDir $root
$running = @(if (-not $AllowSecondInstance) { Get-LassoProcesses $runtimeDir })
if ($running.Count -gt 0) {
    $where = ($running | ForEach-Object { if ($_.Url) { $_.Url + ' (PID ' + $_.Pid + ')' } else { 'PID ' + $_.Pid } }) -join ', '
    Write-Host ('Lasso is already running: ' + $where) -ForegroundColor Yellow
    $answer = if ($Replace) { 'y' } else { Read-Host 'Stop it and start fresh? [Y/n]' }
    if ($answer -eq '' -or $answer -match '^[Yy]') {
        foreach ($stoppedPid in Stop-LassoProcesses $runtimeDir) { Write-Host ('  stopped PID ' + $stoppedPid) -ForegroundColor DarkGray }
    } else {
        Write-Host 'Leaving the running Lasso alone. Use End session in its studio, Exit in its tray menu, or Stop-Lasso.ps1.' -ForegroundColor DarkGray
        $open = @($running | Where-Object { $_.Url } | Select-Object -First 1)
        if ($open.Count -gt 0 -and -not $NoBrowser) { try { Start-Process $open[0].Url } catch {} }
        exit 0
    }
}
$sessionToken = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
# Bind directly to 127.0.0.1; no HttpListener URL ACL or admin permissions.
# The socket is held from selection through shutdown: no free-port check/bind race.
$server = [Lasso.Transport.Server]::new($Port,$PortScanCount)
$requestedPort = $Port
$Port = $server.Port
if ($requestedPort -ne $Port) {
    Write-Host ("Preferred port $requestedPort is unavailable; using free loopback port $Port instead.") -ForegroundColor Yellow
}

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
    $stats=$script:LassoCaptureStats
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
function Get-LassoDelay($Query) { if ($Query['delay'] -match '^\d{1,2}$') { [Math]::Min(10,[int]$Query['delay']) } else { 0 } }
function Get-MetaPath([string]$Name) { Get-LassoMetaPath $library $Name }
function Get-SafeCapturePath([string]$Name) {
    if ($Name -notmatch ('^' + $CaptureNamePattern + '$')) { throw 'Invalid capture name' }
    Join-Path $library $Name
}
# Keep a small, bounded in-memory thumbnail cache: no persistent duplicate screenshots.
$script:thumbnailCache = [Collections.Generic.Dictionary[string,byte[]]]::new([StringComparer]::Ordinal)
$script:thumbnailOrder = [Collections.Generic.Queue[string]]::new()
function Get-LassoThumbnail([string]$Name) {
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
function Invoke-LassoRequest($Context) {
    $request=$Context.Request; $path=$request.Url.AbsolutePath; $method=$request.HttpMethod
    if (-not [Net.IPAddress]::IsLoopback($request.RemoteEndPoint.Address)) { Send-Json $Context @{error='Local clients only'} 403;return }
    if ($request.Url.Host -ne '127.0.0.1' -or $request.Url.Port -ne $Port) { Send-Json $Context @{error='Invalid host'} 403;return }
    $fetchSite=$request.Headers['Sec-Fetch-Site']
    if ($fetchSite -and $fetchSite -notin @('same-origin','none')) { Send-Json $Context @{error='Cross-site requests denied'} 403;return }
    $origin=$request.Headers['Origin']
    if ($origin -and $origin -ne "http://127.0.0.1:$Port") { Send-Json $Context @{error='Origin is not authorized'} 403;return }
    if ($path -eq '/' -and $method -eq 'GET') {
        $html=[IO.File]::ReadAllText((Join-Path $root 'index.html')).Replace('__LASSO_VERSION__',$LassoVersion)
        Send-Response $Context ([Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8';return
    }
    if ($method -eq 'GET' -and $path -match '^/assets/(editor|studio|gif|stitch|redact)\.js$') {
        $filename=$Matches[1]+'.js'
        $source=[IO.File]::ReadAllText((Join-Path $root ('assets/'+$filename))).Replace('__SESSION_TOKEN__',$sessionToken)
        Send-Response $Context ([Text.Encoding]::UTF8.GetBytes($source)) 'application/javascript; charset=utf-8';return
    }
    if ($method -eq 'GET' -and $path -eq '/assets/styles.css') {
        Send-Response $Context ([IO.File]::ReadAllBytes((Join-Path $root 'assets/styles.css'))) 'text/css; charset=utf-8';return
    }
    if ($path -eq '/api/heartbeat' -and $method -eq 'POST') {
        # navigator.sendBeacon cannot set headers, so on this route alone the token may travel in the
        # JSON body as "session". Never in the query string; the body is never logged.
        $beat=ConvertFrom-LassoHeartbeat ([Text.Encoding]::UTF8.GetString((Read-Body $Context 1024)))
        $headerOk=Test-LassoSecretEquals ([string]$request.Headers['X-Lasso-Token']) $sessionToken
        if ($null -eq $beat -or -not ($headerOk -or (Test-LassoSecretEquals $beat.Session $sessionToken))) { Send-Json $Context @{error='Invalid session'} 403;return }
        Register-LassoPresence $presence $beat.Tab $beat.Leaving ([datetime]::UtcNow) $beat.Hidden
        Send-Json $Context @{autoStop=(Test-LassoAutoStop);timeoutSeconds=$presence.HeartbeatTimeout};return
    }
    if ($request.Headers['X-Lasso-Token'] -ne $sessionToken) { Send-Json $Context @{error='Invalid session'} 403;return }
    if ($path -eq '/api/session/stop' -and $method -eq 'POST') {
        # End session in the studio. The intent header keeps a stray authenticated request from stopping Lasso.
        if ($request.Headers['X-Lasso-Intent'] -ne 'end-session') { Send-Json $Context @{error='Missing intent'} 400;return }
        if ($shared.Busy) { Send-Json $Context @{error='A capture is still being saved; try again in a moment'} 409;return }
        Send-Json $Context @{stopped=$true}
        $script:stopReason='End session in the studio.'
        $shared.Quit=$true;return
    }
    if ($path -eq '/api/health' -and $method -eq 'GET') {
        Send-Json $Context @{capture=$true;ocr=(Test-LassoOcr);version=$LassoVersion;offline=$true;dpi=$script:LassoDpiMode;hotkeys=@($shared.Hotkeys);lifecycle=(Get-LassoLifecycleMode)};return
    }
    if ($path -eq '/api/screens' -and $method -eq 'GET') {
        Send-Json $Context @{screens=@([Windows.Forms.Screen]::AllScreens | ForEach-Object {
          @{name=$_.DeviceName;primary=$_.Primary;left=$_.Bounds.Left;top=$_.Bounds.Top;width=$_.Bounds.Width;height=$_.Bounds.Height}
        })};return
    }
    if ($path -eq '/api/windows' -and $method -eq 'GET') { Send-Json $Context @{windows=@(Get-LassoWindows)};return }
    if ($path -eq '/api/capture' -and $method -eq 'GET') {
        $q=$request.QueryString
        Wait-LassoDelay (Get-LassoDelay $q)
        if ($q['window'] -match '^\d+$') {
            # PrintWindow: the window's own pixels, even where the studio or anything else covers it.
            $png=Get-LassoWindowCapture ([long]$q['window'])
            $Context.Response.Headers.Add('X-Lasso-Capture-Method',[string]$script:LassoLastWindowMethod)
            Add-CaptureTimingHeaders $Context
            Send-Response $Context $png 'image/png';return
        }
        $r=[Windows.Forms.SystemInformation]::VirtualScreen
        if ($q['screen'] -match '^\d+$') {
            $screens=@([Windows.Forms.Screen]::AllScreens);$i=[int]$q['screen']
            if ($i -ge $screens.Count) { throw 'Invalid screen' }
            $r=$screens[$i].Bounds
        }
        if ($q['x'] -match '^-?\d+$' -and $q['y'] -match '^-?\d+$' -and $q['w'] -match '^\d+$' -and $q['h'] -match '^\d+$') {
            $r=[Drawing.Rectangle]::new([int]$q['x'],[int]$q['y'],[int]$q['w'],[int]$q['h'])
        }
        $png=Get-LassoRect $r
        Add-CaptureTimingHeaders $Context
        Send-Response $Context $png 'image/png';return
    }
    if ($path -eq '/api/settings') {
        if ($method -eq 'GET') { Send-Json $Context (Get-LassoSettings $settingsPath);return }
        if ($method -eq 'PUT') {
            $changes=[Text.Encoding]::UTF8.GetString((Read-Body $Context 16384)) | ConvertFrom-Json
            $saved=Set-LassoSettings $settingsPath $changes
            $script:stayInTraySetting=[bool]$saved.stayInTray
            Send-Json $Context $saved;return
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
        Wait-LassoDelay (Get-LassoDelay $request.QueryString)
        $shared.Busy=$true
        try { $bytes=Get-LassoRegion } finally { $shared.Busy=$false }
        if ($null -eq $bytes) { Send-Json $Context @{cancelled=$true} 409 }
        else { Add-CaptureTimingHeaders $Context; Send-Response $Context $bytes 'image/png' }
        return
    }
    if ($path -eq '/api/ocr' -and $method -eq 'POST') {
        if (-not (Test-LassoOcr)) { Send-Json $Context @{error='Windows native OCR unsupported by this PowerShell environment'} 501;return }
        $bytes=Read-Body $Context 15000000
        Assert-Png $bytes
        $result=Invoke-LassoOcr $bytes
        Send-Json $Context @{text=$result.text;lines=$result.lines;engine='Windows.Media.Ocr'};return
    }
    if ($path -eq '/api/library' -and $method -eq 'GET') {
        Send-Json $Context @{items=@(Get-LassoCaptureList $library $request.QueryString['q'] $CaptureNamePattern)};return
    }
    if ($path -eq '/api/library' -and $method -eq 'POST') {
        $bytes=Read-Body $Context 25000000;Assert-Png $bytes
        $name=Save-LassoCapture $library $bytes
        Send-Json $Context @{name=$name}
        # After the reply has gone out: index the text in the image so the library can search it.
        $null=Update-LassoOcrIndex $library $name $bytes
        return
    }
    if ($method -eq 'GET' -and $path -match ('^/api/thumb/(' + $CaptureNamePattern + ')$')) {
        $thumbnail=Get-LassoThumbnail $Matches[1]
        if ($null -eq $thumbnail) { Send-Json $Context @{error='Missing capture'} 404 }
        else { Send-Response $Context $thumbnail 'image/jpeg' }
        return
    }
    if ($path -match ('^/api/library/(' + $CaptureNamePattern + ')$')) {
        $name=$Matches[1];$capturePath=Get-SafeCapturePath $name
        if ($method -eq 'GET') {
            if (Test-Path -LiteralPath $capturePath) { Send-Response $Context ([IO.File]::ReadAllBytes($capturePath)) 'image/png' }
            else { Send-Json $Context @{error='Capture not found'} 404 };return
        }
        if (-not (Test-Path -LiteralPath $capturePath)) { Send-Json $Context @{error='Capture not found'} 404;return }
        if ($method -eq 'DELETE') {
            Remove-Item -LiteralPath $capturePath
            # Invalidate cached preview when its original is deleted.
            if ($script:thumbnailCache.ContainsKey($name)) { [void]$script:thumbnailCache.Remove($name) }
            Remove-Item -LiteralPath (Get-MetaPath $name) -ErrorAction SilentlyContinue
            Send-Json $Context @{deleted=$true};return
        }
        if ($method -eq 'PUT') {
            $metadata=[Text.Encoding]::UTF8.GetString((Read-Body $Context 65536)) | ConvertFrom-Json
            # Merge: tags and note change, indexed OCR text is kept.
            Set-LassoMeta $library $name @{ tags=@($metadata.tags | ForEach-Object { [string]$_ }); note=[string]$metadata.note }
            Send-Json $Context @{updated=$true};return
        }
    }
    Send-Json $Context @{error='Route not found'} 404
}
$base="http://127.0.0.1:$Port/"
$shared=[hashtable]::Synchronized(@{
    Events=[Collections.ArrayList]::Synchronized([Collections.ArrayList]::new()); NextId=0
    Quit=$false; Busy=$false; Hotkeys=@(); BaseUrl=$base; Server=$server; LastName=$null; TrayReady=$false; TrayIcon=$null
    TrayStopped=$false; StopReason=$null; Stay=$false
})
# Lifecycle: auto-stop is on unless -Stay, LASSO_AUTO_STOP=0, or the "stay in the tray" preference
# (which needs a running tray, so there is always a visible Exit).
$autoStopEnv=Test-LassoAutoStopEnv $env:LASSO_AUTO_STOP
$script:stayInTraySetting=[bool](Get-LassoSettings $settingsPath).stayInTray
function Test-LassoAutoStop {
    if ($Stay -or -not $autoStopEnv) { return $false }
    if ($script:stayInTraySetting -and $shared.TrayReady) { return $false }
    return $true
}
function Get-LassoLifecycleMode {
    if ($Stay) { return 'stay' }
    if (-not $autoStopEnv) { return 'env' }
    if ($script:stayInTraySetting -and $shared.TrayReady) { return 'tray' }
    return 'tab'
}
# Without a browser to open, nobody is expected to connect, so there is no first-contact limit.
$firstContactBy=if ($NoBrowser) { $null } else { [datetime]::UtcNow.AddSeconds($script:LassoFirstContactTimeout) }
$presence=New-LassoPresence $firstContactBy
$script:stopReason=$null
if ($Stay -and $NoTray) {
    Write-Warning '-Stay keeps Lasso in the tray so it can always be exited from there; -NoTray is ignored.'
    $NoTray=$false
}
$shared.Stay=[bool]$Stay
Write-Host "Lasso $LassoVersion local server: $base" -ForegroundColor Red
$runtimeFile=$null
try { $runtimeFile=Write-LassoRuntimeFile $runtimeDir $PID $Port $base ([bool]$Stay) }
catch { Write-Warning ('Could not write the runtime file in ' + $runtimeDir + ': ' + $_.Exception.Message) }
# Stop-Lasso.ps1 and the launcher signal this event, so Lasso can remove its tray icon and hotkeys itself.
$stopEvent=$null
try { $stopEvent=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,(Get-LassoStopEventName $PID)) }
catch { $stopEvent=$null }
$tray=$null
if (-not $NoTray) {
    try {
        $tray=Start-LassoTray $root $library $shared
        for ($i=0; $i -lt 30 -and -not $shared.TrayReady -and -not $shared.TrayError; $i++) { Start-Sleep -Milliseconds 100 }
        if ($shared.TrayError) { Write-Warning ('Hotkeys and tray unavailable: ' + $shared.TrayError) }
        foreach ($h in $shared.Hotkeys) {
            if ($h.keys) { Write-Host ('  ' + $h.keys + '  capture ' + $h.action) }
            else { Write-Warning ('No free hotkey for ' + $h.action + ' capture; use the tray menu or the studio.') }
        }
    } catch { Write-Warning ('Hotkeys and tray unavailable: ' + $_.Exception.Message) }
}
if ($Stay -and -not $shared.TrayReady) {
    # Staying without a tray would leave a hidden process with no way out: the tab owns Lasso after all.
    Write-Warning '-Stay needs the tray icon (it holds Exit), which is unavailable; closing the studio tab will stop Lasso.'
    $Stay=$false; $shared.Stay=$false
}
switch (Get-LassoLifecycleMode) {
    'stay' { Write-Host 'Staying in the tray after the studio tab closes (-Stay). Exit in the tray menu, End session in the studio, Stop-Lasso.ps1 or Ctrl+C stops it.' }
    'env' { Write-Host 'LASSO_AUTO_STOP=0: Lasso keeps running after the studio tab closes. End session, Exit in the tray menu, Stop-Lasso.ps1 or Ctrl+C stops it.' }
    'tray' { Write-Host 'Preference "stay in the tray" is on: Lasso keeps its hotkeys after the studio tab closes. Exit in the tray menu stops it.' }
    default { Write-Host 'Closing the studio tab stops Lasso, its tray icon and hotkeys (start with -Stay to keep them). Ctrl+C, End session or Exit in the tray menu also stop it.' }
}
if (-not $NoBrowser) {
    try { Start-Process $base }
    catch {
        Write-Warning ('Browser did not open automatically: ' + $_.Exception.Message + '. Open ' + $base + ' manually.')
        $presence.FirstContactBy=$null  # opening it by hand may take a while
    }
}
try {
    while (-not $shared.Quit) {
        $context=$null
        try {
            if ($null -ne $stopEvent -and $stopEvent.WaitOne(0)) { $script:stopReason='Stop-Lasso.ps1 or a new launch asked Lasso to stop.'; break }
            # A gap since the last pass (the PC slept, or a long region selection held this thread) means the
            # tabs could not be heard: they get a fresh grace period.
            $gap=Step-LassoPresenceClock $presence ([datetime]::UtcNow)
            # Wait at most half a second for a client, so the checks run (and Ctrl+C is handled) while idle.
            if (-not $server.Listener.Server.Poll(500000,[Net.Sockets.SelectMode]::SelectRead)) {
                # Only when idle: queued heartbeats are always read first. Requests run on this thread, so a
                # studio capture or save is never cut off; a hotkey capture on the tray thread sets Busy.
                if (-not $gap) {
                    $reason=Get-LassoStopReason $presence ([datetime]::UtcNow) ([bool]$shared.Busy) (Test-LassoAutoStop)
                    if ($reason) { $script:stopReason=$reason + ' (Start with -Stay or set LASSO_AUTO_STOP=0 to keep it running.)'; break }
                }
                continue
            }
            $context=$server.Accept()
            Invoke-LassoRequest $context
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
    # A hotkey capture may still be saving to the library: let it finish (bounded) before the tray goes.
    for ($i=0; $i -lt 300 -and $shared.Busy; $i++) { Start-Sleep -Milliseconds 100 }
    $shared.Quit=$true
    $trayClean=Stop-LassoTray $tray $shared
    try { $server.Dispose() } catch {}
    Remove-LassoRuntimeFile $runtimeFile
    if ($null -ne $stopEvent) { $stopEvent.Dispose() }
    if ($script:stopReason) { Write-Host $script:stopReason -ForegroundColor DarkGray }
    Write-Host 'Lasso stopped.'
    # A tray thread that did not finish would keep this process alive; it has nothing left to save.
    if (-not $trayClean) { [Environment]::Exit(0) }
}