# Windows PowerShell 5.1 / STA native capture diagnostic. No elevation needed.
# Run after extracting SnapShackle on an authorized interactive Windows workstation.
[CmdletBinding()]
param([switch]$DesktopCapture)
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
. (Join-Path $project 'modules/Native.ps1')
$source=[Drawing.Bitmap]::new(128,96)
try {
    $source.SetPixel(40,30,[Drawing.Color]::FromArgb(255,120,30,205))
    $selected=Copy-SnapShackleBitmapArea $source ([Drawing.Rectangle]::new(40,30,60,50))
    try {
        if ($selected.Width -ne 60 -or $selected.Height -ne 50) { throw 'Region crop dimensions are incorrect' }
        $p=$selected.GetPixel(0,0)
        if ($p.R -ne 120 -or $p.G -ne 30 -or $p.B -ne 205) { throw 'Region crop altered screenshot pixels' }
        Write-Host 'PASS: region crop preserves pixel data without recapturing desktop'
    } finally { $selected.Dispose() }
} finally { $source.Dispose() }
if ($DesktopCapture) {
    $screen=[Windows.Forms.Screen]::PrimaryScreen.Bounds
    $w=[math]::Min($screen.Width,1280)
    $h=[math]::Min($screen.Height,720)
    $region=[Drawing.Rectangle]::new($screen.Left,$screen.Top,$w,$h)
    $stopwatch=[Diagnostics.Stopwatch]::StartNew()
    $png=Get-SnapShackleRect $region
    $stopwatch.Stop()
    if ($png.Length -lt 100 -or $png[0] -ne 137 -or $png[1] -ne 80) { throw 'Desktop returned invalid PNG' }
    Write-Host ('Capture {0}x{1}, total={2:N1}ms, BitBlt={3}ms, PNG={4}ms, output={5:N0} KiB' -f $w,$h,$stopwatch.Elapsed.TotalMilliseconds,$script:SnapShackleCaptureStats.acquireMs,$script:SnapShackleCaptureStats.encodeMs,($png.Length/1kb))
}