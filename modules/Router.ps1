# Optional AI help through the Fleet router (Fairlead): alt text and annotation suggestions for the open image.
# Off until the person turns it on (aiSuggest). The host makes the call, never the browser, so the router key is
# not in the page. The key is read when needed and held only in this process: never in settings, files or logs.
#
# Contract: one address for every model call, 127.0.0.1:8776 by default; SNAPSHACKLE_FAIRLEAD_URL changes the port or
# path (loopback only). The client key is the Windows Credential Manager generic credential Fairlead/SnapShackle when
# that exists, otherwise the first line of %LOCALAPPDATA%\Fairlead\local-token (the key Fairlead makes for this Windows
# account). There is no environment variable and no vault item for it. The key is sent only after GET /__fleethacker/id
# names Fairlead, the reported pid owns the port, and the reported path is that process. Nothing listening on 8776 is
# started with Start-FleetService -Name fairlead, then this client waits. This build accepts only a loopback router
# address, so a screenshot never leaves this computer through SnapShackle itself. Requests carry X-Fairlead-Privacy:
# local unless the person chose aiPrivacy = any, and X-Fairlead-Label: SnapShackle.
$script:SnapShackleRouterDefaultUrl = 'http://127.0.0.1:8776'
$script:SnapShackleFairleadPort = 8776
$script:SnapShackleFairleadWaitSeconds = 40
$script:SnapShackleKeyTarget = 'Fairlead/SnapShackle'
$script:SnapShackleMissingKeyMessage = 'Open Fairlead and install a key for SnapShackle.'
$script:SnapShackleSuggestKinds = @('redact', 'box', 'arrow', 'step', 'text')
$script:SnapShackleFairleadCache = ''
$script:SnapShacklePortCheckProblem = ''

# The router address: environment override or the default. Throws unless it is a plain http loopback address.
function Get-SnapShackleRouterUrl {
    $url = [Environment]::GetEnvironmentVariable('SNAPSHACKLE_FAIRLEAD_URL')
    if (-not $url) { $url = $script:SnapShackleRouterDefaultUrl }
    $url = $url.Trim().TrimEnd('/')
    if ($url -notmatch '^http://(127\.0\.0\.1|localhost|\[::1\]):\d{2,5}(/[A-Za-z0-9._/-]*)?$') {
        throw 'The router address must be http://127.0.0.1:<port>: SnapShackle only talks to a router on this computer.'
    }
    return $url
}

# The Credential Manager target. SNAPSHACKLE_FAIRLEAD_TARGET exists for tests only: it may name another
# Fairlead/SnapShackle-<name> credential and nothing else.
function Get-SnapShackleKeyTarget {
    $t = [Environment]::GetEnvironmentVariable('SNAPSHACKLE_FAIRLEAD_TARGET')
    if ($t -and $t -cmatch '^Fairlead/SnapShackle-[A-Za-z0-9-]{1,30}$') { return $t }
    return $script:SnapShackleKeyTarget
}

if (-not ('SnapShackleCredReader' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SnapShackleCredReader
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public int Flags;
        public int Type;
        public string TargetName;
        public string Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public int CredentialBlobSize;
        public IntPtr CredentialBlob;
        public int Persist;
        public int AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias;
        public string UserName;
    }
    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, int type, int flags, out IntPtr credential);
    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);

    public static byte[] ReadBlob(string target)
    {
        IntPtr p;
        if (!CredRead(target, 1, 0, out p)) return null;
        try
        {
            CREDENTIAL c = (CREDENTIAL)Marshal.PtrToStructure(p, typeof(CREDENTIAL));
            byte[] blob = new byte[c.CredentialBlobSize];
            if (c.CredentialBlobSize > 0) Marshal.Copy(c.CredentialBlob, blob, 0, c.CredentialBlobSize);
            return blob;
        }
        finally { CredFree(p); }
    }
}
'@
}

# Which process listens on the router port. Same check the other Fleet apps use: iphlpapi GetExtendedTcpTable,
# loopback listeners only. Compiled on first load; if Windows refuses, AI calls fail closed and the key is not sent.
if (-not ('SnapShacklePortOwner' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class SnapShacklePortOwner {
    [DllImport("iphlpapi.dll", SetLastError = true)]
    static extern uint GetExtendedTcpTable(IntPtr pTcpTable, ref int dwOutBufLen, bool sort, int ipVersion, int tableClass, uint reserved);
    const int TcpTableOwnerPidListener = 3;
    const uint ErrorInsufficientBuffer = 122;
    static int Port(int raw) { return ((raw & 0xFF) << 8) | ((raw >> 8) & 0xFF); }
    static bool Loopback(IntPtr row, int family) {
        if (family == 2) {
            byte first = Marshal.ReadByte(row, 4);
            return first == 127 || Marshal.ReadInt32(row, 4) == 0;
        }
        for (int i = 0; i < 15; i++) { if (Marshal.ReadByte(row, i) != 0) return false; }
        byte last = Marshal.ReadByte(row, 15);
        return last == 0 || last == 1;
    }
    static void Scan(int family, int rowSize, int portOffset, int pidOffset, int port, List<int> pids) {
        for (int attempt = 0; attempt < 4; attempt++) {
            int len = 0;
            GetExtendedTcpTable(IntPtr.Zero, ref len, false, family, TcpTableOwnerPidListener, 0);
            if (len <= 0) throw new InvalidOperationException("GetExtendedTcpTable gave no table size.");
            len += 4096;
            IntPtr buf = Marshal.AllocHGlobal(len);
            try {
                uint rc = GetExtendedTcpTable(buf, ref len, false, family, TcpTableOwnerPidListener, 0);
                if (rc == ErrorInsufficientBuffer) continue;
                if (rc != 0) throw new InvalidOperationException("GetExtendedTcpTable failed with error " + rc + ".");
                int n = Marshal.ReadInt32(buf);
                for (int i = 0; i < n; i++) {
                    IntPtr row = new IntPtr(buf.ToInt64() + 4 + (long)i * rowSize);
                    if (Port(Marshal.ReadInt32(row, portOffset)) != port) continue;
                    if (!Loopback(row, family)) continue;
                    int pid = Marshal.ReadInt32(row, pidOffset);
                    if (!pids.Contains(pid)) pids.Add(pid);
                }
                return;
            } finally { Marshal.FreeHGlobal(buf); }
        }
        throw new InvalidOperationException("The TCP table kept changing while it was read.");
    }
    public static int[] GetListenerPids(int port) {
        List<int> pids = new List<int>();
        Scan(2, 24, 8, 20, port, pids);
        Scan(23, 56, 20, 52, port, pids);
        return pids.ToArray();
    }
}
'@
    } catch {
        $script:SnapShacklePortCheckProblem = 'Windows did not let SnapShackle confirm which program holds the router port, so the Fairlead key was not sent.'
    }
}

# Fairlead stores the key as UTF-16 text; UTF-8 text is accepted as well. Returns '' when the blob holds no printable text.
function ConvertFrom-SnapShackleCredentialBlob([byte[]]$Blob) {
    if ($null -eq $Blob -or $Blob.Length -eq 0) { return '' }
    foreach ($enc in @([Text.Encoding]::Unicode, (New-Object System.Text.UTF8Encoding $false))) {
        $t = $enc.GetString($Blob).Trim([char]0).Trim()
        if ($t.Length -gt 0 -and $t -notmatch '[^\x21-\x7E]') { return $t }
    }
    return ''
}

# Replaceable so tests never read the real Credential Manager: { param($Target) -> key text or $null }.
$script:SnapShackleCredentialReader = {
    param([string]$Target)
    return (ConvertFrom-SnapShackleCredentialBlob ([SnapShackleCredReader]::ReadBlob($Target)))
}
function Set-SnapShackleCredentialReader([scriptblock]$Reader) {
    if ($Reader) { $script:SnapShackleCredentialReader = $Reader }
}

# %LOCALAPPDATA%\Fairlead\local-token, the key Fairlead writes on its first start for this Windows account.
function Get-SnapShackleLocalTokenPath {
    $base = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    if (-not $base) { $base = [Environment]::GetFolderPath('LocalApplicationData') }
    if (-not $base) { return '' }
    return [IO.Path]::Combine($base, 'Fairlead', 'local-token')
}

# The first line of the local-token file, or '' when it is missing, larger than 4 KB, unreadable, or not one
# line of printable text. Never logged.
function Read-SnapShackleLocalTokenFile([string]$Path) {
    try {
        if (-not $Path -or -not [IO.File]::Exists($Path)) { return '' }
        if ((New-Object IO.FileInfo $Path).Length -gt 4096) { return '' }
        $text = [IO.File]::ReadAllText($Path)
        $line = ($text -split "`r?`n", 2)[0].Trim().TrimStart([char]0xFEFF)
        if ($line.Length -eq 0 -or $line -match '[^\x21-\x7E]') { return '' }
        return $line
    } catch { return '' }
}

# Replaceable so tests never read the real file: { param($Path) -> key text or '' }.
$script:SnapShackleLocalTokenReader = { param([string]$Path) Read-SnapShackleLocalTokenFile $Path }

# Finds the client key. Credential Manager wins; otherwise the local-token file. Returns @{ key; source; note }.
# source is 'credential-manager', 'local-token' or 'none'. Never returns an error that contains the key.
function Resolve-SnapShackleRouterKey {
    $key = ''
    try { $key = [string](& $script:SnapShackleCredentialReader (Get-SnapShackleKeyTarget)) } catch { $key = '' }
    $key = $key.Trim()
    if ($key) { return @{ key = $key; source = 'credential-manager'; note = '' } }
    $token = ''
    try { $token = [string](& $script:SnapShackleLocalTokenReader (Get-SnapShackleLocalTokenPath)) } catch { $token = '' }
    $token = $token.Trim()
    if ($token -and $token -notmatch '[^\x21-\x7E]') { return @{ key = $token; source = 'local-token'; note = '' } }
    return @{ key = ''; source = 'none'; note = $script:SnapShackleMissingKeyMessage }
}

function Initialize-SnapShacklePortCheck {
    if ('SnapShacklePortOwner' -as [type]) { return '' }
    if ($script:SnapShacklePortCheckProblem) { return [string]$script:SnapShacklePortCheckProblem }
    return 'Windows did not let SnapShackle confirm which program holds the router port, so the Fairlead key was not sent.'
}

# The distinct pids listening on this loopback port. Throws when the check cannot run. The comma keeps an empty
# or one-element result an array (Windows PowerShell unwraps a returned array).
function Get-SnapShackleListenerPids([int]$Port) {
    $problem = Initialize-SnapShacklePortCheck
    if ($problem) { throw $problem }
    $pids = @([SnapShacklePortOwner]::GetListenerPids($Port))
    return ,$pids
}

# Executable and -File script from Win32_Process. '' when the process is gone or belongs to another account.
function Get-SnapShackleProcessPaths([int]$ProcessId) {
    $proc = $null
    try { $proc = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = " + $ProcessId) -ErrorAction Stop } catch { $proc = $null }
    if (-not $proc) { return @{ ExecutablePath = ''; ScriptPath = '' } }
    $file = ''
    $match = [regex]::Match([string]$proc.CommandLine, '(?i)(?:^|\s)[-/](?:file|f)\s+(?:"([^"]+)"|(\S+))')
    if ($match.Success) {
        if ($match.Groups[1].Success) { $file = $match.Groups[1].Value } else { $file = $match.Groups[2].Value }
    }
    return @{ ExecutablePath = [string]$proc.ExecutablePath; ScriptPath = $file }
}

# An absolute Windows path with no trailing separator, or '' when it is not one.
function ConvertTo-SnapShackleNormalPath([string]$Path) {
    if (-not $Path) { return '' }
    $p = $Path.Trim().Trim('"').Replace('/', '\')
    if ($p -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\?.]+\\[^\\]+)') { return '' }
    try { return [IO.Path]::GetFullPath($p).TrimEnd('\') } catch { return '' }
}

function Test-SnapShackleProcessPath([int]$ProcessId, [string]$Path) {
    $want = ConvertTo-SnapShackleNormalPath $Path
    if (-not $want) { return $false }
    $paths = & $script:SnapShackleProcessReader $ProcessId
    foreach ($candidate in @($paths.ExecutablePath, $paths.ScriptPath)) {
        $normal = ConvertTo-SnapShackleNormalPath ([string]$candidate)
        if ($normal -and [string]::Equals($normal, $want, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

# GET /__fleethacker/id with no key. Returns @{ tool; pid; path } or $null. The body is capped at 4 KB.
function Invoke-SnapShackleFairleadId([string]$Url) {
    $request = [Net.HttpWebRequest]::Create($Url.TrimEnd('/') + '/__fleethacker/id')
    $request.Method = 'GET'
    $request.Proxy = $null
    $request.Timeout = 3000
    $request.ReadWriteTimeout = 3000
    $request.KeepAlive = $false
    $request.AllowAutoRedirect = $false
    $request.Accept = 'application/json'
    $request.UserAgent = 'SnapShackle'
    $request.ServicePoint.Expect100Continue = $false
    $response = $null
    try {
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200) { return $null }
        $reader = [IO.StreamReader]::new($response.GetResponseStream(), [Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd()
        $reader.Close()
        if ($raw.Length -gt 4096) { return $null }
        $parsed = $raw | ConvertFrom-Json
        $path = ''
        $names = @($parsed.PSObject.Properties.Name)
        if ($names -contains 'path') { $path = [string]$parsed.path }
        $procId = 0
        if ($names -contains 'pid') { [void][int]::TryParse([string]$parsed.pid, [ref]$procId) }
        $tool = ''
        if ($names -contains 'tool') { $tool = [string]$parsed.tool }
        return @{ tool = $tool; pid = $procId; path = $path }
    } catch { return $null } finally { if ($response) { $response.Close() } }
}

$script:SnapShackleListenerReader = { param([int]$Port) Get-SnapShackleListenerPids $Port }
$script:SnapShackleProcessReader = { param([int]$ProcessId) Get-SnapShackleProcessPaths $ProcessId }
$script:SnapShackleIdReader = { param([string]$Url) Invoke-SnapShackleFairleadId $Url }

function Clear-SnapShackleFairleadIdentityCache { $script:SnapShackleFairleadCache = '' }

# $null when the address is Fairlead, else @{ code; error }. The id request carries no key.
# code is 'down' (nothing listening), 'port-check' (cannot tell who listens) or 'not-fairlead'.
function Test-SnapShackleFairleadIdentity([string]$Url) {
    $uri = [Uri]$Url
    $port = $uri.Port
    $notFairlead = 'Something other than Fairlead is answering on port ' + $port + ', so the key was not sent.'
    $check = Initialize-SnapShacklePortCheck
    if ($check) { return @{ code = 'port-check'; error = $check } }
    $pids = @()
    try { $pids = @(& $script:SnapShackleListenerReader $port) } catch {
        return @{ code = 'port-check'; error = 'SnapShackle could not read which program listens on the router port, so the Fairlead key was not sent.' }
    }
    if ($pids.Count -eq 0) { return @{ code = 'down'; error = 'The router did not answer. Start Fairlead (127.0.0.1:8776) or check SNAPSHACKLE_FAIRLEAD_URL.' } }
    if ($pids.Count -gt 1) { return @{ code = 'not-fairlead'; error = $notFairlead } }
    $owner = [int]$pids[0]
    $stamp = ''
    try {
        $proc = [Diagnostics.Process]::GetProcessById($owner)
        try { $stamp = ('{0}|{1}|{2}' -f $port, $owner, $proc.StartTime.ToUniversalTime().Ticks) } finally { $proc.Dispose() }
    } catch { $stamp = '' }
    if ($stamp -and $script:SnapShackleFairleadCache -ceq $stamp) { return $null }
    $id = & $script:SnapShackleIdReader $Url
    if ($null -eq $id -or [string]$id.tool -cne 'fairlead' -or [int]$id.pid -ne $owner) {
        return @{ code = 'not-fairlead'; error = $notFairlead }
    }
    $reported = [string]$id.path
    if (-not $reported) {
        $paths = & $script:SnapShackleProcessReader $owner
        $scriptPath = ConvertTo-SnapShackleNormalPath ([string]$paths.ScriptPath)
        $exe = ConvertTo-SnapShackleNormalPath ([string]$paths.ExecutablePath)
        if ($scriptPath -and $scriptPath -match '(?i)\\scripts\\Start-Fairlead\.ps1\z') { $reported = $scriptPath }
        elseif ($exe -and [IO.Path]::GetFileName($exe) -match '(?i)\Afairlead[\w.-]*\.exe\z') { $reported = $exe }
        else { return @{ code = 'not-fairlead'; error = 'The program on port ' + $port + ' says it is Fairlead but reports no path, so the key was not sent.' } }
    }
    if (-not (Test-SnapShackleProcessPath $owner $reported)) { return @{ code = 'not-fairlead'; error = $notFairlead } }
    if ($stamp) { $script:SnapShackleFairleadCache = $stamp }
    return $null
}

# edge-ops FleetPort, next to this repo (or its parent) or under %USERPROFILE%\Projects\edge-ops.
function Find-SnapShackleFleetPortModule {
    $candidates = New-Object System.Collections.Generic.List[string]
    $dir = Split-Path -Parent $PSScriptRoot
    for ($i = 0; $i -lt 3 -and $dir; $i++) {
        $parent = Split-Path -Parent $dir
        if ($parent) { $candidates.Add((Join-Path $parent 'edge-ops\tools\fleet-port\FleetPort.psm1')) }
        $dir = $parent
    }
    $profile = [Environment]::GetEnvironmentVariable('USERPROFILE')
    if ($profile) { $candidates.Add((Join-Path $profile 'Projects\edge-ops\tools\fleet-port\FleetPort.psm1')) }
    foreach ($candidate in $candidates) {
        if ([IO.File]::Exists($candidate)) { return $candidate }
    }
    return ''
}

# Starts Fairlead through FleetPort. Returns @{ State; Message }. Expected failures do not throw, and the key
# is not passed to the helper.
function Start-SnapShackleFairleadService {
    $module = Find-SnapShackleFleetPortModule
    if (-not $module) {
        return @{ State = 'unavailable'; Message = 'Fairlead is not running, and Start-FleetService was not found (edge-ops\tools\fleet-port\FleetPort.psm1 next to SnapShackle, or in %USERPROFILE%\Projects\edge-ops).' }
    }
    try { Import-Module -Name $module -ErrorAction Stop } catch {
        return @{ State = 'unavailable'; Message = 'Fairlead is not running, and FleetPort could not be loaded.' }
    }
    if (-not (Get-Command Start-FleetService -ErrorAction SilentlyContinue)) {
        return @{ State = 'unavailable'; Message = 'Fairlead is not running, and the loaded FleetPort module has no Start-FleetService.' }
    }
    try {
        $repo = Split-Path -Parent $PSScriptRoot
        $started = Start-FleetService -Name fairlead -CallerRoot $repo -WaitSeconds $script:SnapShackleFairleadWaitSeconds
    } catch {
        return @{ State = 'unavailable'; Message = 'Fairlead could not be started.' }
    }
    return @{ State = [string]$started.State; Message = [string]$started.Message }
}

$script:SnapShackleFleetStarter = { Start-SnapShackleFairleadService }

# $null when Fairlead is verified. Otherwise a sentence, and the key has not been sent.
# AlreadyStarted skips a second Start-FleetService in the same call.
function Wait-SnapShackleFairlead([string]$Url, [bool]$AlreadyStarted) {
    $problem = Test-SnapShackleFairleadIdentity $Url
    if ($null -eq $problem) { return $null }
    $uri = [Uri]$Url
    $onFairleadPort = $uri.IsLoopback -and $uri.Port -eq $script:SnapShackleFairleadPort
    if ($problem.code -ne 'down' -or -not $onFairleadPort) { return [string]$problem.error }
    if (-not $AlreadyStarted) {
        $started = & $script:SnapShackleFleetStarter
        if ([string]$started.State -eq 'unavailable') { return [string]$started.Message }
    }
    $deadline = (Get-Date).AddSeconds($script:SnapShackleFairleadWaitSeconds)
    while ($true) {
        $problem = Test-SnapShackleFairleadIdentity $Url
        if ($null -eq $problem) { return $null }
        if ($problem.code -ne 'down') { return [string]$problem.error }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 400
    }
    return 'Fairlead was started but did not answer at ' + $Url + ' within ' + $script:SnapShackleFairleadWaitSeconds + ' s.'
}
# What the studio may know: never the key itself.
function Get-SnapShackleAiStatus($Settings) {
    $enabled = ([string]$Settings.aiSuggest) -eq 'on'
    $url = ''; $problem = ''
    try { $url = Get-SnapShackleRouterUrl } catch { $problem = $_.Exception.Message }
    $key = Resolve-SnapShackleRouterKey
    return @{ enabled = $enabled; routerUrl = $url; keySource = $key.source; privacy = $(if (([string]$Settings.aiPrivacy) -eq 'any') { 'any' } else { 'local' }); problem = $(if ($problem) { $problem } else { $key.note }) }
}

# One chat call to the router. Returns @{ text; route; target }. Throws a plain-language error.
function Invoke-SnapShackleRouterChat([string]$Model, $Messages, $Settings, [int]$MaxTokens = 600, [int]$TimeoutMs = 90000) {
    if (([string]$Settings.aiSuggest) -ne 'on') { throw 'AI suggestions are off. Turn them on under Workflows, Settings.' }
    $base = Get-SnapShackleRouterUrl
    $key = Resolve-SnapShackleRouterKey
    $uri = [Uri]$base
    if (-not $key.key -and $uri.IsLoopback -and $uri.Port -eq $script:SnapShackleFairleadPort) {
        # No key yet: Fairlead's first start writes the local token. Nothing is sent to it.
        $started = & $script:SnapShackleFleetStarter
        if ([string]$started.State -ne 'unavailable') {
            $ready = Wait-SnapShackleFairlead $base $true
            $key = Resolve-SnapShackleRouterKey
            if (-not $key.key) { throw $script:SnapShackleMissingKeyMessage }
            if ($ready) { throw $ready }
        }
    }
    if (-not $key.key) { throw $script:SnapShackleMissingKeyMessage }
    $ready = Wait-SnapShackleFairlead $base $false
    if ($ready) { throw $ready }
    $payload = ConvertTo-Json -InputObject ([ordered]@{ model = $Model; messages = $Messages; max_tokens = $MaxTokens; temperature = 0.2; stream = $false }) -Depth 12 -Compress
    $request = [Net.HttpWebRequest]::Create($base + '/v1/chat/completions')
    $request.Method = 'POST'; $request.Proxy = $null; $request.Timeout = $TimeoutMs; $request.ReadWriteTimeout = $TimeoutMs
    $request.KeepAlive = $false; $request.ServicePoint.Expect100Continue = $false; $request.ContentType = 'application/json'
    $request.UserAgent = 'SnapShackle'
    $request.Headers.Add('Authorization', 'Bearer ' + $key.key)
    if (([string]$Settings.aiPrivacy) -ne 'any') { $request.Headers.Add('X-Fairlead-Privacy', 'local') }
    $request.Headers.Add('X-Fairlead-Label', 'SnapShackle')
    $body = [Text.Encoding]::UTF8.GetBytes($payload)
    $request.ContentLength = $body.Length
    try {
        $out = $request.GetRequestStream(); $out.Write($body, 0, $body.Length); $out.Close()
        $response = $request.GetResponse()
    } catch [Net.WebException] {
        $failed = $_.Exception.Response
        if ($null -eq $failed) { throw 'The router did not answer. Start Fairlead (127.0.0.1:8776) or check SNAPSHACKLE_FAIRLEAD_URL.' }
        $code = [int]$failed.StatusCode; $failed.Close()
        if ($code -eq 401 -or $code -eq 403) { throw 'The router refused the key. Open Fairlead and install a new key for SnapShackle.' }
        throw ('The router answered with an error (' + $code + ').')
    }
    try {
        $reader = [IO.StreamReader]::new($response.GetResponseStream(), [Text.Encoding]::UTF8)
        $raw = $reader.ReadToEnd(); $reader.Close()
        $route = [string]$response.Headers['X-Fairlead-Route']; $target = [string]$response.Headers['X-Fairlead-Target']
    } finally { $response.Close() }
    try { $parsed = $raw | ConvertFrom-Json } catch { throw 'The router sent an answer SnapShackle could not read.' }
    $text = [string]$parsed.choices[0].message.content
    if (-not $text) { throw 'The router returned no text.' }
    return @{ text = $text; route = $route; target = $target }
}
# The image as a message part. Large screenshots are scaled down first (the model does not need 4K).
function New-SnapShackleImagePart([byte[]]$PngBytes) {
    $prepared = Resize-SnapShackleOcrInput $PngBytes 1568
    return [ordered]@{ type = 'image_url'; image_url = [ordered]@{ url = 'data:image/png;base64,' + [Convert]::ToBase64String([byte[]]$prepared.Bytes) } }
}

function Invoke-SnapShackleAltText([byte[]]$PngBytes, $Settings) {
    $messages = @(
        [ordered]@{ role = 'system'; content = 'You write alt text for screenshots. Reply with one or two plain sentences, under 250 characters, describing what the screenshot shows for someone who cannot see it. Do not start with "Screenshot of". Never repeat passwords, tokens, account numbers or personal identifiers you can read in the image.' },
        [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'text'; text = 'Write the alt text for this screenshot.' }, (New-SnapShackleImagePart $PngBytes)) })
    $answer = Invoke-SnapShackleRouterChat 'auto' $messages $Settings 200
    $text = ($answer.text -replace '\s+', ' ').Trim().Trim('"')
    if ($text.Length -gt 500) { $text = $text.Substring(0, 500) }
    return @{ text = $text; route = $answer.route; target = $answer.target }
}

# Turns the model's reply into a short list of suggestions. Anything that is not a clean rectangle in the image, a known
# kind or a short label is dropped. Positions are fractions of the image (0 to 1) so scaling never matters.
function ConvertFrom-SnapShackleSuggestions([string]$Text) {
    $items = [Collections.Generic.List[object]]::new()
    $start = $Text.IndexOf('['); $end = $Text.LastIndexOf(']')
    if ($start -lt 0 -or $end -le $start) { return @() }
    # Windows PowerShell 5.1 returns a JSON array as one object; foreach over it visits each element.
    try { $list = $Text.Substring($start, $end - $start + 1) | ConvertFrom-Json } catch { return @() }
    foreach ($entry in $list) {
        if ($null -eq $entry -or $items.Count -ge 12) { continue }
        $kind = ([string]$entry.kind).Trim().ToLowerInvariant()
        if ($script:SnapShackleSuggestKinds -notcontains $kind) { continue }
        $nums = @()
        foreach ($name in 'x', 'y', 'w', 'h') {
            $v = 0.0
            if (-not [double]::TryParse(([string]$entry.$name), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -or [double]::IsNaN($v) -or [double]::IsInfinity($v)) { $nums = $null; break }
            $nums += $v
        }
        if ($null -eq $nums) { continue }
        $x = [Math]::Max(0.0, [Math]::Min(1.0, $nums[0])); $y = [Math]::Max(0.0, [Math]::Min(1.0, $nums[1]))
        $w = [Math]::Max(0.0, [Math]::Min(1.0 - $x, $nums[2])); $h = [Math]::Max(0.0, [Math]::Min(1.0 - $y, $nums[3]))
        if ($w -lt 0.005 -or $h -lt 0.005) { continue }
        $label = ([string]$entry.label -replace '[\x00-\x1f]', ' ').Trim()
        if ($label.Length -gt 80) { $label = $label.Substring(0, 80) }
        $items.Add([ordered]@{ kind = $kind; x = [Math]::Round($x, 4); y = [Math]::Round($y, 4); w = [Math]::Round($w, 4); h = [Math]::Round($h, 4); label = $label })
    }
    return $items.ToArray()
}
function Invoke-SnapShackleSuggest([byte[]]$PngBytes, [string]$OcrText, $Settings) {
    $hint = ''
    if ($OcrText) { $short = $OcrText; if ($short.Length -gt 1500) { $short = $short.Substring(0, 1500) }; $hint = "`nText read from the image by OCR (may contain mistakes):`n" + $short }
    $messages = @(
        [ordered]@{ role = 'system'; content = 'You suggest annotations for a screenshot that will be shared. Reply with ONLY a JSON array, no other text, at most 8 items. Each item: {"kind":"redact|box|arrow|step|text","x":0.1,"y":0.2,"w":0.3,"h":0.1,"label":"short reason"}. x, y, w, h are fractions of the image width and height, from the top left. Use "redact" for anything sensitive (names, emails, tokens, account numbers), "box" or "arrow" for the key area a reader should look at, "step" for a numbered step, "text" for a short caption.' },
        [ordered]@{ role = 'user'; content = @([ordered]@{ type = 'text'; text = ('Suggest annotations for this screenshot.' + $hint) }, (New-SnapShackleImagePart $PngBytes)) })
    $answer = Invoke-SnapShackleRouterChat 'auto' $messages $Settings 700
    return @{ suggestions = @(ConvertFrom-SnapShackleSuggestions $answer.text); route = $answer.route; target = $answer.target }
}
