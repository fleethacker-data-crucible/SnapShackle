<#
  Dependency-free tests for the pure .NET parts of the SnapShackle host:
  the loopback HTTP transport, the CutterMk / Lasso / SnipHero migrations and the lifecycle rules
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
    $server = [SnapShackle.Transport.Server]::new(28765, 20)
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
        $server = [SnapShackle.Transport.Server]::new([Math]::Max(1024, $taken), 20)
        try { Assert-True ($server.Port -ne $taken) 'server reused an occupied port' }
        finally { $server.Dispose() }
    } finally { $holder.Stop() }
}

Test-Case 'Transport rejects a wrong Host header (DNS rebinding)' {
    $server = [SnapShackle.Transport.Server]::new(28800, 20)
    try {
        $r = Invoke-OneRequest $server "GET / HTTP/1.1`r`nHost: evil.example:80`r`n`r`n" $ok
        Assert-True ($r.Outcome -like 'rejected*') "request was not rejected: $($r.Outcome)"
        Assert-True ($r.StatusLine -eq '') 'rejected request still received a response'
    } finally { $server.Dispose() }
}

Test-Case 'Transport rejects chunked bodies' {
    $server = [SnapShackle.Transport.Server]::new(28830, 20)
    try {
        $raw = "POST /api/library HTTP/1.1`r`nHost: 127.0.0.1:" + $server.Port + "`r`nTransfer-Encoding: chunked`r`n`r`n0`r`n`r`n"
        $r = Invoke-OneRequest $server $raw $ok
        Assert-True ($r.Outcome -like 'rejected*') "chunked request was accepted: $($r.Outcome)"
    } finally { $server.Dispose() }
}

Test-Case 'Transport rejects duplicate headers' {
    $server = [SnapShackle.Transport.Server]::new(28860, 20)
    try {
        $raw = "GET / HTTP/1.1`r`nHost: 127.0.0.1:" + $server.Port + "`r`nX-SnapShackle-Token: a`r`nX-SnapShackle-Token: b`r`n`r`n"
        $r = Invoke-OneRequest $server $raw $ok
        Assert-True ($r.Outcome -like 'rejected*') "duplicate header accepted: $($r.Outcome)"
    } finally { $server.Dispose() }
}

function New-TempDir { $d = Join-Path ([IO.Path]::GetTempPath()) ('snapshackle-test-' + [guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($d); $d }

Test-Case 'Migration moves the whole legacy folder when SnapShackle has none' {
    $base = New-TempDir
    try {
        $legacy = Join-Path $base 'SnipHero/Captures'; [void][IO.Directory]::CreateDirectory($legacy)
        [IO.File]::WriteAllText((Join-Path $legacy 'SnipHero-1.png'), 'a')
        [IO.File]::WriteAllText((Join-Path $legacy 'SnipHero-1.png.meta.json'), '{}')
        $target = Join-Path $base 'SnapShackle/Captures'
        $r = Move-SnapShackleLegacyLibrary -Legacy $legacy -Target $target 3>$null 6>$null
        Assert-True $r.WholeFolder 'expected a whole-folder move'
        Assert-True ($r.Moved -eq 2) "moved $($r.Moved), expected 2"
        Assert-True ([IO.File]::Exists((Join-Path $target 'SnipHero-1.png'))) 'capture missing after move'
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'Migration merges into an existing library without overwriting' {
    $base = New-TempDir
    try {
        $legacy = Join-Path $base 'SnipHero/Captures'; [void][IO.Directory]::CreateDirectory($legacy)
        $target = Join-Path $base 'SnapShackle/Captures'; [void][IO.Directory]::CreateDirectory($target)
        [IO.File]::WriteAllText((Join-Path $legacy 'SnipHero-new.png'), 'new')
        [IO.File]::WriteAllText((Join-Path $legacy 'SnipHero-dup.png'), 'legacy')
        [IO.File]::WriteAllText((Join-Path $target 'SnipHero-dup.png'), 'keep')
        $r = Move-SnapShackleLegacyLibrary -Legacy $legacy -Target $target 3>$null 6>$null
        Assert-True ($r.Moved -eq 1 -and $r.Skipped -eq 1) "moved $($r.Moved) skipped $($r.Skipped)"
        Assert-True ([IO.File]::ReadAllText((Join-Path $target 'SnipHero-dup.png')) -eq 'keep') 'existing file was overwritten'
        Assert-True ([IO.File]::Exists((Join-Path $legacy 'SnipHero-dup.png'))) 'skipped file should stay in the legacy folder'
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'Upgrade from Lasso and SnipHero keeps every capture and the settings' {
    $base = New-TempDir
    try {
        $lasso = Join-Path $base 'Lasso'; $snip = Join-Path $base 'SnipHero'
        [void][IO.Directory]::CreateDirectory((Join-Path $lasso 'Captures')); [void][IO.Directory]::CreateDirectory((Join-Path $snip 'Captures'))
        [IO.File]::WriteAllText((Join-Path $lasso 'Captures/Lasso-1.png'), 'l')
        [IO.File]::WriteAllText((Join-Path $snip 'Captures/SnipHero-1.png'), 's')
        [IO.File]::WriteAllText((Join-Path $lasso 'settings.json'), '{"namePrefix":"Lasso","recordFps":9,"theme":"light"}')
        $app = Join-Path $base 'SnapShackle'
        Invoke-SnapShackleMigration -BaseDir $base -AppDir $app 3>$null 6>$null
        $names = @([IO.Directory]::GetFiles((Join-Path $app 'Captures')) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
        Assert-True (($names -join ',') -eq 'Lasso-1.png,SnipHero-1.png') "captures after upgrade: $($names -join ',')"
        $settings = Get-SnapShackleSettings (Join-Path $app 'settings.json')
        Assert-True ($settings.saved -and $settings.recordFps -eq 9 -and $settings.theme -eq 'light') 'settings not carried over'
        Assert-True ($settings.namePrefix -eq 'SnapShackle') "old default prefix not renamed: $($settings.namePrefix)"
        Assert-True ((Get-SnapShackleCaptureList (Join-Path $app 'Captures') '').Count -eq 2) 'old capture names not listed'
        Invoke-SnapShackleMigration -BaseDir $base -AppDir $app 3>$null 6>$null
        Assert-True (@([IO.Directory]::GetFiles((Join-Path $app 'Captures'))).Count -eq 2) 'second run changed the library'
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'Upgrade from CutterMk copies captures and settings forward once and leaves CutterMk untouched' {
    $base = New-TempDir
    try {
        $old = Join-Path $base 'CutterMk'
        [void][IO.Directory]::CreateDirectory((Join-Path $old 'Captures')); [void][IO.Directory]::CreateDirectory((Join-Path $old 'logs'))
        [IO.File]::WriteAllText((Join-Path $old 'Captures/CutterMk-1.png'), 'c')
        [IO.File]::WriteAllText((Join-Path $old 'Captures/CutterMk-1.png.meta.json'), '{"tags":["kept"],"note":"","ocr":""}')
        [IO.File]::WriteAllText((Join-Path $old 'settings.json'), '{"namePrefix":"CutterMk","recordFps":8,"theme":"system"}')
        [IO.File]::WriteAllText((Join-Path $old 'logs/cuttermk-server-1.json'), '{}')
        $app = Join-Path $base 'SnapShackle'
        Invoke-SnapShackleMigration -BaseDir $base -AppDir $app 3>$null 6>$null
        Assert-True ([IO.File]::ReadAllText((Join-Path $app 'Captures/CutterMk-1.png')) -eq 'c') 'capture not copied'
        Assert-True ([IO.File]::Exists((Join-Path $app 'Captures/CutterMk-1.png.meta.json'))) 'sidecar not copied'
        Assert-True (-not [IO.Directory]::Exists((Join-Path $app 'logs'))) 'runtime files of a running CutterMk must not be copied'
        Assert-True ([IO.File]::Exists((Join-Path $old 'Captures/CutterMk-1.png')) -and [IO.File]::Exists((Join-Path $old 'settings.json')) -and [IO.File]::Exists((Join-Path $old 'logs/cuttermk-server-1.json'))) 'CutterMk folder was changed'
        Assert-True (@([IO.Directory]::GetDirectories($base, 'SnapShackle.migrating-*')).Count -eq 0) 'staging folder left behind'
        $settings = Get-SnapShackleSettings (Join-Path $app 'settings.json')
        Assert-True ($settings.saved -and $settings.recordFps -eq 8 -and $settings.theme -eq 'system') 'settings not carried over'
        Assert-True ($settings.namePrefix -eq 'SnapShackle') "old default prefix not renamed: $($settings.namePrefix)"
        Assert-True ((Get-SnapShackleCaptureList (Join-Path $app 'Captures') '').Count -eq 1) 'CutterMk capture names not listed'
        # Runs once: later CutterMk captures are not copied again, and SnapShackle's own files are never overwritten.
        [IO.File]::WriteAllText((Join-Path $app 'Captures/CutterMk-1.png'), 'edited')
        [IO.File]::WriteAllText((Join-Path $old 'Captures/CutterMk-2.png'), 'later')
        Invoke-SnapShackleMigration -BaseDir $base -AppDir $app 3>$null 6>$null
        Assert-True ([IO.File]::ReadAllText((Join-Path $app 'Captures/CutterMk-1.png')) -eq 'edited') 'second run overwrote a SnapShackle file'
        Assert-True (-not [IO.File]::Exists((Join-Path $app 'Captures/CutterMk-2.png'))) 'second run copied again'
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'Upgrade chain: CutterMk is copied, Lasso leftovers are still moved' {
    $base = New-TempDir
    try {
        [void][IO.Directory]::CreateDirectory((Join-Path $base 'CutterMk/Captures')); [void][IO.Directory]::CreateDirectory((Join-Path $base 'Lasso/Captures'))
        [IO.File]::WriteAllText((Join-Path $base 'CutterMk/Captures/CutterMk-1.png'), 'c')
        [IO.File]::WriteAllText((Join-Path $base 'Lasso/Captures/Lasso-1.png'), 'l')
        $app = Join-Path $base 'SnapShackle'
        Invoke-SnapShackleMigration -BaseDir $base -AppDir $app 3>$null 6>$null
        $names = @([IO.Directory]::GetFiles((Join-Path $app 'Captures')) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
        Assert-True (($names -join ',') -eq 'CutterMk-1.png,Lasso-1.png') "captures after upgrade: $($names -join ',')"
        Assert-True ([IO.File]::Exists((Join-Path $base 'CutterMk/Captures/CutterMk-1.png'))) 'CutterMk capture was moved instead of copied'
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'Environment: SNAPSHACKLE_* is read first, CUTTERMK_* is the fallback' {
    $savedNew = [Environment]::GetEnvironmentVariable('SNAPSHACKLE_AUTO_STOP'); $savedOld = [Environment]::GetEnvironmentVariable('CUTTERMK_AUTO_STOP')
    try {
        [Environment]::SetEnvironmentVariable('SNAPSHACKLE_AUTO_STOP', $null); [Environment]::SetEnvironmentVariable('CUTTERMK_AUTO_STOP', '0')
        Assert-True ((Get-SnapShackleEnv 'AUTO_STOP') -eq '0') 'CUTTERMK_AUTO_STOP fallback not read'
        Assert-True (-not (Test-SnapShackleAutoStopEnv (Get-SnapShackleEnv 'AUTO_STOP'))) 'CUTTERMK_AUTO_STOP=0 did not turn auto-stop off'
        [Environment]::SetEnvironmentVariable('SNAPSHACKLE_AUTO_STOP', '1')
        Assert-True ((Get-SnapShackleEnv 'AUTO_STOP') -eq '1') 'SNAPSHACKLE_AUTO_STOP did not take precedence'
        [Environment]::SetEnvironmentVariable('CUTTERMK_AUTO_STOP', $null); [Environment]::SetEnvironmentVariable('SNAPSHACKLE_AUTO_STOP', $null)
        Assert-True ([string]::IsNullOrEmpty((Get-SnapShackleEnv 'AUTO_STOP'))) 'unset variables should read as empty'
    } finally {
        [Environment]::SetEnvironmentVariable('SNAPSHACKLE_AUTO_STOP', $savedNew); [Environment]::SetEnvironmentVariable('CUTTERMK_AUTO_STOP', $savedOld)
    }
}

Test-Case 'Migration is a no-op without a legacy folder' {
    $r = Move-SnapShackleLegacyLibrary -Legacy (Join-Path ([IO.Path]::GetTempPath()) 'does-not-exist-snapshackle') -Target (Join-Path ([IO.Path]::GetTempPath()) 'unused-snapshackle')
    Assert-True ($r.Moved -eq 0 -and -not $r.WholeFolder) 'expected nothing to happen'
}

Test-Case 'Metadata edits keep the indexed OCR text' {
    $base = New-TempDir
    try {
        $name = Save-SnapShackleCapture $base ([byte[]](1,2,3))
        Set-SnapShackleMeta $base $name @{ ocr = 'Quarterly readiness report' }
        Set-SnapShackleMeta $base $name @{ tags = @('ops','q3'); note = 'for review' }
        $meta = Get-SnapShackleMeta $base $name
        Assert-True ($meta.ocr -eq 'Quarterly readiness report') "ocr text lost: '$($meta.ocr)'"
        Assert-True (($meta.tags -join ',') -eq 'ops,q3' -and $meta.note -eq 'for review') 'tags or note not saved'
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'Library search matches text inside images, names and tags' {
    $base = New-TempDir
    try {
        $a = Save-SnapShackleCapture $base ([byte[]](1)); Set-SnapShackleMeta $base $a @{ ocr = 'Deployment schedule for USS Example' }
        $b = Save-SnapShackleCapture $base ([byte[]](2)); Set-SnapShackleMeta $base $b @{ tags = @('schedule') }
        [IO.File]::WriteAllBytes((Join-Path $base 'SnipHero-old.png'), [byte[]](3))
        [IO.File]::WriteAllBytes((Join-Path $base 'unrelated.png'), [byte[]](4))
        $all = Get-SnapShackleCaptureList $base ''
        Assert-True ($all.Count -eq 3) "expected 3 captures (old SnipHero name included, stray file excluded), got $($all.Count)"
        $hits = Get-SnapShackleCaptureList $base 'SCHEDULE'
        Assert-True ($hits.Count -eq 2) "expected 2 hits, got $($hits.Count)"
        $byText = @($hits | Where-Object { $_.name -eq $a })[0]
        Assert-True ($byText.textMatch -and $byText.hasText) 'OCR match not flagged'
        Assert-True (-not @($hits | Where-Object { $_.name -eq $b })[0].textMatch) 'tag match wrongly flagged as text match'
        Assert-True ((Get-SnapShackleCaptureList $base 'uss example').Count -eq 1) 'phrase search failed'
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'Library API sends a flat items array (0, 1 and many captures)' {
    # Mirrors GET /api/library in Start-SnapShackle.ps1. Wrapping the list in @(...) nested it as
    # items:[[...]], which the studio drew as one broken "Invalid Date" card.
    $base = New-TempDir
    try {
        $json = { [object[]]$items = Get-SnapShackleCaptureList $base ''; ConvertTo-Json -InputObject @{items=$items} -Compress -Depth 5 }
        Assert-True ((& $json) -eq '{"items":[]}') "empty library: $(& $json)"
        $a = Save-SnapShackleCapture $base ([byte[]](1))
        Assert-True ((& $json).StartsWith('{"items":[{"name":"' + $a + '"')) "one capture: $(& $json)"
        $null = Save-SnapShackleCapture $base ([byte[]](2))
        Assert-True (((& $json) | ConvertFrom-Json).items.Count -eq 2) "two captures: $(& $json)"
        $hostSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\Start-SnapShackle.ps1'))
        Assert-True ($hostSource -match '\[object\[\]\]\$items = Get-SnapShackleCaptureList' -and $hostSource -notmatch 'items=@\(Get-SnapShackleCaptureList') 'GET /api/library must not wrap the list in @()'
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'OCR indexing is a no-op where native OCR is unavailable' {
    $base = New-TempDir
    try {
        $name = Save-SnapShackleCapture $base ([byte[]](1))
        $indexed = Update-SnapShackleOcrIndex $base $name ([byte[]](1))
        if (-not (Get-Command Test-SnapShackleOcr -ErrorAction SilentlyContinue)) { Assert-True (-not $indexed) 'claimed to index without OCR' }
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'Settings persist in a file and are sanitised' {
    $base = New-TempDir
    try {
        $path = Join-Path $base 'settings.json'
        $fresh = Get-SnapShackleSettings $path
        Assert-True (-not $fresh.saved -and $fresh.namePrefix -eq 'SnapShackle' -and $fresh.recordFps -eq 6 -and $fresh.stayInTray -eq $false -and $fresh.recordAudio -eq 'off' -and $fresh.recordMicId -eq '') 'bad defaults'
        $null = Set-SnapShackleSettings $path ([pscustomobject]@{ namePrefix = 'My Shots!/..'; recordFps = 99; autoLibrary = $true; evil = 'x' })
        $saved = Get-SnapShackleSettings $path
        Assert-True ($saved.saved -and $saved.namePrefix -eq 'MyShots' -and $saved.recordFps -eq 12 -and $saved.autoLibrary -and $saved.recordAudio -eq 'off' -and $saved.recordMicId -eq '') "not sanitised: $($saved | ConvertTo-Json -Compress)"
        Assert-True (-not $saved.Contains('evil')) 'unknown key stored'
        $null = Set-SnapShackleSettings $path @{ theme = 'neon' }
        Assert-True ((Get-SnapShackleSettings $path).theme -eq 'dark') 'invalid theme accepted'
        $null = Set-SnapShackleSettings $path @{ theme = 'System' }
        Assert-True ((Get-SnapShackleSettings $path).theme -eq 'system') 'theme not saved'
        $null = Set-SnapShackleSettings $path @{ recordFps = 4 }
        $again = Get-SnapShackleSettings $path
        Assert-True ($again.recordFps -eq 4 -and $again.namePrefix -eq 'MyShots') 'partial update lost other settings'
        $null = Set-SnapShackleSettings $path @{ stayInTray = $true }
        Assert-True ((Get-SnapShackleSettings $path).stayInTray -eq $true) 'stay-in-tray preference not saved'
        $null = Set-SnapShackleSettings $path ([pscustomobject]@{ stayInTray = 'yes' })
        Assert-True ((Get-SnapShackleSettings $path).stayInTray -eq $false) 'non-boolean stay-in-tray accepted as true'
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'Record sound is off by default and invalid audio settings are ignored' {
    $base = New-TempDir
    try {
        $path = Join-Path $base 'settings.json'
        [IO.File]::WriteAllText($path, '{"namePrefix":"SnapShackle","recordFps":6}')
        $old = Get-SnapShackleSettings $path
        Assert-True ($old.recordAudio -eq 'off' -and $old.recordMicId -eq '') 'settings written before sound existed did not default to off'
        $null = Set-SnapShackleSettings $path @{ recordAudio = 'BOTH'; recordMicId = 'mic_1' }
        $on = Get-SnapShackleSettings $path
        Assert-True ($on.recordAudio -eq 'both' -and $on.recordMicId -eq 'mic_1' -and $on.recordFps -eq 6) 'sound choice was not saved'
        $null = Set-SnapShackleSettings $path @{ recordFps = 4 }
        $kept = Get-SnapShackleSettings $path
        Assert-True ($kept.recordAudio -eq 'both' -and $kept.recordMicId -eq 'mic_1' -and $kept.recordFps -eq 4) 'partial update dropped the sound choice'
        $null = Set-SnapShackleSettings $path @{ recordAudio = 'surround'; recordMicId = 'bad id <mic>' }
        $san = Get-SnapShackleSettings $path
        Assert-True ($san.recordAudio -eq 'both') 'invalid sound mode replaced a saved choice'
        Assert-True ($san.recordMicId -eq 'badidmic') "mic id not sanitised: $($san.recordMicId)"
        $null = Set-SnapShackleSettings $path @{ recordAudio = 'off'; recordMicId = '' }
        $back = Get-SnapShackleSettings $path
        Assert-True ($back.recordAudio -eq 'off' -and $back.recordMicId -eq '') 'sound could not be turned back off'
        Assert-True ($back.recordCamera -eq 'off' -and $back.recordCameraCorner -eq 'br' -and $back.recordCameraSize -eq 'medium' -and $back.recordCameraId -eq '') 'camera must default to off'
        $null = Set-SnapShackleSettings $path @{ recordCamera = 'ON'; recordCameraCorner = 'TL'; recordCameraSize = 'Large'; recordCameraId = 'cam_1' }
        $cam = Get-SnapShackleSettings $path
        Assert-True ($cam.recordCamera -eq 'on' -and $cam.recordCameraCorner -eq 'tl' -and $cam.recordCameraSize -eq 'large' -and $cam.recordCameraId -eq 'cam_1') "camera choice not saved: $($cam | ConvertTo-Json -Compress)"
        $null = Set-SnapShackleSettings $path @{ recordCamera = 'always'; recordCameraCorner = 'middle'; recordCameraSize = 'huge'; recordCameraId = 'bad id <cam>' }
        $cam = Get-SnapShackleSettings $path
        Assert-True ($cam.recordCamera -eq 'on' -and $cam.recordCameraCorner -eq 'tl' -and $cam.recordCameraSize -eq 'large') 'invalid camera values replaced a saved choice'
        Assert-True ($cam.recordCameraId -eq 'badidcam') "camera id not sanitised: $($cam.recordCameraId)"
        $null = Set-SnapShackleSettings $path @{ recordFps = 5 }
        Assert-True ((Get-SnapShackleSettings $path).recordCamera -eq 'on') 'partial update dropped the camera choice'
        $null = Set-SnapShackleSettings $path @{ recordCamera = 'off'; recordCameraId = '' }
        Assert-True ($back.recordFormat -eq 'webm') 'video format should default to webm'
        $null = Set-SnapShackleSettings $path @{ recordFormat = 'MP4' }
        Assert-True ((Get-SnapShackleSettings $path).recordFormat -eq 'mp4') 'mp4 choice was not saved'
        $null = Set-SnapShackleSettings $path @{ recordFormat = 'avi' }
        Assert-True ((Get-SnapShackleSettings $path).recordFormat -eq 'mp4') 'invalid format replaced a saved choice'
        $null = Set-SnapShackleSettings $path @{ recordFps = 4 }
        Assert-True ((Get-SnapShackleSettings $path).recordFormat -eq 'mp4') 'partial update dropped the format'
    } finally { [IO.Directory]::Delete($base, $true) }
}

# ---- lifecycle: the studio tab owns the server (simulated clock) ----
$t0 = [datetime]::new(2026, 10, 24, 12, 0, 0, [DateTimeKind]::Utc)
function At([double]$Seconds) { $t0.AddSeconds($Seconds) }

Test-Case 'Lifecycle: keeps running while heartbeats arrive, stops 20 s after the last one' {
    $p = New-SnapShacklePresence
    foreach ($s in 0, 5, 10, 15) { Register-SnapShacklePresence $p 'tab-a' $false (At $s) }
    Assert-True ($null -eq (Get-SnapShackleStopReason $p (At 34.5) $false $true)) 'stopped before 20 s without a heartbeat'
    Assert-True ($null -ne (Get-SnapShackleStopReason $p (At 35) $false $true)) 'did not stop 20 s after the last heartbeat'
}

Test-Case 'Lifecycle: a leaving signal stops it 5 s later' {
    $p = New-SnapShacklePresence
    Register-SnapShacklePresence $p 'tab-a' $false (At 0)
    Register-SnapShacklePresence $p 'tab-a' $true (At 2)
    Assert-True ($null -eq (Get-SnapShackleStopReason $p (At 6.5) $false $true)) 'stopped inside the 5 s grace'
    Assert-True ($null -ne (Get-SnapShackleStopReason $p (At 7) $false $true)) 'did not stop 5 s after leaving'
}

Test-Case 'Lifecycle: a reload (leaving, then a heartbeat from the new page) does not stop it' {
    $p = New-SnapShacklePresence
    Register-SnapShacklePresence $p 'page-1' $false (At 0)
    Register-SnapShacklePresence $p 'page-1' $true (At 3)
    Register-SnapShacklePresence $p 'page-2' $false (At 3.6)
    foreach ($s in 4, 8, 10, 20) { Assert-True ($null -eq (Get-SnapShackleStopReason $p (At $s) $false $true)) "stopped at $s s after a reload" }
    # A visible heartbeat from the same page also cancels its leaving signal (bfcache restore).
    $q = New-SnapShacklePresence
    Register-SnapShacklePresence $q 'page-1' $true (At 0)
    Register-SnapShacklePresence $q 'page-1' $false (At 1)
    Assert-True ($null -eq (Get-SnapShackleStopReason $q (At 10) $false $true)) 'a visible heartbeat did not cancel leaving'
}

Test-Case 'Lifecycle: a hidden heartbeat sent while the tab closes does not cancel its leaving signal' {
    $p = New-SnapShacklePresence
    Register-SnapShacklePresence $p 'tab-a' $false (At 0)
    Register-SnapShacklePresence $p 'tab-a' $true (At 1)
    Register-SnapShacklePresence $p 'tab-a' $false (At 1.1) $true
    Assert-True ($null -ne (Get-SnapShackleStopReason $p (At 6.2) $false $true)) 'hidden heartbeat kept a closed tab alive'
}

Test-Case 'Lifecycle: with two tabs open, closing one keeps it running' {
    $p = New-SnapShacklePresence
    Register-SnapShacklePresence $p 'tab-a' $false (At 0)
    Register-SnapShacklePresence $p 'tab-b' $false (At 1)
    Register-SnapShacklePresence $p 'tab-a' $true (At 2)
    Register-SnapShacklePresence $p 'tab-b' $false (At 6)
    Assert-True ($null -eq (Get-SnapShackleStopReason $p (At 10) $false $true)) 'stopped while tab-b is open'
    Register-SnapShacklePresence $p 'tab-b' $true (At 11)
    Assert-True ($null -ne (Get-SnapShackleStopReason $p (At 16) $false $true)) 'did not stop after the last tab left'
}

Test-Case 'Lifecycle: never stops while a capture is being saved, then stops on the next tick' {
    $p = New-SnapShacklePresence
    Register-SnapShacklePresence $p 'tab-a' $false (At 0)
    Register-SnapShacklePresence $p 'tab-a' $true (At 1)
    Assert-True ($null -eq (Get-SnapShackleStopReason $p (At 30) $true $true)) 'stopped while busy'
    Assert-True ($null -ne (Get-SnapShackleStopReason $p (At 30.5) $false $true)) 'did not stop once the capture finished'
}

Test-Case 'Lifecycle: -Stay / SNAPSHACKLE_AUTO_STOP=0 never stop it' {
    $p = New-SnapShacklePresence (At 10)
    Register-SnapShacklePresence $p 'tab-a' $true (At 0)
    Assert-True ($null -eq (Get-SnapShackleStopReason $p (At 3600) $false $false)) 'stopped with auto-stop off'
    foreach ($v in '0', 'false', 'OFF', ' no ') { Assert-True (-not (Test-SnapShackleAutoStopEnv $v)) "SNAPSHACKLE_AUTO_STOP=$v should disable auto-stop" }
    foreach ($v in $null, '', '1', 'true') { Assert-True (Test-SnapShackleAutoStopEnv $v) "SNAPSHACKLE_AUTO_STOP=$v should keep auto-stop on" }
}

Test-Case 'Lifecycle: a hidden (throttled) tab gets 75 s, a never-connected browser 2 minutes' {
    $p = New-SnapShacklePresence
    Register-SnapShacklePresence $p 'tab-a' $false (At 0) $true
    Assert-True ($null -eq (Get-SnapShackleStopReason $p (At 60) $false $true)) 'hidden tab stopped after 60 s'
    Assert-True ($null -ne (Get-SnapShackleStopReason $p (At 75) $false $true)) 'hidden tab kept it running past 75 s'
    $never = New-SnapShacklePresence (At 120)
    Assert-True ($null -eq (Get-SnapShackleStopReason $never (At 119) $false $true)) 'stopped before the browser could connect'
    Assert-True ($null -ne (Get-SnapShackleStopReason $never (At 120) $false $true)) 'kept running with no browser ever connecting'
    $headless = New-SnapShacklePresence
    Assert-True ($null -eq (Get-SnapShackleStopReason $headless (At 9999) $false $true)) '-NoBrowser with no tab yet should keep running'
}

Test-Case 'Lifecycle: after the PC sleeps, open tabs get a fresh grace period' {
    $p = New-SnapShacklePresence
    Register-SnapShacklePresence $p 'tab-a' $false (At 0)
    Assert-True (-not (Step-SnapShacklePresenceClock $p (At 0.5))) 'first tick reported a gap'
    Assert-True (-not (Step-SnapShacklePresenceClock $p (At 1))) 'normal tick reported a gap'
    Assert-True (Step-SnapShacklePresenceClock $p (At 3600)) 'an hour-long gap was not detected'
    Assert-True ($null -eq (Get-SnapShackleStopReason $p (At 3610) $false $true)) 'stopped right after waking'
    Assert-True ($null -ne (Get-SnapShackleStopReason $p (At 3620) $false $true)) 'did not stop 20 s after waking with no tab'
}

Test-Case 'Lifecycle: heartbeat bodies, token comparison and launcher options' {
    $b = ConvertFrom-SnapShackleHeartbeat '{"tab":"abc-1","leaving":true,"session":"s3cret"}'
    Assert-True ($b.Tab -eq 'abc-1' -and $b.Leaving -and $b.Session -eq 's3cret' -and -not $b.Hidden) 'beacon body not parsed'
    Assert-True ($null -eq (ConvertFrom-SnapShackleHeartbeat '[1,2]')) 'array body accepted'
    Assert-True ($null -eq (ConvertFrom-SnapShackleHeartbeat 'not json')) 'invalid body accepted'
    Assert-True ($null -eq (ConvertFrom-SnapShackleHeartbeat '"text"') -and $null -eq (ConvertFrom-SnapShackleHeartbeat '42')) 'scalar body accepted'
    $plain = ConvertFrom-SnapShackleHeartbeat '{"tab":"abc-1","hidden":true}'
    Assert-True ($plain.Tab -eq 'abc-1' -and -not $plain.Leaving -and $plain.Hidden -and $plain.Session -eq '') 'heartbeat body not parsed'
    Assert-True (-not (ConvertFrom-SnapShackleHeartbeat '').Leaving) 'empty body should be a plain heartbeat'
    Assert-True (Test-SnapShackleSecretEquals 'abc' 'abc') 'equal tokens differ'
    Assert-True (-not (Test-SnapShackleSecretEquals 'abc' 'abd') -and -not (Test-SnapShackleSecretEquals '' '') -and -not (Test-SnapShackleSecretEquals 'ab' 'abc')) 'unequal tokens match'
    $o = Read-SnapShackleLaunchOptions @('--stay', '--replace', '--no-browser', '-NoTray', '--bogus')
    Assert-True ($o.Stay -and $o.Replace -and $o.NoBrowser -and $o.NoTray) 'launcher options not read'
    Assert-True (($o.Unknown -join ',') -eq '--bogus') 'unknown option not reported'
    $p = New-SnapShacklePresence
    Register-SnapShacklePresence $p ('x' * 80) $false (At 0)
    Assert-True ($p.Tabs.ContainsKey('default')) 'oversized tab id was stored'
    for ($i = 0; $i -lt 40; $i++) { Register-SnapShacklePresence $p ('t' + $i) $false (At $i) }
    Assert-True ($p.Tabs.Count -le 32) "tab table grew to $($p.Tabs.Count)"
}

Test-Case 'Lifecycle: runtime file has pid/port/url/startedAt but no token; stale files are removed' {
    $dir = New-TempDir
    try {
        $path = Write-SnapShackleRuntimeFile $dir $PID 8765 'http://127.0.0.1:8765/' $false
        $info = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        Assert-True ($info.pid -eq $PID -and $info.port -eq 8765 -and $info.url -eq 'http://127.0.0.1:8765/' -and $info.startedAt) 'runtime file fields missing'
        Assert-True (@($info.PSObject.Properties.Name | Where-Object { $_ -match 'token|session' }).Count -eq 0) 'runtime file must never hold the session token'
        Assert-True ((Split-Path -Leaf $path) -eq ('snapshackle-server-' + $PID + '.json')) 'runtime file name'
        # A dead pid (no such process) and an unreadable file are deleted on sight; this process is never listed.
        $stale = Join-Path $dir 'snapshackle-server-2147480000.json'
        [IO.File]::WriteAllText($stale, '{"pid":2147480000,"port":1,"url":"x","startedAt":"2020-01-01T00:00:00Z"}')
        $junk = Join-Path $dir 'snapshackle-server-1.json'
        [IO.File]::WriteAllText($junk, 'garbage')
        $found = @(Get-SnapShackleProcesses $dir -RuntimeFilesOnly)
        Assert-True (-not [IO.File]::Exists($stale) -and -not [IO.File]::Exists($junk)) 'stale runtime files were kept'
        Assert-True ([IO.File]::Exists($path)) 'the live runtime file was deleted'
        Assert-True (@($found | Where-Object { $_.Pid -eq $PID }).Count -eq 0) 'listed this process as another SnapShackle'
        Remove-SnapShackleRuntimeFile $path
        Assert-True (-not [IO.File]::Exists($path)) 'runtime file not removed on stop'
    } finally { [IO.Directory]::Delete($dir, $true) }
}

Test-Case 'Lifecycle: runtime files written by a CutterMk build (other folder, old name) are read too' {
    $dir = New-TempDir; $legacy = New-TempDir
    try {
        $live = Join-Path $legacy ('cuttermk-server-' + $PID + '.json')
        [IO.File]::WriteAllText($live, ('{"pid":' + $PID + ',"port":8765,"url":"http://127.0.0.1:8765/","startedAt":"' + (Get-Date).ToString('o') + '"}'))
        $stale = Join-Path $legacy 'cuttermk-server-2147480000.json'
        [IO.File]::WriteAllText($stale, '{"pid":2147480000,"port":1,"url":"x","startedAt":"2020-01-01T00:00:00Z"}')
        $found = @(Get-SnapShackleProcesses @($dir, $legacy, $null) -RuntimeFilesOnly)
        Assert-True (-not [IO.File]::Exists($stale)) 'stale CutterMk runtime file was not examined'
        Assert-True ([IO.File]::Exists($live)) 'a live CutterMk runtime file was deleted'
        Assert-True (@($found | Where-Object { $_.Pid -eq $PID }).Count -eq 0) 'listed this process as another instance'
        Assert-True ((Get-SnapShackleLegacyStopEventNames 42) -contains 'Local\CutterMk-Stop-42') 'CutterMk stop event name missing'
    } finally { [IO.Directory]::Delete($dir, $true); [IO.Directory]::Delete($legacy, $true) }
}

$onWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
if ($onWindows) {
    Test-Case 'Lifecycle: Stop-SnapShackleProcesses asks a running instance to stop (no PID needed) and it exits itself' {
        $dir = New-TempDir
        $child = $null
        try {
            # Stands in for a SnapShackle host: owns the named stop event and exits with 7 when it is signalled.
            $childScript = '$e=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,''Local\SnapShackle-Stop-''+$PID); [void]$e.WaitOne(60000); exit 7'
            $exe = (Get-Process -Id $PID).Path
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
            $child = Start-Process -FilePath $exe -ArgumentList ('-NoProfile -NoLogo -EncodedCommand ' + $encoded) -PassThru -WindowStyle Hidden
            $null = $child.Handle  # cache the handle so ExitCode is readable after exit
            $null = Write-SnapShackleRuntimeFile $dir $child.Id 1 'http://127.0.0.1:1/' $false
            $ready = $false; $probe = $null
            for ($i = 0; $i -lt 100 -and -not $ready; $i++) {
                if ([Threading.EventWaitHandle]::TryOpenExisting((Get-SnapShackleStopEventName $child.Id), [ref]$probe)) { $probe.Dispose(); $ready = $true } else { Start-Sleep -Milliseconds 100 }
            }
            Assert-True $ready 'stand-in host never created its stop event'
            $stopped = @(Stop-SnapShackleProcesses $dir 10 -RuntimeFilesOnly)
            Assert-True ($stopped -contains $child.Id) 'instance not reported as stopped'
            $child.WaitForExit(5000) | Out-Null
            Assert-True ($child.ExitCode -eq 7) "instance was force-killed instead of stopping itself (exit $($child.ExitCode))"
            Assert-True (@([IO.Directory]::GetFiles($dir, 'snapshackle-server-*.json')).Count -eq 0) 'runtime file left behind'
        } finally {
            if ($child -and -not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
            [IO.Directory]::Delete($dir, $true)
        }
    }

    Test-Case 'Lifecycle: an instance started by a CutterMk build (old runtime folder and stop event) is asked to stop' {
        $dir = New-TempDir; $legacy = New-TempDir
        $child = $null
        try {
            $childScript = '$e=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::ManualReset,''Local\CutterMk-Stop-''+$PID); [void]$e.WaitOne(60000); exit 7'
            $exe = (Get-Process -Id $PID).Path
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
            $child = Start-Process -FilePath $exe -ArgumentList ('-NoProfile -NoLogo -EncodedCommand ' + $encoded) -PassThru -WindowStyle Hidden
            $null = $child.Handle
            $runtime = Join-Path $legacy ('cuttermk-server-' + $child.Id + '.json')
            [IO.File]::WriteAllText($runtime, ('{"pid":' + $child.Id + ',"port":1,"url":"http://127.0.0.1:1/","startedAt":"' + (Get-Date).ToUniversalTime().ToString('o') + '"}'))
            $ready = $false; $probe = $null
            for ($i = 0; $i -lt 100 -and -not $ready; $i++) {
                if ([Threading.EventWaitHandle]::TryOpenExisting(('Local\CutterMk-Stop-' + $child.Id), [ref]$probe)) { $probe.Dispose(); $ready = $true } else { Start-Sleep -Milliseconds 100 }
            }
            Assert-True $ready 'stand-in CutterMk host never created its stop event'
            $stopped = @(Stop-SnapShackleProcesses @($dir, $legacy) 10 -RuntimeFilesOnly)
            Assert-True ($stopped -contains $child.Id) 'CutterMk instance not reported as stopped'
            $child.WaitForExit(5000) | Out-Null
            Assert-True ($child.ExitCode -eq 7) "CutterMk instance was force-killed instead of stopping itself (exit $($child.ExitCode))"
            Assert-True (-not [IO.File]::Exists($runtime)) 'CutterMk runtime file left behind'
        } finally {
            if ($child -and -not $child.HasExited) { Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue }
            [IO.Directory]::Delete($dir, $true); [IO.Directory]::Delete($legacy, $true)
        }
    }
}

Test-Case 'Share: folder paths accept drive and UNC folders and refuse anything else' {
    foreach ($ok in @('C:\Users\me\OneDrive\Shots', 'D:/Team/Shots', '\\server\share\shots', '\\files.corp.local\team\shots', 'E:\')) {
        Assert-True ($null -ne (ConvertTo-SnapShackleSharePath $ok)) "should accept: $ok"
    }
    Assert-True ((ConvertTo-SnapShackleSharePath 'D:/Team/Shots') -eq 'D:\Team\Shots') 'slashes not normalised'
    Assert-True ((ConvertTo-SnapShackleSharePath '"C:\Shots\"') -eq 'C:\Shots') 'quotes and trailing slash not trimmed'
    foreach ($bad in @('', 'shots', '..\shots', 'C:\a\..\b', 'C:\a\.\b', '\\.\pipe\x', '\\?\C:\x', '\\server', 'C:\a|b', 'C:\a?b', 'C:\a*b', 'http://example.com/x', 'ftp://x/y', 'C:', ('C:\' + ('x' * 300)))) {
        Assert-True ($null -eq (ConvertTo-SnapShackleSharePath $bad)) "should refuse: $bad"
    }
}
Test-Case 'Share: folder list keeps at most 8 clean, uniquely named entries' {
    $in = @(
        @{ name = 'Team drive'; path = '\\server\share\shots' }, @{ name = 'team DRIVE'; path = 'C:\Other' },
        @{ name = 'clipboard'; path = 'C:\Nope' }, @{ name = 'Bad path'; path = 'relative\x' }, @{ name = ''; path = 'C:\Blank' },
        @{ name = 'Name <b>!'; path = 'C:\Shots' })
    $out = ConvertTo-SnapShackleShareFolders $in
    Assert-True ($out.Count -eq 2) ('expected 2 entries, got ' + $out.Count)
    Assert-True ($out[0].name -eq 'Team drive' -and $out[1].name -eq 'Name b') "names: $($out | ConvertTo-Json -Compress)"
    $many = 1..20 | ForEach-Object { @{ name = "F$_"; path = "C:\F$_" } }
    Assert-True ((ConvertTo-SnapShackleShareFolders $many).Count -eq 8) 'not capped at 8'
    Assert-True ((ConvertTo-SnapShackleShareFolders $null).Count -eq 0) 'null should give an empty list'
}
Test-Case 'Share: folders are saved with the settings and survive partial updates' {
    $base = Join-Path ([IO.Path]::GetTempPath()) ('ss-share-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($base)
    try {
        $path = Join-Path $base 'settings.json'
        Assert-True (@((Get-SnapShackleSettings $path).shareFolders).Count -eq 0) 'share folders should default to none'
        $null = Set-SnapShackleSettings $path (ConvertFrom-Json '{"shareFolders":[{"name":"Team","path":"C:\\Team\\Shots"},{"name":"Bad","path":"nope"}]}')
        $got = Get-SnapShackleSettings $path
        Assert-True (@($got.shareFolders).Count -eq 1 -and $got.shareFolders[0].name -eq 'Team' -and $got.shareFolders[0].path -eq 'C:\Team\Shots') "not saved: $($got | ConvertTo-Json -Compress -Depth 5)"
        $null = Set-SnapShackleSettings $path @{ recordFps = 5 }
        Assert-True (@((Get-SnapShackleSettings $path).shareFolders).Count -eq 1) 'a partial update dropped the share folders'
        $null = Set-SnapShackleSettings $path @{ shareFolders = @() }
        Assert-True (@((Get-SnapShackleSettings $path).shareFolders).Count -eq 0) 'share folders could not be cleared'
    } finally { [IO.Directory]::Delete($base, $true) }
}
Test-Case 'Share: copying to a folder never overwrites and clipboard/open use the injected actions' {
    $base = Join-Path ([IO.Path]::GetTempPath()) ('ss-share-' + [guid]::NewGuid().ToString('N'))
    $lib = Join-Path $base 'lib'; $dest = Join-Path $base 'dest'
    [void][IO.Directory]::CreateDirectory($lib); [void][IO.Directory]::CreateDirectory($dest)
    try {
        $png = Join-Path $lib 'SnapShackle-test.png'
        [IO.File]::WriteAllBytes($png, [byte[]](137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3))
        $settings = @{ shareFolders = @(@{ name = 'Team'; path = $dest }, @{ name = 'Gone'; path = (Join-Path $base 'missing') }) }
        $r1 = Invoke-SnapShackleShare -Library $lib -CapturePath $png -Settings $settings -Kind folder -Destination 'team'
        Assert-True ($r1.name -eq 'SnapShackle-test.png' -and [IO.File]::Exists($r1.path)) 'first copy missing'
        $r2 = Invoke-SnapShackleShare -Library $lib -CapturePath $png -Settings $settings -Kind folder -Destination 'Team'
        Assert-True ($r2.name -eq 'SnapShackle-test (2).png') "second copy should get a new name, got $($r2.name)"
        [IO.File]::WriteAllBytes($r1.path, [byte[]](9, 9, 9))
        $r3 = Invoke-SnapShackleShare -Library $lib -CapturePath $png -Settings $settings -Kind folder -Destination 'Team'
        Assert-True ($r3.name -eq 'SnapShackle-test (3).png' -and [IO.File]::ReadAllBytes($r1.path).Length -eq 3) 'an existing file was overwritten'
        Assert-True ((Compare-Object ([IO.File]::ReadAllBytes($png)) ([IO.File]::ReadAllBytes($r2.path))) -eq $null) 'copy differs from the capture'
        foreach ($case in @(@('folder', 'Nope', 'Unknown share folder'), @('folder', 'Gone', 'not found or is offline'), @('upload', '', 'Unknown share kind'))) {
            $msg = ''
            try { $null = Invoke-SnapShackleShare -Library $lib -CapturePath $png -Settings $settings -Kind $case[0] -Destination $case[1] } catch { $msg = $_.Exception.Message }
            Assert-True ($msg -like ('*' + $case[2] + '*')) ("expected '" + $case[2] + "' for " + $case[0] + '/' + $case[1] + ', got: ' + $msg)
        }
        $msg = ''
        try { $null = Invoke-SnapShackleShare -Library $lib -CapturePath (Join-Path $lib 'SnapShackle-none.png') -Settings $settings -Kind open } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -like '*Capture not found*') 'a missing capture should be reported'
        $script:seen = @()
        $clip = { param($p) $script:seen += ('clip:' + [IO.Path]::GetFileName($p)) }
        $open = { param($p, $inExplorer) $script:seen += ('open:' + $inExplorer + ':' + [IO.Path]::GetFileName($p)) }
        $c = Invoke-SnapShackleShare -Library $lib -CapturePath $png -Settings $settings -Kind clipboard -ClipboardAction $clip -OpenAction $open
        $v = Invoke-SnapShackleShare -Library $lib -CapturePath $png -Settings $settings -Kind reveal -ClipboardAction $clip -OpenAction $open
        $o = Invoke-SnapShackleShare -Library $lib -CapturePath $png -Settings $settings -Kind open -ClipboardAction $clip -OpenAction $open
        Assert-True (($script:seen -join ',') -eq 'clip:SnapShackle-test.png,open:True:SnapShackle-test.png,open:False:SnapShackle-test.png') ('actions: ' + ($script:seen -join ','))
        Assert-True ($c.kind -eq 'clipboard' -and $v.kind -eq 'reveal' -and $o.kind -eq 'open') 'kinds not reported'
        $list = Get-SnapShackleShareDestinations $settings
        Assert-True ($list.Count -eq 5 -and $list[0].available -and -not $list[1].available -and $list[2].kind -eq 'clipboard') ('destination list: ' + ($list | ConvertTo-Json -Compress -Depth 4))
    } finally { [IO.Directory]::Delete($base, $true) }
}

Test-Case 'Tray icon comes from the FleetHacker tray kit, drawn at the tray size' {
    $tray = [IO.File]::ReadAllText((Join-Path $root 'modules/Tray.ps1'))
    Assert-True ($tray -notmatch 'GetHicon' -and $tray -notmatch 'SnapShackle\.TrayArt|class TrayArt') 'Tray.ps1 still draws its own icon'
    Assert-True (([regex]::Matches($tray, 'Get-SnapShackleTrayIcon \$Root')).Count -eq 2) 'tray start and Explorer restart must both use Get-SnapShackleTrayIcon'
    $version = [IO.File]::ReadAllText((Join-Path $root 'vendor/fleet-tray/VERSION')).Trim()
    Assert-True ($version -eq 'edge-ops ui-kit/tray v1.0.0, commit c2172f7') "unexpected kit version: $version"
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return }
    # The tray thread is its own runspace: load Tray.ps1 there, as the tray script does.
    $ps = [PowerShell]::Create()
    try {
        [void]$ps.AddScript({
            param($Root)
            . (Join-Path $Root 'modules/Tray.ps1')
            $icon = Get-SnapShackleTrayIcon $Root
            @{ Width = $icon.Width; Height = $icon.Height; Want = Get-FleetTraySize; Kit = [bool]('FleetTray.Art' -as [type]) }
        }).AddArgument($root)
        $out = @($ps.Invoke())
        Assert-True ($ps.Streams.Error.Count -eq 0) ('tray runspace errors: ' + ($ps.Streams.Error -join '; '))
        $r = $out[0]
        Assert-True $r.Kit 'FleetTray.Art was not compiled'
        Assert-True ($r.Width -eq $r.Want -and $r.Height -eq $r.Want) "icon is $($r.Width)x$($r.Height), tray wants $($r.Want)"
    } finally { $ps.Dispose() }
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
