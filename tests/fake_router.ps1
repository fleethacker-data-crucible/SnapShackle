<#
  A stand-in for the Fleet router (Fairlead) used by tests/ai_router_test.ps1. Listens on 127.0.0.1:<Port>, appends one
  JSON line per request to <Log> (method, path, authorization, privacy header, the X-Fairlead-Label header, whether an image was sent, and the system
  prompt), and answers /v1/chat/completions with canned text. -Mode refuse answers 401. Never reaches the network.
#>
param([int]$Port, [string]$Log, [string]$Mode = 'ok')
$ErrorActionPreference = 'Stop'
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
function Send([Net.HttpListenerContext]$c, [int]$status, [string]$text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $c.Response.StatusCode = $status; $c.Response.ContentType = 'application/json'
    $c.Response.Headers.Add('X-Fairlead-Route', 'smart'); $c.Response.Headers.Add('X-Fairlead-Target', 'fake/vision-1')
    $c.Response.OutputStream.Write($bytes, 0, $bytes.Length); $c.Response.Close()
}
while ($listener.IsListening) {
    $c = $listener.GetContext()
    $reader = [IO.StreamReader]::new($c.Request.InputStream, [Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd(); $reader.Close()
    $system = ''; $hasImage = $false
    try {
        $body = $raw | ConvertFrom-Json
        $system = [string]$body.messages[0].content
        foreach ($part in @($body.messages[1].content)) { if ($part.type -eq 'image_url' -and ([string]$part.image_url.url).StartsWith('data:image/png;base64,')) { $hasImage = $true } }
    } catch {}
    $line = [ordered]@{ method = $c.Request.HttpMethod; path = $c.Request.Url.AbsolutePath; authorization = [string]$c.Request.Headers['Authorization']
        privacy = [string]$c.Request.Headers['X-Fairlead-Privacy']; label = [string]$c.Request.Headers['X-Fairlead-Label']; hasImage = $hasImage; system = $system.Substring(0, [Math]::Min(60, $system.Length)) }
    [IO.File]::AppendAllText($Log, (ConvertTo-Json -InputObject $line -Compress) + [Environment]::NewLine)
    if ($c.Request.Url.AbsolutePath -ne '/v1/chat/completions') { Send $c 404 '{"error":"not here"}'; continue }
    if ($Mode -eq 'refuse') { Send $c 401 '{"error":"bad key"}'; continue }
    if ($system -like '*alt text*') { $content = 'A dialog titled Quarterly report with a Save button.' }
    else {
        $content = 'Here you go: [{"kind":"redact","x":0.1,"y":0.2,"w":0.3,"h":0.1,"label":"email address"},{"kind":"arrow","x":0.5,"y":0.5,"w":0.2,"h":0.2,"label":"look here"},{"kind":"explode","x":0,"y":0,"w":1,"h":1,"label":"bad kind"},{"kind":"box","x":0.9,"y":0.9,"w":0.9,"h":0.9,"label":"too big, gets clamped"},{"kind":"box","x":"nope","y":0,"w":0.1,"h":0.1,"label":"bad number"}] done'
    }
    $answer = ConvertTo-Json -InputObject ([ordered]@{ choices = @([ordered]@{ message = [ordered]@{ role = 'assistant'; content = $content } }) }) -Depth 6 -Compress
    Send $c 200 $answer
}
