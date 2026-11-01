<#
  Tests the optional AI help (alt text and annotation suggestions) against a fake router, never a real one.
  Part 1 runs modules/Router.ps1 in this process: the router address rules, how the client key is read (Windows Credential Manager,
  through a replaceable reader), the clean-up of the model's suggestions, a refused key and a router that is not running.
  Part 2 starts a real SnapShackle host (no tray, no browser, temporary data folder) pointed at tests/fake_router.ps1
  and checks the routes: off by default, the right headers and image reach the router, and the key is never shown,
  saved or logged. Images are synthetic; nothing leaves this computer.
  Usage: powershell -NoProfile -STA -File tests/ai_router_test.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$script:onActions = $env:GITHUB_ACTIONS -eq 'true'
function Write-Failure([string]$Text) {
    Write-Host $Text -ForegroundColor Red
    if ($script:onActions) { Write-Host ('::error title=ai_router_test::' + ($Text -replace "`r?`n", ' ')) }
}
trap { Write-Failure ('Unhandled error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage); exit 1 }
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$work = Join-Path ([IO.Path]::GetTempPath()) ('ss-airouter-' + [guid]::NewGuid().ToString('N'))
$appData = Join-Path $work 'appdata'; [void][IO.Directory]::CreateDirectory($appData)
$script:failures = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS  $Name" } catch { $script:failures++; Write-Failure "FAIL  $Name :: $($_.Exception.Message)" }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Get-FreePort { $p = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $p.Start(); $n = $p.LocalEndpoint.Port; $p.Stop(); return $n }
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

. (Join-Path $root 'modules\Ocr.ps1')
. (Join-Path $root 'modules\Router.ps1')

$bmp = [Drawing.Bitmap]::new(320, 200); $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::White)
$g.DrawString('Quarterly report', [Drawing.Font]::new('Arial', 20, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel), [Drawing.Brushes]::Black, 10, 10); $g.Dispose()
$ms = [IO.MemoryStream]::new(); $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $png = $ms.ToArray(); $ms.Dispose()
$on = [pscustomobject]@{ aiSuggest = 'on'; aiPrivacy = 'local' }

function Start-FakeRouter([int]$Port, [string]$Log, [string]$Mode = 'ok') {
    $psi = [Diagnostics.ProcessStartInfo]::new($psExe)
    $psi.Arguments = '-NoProfile -NoLogo -ExecutionPolicy Bypass -File "' + (Join-Path $root 'tests\fake_router.ps1') + '" -Port ' + $Port + ' -Log "' + $Log + '" -Mode ' + $Mode
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($psi)
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Milliseconds 150
        try { $c = [Net.Sockets.TcpClient]::new('127.0.0.1', $Port); $c.Close(); return $proc } catch {}
        if ($proc.HasExited) { throw ('the fake router stopped: ' + $proc.StandardError.ReadToEnd()) }
    }
    throw 'the fake router did not start'
}
$saved = @{}
foreach ($n in 'SNAPSHACKLE_FAIRLEAD_URL', 'SNAPSHACKLE_FAIRLEAD_TARGET', 'LLM_URL') { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
function Reset-Env { foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
$procs = @()
try {
    Reset-Env
    foreach ($n in 'SNAPSHACKLE_FAIRLEAD_URL', 'SNAPSHACKLE_FAIRLEAD_TARGET', 'LLM_URL') { [Environment]::SetEnvironmentVariable($n, $null) }
    Set-SnapShackleCredentialReader { param([string]$Target) 'fl-synthetic-key' }

    Test-Case 'the router address defaults to Fairlead on 127.0.0.1:8776 and only a loopback address is accepted' {
        Assert-True ((Get-SnapShackleRouterUrl) -eq 'http://127.0.0.1:8776') 'default address'
        [Environment]::SetEnvironmentVariable('SNAPSHACKLE_FAIRLEAD_URL', 'http://localhost:9000/')
        Assert-True ((Get-SnapShackleRouterUrl) -eq 'http://localhost:9000') 'override with trailing slash'
        [Environment]::SetEnvironmentVariable('SNAPSHACKLE_FAIRLEAD_URL', $null)
        [Environment]::SetEnvironmentVariable('LLM_URL', 'http://127.0.0.1:9100')
        Assert-True ((Get-SnapShackleRouterUrl) -eq 'http://127.0.0.1:8776') 'other variables are not read'
        [Environment]::SetEnvironmentVariable('LLM_URL', $null)
        foreach ($bad in 'https://example.com', 'http://10.0.0.5:8776', 'http://127.0.0.1.evil.example:80', 'http://127.0.0.1', 'ftp://127.0.0.1:21', 'http://127.0.0.1:8776/..\x') {
            [Environment]::SetEnvironmentVariable('SNAPSHACKLE_FAIRLEAD_URL', $bad)
            $threw = $false; try { [void](Get-SnapShackleRouterUrl) } catch { $threw = $true }
            Assert-True $threw "accepted $bad"
        }
        [Environment]::SetEnvironmentVariable('SNAPSHACKLE_FAIRLEAD_URL', $null)
    }
    Test-Case 'the client key is read only from Windows Credential Manager (Fairlead/SnapShackle), else none with a plain note' {
        $script:asked = @()
        Set-SnapShackleCredentialReader { param([string]$Target) $script:asked += $Target; 'fl-from-store' }
        $k = Resolve-SnapShackleRouterKey
        Assert-True ($k.source -eq 'credential-manager' -and $k.key -eq 'fl-from-store' -and $script:asked[0] -eq 'Fairlead/SnapShackle') ('read: ' + ($k | ConvertTo-Json -Compress))
        [Environment]::SetEnvironmentVariable('SNAPSHACKLE_FAIRLEAD_TARGET', 'Fairlead/Other')
        $null = Resolve-SnapShackleRouterKey
        Assert-True ($script:asked[-1] -eq 'Fairlead/SnapShackle') 'a target outside Fairlead/SnapShackle-* must be ignored'
        [Environment]::SetEnvironmentVariable('SNAPSHACKLE_FAIRLEAD_TARGET', 'Fairlead/SnapShackle-test1')
        $null = Resolve-SnapShackleRouterKey
        Assert-True ($script:asked[-1] -eq 'Fairlead/SnapShackle-test1') 'a test target should be accepted'
        [Environment]::SetEnvironmentVariable('SNAPSHACKLE_FAIRLEAD_TARGET', $null)
        Set-SnapShackleCredentialReader { param([string]$Target) $null }
        $k = Resolve-SnapShackleRouterKey
        Assert-True ($k.source -eq 'none' -and $k.key -eq '' -and $k.note -eq 'Open Fairlead and install a key for SnapShackle.') ('missing: ' + ($k | ConvertTo-Json -Compress))
        Set-SnapShackleCredentialReader { param([string]$Target) throw 'credential store unavailable' }
        $k = Resolve-SnapShackleRouterKey
        Assert-True ($k.source -eq 'none' -and -not ($k | ConvertTo-Json).Contains('unavailable')) 'a store error should be none with the plain note'
        Set-SnapShackleCredentialReader { param([string]$Target) 'fl-synthetic-key' }
        Assert-True ((ConvertFrom-SnapShackleCredentialBlob ([Text.Encoding]::Unicode.GetBytes('fl-abc123'))) -eq 'fl-abc123') 'a UTF-16 key is decoded'
        Assert-True ((ConvertFrom-SnapShackleCredentialBlob ([Text.Encoding]::UTF8.GetBytes('fl-abc123'))) -eq 'fl-abc123') 'a UTF-8 key is decoded'
        Assert-True ((ConvertFrom-SnapShackleCredentialBlob ([byte[]]@(1, 2, 3, 4, 5))) -eq '' -and (ConvertFrom-SnapShackleCredentialBlob ([byte[]]@())) -eq '' -and (ConvertFrom-SnapShackleCredentialBlob $null) -eq '') 'unprintable, empty or no blob is not a key'
    }
    Test-Case 'a call with no key installed stops before any request and says what to do' {
        Set-SnapShackleCredentialReader { param([string]$Target) $null }
        $msg = ''; try { [void](Invoke-SnapShackleAltText $png $on) } catch { $msg = $_.Exception.Message }
        Set-SnapShackleCredentialReader { param([string]$Target) 'fl-synthetic-key' }
        Assert-True ($msg -eq 'Open Fairlead and install a key for SnapShackle.') ('no key: ' + $msg)
    }
    Test-Case 'suggestions are cleaned: known kinds only, clamped into the image, bad numbers dropped, capped' {
        $text = 'Sure: [{"kind":"redact","x":0.1,"y":0.2,"w":0.3,"h":0.1,"label":"email"},{"kind":"explode","x":0,"y":0,"w":1,"h":1},{"kind":"box","x":0.9,"y":0.9,"w":0.9,"h":0.9,"label":"big"},{"kind":"box","x":"nope","y":0,"w":0.1,"h":0.1},{"kind":"arrow","x":-3,"y":0,"w":0.0001,"h":0.5}] ok'
        $s = @(ConvertFrom-SnapShackleSuggestions $text)
        Assert-True ($s.Count -eq 2) ('expected 2 kept, got ' + $s.Count)
        Assert-True ($s[0].kind -eq 'redact' -and $s[0].x -eq 0.1 -and $s[0].label -eq 'email') 'first item'
        Assert-True ($s[1].kind -eq 'box' -and $s[1].x -eq 0.9 -and [Math]::Abs($s[1].w - 0.1) -lt 0.0001 -and [Math]::Abs($s[1].h - 0.1) -lt 0.0001) 'clamped box'
        Assert-True (@(ConvertFrom-SnapShackleSuggestions 'no list here').Count -eq 0 -and @(ConvertFrom-SnapShackleSuggestions '[not json').Count -eq 0) 'garbage should give none'
        $many = '[' + ((1..20 | ForEach-Object { '{"kind":"box","x":0.1,"y":0.1,"w":0.1,"h":0.1,"label":"n' + $_ + '"}' }) -join ',') + ']'
        Assert-True (@(ConvertFrom-SnapShackleSuggestions $many).Count -eq 12) 'more than 12 kept'
        $long = '[{"kind":"text","x":0.1,"y":0.1,"w":0.1,"h":0.1,"label":"' + ('z' * 200) + '"}]'
        Assert-True (@(ConvertFrom-SnapShackleSuggestions $long)[0].label.Length -eq 80) 'label not cut to 80'
    }
    Test-Case 'a refused key and a router that is not running give plain errors' {
        $port = Get-FreePort; $log = Join-Path $work 'refuse.log'
        $procs += Start-FakeRouter $port $log 'refuse'
        [Environment]::SetEnvironmentVariable('SNAPSHACKLE_FAIRLEAD_URL', "http://127.0.0.1:$port")
        Set-SnapShackleCredentialReader { param([string]$Target) 'fl-wrong' }
        $msg = ''; try { [void](Invoke-SnapShackleAltText $png $on) } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -like '*refused the key*' -and -not $msg.Contains('fl-wrong')) ('refused: ' + $msg)
        $procs[-1].Kill(); [void]$procs[-1].WaitForExit(3000)
        $msg = ''; try { [void](Invoke-SnapShackleAltText $png $on) } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -like '*did not answer*') ('down: ' + $msg)
        $off = [pscustomobject]@{ aiSuggest = 'off' }
        $msg = ''; try { [void](Invoke-SnapShackleAltText $png $off) } catch { $msg = $_.Exception.Message }
        Assert-True ($msg -like '*are off*') ('off: ' + $msg)
        Reset-Env
        Set-SnapShackleCredentialReader { param([string]$Target) 'fl-synthetic-key' }
    }

    # Part 2: a real host pointed at the fake router. The host is a separate process, so the key goes in a throwaway
    # Credential Manager entry (Fairlead/SnapShackle-test-<id>), never the real Fairlead/SnapShackle one, removed at the end.
    $script:testTarget = 'Fairlead/SnapShackle-test-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $null = & cmdkey.exe "/generic:$($script:testTarget)" '/user:fairlead' '/pass:fl-test-key-123' 2>&1
    $rport = Get-FreePort; $rlog = Join-Path $work 'router.log'
    $procs += Start-FakeRouter $rport $rlog 'ok'
    $hport = Get-FreePort
    $psi = [Diagnostics.ProcessStartInfo]::new($psExe)
    $psi.Arguments = '-NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Start-SnapShackle.ps1') + '" -NoBrowser -NoTray -AllowSecondInstance -Port ' + $hport
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $appData; $psi.EnvironmentVariables['SNAPSHACKLE_AUTO_STOP'] = '0'
    $psi.EnvironmentVariables['SNAPSHACKLE_FAIRLEAD_URL'] = "http://127.0.0.1:$rport"; $psi.EnvironmentVariables['SNAPSHACKLE_FAIRLEAD_TARGET'] = $script:testTarget
    $host1 = [Diagnostics.Process]::Start($psi); $procs += $host1
    $base = "http://127.0.0.1:$hport"
    function Invoke-Api([string]$Method, [string]$Path, $Body, [string]$Token, [byte[]]$Bytes, [string]$ContentType = 'application/json') {
        $req = [Net.HttpWebRequest]::Create($base + $Path); $req.Method = $Method; $req.Proxy = $null; $req.Timeout = 60000; $req.KeepAlive = $false; $req.ServicePoint.Expect100Continue = $false
        if ($Token) { $req.Headers.Add('X-SnapShackle-Token', $Token) }
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
    $up = $false
    for ($i = 0; $i -lt 100 -and -not $up -and -not $host1.HasExited; $i++) { Start-Sleep -Milliseconds 200; try { $up = (Invoke-Api 'GET' '/' $null '').Status -eq 200 } catch {} }
    if (-not $up) { throw ('the host did not start: ' + $host1.StandardError.ReadToEnd()) }
    $studio = (Invoke-Api 'GET' '/assets/studio.js' $null '').Text
    $token = [regex]::Match($studio, "const TOKEN='([0-9a-f]{64})'").Groups[1].Value
    Assert-True ($token.Length -eq 64) 'no session token'
    function Get-RouterLog { if ([IO.File]::Exists($rlog)) { return @([IO.File]::ReadAllLines($rlog) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) } else { return @() } }

    Test-Case 'AI help is off by default: status says so, calls are refused, and nothing reaches the router' {
        Assert-True ((Invoke-Api 'GET' '/api/ai/status' $null '').Status -eq 403) 'status without a token'
        $st = Invoke-Api 'GET' '/api/ai/status' $null $token
        Assert-True ($st.Json.enabled -eq $false -and $st.Json.keySource -eq 'credential-manager' -and $st.Json.routerUrl -eq "http://127.0.0.1:$rport" -and $st.Json.privacy -eq 'local') ('status: ' + $st.Text)
        Assert-True (-not $st.Text.Contains('fl-test-key-123')) 'the status shows the key'
        $r = Invoke-Api 'POST' '/api/ai/alt-text' $null $token $png 'image/png'
        Assert-True ($r.Status -eq 409 -and $r.Json.error -like '*off*') ('expected 409: ' + $r.Status + ' ' + $r.Text)
        Assert-True ((Get-RouterLog).Count -eq 0) 'a request reached the router while AI help was off'
    }
    Test-Case 'alt text: the image goes to the router with the key and local-only privacy, and the text comes back' {
        $set = Invoke-Api 'PUT' '/api/settings' @{ aiSuggest = 'on' } $token
        Assert-True ($set.Status -eq 200 -and $set.Json.aiSuggest -eq 'on') ('settings: ' + $set.Text)
        $r = Invoke-Api 'POST' '/api/ai/alt-text' $null $token $png 'image/png'
        Assert-True ($r.Status -eq 200 -and $r.Json.text -like '*Quarterly report*' -and $r.Json.route -eq 'smart' -and $r.Json.target -eq 'fake/vision-1') ('alt text: ' + $r.Text)
        $seen = @(Get-RouterLog)[-1]
        Assert-True ($seen.path -eq '/v1/chat/completions' -and $seen.authorization -eq 'Bearer fl-test-key-123' -and $seen.privacy -eq 'local' -and $seen.label -eq 'SnapShackle' -and $seen.hasImage -eq $true) ('what the router saw: ' + ($seen | ConvertTo-Json -Compress))
        Assert-True (-not $r.Text.Contains('fl-test-key-123')) 'the answer shows the key'
    }
    Test-Case 'suggestions come back cleaned, with positions as fractions of the image' {
        $r = Invoke-Api 'POST' '/api/ai/suggest' $null $token $png 'image/png'
        Assert-True ($r.Status -eq 200) ('suggest: ' + $r.Status + ' ' + $r.Text)
        $s = @($r.Json.suggestions)
        Assert-True ($s.Count -eq 3 -and $s[0].kind -eq 'redact' -and $s[2].kind -eq 'box' -and $s[2].x + $s[2].w -le 1.0001) ('suggestions: ' + $r.Text)
        $seen = @(Get-RouterLog)[-1]
        Assert-True ($seen.system -like '*annotations*') 'the suggest prompt was not used'
    }
    Test-Case 'choosing any-privacy drops the local-only header; the key is never saved or shown' {
        $null = Invoke-Api 'PUT' '/api/settings' @{ aiPrivacy = 'any' } $token
        $null = Invoke-Api 'POST' '/api/ai/alt-text' $null $token $png 'image/png'
        Assert-True (@(Get-RouterLog)[-1].privacy -eq '') 'the privacy header was still sent'
        $null = Invoke-Api 'PUT' '/api/settings' @{ aiPrivacy = 'bogus'; aiSuggest = 'maybe' } $token
        $now = Invoke-Api 'GET' '/api/settings' $null $token
        Assert-True ($now.Json.aiPrivacy -eq 'any' -and $now.Json.aiSuggest -eq 'on') 'invalid values replaced a saved choice'
        Assert-True (-not $now.Text.Contains('fl-test-key-123')) 'settings show the key'
        foreach ($f in Get-ChildItem -LiteralPath $appData -Recurse -File) {
            # The host may hold a log open for writing, so read with sharing allowed.
            $fs = [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try { $content = [Text.Encoding]::UTF8.GetString(([IO.BinaryReader]::new($fs)).ReadBytes([int]$fs.Length)) } finally { $fs.Dispose() }
            Assert-True (-not $content.Contains('fl-test-key-123')) ('the key was written to ' + $f.FullName)
        }
    }
    Test-Case 'bad input is refused and the host keeps answering' {
        $r = Invoke-Api 'POST' '/api/ai/suggest' $null $token ([Text.Encoding]::UTF8.GetBytes('not a png')) 'image/png'
        Assert-True ($r.Status -ge 400) ('a non-PNG was accepted: ' + $r.Status)
        Assert-True ((Invoke-Api 'GET' '/api/health' $null $token).Status -eq 200) 'the host stopped answering'
    }
} finally {
    foreach ($p in $procs) { try { if ($null -ne $p -and -not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(5000) } } catch {} }
    Reset-Env
    if ($script:testTarget) { $null = & cmdkey.exe "/delete:$($script:testTarget)" 2>&1 }
    try { [IO.Directory]::Delete($work, $true) } catch {}
}
if ($script:failures -gt 0) { Write-Failure "$($script:failures) AI router test(s) failed"; exit 1 }
Write-Host 'All AI router tests passed.' -ForegroundColor Green
