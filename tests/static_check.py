"""Development-only static checks; not a substitute for Windows runtime verification."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
required=['SnipHero.bat','Start-SnipHero.ps1','modules/LocalHttp.ps1','modules/Native.ps1','modules/Ocr.ps1','index.html','assets/editor.js','assets/studio.js','assets/gif.js','assets/stitch.js','assets/styles.css','README.md']
for path in required:
 p=ROOT/path
 assert p.is_file() and p.stat().st_size>200,path
host=(ROOT/'Start-SnipHero.ps1').read_text()
ui=(ROOT/'index.html').read_text()
studio=(ROOT/'assets/studio.js').read_text()
for route in ['/api/health','/api/screens','/api/windows','/api/capture','/api/region','/api/library','/api/ocr']:
 assert route in host,route
for name in ['capture','region','windowCapture','record','gif','librarySave','librarySearch','projectSave','projectOpen','scrollAdd','scrollAuto','scrollFinish','ocr','canvas']:
 assert f'id="{name}"' in ui,name
for control in ['getDisplayMedia','MediaRecorder','SnipGif.encode','SnipStitch.stitch','refreshLibrary','saveLibrary']:
 assert control in studio,control
assert 'Get-SnipRegion' in (ROOT/'modules/Native.ps1').read_text()
assert 'Windows.Media.Ocr' in (ROOT/'modules/Ocr.ps1').read_text()
print('PASS: source structure and route/feature wiring (static only)')