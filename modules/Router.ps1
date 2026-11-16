# Optional AI help through the Fleet router (Fairlead): alt text and annotation suggestions for the open image.
# Off until the person turns it on (aiSuggest). The host makes the call, never the browser, so the router key is
# not in the page. The key is read when needed and held only in this process: never in settings, files SnapShackle
# writes, or logs.
#
# Contract: one address for every model call, 127.0.0.1:8776 by default; SNAPSHACKLE_FAIRLEAD_URL changes the port or
# path (loopback only). The key is the Fairlead/SnapShackle credential when that exists, otherwise the first line of
# %LOCALAPPDATA%\Fairlead\local-token (the token Fairlead makes for this Windows account). There is no environment
# variable and no vault item for it. Before the key is sent, GET /__fleethacker/id must name fairlead, the reported
# pid must own the port, and the reported path must be that process's executable or -File script. Nothing listening:
# Start-FleetService -Name fairlead, then wait. This build accepts only a loopback router address, so a screenshot
# never leaves this computer through SnapShackle itself. Requests carry X-Fairlead-Privacy: local unless the person
# chose aiPrivacy = any, and X-Fairlead-Label: SnapShackle.
$script:SnapShackleRouterDefaultUrl = 'http://127.0.0.1:8776'
$script:SnapShackleKeyTarget = 'Fairlead/SnapShackle'
$script:SnapShackleMissingKeyMessage = 'Open Fairlead and install a key for SnapShackle.'
$script:SnapShackleSuggestKinds = @('redact', 'box', 'arrow', 'step', 'text')

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

# %LOCALAPPDATA%\Fairlead\local-token. Tests set SnapShackleLocalTokenPath to a throwaway file; nothing else may.
function Get-SnapShackleLocalTokenPath {
    if ($script:SnapShackleLocalTokenPath) { return [string]$script:SnapShackleLocalTokenPath }
    $base = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $base) { $base = [Environment]::GetEnvironmentVariable('LOCALAPPDATA') }
    if (-not $base) { return '' }
    return [IO.Path]::Combine($base, 'Fairlead', 'local-token')
}
# The first line of Fairlead's local token, or '' when it is missing, unreadable, larger than 4 KB, or not an fl- key.
# The file is Fairlead's. SnapShackle never writes it and never logs what it read.
function Read-SnapShackleLocalToken([string]$Path) {
    try {
        if (-not $Path -or -not [IO.File]::Exists($Path)) { return '' }
        if ((New-Object IO.FileInfo $Path).Length -gt 4096) { return '' }
        $text = [IO.File]::ReadAllText($Path)
        $line = ($text -split "`r?`n", 2)[0]
        if ($null -eq $line) { return '' }
        $line = $line.Trim().TrimStart([char]0xFEFF)
        if ($line -cmatch '\Afl-[A-Za-z0-9_-]{8,256}\z') { return $line }
        return ''
    } catch { return '' }
}
# Credential Manager first, then Fairlead's local token. Returns @{ key; source; note }. source is
# 'credential-manager', 'local-token' or 'none'. Never returns an error that contains the key.
function Resolve-SnapShackleRouterKey {
    $key = ''
    try { $key = [string](& $script:SnapShackleCredentialReader (Get-SnapShackleKeyTarget)) } catch { $key = '' }
    $key = $key.Trim()
    if ($key) { return @{ key = $key; source = 'credential-manager'; note = '' } }
    $fileKey = Read-SnapShackleLocalToken (Get-SnapShackleLocalTokenPath)
    if ($fileKey) { return @{ key = $fileKey; source = 'local-token'; note = '' } }
    return @{ key = ''; source = 'none'; note = $script:SnapShackleMissingKeyMessage }
}

# ---- Who is on the router port (the key is not sent until this passes) ----------------------------
# iphlpapi.dll is an OS DLL. P/Invoke from Add-Type source is the same approach Semaphore uses, and it needs no admin.
$script:SnapShacklePortOwnerSource = @'
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
# $null when this process can tell who listens, else a sentence and the key is not sent. Compiled once.
function Initialize-SnapShacklePortCheck {
    if ('SnapShacklePortOwner' -as [type]) { return $null }
    if ($script:SnapShacklePortCheckProblem) { return [string]$script:SnapShacklePortCheckProblem }
    $problem = $null
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') {
        $problem = 'SnapShackle can check which program holds the router port only on Windows, so the key was not sent.'
    } else {
        try { Add-Type -TypeDefinition $script:SnapShacklePortOwnerSource -Language CSharp -ErrorAction Stop }
        catch { $problem = 'Windows did not let SnapShackle compile its port check, so the key was not sent.' }
    }
    if ($problem) { $script:SnapShacklePortCheckProblem = $problem }
    return $problem
}
# Tests replace this with { param($Port) -> int[] }. The real one reads the TCP table.
function Get-SnapShackleListenerPids([int]$Port) {
    if ($script:SnapShackleListenerLookup) { return @(& $script:SnapShackleListenerLookup $Port) }
    return @([SnapShacklePortOwner]::GetListenerPids($Port))
}
# Tests replace this with { param($ProcessId) -> @{ ExecutablePath; ScriptPath } }.
function Get-SnapShackleProcessPaths([int]$ProcessId) {
    if ($script:SnapShackleProcessLookup) { return (& $script:SnapShackleProcessLookup $ProcessId) }
    $p = $null
    try { $p = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId = ' + $ProcessId) -ErrorAction Stop } catch { $p = $null }
    if (-not $p) { return @{ ExecutablePath = ''; ScriptPath = '' } }
    $file = ''
    $m = [regex]::Match([string]$p.CommandLine, '(?i)(?:^|\s)[-/](?:file|f)\s+(?:"([^"]+)"|(\S+))')
    if ($m.Success) { if ($m.Groups[1].Success) { $file = $m.Groups[1].Value } else { $file = $m.Groups[2].Value } }
    return @{ ExecutablePath = [string]$p.ExecutablePath; ScriptPath = $file }
}
# An absolute Windows path, normalized, or '' when it is not one. Never a bare name.
function ConvertTo-SnapShackleNormalPath([string]$Path) {
    if (-not $Path) { return '' }
    $p = $Path.Trim().Trim('"').Replace('/', '\')
    if ($p -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\?.]+\\[^\\]+)') { return '' }
    if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
        try { return [IO.Path]::GetFullPath($p).TrimEnd('\') } catch { return '' }
    }
    return $p.TrimEnd('\')
}
# $true only when the id path is exactly that process's executable or -File script. Never a substring.
function Test-SnapShackleProcessPath([int]$ProcessId, [string]$Path) {
    $want = ConvertTo-SnapShackleNormalPath $Path
    if (-not $want) { return $false }
    $paths = Get-SnapShackleProcessPaths -ProcessId $ProcessId
    foreach ($candidate in @($paths.ExecutablePath, $paths.ScriptPath)) {
        $c = ConvertTo-SnapShackleNormalPath $candidate
        if ($c -and [string]::Equals($c, $want, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}
function Test-SnapShackleRouterOpen([string]$BaseUrl, [int]$TimeoutMs = 400) {
    try { $u = [Uri]$BaseUrl } catch { return $false }
    $hostName = $u.Host
    if ($hostName -eq 'localhost') { $hostName = '127.0.0.1' }
    $c = New-Object Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($hostName, $u.Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs)) { return $false }
        $c.EndConnect($ar)
        return $true
    } catch { return $false } finally { try { $c.Close() } catch {} }
}
# $null when the address is Fairlead, else a sentence. The request carries no key.
function Test-SnapShackleFairleadIdentity([string]$BaseUrl) {
    $u = [Uri]$BaseUrl
    $port = $u.Port
    $notFairlead = 'Something other than Fairlead is answering on port ' + $port + ', so the key was not sent.'
    # A test stub replaces the TCP table. The real check compiles only on Windows and fails closed anywhere else.
    if (-not $script:SnapShackleListenerLookup) {
        $problem = Initialize-SnapShacklePortCheck
        if ($problem) { return $problem }
    }
    try { $pids = @(Get-SnapShackleListenerPids -Port $port | Where-Object { $null -ne $_ }) }
    catch { return ('SnapShackle could not read which program listens on port ' + $port + ', so the key was not sent.') }
    if ($pids.Count -eq 0) { return ('Fairlead is not running at ' + $BaseUrl + ', so the key was not sent.') }
    if ($pids.Count -gt 1) { return $notFairlead }
    $owner = 0
    if (-not [int]::TryParse([string]$pids[0], [ref]$owner)) { return $notFairlead }
    $req = [Net.HttpWebRequest]::Create($u.GetLeftPart([UriPartial]::Authority) + '/__fleethacker/id')
    $req.Method = 'GET'; $req.Timeout = 3000; $req.ReadWriteTimeout = 3000; $req.Proxy = $null
    $req.AllowAutoRedirect = $false; $req.Accept = 'application/json'; $req.UserAgent = 'SnapShackle'; $req.KeepAlive = $false
    $req.ServicePoint.Expect100Continue = $false
    $resp = $null
    try {
        try { $resp = $req.GetResponse() } catch [Net.WebException] {
            if ($null -ne $_.Exception.Response) { try { $_.Exception.Response.Close() } catch {} }
            return ('The program at ' + $u.Authority + ' did not identify itself as Fairlead, so the key was not sent.')
        }
        if ([int]$resp.StatusCode -ne 200) { return ('The program at ' + $u.Authority + ' did not identify itself as Fairlead, so the key was not sent.') }
        $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        if ($text.Length -gt 4096) { return $notFairlead }
        $id = $null
        try { $id = $text.TrimStart([char]0xFEFF).Trim() | ConvertFrom-Json } catch { return $notFairlead }
        $tool = [string]$id.tool
        if ($tool -cne 'fairlead') {
            $who = 'something else'
            if ($tool -cmatch '\A[A-Za-z0-9._-]{1,40}\z') { $who = '"' + $tool + '"' }
            return ('The program at ' + $u.Authority + ' is ' + $who + ', not Fairlead, so the key was not sent.')
        }
        $idPid = 0
        if (-not [int]::TryParse([string]$id.pid, [ref]$idPid) -or $idPid -ne $owner) {
            return ('The program on port ' + $port + ' is not the one that answered the identity check, so the key was not sent.')
        }
        $reported = [string]$id.path
        if (-not $reported -or -not (Test-SnapShackleProcessPath -ProcessId $owner -Path $reported)) {
            return ('The program on port ' + $port + ' reported a path that is not the program holding the port, so the key was not sent.')
        }
        return $null
    } catch {
        return ('The program at ' + $u.Authority + ' did not identify itself as Fairlead, so the key was not sent.')
    } finally { if ($null -ne $resp) { try { $resp.Close() } catch {} } }
}

# FleetPort's Start-FleetService, found next to this app or under Projects. Tests set SnapShackleFairleadStarter
# to { param($Port) -> @{ State; Message } } so they never start a real Fairlead.
function Find-SnapShackleFleetPortModule {
    $found = New-Object System.Collections.Generic.List[string]
    $app = Split-Path -Parent $PSScriptRoot
    foreach ($start in @($app, (Split-Path -Parent $app))) {
        $dir = $start
        for ($i = 0; $i -lt 3 -and $dir; $i++) {
            $found.Add((Join-Path $dir 'edge-ops\tools\fleet-port\FleetPort.psm1'))
            $dir = Split-Path -Parent $dir
        }
    }
    $profile = [Environment]::GetFolderPath('UserProfile')
    if (-not $profile) { $profile = [Environment]::GetEnvironmentVariable('USERPROFILE') }
    if ($profile) { $found.Add((Join-Path $profile 'Projects\edge-ops\tools\fleet-port\FleetPort.psm1')) }
    foreach ($p in $found) { if ($p -and [IO.File]::Exists($p)) { return $p } }
    return ''
}
function Invoke-SnapShackleFleetServiceStart([int]$Port) {
    $module = Find-SnapShackleFleetPortModule
    if (-not $module) {
        return @{ State = 'unavailable'; Message = 'Fairlead is not running, and Start-FleetService was not found (edge-ops tools\fleet-port\FleetPort.psm1 next to SnapShackle or in Projects). The key was not sent.' }
    }
    try {
        Import-Module -Name $module -ErrorAction Stop
        $caller = Split-Path -Parent $PSScriptRoot
        $r = Start-FleetService -Name fairlead -Port $Port -WaitSeconds 40 -CallerRoot $caller
        $state = [string]$r.State
        $message = [string]$r.Message
        if ($state -ne 'running' -and -not $message) { $message = 'Fairlead could not be started. The key was not sent.' }
        return @{ State = $state; Message = $message }
    } catch {
        return @{ State = 'unavailable'; Message = 'Fairlead could not be started. The key was not sent.' }
    }
}
function Start-SnapShackleFairlead([int]$Port) {
    try {
        if ($script:SnapShackleFairleadStarter) { return (& $script:SnapShackleFairleadStarter $Port) }
        return (Invoke-SnapShackleFleetServiceStart -Port $Port)
    } catch {
        return @{ State = 'unavailable'; Message = 'Fairlead could not be started. The key was not sent.' }
    }
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
    # Start first, so a new PC can mint the local token, then prove it is Fairlead, then read the key.
    if (-not (Test-SnapShackleRouterOpen $base)) {
        $started = Start-SnapShackleFairlead -Port ([Uri]$base).Port
        if ([string]$started.State -ne 'running') {
            $msg = [string]$started.Message
            if (-not $msg) { $msg = 'Fairlead is not running, and it could not be started. The key was not sent.' }
            throw $msg
        }
    }
    $why = Test-SnapShackleFairleadIdentity -BaseUrl $base
    if ($why) { throw $why }
    $key = Resolve-SnapShackleRouterKey
    if (-not $key.key) { throw $script:SnapShackleMissingKeyMessage }
    $payload = ConvertTo-Json -InputObject ([ordered]@{ model = $Model; messages = $Messages; max_tokens = $MaxTokens; temperature = 0.2; stream = $false }) -Depth 12 -Compress
    $request = [Net.HttpWebRequest]::Create($base + '/v1/chat/completions')
    $request.Method = 'POST'; $request.Proxy = $null; $request.AllowAutoRedirect = $false
    $request.Timeout = $TimeoutMs; $request.ReadWriteTimeout = $TimeoutMs
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
        if ($null -eq $failed) { throw 'The router did not answer.' }
        $code = [int]$failed.StatusCode; $failed.Close()
        if ($code -ge 300 -and $code -lt 400) { throw 'The router sent a redirect, so the screenshot was not sent on.' }
        if ($code -eq 401 -or $code -eq 403) { throw 'The router refused the key. Open Fairlead and install a new key for SnapShackle.' }
        throw ('The router answered with an error (' + $code + ').')
    }
    if ([int]$response.StatusCode -ge 300 -and [int]$response.StatusCode -lt 400) {
        $response.Close()
        throw 'The router sent a redirect, so the screenshot was not sent on.'
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
