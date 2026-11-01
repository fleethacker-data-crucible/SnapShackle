# Optional AI help through the Fleet router (Fairlead): alt text and annotation suggestions for the open image.
# Off until the person turns it on (aiSuggest). The host makes the call, never the browser, so the router key is
# not in the page. The key is read when needed and held only in this process: never in settings, files or logs.
#
# Contract: one address for every model call, 127.0.0.1:8776 by default; SNAPSHACKLE_FAIRLEAD_URL changes the port or
# path (loopback only). Each app has its own client key, installed by Fairlead into Windows Credential Manager as the
# generic credential Fairlead/SnapShackle. This build accepts only a loopback router address, so a screenshot never
# leaves this computer through SnapShackle itself. Requests carry X-Fairlead-Privacy: local unless the person chose
# aiPrivacy = any, and X-Fairlead-Label: SnapShackle.
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

# Finds the client key in Windows Credential Manager. Returns @{ key; source; note }; source is 'credential-manager'
# or 'none' (then note says what to do). Never returns an error that contains the key.
function Resolve-SnapShackleRouterKey {
    $key = ''
    try { $key = [string](& $script:SnapShackleCredentialReader (Get-SnapShackleKeyTarget)) } catch { $key = '' }
    $key = $key.Trim()
    if ($key) { return @{ key = $key; source = 'credential-manager'; note = '' } }
    return @{ key = ''; source = 'none'; note = $script:SnapShackleMissingKeyMessage }
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
    if (-not $key.key) { throw $script:SnapShackleMissingKeyMessage }
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
