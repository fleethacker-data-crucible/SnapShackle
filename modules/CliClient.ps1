# CLI side of a SnapShackle action: talk to the running host the way snapshackle.ps1 always has.
# The host route calls the same action function. This file only carries the request across.

function New-SnapShackleCliResult([bool]$Ok, $Result, [string]$Error, [string]$ErrorType, [int]$Exit) {
    return @{ __fleet = $true; Ok = $Ok; Result = $Result; Error = $Error; ErrorType = $ErrorType; Exit = $Exit }
}

function Get-SnapShackleCliSession([string]$Root) {
    $dir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'SnapShackle' } else { Join-Path $Root 'captures' }
    $path = Get-SnapShackleSessionFilePath $dir
    if (-not [IO.File]::Exists($path)) { return $null }
    try { $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { return $null }
    $pidValue = 0
    foreach ($property in @($saved.PSObject.Properties)) { if ($property.Name -eq 'pid') { $pidValue = [int]$property.Value } }
    if (-not (Get-Process -Id $pidValue -ErrorAction SilentlyContinue)) { return $null }
    return $saved
}

function Invoke-SnapShackleCliHttp([string]$Method, [string]$Path, [string]$Token, [int]$Port, [byte[]]$Body, [string]$ContentType, [hashtable]$Headers = @{}) {
    $req = [Net.HttpWebRequest]::Create('http://127.0.0.1:' + $Port + $Path)
    $req.Method = $Method; $req.Proxy = $null; $req.Timeout = 60000; $req.KeepAlive = $false; $req.ServicePoint.Expect100Continue = $false
    $req.UserAgent = 'SnapShackle-CLI'
    $req.Headers.Add('X-SnapShackle-Token', $Token)
    foreach ($headerName in @($Headers.Keys)) { $req.Headers.Add($headerName, [string]$Headers[$headerName]) }
    if ($null -eq $Body -and $Method -ne 'GET') { $req.ContentLength = 0 }
    if ($null -ne $Body) { $req.ContentType = $ContentType; $req.ContentLength = $Body.Length; $stream = $req.GetRequestStream(); $stream.Write($Body, 0, $Body.Length); $stream.Close() }
    try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if ($null -eq $resp) { throw } }
    $memory = [IO.MemoryStream]::new(); $read = $resp.GetResponseStream(); $read.CopyTo($memory); $read.Close()
    $out = [pscustomobject]@{ Status = [int]$resp.StatusCode; Bytes = $memory.ToArray(); Type = [string]$resp.ContentType }
    $resp.Close(); $memory.Dispose()
    return $out
}

function ConvertFrom-SnapShackleCliBytes([byte[]]$Bytes) {
    try { return ([Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json) } catch { return $null }
}

function Get-SnapShackleCliValue($Arguments, [string]$Name) {
    if ($null -eq $Arguments) { return $null }
    if ($Arguments -is [hashtable]) {
        if (-not $Arguments.Contains($Name)) { return $null }
        return $Arguments[$Name]
    }
    foreach ($property in @($Arguments.PSObject.Properties)) { if ($property.Name -eq $Name) { return $property.Value } }
    return $null
}

function Test-SnapShackleCliValue($Arguments, [string]$Name) {
    if ($null -eq $Arguments) { return $false }
    if ($Arguments -is [hashtable]) { return $Arguments.Contains($Name) }
    foreach ($property in @($Arguments.PSObject.Properties)) { if ($property.Name -eq $Name) { return $true } }
    return $false
}

function Invoke-SnapShackleAppStart {
    param($Arguments, [string]$Root)
    $session = Get-SnapShackleCliSession $Root
    if ($null -ne $session) {
        return (New-SnapShackleCliResult $true ([ordered]@{ started = $false; alreadyRunning = $true; port = [int]$session.port; pid = [int]$session.pid }) '' '' 0)
    }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args2 = '-NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "' + (Join-Path $Root 'Start-SnapShackle.ps1') + '" -NoBrowser -NoTray -Replace'
    if (Test-SnapShackleCliValue $Arguments 'port') { $args2 += ' -Port ' + [int](Get-SnapShackleCliValue $Arguments 'port') }
    $env:SNAPSHACKLE_AUTO_STOP = '0'
    $process = Start-Process -FilePath $psExe -ArgumentList $args2 -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 150; $i++) {
        Start-Sleep -Milliseconds 200
        $session = Get-SnapShackleCliSession $Root
        if ($null -ne $session) {
            try {
                $response = Invoke-SnapShackleCliHttp 'GET' '/api/health' ([string]$session.token) ([int]$session.port) $null ''
                if ($response.Status -eq 200) { return (New-SnapShackleCliResult $true ([ordered]@{ started = $true; port = [int]$session.port; pid = [int]$session.pid }) '' '' 0) }
            } catch {}
        }
        if ($process.HasExited) { return (New-SnapShackleCliResult $false $null 'SnapShackle exited while starting (run Launch-SnapShackle.bat to see why)' 'failed' 1) }
    }
    return (New-SnapShackleCliResult $false $null 'SnapShackle did not answer within 30 seconds' 'failed' 1)
}

function Invoke-SnapShackleCliTransport {
    param($Arguments, $Context)
    $root = [string]$Context.Root
    $cmd = $Context.Command
    $name = [string]$cmd.name
    $opts = $Arguments
    $route = [string]$cmd.route
    $query = [Collections.Generic.List[string]]::new()
    $bodyObject = $null
    foreach ($spec in @($cmd.options)) {
        if (-not (Test-SnapShackleCliValue $opts $spec.name)) { continue }
        $value = [string](Get-SnapShackleCliValue $opts $spec.name)
        switch ($spec.in) {
            'path' { $route = $route.Replace('{' + $spec.name + '}', [Uri]::EscapeDataString($value)) }
            'query' { $query.Add($spec.name + '=' + [Uri]::EscapeDataString($value)) }
            'body' { if ($null -eq $bodyObject) { $bodyObject = [ordered]@{} }; $bodyObject[$spec.name] = $value }
        }
    }
    if ($name -eq 'capture rect') { $query.Clear(); foreach ($key in 'x', 'y', 'w', 'h') { $query.Add($key + '=' + (Get-SnapShackleCliValue $opts $key)) } }
    if ($query.Count -gt 0) { $route += '?' + ($query -join '&') }
    if ($name -eq 'library tag') {
        $bodyObject = [ordered]@{ tags = @(); note = '' }
        if (Test-SnapShackleCliValue $opts 'tags') { $bodyObject.tags = @(([string](Get-SnapShackleCliValue $opts 'tags')).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        if (Test-SnapShackleCliValue $opts 'note') { $bodyObject.note = [string](Get-SnapShackleCliValue $opts 'note') }
    }
    if ($name -eq 'settings set') {
        if (Test-SnapShackleCliValue $opts 'file') {
            $bodyObject = [IO.File]::ReadAllText([string](Get-SnapShackleCliValue $opts 'file')) | ConvertFrom-Json
        } else {
            $value = [string](Get-SnapShackleCliValue $opts 'value'); $typed = $value
            if ($value -in @('true', 'false')) { $typed = ($value -eq 'true') } elseif ($value -match '^-?\d{1,9}$') { $typed = [int]$value }
            $bodyObject = @{ ([string](Get-SnapShackleCliValue $opts 'key')) = $typed }
        }
    }
    $session = Get-SnapShackleCliSession $root
    if ($null -eq $session) { return (New-SnapShackleCliResult $false $null 'SnapShackle is not running. Start it with: snapshackle app start' 'notrunning' 3) }
    $token = [string]$session.token
    $port = [int]$session.port
    $bytes = $null
    $contentType = ''
    if ($cmd.request -eq 'png') {
        if (Test-SnapShackleCliValue $opts 'name') {
            $got = Invoke-SnapShackleCliHttp 'GET' ('/api/library/' + [Uri]::EscapeDataString([string](Get-SnapShackleCliValue $opts 'name'))) $token $port $null ''
            if ($got.Status -ne 200) { return (New-SnapShackleCliResult $false $null ('Capture not found: ' + (Get-SnapShackleCliValue $opts 'name')) 'failed' 1) }
            $bytes = $got.Bytes
        } else { $bytes = [IO.File]::ReadAllBytes([string](Get-SnapShackleCliValue $opts 'file')) }
        $contentType = 'image/png'
    } elseif ($null -ne $bodyObject) {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $bodyObject -Depth 8 -Compress))
        $contentType = 'application/json'
    }
    $headers = @{}
    if ($cmd.destructive -and $Context.Confirmed) { $headers['X-SnapShackle-Confirm'] = 'yes' }
    if ($name -eq 'session stop') { $headers['X-SnapShackle-Intent'] = 'end-session' }
    if ($name -eq 'session stop' -and $cmd.method -eq 'POST' -and $null -eq $bytes) { $bytes = [byte[]]@(); $contentType = 'application/json' }
    try { $response = Invoke-SnapShackleCliHttp $cmd.method $route $token $port $bytes $contentType $headers }
    catch { return (New-SnapShackleCliResult $false $null ('Could not reach SnapShackle: ' + $_.Exception.Message) 'notrunning' 3) }
    if ($response.Status -lt 200 -or $response.Status -ge 300) {
        $err = ConvertFrom-SnapShackleCliBytes $response.Bytes
        $message = 'HTTP ' + $response.Status
        if ($err) {
            foreach ($property in @($err.PSObject.Properties)) { if ($property.Name -eq 'error' -and $property.Value) { $message = [string]$property.Value } }
        }
        return (New-SnapShackleCliResult $false $null $message 'failed' 1)
    }
    if ($cmd.response -eq 'png') {
        $outPath = [string](Get-SnapShackleCliValue $opts 'out')
        if ($response.Bytes.Length -lt 8 -or $response.Bytes[0] -ne 137 -or $response.Bytes[1] -ne 80) { return (New-SnapShackleCliResult $false $null 'SnapShackle did not return a PNG' 'failed' 1) }
        [IO.File]::WriteAllBytes($outPath, $response.Bytes)
        $sha = [Security.Cryptography.SHA256]::Create()
        $hash = (($sha.ComputeHash($response.Bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
        $sha.Dispose()
        return (New-SnapShackleCliResult $true ([ordered]@{ file = $outPath; bytes = $response.Bytes.Length; sha256 = $hash }) '' '' 0)
    }
    $data = ConvertFrom-SnapShackleCliBytes $response.Bytes
    if ($name -eq 'session stop') { $data = [ordered]@{ stopped = $true } }
    return (New-SnapShackleCliResult $true $data '' '' 0)
}
