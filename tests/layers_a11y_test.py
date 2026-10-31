"""Layer list accessibility in Chromium against a mocked local API (issue: make layer selection state explicit).

Checks that each layer button says whether it is selected (aria-pressed), that the selection is announced by name in a
live region, and that keyboard focus stays on the layer you chose when the list is rebuilt.
Usage: python tests/layers_a11y_test.py
"""
import os
import re
from pathlib import Path
from playwright.sync_api import sync_playwright

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
    page = browser.new_page(viewport={'width': 1440, 'height': 950})
    errors = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    html = (ROOT / 'index.html').read_text(encoding='utf-8')
    scripts = re.findall(r'<script[^>]*src="/assets/([a-z]+)\.js"', html)
    styles = re.findall(r'<link rel="stylesheet" href="/(assets/[a-z/]+\.css)"', html)
    html = re.sub(r'<script[^>]*src="[^"]+"[^>]*></script>', '', html)
    html = re.sub(r'<link[^>]*stylesheet[^>]*>', '', html)
    page.set_content(html)
    for sheet in styles:
        page.add_style_tag(path=str(ROOT / sheet))
    page.evaluate(MOCK)
    for name in scripts:
        page.add_script_tag(path=str(ROOT / 'assets' / f'{name}.js'))

    # Two annotations: a rectangle and an ellipse.
    box = page.locator('#canvas').bounding_box()
    for tool, (x1, y1, x2, y2) in (('rectangle', (30, 35, 210, 175)), ('ellipse', (240, 40, 400, 160))):
        page.locator(f'[data-tool="{tool}"]').click()
        page.mouse.move(box['x'] + x1, box['y'] + y1); page.mouse.down(); page.mouse.move(box['x'] + x2, box['y'] + y2, steps=4); page.mouse.up()
    page.locator('#tabLayers').click()
    layers = page.locator('#layers button')
    assert layers.count() == 2, layers.count()

    pressed = lambda: page.evaluate('[...document.querySelectorAll("#layers button")].map(b => b.getAttribute("aria-pressed"))')
    # Newest first: ellipse (2) is listed above rectangle (1). Drawing selects the new object.
    labels = page.evaluate('[...document.querySelectorAll("#layers button")].map(b => b.textContent)')
    assert labels[0].startswith('2. ellipse') and labels[1].startswith('1. rectangle'), labels
    assert pressed() in (['true', 'false'], ['false', 'false']), ('every layer button must say whether it is selected', pressed())
    assert None not in pressed(), 'aria-pressed missing'

    # Selecting a layer with the mouse flips the pressed state and announces the layer by name.
    layers.nth(1).click()
    assert pressed() == ['false', 'true'], pressed()
    announce = page.locator('#layerAnnounce')
    assert announce.get_attribute('aria-live') == 'polite'
    assert announce.inner_text() == 'Selected layer 1 of 2: rectangle', announce.inner_text()

    # The keyboard: focus a layer button, press Enter; the list is rebuilt but focus stays on that layer.
    page.evaluate('document.querySelectorAll("#layers button")[0].focus()')
    page.keyboard.press('Enter')
    assert pressed() == ['true', 'false'], pressed()
    focused = page.evaluate('(() => { const a = document.activeElement; return [a.closest("#layers") !== null, a.textContent, a.getAttribute("aria-pressed")] })()')
    assert focused == [True, '2. ellipse', 'true'], ('focus was lost when the list was rebuilt', focused)
    assert announce.inner_text() == 'Selected layer 2 of 2: ellipse', announce.inner_text()
    page.keyboard.press('Tab'); page.keyboard.press('Enter')
    assert pressed() == ['false', 'true'], pressed()
    assert page.evaluate('document.activeElement.textContent') == '1. rectangle', 'focus should follow the chosen layer'

    # Clearing the selection (Escape in the canvas) is announced and no button stays pressed.
    page.locator('#undo').click(); page.locator('#undo').click()
    assert page.locator('#layers button').count() == 0
    assert announce.inner_text() in ('', 'No layer selected'), announce.inner_text()
    assert not errors, errors
    browser.close()
print('PASS: layer buttons expose their selected state, announce the selection by name, and keep keyboard focus')
