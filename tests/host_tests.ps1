<#
  Dependency-free tests for the pure .NET parts of the Lasso host:
  the loopback HTTP transport and the SnipHero library migration.
  Runs on Windows PowerShell 5.1 and PowerShell 7 (Windows or Linux).
  Usage: powershell -NoProfile -File tests/host_tests.ps1
#>
$ErrorActionPreference = 'Stop'
# On GitHub Actions, failures are also reported as annotations so they show on the PR checks.
$script:onActions = $env:GITHUB_ACTIONS -eq 'true'
function Write-Failure([string]$Text) {
    Write-Host $Text -ForegroundColor Red
    if ($script:onActions) { Write-Host ('::error title=host_tests::' + ($Text -replace "`r?`n", ' ')) }
}
trap { Write-Failure ('Unhandled error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage); exit 1 }
Write-Host ('PowerShell ' + $PSVersionTable.PSVersion + ' ' + $PSVersionTable.PSEdition)
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'modules/LocalHttp.ps1')
. (Join-Path $root 'modules/Migration.ps1')
. (Join-Path $root 'modules/Library.ps1')

$script:failures = 0
$script:passes = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passes++; Write-Host "PASS  $Name" }
    catch { $script:failures++; Write-Failure "FAIL  $Name :: $($_.Exception.Message)" }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

# Sends one raw HTTP request and returns the first response line ('' if the server closed without answering).
function Send-RawRequest([int]$Port, [string]$Raw) {
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $client.Connect([Net.IPAddress]::Loopback, $Port)
        $client.ReceiveTimeout = 5000
        $stream = $client.GetStream()
        $bytes = [Text.Encoding]::ASCII.GetBytes($Raw)
        $stream.Write($bytes, 0, $bytes.Length)
        $reader = [IO.StreamReader]::new($stream)
        try { return [string]$reader.ReadLine() } catch { return '' }
    } finally { $client.Close() }
}

# Accepts one connection on a background thread so the test can act as the client.
function Invoke-OneRequest($Server, [string]$Raw, [scriptblock]$Handler) {
    $ps = [PowerShell]::Create()
    $null = $ps.AddScript({
        param($srv, $handlerText)
        try {
            $ctx = $srv.Accept()
            try { & ([scriptblock]::Create($handlerText)) $ctx } finally { $ctx.Dispose() }
            'handled'
        } catch { 'rejected: ' + $_.Exception.InnerException.Message }
    }).AddArgument($Server).AddArgument($Handler.ToString())
    $async = $ps.BeginInvoke()
    $line = Send-RawRequest $Server.Port $Raw
    $outcome = $ps.EndInvoke($async)
    $ps.Dispose()
    return [pscustomobject]@{ StatusLine = $line; Outcome = [string]($outcome | Select-Object -First 1) }
}

$ok = {
    param($ctx)
    $body = [Text.Encoding]::UTF8.GetBytes('ok')
    $ctx.Response.StatusCode = 200
    $ctx.Response.ContentType = 'text/plain'
    $ctx.Response.SetBody($body)
    $ctx.Response.Close()
}

Test-Case 'Transport binds a loopback port and answers a valid request' {
    $server = [Lasso.Transport.Server]::new(28765, 20)
    try {
        $r = Invoke-OneRequest $server ("GET / HTTP/1.1`r`nHost: 127.0.0.1:" + $server.Port + "`r`n`r`n") $ok
        Assert-True ($r.StatusLine -eq 'HTTP/1.1 200 OK') "unexpected status '$($r.StatusLine)'"
    } finally { $server.Dispose() }
}

Test-Case 'Transport falls back when the preferred port is taken' {
    $holder = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $holder.Start()
    try {
        $taken = ([Net.IPEndPoint]$holder.LocalEndpoint).Port
        $server = [Lasso.Transport.Server]::new([Math]::Max(1024, $taken), 20)
        try { Assert-True ($server.Port -ne $taken) 'server reused an occupied port' }
        finally { $server.Dispose() }
    } finally { $holder.Stop() }
}

Test-Case 'Transport rejects a wrong Host header (DNS rebinding)' {
    $server = [Lasso.Transport.Server]::new(28800, 20)
    try {
        $r = Invoke-OneRequest $server "GET / HTTP/1.1`r`nHost: evil.example:80`r`n`r`n" $ok
        Assert-True ($r.Outcome -like 'rejected*') "request was not rejected: $($r.Outcome)"
        Assert-True ($r.StatusLine -eq '') 'rejected request still received a response'
    } finally { $server.Dispose() }
}

Test-Case 'Transport rejects chunked bodies' {
    $server = [Lasso.Transport.Server]::new(28830, 20)
    try {
        $raw = "POST /api/library HTTP/1.1`r`nHost: 127.0.0.1:" + $server.Port + "`r`nTransfer-Encoding: chunked`r`n`r`n0`r`n`r`n"
        $r = Invoke-OneRequest $server $raw $ok
        Assert-True ($r.Outcome -like 'rejected*') "chunked request was accepted: $($r.Outcome)"
    } finally { $server.Dispose() }
}

Test-Case 'Transport rejects duplicate headers' {
    $server = [Lasso.Transport.Server]::new(28860, 20)
    try {
        $raw = "GET / HTTP/1.1`r`nHost: 127.0.0.1:" + $server.Port + "`r`nX-Lasso-Token: a`r`nX-Lasso-Token: b`r`n`r`n"
        $r = Invoke-OneRequest $server $raw $ok
        Assert-True ($r.Outcome -like 'rejected*') "duplicate header accepted: $($r.Outcome)"
    } finally { $server.Dispose() }
}

function New-TempDir { $d = Join-Path ([IO.Path]::GetTempPath()) ('lasso-test-' + [guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($d); $d }

Test-Case 'Migration moves the whole legacy folder when Lasso has none' {
    $base = New-TempDir
    try {
        $legacy = Join-Path $base 'SnipHero/Captures'; [void][IO.Directory]::CreateDirectory($legacy)
        [IO.File]::WriteAllText((Join-Path $legacy 'SnipHero-1.png'), 'a')
        [IO.File]::WriteAllText((Join-Path $legacy 'SnipHero-1.png.meta.json'), '{}')
        $target = Join-Path $base 'Lasso/Captures'
        $r = Move-LassoLegacyLibrary -Legacy $legacy -Target $target 3>$null 6>$null
        Assert-True $r.WholeFolder 'expected a whole-folder move'
        Assert-True ($r.Moved -eq 2) "moved $($r.Moved), expected 2"
        Assert-True ([IO.File]::Exists((Join-Path $target 'SnipHero-1.png'))) 'capture missing after move'
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'Migration merges into an existing library without overwriting' {
    $base = New-TempDir
    try {
        $legacy = Join-Path $base 'SnipHero/Captures'; [void][IO.Directory]::CreateDirectory($legacy)
        $target = Join-Path $base 'Lasso/Captures'; [void][IO.Directory]::CreateDirectory($target)
        [IO.File]::WriteAllText((Join-Path $legacy 'SnipHero-new.png'), 'new')
        [IO.File]::WriteAllText((Join-Path $legacy 'SnipHero-dup.png'), 'legacy')
        [IO.File]::WriteAllText((Join-Path $target 'SnipHero-dup.png'), 'keep')
        $r = Move-LassoLegacyLibrary -Legacy $legacy -Target $target 3>$null 6>$null
        Assert-True ($r.Moved -eq 1 -and $r.Skipped -eq 1) "moved $($r.Moved) skipped $($r.Skipped)"
        Assert-True ([IO.File]::ReadAllText((Join-Path $target 'SnipHero-dup.png')) -eq 'keep') 'existing file was overwritten'
        Assert-True ([IO.File]::Exists((Join-Path $legacy 'SnipHero-dup.png'))) 'skipped file should stay in the legacy folder'
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'Migration is a no-op without a legacy folder' {
    $r = Move-LassoLegacyLibrary -Legacy (Join-Path ([IO.Path]::GetTempPath()) 'does-not-exist-lasso') -Target (Join-Path ([IO.Path]::GetTempPath()) 'unused-lasso')
    Assert-True ($r.Moved -eq 0 -and -not $r.WholeFolder) 'expected nothing to happen'
}

Test-Case 'Metadata edits keep the indexed OCR text' {
    $base = New-TempDir
    try {
        $name = Save-LassoCapture $base ([byte[]](1,2,3))
        Set-LassoMeta $base $name @{ ocr = 'Quarterly readiness report' }
        Set-LassoMeta $base $name @{ tags = @('ops','q3'); note = 'for review' }
        $meta = Get-LassoMeta $base $name
        Assert-True ($meta.ocr -eq 'Quarterly readiness report') "ocr text lost: '$($meta.ocr)'"
        Assert-True (($meta.tags -join ',') -eq 'ops,q3' -and $meta.note -eq 'for review') 'tags or note not saved'
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'Library search matches text inside images, names and tags' {
    $base = New-TempDir
    try {
        $a = Save-LassoCapture $base ([byte[]](1)); Set-LassoMeta $base $a @{ ocr = 'Deployment schedule for USS Example' }
        $b = Save-LassoCapture $base ([byte[]](2)); Set-LassoMeta $base $b @{ tags = @('schedule') }
        [IO.File]::WriteAllBytes((Join-Path $base 'SnipHero-old.png'), [byte[]](3))
        [IO.File]::WriteAllBytes((Join-Path $base 'unrelated.png'), [byte[]](4))
        $all = Get-LassoCaptureList $base ''
        Assert-True ($all.Count -eq 3) "expected 3 captures (old SnipHero name included, stray file excluded), got $($all.Count)"
        $hits = Get-LassoCaptureList $base 'SCHEDULE'
        Assert-True ($hits.Count -eq 2) "expected 2 hits, got $($hits.Count)"
        $byText = @($hits | Where-Object { $_.name -eq $a })[0]
        Assert-True ($byText.textMatch -and $byText.hasText) 'OCR match not flagged'
        Assert-True (-not @($hits | Where-Object { $_.name -eq $b })[0].textMatch) 'tag match wrongly flagged as text match'
        Assert-True ((Get-LassoCaptureList $base 'uss example').Count -eq 1) 'phrase search failed'
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'OCR indexing is a no-op where native OCR is unavailable' {
    $base = New-TempDir
    try {
        $name = Save-LassoCapture $base ([byte[]](1))
        $indexed = Update-LassoOcrIndex $base $name ([byte[]](1))
        if (-not (Get-Command Test-LassoOcr -ErrorAction SilentlyContinue)) { Assert-True (-not $indexed) 'claimed to index without OCR' }
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'Settings persist in a file and are sanitised' {
    $base = New-TempDir
    try {
        $path = Join-Path $base 'settings.json'
        $fresh = Get-LassoSettings $path
        Assert-True (-not $fresh.saved -and $fresh.namePrefix -eq 'Lasso' -and $fresh.recordFps -eq 6) 'bad defaults'
        $null = Set-LassoSettings $path ([pscustomobject]@{ namePrefix = 'My Shots!/..'; recordFps = 99; autoLibrary = $true; evil = 'x' })
        $saved = Get-LassoSettings $path
        Assert-True ($saved.saved -and $saved.namePrefix -eq 'MyShots' -and $saved.recordFps -eq 12 -and $saved.autoLibrary) "not sanitised: $($saved | ConvertTo-Json -Compress)"
        Assert-True (-not $saved.Contains('evil')) 'unknown key stored'
        $null = Set-LassoSettings $path @{ recordFps = 4 }
        $again = Get-LassoSettings $path
        Assert-True ($again.recordFps -eq 4 -and $again.namePrefix -eq 'MyShots') 'partial update lost other settings'
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'Every PowerShell file parses' {
    $errors = @()
    Get-ChildItem -Path $root -Recurse -File -Filter *.ps1 | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } | ForEach-Object {
        $tokens = $null; $parseErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$parseErrors)
        foreach ($e in $parseErrors) { $errors += ($_.Name + ':' + $e.Extent.StartLineNumber + ' ' + $e.Message) }
    }
    Assert-True ($errors.Count -eq 0) ($errors -join '; ')
}

Test-Case 'PowerShell files are ASCII (5.1 reads BOM-less files as ANSI)' {
    $bad = @(Get-ChildItem -Path $root -Recurse -File -Filter *.ps1 | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
        Where-Object { @([IO.File]::ReadAllBytes($_.FullName) | Where-Object { $_ -gt 127 }).Count -gt 0 } | ForEach-Object { $_.Name })
    Assert-True ($bad.Count -eq 0) ('non-ASCII bytes in: ' + ($bad -join ', '))
}

Write-Host ("{0} passed, {1} failed" -f $script:passes, $script:failures)
if ($script:failures -gt 0) { exit 1 }
