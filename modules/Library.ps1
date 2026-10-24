# Capture library helpers shared by the HTTP host and the hotkey/tray thread.
function New-LassoCaptureName {
    'Lasso-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.png'
}
# Writes PNG bytes into the library under a new unique name and returns the name.
function Save-LassoCapture([string]$Library, [byte[]]$Bytes) {
    $name = New-LassoCaptureName
    [IO.File]::WriteAllBytes((Join-Path $Library $name), $Bytes)
    return $name
}
