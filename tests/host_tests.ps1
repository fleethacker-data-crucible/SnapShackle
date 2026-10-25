<#
  Dependency-free tests for the pure .NET parts of the Lasso host:
  the loopback HTTP transport, the SnipHero library migration and the lifecycle rules
  (the studio tab owns the server; time is simulated, nothing sleeps 20 s).
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
. (Join-Path $root 'modules/Lifecycle.ps1')

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
        Assert-True (-not $fresh.saved -and $fresh.namePrefix -eq 'Lasso' -and $fresh.recordFps -eq 6 -and $fresh.stayInTray -eq $false) 'bad defaults'
        $null = Set-LassoSettings $path ([pscustomobject]@{ namePrefix = 'My Shots!/..'; recordFps = 99; autoLibrary = $true; evil = 'x' })
        $saved = Get-LassoSettings $path
        Assert-True ($saved.saved -and $saved.namePrefix -eq 'MyShots' -and $saved.recordFps -eq 12 -and $saved.autoLibrary) "not sanitised: $($saved | ConvertTo-Json -Compress)"
        Assert-True (-not $saved.Contains('evil')) 'unknown key stored'
        $null = Set-LassoSettings $path @{ recordFps = 4 }
        $again = Get-LassoSettings $path
        Assert-True ($again.recordFps -eq 4 -and $again.namePrefix -eq 'MyShots') 'partial update lost other settings'
        $null = Set-LassoSettings $path @{ stayInTray = $true }
        Assert-True ((Get-LassoSettings $path).stayInTray -eq $true) 'stay-in-tray preference not saved'
        $null = Set-LassoSettings $path ([pscustomobject]@{ stayInTray = 'yes' })
        Assert-True ((Get-LassoSettings $path).stayInTray -eq $false) 'non-boolean stay-in-tray accepted as true'
    } finally { [IO.Directory]::Delete($base, $true) }
}

# ---- lifecycle: the studio tab owns the server (simulated clock) ----
$t0 = [datetime]::new(2026, 10, 24, 12, 0, 0, [DateTimeKind]::Utc)
function At([double]$Seconds) { $t0.AddSeconds($Seconds) }

Test-Case 'Lifecycle: keeps running while heartbeats arrive, stops 20 s after the last one' {
    $p = New-LassoPresence
    foreach ($s in 0, 5, 10, 15) { Register-LassoPresence $p 'tab-a' $false (At $s) }
    Assert-True ($null -eq (Get-LassoStopReason $p (At 34.5) $false $true)) 'stopped before 20 s without a heartbeat'
    Assert-True ($null -ne (Get-LassoStopReason $p (At 35) $false $true)) 'did not stop 20 s after the last heartbeat'
}

Test-Case 'Lifecycle: a leaving signal stops it 5 s later' {
    $p = New-LassoPresence
    Register-LassoPresence $p 'tab-a' $false (At 0)
    Register-LassoPresence $p 'tab-a' $true (At 2)
    Assert-True ($null -eq (Get-LassoStopReason $p (At 6.5) $false $true)) 'stopped inside the 5 s grace'
    Assert-True ($null -ne (Get-LassoStopReason $p (At 7) $false $true)) 'did not stop 5 s after leaving'
}

Test-Case 'Lifecycle: a reload (leaving, then a heartbeat from the new page) does not stop it' {
    $p = New-LassoPresence
    Register-LassoPresence $p 'page-1' $false (At 0)
    Register-LassoPresence $p 'page-1' $true (At 3)
    Register-LassoPresence $p 'page-2' $false (At 3.6)
    foreach ($s in 4, 8, 10, 20) { Assert-True ($null -eq (Get-LassoStopReason $p (At $s) $false $true)) "stopped at $s s after a reload" }
    # A visible heartbeat from the same page also cancels its leaving signal (bfcache restore).
    $q = New-LassoPresence
    Register-LassoPresence $q 'page-1' $true (At 0)
    Register-LassoPresence $q 'page-1' $false (At 1)
    Assert-True ($null -eq (Get-LassoStopReason $q (At 10) $false $true)) 'a visible heartbeat did not cancel leaving'
}

Test-Case 'Lifecycle: a hidden heartbeat sent while the tab closes does not cancel its leaving signal' {
    $p = New-LassoPresence
    Register-LassoPresence $p 'tab-a' $false (At 0)
    Register-LassoPresence $p 'tab-a' $true (At 1)
    Register-LassoPresence $p 'tab-a' $false (At 1.1) $true
    Assert-True ($null -ne (Get-LassoStopReason $p (At 6.2) $false $true)) 'hidden heartbeat kept a closed tab alive'
}

Test-Case 'Lifecycle: with two tabs open, closing one keeps it running' {
    $p = New-LassoPresence
    Register-LassoPresence $p 'tab-a' $false (At 0)
    Register-LassoPresence $p 'tab-b' $false (At 1)
    Register-LassoPresence $p 'tab-a' $true (At 2)
    Register-LassoPresence $p 'tab-b' $false (At 6)
    Assert-True ($null -eq (Get-LassoStopReason $p (At 10) $false $true)) 'stopped while tab-b is open'
    Register-LassoPresence $p 'tab-b' $true (At 11)
    Assert-True ($null -ne (Get-LassoStopReason $p (At 16) $false $true)) 'did not stop after the last tab left'
}

Test-Case 'Lifecycle: never stops while a capture is being saved, then stops on the next tick' {
    $p = New-LassoPresence
    Register-LassoPresence $p 'tab-a' $false (At 0)
    Register-LassoPresence $p 'tab-a' $true (At 1)
    Assert-True ($null -eq (Get-LassoStopReason $p (At 30) $true $true)) 'stopped while busy'
    Assert-True ($null -ne (Get-LassoStopReason $p (At 30.5) $false $true)) 'did not stop once the capture finished'
}

Test-Case 'Lifecycle: -Stay / LASSO_AUTO_STOP=0 never stop it' {
    $p = New-LassoPresence (At 10)
    Register-LassoPresence $p 'tab-a' $true (At 0)
    Assert-True ($null -eq (Get-LassoStopReason $p (At 3600) $false $false)) 'stopped with auto-stop off'
    foreach ($v in '0', 'false', 'OFF', ' no ') { Assert-True (-not (Test-LassoAutoStopEnv $v)) "LASSO_AUTO_STOP=$v should disable auto-stop" }
    foreach ($v in $null, '', '1', 'true') { Assert-True (Test-LassoAutoStopEnv $v) "LASSO_AUTO_STOP=$v should keep auto-stop on" }
}

Test-Case 'Lifecycle: a hidden (throttled) tab gets 75 s, a never-connected browser 2 minutes' {
    $p = New-LassoPresence
    Register-LassoPresence $p 'tab-a' $false (At 0) $true
    Assert-True ($null -eq (Get-LassoStopReason $p (At 60) $false $true)) 'hidden tab stopped after 60 s'
    Assert-True ($null -ne (Get-LassoStopReason $p (At 75) $false $true)) 'hidden tab kept it running past 75 s'
    $never = New-LassoPresence (At 120)
    Assert-True ($null -eq (Get-LassoStopReason $never (At 119) $false $true)) 'stopped before the browser could connect'
    Assert-True ($null -ne (Get-LassoStopReason $never (At 120) $false $true)) 'kept running with no browser ever connecting'
    $headless = New-LassoPresence
    Assert-True ($null -eq (Get-LassoStopReason $headless (At 9999) $false $true)) '-NoBrowser with no tab yet should keep running'
}

Test-Case 'Lifecycle: after the PC sleeps, open tabs get a fresh grace period' {
    $p = New-LassoPresence
    Register-LassoPresence $p 'tab-a' $false (At 0)
    Assert-True (-not (Step-LassoPresenceClock $p (At 0.5))) 'first tick reported a gap'
    Assert-True (-not (Step-LassoPresenceClock $p (At 1))) 'normal tick reported a gap'
    Assert-True (Step-LassoPresenceClock $p (At 3600)) 'an hour-long gap was not detected'
    Assert-True ($null -eq (Get-LassoStopReason $p (At 3610) $false $true)) 'stopped right after waking'
    Assert-True ($null -ne (Get-LassoStopReason $p (At 3620) $false $true)) 'did not stop 20 s after waking with no tab'
}

Test-Case 'Lifecycle: heartbeat bodies, token comparison and launcher options' {
    $b = ConvertFrom-LassoHeartbeat '{"tab":"abc-1","leaving":true,"session":"s3cret"}'
    Assert-True ($b.Tab -eq 'abc-1' -and $b.Leaving -and $b.Session -eq 's3cret' -and -not $b.Hidden) 'beacon body not parsed'
    Assert-True ($null -eq (ConvertFrom-LassoHeartbeat '[1,2]')) 'array body accepted'
    Assert-True ($null -eq (ConvertFrom-LassoHeartbeat 'not json')) 'invalid body accepted'
    Assert-True ($null -eq (ConvertFrom-LassoHeartbeat '"text"') -and $null -eq (ConvertFrom-LassoHeartbeat '42')) 'scalar body accepted'
    $plain = ConvertFrom-LassoHeartbeat '{"tab":"abc-1","hidden":true}'
    Assert-True ($plain.Tab -eq 'abc-1' -and -not $plain.Leaving -and $plain.Hidden -and $plain.Session -eq '') 'heartbeat body not parsed'
    Assert-True (-not (ConvertFrom-LassoHeartbeat '').Leaving) 'empty body should be a plain heartbeat'
    Assert-True (Test-LassoSecretEquals 'abc' 'abc') 'equal tokens differ'
    Assert-True (-not (Test-LassoSecretEquals 'abc' 'abd') -and -not (Test-LassoSecretEquals '' '') -and -not (Test-LassoSecretEquals 'ab' 'abc')) 'unequal tokens match'
    $o = Read-LassoLaunchOptions @('--stay', '--replace', '--no-browser', '-NoTray', '--bogus')
    Assert-True ($o.Stay -and $o.Replace -and $o.NoBrowser -and $o.NoTray) 'launcher options not read'
    Assert-True (($o.Unknown -join ',') -eq '--bogus') 'unknown option not reported'
    $p = New-LassoPresence
    Register-LassoPresence $p ('x' * 80) $false (At 0)
    Assert-True ($p.Tabs.ContainsKey('default')) 'oversized tab id was stored'
    for ($i = 0; $i -lt 40; $i++) { Register-LassoPresence $p ('t' + $i) $false (At $i) }
    Assert-True ($p.Tabs.Count -le 32) "tab table grew to $($p.Tabs.Count)"
}

Test-Case 'Lifecycle: runtime file has pid/port/url/startedAt but no token; stale files are removed' {
    $dir = New-TempDir
    try {
        $path = Write-LassoRuntimeFile $dir $PID 8765 'http://127.0.0.1:8765/' $false
        $info = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        Assert-True ($info.pid -eq $PID -and $info.port -eq 8765 -and $info.url -eq 'http://127.0.0.1:8765/' -and $info.startedAt) 'runtime file fields missing'
        Assert-True (@($info.PSObject.Properties.Name | Where-Object { $_ -match 'token|session' }).Count -eq 0) 'runtime file must never hold the session token'
        Assert-True ((Split-Path -Leaf $path) -eq ('lasso-server-' + $PID + '.json')) 'runtime file name'
        # A dead pid (no such process) and an unreadable file are deleted on sight; this process is never listed.
        $stale = Join-Path $dir 'lasso-server-2147480000.json'
        [IO.File]::WriteAllText($stale, '{"pid":2147480000,"port":1,"url":"x","startedAt":"2020-01-01T00:00:00Z"}')
        $junk = Join-Path $dir 'lasso-server-1.json'
        [IO.File]::WriteAllText($junk, 'garbage')
        $found = @(Get-LassoProcesses $dir -RuntimeFilesOnly)
        Assert-True (-not [IO.File]::Exists($stale) -and -not [IO.File]::Exists($junk)) 'stale runtime files were kept'
        Assert-True ([IO.File]::Exists($path)) 'the live runtime file was deleted'
        Assert-True (@($found | Where-Object { $_.Pid -eq $PID }).Count -eq 0) 'listed this process as another Lasso'
        Remove-LassoRuntimeFile $path
        Assert-True (-not [IO.File]::Exists($path)) 'runtime file not removed on stop'
    } finally { [IO.Directory]::Delete($dir, $true) }
}

$onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
if ($onWindows) {
    Test-Case 'Lifecycle: Stop-LassoProcesses asks a running instance to stop (no PID needed) and it exits itself' {
        $dir = New-TempDir
        $child = $null
        try {
            # Stands in for a Lasso host: owns the named stop event and exits with 7 when it is signalled.
            $childScript = '$e=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,''Local\Lasso-Stop-''+$PID); [void]$e.WaitOne(60000); exit 7'
            $exe = (Get-Process -Id $PID).Path
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
            $child = Start-Process -FilePath $exe -ArgumentList ('-NoProfile -NoLogo -EncodedCommand ' + $encoded) -PassThru -WindowStyle Hidden
            $null = $child.Handle  # cache the handle so ExitCode is readable after exit
            $null = Write-LassoRuntimeFile $dir $child.Id 1 'http://127.0.0.1:1/' $false
            $ready = $false; $probe = $null
            for ($i = 0; $i -lt 100 -and -not $ready; $i++) {
                if ([Threading.EventWaitHandle]::TryOpenExisting((Get-LassoStopEventName $child.Id), [ref]$probe)) { $probe.Dispose(); $ready = $true } else { Start-Sleep -Milliseconds 100 }
            }
            Assert-True $ready 'stand-in host never created its stop event'
            $stopped = @(Stop-LassoProcesses $dir 10 -RuntimeFilesOnly)
            Assert-True ($stopped -contains $child.Id) 'instance not reported as stopped'
            $child.WaitForExit(5000) | Out-Null
            Assert-True ($child.ExitCode -eq 7) "instance was force-killed instead of stopping itself (exit $($child.ExitCode))"
            Assert-True (@([IO.Directory]::GetFiles($dir, 'lasso-server-*.json')).Count -eq 0) 'runtime file left behind'
        } finally {
            if ($child -and -not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
            [IO.Directory]::Delete($dir, $true)
        }
    }
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
