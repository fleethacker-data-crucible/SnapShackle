param([int]$Port=8765,[switch]$NoBrowser)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$library=Join-Path $root 'captures';[void][IO.Directory]::CreateDirectory($library)
$token=[guid]::NewGuid().ToString('N')
$listener=[Net.HttpListener]::new();$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
function Reply($c,[byte[]]$bytes,[string]$type='application/json',[int]$status=200){$c.Response.StatusCode=$status;$c.Response.ContentType=$type;$c.Response.Headers.Add('Cache-Control','no-store');$c.Response.Headers.Add('X-Content-Type-Options','nosniff');$c.Response.ContentLength64=$bytes.Length;$c.Response.OutputStream.Write($bytes,0,$bytes.Length);$c.Response.Close()}
function Json($c,$o,[int]$status=200){Reply $c ([Text.Encoding]::UTF8.GetBytes(($o|ConvertTo-Json -Depth 8 -Compress))) 'application/json' $status}
function Capture([Drawing.Rectangle]$rect){if($rect.Width -le 0 -or $rect.Height -le 0 -or [long]$rect.Width*$rect.Height -gt 120000000){throw 'Invalid capture rectangle'};$b=[Drawing.Bitmap]::new($rect.Width,$rect.Height);$g=[Drawing.Graphics]::FromImage($b);try{$g.CopyFromScreen($rect.Left,$rect.Top,0,0,$b.Size);$m=[IO.MemoryStream]::new();try{$b.Save($m,[Drawing.Imaging.ImageFormat]::Png);return $m.ToArray()}finally{$m.Dispose()}}finally{$g.Dispose();$b.Dispose()}}
function Body($c){$m=[IO.MemoryStream]::new();try{$c.Request.InputStream.CopyTo($m);if($m.Length -gt 30000000){throw 'Request too large'};return $m.ToArray()}finally{$m.Dispose()}}
$base="http://localhost:$Port/"
if(!$NoBrowser){Start-Process ($base+'?token='+$token)}
Write-Host "SnipHero at $base (Ctrl+C to stop)" -ForegroundColor Red
try{while($listener.IsListening){$c=$listener.GetContext();try{
$remote=$c.Request.RemoteEndPoint.Address;if(![Net.IPAddress]::IsLoopback($remote)){Json $c @{error='Loopback only'} 403;continue}
$p=$c.Request.Url.AbsolutePath;$method=$c.Request.HttpMethod
if($p -eq '/' -and $method -eq 'GET'){$html=[IO.File]::ReadAllText((Join-Path $root 'index.html'));$html=$html.Replace('__SESSION_TOKEN__',$token);Reply $c ([Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8';continue}
if($c.Request.Headers['X-SnipHero-Token'] -ne $token){Json $c @{error='Unauthorized session'} 403;continue}
if($p -eq '/api/screens' -and $method -eq 'GET'){$s=@([Windows.Forms.Screen]::AllScreens|ForEach-Object {@{name=$_.DeviceName;primary=$_.Primary;left=$_.Bounds.Left;top=$_.Bounds.Top;width=$_.Bounds.Width;height=$_.Bounds.Height}});Json $c @{screens=$s};continue}
if($p -eq '/api/capture' -and $method -eq 'GET'){$q=$c.Request.QueryString;$rect=[Windows.Forms.SystemInformation]::VirtualScreen;if($q['screen'] -match '^\d+$'){$i=[int]$q['screen'];$screens=@([Windows.Forms.Screen]::AllScreens);if($i -ge $screens.Count){throw 'Unknown display'};$rect=$screens[$i].Bounds};if($q['x'] -match '^-?\d+$' -and $q['y'] -match '^-?\d+$' -and $q['w'] -match '^\d+$' -and $q['h'] -match '^\d+$'){$rect=[Drawing.Rectangle]::new([int]$q['x'],[int]$q['y'],[int]$q['w'],[int]$q['h'])};Reply $c (Capture $rect) 'image/png';continue}
if($p -eq '/api/library' -and $method -eq 'GET'){$items=@(Get-ChildItem $library -Filter '*.png' -File|Sort-Object LastWriteTime -Descending|Select-Object -First 150|ForEach-Object {@{name=$_.Name;bytes=$_.Length;modified=$_.LastWriteTime.ToString('o')}});Json $c @{items=$items};continue}
if($p -eq '/api/library' -and $method -eq 'POST'){$bytes=Body $c;if($bytes.Length -lt 8 -or $bytes[0] -ne 137 -or $bytes[1] -ne 80 -or $bytes[2] -ne 78 -or $bytes[3] -ne 71){throw 'PNG required'};$name='SnipHero-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)+'.png';[IO.File]::WriteAllBytes((Join-Path $library $name),$bytes);Json $c @{name=$name};continue}
if($p -match '^/api/library/([a-zA-Z0-9_.-]+\.png)$' -and $method -eq 'GET'){$name=$Matches[1];$f=Join-Path $library $name;if(!(Test-Path -LiteralPath $f)){Json $c @{error='Not found'} 404;continue};Reply $c ([IO.File]::ReadAllBytes($f)) 'image/png';continue}
Json $c @{error='Not found'} 404
}catch{Write-Warning $_;try{if($c.Response.OutputStream.CanWrite){Json $c @{error=$_.Exception.Message} 500}}catch{}}}}
finally{$listener.Stop();$listener.Close()}