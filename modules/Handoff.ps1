# Hand-off for Bowerbird, Capstan and Scrimshaw. tools/handoff.ps1 and the handoff actions call this.
# It reads the capture folder and never changes a capture. It does not exit the process.
$script:SnapShackleHandoffSchema = 'snapshackle.handoff/1'
$script:SnapShackleHandoffNamePattern = '(?:SnapShackle|CutterMk|Lasso|SnipHero)-[a-zA-Z0-9_.-]+\.png'

function Get-SnapShackleHandoffSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ((($sha.ComputeHash([IO.File]::ReadAllBytes($Path))) | ForEach-Object { $_.ToString('x2') }) -join '') } finally { $sha.Dispose() }
}

function Test-SnapShackleHandoffInside([string]$Parent, [string]$Child) {
    $parent = $Parent.TrimEnd('\', '/')
    $child = $Child.TrimEnd('\', '/')
    if ($child -ieq $parent) { return $true }
    if ($child.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($child.StartsWith($parent + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $false
}

function New-SnapShackleHandoffFailure([int]$Exit, [string]$Error) {
    return @{ Ok = $false; Exit = $Exit; Error = $Error }
}

# Returns Ok plus, for list, Document and Entries; for export, Summary, OutDir and Manifest.
function Invoke-SnapShackleHandoff {
    param(
        [ValidateSet('list', 'export')][string]$Mode = 'list',
        [string]$Library,
        [string]$OutDir,
        [string]$Query,
        [string]$Tag,
        [string]$Since,
        [string[]]$Name,
        [int]$Max = 200,
        [bool]$IncludeText = $false,
        [bool]$DryRun = $false,
        [string]$Root = ''
    )
    if (-not $Library) {
        $Library = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'SnapShackle\Captures' } else { Join-Path $Root 'captures' }
    }
    if ($Max -lt 1 -or $Max -gt 250) { return (New-SnapShackleHandoffFailure 2 '-Max must be between 1 and 250') }
    if (-not [IO.Directory]::Exists($Library)) { return (New-SnapShackleHandoffFailure 1 ('the capture folder was not found: ' + $Library)) }
    $library = [IO.Path]::GetFullPath($Library)
    $sinceDate = $null
    if ($Since) {
        try { $sinceDate = [datetime]::Parse($Since, [Globalization.CultureInfo]::InvariantCulture) }
        catch { return (New-SnapShackleHandoffFailure 2 ('-Since is not a date: ' + $Since)) }
    }
    $wanted = @($Name | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($n in $wanted) {
        if ($n -notmatch ('^' + $script:SnapShackleHandoffNamePattern + '$')) { return (New-SnapShackleHandoffFailure 2 ('not a capture name: ' + $n)) }
    }
    $out = $null
    if ($Mode -eq 'export') {
        if (-not $OutDir) { return (New-SnapShackleHandoffFailure 2 'export needs -OutDir') }
        $out = [IO.Path]::GetFullPath($OutDir)
        if (Test-SnapShackleHandoffInside $library $out) { return (New-SnapShackleHandoffFailure 2 '-OutDir must not be the capture folder or inside it') }
    }
    [object[]]$items = Get-SnapShackleCaptureList $library $Query $script:SnapShackleHandoffNamePattern
    if ($Tag) { $items = @($items | Where-Object { @($_.tags) -contains $Tag }) }
    if ($sinceDate) { $items = @($items | Where-Object { [datetime]::Parse($_.modified, [Globalization.CultureInfo]::InvariantCulture) -ge $sinceDate }) }
    if ($wanted.Count -gt 0) { $items = @($items | Where-Object { $wanted -contains $_.name }) }
    $items = @($items | Select-Object -First $Max)
    $entries = foreach ($item in $items) {
        $meta = Get-SnapShackleMeta $library $item.name
        $png = Join-Path $library $item.name
        $entry = [ordered]@{
            name = $item.name; file = $item.name; bytes = [long]$item.bytes; modified = $item.modified
            sha256 = (Get-SnapShackleHandoffSha256 $png); tags = @($meta.tags); note = [string]$meta.note
            sidecar = [IO.File]::Exists((Get-SnapShackleMetaPath $library $item.name)); ocrChars = ([string]$meta.ocr).Length
        }
        if ($IncludeText) { $entry.ocr = [string]$meta.ocr }
        $entry
    }
    $entries = @($entries)
    if ($Mode -eq 'list') {
        $document = [ordered]@{ schema = $script:SnapShackleHandoffSchema; source = 'SnapShackle'; count = $entries.Count; captures = $entries }
        return @{ Ok = $true; Exit = 0; Mode = 'list'; Document = $document; Entries = $entries }
    }
    $copied = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $manifestPath = Join-Path $out 'handoff.json'
    $earlier = @()
    $createdAt = (Get-Date).ToString('o')
    if ([IO.File]::Exists($manifestPath)) {
        try { $old = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json } catch { $old = $null }
        $oldSchema = $null
        if ($null -ne $old) {
            foreach ($property in @($old.PSObject.Properties)) { if ($property.Name -eq 'schema') { $oldSchema = [string]$property.Value } }
        }
        if (-not $old -or $oldSchema -ne $script:SnapShackleHandoffSchema) {
            return (New-SnapShackleHandoffFailure 1 ('handoff.json in the output folder is not a hand-off manifest; nothing was copied: ' + $manifestPath))
        }
        $oldCaptures = $null
        $oldCreated = $null
        foreach ($property in @($old.PSObject.Properties)) {
            if ($property.Name -eq 'captures') { $oldCaptures = $property.Value }
            if ($property.Name -eq 'createdAt') { $oldCreated = [string]$property.Value }
        }
        $earlier = @($oldCaptures | Where-Object { $_ })
        if ($oldCreated) { $createdAt = $oldCreated }
    }
    if (-not $DryRun) { [void][IO.Directory]::CreateDirectory($out) }
    foreach ($e in $entries) {
        $target = Join-Path $out $e.name
        if ([IO.File]::Exists($target)) { $skipped.Add([ordered]@{ name = $e.name; reason = 'a file with that name is already in the output folder' }); continue }
        if (-not $DryRun) {
            [IO.File]::Copy((Join-Path $library $e.name), $target, $false)
            if ($e.sidecar) { [IO.File]::Copy((Get-SnapShackleMetaPath $library $e.name), ($target + '.meta.json'), $false) }
        }
        $copied.Add($e)
    }
    $copiedNames = @($copied | ForEach-Object { $_.name })
    $listed = @(@($earlier | Where-Object { $copiedNames -notcontains $_.name }) + $copied.ToArray())
    $manifest = [ordered]@{ schema = $script:SnapShackleHandoffSchema; source = 'SnapShackle'; createdAt = $createdAt; updatedAt = (Get-Date).ToString('o'); count = $listed.Count; captures = $listed; skipped = $skipped.ToArray() }
    if (-not $DryRun) {
        $tmp = $manifestPath + '.tmp'
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $manifest -Depth 6), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($manifestPath)) { $bak = $manifestPath + '.bak'; [IO.File]::Replace($tmp, $manifestPath, $bak); [IO.File]::Delete($bak) } else { [IO.File]::Move($tmp, $manifestPath) }
    }
    $summary = @{ dryRun = [bool]$DryRun; copied = $copied.Count; skipped = $skipped.Count; manifest = $(if ($DryRun) { $null } else { 'handoff.json' }) }
    return @{ Ok = $true; Exit = 0; Mode = 'export'; Summary = $summary; OutDir = $out; Copied = $copied.Count; Skipped = $skipped.Count; DryRun = [bool]$DryRun }
}
