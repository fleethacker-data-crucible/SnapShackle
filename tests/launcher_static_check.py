"""Cross-platform source assertions for the Windows launcher/port integration."""
from pathlib import Path
import re
p=Path(__file__).resolve().parents[1]
launcher=(p/'Launch-SnapShackle.bat').read_text(encoding='utf-8')
host=(p/'Start-SnapShackle.ps1').read_text(encoding='utf-8')
module=(p/'modules/LocalHttp.ps1').read_text(encoding='utf-8')
js=(p/'assets/studio.js').read_text(encoding='utf-8')
assert 'powershell.exe' in launcher.lower()
assert '-NoProfile' in launcher and '-STA' in launcher
assert '-ExecutionPolicy Bypass' in launcher
assert '%~dp0Start-SnapShackle.ps1' in launcher and '%*' in launcher
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
# Forwarding stub for shortcuts made before the rename: it must start the new launcher, never the
# old Start-CutterMk.ps1 (which would dot-source the new modules and fail), and ship in the release zip.
stub=(p/'CutterMk.bat').read_text(encoding='utf-8')
stub_lines=[l for l in stub.splitlines() if l.strip()]
assert len(stub_lines)<=3, 'CutterMk.bat must stay a tiny forwarding stub'
assert 'call "%~dp0Launch-SnapShackle.bat" %*' in stub, 'CutterMk.bat must forward to Launch-SnapShackle.bat with all arguments'
assert 'Start-CutterMk.ps1' not in stub and 'powershell' not in stub.lower()
release=(p/'.github/workflows/release.yml').read_text(encoding='utf-8')
assert "'CutterMk.bat'" in release and "'Launch-SnapShackle.bat'" in release, 'release zip must ship the launcher and the CutterMk.bat stub'
# Lifecycle options reach the host from both launchers: --stay / --replace (or -Stay / -Replace).
dev=(p/'dev/Launch-LocalDev.bat').read_text(encoding='utf-8')
assert '%*' in dev and '-Replace' in dev, 'dev launcher must stop a running SnapShackle first'
assert '--stay' in launcher and '--replace' in launcher
assert '[switch]$Stay' in host and '[switch]$Replace' in host and 'ValueFromRemainingArguments' in host
assert 'PositionalBinding=$false' in host, '--stay must not bind to -Port'
assert "Read-Host 'Stop it and start fresh? [Y/n]'" in host
assert 'Get-SnapShackleProcesses' in host and 'Stop-SnapShackleProcesses' in host
assert 'still running' in host and 'Not starting another copy.' in host and 'exit 1' in host
assert 'WebRequest]::Create' in host and '/api/health' in host and 'BrowserMessage' in host
assert "const api=(path,options={})=>fetch(path," in js and "showSessionEnded('lost')" in js and 'reloadSession' in js
print('PASS: CutterMk.bat forwarding stub ships and forwards to Launch-SnapShackle.bat')
print('PASS: process-only launcher, atomic loopback port fallback, dynamic browser URL, no HTTP.sys URL reservations, --stay/--replace passthrough')