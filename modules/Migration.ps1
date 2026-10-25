<#
  One-time moves of data from earlier names of this app (Lasso, and before that SnipHero)
  into the CutterMk folder. Files are moved, never copied or deleted. A name that already
  exists in the CutterMk folder is left where it is, so nothing is ever overwritten.
#>
# Earlier app names, newest first. Their captures used these name prefixes too.
$script:CutterMkLegacyNames = @('Lasso', 'SnipHero')

function Move-CutterMkLegacyLibrary {
    param([string]$Legacy, [string]$Target, [string]$From = 'earlier')
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
            Write-Host ("Moved {0} {1} library file(s) into {2}" -f $result.Moved, $From, $Target) -ForegroundColor Yellow
        }
        if ($result.Skipped -gt 0) {
            Write-Warning ("{0} {1} library file(s) already exist in the CutterMk library and were left in {2}" -f $result.Skipped, $From, $Legacy)
        }
    } catch {
        Write-Warning ("Could not move {0} captures from {1}: {2}" -f $From, $Legacy, $_.Exception.Message)
    }
    return $result
}

# Moves a settings file from an earlier app folder when CutterMk has none yet.
function Move-CutterMkLegacySettings {
    param([string]$Legacy, [string]$Target)
    if (-not $Legacy -or -not [IO.File]::Exists($Legacy) -or [IO.File]::Exists($Target)) { return $false }
    try {
        $parent = [IO.Path]::GetDirectoryName($Target)
        if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
        [IO.File]::Move($Legacy, $Target)
        return $true
    } catch {
        Write-Warning ("Could not move settings from {0}: {1}" -f $Legacy, $_.Exception.Message)
        return $false
    }
}

# Runs every migration for a CutterMk data folder (normally %LOCALAPPDATA%\CutterMk).
# $BaseDir is the parent of the app folders (normally %LOCALAPPDATA%).
function Invoke-CutterMkMigration {
    param([string]$BaseDir, [string]$AppDir)
    if (-not $BaseDir) { return }
    $library = Join-Path $AppDir 'Captures'
    foreach ($name in $script:CutterMkLegacyNames) {
        $old = Join-Path $BaseDir $name
        $null = Move-CutterMkLegacySettings -Legacy (Join-Path $old 'settings.json') -Target (Join-Path $AppDir 'settings.json')
        $null = Move-CutterMkLegacyLibrary -Legacy (Join-Path $old 'Captures') -Target $library -From $name
    }
}
