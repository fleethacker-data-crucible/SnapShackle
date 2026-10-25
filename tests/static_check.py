"""Development-only static checks; not a substitute for Windows runtime verification."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
required=['Lasso.bat','Start-Lasso.ps1','modules/LocalHttp.ps1','modules/Native.ps1','modules/Ocr.ps1','modules/Tray.ps1','modules/Library.ps1','modules/Migration.ps1','index.html','assets/editor.js','assets/studio.js','assets/gif.js','assets/stitch.js','assets/redact.js','assets/styles.css','README.md','tests/windows_capture_perf.ps1']
for path in required:
 p=ROOT/path
 assert p.is_file() and p.stat().st_size>200,path
host=(ROOT/'Start-Lasso.ps1').read_text(encoding='utf-8')
ui=(ROOT/'index.html').read_text(encoding='utf-8')
studio=(ROOT/'assets/studio.js').read_text(encoding='utf-8')
for route in ['/api/health','/api/screens','/api/windows','/api/capture','/api/region','/api/library','/api/ocr']:
 assert route in host,route
for name in ['capture','region','windowCapture','record','gif','librarySave','librarySearch','projectSave','projectOpen','scrollAdd','scrollAuto','scrollFinish','ocr','canvas']:
 assert f'id="{name}"' in ui,name
for control in ['getDisplayMedia','MediaRecorder','LassoGif.encode','LassoStitch.stitch','refreshLibrary','saveLibrary']:
 assert control in studio,control
assert 'Get-LassoRegion' in (ROOT/'modules/Native.ps1').read_text(encoding='utf-8')
assert 'Windows.Media.Ocr' in (ROOT/'modules/Ocr.ps1').read_text(encoding='utf-8')
print('PASS: source structure and route/feature wiring (static only)')

# Performance feature wiring: never recapture screen after the region overlay.
native=(ROOT/'modules/Native.ps1').read_text(encoding='utf-8')
region=native.split('function Get-LassoRegion {',1)[1]
assert region.count('CopyFromScreen(')==1, 'Region capture must acquire the desktop exactly once'
assert 'Copy-LassoBitmapArea $background $region' in region
assert 'return $Original.Clone($Area,$Original.PixelFormat)' in native
assert '/api/thumb/' in host and 'Get-LassoThumbnail' in host
assert "Server-Timing" in host and "SetBody($Bytes)" in host
assert "BufferedStream" in (ROOT/'modules/LocalHttp.ps1').read_text(encoding='utf-8')
assert "await loadImage(blob,'Desktop capture')" in studio
assert 'portableProject()' in studio and 'IntersectionObserver' in studio
print('PASS: capture latency architecture, timing hooks and thumbnail cache')