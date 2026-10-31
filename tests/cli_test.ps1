<#
  End-to-end test of snapshackle.ps1 against a real, headless host in its own temporary LOCALAPPDATA.
  Synthetic data only: PNGs are drawn in memory and the one window captured is a form this test draws.
  The real desktop is never captured (capture screen and capture rect are not run).
  Usage: powershell -NoProfile -STA -File tests/cli_test.ps1
#>
$ErrorActionPreference = 'Stop'
$script:onActions = $env:GITHUB_ACTIONS -eq 'true'
function Write-Failure([string]$Text) {
    Write-Host $Text -ForegroundColor Red
    if ($script:onActions) { Write-Host ('::error title=cli_test::' + ($Text -replace "`r?`n", ' ')) }
}
trap { Write-Failure ('Unhandled error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage); exit 1 }
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $root 'modules/Cli.ps1')
. (Join-Path $root 'modules/Ocr.ps1')
$work = Join-Path ([IO.Path]::GetTempPath()) ('ss-cli-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$oldLocal = $env:LOCALAPPDATA
$env:LOCALAPPDATA = Join-Path $work 'appdata'
[void][IO.Directory]::CreateDirectory($env:LOCALAPPDATA)
$appDir = Join-Path $env:LOCALAPPDATA 'SnapShackle'
$sessionPath = Get-SnapShackleSessionFilePath $appDir
$script:failures = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS  $Name" } catch { $script:failures++; Write-Failure "FAIL  $Name :: $($_.Exception.Message)" }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Runs the CLI as a child process while this thread keeps pumping messages (a PrintWindow of our own form needs that).
function Invoke-Cli([string[]]$CliArgs) {
    $quoted = ($CliArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
    $psi = [Diagnostics.ProcessStartInfo]::new($psExe)
    $psi.Arguments = '-NoProfile -NoLogo -ExecutionPolicy Bypass -File "' + (Join-Path $root 'snapshackle.ps1') + '" ' + $quoted
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds(90)
    while (-not $p.HasExited -and [DateTime]::UtcNow -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }
    if (-not $p.HasExited) { $p.Kill(); throw ('CLI timed out: ' + $quoted) }
    $p.WaitForExit()
    $text = $out.Result
    $json = $null; try { $json = $text | ConvertFrom-Json } catch {}
    return [pscustomobject]@{ Exit = $p.ExitCode; Text = $text; Err = $err.Result; Json = $json }
}
function New-TextPng([string]$Path, [string[]]$Lines) {
    $bmp = [Drawing.Bitmap]::new(700, 140); $g = [Drawing.Graphics]::FromImage($bmp)
    $font = [Drawing.Font]::new('Arial', 28, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    $g.Clear([Drawing.Color]::White); $y = 14
    foreach ($l in $Lines) { $g.DrawString($l, $font, [Drawing.Brushes]::Black, 16, $y); $y += 52 }
    $g.Dispose(); $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
function Get-Sha([string]$Path) { $s = [Security.Cryptography.SHA256]::Create(); try { return (($s.ComputeHash([IO.File]::ReadAllBytes($Path)) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $s.Dispose() } }
function Invoke-RawApi([string]$Method, [string]$Path, [string]$Token) {
    $s = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
    $req = [Net.HttpWebRequest]::Create('http://127.0.0.1:' + $s.port + $Path); $req.Method = $Method; $req.Proxy = $null; $req.KeepAlive = $false
    if ($Token) { $req.Headers.Add('X-SnapShackle-Token', $Token) }
    if ($Method -ne 'GET') { $req.ContentLength = 0 }
    try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response }
    $code = [int]$resp.StatusCode; $resp.Close(); return $code
}
$form = $null
try {
    Test-Case 'app start brings SnapShackle up headless, with a session file only this user can read' {
        $port = ([Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)); $port.Start(); $free = $port.LocalEndpoint.Port; $port.Stop()
        $r = Invoke-Cli @('app', 'start', '--port', [string]$free, '--json')
        Assert-True ($r.Exit -eq 0 -and $r.Json.ok -eq $true -and $r.Json.result.started -eq $true) ('start failed: ' + $r.Text + $r.Err)
        Assert-True ([IO.File]::Exists($sessionPath)) 'no session file'
        $s = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
        Assert-True ($s.token -match '^[0-9a-f]{64}$' -and $s.port -eq $free) 'session file content'
        $acl = Get-Acl -LiteralPath $sessionPath
        Assert-True $acl.AreAccessRulesProtected 'the token file inherits permissions from its folder'
        $rules = @($acl.Access)
        Assert-True ($rules.Count -eq 1) ('expected one access rule, found ' + $rules.Count)
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        Assert-True ($rules[0].IdentityReference.Value -eq $me -and $rules[0].AccessControlType -eq 'Allow') ('token file is open to ' + $rules[0].IdentityReference.Value)
        Assert-True (-not (((Get-ChildItem -LiteralPath (Join-Path $appDir 'logs') -Filter *.json | ForEach-Object { [IO.File]::ReadAllText($_.FullName) }) -join ' ') -match $s.token)) 'the token leaked into the runtime file'
    }
    Test-Case 'app start again reports it is already running; health works' {
        $r = Invoke-Cli @('app', 'start', '--json')
        Assert-True ($r.Json.result.alreadyRunning -eq $true) $r.Text
        $h = Invoke-Cli @('app', 'health', '--json')
        Assert-True ($h.Exit -eq 0 -and $h.Json.result.capture -eq $true -and $h.Json.result.version -match '^\d+\.\d+') $h.Text
    }
    Test-Case 'the host serves the same command list the CLI uses' {
        $r = Invoke-Cli @('commands', 'list', '--json')
        Assert-True ($r.Exit -eq 0 -and $r.Json.result.schema -eq 'snapshackle.commands/1') $r.Text
        $served = @($r.Json.result.commands | ForEach-Object { $_.name }) -join ','
        $local = @($script:SnapShackleCommands | ForEach-Object { $_.name }) -join ','
        Assert-True ($served -eq $local) 'host and CLI registries differ'
        $listing = Invoke-Cli @('commands')
        Assert-True ($listing.Exit -eq 0 -and $listing.Text -match 'library delete') 'text listing'
    }
    $png = Join-Path $work 'synthetic.png'
    New-TextPng $png @('Quarterly report 2026', 'Contact jane.doe@example.com')
    $saved = ''
    Test-Case 'library save, list, tag, get and delete work from the CLI, and delete needs --yes' {
        $r = Invoke-Cli @('library', 'save', '--file', $png, '--json')
        Assert-True ($r.Exit -eq 0 -and $r.Json.result.name -like 'SnapShackle-*.png') $r.Text
        $script:saved = $r.Json.result.name
        $l = Invoke-Cli @('library', 'list', '--json')
        Assert-True (@($l.Json.result.items | Where-Object { $_.name -eq $script:saved }).Count -eq 1) 'saved capture not listed'
        $t = Invoke-Cli @('library', 'tag', '--name', $script:saved, '--tags', 'demo, synthetic', '--note', 'made by cli_test', '--json')
        Assert-True ($t.Exit -eq 0) $t.Text
        $l2 = Invoke-Cli @('library', 'list', '--q', 'synthetic', '--json')
        $item = @($l2.Json.result.items | Where-Object { $_.name -eq $script:saved })[0]
        Assert-True ($null -ne $item -and $item.note -eq 'made by cli_test' -and (@($item.tags) -join ',') -eq 'demo,synthetic') ('tags not saved: ' + $l2.Text)
        $out = Join-Path $work 'got.png'
        $g = Invoke-Cli @('library', 'get', '--name', $script:saved, '--out', $out, '--json')
        Assert-True ($g.Exit -eq 0 -and $g.Json.result.sha256 -eq (Get-Sha $out) -and (Get-Sha $out) -eq (Get-Sha $png)) ('downloaded PNG differs: ' + $g.Text)
        $no = Invoke-Cli @('library', 'delete', '--name', $script:saved, '--json')
        Assert-True ($no.Exit -eq 2 -and $no.Json.errorType -eq 'usage') ('delete without --yes should be a usage error: ' + $no.Text)
        Assert-True ([IO.File]::Exists((Join-Path $appDir ('Captures\' + $script:saved)))) 'the capture was deleted without --yes'
        $dry = Invoke-Cli @('library', 'delete', '--name', $script:saved, '--dry-run', '--json')
        Assert-True ($dry.Exit -eq 0 -and $dry.Json.result.dryRun -eq $true -and [IO.File]::Exists((Join-Path $appDir ('Captures\' + $script:saved)))) 'dry run changed something'
        $tok = (Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json).token
        Assert-True (-not $dry.Text.Contains($tok)) 'the token appeared in CLI output'
        Assert-True ((Invoke-RawApi 'DELETE' ('/api/library/' + $script:saved) $tok) -eq 409) 'the API deleted without the confirmation header'
        Assert-True ((Invoke-RawApi 'GET' '/api/health' '') -eq 403) 'the API answered without a token'
        $yes = Invoke-Cli @('library', 'delete', '--name', $script:saved, '--yes', '--json')
        Assert-True ($yes.Exit -eq 0) $yes.Text
        Assert-True (-not [IO.File]::Exists((Join-Path $appDir ('Captures\' + $script:saved)))) 'capture still there after --yes'
        $audit = Get-Content -LiteralPath (Join-Path $appDir 'logs\snapshackle-audit.log') -Raw
        Assert-True ($audit -match ('library-delete ' + [regex]::Escape($script:saved) + ' via cli')) ('no audit line: ' + $audit)
    }
    Test-Case 'usage errors exit 2 with a message and never reach the host' {
        foreach ($case in @(@('nope', 'thing'), @('library', 'get', '--name', 'SnapShackle-x.png'), @('capture', 'window', '--window', 'abc', '--out', 'x.png'), @('library', 'list', '--bogus', '1'), @('library', 'get', '--name', '..\evil.png', '--out', 'x.png'), @('library', 'save', '--file', (Join-Path $work 'missing.png')), @('ocr', 'run'), @('settings', 'set', '--key', 'theme'))) {
            $r = Invoke-Cli ($case + '--json')
            Assert-True ($r.Exit -eq 2 -and $r.Json.ok -eq $false -and $r.Json.errorType -eq 'usage') ((($case -join ' ')) + ' -> exit ' + $r.Exit + ' ' + $r.Text)
        }
    }
    Test-Case 'a synthetic window can be captured by id with PrintWindow' {
        $form = [Windows.Forms.Form]::new(); $form.Text = 'Fleet Demo - cli test'; $form.StartPosition = 'Manual'; $form.Location = [Drawing.Point]::new(60, 60)
        $form.ClientSize = [Drawing.Size]::new(420, 240); $form.ShowInTaskbar = $false; $form.BackColor = [Drawing.Color]::FromArgb(255, 18, 160, 90)
        $form.Show(); $end = [DateTime]::UtcNow.AddMilliseconds(600); while ([DateTime]::UtcNow -lt $end) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 20 }
        $w = Invoke-Cli @('window', 'list', '--json')
        Assert-True (@($w.Json.result.windows | Where-Object { $_.Title -like 'Fleet Demo - cli test*' }).Count -ge 1) 'the synthetic window is not in window list'
        $out = Join-Path $work 'window.png'
        $c = Invoke-Cli @('capture', 'window', '--window', [string][long]$form.Handle, '--out', $out, '--json')
        Assert-True ($c.Exit -eq 0 -and $c.Json.result.bytes -gt 500) $c.Text
        $img = [Drawing.Bitmap]::new($out)
        try {
            Assert-True ($img.Width -ge 420 -and $img.Height -ge 240) ('size ' + $img.Width + 'x' + $img.Height)
            $p = $img.GetPixel([int]($img.Width / 2), [int]($img.Height / 2))
            Assert-True ($p.R -eq 18 -and $p.G -eq 160 -and $p.B -eq 90) ('window pixels not captured: ' + $p.R + ',' + $p.G + ',' + $p.B)
        } finally { $img.Dispose() }
        $form.Close(); $form.Dispose(); $form = $null
    }
    Test-Case 'ocr run reads synthetic text, or fails clearly where OCR is missing' {
        $r = Invoke-Cli @('ocr', 'run', '--file', $png, '--json')
        if (Test-SnapShackleOcr) {
            Assert-True ($r.Exit -eq 0 -and $r.Json.result.text -match '(?i)quarterly') ('OCR text: ' + $r.Text)
        } else {
            Assert-True ($r.Exit -eq 1 -and $r.Json.error -match 'OCR') ('expected a clear OCR error: ' + $r.Text)
        }
    }
    Test-Case 'settings set and show round-trip, typed, and unknown keys are ignored' {
        $r = Invoke-Cli @('settings', 'set', '--key', 'namePrefix', '--value', 'DemoRun', '--json')
        Assert-True ($r.Exit -eq 0 -and $r.Json.result.namePrefix -eq 'DemoRun') $r.Text
        $r2 = Invoke-Cli @('settings', 'set', '--key', 'recordFps', '--value', '9', '--json')
        Assert-True ($r2.Json.result.recordFps -eq 9 -and $r2.Json.result.namePrefix -eq 'DemoRun') $r2.Text
        $r3 = Invoke-Cli @('settings', 'set', '--key', 'bogus', '--value', 'true', '--json')
        Assert-True ($r3.Exit -eq 0 -and $null -eq $r3.Json.result.bogus) $r3.Text
        $file = Join-Path $work 'prefs.json'; [IO.File]::WriteAllText($file, '{"autoLibrary":true}', [Text.UTF8Encoding]::new($false))
        $r4 = Invoke-Cli @('settings', 'set', '--file', $file, '--json')
        Assert-True ($r4.Json.result.autoLibrary -eq $true) $r4.Text
        $show = Invoke-Cli @('settings', 'show', '--json')
        Assert-True ($show.Json.result.namePrefix -eq 'DemoRun' -and $show.Json.result.saved -eq $true) $show.Text
    }
    Test-Case '--out writes a UTF-8 file without a BOM' {
        $out = Join-Path $work 'result.json'
        $r = Invoke-Cli @('app', 'health', '--out', $out)
        Assert-True ($r.Exit -eq 0 -and [IO.File]::Exists($out)) $r.Text
        $b = [IO.File]::ReadAllBytes($out)
        Assert-True ($b[0] -ne 0xEF -and $b[0] -ne 0xFF -and $b[0] -eq [byte][char]'{') 'result file starts with a BOM'
        Assert-True ((([IO.File]::ReadAllText($out)) | ConvertFrom-Json).schema -eq 'snapshackle.result/1') 'result schema'
    }
    Test-Case 'session stop needs --yes, then stops SnapShackle and removes the session file' {
        $pidBefore = [int](Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json).pid
        $no = Invoke-Cli @('session', 'stop', '--json')
        Assert-True ($no.Exit -eq 2) ('stop without --yes: ' + $no.Text)
        $r = Invoke-Cli @('session', 'stop', '--yes', '--json')
        Assert-True ($r.Exit -eq 0 -and $r.Json.result.stopped -eq $true) $r.Text
        $gone = $false
        for ($i = 0; $i -lt 100 -and -not $gone; $i++) { Start-Sleep -Milliseconds 200; $gone = -not (Get-Process -Id $pidBefore -ErrorAction SilentlyContinue) }
        Assert-True $gone 'the host process is still running'
        Assert-True (-not [IO.File]::Exists($sessionPath)) 'the session file was left behind'
        $h = Invoke-Cli @('app', 'health', '--json')
        Assert-True ($h.Exit -eq 3 -and $h.Json.errorType -eq 'notrunning') ('health after stop: ' + $h.Text)
    }
} finally {
    if ($null -ne $form) { try { $form.Close() } catch {} }
    try { $s = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json; Stop-Process -Id ([int]$s.pid) -Force -ErrorAction SilentlyContinue } catch {}
    $env:LOCALAPPDATA = $oldLocal
    try { [IO.Directory]::Delete($work, $true) } catch {}
}
if ($script:failures -gt 0) { Write-Failure "$($script:failures) CLI test(s) failed"; exit 1 }
Write-Host 'All CLI tests passed.' -ForegroundColor Green
