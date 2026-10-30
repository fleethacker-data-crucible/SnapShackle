<#
  Real-Windows test of modules/Ocr.ps1 (Windows.Media.Ocr through Windows PowerShell 5.1).
  The image is drawn in memory from synthetic text: no screen is captured and nothing is written to disk.
  Skips (exit 0, says so) when this runtime has no WinRT OCR or no OCR language pack; fails when OCR
  is available but wrong. Usage: powershell -NoProfile -STA -File tests/windows_ocr_test.ps1
  Pass -RequireOcr on a machine that must have OCR (the CI runner) to turn a skip into a failure.
#>
param([switch]$RequireOcr)
$ErrorActionPreference = 'Stop'
$script:onActions = $env:GITHUB_ACTIONS -eq 'true'
function Write-Failure([string]$Text) {
    Write-Host $Text -ForegroundColor Red
    if ($script:onActions) { Write-Host ('::error title=windows_ocr_test::' + ($Text -replace "`r?`n", ' ')) }
}
trap { Write-Failure ('Unhandled error: ' + $_.Exception.Message + ' at ' + $_.InvocationInfo.PositionMessage); exit 1 }
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Add-Type -AssemblyName System.Drawing
. (Join-Path $root 'modules/Ocr.ps1')
Write-Host ('PowerShell ' + $PSVersionTable.PSVersion + ' ' + $PSVersionTable.PSEdition)

if (-not (Test-SnapShackleOcr)) {
    $why = 'Windows native OCR is not available here (needs Windows PowerShell 5.1 and an OCR language pack).'
    if ($RequireOcr) { Write-Failure ('FAIL  ' + $why); exit 1 }
    Write-Host ('SKIP  ' + $why) -ForegroundColor Yellow
    exit 0
}

$script:failures = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try { & $Body; Write-Host "PASS  $Name" }
    catch { $script:failures++; Write-Failure "FAIL  $Name :: $($_.Exception.Message)" }
}
function Assert-True($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

# Black text on white, drawn at a size OCR reads reliably. $Lines is an array of strings.
function New-TextPng([string[]]$Lines, [int]$Width, [int]$Height, [float]$FontSize = 28) {
    $bitmap = [Drawing.Bitmap]::new($Width, $Height)
    $gfx = [Drawing.Graphics]::FromImage($bitmap)
    $font = [Drawing.Font]::new('Arial', $FontSize, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    try {
        $gfx.Clear([Drawing.Color]::White)
        $gfx.TextRenderingHint = [Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $y = 20
        foreach ($line in $Lines) { $gfx.DrawString($line, $font, [Drawing.Brushes]::Black, 20, $y); $y += [int]($FontSize * 2) }
        $out = [IO.MemoryStream]::new()
        try { $bitmap.Save($out, [Drawing.Imaging.ImageFormat]::Png); return ,$out.ToArray() } finally { $out.Dispose() }
    } finally { $font.Dispose(); $gfx.Dispose(); $bitmap.Dispose() }
}

Test-Case 'recognises synthetic text' {
    $png = New-TextPng @('Quarterly report 2026', 'Contact: jane.doe@example.com') 760 160
    $result = Invoke-SnapShackleOcr $png
    $text = ([string]$result.text).ToLowerInvariant()
    Assert-True ($text.Contains('quarterly')) "expected 'quarterly' in: $text"
    Assert-True ($text.Contains('report')) "expected 'report' in: $text"
    Assert-True ($result.lines.Count -ge 2) ('expected 2 or more lines, got ' + $result.lines.Count)
}
Test-Case 'word boxes lie inside the image and follow reading order' {
    $png = New-TextPng @('Alpha Bravo Charlie') 600 100
    $result = Invoke-SnapShackleOcr $png
    $words = @($result.lines | ForEach-Object { $_.words } | ForEach-Object { $_ })
    Assert-True ($words.Count -ge 3) ('expected 3 or more words, got ' + $words.Count)
    foreach ($w in $words) {
        Assert-True ($w.x -ge 0 -and $w.y -ge 0 -and ($w.x + $w.w) -le 601 -and ($w.y + $w.h) -le 101) ('box outside image: ' + $w.text)
    }
    Assert-True ($words[0].x -lt $words[1].x -and $words[1].x -lt $words[2].x) 'words are not left to right'
}
Test-Case 'an image larger than the engine limit is shrunk and boxes are scaled back' {
    $limit = [int]([Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]::MaxImageDimension)
    $width = $limit + 400
    $png = New-TextPng @('Large canvas text') $width 120 40
    $result = Invoke-SnapShackleOcr $png
    $words = @($result.lines | ForEach-Object { $_.words } | ForEach-Object { $_ })
    Assert-True ($words.Count -ge 1) 'no words found in the oversize image'
    foreach ($w in $words) { Assert-True (($w.x + $w.w) -le ($width + 1)) 'box not scaled back to original pixels' }
    Assert-True (([string]$result.text).ToLowerInvariant().Contains('canvas')) ('expected "canvas" in: ' + $result.text)
}
Test-Case 'blank image returns empty text without throwing' {
    $png = New-TextPng @() 300 100
    $result = Invoke-SnapShackleOcr $png
    Assert-True (([string]$result.text).Trim().Length -eq 0) 'blank image produced text'
}
if ($script:failures -gt 0) { Write-Failure "$($script:failures) OCR test(s) failed"; exit 1 }
Write-Host 'All OCR tests passed.' -ForegroundColor Green
