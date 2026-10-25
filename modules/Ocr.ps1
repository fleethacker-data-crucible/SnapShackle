# Optional Windows 10/11 native OCR. Uses WinRT if exposed by installed PowerShell runtime.
# Makes no network calls, needs no downloaded models, and never writes the image to disk.
$script:SnapShackleOcrAvailable = $null
function Test-SnapShackleOcr {
    if ($null -ne $script:SnapShackleOcrAvailable) { return $script:SnapShackleOcrAvailable }
    $script:SnapShackleOcrAvailable = $false
    if ($PSVersionTable.PSEdition -ne 'Desktop') { return $false }
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        $type = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]
        $script:SnapShackleOcrAvailable = ($null -ne $type::TryCreateFromUserProfileLanguages())
    } catch { $script:SnapShackleOcrAvailable = $false }
    return $script:SnapShackleOcrAvailable
}
# PowerShell 5.1 cannot await IAsyncOperation<T> directly, so bridge through WindowsRuntimeSystemExtensions.AsTask<T>.
# Several one-parameter generic AsTask overloads exist (IAsyncOperation<T>, IAsyncActionWithProgress<T>, ...);
# pick the IAsyncOperation<T> one explicitly instead of whichever comes first.
$script:SnapShackleAsTask = $null
function Wait-SnapShackleWinRt([object]$Operation, [Type]$ResultType) {
    if ($null -eq $script:SnapShackleAsTask) {
        $script:SnapShackleAsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
            Where-Object {
                $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 -and
                $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
            } | Select-Object -First 1
        if ($null -eq $script:SnapShackleAsTask) { throw 'Windows Runtime async bridge is unavailable' }
    }
    $task = $script:SnapShackleAsTask.MakeGenericMethod(@($ResultType)).Invoke($null, @($Operation))
    $task.GetAwaiter().GetResult()
}
# Shrinks an image that exceeds the OCR engine's limit. Returns the PNG to recognise and the scale applied.
function Resize-SnapShackleOcrInput([byte[]]$PngBytes, [int]$MaxDimension) {
    $source = [IO.MemoryStream]::new($PngBytes, $false)
    try {
        $image = [Drawing.Image]::FromStream($source)
        try {
            $largest = [Math]::Max($image.Width, $image.Height)
            if ($largest -le $MaxDimension) { return @{ Bytes = $PngBytes; Scale = 1.0 } }
            $scale = $MaxDimension / [double]$largest
            $w = [Math]::Max(1, [int][Math]::Floor($image.Width * $scale))
            $h = [Math]::Max(1, [int][Math]::Floor($image.Height * $scale))
            $small = [Drawing.Bitmap]::new($w, $h)
            $gfx = [Drawing.Graphics]::FromImage($small)
            try {
                $gfx.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $gfx.DrawImage($image, 0, 0, $w, $h)
                $out = [IO.MemoryStream]::new()
                try { $small.Save($out, [Drawing.Imaging.ImageFormat]::Png); return @{ Bytes = $out.ToArray(); Scale = $scale } }
                finally { $out.Dispose() }
            } finally { $gfx.Dispose(); $small.Dispose() }
        } finally { $image.Dispose() }
    } finally { $source.Dispose() }
}
# Returns the recognised text plus lines and word boxes in the original image's pixel coordinates.
function Invoke-SnapShackleOcr([byte[]]$PngBytes) {
    if (-not (Test-SnapShackleOcr)) { throw 'Windows native OCR is not available in this PowerShell runtime' }
    $ocrType = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]
    $decoderType = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
    $bitmapType = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
    $resultType = [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType=WindowsRuntime]
    $prepared = Resize-SnapShackleOcrInput $PngBytes ([int]$ocrType::MaxImageDimension)
    $memory = [IO.MemoryStream]::new([byte[]]$prepared.Bytes, $false)
    $stream = $null; $bitmap = $null
    try {
        # In memory only: the screenshot never touches %TEMP%.
        $stream = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($memory)
        $decoder = Wait-SnapShackleWinRt ($decoderType::CreateAsync($stream)) $decoderType
        $bitmap = Wait-SnapShackleWinRt ($decoder.GetSoftwareBitmapAsync()) $bitmapType
        $engine = $ocrType::TryCreateFromUserProfileLanguages()
        $result = Wait-SnapShackleWinRt ($engine.RecognizeAsync($bitmap)) $resultType
        $back = 1.0 / [double]$prepared.Scale
        $lines = @(foreach ($line in $result.Lines) {
            @{
                text = [string]$line.Text
                words = @(foreach ($word in $line.Words) {
                    $r = $word.BoundingRect
                    @{ text = [string]$word.Text; x = [Math]::Round($r.X * $back, 1); y = [Math]::Round($r.Y * $back, 1)
                       w = [Math]::Round($r.Width * $back, 1); h = [Math]::Round($r.Height * $back, 1) }
                })
            }
        })
        return @{ text = [string]$result.Text; lines = $lines }
    } finally {
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        $memory.Dispose()
    }
}
