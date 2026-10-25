"""Cross-platform source assertions for the Windows launcher/port integration."""
from pathlib import Path
import re
p=Path(__file__).resolve().parents[1]
launcher=(p/'Lasso.bat').read_text(encoding='utf-8')
host=(p/'Start-Lasso.ps1').read_text(encoding='utf-8')
module=(p/'modules/LocalHttp.ps1').read_text(encoding='utf-8')
js=(p/'assets/studio.js').read_text(encoding='utf-8')
assert 'powershell.exe' in launcher.lower()
assert '-NoProfile' in launcher and '-STA' in launcher
assert '-ExecutionPolicy Bypass' in launcher
assert '%~dp0Start-Lasso.ps1' in launcher and '%*' in launcher
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
# Lifecycle options reach the host from both launchers: --stay / --replace (or -Stay / -Replace).
dev=(p/'dev/Launch-LocalDev.bat').read_text(encoding='utf-8')
assert '%*' in dev and '-Replace' in dev, 'dev launcher must stop a running Lasso first'
assert '--stay' in launcher and '--replace' in launcher
assert '[switch]$Stay' in host and '[switch]$Replace' in host and 'ValueFromRemainingArguments' in host
assert 'PositionalBinding=$false' in host, '--stay must not bind to -Port'
assert "Read-Host 'Stop it and start fresh? [Y/n]'" in host
assert 'Get-LassoProcesses' in host and 'Stop-LassoProcesses' in host
print('PASS: process-only launcher, atomic loopback port fallback, dynamic browser URL, no HTTP.sys URL reservations, --stay/--replace passthrough')