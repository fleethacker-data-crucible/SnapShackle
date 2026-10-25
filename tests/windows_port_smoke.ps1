<#
 Run on an authorized Windows workstation with Windows PowerShell 5.1.
 Tests that a busy port is skipped without stopping the process that owns it,
 and that the host serves the GUI and rejects unauthenticated API calls.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
# On GitHub Actions, report the reason as an annotation so it shows on the PR checks.
trap {
    $message = 'Port smoke test failed: ' + $_.Exception.Message
    Write-Host $message -ForegroundColor Red
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host ('::error title=windows_port_smoke::' + ($message -replace "`r?`n", ' ')) }
    exit 1
}
$root = Split-Path -Parent $PSScriptRoot
# The host rejects Expect: 100-continue, which Windows PowerShell adds to POSTs by default.
# Set before the first request: each host's ServicePoint copies the flag when it is created.
[Net.ServicePointManager]::Expect100Continue = $false
$hostScript = Join-Path $root 'Start-Lasso.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sentinel = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$sentinel.Start()
$occupiedPort = ([Net.IPEndPoint]$sentinel.LocalEndpoint).Port
$outFile = Join-Path $env:TEMP ('Lasso-stdout-' + [guid]::NewGuid().ToString('N') + '.txt')
$errFile = Join-Path $env:TEMP ('Lasso-stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
$child = $null
# The host still has its redirected output open for writing, so read with shared access.
function Read-SharedText([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { return [IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
}
try {
    $arg = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "' + $hostScript + '" -NoBrowser -NoTray -AllowSecondInstance -Port ' + $occupiedPort + ' -PortScanCount 4'
    $child = Start-Process -FilePath $psExe -ArgumentList $arg -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile -WindowStyle Hidden
    $url = $null
    for ($i=0; $i -lt 300; $i++) {
        Start-Sleep -Milliseconds 100
        if (Test-Path $outFile) {
            $m = [regex]::Match((Read-SharedText $outFile), 'http://127\.0\.0\.1:(\d+)/')
            if ($m.Success) { $url = $m.Value; break }
        }
        if ($child.HasExited) { throw ('Host exited unexpectedly: ' + (Read-SharedText $errFile)) }
    }
    if (-not $url) { throw ('Host did not announce its URL. Errors: ' + (Read-SharedText $errFile)) }
    if ($url -eq ('http://127.0.0.1:' + $occupiedPort + '/')) { throw 'Lasso attempted to reuse an occupied port' }
    if (-not $sentinel.Server.IsBound) { throw 'Existing server was disrupted' }
    $page = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 10
    if ($page.StatusCode -ne 200 -or $page.Content -notmatch 'LAS') { throw 'Studio HTML did not load' }
    try {
        $response=Invoke-WebRequest -UseBasicParsing -Uri ($url + 'api/health') -TimeoutSec 5
        throw 'Unauthenticated health route should return 403'
    } catch [System.Net.WebException] {
        if ([int]$_.Exception.Response.StatusCode -ne 403) { throw }
    }
    Write-Host ('PASS: preferred port ' + $occupiedPort + ' occupied, Lasso safely selected ' + $url)
    Write-Host 'PASS: studio HTML served; API authentication enforced; existing listener retained'

    # Lifecycle, end to end: runtime file, heartbeat auth, and auto-stop after the tab's leaving signal.
    $logs = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'Lasso\logs' } else { Join-Path $root 'logs' }
    $runtimeFile = Join-Path $logs ('lasso-server-' + $child.Id + '.json')
    if (-not (Test-Path -LiteralPath $runtimeFile)) { throw ('Runtime file missing: ' + $runtimeFile) }
    $runtime = Get-Content -LiteralPath $runtimeFile -Raw
    $info = $runtime | ConvertFrom-Json
    if ($info.pid -ne $child.Id -or $info.url -ne $url -or -not $info.startedAt) { throw ('Runtime file is incomplete: ' + $runtime) }
    $token = [regex]::Match((Invoke-WebRequest -UseBasicParsing -Uri ($url + 'assets/studio.js') -TimeoutSec 10).Content, "const TOKEN='([0-9a-f]{64})'").Groups[1].Value
    if (-not $token) { throw 'Session token not found in studio.js' }
    if ($runtime.Contains($token)) { throw 'Runtime file contains the session token' }
    function Send-Beat([string]$Body, [hashtable]$Headers = @{}, [string]$Query = '') {
        try { return [int](Invoke-WebRequest -UseBasicParsing -Method Post -Uri ($url + 'api/heartbeat' + $Query) -Headers $Headers -Body $Body -ContentType 'application/json' -TimeoutSec 5).StatusCode }
        catch [System.Net.WebException] { if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode } throw }
    }
    if ((Send-Beat '{"tab":"smoke"}') -ne 403) { throw 'Heartbeat without a token was accepted' }
    if ((Send-Beat '{"tab":"smoke"}' @{} ('?session=' + $token)) -ne 403) { throw 'Heartbeat accepted a token in the query string' }
    if ((Send-Beat '{"tab":"smoke","leaving":false}' @{ 'X-Lasso-Token' = $token }) -ne 200) { throw 'Heartbeat with the header token was refused' }
    # The beacon form: token in the body, no header.
    if ((Send-Beat ('{"tab":"smoke","leaving":true,"session":"' + $token + '"}')) -ne 200) { throw 'Leaving beacon with the body token was refused' }
    if (-not $child.WaitForExit(15000)) { throw 'Lasso kept running after the studio tab left' }
    if (Test-Path -LiteralPath $runtimeFile) { throw 'Runtime file was not removed when Lasso stopped' }
    Write-Host 'PASS: runtime file without token; heartbeat auth (header or beacon body, never query); auto-stop after the leaving signal'
} finally {
    if ($child) { try { if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } } catch {} }
    $sentinel.Stop()
    Remove-Item -LiteralPath $outFile,$errFile -Force -ErrorAction SilentlyContinue
}