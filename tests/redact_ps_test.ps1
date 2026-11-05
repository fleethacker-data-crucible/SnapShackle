<#
  Pure tests for modules/Redact.ps1 (no OCR, no windows, no screen): the same cases as tests/redact_test.py,
  so the scripted pass and the studio find the same things.
  Usage: powershell -NoProfile -File tests/redact_ps_test.ps1
#>
$ErrorActionPreference = 'Stop'
$script:onActions = $env:GITHUB_ACTIONS -eq 'true'
function Write-Failure([string]$Text) {
    Write-Host $Text -ForegroundColor Red
    if ($script:onActions) { Write-Host ('::error title=redact_ps_test::' + ($Text -replace "`r?`n", ' ')) }
}
trap { Write-Failure ('Unhandled error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage); exit 1 }
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
. (Join-Path $root 'modules/Redact.ps1')
$script:failures = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS  $Name" } catch { $script:failures++; Write-Failure "FAIL  $Name :: $($_.Exception.Message)" }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

# Words laid out left to right, 10px per character plus a 6px gap, one line per row.
function New-Line([int]$Row, [string[]]$Texts) {
    $x = 10; $words = foreach ($t in $Texts) { @{ text = $t; x = $x; y = (20 + $Row * 30); w = ($t.Length * 10); h = 18 }; $x += $t.Length * 10 + 6 }
    return @{ text = ($Texts -join ' '); words = @($words) }
}
$lines = @(
    (New-Line 0 @('Contact', 'j.smith@corp.org', 'today')),
    (New-Line 1 @('SSN', '123-45-6789')),
    (New-Line 2 @('Call', '(757)', '555-0142', 'now')),
    (New-Line 3 @('EDIPI', '1234567890')),
    (New-Line 4 @('Card', '4111', '1111', '1111', '1111')),
    (New-Line 5 @('Host', '10.0.0.255')),
    (New-Line 7 @('Key', 'sk-DEMO0000000000000000AAAA', 'token', 'ghp_AAAAAAAAAAAAAAAAAAAAAAAA')),
    # Must NOT match: invalid IP octet, failing Luhn card, a date, an 11-digit number.
    (New-Line 6 @('bad', '999.1.1.1', '4111', '1111', '1111', '1112', '2026-10-24', '12345678901'))
)
Test-Case 'finds email, SSN, phone, DoD ID, card and IP, and nothing else' {
    $found = @(Find-SnapShackleSensitive $lines 0)
    $kinds = (@($found | ForEach-Object { $_.kind }) | Sort-Object) -join ','
    Assert-True ($kinds -eq 'card,dodid,email,ip,phone,secret,secret,ssn') "kinds: $kinds ($($found.Count) found)"
}
Test-Case 'boxes cover every word of a match' {
    $found = @(Find-SnapShackleSensitive $lines 0)
    $email = $found | Where-Object { $_.kind -eq 'email' }
    Assert-True ($email.text -eq 'j.smith@corp.org') 'email text'
    $phone = ($found | Where-Object { $_.kind -eq 'phone' }).box
    Assert-True ($phone.x -eq 56 -and $phone.x2 -eq (56 + 50 + 6 + 80)) "phone box: $($phone | ConvertTo-Json -Compress)"
    $card = ($found | Where-Object { $_.kind -eq 'card' }).box
    Assert-True (($card.x2 - $card.x) -eq (4 * 40 + 3 * 6)) "card box: $($card | ConvertTo-Json -Compress)"
}
Test-Case 'padding widens boxes on every side' {
    $found = @(Find-SnapShackleSensitive @($lines[1]) 3)
    $b = $found[0].box
    Assert-True ($b.x -eq (10 + 30 + 6 - 3) -and $b.y -eq 47 -and $b.y2 -eq 71) "padded box: $($b | ConvertTo-Json -Compress)"
}
Test-Case 'phrase search is case-insensitive and spans words' {
    $line = New-Line 0 @('Project', 'STARLING', 'and', 'project', 'starling', 'Docs')
    $hits = @(Find-SnapShackleTerm @($line) 'project starling' 0)
    Assert-True ($hits.Count -eq 2) ('expected 2 hits, got ' + $hits.Count)
    Assert-True (@(Find-SnapShackleTerm @($line) '   ' 0).Count -eq 0) 'a blank term should find nothing'
    Assert-True (@(Find-SnapShackleTerm @($line) 'a.b' 0).Count -eq 0) 'a dot in a term must not act as a wildcard'
}
Test-Case 'a line with no word boxes still yields a box from its own bounds' {
    $found = @(Find-SnapShackleSensitive @(@{ text = 'mail a@b.co'; x = 5; y = 6; w = 100; h = 12 }) 0)
    Assert-True ($found.Count -eq 1 -and $found[0].box.x -eq 5 -and $found[0].box.x2 -eq 105 -and $found[0].box.y2 -eq 18) 'line fallback box'
}
Test-Case 'redaction boxes are opaque black, clamped to the image, and leave the rest alone' {
    $bmp = [Drawing.Bitmap]::new(60, 40); $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::FromArgb(255, 200, 220, 240)); $g.Dispose()
    $m = [IO.MemoryStream]::new(); $bmp.Save($m, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    $out = Add-SnapShackleRedactionBoxes $m.ToArray() @(@{ x = 10; y = 10; x2 = 30; y2 = 20 }, @{ x = -5; y = 30; x2 = 500; y2 = 500 }, @{ x = 20; y = 20; x2 = 20; y2 = 30 })
    $r = [Drawing.Bitmap]::new([IO.MemoryStream]::new($out))
    try {
        Assert-True ($r.Width -eq 60 -and $r.Height -eq 40) 'size changed'
        $inside = $r.GetPixel(15, 15); $edge = $r.GetPixel(59, 39); $far = $r.GetPixel(40, 15); $zero = $r.GetPixel(20, 25)
        Assert-True ($inside.R -eq 0 -and $inside.G -eq 0 -and $inside.B -eq 0 -and $inside.A -eq 255) 'box is not opaque black'
        Assert-True ($edge.R -eq 0) 'clamped box missing at the corner'
        Assert-True ($far.R -eq 200 -and $far.G -eq 220 -and $far.B -eq 240) 'pixels outside the boxes changed'
        Assert-True ($zero.R -eq 200) 'a zero-width box drew something'
    } finally { $r.Dispose() }
}
if ($script:failures -gt 0) { Write-Failure "$($script:failures) redaction test(s) failed"; exit 1 }
Write-Host 'All redaction tests passed.' -ForegroundColor Green
