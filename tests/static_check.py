"""Development-only static checks; not a substitute for Windows runtime verification."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
required=['Launch-SnapShackle.bat','Start-SnapShackle.ps1','modules/LocalHttp.ps1','modules/Native.ps1','modules/Ocr.ps1','modules/Tray.ps1','modules/Library.ps1','docs/CAPTURE-FORMAT.md','tests/capture_format_test.ps1','modules/Share.ps1','modules/Migration.ps1','modules/Lifecycle.ps1','Stop-SnapShackle.ps1','index.html','assets/editor.js','assets/studio.js','assets/audio.js','assets/webcam.js','assets/gif.js','assets/stitch.js','assets/redact.js','assets/styles.css','README.md','tests/windows_capture_perf.ps1','assets/icons.js','assets/theme.js']
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
# The original emblems in assets/brand are for the README only (they are not in release zips). The app
# shows its own copies from assets/ui (backdrop made transparent, scaled), which ship with assets/.
for name in ('emblem-dark.png','emblem-light.png'):
 assert (ROOT/'assets/brand'/name).is_file(), name
for name in ('emblem-dark.png','emblem-light.png','icon-256.png','favicon.ico'):
 assert (ROOT/'assets/ui'/name).is_file(), name
assert (ROOT/'assets/vendor/fleet/fleet.css').is_file()
for source,text in (('index.html',ui),('assets/studio.js',studio),('assets/styles.css',(ROOT/'assets/styles.css').read_text(encoding='utf-8')),('Start-SnapShackle.ps1',host)):
 assert 'assets/brand' not in text, source+' must not reference the README emblems'
assert '/assets/ui/emblem-dark.png' in ui and '/assets/ui/emblem-light.png' in ui and '/assets/vendor/fleet/fleet.css' in ui and 'data-app="snapshackle"' in ui
print('PASS: README emblems stay in assets/brand; the app uses its copies in assets/ui and the Fleet tokens')

# Optional video sound: off unless chosen, and GIF / stills / scrolling capture stay silent.
audio=(ROOT/'assets/audio.js').read_text(encoding='utf-8')
assert 'src="/assets/audio.js"' in ui
assert 'id="recordAudio"' in ui and 'id="recordMic"' in ui and 'id="recordMicRefresh"' in ui and 'id="recordAudioLive"' in ui
assert 'for="recordAudio"' in ui and 'for="recordMic"' in ui
assert 'aria-describedby="recordAudioHelp"' in ui and 'aria-live="polite"' in ui and 'role="status"' in ui
assert 'SnapShackleAudio.prepareRecording' in studio
assert 'shareScreen({video:{frameRate:settings.recordFps},audio:false})' in studio
gif_fn=studio.split("$('#gif').onclick",1)[1].split("$('#scrollAuto').onclick",1)[0]
assert 'getSharedScreen()' in gif_fn and 'prepareRecording' not in gif_fn and 'getUserMedia' not in gif_fn
browser_fn=studio.split("$('#browserCapture').onclick",1)[1].split('const toolNames',1)[0]
assert 'getSharedScreen()' in browser_fn and 'prepareRecording' not in browser_fn
scroll_fn=studio.split("$('#scrollAuto').onclick",1)[1].split("$('#scrollAdd').onclick",1)[0]
assert 'getSharedScreen()' in scroll_fn and 'prepareRecording' not in scroll_fn
library=(ROOT/'modules/Library.ps1').read_text(encoding='utf-8')
assert "recordAudio = 'off'" in library and 'recordMicId' in library
assert 'http://' not in audio and 'https://' not in audio and '.mil' not in audio
assert 'normalizeMode' in audio and 'prepareRecording' in audio
share=(ROOT/'modules/Share.ps1').read_text(encoding='utf-8')
assert "/api/share" in host and 'Invoke-SnapShackleShare' in host and 'Get-SafeCapturePath ([string]$share.capture)' in host, 'share route must validate the capture name'
assert 'id="shareDestination"' in ui and 'for="shareDestination"' in ui and 'id="shareFolders"' in ui and 'for="shareFolders"' in ui
assert 'Invoke-WebRequest' not in share and 'WebClient' not in share and 'Invoke-RestMethod' not in share and 'http://' not in share and 'https://' not in share, 'sharing must stay local'
assert '$false)' in share and 'File]::Copy' in share, 'folder copies must never overwrite'
print('PASS: share destinations stay local, validate the capture name and never overwrite')
assert 'src="/assets/webcam.js"' in ui and ui.index('/assets/webcam.js') < ui.index('/assets/studio.js'), 'webcam.js must load before studio.js'
assert 'id="recordCamera"' in ui and 'value="off" selected' in ui.split('id="recordCamera"')[1].split('</select>')[0] and 'id="recordCameraRefresh"' in ui
assert 'for="recordCamera"' in ui and 'aria-describedby="recordCameraHelp"' in ui
assert "recordCamera = 'off'" in library and 'recordCameraCorner' in library
assert 'webcam' in host.split('/assets/(')[1].split(')')[0], 'webcam.js must be served with the other studio scripts'
assert 'http://' not in (ROOT/'assets/webcam.js').read_text(encoding='utf-8') and 'fetch(' not in (ROOT/'assets/webcam.js').read_text(encoding='utf-8')
assert 'SnapShackleWebcam.createCompositor' in studio and "getUserMedia({video" not in studio.replace("getUserMedia(c)", ''), 'camera is requested only through SnapShackleWebcam'
print('PASS: camera picture-in-picture is off by default, local only, and wired through SnapShackleWebcam')
assert 'id="recordFormat"' in ui and 'for="recordFormat"' in ui and 'value="mp4"' in ui and 'aria-describedby="recordFormatHelp"' in ui
assert 'pickRecorderType' in studio and 'downloadName(pick.ext)' in studio and "recordFormat='webm'" not in studio
assert "recordFormat = 'webm'" in library and "'webm', 'mp4'" in library
print('PASS: video format (WebM or MP4) is a saved setting, chosen through pickRecorderType')
print('PASS: optional record sound is wired, off by default, and kept out of GIF and still capture')

# A restarted server reuses the port. The old tab must say the session is gone, and the tray must
# focus only the window for this start (port + start id), never a stale "SnapShackle Studio" tab.
assert "(editor|studio|gif|stitch|redact|icons|theme|audio|webcam)" in host, 'audio.js must be served with the other studio scripts'
assert "__STUDIO_TITLE__" in host and "__STUDIO_TITLE__" in ui and "__STUDIO_TITLE__" in studio
assert "studioStartId" in host and "StudioTitle" in host and "$script:studioTitle" in host
assert "SnapShackle Studio " in host
assert "HttpWebRequest" not in host and "WebRequest]::Create" in host
assert "/api/health" in host and "BrowserMessage" in host and "BrowserClosed" in host
assert "did not answer /api/health" in host
assert "X-SnapShackle-Token" in host
stop_at = host.index("Stop-SnapShackleProcesses $searchDirs")
still_at = host.index("Get-SnapShackleProcesses $searchDirs", stop_at)
warn_at = host.index("still running", stop_at)
assert still_at > stop_at and warn_at > still_at and "exit 1" in host[warn_at:warn_at+400]
assert "Not starting another copy." in host
assert "ActivateByTitle('SnapShackle Studio')" not in tray
assert "StudioTitle" in tray and "ActivateByTitle($title)" in tray
assert "TaskbarCreated" in tray and "ExplorerRestarted" in tray and "RegisterWindowMessage" in tray
assert "string.IsNullOrEmpty(contains)" in native
assert "reloadSession" in studio and "showSessionEnded('lost')" in studio
assert "Invalid session" in studio and "location.reload" in studio
beat = studio.split("function heartbeat", 1)[1].split("function leavingSignal", 1)[0]
assert "showSessionEnded('lost')" in beat and ".catch(()=>{})" not in beat.split("if(leaving)", 1)[0]
poll = studio.split("async function pollEvents", 1)[1].split("setInterval(pollEvents", 1)[0]
assert poll.count("showSessionEnded('lost')") >= 2
assert "SnapShackle Studio (stopped)" in studio
print('PASS: session loss is visible, the tray matches only this start, health is checked, Explorer restart restores the icon')
