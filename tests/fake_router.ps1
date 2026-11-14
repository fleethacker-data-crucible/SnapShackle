<#
  A stand-in for the Fleet router (Fairlead) used by tests/ai_router_test.ps1. Listens on 127.0.0.1:<Port> with its own
  socket (so this process owns the port), appends one JSON line per request to <Log> (method, path, authorization,
  privacy header, the X-Fairlead-Label header, whether an image was sent, and the system prompt), answers
  GET /__fleethacker/id as fairlead, and answers /v1/chat/completions with canned text. -Mode refuse answers 401 on
  the chat route. -IdTool, -IdPid and -IdPath override the identity answer (0 and '' mean this process and this script).
  Never reaches the network.
#>
param([int]$Port, [string]$Log, [string]$Mode = 'ok', [string]$IdTool = 'fairlead', [int]$IdPid = 0, [string]$IdPath = '')
$ErrorActionPreference = 'Stop'
if ($IdPid -le 0) { $IdPid = $PID }
if (-not $IdPath) { $IdPath = $PSCommandPath }
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
$listener.Start()

function Read-Request([Net.Sockets.NetworkStream]$Stream) {
    $ms = New-Object IO.MemoryStream
    $buf = New-Object byte[] 8192
    $headerEnd = -1
    while ($headerEnd -lt 0 -and $ms.Length -lt 1048576) {
        $n = $Stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
        $ascii = [Text.Encoding]::ASCII.GetString($ms.ToArray())
        $headerEnd = $ascii.IndexOf("`r`n`r`n")
    }
    if ($headerEnd -lt 0) { return '' }
    $all = [Text.Encoding]::UTF8.GetString($ms.ToArray())
    $header = $all.Substring(0, $headerEnd)
    $need = 0
    if ($header -match '(?im)^Content-Length:\s*(\d+)') { $need = [int]$Matches[1] }
    if ($need -gt 1048576) { $need = 1048576 }
    while (($all.Length - ($headerEnd + 4)) -lt $need -and $ms.Length -lt 1048576) {
        $n = $Stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
        $all = [Text.Encoding]::UTF8.GetString($ms.ToArray())
    }
    return $all
}
function Send-Json([Net.Sockets.NetworkStream]$Stream, [int]$Status, [string]$Reason, [string]$Text) {
    $body = [Text.Encoding]::UTF8.GetBytes($Text)
    $head = 'HTTP/1.1 ' + $Status + ' ' + $Reason + "`r`n" +
        "Content-Type: application/json`r`n" +
        'Content-Length: ' + $body.Length + "`r`n" +
        "Connection: close`r`n" +
        "X-Fairlead-Route: smart`r`n" +
        "X-Fairlead-Target: fake/vision-1`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($hb, 0, $hb.Length)
    if ($body.Length -gt 0) { $Stream.Write($body, 0, $body.Length) }
    $Stream.Flush()
}
function Get-Header([string]$Header, [string]$Name) {
    $m = [regex]::Match($Header, '(?im)^' + [regex]::Escape($Name) + ':\s*(.*)$')
    if ($m.Success) { return $m.Groups[1].Value.Trim() }
    return ''
}

while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        $stream.ReadTimeout = 5000
        $raw = Read-Request $stream
        if (-not $raw -or $raw -notmatch '^(GET|POST|PUT|DELETE|HEAD) ') { continue }
        $splitAt = $raw.IndexOf("`r`n`r`n")
        $header = $raw; $bodyText = ''
        if ($splitAt -ge 0) { $header = $raw.Substring(0, $splitAt); $bodyText = $raw.Substring($splitAt + 4) }
        $requestLine = ($header -split "`r`n", 2)[0]
        $parts = $requestLine.Split(' ')
        $method = $(if ($parts.Length -gt 0) { $parts[0] } else { '' })
        $path = '/'
        if ($parts.Length -gt 1) { $path = ($parts[1] -split '\?', 2)[0] }
        $system = ''; $hasImage = $false
        try {
            $body = $bodyText | ConvertFrom-Json
            $system = [string]$body.messages[0].content
            foreach ($part in @($body.messages[1].content)) { if ($part.type -eq 'image_url' -and ([string]$part.image_url.url).StartsWith('data:image/png;base64,')) { $hasImage = $true } }
        } catch {}
        $line = [ordered]@{ method = $method; path = $path; authorization = (Get-Header $header 'Authorization')
            privacy = (Get-Header $header 'X-Fairlead-Privacy'); label = (Get-Header $header 'X-Fairlead-Label'); hasImage = $hasImage; system = $system.Substring(0, [Math]::Min(60, $system.Length)) }
        [IO.File]::AppendAllText($Log, (ConvertTo-Json -InputObject $line -Compress) + [Environment]::NewLine)
        if ($path -eq '/__fleethacker/id') {
            $id = ConvertTo-Json -InputObject ([ordered]@{ tool = $IdTool; version = 'test'; pid = $IdPid; path = $IdPath }) -Compress
            Send-Json $stream 200 'OK' $id
            continue
        }
        if ($path -ne '/v1/chat/completions') { Send-Json $stream 404 'Not Found' '{"error":"not here"}'; continue }
        if ($Mode -eq 'refuse') { Send-Json $stream 401 'Unauthorized' '{"error":"bad key"}'; continue }
        if ($system -like '*alt text*') { $content = 'A dialog titled Quarterly report with a Save button.' }
        else {
            $content = 'Here you go: [{"kind":"redact","x":0.1,"y":0.2,"w":0.3,"h":0.1,"label":"email address"},{"kind":"arrow","x":0.5,"y":0.5,"w":0.2,"h":0.2,"label":"look here"},{"kind":"explode","x":0,"y":0,"w":1,"h":1,"label":"bad kind"},{"kind":"box","x":0.9,"y":0.9,"w":0.9,"h":0.9,"label":"too big, gets clamped"},{"kind":"box","x":"nope","y":0,"w":0.1,"h":0.1,"label":"bad number"}] done'
        }
        $answer = ConvertTo-Json -InputObject ([ordered]@{ choices = @([ordered]@{ message = [ordered]@{ role = 'assistant'; content = $content } }) }) -Depth 6 -Compress
        Send-Json $stream 200 'OK' $answer
    } catch {} finally { try { $client.Close() } catch {} }
}
