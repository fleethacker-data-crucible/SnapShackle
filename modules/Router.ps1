# Optional AI help through the Fleet router (Fairlead): alt text and annotation suggestions for the open image.
# Off until the person turns it on (aiSuggest). The host makes the call, never the browser, so the router key is
# not in the page. The key is read when needed and held only in this process: never in settings, files or logs.
#
# Contract (Fleet relationships, 2026-10-30): one address for every model call, 127.0.0.1:8776 by default;
# SNAPSHACKLE_AI_ENDPOINT_URL (or LLM_URL) overrides it; each app has its own client key; Lazarette holds the key
# and an app reads its item by name. This build accepts only a loopback router address, so a screenshot never
# leaves this computer through SnapShackle itself. Requests carry X-Fairlead-Privacy: local unless the person
# chose aiPrivacy = any.
$script:SnapShackleRouterDefaultUrl = 'http://127.0.0.1:8776'
$script:SnapShackleRouterDefaultItem = 'snapshackle-router-key'
$script:SnapShackleSuggestKinds = @('redact', 'box', 'arrow', 'step', 'text')

# The router address: environment override or the default. Throws unless it is a plain http loopback address.
function Get-SnapShackleRouterUrl {
    $url = [Environment]::GetEnvironmentVariable('SNAPSHACKLE_AI_ENDPOINT_URL')
    if (-not $url) { $url = [Environment]::GetEnvironmentVariable('LLM_URL') }
    if (-not $url) { $url = $script:SnapShackleRouterDefaultUrl }
    $url = $url.Trim().TrimEnd('/')
    if ($url -notmatch '^http://(127\.0\.0\.1|localhost|\[::1\]):\d{2,5}(/[A-Za-z0-9._/-]*)?$') {
        throw 'The router address must be http://127.0.0.1:<port>: SnapShackle only talks to a router on this computer.'
    }
    return $url
}
# The vault item that holds this app's client key, by name. SNAPSHACKLE_LAZARETTE_ITEM_Router overrides the name.
function Get-SnapShackleRouterItemName {
    $name = [Environment]::GetEnvironmentVariable('SNAPSHACKLE_LAZARETTE_ITEM_Router')
    if ($name) { return $name.Trim() }
    return $script:SnapShackleRouterDefaultItem
}
# Finds the client key. Order: SNAPSHACKLE_ROUTER_KEY in the process environment (set by a launcher that unlocked the
# vault), then the Lazarette item when its helpers are already loaded and unlocked in this process, then none (the
# router lets this computer in without a key when it is set that way). Returns @{ key; source; note }.
function Resolve-SnapShackleRouterKey {
    $fromEnv = [Environment]::GetEnvironmentVariable('SNAPSHACKLE_ROUTER_KEY')
    if ($fromEnv) { return @{ key = $fromEnv.Trim(); source = 'env'; note = '' } }
    $reader = $null
    foreach ($candidate in @('Get-LazaretteSecret', 'Get-ArcSecret')) { if (Get-Command $candidate -CommandType Function, Alias -ErrorAction SilentlyContinue) { $reader = $candidate; break } }
    if ($reader) {
        try {
            $secret = & $reader -Service (Get-SnapShackleRouterItemName)
            if ($secret) { return @{ key = ([string]$secret).Trim(); source = 'vault'; note = '' } }
        } catch { return @{ key = ''; source = 'none'; note = 'The vault item was not available (locked, missing or ambiguous).' } }
    }
    return @{ key = ''; source = 'none'; note = '' }
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
    $payload = ConvertTo-Json -InputObject ([ordered]@{ model = $Model; messages = $Messages; max_tokens = $MaxTokens; temperature = 0.2; stream = $false }) -Depth 12 -Compress
    $request = [Net.HttpWebRequest]::Create($base + '/v1/chat/completions')
    $request.Method = 'POST'; $request.Proxy = $null; $request.Timeout = $TimeoutMs; $request.ReadWriteTimeout = $TimeoutMs
    $request.KeepAlive = $false; $request.ServicePoint.Expect100Continue = $false; $request.ContentType = 'application/json'
    $request.UserAgent = 'SnapShackle'
    if ($key.key) { $request.Headers.Add('Authorization', 'Bearer ' + $key.key) }
    if (([string]$Settings.aiPrivacy) -ne 'any') { $request.Headers.Add('X-Fairlead-Privacy', 'local') }
    $request.Headers.Add('X-Fairlead-Label', 'snapshackle')
    $body = [Text.Encoding]::UTF8.GetBytes($payload)
    $request.ContentLength = $body.Length
    try {
        $out = $request.GetRequestStream(); $out.Write($body, 0, $body.Length); $out.Close()
        $response = $request.GetResponse()
    } catch [Net.WebException] {
        $failed = $_.Exception.Response
        if ($null -eq $failed) { throw 'The router did not answer. Start Fairlead (127.0.0.1:8776) or check SNAPSHACKLE_AI_ENDPOINT_URL.' }
        $code = [int]$failed.StatusCode; $failed.Close()
        if ($code -eq 401 -or $code -eq 403) { throw 'The router refused the key. Check the vault item ' + (Get-SnapShackleRouterItemName) + ' (or SNAPSHACKLE_ROUTER_KEY).' }
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
