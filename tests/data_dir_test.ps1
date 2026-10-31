<#
  Tests the data folder option (-DataDir, --data-dir, SNAPSHACKLE_DATA_DIR) that keeps a demo or trial run away from
  the real %LOCALAPPDATA%\SnapShackle. Part 1 runs the option parsing in this process. Part 2 starts real hosts (no tray,
  no browser) whose LOCALAPPDATA is an empty "sentinel" folder, saves a synthetic capture, a setting and tags, and checks
  that everything landed under the data folder and that the sentinel stayed empty. Nothing is captured from the screen.
  Usage: powershell -NoProfile -STA -File tests/data_dir_test.ps1
#>
$ErrorActionPreference = 'Stop'
$script:onActions = $env:GITHUB_ACTIONS -eq 'true'
function Write-Failure([string]$Text) {
    Write-Host $Text -ForegroundColor Red
    if ($script:onActions) { Write-Host ('::error title=data_dir_test::' + ($Text -replace "`r?`n", ' ')) }
}
trap { Write-Failure ('Unhandled error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage); exit 1 }
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$work = Join-Path ([IO.Path]::GetTempPath()) ('ss-datadir-' + [guid]::NewGuid().ToString('N'))
$sentinel = Join-Path $work 'sentinel-localappdata'; [void][IO.Directory]::CreateDirectory($sentinel)
$script:failures = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS  $Name" } catch { $script:failures++; Write-Failure "FAIL  $Name :: $($_.Exception.Message)" }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
. (Join-Path $root 'modules\Lifecycle.ps1')
$savedLocal = [Environment]::GetEnvironmentVariable('LOCALAPPDATA'); $savedDir = [Environment]::GetEnvironmentVariable('SNAPSHACKLE_DATA_DIR')

try {
    Test-Case 'launcher options accept --data-dir in both forms and still report unknown options' {
        $o = Read-SnapShackleLaunchOptions @('--stay', '--data-dir', 'C:\Demo\One', '--bogus')
        Assert-True ($o.Stay -and $o.DataDir -eq 'C:\Demo\One' -and ($o.Unknown -join ',') -eq '--bogus') ('spaced form: ' + ($o | ConvertTo-Json -Compress))
        $o = Read-SnapShackleLaunchOptions @('--data-dir=C:\Demo\Two', '-NoTray')
        Assert-True ($o.DataDir -eq 'C:\Demo\Two' -and $o.NoTray) 'equals form'
        $o = Read-SnapShackleLaunchOptions @('--data-dir')
        Assert-True ($null -eq $o.DataDir -and $o.Unknown.Count -eq 1) 'a --data-dir with no folder should be reported, not swallowed'
        Assert-True ($null -eq (Read-SnapShackleLaunchOptions @('--stay')).DataDir) 'no option, no data dir'
    }
    Test-Case 'the data folder must be a full path; the parameter wins over the environment; the folder is created' {
        [Environment]::SetEnvironmentVariable('SNAPSHACKLE_DATA_DIR', $null)
        Assert-True ($null -eq (Set-SnapShackleDataRoot '')) 'nothing asked, nothing changed'
        foreach ($bad in 'demo', '.\demo', 'C:\dem*', 'C:\a|b', 'C', 'C:\') {
            $threw = $false; try { [void](Set-SnapShackleDataRoot $bad) } catch { $threw = $true }
            Assert-True $threw "accepted '$bad'"
        }
        Assert-True ([Environment]::GetEnvironmentVariable('LOCALAPPDATA') -eq $savedLocal) 'a refused folder must not change LOCALAPPDATA'
        $fromEnv = Join-Path $work 'from-env'; $fromParam = Join-Path $work 'from-param'
        [Environment]::SetEnvironmentVariable('SNAPSHACKLE_DATA_DIR', $fromEnv)
        Assert-True ((Set-SnapShackleDataRoot $null) -eq $fromEnv -and [IO.Directory]::Exists($fromEnv) -and $env:LOCALAPPDATA -eq $fromEnv) 'environment form'
        Assert-True ((Set-SnapShackleDataRoot ('"' + $fromParam + '"')) -eq $fromParam -and $env:LOCALAPPDATA -eq $fromParam) 'parameter wins, quotes are trimmed'
        Assert-True ((Get-SnapShackleRuntimeDir $root) -eq (Join-Path $fromParam 'SnapShackle\logs')) 'runtime files follow the data folder'
        [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $savedLocal); [Environment]::SetEnvironmentVariable('SNAPSHACKLE_DATA_DIR', $null)
    }

    $png = [byte[]](137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130)
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    function Get-FreePort { $p = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $p.Start(); $n = $p.LocalEndpoint.Port; $p.Stop(); return $n }
    function Invoke-Api([string]$Base, [string]$Method, [string]$Path, $Body, [string]$Token, [byte[]]$Bytes, [string]$ContentType = 'application/json', [hashtable]$Headers = @{}) {
        $req = [Net.HttpWebRequest]::Create($Base + $Path); $req.Method = $Method; $req.Proxy = $null; $req.Timeout = 20000; $req.KeepAlive = $false; $req.ServicePoint.Expect100Continue = $false
        if ($Token) { $req.Headers.Add('X-SnapShackle-Token', $Token) }
        foreach ($k in $Headers.Keys) { $req.Headers.Add($k, $Headers[$k]) }
        if ($null -ne $Body -or $null -ne $Bytes) {
            if ($null -eq $Bytes) { $Bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 6 -Compress)) }
            $req.ContentType = $ContentType; $req.ContentLength = $Bytes.Length
            $s = $req.GetRequestStream(); $s.Write($Bytes, 0, $Bytes.Length); $s.Close()
        } elseif ($Method -in @('PUT', 'POST', 'DELETE')) { $req.ContentLength = 0 }
        try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if ($null -eq $resp) { throw } }
        $reader = [IO.StreamReader]::new($resp.GetResponseStream()); $text = $reader.ReadToEnd(); $reader.Close()
        $status = [int]$resp.StatusCode; $resp.Close()
        $json = $null; try { $json = $text | ConvertFrom-Json } catch {}
        return [pscustomobject]@{ Status = $status; Text = $text; Json = $json }
    }
    # Runs one host with the given extra arguments, saves a capture, a setting and tags, stops it, and returns what it did.
    function Invoke-DemoRun([string[]]$ExtraArgs) {
        $port = Get-FreePort
        $psi = [Diagnostics.ProcessStartInfo]::new($psExe)
        $psi.Arguments = '-NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Start-SnapShackle.ps1') + '" -NoBrowser -NoTray -AllowSecondInstance -Port ' + $port + ' ' + ($ExtraArgs -join ' ')
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['LOCALAPPDATA'] = $sentinel; $psi.EnvironmentVariables['SNAPSHACKLE_AUTO_STOP'] = '0'
        $proc = [Diagnostics.Process]::Start($psi)
        $base = "http://127.0.0.1:$port"
        try {
            $up = $false
            for ($i = 0; $i -lt 100 -and -not $up -and -not $proc.HasExited; $i++) { Start-Sleep -Milliseconds 200; try { $up = (Invoke-Api $base 'GET' '/' $null '').Status -eq 200 } catch {} }
            if (-not $up) { throw ('the host did not start: ' + $proc.StandardError.ReadToEnd()) }
            $studio = (Invoke-Api $base 'GET' '/assets/studio.js' $null '').Text
            $token = [regex]::Match($studio, "const TOKEN='([0-9a-f]{64})'").Groups[1].Value
            $health = Invoke-Api $base 'GET' '/api/health' $null $token
            $saved = Invoke-Api $base 'POST' '/api/library' $null $token $png 'image/png'
            $null = Invoke-Api $base 'PUT' '/api/settings' @{ namePrefix = 'DemoRun' } $token
            $null = Invoke-Api $base 'PUT' ('/api/library/' + $saved.Json.name) @{ tags = @('demo'); note = 'synthetic' } $token
            $null = Invoke-Api $base 'POST' '/api/session/stop' $null $token $null 'application/json' @{ 'X-SnapShackle-Intent' = 'end-session' }
            [void]$proc.WaitForExit(15000)
            return [pscustomobject]@{ Health = $health.Json; Name = $saved.Json.name }
        } finally { try { if (-not $proc.HasExited) { $proc.Kill(); [void]$proc.WaitForExit(5000) } } catch {} }
    }
    function Assert-DemoFolder([string]$Folder, [string]$Name) {
        $app = Join-Path $Folder 'SnapShackle'
        Assert-True ([IO.File]::Exists((Join-Path $app ('Captures\' + $Name)))) 'the capture is not under the data folder'
        Assert-True ([IO.File]::Exists((Join-Path $app ('Captures\' + $Name + '.meta.json')))) 'the sidecar is not under the data folder'
        Assert-True ([IO.File]::Exists((Join-Path $app 'settings.json')) -and ([IO.File]::ReadAllText((Join-Path $app 'settings.json'))) -match 'DemoRun') 'settings are not under the data folder'
        Assert-True ([IO.Directory]::Exists((Join-Path $app 'logs'))) 'logs are not under the data folder'
        Assert-True (@(Get-ChildItem -LiteralPath $sentinel -Force -Recurse).Count -eq 0) ('something was written to the real LOCALAPPDATA: ' + ((Get-ChildItem -LiteralPath $sentinel -Force -Recurse | ForEach-Object { $_.FullName }) -join '; '))
    }

    Test-Case '-DataDir keeps captures, settings and logs under the data folder and writes nothing to LOCALAPPDATA' {
        $folder = Join-Path $work 'demo-a'
        $run = Invoke-DemoRun @('-DataDir', ('"' + $folder + '"'))
        Assert-True ($run.Health.customDataDir -eq $true) ('health should say a custom data folder is in use: ' + ($run.Health | ConvertTo-Json -Compress))
        Assert-DemoFolder $folder $run.Name
    }
    Test-Case '--data-dir= (the launcher form) does the same' {
        $folder = Join-Path $work 'demo-b'
        $run = Invoke-DemoRun @(('--data-dir="' + $folder + '"'))
        Assert-True ($run.Health.customDataDir -eq $true) 'launcher form not honoured'
        Assert-DemoFolder $folder $run.Name
    }
} finally {
    [Environment]::SetEnvironmentVariable('LOCALAPPDATA', $savedLocal); [Environment]::SetEnvironmentVariable('SNAPSHACKLE_DATA_DIR', $savedDir)
    try { [IO.Directory]::Delete($work, $true) } catch {}
}
if ($script:failures -gt 0) { Write-Failure "$($script:failures) data folder test(s) failed"; exit 1 }
Write-Host 'All data folder tests passed.' -ForegroundColor Green
