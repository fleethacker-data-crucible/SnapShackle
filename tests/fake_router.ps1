<#
  A stand-in for the Fleet router (Fairlead) used by tests/ai_router_test.ps1. Listens on 127.0.0.1:<Port> with a
  TcpListener, so this process owns the socket (HttpListener would belong to HTTP.sys). Appends one JSON line per
  request to <Log> and answers /v1/chat/completions with canned text. -Mode refuse answers 401. -IdMode changes
  GET /__fleethacker/id: ok, wrong-tool, wrong-pid, wrong-path, no-path. The id answer carries no check of the key.
  Never reaches the network.
#>
param([int]$Port, [string]$Log, [string]$Mode = 'ok', [string]$IdMode = 'ok')
$ErrorActionPreference = 'Stop'
$listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback, $Port)
$listener.Start()

function Find-HeaderEnd([System.Collections.Generic.List[byte]]$Bytes) {
    for ($i = 0; $i -le $Bytes.Count - 4; $i++) {
        if ($Bytes[$i] -eq 13 -and $Bytes[$i + 1] -eq 10 -and $Bytes[$i + 2] -eq 13 -and $Bytes[$i + 3] -eq 10) { return $i }
    }
    return -1
}

function Read-Request($Stream) {
    $data = New-Object System.Collections.Generic.List[byte]
    $buf = New-Object byte[] 8192
    $headerLen = -1
    while ($headerLen -lt 0 -and $data.Count -lt 1048576) {
        $n = $Stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        for ($i = 0; $i -lt $n; $i++) { $data.Add($buf[$i]) }
        $headerLen = Find-HeaderEnd $data
    }
    if ($headerLen -lt 0) { return $null }
    $headerText = [Text.Encoding]::ASCII.GetString($data.ToArray(), 0, $headerLen)
    $contentLength = 0
    foreach ($line in ($headerText -split "`r`n")) {
        if ($line -match '^(?i)Content-Length:\s*(\d+)\s*$') { $contentLength = [int]$Matches[1] }
    }
    if ($contentLength -gt 1048576) { return $null }
    $need = $headerLen + 4 + $contentLength
    while ($data.Count -lt $need) {
        $n = $Stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        for ($i = 0; $i -lt $n; $i++) { $data.Add($buf[$i]) }
    }
    $body = ''
    if ($contentLength -gt 0 -and $data.Count -ge $need) {
        $body = [Text.Encoding]::UTF8.GetString($data.GetRange($headerLen + 4, $contentLength).ToArray())
    }
    $lines = $headerText -split "`r`n"
    $parts = $lines[0].Split(' ')
    $path = $parts[1]
    $query = $path.IndexOf('?')
    if ($query -ge 0) { $path = $path.Substring(0, $query) }
    $headers = @{}
    foreach ($line in ($lines | Select-Object -Skip 1)) {
        $colon = $line.IndexOf(':')
        if ($colon -gt 0) { $headers[$line.Substring(0, $colon).Trim().ToLowerInvariant()] = $line.Substring($colon + 1).Trim() }
    }
    return @{ method = $parts[0]; path = $path; headers = $headers; body = $body }
}

function Send-Json($Stream, [int]$Status, [string]$Reason, [string]$Json) {
    $payload = [Text.Encoding]::UTF8.GetBytes($Json)
    $head = [Text.Encoding]::ASCII.GetBytes(("HTTP/1.1 {0} {1}`r`nContent-Type: application/json`r`nContent-Length: {2}`r`nConnection: close`r`nX-Fairlead-Route: smart`r`nX-Fairlead-Target: fake/vision-1`r`n`r`n" -f $Status, $Reason, $payload.Length))
    $Stream.Write($head, 0, $head.Length)
    if ($payload.Length -gt 0) { $Stream.Write($payload, 0, $payload.Length) }
    $Stream.Flush()
}

while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $client.ReceiveTimeout = 5000
        $client.SendTimeout = 5000
        $stream = $client.GetStream()
        $request = Read-Request $stream
        if ($null -eq $request) { continue }
        $system = ''
        $hasImage = $false
        try {
            $parsed = $request.body | ConvertFrom-Json
            $system = [string]$parsed.messages[0].content
            foreach ($part in @($parsed.messages[1].content)) {
                if ($part.type -eq 'image_url' -and ([string]$part.image_url.url).StartsWith('data:image/png;base64,')) { $hasImage = $true }
            }
        } catch {}
        $authorization = [string]$request.headers['authorization']
        $line = [ordered]@{
            method = $request.method; path = $request.path; authorization = $authorization
            privacy = [string]$request.headers['x-fairlead-privacy']; label = [string]$request.headers['x-fairlead-label']
            hasImage = $hasImage; system = $system.Substring(0, [Math]::Min(60, $system.Length))
        }
        [IO.File]::AppendAllText($Log, (ConvertTo-Json -InputObject $line -Compress) + [Environment]::NewLine)
        if ($request.path -eq '/__fleethacker/id') {
            $idPid = $PID
            $idPath = $PSCommandPath
            $idTool = 'fairlead'
            if ($IdMode -eq 'wrong-tool') { $idTool = 'other' }
            elseif ($IdMode -eq 'wrong-pid') { $idPid = 0 }
            elseif ($IdMode -eq 'wrong-path') { $idPath = 'C:\not-fairlead\other.ps1' }
            $id = [ordered]@{ tool = $idTool; version = 'test'; pid = $idPid }
            if ($IdMode -ne 'no-path') { $id.path = $idPath }
            Send-Json $stream 200 'OK' (ConvertTo-Json -InputObject $id -Compress)
            continue
        }
        if ($request.path -ne '/v1/chat/completions') { Send-Json $stream 404 'Not Found' '{"error":"not here"}'; continue }
        if ($Mode -eq 'refuse') { Send-Json $stream 401 'Unauthorized' '{"error":"bad key"}'; continue }
        if ($system -like '*alt text*') { $content = 'A dialog titled Quarterly report with a Save button.' }
        else {
            $content = 'Here you go: [{"kind":"redact","x":0.1,"y":0.2,"w":0.3,"h":0.1,"label":"email address"},{"kind":"arrow","x":0.5,"y":0.5,"w":0.2,"h":0.2,"label":"look here"},{"kind":"explode","x":0,"y":0,"w":1,"h":1,"label":"bad kind"},{"kind":"box","x":0.9,"y":0.9,"w":0.9,"h":0.9,"label":"too big, gets clamped"},{"kind":"box","x":"nope","y":0,"w":0.1,"h":0.1,"label":"bad number"}] done'
        }
        $answer = ConvertTo-Json -InputObject ([ordered]@{ choices = @([ordered]@{ message = [ordered]@{ role = 'assistant'; content = $content } }) }) -Depth 6 -Compress
        Send-Json $stream 200 'OK' $answer
    } catch {} finally { $client.Close() }
}
