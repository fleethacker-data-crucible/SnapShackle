<#
  One-time move of SnipHero-era captures into the Lasso library.
  Files are moved, never copied or deleted. A name that already exists in the
  Lasso library is left where it is, so nothing is ever overwritten.
#>
function Move-LassoLegacyLibrary {
    param([string]$Legacy, [string]$Target)
    $result = [pscustomobject]@{ Moved = 0; Skipped = 0; WholeFolder = $false }
    if (-not $Legacy -or -not [IO.Directory]::Exists($Legacy)) { return $result }
    try {
        if (-not [IO.Directory]::Exists($Target)) {
            $parent = [IO.Path]::GetDirectoryName($Target)
            if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
            $count = [IO.Directory]::GetFiles($Legacy).Length
            # Same volume (both under LOCALAPPDATA), so this is a rename, not a copy.
            [IO.Directory]::Move($Legacy, $Target)
            $result.Moved = $count
            $result.WholeFolder = $true
        } else {
            foreach ($file in [IO.Directory]::GetFiles($Legacy)) {
                $destination = Join-Path $Target ([IO.Path]::GetFileName($file))
                if ([IO.File]::Exists($destination)) { $result.Skipped++; continue }
                [IO.File]::Move($file, $destination)
                $result.Moved++
            }
        }
        if ($result.Moved -gt 0) {
            Write-Host ("Moved {0} SnipHero library file(s) into {1}" -f $result.Moved, $Target) -ForegroundColor Yellow
        }
        if ($result.Skipped -gt 0) {
            Write-Warning ("{0} SnipHero library file(s) already exist in the Lasso library and were left in {1}" -f $result.Skipped, $Legacy)
        }
    } catch {
        Write-Warning ("Could not move SnipHero captures from {0}: {1}" -f $Legacy, $_.Exception.Message)
    }
    return $result
}
