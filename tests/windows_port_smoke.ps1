<#
 Run on an authorized Windows workstation with Windows PowerShell 5.1.
 Tests that a busy port is skipped without stopping the process that owns it,
 and that the host serves the GUI and rejects unauthenticated API calls.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$hostScript = Join-Path $root 'Start-Lasso.ps1'
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$sentinel = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$sentinel.Start()
$occupiedPort = ([Net.IPEndPoint]$sentinel.LocalEndpoint).Port
$outFile = Join-Path $env:TEMP ('Lasso-stdout-' + [guid]::NewGuid().ToString('N') + '.txt')
$errFile = Join-Path $env:TEMP ('Lasso-stderr-' + [guid]::NewGuid().ToString('N') + '.txt')
$child = $null
try {
    $arg = '-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "' + $hostScript + '" -NoBrowser -Port ' + $occupiedPort + ' -PortScanCount 4'
    $child = Start-Process -FilePath $psExe -ArgumentList $arg -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile -WindowStyle Hidden
    $url = $null
    for ($i=0; $i -lt 120; $i++) {
        Start-Sleep -Milliseconds 100
        if (Test-Path $outFile) {
            $m = [regex]::Match(([IO.File]::ReadAllText($outFile)), 'http://127\.0\.0\.1:(\d+)/')
            if ($m.Success) { $url = $m.Value; break }
        }
        if ($child.HasExited) { throw ('Host exited unexpectedly: ' + ([IO.File]::ReadAllText($errFile))) }
    }
    if (-not $url) { throw ('Host did not announce its URL. Errors: ' + ([IO.File]::ReadAllText($errFile))) }
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
} finally {
    if ($child) { try { if (-not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue } } catch {} }
    $sentinel.Stop()
    Remove-Item -LiteralPath $outFile,$errFile -Force -ErrorAction SilentlyContinue
}