# SnapShackle actions. One function per feature. The CLI (transport cli) and the localhost API (transport host)
# both enter through Invoke-SnapShackleNamedAction, which the Fleet registry calls.
$script:SnapShackleFleetModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'vendor/FleetAction/FleetAction.psm1'
# A .psm1 keeps its functions in the module. The action scriptblock is created here, in the
# caller's scope, and calls Invoke-SnapShackleNamedAction by name when the module runs it.
Import-Module -Name $script:SnapShackleFleetModule -Force -DisableNameChecking
if (-not (Get-Command Invoke-SnapShackleHandoff -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'Handoff.ps1') }
if (-not (Get-Command Invoke-SnapShackleCliTransport -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'CliClient.ps1') }
if (-not (Get-Command Get-SnapShackleCaptureList -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot 'Library.ps1') }

function ConvertTo-SnapShackleArgsSchema($Command) {
    $properties = [ordered]@{}
    $required = New-Object System.Collections.Generic.List[string]
    foreach ($option in @($Command.options)) {
        $typeName = switch ([string]$option.type) { 'int' { 'integer' } 'bool' { 'boolean' } default { 'string' } }
        $property = [ordered]@{ type = $typeName }
        if ($option.help) { $property.description = [string]$option.help }
        if ($option.type -eq 'int') { $property.minimum = -999999999; $property.maximum = 999999999 }
        if ($option.Contains('allowed') -and @($option.allowed).Count -gt 0) { $property.enum = @($option.allowed) }
        $properties[[string]$option.name] = $property
        # --out is the CLI result file, not an input the host action has to be given.
        # --out is where the CLI writes a PNG. A local --file is the CLI's path; the host may pass the bytes instead.
        $cliOnly = ([string]$option.name -eq 'out') -or ([string]$option.name -eq 'file' -and [string]$option.in -eq 'local')
        if ($option.required -and -not $cliOnly) { $required.Add([string]$option.name) }
    }
    # settings set accepts a JSON object of preference keys, not only --key/--value.
    $allowExtra = ([string]$Command.name -eq 'settings set')
    $schema = [ordered]@{ type = 'object'; additionalProperties = $allowExtra; properties = $properties }
    if ($required.Count -gt 0) { $schema.required = @($required) }
    return $schema
}

function Get-SnapShackleActionState($Context) {
    $state = @{}
    if ($script:SnapShackleActionState) {
        foreach ($key in @($script:SnapShackleActionState.Keys)) { $state[[string]$key] = $script:SnapShackleActionState[$key] }
    }
    if ($Context -is [hashtable]) {
        foreach ($name in @('Library', 'SettingsPath', 'RuntimeDir', 'CaptureNamePattern', 'Version', 'Root', 'PngBytes', 'Source', 'Audited', 'Command')) {
            if ($Context.Contains($name) -and $null -ne $Context[$name] -and [string]$Context[$name] -ne '') { $state[$name] = $Context[$name] }
        }
    }
    if (-not $state.CaptureNamePattern) { $state.CaptureNamePattern = '(?:SnapShackle|CutterMk|Lasso|SnipHero)-[a-zA-Z0-9_.-]+\.png' }
    return $state
}

function Get-SnapShackleCommandById([string]$Id) {
    $rest = $Id.Substring('snapshackle.'.Length)
    $dot = $rest.IndexOf('.')
    if ($dot -lt 1) { return $null }
    $name = $rest.Substring(0, $dot) + ' ' + $rest.Substring($dot + 1)
    return @($script:SnapShackleCommands | Where-Object { $_.name -eq $name } | Select-Object -First 1)
}

function Get-SnapShacklePngBytes($Arguments, $Context) {
    if ($Context -is [hashtable] -and $Context.Contains('PngBytes') -and $null -ne $Context.PngBytes) { return [byte[]]$Context.PngBytes }
    if ($Arguments -is [hashtable] -and $Arguments.Contains('file') -and $Arguments.file) { return [IO.File]::ReadAllBytes([string]$Arguments.file) }
    return $null
}

function Invoke-SnapShackleNamedAction([string]$Id, $Arguments, $Context) {
    $command = $null
    if ($Context -is [hashtable] -and $Context.Contains('Command') -and $Context.Command) { $command = $Context.Command }
    if ($null -eq $command) { $command = Get-SnapShackleCommandById $Id }
    $local = $false
    if ($command -and [string]$command.kind -eq 'local') { $local = $true }
    if ($Context.Transport -eq 'cli' -and -not $local) {
        $remote = @{}
        foreach ($key in @($Context.Keys)) { $remote[$key] = $Context[$key] }
        $remote.Command = $command
        return Invoke-SnapShackleCliTransport -Arguments $Arguments -Context $remote
    }
    switch ($Id) {
        'snapshackle.app.health' { return Invoke-SnapShackleHealthWork $Arguments $Context }
        'snapshackle.app.start' { return Invoke-SnapShackleAppStart -Arguments $Arguments -Root ([string](Get-SnapShackleActionState $Context).Root) }
        'snapshackle.screen.list' { return Invoke-SnapShackleScreenListWork }
        'snapshackle.window.list' { return @{ windows = @(Get-SnapShackleWindows) } }
        'snapshackle.capture.screen' { return Invoke-SnapShackleCaptureScreenWork $Arguments }
        'snapshackle.capture.window' { return Invoke-SnapShackleCaptureWindowWork $Arguments }
        'snapshackle.capture.rect' { return Invoke-SnapShackleCaptureRectWork $Arguments }
        'snapshackle.ocr.run' { return Invoke-SnapShackleOcrWork $Arguments $Context }
        'snapshackle.library.list' { return Invoke-SnapShackleLibraryListWork $Arguments $Context }
        'snapshackle.library.get' { return Invoke-SnapShackleLibraryGetWork $Arguments $Context }
        'snapshackle.library.save' { return Invoke-SnapShackleLibrarySaveWork $Arguments $Context }
        'snapshackle.library.tag' { return Invoke-SnapShackleLibraryTagWork $Arguments $Context }
        'snapshackle.library.delete' { return Invoke-SnapShackleLibraryDeleteWork $Arguments $Context }
        'snapshackle.share.list' { return Invoke-SnapShackleShareListWork $Context }
        'snapshackle.share.send' { return Invoke-SnapShackleShareSendWork $Arguments $Context }
        'snapshackle.ai.status' { return Get-SnapShackleAiStatus (Get-SnapShackleSettings (Get-SnapShackleActionState $Context).SettingsPath) }
        'snapshackle.ai.describe' { return Invoke-SnapShackleAiWork 'describe' $Arguments $Context }
        'snapshackle.ai.suggest' { return Invoke-SnapShackleAiWork 'suggest' $Arguments $Context }
        'snapshackle.settings.show' { return Get-SnapShackleSettings (Get-SnapShackleActionState $Context).SettingsPath }
        'snapshackle.settings.set' { return Invoke-SnapShackleSettingsSetWork $Arguments $Context }
        'snapshackle.session.stop' { return Invoke-SnapShackleSessionStopWork $Context }
        'snapshackle.commands.list' { return (Get-SnapShackleCommandsDocument) }
        'snapshackle.handoff.list' { return Invoke-SnapShackleHandoffWork 'list' $Arguments $Context }
        'snapshackle.handoff.export' { return Invoke-SnapShackleHandoffWork 'export' $Arguments $Context }
        'snapshackle.evidence.run' { return Invoke-SnapShackleEvidenceWork $Arguments $Context }
        default { throw ('No function is registered for ' + $Id) }
    }
}

function Invoke-SnapShackleHealthWork($Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $ocr = $false
    if (Get-Command Test-SnapShackleOcr -ErrorAction SilentlyContinue) { $ocr = [bool](Test-SnapShackleOcr) }
    $hotkeys = @()
    if ($script:shared) { $hotkeys = @($script:shared.Hotkeys) }
    $life = 'tab'
    if (Get-Command Get-SnapShackleLifecycleMode -ErrorAction SilentlyContinue) { $life = [string](Get-SnapShackleLifecycleMode) }
    return @{ capture = $true; customDataDir = [bool]$script:SnapShackleDataRoot; ocr = $ocr; version = [string]$state.Version; offline = $true; dpi = [string]$script:SnapShackleDpiMode; hotkeys = $hotkeys; lifecycle = $life }
}

function Invoke-SnapShackleScreenListWork {
    $screens = @([Windows.Forms.Screen]::AllScreens | ForEach-Object {
        @{ name = $_.DeviceName; primary = $_.Primary; left = $_.Bounds.Left; top = $_.Bounds.Top; width = $_.Bounds.Width; height = $_.Bounds.Height }
    })
    return @{ screens = $screens }
}

function Get-SnapShackleActionDelay($Arguments) {
    if ($Arguments -is [hashtable] -and $Arguments.Contains('delay') -and [string]$Arguments.delay -match '^\d+$') { return [Math]::Min(10, [int]$Arguments.delay) }
    return 0
}

function Invoke-SnapShackleCaptureScreenWork($Arguments) {
    if (Get-Command Wait-SnapShackleDelay -ErrorAction SilentlyContinue) { Wait-SnapShackleDelay (Get-SnapShackleActionDelay $Arguments) }
    $rect = [Windows.Forms.SystemInformation]::VirtualScreen
    if ($Arguments -is [hashtable] -and $Arguments.Contains('screen') -and $null -ne $Arguments.screen -and [string]$Arguments.screen -ne '' -and [string]$Arguments.screen -match '^\d+$') {
        $screens = @([Windows.Forms.Screen]::AllScreens)
        $index = [int]$Arguments.screen
        if ($index -ge $screens.Count) { throw 'Invalid screen' }
        $rect = $screens[$index].Bounds
    }
    return @{ png = [byte[]](Get-SnapShackleRect $rect) }
}

function Invoke-SnapShackleCaptureWindowWork($Arguments) {
    if (Get-Command Wait-SnapShackleDelay -ErrorAction SilentlyContinue) { Wait-SnapShackleDelay (Get-SnapShackleActionDelay $Arguments) }
    $png = Get-SnapShackleWindowCapture ([long]$Arguments.window)
    return @{ png = [byte[]]$png; method = [string]$script:SnapShackleLastWindowMethod }
}

function Invoke-SnapShackleCaptureRectWork($Arguments) {
    if (Get-Command Wait-SnapShackleDelay -ErrorAction SilentlyContinue) { Wait-SnapShackleDelay (Get-SnapShackleActionDelay $Arguments) }
    $rect = [Drawing.Rectangle]::new([int]$Arguments.x, [int]$Arguments.y, [int]$Arguments.w, [int]$Arguments.h)
    return @{ png = [byte[]](Get-SnapShackleRect $rect) }
}

function Invoke-SnapShackleOcrWork($Arguments, $Context) {
    if (-not (Get-Command Test-SnapShackleOcr -ErrorAction SilentlyContinue) -or -not (Test-SnapShackleOcr)) {
        return @{ statusCode = 501; error = 'Windows native OCR unsupported by this PowerShell environment' }
    }
    $bytes = Get-SnapShacklePngBytes $Arguments $Context
    if ($null -eq $bytes) { throw 'A PNG file is required' }
    $result = Invoke-SnapShackleOcr $bytes
    return @{ text = $result.text; lines = $result.lines; engine = 'Windows.Media.Ocr' }
}

function Invoke-SnapShackleLibraryListWork($Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $query = ''
    if ($Arguments -is [hashtable] -and $Arguments.Contains('q') -and $null -ne $Arguments.q) { $query = [string]$Arguments.q }
    [object[]]$items = Get-SnapShackleCaptureList $state.Library $query $state.CaptureNamePattern
    return @{ items = $items }
}

function Invoke-SnapShackleLibraryGetWork($Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $name = [string]$Arguments.name
    if ($name -notmatch ('^' + $state.CaptureNamePattern + '$')) { return @{ statusCode = 404; error = 'Capture not found' } }
    $path = Join-Path $state.Library $name
    if (-not (Test-Path -LiteralPath $path)) { return @{ statusCode = 404; error = 'Capture not found' } }
    return @{ png = [IO.File]::ReadAllBytes($path) }
}

function Invoke-SnapShackleLibrarySaveWork($Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $bytes = Get-SnapShacklePngBytes $Arguments $Context
    if ($null -eq $bytes) { throw 'A PNG file is required' }
    $name = Save-SnapShackleCapture $state.Library $bytes
    return @{ name = $name; indexBytes = $true }
}

function Invoke-SnapShackleLibraryTagWork($Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $name = [string]$Arguments.name
    if ($name -notmatch ('^' + $state.CaptureNamePattern + '$')) { throw 'Invalid capture name' }
    $path = Join-Path $state.Library $name
    if (-not (Test-Path -LiteralPath $path)) { return @{ statusCode = 404; error = 'Capture not found' } }
    $tags = @()
    $note = ''
    if ($Arguments.Contains('tags') -and $null -ne $Arguments.tags) {
        $raw = $Arguments.tags
        if ($raw -is [string]) { $tags = @($raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        else { $tags = @($raw | ForEach-Object { [string]$_ }) }
    }
    if ($Arguments.Contains('note') -and $null -ne $Arguments.note) { $note = [string]$Arguments.note }
    Set-SnapShackleMeta $state.Library $name @{ tags = $tags; note = $note }
    return @{ updated = $true }
}

function Invoke-SnapShackleLibraryDeleteWork($Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $name = [string]$Arguments.name
    if ($name -notmatch ('^' + $state.CaptureNamePattern + '$')) { throw 'Invalid capture name' }
    $path = Join-Path $state.Library $name
    if (-not (Test-Path -LiteralPath $path)) { return @{ statusCode = 404; error = 'Capture not found' } }
    if (-not ($Context -is [hashtable] -and $Context.Contains('Audited') -and $Context.Audited)) {
        $source = 'api'
        if ($Context.Contains('Source') -and $Context.Source) { $source = [string]$Context.Source }
        if ($state.RuntimeDir) { Write-SnapShackleAudit $state.RuntimeDir 'library-delete' $name $source }
    }
    Remove-Item -LiteralPath $path
    if ($script:thumbnailCache -and $script:thumbnailCache.ContainsKey($name)) { [void]$script:thumbnailCache.Remove($name) }
    Remove-Item -LiteralPath (Get-SnapShackleMetaPath $state.Library $name) -ErrorAction SilentlyContinue
    return @{ deleted = $true }
}

function Invoke-SnapShackleShareListWork($Context) {
    $state = Get-SnapShackleActionState $Context
    [object[]]$destinations = Get-SnapShackleShareDestinations (Get-SnapShackleSettings $state.SettingsPath)
    return @{ destinations = $destinations }
}

function Invoke-SnapShackleShareSendWork($Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $name = [string]$Arguments.capture
    if ($name -notmatch ('^' + $state.CaptureNamePattern + '$')) { throw 'Invalid capture name' }
    $destination = ''
    if ($Arguments.Contains('destination') -and $null -ne $Arguments.destination) { $destination = [string]$Arguments.destination }
    return Invoke-SnapShackleShare -Library $state.Library -CapturePath (Join-Path $state.Library $name) -Settings (Get-SnapShackleSettings $state.SettingsPath) -Kind ([string]$Arguments.kind) -Destination $destination
}

function Invoke-SnapShackleAiWork([string]$Which, $Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $settings = Get-SnapShackleSettings $state.SettingsPath
    if (([string]$settings.aiSuggest) -ne 'on') { return @{ statusCode = 409; error = 'AI suggestions are off. Turn them on under Workflows, Settings.' } }
    $bytes = Get-SnapShacklePngBytes $Arguments $Context
    if ($null -eq $bytes) { throw 'A PNG file is required' }
    try {
        if ($Which -eq 'describe') { return Invoke-SnapShackleAltText $bytes $settings }
        $ocrText = ''
        if ((Get-Command Test-SnapShackleOcr -ErrorAction SilentlyContinue) -and (Test-SnapShackleOcr)) {
            try { $ocrText = [string](Invoke-SnapShackleOcr $bytes).text } catch {}
        }
        return Invoke-SnapShackleSuggest $bytes $ocrText $settings
    } catch { return @{ statusCode = 502; error = (Protect-FleetLogText $_.Exception.Message) } }
}

function Invoke-SnapShackleSettingsSetWork($Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $changes = $Arguments
    if ($Arguments -is [hashtable] -and $Arguments.Contains('file') -and $Arguments.file) {
        $changes = [IO.File]::ReadAllText([string]$Arguments.file) | ConvertFrom-Json
    } elseif ($Arguments -is [hashtable] -and $Arguments.Contains('key') -and $Arguments.key) {
        $value = [string]$Arguments.value
        $typed = $value
        if ($value -in @('true', 'false')) { $typed = ($value -eq 'true') } elseif ($value -match '^-?\d{1,9}$') { $typed = [int]$value }
        $changes = @{ ([string]$Arguments.key) = $typed }
    }
    $saved = Set-SnapShackleSettings $state.SettingsPath $changes
    $script:stayInTraySetting = [bool]$saved.stayInTray
    return $saved
}

function Invoke-SnapShackleSessionStopWork($Context) {
    if ($script:shared -and $script:shared.Busy) { return @{ statusCode = 409; error = 'A capture is still being saved; try again in a moment' } }
    $state = Get-SnapShackleActionState $Context
    if (-not ($Context -is [hashtable] -and $Context.Contains('Audited') -and $Context.Audited)) {
        $source = 'api'
        if ($Context -is [hashtable] -and $Context.Contains('Source') -and $Context.Source) { $source = [string]$Context.Source }
        if ($state.RuntimeDir) { Write-SnapShackleAudit $state.RuntimeDir 'session-stop' '' $source }
    }
    $script:stopReason = 'End session in the studio.'
    if ($script:shared) { $script:shared.Quit = $true }
    return @{ stopped = $true }
}

function Invoke-SnapShackleHandoffWork([string]$Mode, $Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $library = ''
    if ($Arguments.Contains('library') -and $Arguments.library) { $library = [string]$Arguments.library }
    elseif ($state.Library) { $library = [string]$state.Library }
    $names = @()
    if ($Arguments.Contains('name') -and $Arguments.name) { $names = @([string]$Arguments.name) }
    $max = 200
    if ($Arguments.Contains('max') -and $null -ne $Arguments.max) { $max = [int]$Arguments.max }
    $include = $false
    if ($Arguments.Contains('includetext') -and $Arguments.includetext -eq $true) { $include = $true }
    $dry = $false
    if ($Arguments.Contains('dryrun') -and $Arguments.dryrun -eq $true) { $dry = $true }
    $query = ''; $tag = ''; $since = ''; $outdir = ''
    if ($Arguments.Contains('query')) { $query = [string]$Arguments.query }
    if ($Arguments.Contains('tag')) { $tag = [string]$Arguments.tag }
    if ($Arguments.Contains('since')) { $since = [string]$Arguments.since }
    if ($Arguments.Contains('outdir')) { $outdir = [string]$Arguments.outdir }
    $ran = Invoke-SnapShackleHandoff -Mode $Mode -Library $library -OutDir $outdir -Query $query -Tag $tag -Since $since -Name $names -Max $max -IncludeText:$include -DryRun:$dry -Root ([string]$state.Root)
    if (-not $ran.Ok) {
        $kind = $(if ([int]$ran.Exit -eq 2) { 'usage' } else { 'failed' })
        return (New-SnapShackleCliResult $false $null ([string]$ran.Error) $kind ([int]$ran.Exit))
    }
    if ($Mode -eq 'list') { return $ran.Document }
    return $ran.Summary
}

function Invoke-SnapShackleEvidenceWork($Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $root = [string]$state.Root
    if (-not $root) { $root = Split-Path -Parent $PSScriptRoot }
    $manifest = [string]$Arguments.manifest
    $outDir = [string]$Arguments.outdir
    if (-not [IO.File]::Exists($manifest)) { throw ('Manifest not found: ' + $manifest) }
    $scriptPath = Join-Path $root 'tools/evidence-capture.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw 'evidence-capture.ps1 was not found' }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) { throw 'evidence run needs Windows PowerShell 5.1 and an interactive desktop. The evidence script is unchanged.' }
    $argList = @('-NoProfile', '-NoLogo', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-Manifest', $manifest, '-OutDir', $outDir)
    if ($Arguments.Contains('keepraw') -and $Arguments.keepraw -eq $true) { $argList += '-KeepRaw' }
    if ($Arguments.Contains('skipredact') -and $Arguments.skipredact -eq $true) { $argList += '-SkipRedact' }
    $process = Start-Process -FilePath $psExe -ArgumentList $argList -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) { throw ('evidence run failed with exit ' + $process.ExitCode + '. It draws its own windows, so it needs an interactive desktop and Windows OCR unless skipredact is true.') }
    return @{ ok = $true; outDir = $outDir; exit = [int]$process.ExitCode }
}

$script:SnapShackleFleetHandler = {
    param($Arguments, $Context)
    return (Invoke-SnapShackleNamedAction ([string]$Context.ActionId) $Arguments $Context)
}

function Register-SnapShackleFleetActions {
    if (-not $script:SnapShackleCommands) { return }
    Clear-FleetActionRegistry
    foreach ($command in @($script:SnapShackleCommands)) {
        $parts = @($command.name -split ' ')
        $id = 'snapshackle.' + $parts[0] + '.' + $parts[1]
        $schema = ConvertTo-SnapShackleArgsSchema $command
        Register-FleetAction -Id $id -App 'snapshackle' -Noun $parts[0] -Verb $parts[1] -Summary ([string]$command.summary) -ArgsSchema $schema -Handler $script:SnapShackleFleetHandler -Destructive:([bool]$command.destructive) -Local ($command.kind -eq 'local') -Method ([string]$command.method) -Route ([string]$command.route)
    }
}

Register-SnapShackleFleetActions
