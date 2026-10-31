<#
  Starts a real SnapShackle host (no tray, no browser, its own temporary LOCALAPPDATA, a free port) and
  checks the share routes over HTTP: token required, bad capture names refused, a folder copy that never
  overwrites, settings sanitising. Nothing is captured from the screen; the test PNG is synthetic.
  Usage: powershell -NoProfile -STA -File tests/share_api_test.ps1
#>
$ErrorActionPreference = 'Stop'
$script:onActions = $env:GITHUB_ACTIONS -eq 'true'
function Write-Failure([string]$Text) {
    Write-Host $Text -ForegroundColor Red
    if ($script:onActions) { Write-Host ('::error title=share_api_test::' + ($Text -replace "`r?`n", ' ')) }
}
trap { Write-Failure ('Unhandled error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage); exit 1 }
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$work = Join-Path ([IO.Path]::GetTempPath()) ('ss-shareapi-' + [guid]::NewGuid().ToString('N'))
$appData = Join-Path $work 'appdata'; $dest = Join-Path $work 'dest'
[void][IO.Directory]::CreateDirectory($appData); [void][IO.Directory]::CreateDirectory($dest)
$script:failures = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS  $Name" } catch { $script:failures++; Write-Failure "FAIL  $Name :: $($_.Exception.Message)" }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

# A free loopback port.
$probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
$psi = [Diagnostics.ProcessStartInfo]::new((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'))
$psi.Arguments = '-NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Start-SnapShackle.ps1') + '" -NoBrowser -NoTray -AllowSecondInstance -Port ' + $port
$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$psi.EnvironmentVariables['LOCALAPPDATA'] = $appData
$psi.EnvironmentVariables['SNAPSHACKLE_AUTO_STOP'] = '0'
$proc = [Diagnostics.Process]::Start($psi)
$base = "http://127.0.0.1:$port"
function Invoke-Api([string]$Method, [string]$Path, $Body, [string]$Token, [byte[]]$Bytes, [string]$ContentType = 'application/json') {
    $req = [Net.HttpWebRequest]::Create($base + $Path); $req.Method = $Method; $req.Proxy = $null; $req.Timeout = 15000; $req.KeepAlive = $false; $req.ServicePoint.Expect100Continue = $false
    if ($Token) { $req.Headers.Add('X-SnapShackle-Token', $Token) }
    if ($null -ne $Body -or $null -ne $Bytes) {
        if ($null -eq $Bytes) { $Bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 6 -Compress)) }
        $req.ContentType = $ContentType; $req.ContentLength = $Bytes.Length
        $s = $req.GetRequestStream(); $s.Write($Bytes, 0, $Bytes.Length); $s.Close()
    }
    try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if ($null -eq $resp) { throw } }
    $reader = [IO.StreamReader]::new($resp.GetResponseStream()); $text = $reader.ReadToEnd(); $reader.Close()
    $status = [int]$resp.StatusCode; $resp.Close()
    $json = $null; try { $json = $text | ConvertFrom-Json } catch {}
    return [pscustomobject]@{ Status = $status; Text = $text; Json = $json }
}
try {
    $up = $false
    for ($i = 0; $i -lt 100 -and -not $up -and -not $proc.HasExited; $i++) {
        Start-Sleep -Milliseconds 200
        try { $up = (Invoke-Api 'GET' '/' $null '').Status -eq 200 } catch {}
    }
    if (-not $up) { throw ('the host did not start: ' + $proc.StandardError.ReadToEnd()) }
    # The studio script carries the session token, as it does for the browser.
    $studio = (Invoke-Api 'GET' '/assets/studio.js' $null '').Text
    $token = [regex]::Match($studio, "const TOKEN='([0-9a-f]{64})'").Groups[1].Value
    Assert-True ($token.Length -eq 64) 'no session token in studio.js'

    $png = [byte[]](137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130)
    $name = ''
    Test-Case 'a synthetic capture can be saved to the (temporary) library' {
        $r = Invoke-Api 'POST' '/api/library' $null $token $png 'image/png'
        Assert-True ($r.Status -eq 200 -and $r.Json.name -like 'SnapShackle-*.png') ('save failed: ' + $r.Text)
        $script:name = $r.Json.name
        Assert-True ([IO.File]::Exists((Join-Path $appData ('SnapShackle\Captures\' + $r.Json.name)))) 'capture not in the temporary library'
    }
    Test-Case 'share routes need the session token' {
        Assert-True ((Invoke-Api 'GET' '/api/share' $null '').Status -eq 403) 'GET without a token was allowed'
        Assert-True ((Invoke-Api 'POST' '/api/share' @{ capture = $script:name; kind = 'open' } '').Status -eq 403) 'POST without a token was allowed'
    }
    Test-Case 'share folders are saved through settings and listed' {
        $put = Invoke-Api 'PUT' '/api/settings' @{ shareFolders = @(@{ name = 'Team'; path = $dest }, @{ name = 'Nope'; path = 'relative' }) } $token
        Assert-True ($put.Status -eq 200 -and @($put.Json.shareFolders).Count -eq 1) ('settings: ' + $put.Text)
        $list = Invoke-Api 'GET' '/api/share' $null $token
        $kinds = @($list.Json.destinations | ForEach-Object { $_.kind }) -join ','
        Assert-True ($kinds -eq 'folder,clipboard,reveal,open') ('destinations: ' + $kinds)
        Assert-True ($list.Json.destinations[0].available -eq $true) 'folder should be available'
    }
    Test-Case 'a folder copy works twice without overwriting' {
        $a = Invoke-Api 'POST' '/api/share' @{ capture = $script:name; kind = 'folder'; destination = 'Team' } $token
        $b = Invoke-Api 'POST' '/api/share' @{ capture = $script:name; kind = 'folder'; destination = 'team' } $token
        Assert-True ($a.Status -eq 200 -and $b.Status -eq 200) ('copy failed: ' + $a.Text + ' / ' + $b.Text)
        Assert-True ($a.Json.name -ne $b.Json.name) 'second copy reused the first name'
        Assert-True (@(Get-ChildItem -LiteralPath $dest -Filter *.png).Count -eq 2) 'expected two files in the destination'
    }
    Test-Case 'bad requests are refused with a message, not a crash' {
        foreach ($case in @(
            @{ capture = '..\..\Windows\win.ini'; kind = 'folder'; destination = 'Team' },
            @{ capture = 'SnapShackle-missing.png'; kind = 'folder'; destination = 'Team' },
            @{ capture = $script:name; kind = 'folder'; destination = 'Unknown' },
            @{ capture = $script:name; kind = 'upload'; destination = '' })) {
            $r = Invoke-Api 'POST' '/api/share' $case $token
            Assert-True ($r.Status -eq 400 -and $r.Json.error) ('expected a 400 with an error for ' + ($case | ConvertTo-Json -Compress) + ', got ' + $r.Status + ' ' + $r.Text)
        }
        Assert-True ((Invoke-Api 'GET' '/api/health' $null $token).Status -eq 200) 'the host stopped answering after bad requests'
    }
} finally {
    try { if (-not $proc.HasExited) { $proc.Kill(); [void]$proc.WaitForExit(5000) } } catch {}
    try { [IO.Directory]::Delete($work, $true) } catch {}
}
if ($script:failures -gt 0) { Write-Failure "$($script:failures) share API test(s) failed"; exit 1 }
Write-Host 'All share API tests passed.' -ForegroundColor Green
