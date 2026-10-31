"""Share controls in Chromium against a mocked local API: the destination list, the settings text box and the share request.
Usage: python tests/share_ui_test.py
"""
import json
import os
import re
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
MOCK = r"""() => {
  const json=(x,status=200)=>new Response(JSON.stringify(x),{status,headers:{'Content-Type':'application/json'}});
  window.__shares=[];
  window.__saved={namePrefix:'SnapShackle',autoLibrary:false,recordFps:6,stayInTray:false,theme:'dark',recordAudio:'off',recordMicId:'',shareFolders:[{name:'Team drive',path:'\\\\server\\share\\shots'}]};
  window.fetch=async (path,options={}) => {
    const url=String(path);
    if(url.startsWith('/api/health'))return json({capture:true,ocr:false,version:'test'});
    if(url.startsWith('/api/screens'))return json({screens:[]});
    if(url.startsWith('/api/windows'))return json({windows:[]});
    if(url.startsWith('/api/settings')){if(options.method==='PUT'){window.__saved=JSON.parse(options.body);return json({...window.__saved,saved:true})}return json({...window.__saved,saved:true})}
    if(url.startsWith('/api/heartbeat'))return json({autoStop:true,timeoutSeconds:20});
    if(url.startsWith('/api/events'))return json({events:[],latest:0});
    if(url==='/api/share'&&options.method==='POST'){const body=JSON.parse(options.body);window.__shares.push(body);return body.destination==='Gone'?json({error:'The folder was not found or is offline'},400):json({kind:body.kind,message:body.kind==='folder'?'Copied to '+body.destination:'File copied to the clipboard. Paste it into the message or chat.'})}
    if(url==='/api/share')return json({destinations:[{kind:'folder',name:'Team drive',path:'x',available:true},{kind:'folder',name:'Gone',path:'y',available:false},{kind:'clipboard',name:'clipboard',path:'',available:true},{kind:'reveal',name:'reveal',path:'',available:true},{kind:'open',name:'open',path:'',available:true}]});
    if(url.startsWith('/api/library')&&options.method==='POST')return json({name:'SnapShackle-Mock.png'});
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
    page.wait_for_function('document.querySelectorAll("#shareDestination option").length===5', timeout=6000)
    options = page.evaluate('[...document.querySelectorAll("#shareDestination option")].map(o => [o.value, o.textContent, o.disabled])')
    assert options[0] == ['folder:Team drive', 'Team drive (folder)', False], options
    assert options[1][2] is True and 'offline' in options[1][1], options
    assert [o[0] for o in options[2:]] == ['clipboard', 'reveal', 'open'], options
    # Saved folders show as "Name = path" lines and go back to the host in the same shape.
    page.locator('#tabWorkflows').click()
    assert page.locator('#shareFolders').input_value() == 'Team drive = \\\\server\\share\\shots'
    page.locator('#shareFolders').fill('Team drive = \\\\server\\share\\shots\nLocal = D:\\Shots\nno equals sign here\n = C:\\NoName')
    page.locator('#settingsSave').click()
    page.wait_for_function('window.__saved.shareFolders.length===2', timeout=6000)
    assert page.evaluate('window.__saved.shareFolders') == [{'name': 'Team drive', 'path': '\\\\server\\share\\shots'}, {'name': 'Local', 'path': 'D:\\Shots'}]
    # Sharing without a selected capture asks for one; with one, it posts the chosen destination.
    page.locator('#tabLibrary').click()
    page.locator('#shareSelected').click()
    assert 'Choose a saved capture first' in page.locator('#status').inner_text()
    page.locator('#shareDestination').select_option('clipboard')
    page.locator('#shareCurrent').click()
    page.wait_for_function('window.__shares.length===1', timeout=6000)
    sent = page.evaluate('window.__shares[0]')
    assert sent == {'capture': 'SnapShackle-Mock.png', 'kind': 'clipboard', 'destination': ''}, sent
    assert 'File copied to the clipboard' in page.locator('#status').inner_text()
    page.wait_for_function('document.querySelectorAll("#shareDestination option").length===5')
    page.locator('#shareDestination').select_option('folder:Team drive')
    page.locator('#shareSelected').click()
    page.wait_for_function('window.__shares.length===2', timeout=6000)
    assert page.evaluate('window.__shares[1]') == {'capture': 'SnapShackle-Mock.png', 'kind': 'folder', 'destination': 'Team drive'}
    assert not errors, errors
    browser.close()
print('PASS: share destinations list, folder settings round-trip, and the share request')
