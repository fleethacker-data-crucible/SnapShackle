from pathlib import Path
p=Path(__file__).resolve().parents[1]
required=['Start-SnipHero.ps1','modules/Native.ps1','index.html','assets/editor.js','assets/studio.js','assets/gif.js','README.md']
for path in required:
 f=p/path
 assert f.exists() and f.stat().st_size>300, path
ps=(p/'Start-SnipHero.ps1').read_text()
js=(p/'assets/studio.js').read_text()
html=(p/'index.html').read_text()
for route in ['/api/screens','/api/windows','/api/capture','/api/region','/api/library']:
 assert route in ps, route
for item in ['record','gif','ocr','scrollAdd','scrollFinish','metadataSave','projectSave','windowCapture','region']:
 assert 'id="'+item+'"' in html, item
for key in ['MediaRecorder','SnipGif.encode','getDisplayMedia','refreshLibrary','saveLibrary']:
 assert key in js, key
print('PASS: source files, routes and UI wiring present (static only)')
