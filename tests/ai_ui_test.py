"""AI help in Chromium against a mocked local API: off by default, the settings, alt text and the suggestion list.
The real router call is tested in tests/ai_router_test.ps1; here the host is mocked so the browser never sees a key.
Usage: python tests/ai_ui_test.py
"""
import json
import os
from pathlib import Path
from playwright.sync_api import sync_playwright
from studio_page import read_studio_document

ROOT = Path(__file__).resolve().parents[1]
MOCK = r"""() => {
  const json=(x,status=200)=>new Response(JSON.stringify(x),{status,headers:{'Content-Type':'application/json'}});
  window.__calls=[];
  window.__saved={namePrefix:'SnapShackle',autoLibrary:false,recordFps:6,stayInTray:false,theme:'dark',recordAudio:'off',recordMicId:'',aiSuggest:'off',aiPrivacy:'local'};
  window.fetch=async (path,options={}) => {
    const url=String(path);
    if(url.startsWith('/api/health'))return json({capture:true,ocr:false,version:'test'});
    if(url.startsWith('/api/screens'))return json({screens:[]});
    if(url.startsWith('/api/windows'))return json({windows:[]});
    if(url.startsWith('/api/settings')){if(options.method==='PUT'){window.__saved={...window.__saved,...JSON.parse(options.body)};return json({...window.__saved,saved:true})}return json({...window.__saved,saved:true})}
    if(url.startsWith('/api/heartbeat'))return json({autoStop:true,timeoutSeconds:20});
    if(url.startsWith('/api/events'))return json({events:[],latest:0});
    if(url==='/api/ai/status')return json({enabled:window.__saved.aiSuggest==='on',routerUrl:'http://127.0.0.1:8776',keySource:'credential-manager',privacy:window.__saved.aiPrivacy,problem:''});
    if(url.startsWith('/api/ai/')){window.__calls.push(url);if(window.__saved.aiSuggest!=='on')return json({error:'AI suggestions are off.'},409);
      if(url==='/api/ai/alt-text')return json({text:'A report dialog with a Save button.',route:'smart',target:'fake/vision-1'});
      return json({suggestions:[{kind:'redact',x:0.1,y:0.1,w:0.2,h:0.1,label:'email'},{kind:'arrow',x:0.5,y:0.5,w:0.2,h:0.2,label:'look here'},{kind:'step',x:0.7,y:0.1,w:0.1,h:0.1,label:'first'}],route:'smart',target:'fake/vision-1'})}
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
    html, scripts, styles = read_studio_document(ROOT)
    page.set_content(html)
    for sheet in styles:
        page.add_style_tag(path=str(ROOT / sheet))
    page.evaluate(MOCK)
    for name in scripts:
        page.add_script_tag(path=str(ROOT / 'assets' / f'{name}.js'))
    page.locator('#tabWorkflows').click()
    # Off by default: the status says so and both buttons are disabled; nothing was sent.
    page.wait_for_function('document.querySelector("#aiStatus").textContent.startsWith("Off")', timeout=6000)
    assert page.locator('#aiAltText').is_disabled() and page.locator('#aiSuggestBtn').is_disabled()
    assert page.locator('#aiSuggest').input_value() == 'off' and page.locator('#aiPrivacy').input_value() == 'local'
    assert page.evaluate('window.__calls.length') == 0
    # Turn it on and save: the host gets both choices; the status shows the router and where the key came from, never the key.
    page.locator('#aiSuggest').select_option('on')
    page.locator('#settingsSave').click()
    page.wait_for_function('window.__saved.aiSuggest==="on"', timeout=6000)
    assert page.evaluate('window.__saved.aiPrivacy') == 'local'
    page.wait_for_function('document.querySelector("#aiStatus").textContent.startsWith("On")', timeout=6000)
    status = page.locator('#aiStatus').inner_text()
    assert '127.0.0.1:8776' in status and 'Credential Manager' in status and 'local models only' in status, status
    assert page.locator('#aiAltText').is_enabled() and page.locator('#aiSuggestBtn').is_enabled()
    # Alt text lands in the box and can become the note.
    page.locator('#aiAltText').click()
    page.wait_for_function('document.querySelector("#aiAlt").value.length>0', timeout=6000)
    assert page.locator('#aiAlt').input_value() == 'A report dialog with a Save button.'
    page.locator('#aiAltNote').click()
    assert page.locator('#note').input_value() == 'A report dialog with a Save button.'
    # Suggestions are listed, not applied; unticking one leaves it out of the undoable add.
    layers = r'JSON.stringify([...document.querySelectorAll("#layers button")].map(b => b.textContent.replace(/^\d+\. /, "")))'
    before = page.evaluate(layers)
    page.locator('#aiSuggestBtn').click()
    page.wait_for_function('document.querySelectorAll("#aiSuggestions input").length===3', timeout=6000)
    assert page.evaluate(layers) == before, 'suggestions were applied without being accepted'
    rows = page.evaluate('[...document.querySelectorAll("#aiSuggestions label")].map(l=>l.textContent)')
    assert rows[0].startswith('Cover: email') and rows[2].startswith('Step: first'), rows
    page.locator('#aiSuggestions input').nth(1).uncheck()
    assert page.locator('#aiApply').inner_text() == 'Add 2 checked'
    page.locator('#aiApply').click()
    after = json.loads(page.evaluate(layers))
    # The layer list shows the newest object first.
    assert after == ['step', 'redact'] + json.loads(before), after
    page.locator('#undo').click()
    assert page.evaluate(layers) == before, 'one undo should remove the added suggestions'
    assert not errors, errors
    browser.close()
print('PASS: AI help is off by default, saved as a setting, and suggestions are only added when accepted')
