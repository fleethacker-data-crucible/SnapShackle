# SnapShackle actions. One function per feature. The CLI (transport cli) and the localhost API (transport host)
# both enter through Invoke-SnapShackleNamedAction, which the Fleet registry calls.
$script:SnapShackleFleetModule = Join-Path (Split-Path -Parent $PSScriptRoot) 'vendor/FleetAction/FleetAction.psd1'
Import-Module -Name $script:SnapShackleFleetModule -Force -DisableNameChecking

function Get-SnapArg($Object, [string]$Name) {
    if ($null -eq $Object -or -not $Name) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in @($Object.Keys)) { if ([string]$key -ceq $Name) { return $Object[$key] } }
        return $null
    }
    foreach ($property in @($Object.PSObject.Properties)) { if ($property.Name -ceq $Name) { return $property.Value } }
    return $null
}
function Test-SnapArg($Object, [string]$Name) {
    if ($null -eq $Object -or -not $Name) { return $false }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in @($Object.Keys)) { if ([string]$key -ceq $Name) { return $true } }
        return $false
    }
    foreach ($property in @($Object.PSObject.Properties)) { if ($property.Name -ceq $Name) { return $true } }
    return $false
}
function Invoke-SnapShackleFleet {
    param([string]$Noun, [string]$Verb, $Arguments = @{}, [switch]$Confirmed, [byte[]]$PngBytes, [bool]$SkipAudit = $false)
    $previousPng = $script:SnapShacklePendingPng
    $previousSkip = $script:SnapShackleSkipAudit
    $script:SnapShackleSkipAudit = $SkipAudit
    if ($null -ne $PngBytes) { $script:SnapShacklePendingPng = $PngBytes }
    try {
        $envelope = Invoke-FleetAction -App 'snapshackle' -Noun $Noun -Verb $Verb -Arguments $Arguments -Confirmed:$Confirmed
        if ($envelope.ok) { return [pscustomobject]@{ Ok = $true; Result = $envelope.result; Error = ''; Exit = 0 } }
        return [pscustomobject]@{ Ok = $false; Result = $null; Error = [string]$envelope.error.message; Exit = (Get-FleetExitCode -Envelope $envelope) }
    } finally {
        $script:SnapShacklePendingPng = $previousPng
        $script:SnapShackleSkipAudit = $previousSkip
    }
}
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

function Get-SnapShacklePngBytes($Arguments) {
    if ($null -ne $script:SnapShacklePendingPng) { return [byte[]]$script:SnapShacklePendingPng }
    $file = Get-SnapArg $Arguments 'file'
    if ($file) { return [IO.File]::ReadAllBytes([string]$file) }
    return $null
}

function Invoke-SnapShackleNamedAction([string]$Id, $Arguments) {
    $command = Get-SnapShackleCommandById $Id
    $local = $false
    if ($command -and [string]$command.kind -eq 'local') { $local = $true }
    $cli = $script:SnapShackleCliContext
    if ($cli -and [string]$cli.Transport -eq 'cli' -and -not $local) {
        $remote = @{ Transport = 'cli'; Root = [string]$cli.Root; Command = $cli.Command; Confirmed = [bool]$cli.Confirmed }
        return Invoke-SnapShackleCliTransport -Arguments $Arguments -Context $remote
    }
    try { return (Invoke-SnapShackleHostAction $Id $Arguments) }
    catch { return @{ statusCode = 400; error = [string]$_.Exception.Message } }
}
function Invoke-SnapShackleHostAction([string]$Id, $Arguments) {
    switch ($Id) {
        'snapshackle.app.health' { return Invoke-SnapShackleHealthWork $Arguments $null }
        'snapshackle.app.start' { return Invoke-SnapShackleAppStart -Arguments $Arguments -Root $(if ($script:SnapShackleCliContext) { [string]$script:SnapShackleCliContext.Root } else { [string](Get-SnapShackleActionState $null).Root }) }
        'snapshackle.screen.list' { return Invoke-SnapShackleScreenListWork }
        'snapshackle.window.list' { return @{ windows = @(Get-SnapShackleWindows) } }
        'snapshackle.capture.screen' { return Invoke-SnapShackleCaptureScreenWork $Arguments }
        'snapshackle.capture.window' { return Invoke-SnapShackleCaptureWindowWork $Arguments }
        'snapshackle.capture.rect' { return Invoke-SnapShackleCaptureRectWork $Arguments }
        'snapshackle.ocr.run' { return Invoke-SnapShackleOcrWork $Arguments $null }
        'snapshackle.library.list' { return Invoke-SnapShackleLibraryListWork $Arguments $null }
        'snapshackle.library.get' { return Invoke-SnapShackleLibraryGetWork $Arguments $null }
        'snapshackle.library.save' { return Invoke-SnapShackleLibrarySaveWork $Arguments $null }
        'snapshackle.library.tag' { return Invoke-SnapShackleLibraryTagWork $Arguments $null }
        'snapshackle.library.delete' { return Invoke-SnapShackleLibraryDeleteWork $Arguments $null }
        'snapshackle.share.list' { return Invoke-SnapShackleShareListWork $null }
        'snapshackle.share.send' { return Invoke-SnapShackleShareSendWork $Arguments $null }
        'snapshackle.ai.status' { return Get-SnapShackleAiStatus (Get-SnapShackleSettings (Get-SnapShackleActionState $null).SettingsPath) }
        'snapshackle.ai.describe' { return Invoke-SnapShackleAiWork 'describe' $Arguments $null }
        'snapshackle.ai.suggest' { return Invoke-SnapShackleAiWork 'suggest' $Arguments $null }
        'snapshackle.settings.show' { return Get-SnapShackleSettings (Get-SnapShackleActionState $null).SettingsPath }
        'snapshackle.settings.set' { return Invoke-SnapShackleSettingsSetWork $Arguments $null }
        'snapshackle.session.stop' { return Invoke-SnapShackleSessionStopWork $null }
        'snapshackle.handoff.list' { return Invoke-SnapShackleHandoffWork 'list' $Arguments $null }
        'snapshackle.handoff.export' { return Invoke-SnapShackleHandoffWork 'export' $Arguments $null }
        'snapshackle.evidence.run' { return Invoke-SnapShackleEvidenceWork $Arguments $null }
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
    $delay = Get-SnapArg $Arguments 'delay'
    if ($null -ne $delay -and [string]$delay -match '^\d+$') { return [Math]::Min(10, [int]$delay) }
    return 0
}

function Invoke-SnapShackleCaptureScreenWork($Arguments) {
    if (Get-Command Wait-SnapShackleDelay -ErrorAction SilentlyContinue) { Wait-SnapShackleDelay (Get-SnapShackleActionDelay $Arguments) }
    $rect = [Windows.Forms.SystemInformation]::VirtualScreen
    $screen = Get-SnapArg $Arguments 'screen'
    if ($null -ne $screen -and [string]$screen -ne '' -and [string]$screen -match '^\d+$') {
        $screens = @([Windows.Forms.Screen]::AllScreens)
        $index = [int]$screen
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
    $bytes = Get-SnapShacklePngBytes $Arguments
    if ($null -eq $bytes) { throw 'A PNG file is required' }
    $result = Invoke-SnapShackleOcr $bytes
    return @{ text = $result.text; lines = $result.lines; engine = 'Windows.Media.Ocr' }
}

function Invoke-SnapShackleLibraryListWork($Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $query = ''
    if (Test-SnapArg $Arguments 'q') { $query = [string](Get-SnapArg $Arguments 'q') }
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
    $bytes = Get-SnapShacklePngBytes $Arguments
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
    if (Test-SnapArg $Arguments 'tags' -and $null -ne (Get-SnapArg $Arguments 'tags')) {
        $raw = Get-SnapArg $Arguments 'tags'
        if ($raw -is [string]) { $tags = @($raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        else { $tags = @($raw | ForEach-Object { [string]$_ }) }
    }
    if (Test-SnapArg $Arguments 'note') { $note = [string](Get-SnapArg $Arguments 'note') }
    Set-SnapShackleMeta $state.Library $name @{ tags = $tags; note = $note }
    return @{ updated = $true }
}

function Invoke-SnapShackleLibraryDeleteWork($Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $name = [string]$Arguments.name
    if ($name -notmatch ('^' + $state.CaptureNamePattern + '$')) { throw 'Invalid capture name' }
    $path = Join-Path $state.Library $name
    if (-not (Test-Path -LiteralPath $path)) { return @{ statusCode = 404; error = 'Capture not found' } }
    if (-not $script:SnapShackleSkipAudit) {
        $source = 'api'
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
    if (Test-SnapArg $Arguments 'destination' -and $null -ne (Get-SnapArg $Arguments 'destination')) { $destination = [string](Get-SnapArg $Arguments 'destination') }
    return Invoke-SnapShackleShare -Library $state.Library -CapturePath (Join-Path $state.Library $name) -Settings (Get-SnapShackleSettings $state.SettingsPath) -Kind ([string]$Arguments.kind) -Destination $destination
}

function Invoke-SnapShackleAiWork([string]$Which, $Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $settings = Get-SnapShackleSettings $state.SettingsPath
    if (([string]$settings.aiSuggest) -ne 'on') { return @{ statusCode = 409; error = 'AI suggestions are off. Turn them on under Workflows, Settings.' } }
    $bytes = Get-SnapShacklePngBytes $Arguments
    if ($null -eq $bytes) { throw 'A PNG file is required' }
    try {
        if ($Which -eq 'describe') { return Invoke-SnapShackleAltText $bytes $settings }
        $ocrText = ''
        if ((Get-Command Test-SnapShackleOcr -ErrorAction SilentlyContinue) -and (Test-SnapShackleOcr)) {
            try { $ocrText = [string](Invoke-SnapShackleOcr $bytes).text } catch {}
        }
        return Invoke-SnapShackleSuggest $bytes $ocrText $settings
    } catch { return @{ statusCode = 502; error = [string]$_.Exception.Message } }
}

function Invoke-SnapShackleSettingsSetWork($Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $changes = $Arguments
    if ((Get-SnapArg $Arguments 'file')) {
        $changes = [IO.File]::ReadAllText([string](Get-SnapArg $Arguments 'file')) | ConvertFrom-Json
    } elseif ((Get-SnapArg $Arguments 'key')) {
        $value = [string](Get-SnapArg $Arguments 'value')
        $typed = $value
        if ($value -in @('true', 'false')) { $typed = ($value -eq 'true') } elseif ($value -match '^-?\d{1,9}$') { $typed = [int]$value }
        $changes = @{ ([string](Get-SnapArg $Arguments 'key')) = $typed }
    }
    $saved = Set-SnapShackleSettings $state.SettingsPath $changes
    $script:stayInTraySetting = [bool]$saved.stayInTray
    return $saved
}

function Invoke-SnapShackleSessionStopWork($Context) {
    if ($script:shared -and $script:shared.Busy) { return @{ statusCode = 409; error = 'A capture is still being saved; try again in a moment' } }
    $state = Get-SnapShackleActionState $Context
    if (-not $script:SnapShackleSkipAudit) {
        if ($state.RuntimeDir) { Write-SnapShackleAudit $state.RuntimeDir 'session-stop' '' 'api' }
    }
    $script:stopReason = 'End session in the studio.'
    if ($script:shared) { $script:shared.Quit = $true }
    return @{ stopped = $true }
}

function Invoke-SnapShackleHandoffWork([string]$Mode, $Arguments, $Context) {
    $state = Get-SnapShackleActionState $Context
    $library = ''
    if ((Get-SnapArg $Arguments 'library')) { $library = [string](Get-SnapArg $Arguments 'library') }
    elseif ($state.Library) { $library = [string]$state.Library }
    $names = @()
    if ((Get-SnapArg $Arguments 'name')) { $names = @([string](Get-SnapArg $Arguments 'name')) }
    $max = 200
    if ($null -ne (Get-SnapArg $Arguments 'max') -and [string](Get-SnapArg $Arguments 'max') -ne '') { $max = [int](Get-SnapArg $Arguments 'max') }
    $include = ((Get-SnapArg $Arguments 'includetext') -eq $true)
    $dry = ((Get-SnapArg $Arguments 'dryrun') -eq $true)
    $query = [string](Get-SnapArg $Arguments 'query'); $tag = [string](Get-SnapArg $Arguments 'tag'); $since = [string](Get-SnapArg $Arguments 'since'); $outdir = [string](Get-SnapArg $Arguments 'outdir')
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
    if ((Get-SnapArg $Arguments 'keepraw') -eq $true) { $argList += '-KeepRaw' }
    if ((Get-SnapArg $Arguments 'skipredact') -eq $true) { $argList += '-SkipRedact' }
    $process = Start-Process -FilePath $psExe -ArgumentList $argList -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) { throw ('evidence run failed with exit ' + $process.ExitCode + '. It draws its own windows, so it needs an interactive desktop and Windows OCR unless skipredact is true.') }
    return @{ ok = $true; outDir = $outDir; exit = [int]$process.ExitCode }
}

$script:SnapHandlers = @{
    'snapshackle.app.health' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.app.health' $Arguments }
    'snapshackle.app.start' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.app.start' $Arguments }
    'snapshackle.screen.list' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.screen.list' $Arguments }
    'snapshackle.window.list' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.window.list' $Arguments }
    'snapshackle.capture.screen' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.capture.screen' $Arguments }
    'snapshackle.capture.window' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.capture.window' $Arguments }
    'snapshackle.capture.rect' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.capture.rect' $Arguments }
    'snapshackle.ocr.run' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.ocr.run' $Arguments }
    'snapshackle.library.list' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.library.list' $Arguments }
    'snapshackle.library.get' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.library.get' $Arguments }
    'snapshackle.library.save' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.library.save' $Arguments }
    'snapshackle.library.tag' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.library.tag' $Arguments }
    'snapshackle.library.delete' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.library.delete' $Arguments }
    'snapshackle.share.list' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.share.list' $Arguments }
    'snapshackle.share.send' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.share.send' $Arguments }
    'snapshackle.ai.status' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.ai.status' $Arguments }
    'snapshackle.ai.describe' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.ai.describe' $Arguments }
    'snapshackle.ai.suggest' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.ai.suggest' $Arguments }
    'snapshackle.settings.show' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.settings.show' $Arguments }
    'snapshackle.settings.set' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.settings.set' $Arguments }
    'snapshackle.session.stop' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.session.stop' $Arguments }
    'snapshackle.handoff.list' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.handoff.list' $Arguments }
    'snapshackle.handoff.export' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.handoff.export' $Arguments }
    'snapshackle.evidence.run' = { param($Arguments) Invoke-SnapShackleNamedAction 'snapshackle.evidence.run' $Arguments }
}

function Register-SnapShackleFleetActions {
    if (-not $script:SnapShackleCommands) { return }
    Clear-FleetAction
    foreach ($command in @($script:SnapShackleCommands)) {
        $parts = @([string]$command.name -split ' ')
        if ($parts[0] -eq 'commands' -or $parts[0] -eq 'help' -or $parts[0] -eq 'job') { continue }
        $id = 'snapshackle.' + $parts[0] + '.' + $parts[1]
        $params = New-Object System.Collections.Generic.List[object]
        foreach ($option in @($command.options)) {
            $typeName = 'string'
            if ([string]$option.type -eq 'int') { $typeName = 'number' }
            elseif ([string]$option.type -eq 'bool') { $typeName = 'boolean' }
            $required = [bool]$option.required
            if ([string]$option.name -eq 'out' -or ([string]$option.name -eq 'file' -and [string]$option.in -eq 'local')) { $required = $false }
            $param = New-Object System.Management.Automation.PSObject
            $param | Add-Member -MemberType NoteProperty -Name 'name' -Value ([string]$option.name)
            $param | Add-Member -MemberType NoteProperty -Name 'type' -Value $typeName
            $param | Add-Member -MemberType NoteProperty -Name 'required' -Value $required
            $params.Add($param)
        }
        $handler = $script:SnapHandlers[$id]
        if ($null -eq $handler) { throw ('No handler for ' + $id) }
        $register = @{
            App = 'snapshackle'; Noun = $parts[0]; Verb = $parts[1]
            Description = [string]$command.summary; Handler = $handler; Parameters = $params.ToArray()
        }
        if ($command.destructive) { $null = Register-FleetAction @register -Destructive }
        else { $null = Register-FleetAction @register }
    }
}

Register-SnapShackleFleetActions
