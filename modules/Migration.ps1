<#
  One-time migrations of data from earlier names of this app into the SnapShackle folder.
  - CutterMk (the name before SnapShackle): when %LOCALAPPDATA%\SnapShackle does not exist yet,
    the CutterMk folder's captures and settings are COPIED forward and the CutterMk folder is
    left untouched, so an older CutterMk build still finds all its data. The copy is staged in a
    temporary folder and renamed into place, so an interrupted copy is retried on the next start
    and a finished one never runs again (the SnapShackle folder then exists).
  - Lasso, and before that SnipHero: unchanged from CutterMk. Their captures and settings are
    moved, never copied or deleted, and a name that already exists is left where it is.
#>
# The name this app had just before SnapShackle. Its data is copied forward, never moved.
$script:SnapShackleCopyForwardName = 'CutterMk'
# Earlier app names, newest first. Their captures used these name prefixes too.
$script:SnapShackleLegacyNames = @('Lasso', 'SnipHero')

# Copies the CutterMk data folder (captures and settings.json; not logs, which hold runtime
# files of running instances) to the SnapShackle folder when that folder does not exist yet.
# The original is never changed. Returns $true when it copied.
function Copy-SnapShackleFromCutterMk {
    param([string]$Legacy, [string]$Target)
    if (-not $Legacy -or -not $Target) { return $false }
    if ([IO.Directory]::Exists($Target) -or -not [IO.Directory]::Exists($Legacy)) { return $false }
    $parent = [IO.Path]::GetDirectoryName($Target)
    $stage = Join-Path $parent ([IO.Path]::GetFileName($Target) + '.migrating-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        [void][IO.Directory]::CreateDirectory($stage)
        $count = 0
        $settings = Join-Path $Legacy 'settings.json'
        if ([IO.File]::Exists($settings)) { [IO.File]::Copy($settings, (Join-Path $stage 'settings.json')); $count++ }
        $captures = Join-Path $Legacy 'Captures'
        if ([IO.Directory]::Exists($captures)) {
            $stageCaptures = Join-Path $stage 'Captures'
            [void][IO.Directory]::CreateDirectory($stageCaptures)
            foreach ($file in [IO.Directory]::GetFiles($captures)) {
                [IO.File]::Copy($file, (Join-Path $stageCaptures ([IO.Path]::GetFileName($file))))
                $count++
            }
        }
        # Another start may have created the folder meanwhile: never overwrite it.
        if ([IO.Directory]::Exists($Target)) { [IO.Directory]::Delete($stage, $true); return $false }
        [IO.Directory]::Move($stage, $Target)
        Write-Host ("Copied {0} file(s) from {1} into {2}; the {3} folder is unchanged." -f $count, $Legacy, $Target, $script:SnapShackleCopyForwardName) -ForegroundColor Yellow
        return $true
    } catch {
        Write-Warning ("Could not copy {0} data from {1}: {2}" -f $script:SnapShackleCopyForwardName, $Legacy, $_.Exception.Message)
        try { if ([IO.Directory]::Exists($stage)) { [IO.Directory]::Delete($stage, $true) } } catch {}
        return $false
    }
}

function Move-SnapShackleLegacyLibrary {
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
            Write-Warning ("{0} {1} library file(s) already exist in the SnapShackle library and were left in {2}" -f $result.Skipped, $From, $Legacy)
        }
    } catch {
        Write-Warning ("Could not move {0} captures from {1}: {2}" -f $From, $Legacy, $_.Exception.Message)
    }
    return $result
}

# Moves a settings file from an earlier app folder when SnapShackle has none yet.
function Move-SnapShackleLegacySettings {
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

# Runs every migration for a SnapShackle data folder (normally %LOCALAPPDATA%\SnapShackle).
# $BaseDir is the parent of the app folders (normally %LOCALAPPDATA%).
# Order: copy CutterMk forward first (it already holds whatever it moved from Lasso and
# SnipHero), then move anything still left in a Lasso or SnipHero folder, as CutterMk did.
function Invoke-SnapShackleMigration {
    param([string]$BaseDir, [string]$AppDir)
    if (-not $BaseDir) { return }
    $null = Copy-SnapShackleFromCutterMk -Legacy (Join-Path $BaseDir $script:SnapShackleCopyForwardName) -Target $AppDir
    $library = Join-Path $AppDir 'Captures'
    foreach ($name in $script:SnapShackleLegacyNames) {
        $old = Join-Path $BaseDir $name
        $null = Move-SnapShackleLegacySettings -Legacy (Join-Path $old 'settings.json') -Target (Join-Path $AppDir 'settings.json')
        $null = Move-SnapShackleLegacyLibrary -Legacy (Join-Path $old 'Captures') -Target $library -From $name
    }
}
