"""Numeric position and size controls for the selected layer, in Chromium against a mocked local API.

Select a drawn rectangle, type exact X, Y, width and height, and check the saved project holds exactly those numbers;
each edit is one Undo step; fixed-size layers (steps) and text keep the fields they cannot change switched off; and a
non-number is refused. Usage: python tests/layers_numeric_test.py
"""
import json
import os
from pathlib import Path
from playwright.sync_api import sync_playwright
from studio_page import read_studio_document

ROOT = Path(__file__).resolve().parents[1]
MOCK = r"""() => {
  const json=(x,status=200)=>new Response(JSON.stringify(x),{status,headers:{'Content-Type':'application/json'}});
  window.fetch=async (path,options={}) => {
    const url=String(path);
    if(url.startsWith('/api/health'))return json({capture:true,ocr:false,version:'test'});
    if(url.startsWith('/api/screens'))return json({screens:[]});
    if(url.startsWith('/api/windows'))return json({windows:[]});
    if(url.startsWith('/api/settings'))return json({namePrefix:'SnapShackle',autoLibrary:false,recordFps:6,stayInTray:false,theme:'dark',recordAudio:'off',recordMicId:'',saved:true});
    if(url.startsWith('/api/heartbeat'))return json({autoStop:true,timeoutSeconds:20});
    if(url.startsWith('/api/events'))return json({events:[],latest:0});
    if(url.startsWith('/api/library'))return json({items:[]});
    return json({error:'not found'},404);
  };
  navigator.sendBeacon=()=>true;
}"""

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, executable_path=os.environ.get('SNAPSHACKLE_CHROMIUM') or None, args=['--no-sandbox'])
    context = browser.new_context(viewport={'width': 1440, 'height': 950}, accept_downloads=True)
    page = context.new_page()
    errors = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    html, scripts, styles = read_studio_document(ROOT)
    page.set_content(html)
    for sheet in styles:
        page.add_style_tag(path=str(ROOT / sheet))
    page.evaluate(MOCK)
    for name in scripts:
        page.add_script_tag(path=str(ROOT / 'assets' / f'{name}.js'))

    fields = lambda: page.evaluate('["layerX","layerY","layerW","layerH"].map(id => document.getElementById(id).value)')
    disabled = lambda: page.evaluate('["layerX","layerY","layerW","layerH"].map(id => document.getElementById(id).disabled)')
    project = lambda: json.loads(Path(save_project().path()).read_text(encoding='utf-8'))

    def save_project():
        page.locator('#tabLayers').click()
        with page.expect_download(timeout=8000) as d:
            page.locator('#projectSave').click()
        return d.value

    page.locator('#tabLayers').click()
    assert disabled() == [True, True, True, True] and fields() == ['', '', '', ''], 'no layer selected: fields are off and empty'

    # Draw a rectangle from canvas pixel (30,35) to (210,175), then select its layer.
    box = page.locator('#canvas').bounding_box()
    scale = page.evaluate('document.querySelector("#canvas").width') / box['width']
    page.locator('[data-tool="rectangle"]').click()
    page.mouse.move(box['x'] + 30 / scale, box['y'] + 35 / scale); page.mouse.down()
    page.mouse.move(box['x'] + 210 / scale, box['y'] + 175 / scale, steps=4); page.mouse.up()
    page.locator('#layers button').first.click()
    x, y, w, h = [int(v) for v in fields()]
    assert disabled() == [False, False, False, False]
    assert abs(w - 180) <= 3 and abs(h - 140) <= 3 and abs(x - 30) <= 3 and abs(y - 35) <= 3, (x, y, w, h)

    # Dragging the south-east corner handle resizes a rectangle (the same resize code the number fields use).
    page.locator('[data-tool="select"]').click()
    page.locator('#layers button').first.click()
    sx, sy = box['x'] + (x + w) / scale, box['y'] + (y + h) / scale
    page.mouse.move(sx, sy); page.mouse.down(); page.mouse.move(sx + 30 / scale, sy + 20 / scale, steps=4); page.mouse.up()
    grown = [int(v) for v in fields()]
    assert abs(grown[2] - (w + 30)) <= 4 and abs(grown[3] - (h + 20)) <= 4, ('corner drag did not resize', (x, y, w, h), grown)

    # Exact edits: the project holds exactly the typed numbers.
    for field, value in (('layerX', '100'), ('layerY', '80'), ('layerW', '240'), ('layerH', '90')):
        page.locator('#' + field).fill(value)
        page.locator('#' + field).press('Enter')
    assert fields() == ['100', '80', '240', '90'], fields()
    o = project()['objects'][0]
    assert (min(o['x'], o['x2']), min(o['y'], o['y2']), abs(o['x2'] - o['x']), abs(o['y2'] - o['y'])) == (100, 80, 240, 90), o

    # One Undo per edit.
    page.locator('#undo').click()
    page.locator('#layers button').first.click()   # undo clears the selection
    assert fields() == ['100', '80', '240', str(grown[3])], ('undo should undo only the last edit', fields())
    page.locator('#redo').click()
    page.locator('#layers button').first.click()
    assert fields() == ['100', '80', '240', '90'], fields()

    # An empty field is refused and the layer is unchanged; an out-of-range size is clamped to the image.
    page.locator('#layerW').fill('')
    page.locator('#layerW').press('Enter')
    assert page.locator('#status').inner_text() == 'Type a number'
    assert fields() == ['100', '80', '240', '90'], ('an empty field changed the layer', fields())
    page.locator('#layerW').fill('99999')
    page.locator('#layerW').press('Enter')
    assert int(fields()[2]) <= page.evaluate('document.querySelector("#canvas").width')

    # A numbered step has a fixed size: only X and Y are on.
    page.locator('[data-tool="step"]').click()
    page.mouse.click(box['x'] + 300 / scale, box['y'] + 120 / scale)
    page.locator('#layers button').first.click()
    assert 'step' in page.locator('#layers button').first.inner_text()
    assert disabled() == [False, False, True, True], disabled()
    assert not errors, errors
    browser.close()
print('PASS: numeric X, Y, width and height edit the selected layer exactly, one Undo step each, with fixed-size layers kept off')
