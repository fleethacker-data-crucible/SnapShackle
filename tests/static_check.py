"""Development-only static checks; not a substitute for Windows runtime verification."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
required=['Launch-SnapShackle.bat','Start-SnapShackle.ps1','modules/LocalHttp.ps1','modules/Native.ps1','modules/Ocr.ps1','modules/Tray.ps1','modules/Library.ps1','modules/Migration.ps1','modules/Lifecycle.ps1','Stop-SnapShackle.ps1','index.html','assets/editor.js','assets/studio.js','assets/gif.js','assets/stitch.js','assets/redact.js','assets/styles.css','README.md','tests/windows_capture_perf.ps1','assets/icons.js','assets/theme.js']
for path in required:
 p=ROOT/path
 assert p.is_file() and p.stat().st_size>200,path
host=(ROOT/'Start-SnapShackle.ps1').read_text(encoding='utf-8')
ui=(ROOT/'index.html').read_text(encoding='utf-8')
studio=(ROOT/'assets/studio.js').read_text(encoding='utf-8')
for route in ['/api/health','/api/screens','/api/windows','/api/capture','/api/region','/api/library','/api/ocr']:
 assert route in host,route
for name in ['capture','region','windowCapture','record','gif','librarySave','librarySearch','projectSave','projectOpen','scrollAdd','scrollAuto','scrollFinish','ocr','canvas']:
 assert f'id="{name}"' in ui,name
for control in ['getDisplayMedia','MediaRecorder','SnapShackleGif.encode','SnapShackleStitch.stitch','refreshLibrary','saveLibrary']:
 assert control in studio,control
assert 'Get-SnapShackleRegion' in (ROOT/'modules/Native.ps1').read_text(encoding='utf-8')
assert 'Windows.Media.Ocr' in (ROOT/'modules/Ocr.ps1').read_text(encoding='utf-8')
print('PASS: source structure and route/feature wiring (static only)')

# Performance feature wiring: never recapture screen after the region overlay.
native=(ROOT/'modules/Native.ps1').read_text(encoding='utf-8')
region=native.split('function Get-SnapShackleRegion {',1)[1]
assert region.count('CopyFromScreen(')==1, 'Region capture must acquire the desktop exactly once'
assert 'Copy-SnapShackleBitmapArea $background $region' in region
assert 'return $Original.Clone($Area,$Original.PixelFormat)' in native
assert '/api/thumb/' in host and 'Get-SnapShackleThumbnail' in host
assert "Server-Timing" in host and "SetBody($Bytes)" in host
assert "BufferedStream" in (ROOT/'modules/LocalHttp.ps1').read_text(encoding='utf-8')
assert "await loadImage(blob,'Desktop capture')" in studio
assert 'portableProject()' in studio and 'IntersectionObserver' in studio
print('PASS: capture latency architecture, timing hooks and thumbnail cache')

# Lifecycle: the studio tab owns the server, tray icon and hotkeys.
life=(ROOT/'modules/Lifecycle.ps1').read_text(encoding='utf-8')
tray=(ROOT/'modules/Tray.ps1').read_text(encoding='utf-8')
assert "/api/heartbeat" in host and "/api/session/stop" in host and "'end-session'" in host
assert host.index("'/api/heartbeat'") < host.index("$request.Headers['X-SnapShackle-Token'] -ne $sessionToken"), 'beacon route must be reachable without the header'
assert "$beat.Session" in host and "QueryString['session']" not in host, 'beacon token only in the body'
assert "Get-SnapShackleStopReason" in host and "$shared.Busy" in host and "Write-SnapShackleRuntimeFile" in host and "Remove-SnapShackleRuntimeFile $runtimeFile" in host
assert "Listener.Server.Poll(" in host, 'idle loop must wake up to check presence'
assert "SNAPSHACKLE_AUTO_STOP" in host and "Test-SnapShackleAutoStopEnv" in life
assert "$script:SnapShackleHeartbeatTimeout = 20" in life and "$script:SnapShackleLeavingGrace = 5" in life
assert "token" not in life.split('function Write-SnapShackleRuntimeFile',1)[1].split('}',1)[0].lower()
assert "'Exit'" in tray and "UnregisterHotKey" in tray and "$tray.Dispose()" in tray
assert "id=\"endSession\"" in ui and "id=\"stayInTray\"" in ui
assert "navigator.sendBeacon" in studio and "'/api/heartbeat'" in studio and "pagehide" in studio and "setInterval(()=>heartbeat(),5000)" in studio
assert (ROOT/'Stop-SnapShackle.ps1').is_file() and 'Stop-SnapShackleProcesses' in (ROOT/'Stop-SnapShackle.ps1').read_text(encoding='utf-8')
print('PASS: lifecycle wiring (heartbeat, beacon auth, End session, tray Exit, runtime file, Stop-SnapShackle.ps1)')
# Brand emblems are for the README only: the app must not load or require them (they are not in release zips).
for name in ('emblem-dark.png','emblem-light.png'):
 assert (ROOT/'assets/brand'/name).is_file(), name
for source,text in (('index.html',ui),('assets/studio.js',studio),('assets/styles.css',(ROOT/'assets/styles.css').read_text(encoding='utf-8')),('Start-SnapShackle.ps1',host)):
 assert 'assets/brand' not in text and 'emblem-' not in text, source+' must not reference the README emblems'
print('PASS: README emblems present in assets/brand and not wired into the app')
