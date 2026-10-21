"""Chromium interactions against a mocked local API (no Windows needed)."""
import base64
import io
import re
from pathlib import Path
from PIL import Image, ImageDraw
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
image = Image.new('RGB', (900, 580), '#f3f5fa')
draw = ImageDraw.Draw(image)
draw.rectangle((50, 45, 400, 300), fill='#38bde1', outline='#1c4c64', width=4)
draw.text((60, 70), 'SNIPHERO TEST IMAGE', fill='#121a28')
stream = io.BytesIO()
image.save(stream, 'PNG')
image_b64 = base64.b64encode(stream.getvalue()).decode()

MOCK = r"""(imageBase64) => {
  const bytes=Uint8Array.from(atob(imageBase64), c=>c.charCodeAt(0));
  window.fetch=async (path,options={}) => {
    const url=String(path);
    const json=(x,status=200)=>new Response(JSON.stringify(x),{status,headers:{'Content-Type':'application/json'}});
    if(url.startsWith('/api/health'))return json({capture:true,ocr:false,version:'test'});
    if(url.startsWith('/api/screens'))return json({screens:[{name:'TEST',primary:true}]});
    if(url.startsWith('/api/windows'))return json({windows:[{Title:'Mock window',Id:123}]});
    if(url.startsWith('/api/capture')||url.startsWith('/api/region'))return new Response(bytes,{status:200,headers:{'Content-Type':'image/png'}});
    if(url.startsWith('/api/library')&&options.method==='POST'){window.__library=bytes;return json({name:'SnipHero-Mock.png'})}
    if(url.startsWith('/api/library/SnipHero-'))return new Response(window.__library||bytes,{status:200,headers:{'Content-Type':'image/png'}});
    if(url.startsWith('/api/library')&&(!options.method||options.method==='GET'))return json({items:window.__library?[{name:'SnipHero-Mock.png',tags:[],note:'',modified:'2026-10-21T00:00:00'}]:[]});
    if(url.startsWith('/api/ocr'))return json({error:'Unavailable'},501);
    return json({error:'not found'},404);
  };
}"""

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, executable_path='/usr/bin/chromium', args=['--no-sandbox'])
    page = browser.new_page(viewport={'width':1440,'height':950}, accept_downloads=True)
    errors = []
    page.on('pageerror', lambda error:errors.append(str(error)))
    html = (ROOT/'index.html').read_text()
    html = re.sub(r'<script[^>]*src="[^"]+"[^>]*></script>', '', html)
    html = re.sub(r'<link[^>]*stylesheet[^>]*>', '', html)
    page.set_content(html)
    page.add_style_tag(path=str(ROOT/'assets/styles.css'))
    page.evaluate(MOCK, image_b64)
    for name in ['editor','gif','stitch','studio']:
        page.add_script_tag(path=str(ROOT/'assets'/f'{name}.js'))

    assert page.locator('#tools button').count()==12, 'Tools failed to initialize'
    page.locator('#capture').click()
    page.wait_for_function('document.querySelector("#canvas").width===900')
    page.locator('[data-tool="rectangle"]').click()
    bounds = page.locator('#canvas').bounding_box()
    page.mouse.move(bounds['x']+30,bounds['y']+35)
    page.mouse.down()
    page.mouse.move(bounds['x']+210,bounds['y']+175,steps=4)
    page.mouse.up()
    assert page.locator('#layers button').count()==1, 'Annotation not created'
    page.locator('#undo').click()
    page.wait_for_timeout(50)
    assert page.locator('#layers button').count()==0, 'Undo failed'
    page.locator('#redo').click()
    page.wait_for_timeout(50)
    assert page.locator('#layers button').count()==1, 'Redo failed'
    page.locator('#tabLayers').click()
    page.locator('#layers button').first.click()
    page.locator('#duplicate').click()
    assert page.locator('#layers button').count()==2, 'Duplicate failed'
    assert page.locator('#projectSave').is_visible()
    with page.expect_download() as download:
        page.locator('#png').click()
    assert download.value.suggested_filename.endswith('.png')
    page.locator('#tabLibrary').click()
    page.locator('#librarySave').click()
    page.wait_for_function('document.querySelectorAll(".capture-card").length>0')
    page.wait_for_function('document.querySelector(".capture-card img").naturalWidth>0')
    assert not errors, 'JS errors: '+repr(errors)
    print('PASS: browser startup, capture, annotations, undo/redo, duplicate, PNG export, loaded library preview')
    page.screenshot(path=str(ROOT/'tests/preview.png'), full_page=True)
    browser.close()