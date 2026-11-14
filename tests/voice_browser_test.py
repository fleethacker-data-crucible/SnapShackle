"""Voice notes in a real Chromium, using its built-in fake microphone (no real microphone, nothing uploaded).

Record on a selected annotation, stop, see the note on the layer, undo and redo it, save and reload an editable project
(a tampered note in the file is dropped), release the microphone, and show a plain message when the microphone is refused.
Usage: python tests/voice_browser_test.py   (Playwright; SNAPSHACKLE_CHROMIUM may point at a browser)
"""
import json
import os
from pathlib import Path
from playwright.sync_api import sync_playwright
from studio_page import read_studio_document

ROOT = Path(__file__).resolve().parents[1]
ARGS = ['--no-sandbox', '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream']
MOCK = r"""() => {
  const json=(x,status=200)=>new Response(JSON.stringify(x),{status,headers:{'Content-Type':'application/json'}});
  window.__saved={namePrefix:'SnapShackle',autoLibrary:false,recordFps:6,stayInTray:false,theme:'dark',recordAudio:'off',recordMicId:''};
  window.fetch=async (path,options={}) => {
    const url=String(path);
    if(url.startsWith('data:'))return fetch0(url);
    if(url.startsWith('/api/health'))return json({capture:true,ocr:false,version:'test'});
    if(url.startsWith('/api/screens'))return json({screens:[]});
    if(url.startsWith('/api/windows'))return json({windows:[]});
    if(url.startsWith('/api/settings'))return json({...window.__saved,saved:true});
    if(url.startsWith('/api/heartbeat'))return json({autoStop:true,timeoutSeconds:20});
    if(url.startsWith('/api/events'))return json({events:[],latest:0});
    if(url.startsWith('/api/library'))return json({items:[]});
    return json({error:'not found'},404);
  };
  navigator.sendBeacon=()=>true;
  // Remember every microphone track so the test can check they are released.
  window.__tracks=[];
  const real=navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
  navigator.mediaDevices.getUserMedia=async c=>{const s=await real(c);s.getTracks().forEach(t=>window.__tracks.push(t));return s};
}"""

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, executable_path=os.environ.get('SNAPSHACKLE_CHROMIUM') or None, args=ARGS)
    context = browser.new_context(viewport={'width': 1440, 'height': 950}, accept_downloads=True)
    context.grant_permissions(['microphone'], origin='http://localhost')
    page = context.new_page()
    errors = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    html, scripts, styles = read_studio_document(ROOT)
    # A secure origin is needed for getUserMedia; serve the page from http://localhost.
    context.route('http://localhost/studio', lambda route: route.fulfill(status=200, content_type='text/html', body=html))
    page.goto('http://localhost/studio')
    for sheet in styles:
        page.add_style_tag(path=str(ROOT / sheet))
    page.evaluate(MOCK.replace('fetch0(url)', 'new Response("")'))
    for name in scripts:
        page.add_script_tag(path=str(ROOT / 'assets' / f'{name}.js'))

    page.locator('#tabWorkflows').click()
    assert 'Select an annotation' in page.locator('#voiceStatus').inner_text()
    assert page.locator('#voiceRecord').is_disabled(), 'Record must wait for a selected annotation'

    # Draw a rectangle and select its layer.
    page.locator('[data-tool="rectangle"]').click()
    b = page.locator('#canvas').bounding_box()
    page.mouse.move(b['x'] + 30, b['y'] + 35); page.mouse.down(); page.mouse.move(b['x'] + 210, b['y'] + 175, steps=4); page.mouse.up()
    page.locator('#tabLayers').click()
    page.locator('#layers button').first.click()
    page.locator('#tabWorkflows').click()
    assert page.locator('#voiceRecord').is_enabled()
    assert page.evaluate('window.__tracks.length') == 0, 'the microphone must not open before Record is pressed'

    # Record about a second, stop, and the note sits on the layer.
    page.locator('#voiceRecord').click()
    page.wait_for_function('document.querySelector("#voiceRecord").textContent==="Stop recording"', timeout=8000)
    assert 'microphone is on' in page.locator('#voiceStatus').inner_text()
    page.wait_for_timeout(1200)
    page.locator('#voiceRecord').click()
    page.wait_for_function('document.querySelector("#layers button").textContent.includes("(voice")', timeout=8000)
    assert all(s == 'ended' for s in page.evaluate('window.__tracks.map(t=>t.readyState)')), 'the microphone was not released'
    assert page.locator('#voicePlay').is_enabled() and page.locator('#voiceSave').is_enabled() and page.locator('#voiceDelete').is_enabled()
    assert page.locator('#voiceRecord').inner_text() == 'Record'

    # Undo removes the note with the history step, redo brings it back.
    page.locator('#undo').click()
    page.wait_for_function('!document.querySelector("#layers button")?.textContent.includes("(voice")', timeout=4000)
    page.locator('#redo').click()
    page.wait_for_function('document.querySelector("#layers button").textContent.includes("(voice")', timeout=4000)

    # The audio file can be saved.
    page.locator('#tabLayers').click(); page.locator('#layers button').first.click(); page.locator('#tabWorkflows').click()
    with page.expect_download(timeout=8000) as audio_download:
        page.locator('#voiceSave').click()
    assert audio_download.value.suggested_filename.endswith('.webm') or audio_download.value.suggested_filename.endswith('.ogg')

    # An editable project carries the note; a tampered note in a loaded file is dropped.
    page.locator('#tabLayers').click()
    with page.expect_download(timeout=8000) as project_download:
        page.locator('#projectSave').click()
    project = json.loads(Path(project_download.value.path()).read_text(encoding='utf-8'))
    note = project['objects'][0]['voice']
    assert note['mime'].startswith('audio/') and note['ms'] >= 500 and len(note['data']) > 100, note['mime']
    project['objects'].append({'type': 'rectangle', 'x': 5, 'y': 5, 'x2': 50, 'y2': 50, 'voice': {'mime': 'text/html', 'ms': 1000, 'data': 'AAAA'}})
    page.locator('#projectFile').set_input_files(files=[{'name': 'tampered.json', 'mimeType': 'application/json', 'buffer': json.dumps(project).encode('utf-8')}])
    page.wait_for_function('document.querySelectorAll("#layers button").length===2', timeout=8000)
    labels = page.evaluate('[...document.querySelectorAll("#layers button")].map(b=>b.textContent)')
    assert sum('(voice' in l for l in labels) == 1, labels

    # A refused microphone gives a plain message and records nothing.
    page.evaluate("() => { navigator.mediaDevices.getUserMedia = async () => { const e = new Error('no'); e.name = 'NotAllowedError'; throw e } }")
    page.locator('#layers button').first.click()
    page.locator('#tabWorkflows').click()
    page.locator('#voiceRecord').click()
    page.wait_for_function('document.querySelector("#status").textContent.includes("not allowed")', timeout=6000)
    assert page.locator('#voiceRecord').inner_text() == 'Record'
    assert not errors, errors
    browser.close()
print('PASS: voice notes record on a selected annotation, ride Undo and projects, drop tampered notes, release the microphone and cope with refusal')
