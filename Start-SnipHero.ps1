param([int]$Port=8765,[switch]$NoBrowser)
$ErrorActionPreference='Stop'
if(-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core'){throw 'SnipHero desktop capture requires Windows.'}
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'modules/Native.ps1')
$library=Join-Path $env:LOCALAPPDATA 'SnipHero\Captures'
if(!$env:LOCALAPPDATA){$library=Join-Path $root 'captures'}
[void][IO.Directory]::CreateDirectory($library)
$token=[guid]::NewGuid().ToString('N');$listener=[Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/");$listener.Start()
function Reply($c,[byte[]]$bytes,[string]$type='application/json',[int]$status=200){$c.Response.StatusCode=$status;$c.Response.ContentType=$type;$c.Response.Headers.Add('Cache-Control','no-store');$c.Response.Headers.Add('X-Content-Type-Options','nosniff');$c.Response.Headers.Add('Content-Security-Policy',"default-src 'self' blob: data:; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' blob: data:; media-src 'self' blob:; object-src 'none'; frame-ancestors 'none'");$c.Response.ContentLength64=$bytes.Length;$c.Response.OutputStream.Write($bytes,0,$bytes.Length);$c.Response.Close()}
function Json($c,$o,[int]$status=200){Reply $c ([Text.Encoding]::UTF8.GetBytes(($o|ConvertTo-Json -Depth 12 -Compress))) 'application/json' $status}
function Body($c,[int]$max=35000000){if($c.Request.ContentLength64 -gt $max){throw 'Payload exceeds size limit'};$m=[IO.MemoryStream]::new();try{$buffer=New-Object byte[] 8192;while(($n=$c.Request.InputStream.Read($buffer,0,$buffer.Length)) -gt 0){$m.Write($buffer,0,$n);if($m.Length -gt $max){throw 'Payload exceeds size limit'}};return ,$m.ToArray()}finally{$m.Dispose()}}
function PngValid([byte[]]$b){return ($b.Length -gt 24 -and $b[0] -eq 137 -and $b[1] -eq 80 -and $b[2] -eq 78 -and $b[3] -eq 71 -and $b[4] -eq 13)}
function MetadataPath($name){Join-Path $library ($name+'.meta.json')}
function ListCaptures($q){$search=([string]$q).ToLowerInvariant();@((Get-ChildItem -LiteralPath $library -Filter '*.png' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1000 | ForEach-Object { $meta=@{};$mp=MetadataPath $_.Name;if(Test-Path -LiteralPath $mp){try{$meta=Get-Content -LiteralPath $mp -Raw|ConvertFrom-Json}catch{}};[pscustomobject]@{name=$_.Name;bytes=$_.Length;modified=$_.LastWriteTime.ToString('o');tags=@($meta.tags);note=[string]$meta.note} } | Where-Object { !$search -or ($_.name+' '+$_.note+' '+($_.tags -join ' ')).ToLowerInvariant().Contains($search) } | Select-Object -First 250))}
function SafeName($n){if($n -notmatch '^SnipHero-[a-zA-Z0-9_.-]+\.png$'){throw 'Invalid capture name'};Join-Path $library $n}
$base="http://localhost:$Port/"
if(!$NoBrowser){Start-Process ($base+'?session='+$token)}
Write-Host "SnipHero Studio: $base (Ctrl+C to stop)" -ForegroundColor Red
try{while($listener.IsListening){$c=$listener.GetContext();try{
 if(![Net.IPAddress]::IsLoopback($c.Request.RemoteEndPoint.Address)){Json $c @{error='Local requests only'} 403;continue}
 $p=$c.Request.Url.AbsolutePath;$method=$c.Request.HttpMethod
 if($p -eq '/' -and $method -eq 'GET'){$html=[IO.File]::ReadAllText((Join-Path $root 'index.html')).Replace('__SESSION_TOKEN__',$token);Reply $c ([Text.Encoding]::UTF8.GetBytes($html)) 'text/html; charset=utf-8';continue}
 if($p -match '^/assets/(editor|studio|gif)\.js$' -and $method -eq 'GET'){$asset=$Matches[1];$script=[IO.File]::ReadAllText((Join-Path $root ('assets/'+$asset+'.js'))).Replace('__SESSION_TOKEN__',$token);Reply $c ([Text.Encoding]::UTF8.GetBytes($script)) 'application/javascript; charset=utf-8';continue}
 if($c.Request.Headers['X-SnipHero-Token'] -ne $token){Json $c @{error='Invalid session'} 403;continue}
 if($p -eq '/api/screens' -and $method -eq 'GET'){Json $c @{screens=@([Windows.Forms.Screen]::AllScreens|ForEach-Object {@{name=$_.DeviceName;primary=$_.Primary;left=$_.Bounds.Left;top=$_.Bounds.Top;width=$_.Bounds.Width;height=$_.Bounds.Height}})};continue}
 if($p -eq '/api/windows' -and $method -eq 'GET'){Json $c @{windows=@(Get-SnipWindows)};continue}
 if($p -eq '/api/capture' -and $method -eq 'GET'){$q=$c.Request.QueryString;$r=[Windows.Forms.SystemInformation]::VirtualScreen
  if($q['screen'] -match '^\d+$'){$screens=@([Windows.Forms.Screen]::AllScreens);$i=[int]$q['screen'];if($i -ge $screens.Count){throw 'Invalid screen'};$r=$screens[$i].Bounds}
  if($q['window'] -match '^\d+$'){$w=[SnipHero.Native]::Window([long]$q['window']);$r=[Drawing.Rectangle]::new($w.X,$w.Y,$w.Width,$w.Height)}
  if($q['x'] -match '^-?\d+$' -and $q['y'] -match '^-?\d+$' -and $q['w'] -match '^\d+$' -and $q['h'] -match '^\d+$'){$r=[Drawing.Rectangle]::new([int]$q['x'],[int]$q['y'],[int]$q['w'],[int]$q['h'])}
  Reply $c (Get-SnipRect $r) 'image/png';continue}
 if($p -eq '/api/region' -and $method -eq 'GET'){$b=Get-SnipRegion;if(!$b){Json $c @{cancelled=$true} 409}else{Reply $c $b 'image/png'};continue}
 if($p -eq '/api/library' -and $method -eq 'GET'){Json $c @{items=@(ListCaptures $c.Request.QueryString['q'])};continue}
 if($p -eq '/api/library' -and $method -eq 'POST'){$bytes=Body $c;if(!(PngValid $bytes)){throw 'PNG required'};$name='SnipHero-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)+'.png';[IO.File]::WriteAllBytes((Join-Path $library $name),$bytes);Json $c @{name=$name};continue}
 if($p -match '^/api/library/(SnipHero-[a-zA-Z0-9_.-]+\.png)$'){$name=$Matches[1];$f=SafeName $name
  if($method -eq 'GET'){if(!(Test-Path -LiteralPath $f)){Json $c @{error='Missing capture'} 404}else{Reply $c ([IO.File]::ReadAllBytes($f)) 'image/png'};continue}
  if($method -eq 'DELETE'){Remove-Item -LiteralPath $f -ErrorAction Stop;$mp=MetadataPath $name;Remove-Item -LiteralPath $mp -ErrorAction SilentlyContinue;Json $c @{deleted=$true};continue}
  if($method -eq 'PUT'){$data=[Text.Encoding]::UTF8.GetString((Body $c 65536))|ConvertFrom-Json;$tags=@($data.tags|Select-Object -First 20|ForEach-Object{([string]$_).Substring(0,[Math]::Min(40,([string]$_).Length))});$note=([string]$data.note);if($note.Length -gt 2000){$note=$note.Substring(0,2000)};@{tags=$tags;note=$note}|ConvertTo-Json|Set-Content -LiteralPath (MetadataPath $name) -Encoding UTF8;Json $c @{updated=$true};continue}}
 Json $c @{error='Route not found'} 404
}catch{Write-Warning $_;try{if($c.Response.OutputStream.CanWrite){Json $c @{error=$_.Exception.Message} 500}}catch{}}}}
finally{$listener.Stop();$listener.Close()}