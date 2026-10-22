"""Cross-platform source assertions for the Windows launcher/port integration."""
from pathlib import Path
import re
p=Path(__file__).resolve().parents[1]
launcher=(p/'SnipHero.bat').read_text()
host=(p/'Start-SnipHero.ps1').read_text()
module=(p/'modules/LocalHttp.ps1').read_text()
js=(p/'assets/studio.js').read_text()
assert 'powershell.exe' in launcher.lower()
assert '-NoProfile' in launcher and '-STA' in launcher
assert '-ExecutionPolicy Bypass' in launcher
assert '%~dp0Start-SnipHero.ps1' in launcher and '%*' in launcher
assert re.search(r'\bDiagnostics\b',host)
assert '$server.Port' in host and '$server.Accept()' in host
assert 'http://127.0.0.1:$Port/' in host
assert 'HttpListener' not in re.sub(r'(?m)^\s*#.*$', '', host)
assert 'new HttpListener(' not in module and 'HttpListener]' not in module
assert 'TcpListener(IPAddress.Loopback,port)' in module
assert 'TcpListener(IPAddress.Loopback,0)' in module
assert 'SocketError.AddressAlreadyInUse' in module
assert 'Content-Length' in module and 'MaxBody=30000000' in module
assert 'Invalid Host header' in module and 'Transfer-Encoding' in module
assert "const api=(path,options={})=>fetch(path," in js
assert 'http://localhost:' not in host
assert 'http://localhost:' not in js
assert (p/'tests/windows_port_smoke.ps1').is_file()
print('PASS: process-only launcher, atomic loopback port fallback, dynamic browser URL, no HTTP.sys URL reservations')