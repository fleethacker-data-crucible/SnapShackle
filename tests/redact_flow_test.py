"""Smart-redaction flow in Chromium with a mocked OCR: the status line must never let "nothing found" pass for
"checked and clean" when OCR read nothing, and found items turn into solid boxes. Usage: python tests/redact_flow_test.py"""
import os
import re
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
MOCK = r"""() => {
  const json=(x,status=200)=>new Response(JSON.stringify(x),{status,headers:{'Content-Type':'application/json'}});
  window.__ocr={text:'',lines:[]};
  window.fetch=async (path,options={}) => {
    const url=String(path);
    if(url.startsWith('/api/health'))return json({capture:true,ocr:true,version:'test'});
    if(url.startsWith('/api/screens'))return json({screens:[]});
    if(url.startsWith('/api/windows'))return json({windows:[]});
    if(url.startsWith('/api/settings'))return json({saved:false,namePrefix:'SnapShackle',recordFps:6});
    if(url.startsWith('/api/heartbeat'))return json({autoStop:true,timeoutSeconds:20});
    if(url.startsWith('/api/events'))return json({events:[],latest:0});
    if(url.startsWith('/api/library'))return json({items:[]});
    if(url.startsWith('/api/ocr'))return json({engine:'Windows.Media.Ocr',...window.__ocr});
    return json({error:'not found'},404);
  };
  navigator.sendBeacon=()=>true;
}"""
LINE = {'text': 'Mail jane.doe@example.com', 'words': [{'text': 'Mail', 'x': 20, 'y': 20, 'w': 40, 'h': 18}, {'text': 'jane.doe@example.com', 'x': 66, 'y': 20, 'w': 200, 'h': 18}]}
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
    page.locator('#tabWorkflows').click()
    # 1. OCR reads nothing: say so in the status line and next to the button.
    page.locator('#redactFind').click()
    page.wait_for_function('document.querySelector("#status").textContent.includes("read no text")', timeout=6000)
    assert 'nothing could be checked' in page.locator('#redactFindings').inner_text()
    assert page.locator('#redactApply').is_hidden()
    # 2. OCR read text but nothing sensitive: not "clean", "check it yourself".
    page.evaluate('window.__ocr={text:"hello",lines:[{text:"hello world",words:[{text:"hello",x:1,y:1,w:30,h:10},{text:"world",x:40,y:1,w:30,h:10}]}]}')
    page.locator('#redactFind').click()
    page.wait_for_function('document.querySelector("#status").textContent.includes("1 line read")', timeout=6000)
    assert 'Check the image yourself' in page.locator('#status').inner_text()
    # 3. A finding becomes a solid redaction layer; Undo removes it in one step.
    page.evaluate('(l)=>{window.__ocr={text:l.text,lines:[l]}}', LINE)
    page.locator('#redactFind').click()
    page.wait_for_function('document.querySelectorAll("#redactFindings input:checked").length===1', timeout=6000)
    assert 'Found 1 item' in page.locator('#status').inner_text()
    page.locator('#redactApply').click()
    page.locator('#tabLayers').click()
    assert page.locator('#layers button').count() == 1, 'redaction layer not added'
    page.locator('#undo').click()
    page.wait_for_timeout(100)
    assert page.locator('#layers button').count() == 0, 'undo did not remove the redaction'
    assert not errors, errors
    browser.close()
print('PASS: redaction flow says when OCR read nothing, never calls an unread image clean, and adds undoable boxes')
