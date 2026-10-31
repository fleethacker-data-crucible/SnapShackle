<#
  Checks docs/CAPTURE-FORMAT.md against a real capture. Starts a real SnapShackle host (no tray, no browser, its own
  temporary LOCALAPPDATA, a free port), saves a synthetic PNG with text through the library route, tags it, and
  validates the files on disk against the field list in the document: names and place, PNG signature, sidecar fields,
  types and limits, UTF-8 without a BOM, the OCR text when Windows OCR is available, and delete removing both files.
  Nothing is captured from the screen. Usage: powershell -NoProfile -STA -File tests/capture_format_test.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$script:onActions = $env:GITHUB_ACTIONS -eq 'true'
function Write-Failure([string]$Text) {
    Write-Host $Text -ForegroundColor Red
    if ($script:onActions) { Write-Host ('::error title=capture_format_test::' + ($Text -replace "`r?`n", ' ')) }
}
trap { Write-Failure ('Unhandled error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage); exit 1 }
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$work = Join-Path ([IO.Path]::GetTempPath()) ('ss-capformat-' + [guid]::NewGuid().ToString('N'))
$appData = Join-Path $work 'appdata'; $libDir = Join-Path $appData 'SnapShackle\Captures'
[void][IO.Directory]::CreateDirectory($appData)
$script:failures = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS  $Name" } catch { $script:failures++; Write-Failure "FAIL  $Name :: $($_.Exception.Message)" }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

# The documented field list: the fenced json block marked capture-sidecar.
$docText = [IO.File]::ReadAllText((Join-Path $root 'docs\CAPTURE-FORMAT.md'))
$block = [regex]::Match($docText, '(?s)```json capture-sidecar\s*(\{.*?\})\s*```')
if (-not $block.Success) { Write-Failure 'docs/CAPTURE-FORMAT.md has no ```json capture-sidecar block'; exit 1 }
$spec = $block.Groups[1].Value | ConvertFrom-Json
$specFields = @($spec.fields.PSObject.Properties.Name)

function New-TextPng([string]$Path, [string[]]$Lines) {
    $bmp = [Drawing.Bitmap]::new(700, 140); $g = [Drawing.Graphics]::FromImage($bmp)
    $font = [Drawing.Font]::new('Arial', 28, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    $g.Clear([Drawing.Color]::White); $y = 14
    foreach ($l in $Lines) { $g.DrawString($l, $font, [Drawing.Brushes]::Black, 16, $y); $y += 52 }
    $g.Dispose(); $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
}
$png = Join-Path $work 'in.png'; New-TextPng $png @('Quarterly readiness report', 'Contact hall monitor')
$bytes = [IO.File]::ReadAllBytes($png)

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
    } elseif ($Method -in @('PUT', 'POST', 'DELETE')) { $req.ContentLength = 0 }
    try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if ($null -eq $resp) { throw } }
    $reader = [IO.StreamReader]::new($resp.GetResponseStream()); $text = $reader.ReadToEnd(); $reader.Close()
    $status = [int]$resp.StatusCode; $resp.Close()
    $json = $null; try { $json = $text | ConvertFrom-Json } catch {}
    return [pscustomobject]@{ Status = $status; Text = $text; Json = $json }
}
# The sidecar against the documented fields. Throws on the first difference, otherwise returns the parsed sidecar.
function Assert-SidecarMatchesDoc([string]$Path) {
    $raw = [IO.File]::ReadAllBytes($Path)
    Assert-True (-not ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF)) 'the sidecar has a byte-order mark; the contract says UTF-8 without one'
    $side = [Text.UTF8Encoding]::new($false, $true).GetString($raw) | ConvertFrom-Json
    $names = @($side.PSObject.Properties.Name)
    foreach ($n in $names) { Assert-True ($specFields -contains $n) ("sidecar field '$n' is not in docs/CAPTURE-FORMAT.md") }
    foreach ($n in $specFields) { Assert-True ($names -contains $n) ("documented field '$n' is missing from the sidecar") }
    Assert-True ($side.schema -is [string] -and $side.schema -eq $spec.fields.schema.value -and $spec.schema -eq $spec.fields.schema.value) 'schema value differs from the document'
    foreach ($t in @($side.tags)) { Assert-True ($t -is [string] -and $t.Length -le $spec.fields.tags.maxLength) "tag '$t' breaks the documented type or length" }
    Assert-True (@($side.tags).Count -le $spec.fields.tags.maxItems) 'more tags than documented'
    Assert-True ($side.note -is [string] -and $side.note.Length -le $spec.fields.note.maxLength) 'note breaks the documented type or length'
    Assert-True ($side.ocr -is [string] -and $side.ocr.Length -le $spec.fields.ocr.maxLength) 'ocr breaks the documented type or length'
    return $side
}
try {
    $up = $false
    for ($i = 0; $i -lt 100 -and -not $up -and -not $proc.HasExited; $i++) {
        Start-Sleep -Milliseconds 200
        try { $up = (Invoke-Api 'GET' '/' $null '').Status -eq 200 } catch {}
    }
    if (-not $up) { throw ('the host did not start: ' + $proc.StandardError.ReadToEnd()) }
    $studio = (Invoke-Api 'GET' '/assets/studio.js' $null '').Text
    $token = [regex]::Match($studio, "const TOKEN='([0-9a-f]{64})'").Groups[1].Value
    Assert-True ($token.Length -eq 64) 'no session token in studio.js'
    $ocrOn = [bool](Invoke-Api 'GET' '/api/health' $null $token).Json.ocr
    Write-Host ('      Windows OCR available: ' + $ocrOn)
    $script:name = ''

    Test-Case 'a saved capture is a PNG in %LOCALAPPDATA%\SnapShackle\Captures with a documented name' {
        $r = Invoke-Api 'POST' '/api/library' $null $token $bytes 'image/png'
        Assert-True ($r.Status -eq 200) ('save failed: ' + $r.Text)
        $script:name = $r.Json.name
        Assert-True ($script:name -match '^SnapShackle-\d{8}-\d{6}-\d{3}-[0-9a-f]{8}\.png$') ("name '$($script:name)' does not match the documented pattern")
        $file = Join-Path $libDir $script:name
        Assert-True ([IO.File]::Exists($file)) 'the PNG is not in %LOCALAPPDATA%\SnapShackle\Captures'
        $head = [IO.File]::ReadAllBytes($file)[0..7]
        Assert-True (($head -join ',') -eq '137,80,78,71,13,10,26,10') 'not a PNG'
        Assert-True (@(Get-ChildItem -LiteralPath $libDir -Directory).Count -eq 0) 'the contract says one folder with no sub-folders'
    }
    Test-Case 'tagging writes <name>.png.meta.json with exactly the documented fields' {
        $put = Invoke-Api 'PUT' ('/api/library/' + $script:name) @{ tags = @('ops', 'q3'); note = 'for review' } $token
        Assert-True ($put.Status -eq 200) ('tag failed: ' + $put.Text)
        $path = Join-Path $libDir ($script:name + '.meta.json')
        Assert-True ([IO.File]::Exists($path)) 'sidecar is not named <png name>.meta.json'
        $side = Assert-SidecarMatchesDoc $path
        Assert-True ((@($side.tags) -join ',') -eq 'ops,q3' -and $side.note -eq 'for review') 'tags or note not stored'
    }
    Test-Case 'the recognised text lands in the ocr field (empty where OCR is unavailable)' {
        $path = Join-Path $libDir ($script:name + '.meta.json')
        $text = ''
        for ($i = 0; $i -lt 50; $i++) {
            $text = [string](Assert-SidecarMatchesDoc $path).ocr
            if ($text -or -not $ocrOn) { break }
            Start-Sleep -Milliseconds 200
        }
        if ($ocrOn) { Assert-True ($text -match 'readiness') ("ocr text missing or wrong: '$text'") }
        else { Assert-True ($text -eq '') 'ocr must be empty where OCR is unavailable' }
        $side = Assert-SidecarMatchesDoc $path
        Assert-True ((@($side.tags) -join ',') -eq 'ops,q3') 'indexing the text dropped the tags'
    }
    Test-Case 'a sidecar written before the schema field existed still reads, and the library lists it' {
        $legacyName = 'SnapShackle-20250101-000000-000-aaaaaaaa.png'
        [IO.File]::WriteAllBytes((Join-Path $libDir $legacyName), $bytes)
        [IO.File]::WriteAllText((Join-Path $libDir ($legacyName + '.meta.json')), '{"tags":["old"],"note":"kept","ocr":"older text"}', [Text.UTF8Encoding]::new($false))
        $l = Invoke-Api 'GET' '/api/library?q=older' $null $token
        $item = @($l.Json.items | Where-Object { $_.name -eq $legacyName })[0]
        Assert-True ($null -ne $item -and $item.note -eq 'kept' -and (@($item.tags) -join ',') -eq 'old') ('legacy sidecar not read: ' + $l.Text)
        $null = Invoke-Api 'PUT' ('/api/library/' + $legacyName) @{ tags = @('old', 'new'); note = 'kept' } $token
        $side = Assert-SidecarMatchesDoc (Join-Path $libDir ($legacyName + '.meta.json'))
        Assert-True ($side.ocr -eq 'older text') 'rewriting the sidecar lost the indexed text'
    }
    Test-Case 'the limits in the document are enforced when writing' {
        $many = 1..30 | ForEach-Object { 'tag' + $_ + ('x' * 60) }
        $null = Invoke-Api 'PUT' ('/api/library/' + $script:name) @{ tags = $many; note = ('n' * 3000) } $token
        $side = Assert-SidecarMatchesDoc (Join-Path $libDir ($script:name + '.meta.json'))
        Assert-True (@($side.tags).Count -eq $spec.fields.tags.maxItems -and $side.note.Length -eq $spec.fields.note.maxLength) 'limits were not applied'
    }
    Test-Case 'deleting a capture removes the PNG and its sidecar' {
        $d = Invoke-Api 'DELETE' ('/api/library/' + $script:name) $null $token
        Assert-True ($d.Status -eq 200) ('delete failed: ' + $d.Text)
        Assert-True (-not [IO.File]::Exists((Join-Path $libDir $script:name)) -and -not [IO.File]::Exists((Join-Path $libDir ($script:name + '.meta.json')))) 'a file was left behind'
    }
} finally {
    try { if (-not $proc.HasExited) { $proc.Kill(); [void]$proc.WaitForExit(5000) } } catch {}
    try { [IO.Directory]::Delete($work, $true) } catch {}
}
if ($script:failures -gt 0) { Write-Failure "$($script:failures) capture format test(s) failed"; exit 1 }
Write-Host 'All capture format tests passed.' -ForegroundColor Green
