<#
  SnapShackle command line. Every action is <noun> <verb> (id snapshackle.<noun>.<verb>) and the GUI, this CLI
  and the local API call the same function (modules/Actions.ps1, Fleet action registry).
    powershell -NoProfile -ExecutionPolicy Bypass -File snapshackle.ps1 <noun> <verb> [--option value ...] [--json] [--out file] [--yes] [--dry-run]
    powershell -NoProfile -ExecutionPolicy Bypass -File snapshackle.ps1 commands --json
    powershell -NoProfile -ExecutionPolicy Bypass -File snapshackle.ps1 --job examples\training-course-handoff.json
  commands --json is the discovery document. help --json prints the same document.
  Exit codes: 0 success, 1 the command failed, 2 usage error, 3 SnapShackle is not running.
  Nothing waits on a dialog. Destructive actions (library delete, session stop, evidence run) need --yes, which is -Confirmed.
  The session token comes from %LOCALAPPDATA%\SnapShackle\api-session.json (readable only by you); it is never printed,
  never taken on the command line, and never part of --dry-run output. Job files are JSON only.
#>
# No param block: any [Parameter()] makes the script an advanced function and --out would then match the common parameter
# -OutVariable/-OutBuffer ("ambiguous"). The arguments come from the automatic $args instead.
$Rest = @($args | ForEach-Object { [string]$_ })
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'modules/Cli.ps1')
. (Join-Path $root 'modules/Lifecycle.ps1')
. (Join-Path $root 'modules/Actions.ps1')
$ResultSchema = 'snapshackle.result/1'
$FlagNames = @('json', 'yes', 'dry-run', 'help')

function Exit-SnapShackle([int]$Code) { exit $Code }
function Write-Utf8NoBom([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }

# --- arguments ------------------------------------------------------------------------------------------------------
$positional = [Collections.Generic.List[string]]::new()
$opts = @{}
$dataDirArg = $null
$jobPath = $null
$flags = @{}
for ($i = 0; $i -lt @($Rest).Count; $i++) {
    $a = [string]$Rest[$i]
    if ($a -like '--*' -and $a.Length -gt 2) {
        $n = $a.Substring(2).ToLowerInvariant()
        # --data-dir <folder>: talk to the SnapShackle (or start the one) that keeps its data there (see Start-SnapShackle.ps1 -DataDir).
        if ($n -eq 'data-dir') { if ($i + 1 -lt @($Rest).Count) { $dataDirArg = [string]$Rest[++$i] }; continue }
        if ($n -eq 'job') { if ($i + 1 -lt @($Rest).Count) { $jobPath = [string]$Rest[++$i] }; continue }
        if ($FlagNames -contains $n) { $flags[$n] = $true; continue }
        $optType = 'string'
        if ($positional.Count -ge 2) {
            $peek = $positional[0] + ' ' + $positional[1]
            $peekCmd = @($script:SnapShackleCommands | Where-Object { $_.name -eq $peek } | Select-Object -First 1)
            if ($peekCmd.Count -eq 1) {
                $peekSpec = @($peekCmd[0].options) | Where-Object { $_.name -eq $n } | Select-Object -First 1
                if ($peekSpec) { $optType = [string]$peekSpec.type }
            }
        }
        if ($optType -eq 'bool') {
            $next = $null
            if ($i + 1 -lt @($Rest).Count) { $next = [string]$Rest[$i + 1] }
            if ($next -eq 'true' -or $next -eq 'false') { $opts[$n] = ($next -eq 'true'); $i++; continue }
            $opts[$n] = $true
            continue
        }
        if ($i + 1 -ge @($Rest).Count) { $opts[$n] = $null; continue }
        $opts[$n] = [string]$Rest[++$i]
    } else { $positional.Add($a) }
}
$asJson = [bool]$flags['json']

function Write-Result([string]$Command, [bool]$Ok, $Result, [string]$ErrorText, [string]$ErrorType, [int]$Code) {
    $doc = [ordered]@{ schema = $ResultSchema; command = $Command; ok = $Ok }
    if ($Ok) { $doc.result = $Result } else { $doc.error = $ErrorText; $doc.errorType = $ErrorType }
    $text = ConvertTo-Json -InputObject $doc -Depth 8
    if ($opts.ContainsKey('out') -and $opts['out'] -and -not $script:OutIsBinary) { Write-Utf8NoBom ([string]$opts['out']) $text }
    if ($asJson) { Write-Output $text }
    elseif ($Ok) { if ($Result -is [string]) { Write-Output $Result } else { Write-Output (ConvertTo-Json -InputObject $Result -Depth 8) } }
    else { [Console]::Error.WriteLine('snapshackle: ' + $ErrorText) }
    Exit-SnapShackle $Code
}
function Stop-Usage([string]$Command, [string]$Message) { Write-Result $Command $false $null ($Message + ' (try: snapshackle commands)') 'usage' 2 }
# A data folder of its own (--data-dir, or SNAPSHACKLE_DATA_DIR): every path below, and a SnapShackle started by app start, follows it.
try { [void](Set-SnapShackleDataRoot $dataDirArg) } catch { Stop-Usage 'snapshackle' $_.Exception.Message }

if ($jobPath) {
    $jobContext = @{ Transport = 'cli'; Root = $root }
    $job = Invoke-FleetActionJob -Path $jobPath -Context $jobContext -Confirmed:([bool]$flags['yes']) -DryRun:([bool]$flags['dry-run'])
    if (-not $job.Ok) { Write-Result ('job ' + $jobPath) $false $null $job.Error $job.ErrorType $job.Exit }
    Write-Result ('job ' + $jobPath) $true $job.Result '' '' 0
}

# --- listing --------------------------------------------------------------------------------------------------------
$commands = @($script:SnapShackleCommands)
if ($positional.Count -eq 0 -or $flags['help'] -or ($positional.Count -eq 1 -and $positional[0] -in @('help', 'commands'))) {
    if ($asJson) { Write-Output (ConvertTo-Json -InputObject (Get-SnapShackleCommandsDocument) -Depth 8); Exit-SnapShackle 0 }
    Write-Output 'snapshackle <noun> <verb> [--option value ...] [--json] [--out file] [--yes] [--dry-run]'
    Write-Output ''
    foreach ($c in $commands) {
        $o = (@($c.options) | ForEach-Object { if ($_.required) { '--' + $_.name } else { '[--' + $_.name + ']' } }) -join ' '
        Write-Output ('  {0,-16} {1}' -f $c.name, $c.summary)
        if ($o) { Write-Output ('  {0,-16}   options: {1}' -f '', $o) }
    }
    Exit-SnapShackle 0
}
$name = ($positional | Select-Object -First 2) -join ' '
$cmd = $commands | Where-Object { $_.name -eq $name } | Select-Object -First 1
if ($null -eq $cmd) { Stop-Usage $name ('Unknown command "' + $name + '"') }
if ($positional.Count -gt 2) { Stop-Usage $name ('Unexpected extra argument "' + $positional[2] + '"') }
$script:OutIsBinary = ($cmd.response -eq 'png')

# --- options --------------------------------------------------------------------------------------------------------
foreach ($k in $opts.Keys) {
    # --out on a JSON command writes the result document to that file (UTF-8, no BOM); PNG commands list it as their own option.
    if ($k -eq 'out' -and $cmd.response -ne 'png') { if (-not $opts[$k]) { Stop-Usage $name 'Option --out needs a file name' }; continue }
    $spec = @($cmd.options) | Where-Object { $_.name -eq $k } | Select-Object -First 1
    if ($null -eq $spec) { Stop-Usage $name ('Unknown option --' + $k) }
    if ($null -eq $opts[$k]) { Stop-Usage $name ('Option --' + $k + ' needs a value') }
    if ($spec.type -eq 'int' -and $opts[$k] -notmatch '^-?\d{1,9}$') { Stop-Usage $name ('Option --' + $k + ' must be a whole number') }
    if ($spec.Contains('allowed') -and $spec.allowed -notcontains $opts[$k]) { Stop-Usage $name ('Option --' + $k + ' must be one of: ' + ($spec.allowed -join ', ')) }
}
foreach ($spec in @($cmd.options)) { if ($spec.required -and -not $opts.ContainsKey($spec.name)) { Stop-Usage $name ('Missing --' + $spec.name) } }
if ($cmd.destructive -and -not $flags['yes'] -and -not $flags['dry-run']) { Stop-Usage $name ('"' + $name + '" is destructive: add --yes to confirm (or --dry-run to preview)') }
# Per-command rules the registry cannot express.
if ($name -eq 'ocr run' -and $opts.ContainsKey('file') -eq $opts.ContainsKey('name')) { Stop-Usage $name 'Give exactly one of --file or --name' }
if ($name -eq 'settings set') {
    $given = @('key', 'file') | Where-Object { $opts.ContainsKey($_) }
    if (@($given).Count -ne 1) { Stop-Usage $name 'Give --key with --value, or --file' }
    if ($opts.ContainsKey('key') -and -not $opts.ContainsKey('value')) { Stop-Usage $name '--key needs --value' }
}
if ($name -eq 'library tag' -and -not ($opts.ContainsKey('tags') -or $opts.ContainsKey('note'))) { Stop-Usage $name 'Give --tags and/or --note' }
if ($opts.ContainsKey('name') -and $cmd.route -like '*{name}*' -and $opts['name'] -notmatch '^(?:SnapShackle|CutterMk|Lasso|SnipHero)-[a-zA-Z0-9_.-]+\.png$') { Stop-Usage $name 'Not a capture name (see library list)' }
foreach ($fileOpt in @('file')) { if ($opts.ContainsKey($fileOpt) -and $cmd.name -ne 'settings set' -and -not [IO.File]::Exists([string]$opts[$fileOpt])) { Stop-Usage $name ('File not found: ' + $opts[$fileOpt]) } }
if ($name -eq 'settings set' -and $opts.ContainsKey('file') -and -not [IO.File]::Exists([string]$opts['file'])) { Stop-Usage $name ('File not found: ' + $opts['file']) }

# --- request --------------------------------------------------------------------------------------------------------
$route = [string]$cmd.route
$query = [Collections.Generic.List[string]]::new()
$bodyObject = $null
foreach ($spec in @($cmd.options)) {
    if (-not $opts.ContainsKey($spec.name)) { continue }
    $v = [string]$opts[$spec.name]
    switch ($spec.in) {
        'path' { $route = $route.Replace('{' + $spec.name + '}', [Uri]::EscapeDataString($v)) }
        'query' { $query.Add($spec.name + '=' + [Uri]::EscapeDataString($v)) }
        'body' { if ($null -eq $bodyObject) { $bodyObject = [ordered]@{} }; $bodyObject[$spec.name] = $v }
    }
}
if ($name -eq 'capture rect') { $query.Clear(); foreach ($k in 'x', 'y', 'w', 'h') { $query.Add($k + '=' + $opts[$k]) } }
if ($name -eq 'capture window') { }
if ($query.Count -gt 0) { $route += '?' + ($query -join '&') }
if ($name -eq 'library tag') {
    $bodyObject = [ordered]@{ tags = @(); note = '' }
    if ($opts.ContainsKey('tags')) { $bodyObject.tags = @(([string]$opts['tags']).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($opts.ContainsKey('note')) { $bodyObject.note = [string]$opts['note'] }
}
if ($name -eq 'settings set') {
    if ($opts.ContainsKey('file')) { $bodyObject = [IO.File]::ReadAllText([string]$opts['file']) | ConvertFrom-Json }
    else {
        $value = [string]$opts['value']; $typed = $value
        if ($value -in @('true', 'false')) { $typed = ($value -eq 'true') } elseif ($value -match '^-?\d{1,9}$') { $typed = [int]$value }
        $bodyObject = @{ ([string]$opts['key']) = $typed }
    }
}

if ($flags['dry-run']) {
    $preview = [ordered]@{ command = $name; method = $cmd.method; route = $route; destructive = [bool]$cmd.destructive; wouldSend = $(if ($null -ne $bodyObject) { $bodyObject } elseif ($cmd.request -eq 'png') { 'PNG bytes from ' + $(if ($opts.ContainsKey('file')) { $opts['file'] } else { 'library capture ' + $opts['name'] }) } else { $null }); dryRun = $true }
    Write-Result $name $true $preview '' '' 0
}

# Coerce whole numbers before the action schema sees them. Bool flags are already booleans.
foreach ($spec in @($cmd.options)) {
    if ($spec.type -eq 'int' -and $opts.ContainsKey($spec.name)) { $opts[$spec.name] = [int]$opts[$spec.name] }
}

$id = 'snapshackle.' + (($name -split ' ') -join '.')
$actionContext = @{ Transport = 'cli'; Root = $root; Command = $cmd }
$ran = Invoke-FleetAction -Id $id -Arguments $opts -Context $actionContext -Confirmed:([bool]$flags['yes']) -DryRun:$false
if (-not $ran.Ok) { Write-Result $name $false $null $ran.Error $ran.ErrorType $ran.Exit }
Write-Result $name $true $ran.Result '' '' 0
