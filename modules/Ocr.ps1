# Optional Windows 10/11 native OCR. Uses WinRT if exposed by installed PowerShell runtime.
# Intentionally makes no network calls and does not require downloaded OCR models.
function Test-LassoOcr {
    if ($PSVersionTable.PSEdition -ne 'Desktop') { return $false }
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction Stop
        $type = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]
        return ($null -ne $type::TryCreateFromUserProfileLanguages())
    } catch { return $false }
}
function Wait-LassoWinRt([object]$Operation, [Type]$ResultType) {
    # PowerShell 5.1 cannot await IAsyncOperation<T> directly. Use WinRT AsTask<T>.
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 } |
        Select-Object -First 1
    if ($null -eq $method) { throw 'Windows Runtime async bridge is unavailable' }
    $task = $method.MakeGenericMethod(@($ResultType)).Invoke($null, @($Operation))
    $task.GetAwaiter().GetResult()
}
function Invoke-LassoOcr([byte[]]$PngBytes) {
    if (-not (Test-LassoOcr)) { throw 'Windows native OCR is not available in this PowerShell runtime' }
    $filePath = Join-Path $env:TEMP ('SnipHero-Ocr-' + [guid]::NewGuid().ToString('N') + '.png')
    [IO.File]::WriteAllBytes($filePath, $PngBytes)
    $stream = $null; $bitmap = $null
    try {
        $storageType = [Windows.Storage.StorageFile, Windows.Storage, ContentType=WindowsRuntime]
        $streamType = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType=WindowsRuntime]
        $decoderType = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
        $bitmapType = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType=WindowsRuntime]
        $ocrType = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime]
        $resultType = [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType=WindowsRuntime]
        $file = Wait-LassoWinRt ($storageType::GetFileFromPathAsync($filePath)) $storageType
        $stream = Wait-LassoWinRt ($file.OpenReadAsync()) $streamType
        $decoder = Wait-LassoWinRt ($decoderType::CreateAsync($stream)) $decoderType
        $bitmap = Wait-LassoWinRt ($decoder.GetSoftwareBitmapAsync()) $bitmapType
        $engine = $ocrType::TryCreateFromUserProfileLanguages()
        $result = Wait-LassoWinRt ($engine.RecognizeAsync($bitmap)) $resultType
        return [string]$result.Text
    } finally {
        if ($null -ne $bitmap) { $bitmap.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        Remove-Item -LiteralPath $filePath -ErrorAction SilentlyContinue
    }
}