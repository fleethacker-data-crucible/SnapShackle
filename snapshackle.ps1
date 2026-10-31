<#
  SnapShackle command line (Fleet CLI parity): every action that has a command here is also a route of the local API,
  and both come from one registry (modules/Cli.ps1). Run through SnapShackle-CLI.bat or:
    powershell -NoProfile -ExecutionPolicy Bypass -File snapshackle.ps1 <noun> <verb> [--option value ...] [--json] [--out file] [--yes] [--dry-run]
  snapshackle commands            list every command (add --json for the machine-readable document)
  snapshackle app start           start SnapShackle headless, then run any other command against it
  Exit codes: 0 success, 1 the command failed, 2 usage error, 3 SnapShackle is not running.
  Nothing waits on a dialog. Destructive commands (library delete, session stop) need --yes.
  The session token comes from %LOCALAPPDATA%\SnapShackle\api-session.json (readable only by you); it is never printed,
  never taken on the command line, and never part of --dry-run output.
#>
# No param block: any [Parameter()] makes the script an advanced function and --out would then match the common parameter
# -OutVariable/-OutBuffer ("ambiguous"). The arguments come from the automatic $args instead.
$Rest = @($args | ForEach-Object { [string]$_ })
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'modules/Cli.ps1')
$ResultSchema = 'snapshackle.result/1'
$FlagNames = @('json', 'yes', 'dry-run', 'help')

function Exit-SnapShackle([int]$Code) { exit $Code }
function Write-Utf8NoBom([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }

# --- arguments ------------------------------------------------------------------------------------------------------
$positional = [Collections.Generic.List[string]]::new()
$opts = @{}
$flags = @{}
for ($i = 0; $i -lt @($Rest).Count; $i++) {
    $a = [string]$Rest[$i]
    if ($a -like '--*' -and $a.Length -gt 2) {
        $n = $a.Substring(2).ToLowerInvariant()
        if ($FlagNames -contains $n) { $flags[$n] = $true; continue }
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

# --- session --------------------------------------------------------------------------------------------------------
function Get-Session {
    $dir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'SnapShackle' } else { Join-Path $root 'captures' }
    $path = Get-SnapShackleSessionFilePath $dir
    if (-not [IO.File]::Exists($path)) { return $null }
    try { $s = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { return $null }
    if (-not (Get-Process -Id ([int]$s.pid) -ErrorAction SilentlyContinue)) { return $null }
    return $s
}
function Invoke-Api([string]$Method, [string]$Path, [string]$Token, [int]$Port, [byte[]]$Body, [string]$ContentType, [hashtable]$Headers = @{}) {
    $req = [Net.HttpWebRequest]::Create('http://127.0.0.1:' + $Port + $Path)
    $req.Method = $Method; $req.Proxy = $null; $req.Timeout = 60000; $req.KeepAlive = $false; $req.ServicePoint.Expect100Continue = $false
    $req.UserAgent = 'SnapShackle-CLI'
    $req.Headers.Add('X-SnapShackle-Token', $Token)
    foreach ($h in $Headers.Keys) { $req.Headers.Add($h, [string]$Headers[$h]) }
    if ($null -eq $Body -and $Method -ne 'GET') { $req.ContentLength = 0 }
    if ($null -ne $Body) { $req.ContentType = $ContentType; $req.ContentLength = $Body.Length; $s = $req.GetRequestStream(); $s.Write($Body, 0, $Body.Length); $s.Close() }
    try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response; if ($null -eq $resp) { throw } }
    $ms = [IO.MemoryStream]::new(); $rs = $resp.GetResponseStream(); $rs.CopyTo($ms); $rs.Close()
    $out = [pscustomobject]@{ Status = [int]$resp.StatusCode; Bytes = $ms.ToArray(); Type = [string]$resp.ContentType }
    $resp.Close(); $ms.Dispose()
    return $out
}
function ConvertFrom-ApiBytes([byte[]]$Bytes) { try { return ([Text.Encoding]::UTF8.GetString($Bytes) | ConvertFrom-Json) } catch { return $null } }

if ($name -eq 'app start') {
    if ($null -ne (Get-Session)) { $s = Get-Session; Write-Result $name $true ([ordered]@{ started = $false; alreadyRunning = $true; port = [int]$s.port; pid = [int]$s.pid }) '' '' 0 }
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args2 = '-NoProfile -NoLogo -STA -ExecutionPolicy Bypass -File "' + (Join-Path $root 'Start-SnapShackle.ps1') + '" -NoBrowser -NoTray -Replace'
    if ($opts.ContainsKey('port')) { $args2 += ' -Port ' + [int]$opts['port'] }
    $env:SNAPSHACKLE_AUTO_STOP = '0'
    $p = Start-Process -FilePath $psExe -ArgumentList $args2 -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 150; $i++) {
        Start-Sleep -Milliseconds 200
        $s = Get-Session
        if ($null -ne $s) {
            try { $r = Invoke-Api 'GET' '/api/health' ([string]$s.token) ([int]$s.port) $null ''; if ($r.Status -eq 200) { Write-Result $name $true ([ordered]@{ started = $true; port = [int]$s.port; pid = [int]$s.pid }) '' '' 0 } } catch {}
        }
        if ($p.HasExited) { Write-Result $name $false $null 'SnapShackle exited while starting (run Launch-SnapShackle.bat to see why)' 'failed' 1 }
    }
    Write-Result $name $false $null 'SnapShackle did not answer within 30 seconds' 'failed' 1
}

$session = Get-Session
if ($null -eq $session) { Write-Result $name $false $null 'SnapShackle is not running. Start it with: snapshackle app start' 'notrunning' 3 }
$token = [string]$session.token; $port = [int]$session.port

# Request body.
$bytes = $null; $ctype = ''
if ($cmd.request -eq 'png') {
    if ($opts.ContainsKey('name')) {
        $got = Invoke-Api 'GET' ('/api/library/' + [Uri]::EscapeDataString([string]$opts['name'])) $token $port $null ''
        if ($got.Status -ne 200) { Write-Result $name $false $null (('Capture not found: ' + $opts['name'])) 'failed' 1 }
        $bytes = $got.Bytes
    } else { $bytes = [IO.File]::ReadAllBytes([string]$opts['file']) }
    $ctype = 'image/png'
} elseif ($null -ne $bodyObject) {
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $bodyObject -Depth 8 -Compress)); $ctype = 'application/json'
}
$headers = @{}
if ($cmd.destructive -and $flags['yes']) { $headers['X-SnapShackle-Confirm'] = 'yes' }
if ($name -eq 'session stop') { $headers['X-SnapShackle-Intent'] = 'end-session' }
if ($name -eq 'session stop' -and $cmd.method -eq 'POST' -and $null -eq $bytes) { $bytes = [byte[]]@(); $ctype = 'application/json' }

try { $r = Invoke-Api $cmd.method $route $token $port $bytes $ctype $headers }
catch { Write-Result $name $false $null ('Could not reach SnapShackle: ' + $_.Exception.Message) 'notrunning' 3 }
if ($r.Status -lt 200 -or $r.Status -ge 300) {
    $err = ConvertFrom-ApiBytes $r.Bytes
    $msg = if ($err -and $err.error) { [string]$err.error } else { 'HTTP ' + $r.Status }
    Write-Result $name $false $null $msg 'failed' 1
}
if ($cmd.response -eq 'png') {
    $outPath = [string]$opts['out']
    if ($r.Bytes.Length -lt 8 -or $r.Bytes[0] -ne 137 -or $r.Bytes[1] -ne 80) { Write-Result $name $false $null 'SnapShackle did not return a PNG' 'failed' 1 }
    [IO.File]::WriteAllBytes($outPath, $r.Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = (($sha.ComputeHash($r.Bytes) | ForEach-Object { $_.ToString('x2') }) -join ''); $sha.Dispose()
    Write-Result $name $true ([ordered]@{ file = $outPath; bytes = $r.Bytes.Length; sha256 = $hash }) '' '' 0
}
$data = ConvertFrom-ApiBytes $r.Bytes
if ($name -eq 'session stop') { $data = [ordered]@{ stopped = $true } }
Write-Result $name $true $data '' '' 0
