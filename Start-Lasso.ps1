<#
 Lasso local server. Windows PowerShell 5.1 recommended for native OCR.
 No elevated privileges, remote listening, installers, or online dependencies.
#>
[CmdletBinding()]
param(
    [ValidateRange(1024,65535)][int]$Port=8765,
    [switch]$NoBrowser,
    [ValidateRange(1,500)][int]$PortScanCount=100,
    [switch]$Diagnostics
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) {
    throw 'Lasso requires a Windows desktop session.'
}
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'modules/LocalHttp.ps1')
. (Join-Path $root 'modules/Native.ps1')
. (Join-Path $root 'modules/Ocr.ps1')
. (Join-Path $root 'modules/Migration.ps1')
$LassoVersion = ([IO.File]::ReadAllText((Join-Path $root 'VERSION'))).Trim()
$library = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Lasso\Captures' } else { Join-Path $root 'captures' }
# Captures from SnipHero builds keep working: they are moved (never copied or deleted) on first start.
$legacyLibrary = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'SnipHero\Captures' } else { $null }
$null = Move-LassoLegacyLibrary -Legacy $legacyLibrary -Target $library
[void][IO.Directory]::CreateDirectory($library)
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
function Get-MetaPath([string]$Name) { Join-Path $library ($Name + '.meta.json') }
function Get-SafeCapturePath([string]$Name) {
    if ($Name -notmatch ('^' + $CaptureNamePattern + '$')) { throw 'Invalid capture name' }
    Join-Path $library $Name
}
function Get-CaptureList([string]$Query) {
    $search = ([string]$Query).ToLowerInvariant()
    @((Get-ChildItem -LiteralPath $library -File -Filter '*.png' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 2000 | ForEach-Object {
          $metadata = @{tags=@();note=''}
          $mp = Get-MetaPath $_.Name
          if (Test-Path -LiteralPath $mp) { try { $metadata=Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json } catch {} }
          [pscustomobject]@{name=$_.Name;bytes=$_.Length;modified=$_.LastWriteTime.ToString('o');tags=@($metadata.tags | Where-Object { $_ });note=[string]$metadata.note}
        } | Where-Object { -not $search -or ($_.name+' '+$_.note+' '+($_.tags -join ' ')).ToLowerInvariant().Contains($search) } |
        Select-Object -First 250))
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
    if ($method -eq 'GET' -and $path -match '^/assets/(editor|studio|gif|stitch)\.js$') {
        $filename=$Matches[1]+'.js'
        $source=[IO.File]::ReadAllText((Join-Path $root ('assets/'+$filename))).Replace('__SESSION_TOKEN__',$sessionToken)
        Send-Response $Context ([Text.Encoding]::UTF8.GetBytes($source)) 'application/javascript; charset=utf-8';return
    }
    if ($method -eq 'GET' -and $path -eq '/assets/styles.css') {
        Send-Response $Context ([IO.File]::ReadAllBytes((Join-Path $root 'assets/styles.css'))) 'text/css; charset=utf-8';return
    }
    if ($request.Headers['X-Lasso-Token'] -ne $sessionToken) { Send-Json $Context @{error='Invalid session'} 403;return }
    if ($path -eq '/api/health' -and $method -eq 'GET') {
        Send-Json $Context @{capture=$true;ocr=(Test-LassoOcr);version=$LassoVersion;offline=$true};return
    }
    if ($path -eq '/api/screens' -and $method -eq 'GET') {
        Send-Json $Context @{screens=@([Windows.Forms.Screen]::AllScreens | ForEach-Object {
          @{name=$_.DeviceName;primary=$_.Primary;left=$_.Bounds.Left;top=$_.Bounds.Top;width=$_.Bounds.Width;height=$_.Bounds.Height}
        })};return
    }
    if ($path -eq '/api/windows' -and $method -eq 'GET') { Send-Json $Context @{windows=@(Get-LassoWindows)};return }
    if ($path -eq '/api/capture' -and $method -eq 'GET') {
        $q=$request.QueryString
        $r=[Windows.Forms.SystemInformation]::VirtualScreen
        if ($q['screen'] -match '^\d+$') {
            $screens=@([Windows.Forms.Screen]::AllScreens);$i=[int]$q['screen']
            if ($i -ge $screens.Count) { throw 'Invalid screen' }
            $r=$screens[$i].Bounds
        }
        if ($q['window'] -match '^\d+$') {
            $w=[Lasso.Native]::Window([long]$q['window'])
            $r=[Drawing.Rectangle]::new($w.X,$w.Y,$w.Width,$w.Height)
        }
        if ($q['x'] -match '^-?\d+$' -and $q['y'] -match '^-?\d+$' -and $q['w'] -match '^\d+$' -and $q['h'] -match '^\d+$') {
            $r=[Drawing.Rectangle]::new([int]$q['x'],[int]$q['y'],[int]$q['w'],[int]$q['h'])
        }
        $png=Get-LassoRect $r
        Add-CaptureTimingHeaders $Context
        Send-Response $Context $png 'image/png';return
    }
    if ($path -eq '/api/region' -and $method -eq 'GET') {
        $bytes=Get-LassoRegion
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
        Send-Json $Context @{items=@(Get-CaptureList $request.QueryString['q'])};return
    }
    if ($path -eq '/api/library' -and $method -eq 'POST') {
        $bytes=Read-Body $Context 25000000;Assert-Png $bytes
        $name='Lasso-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)+'.png'
        [IO.File]::WriteAllBytes((Join-Path $library $name),$bytes)
        Send-Json $Context @{name=$name};return
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
            $tags=@($metadata.tags | Select-Object -First 20 | ForEach-Object {
              $v=[string]$_;$v.Substring(0,[Math]::Min(40,$v.Length))
            })
            $note=[string]$metadata.note
            if ($note.Length -gt 2000) { $note=$note.Substring(0,2000) }
            @{tags=$tags;note=$note} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Get-MetaPath $name) -Encoding UTF8
            Send-Json $Context @{updated=$true};return
        }
    }
    Send-Json $Context @{error='Route not found'} 404
}
$base="http://127.0.0.1:$Port/"
Write-Host "Lasso $LassoVersion local server: $base" -ForegroundColor Red
Write-Host 'Press Ctrl+C in this console to stop.'
if (-not $NoBrowser) {
    try { Start-Process $base }
    catch { Write-Warning ('Browser did not open automatically: ' + $_.Exception.Message + '. Open ' + $base + ' manually.') }
}
try {
    while ($true) {
        $context=$null
        try {
            $context=$server.Accept()
            Invoke-LassoRequest $context
        } catch [System.IO.InvalidDataException] {
            Write-Warning ('Rejected malformed local HTTP request: ' + $_.Exception.Message)
        } catch {
            Write-Warning ('Local HTTP request failed: ' + $_.Exception.Message)
            if ($null -ne $context) {
                try { if ($context.Response.OutputStream.CanWrite) { Send-Json $context @{error='Request failed'} 500 } } catch {}
            }
        } finally {
            if ($null -ne $context) { $context.Dispose() }
        }
    }
} finally {
    $server.Dispose()
}