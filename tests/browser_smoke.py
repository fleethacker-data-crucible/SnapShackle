"""Chromium interactions against a mocked local API (no Windows needed)."""
import base64
import os
import io
import re
from pathlib import Path
from PIL import Image, ImageDraw
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
image = Image.new('RGB', (900, 580), '#f3f5fa')
draw = ImageDraw.Draw(image)
draw.rectangle((50, 45, 400, 300), fill='#38bde1', outline='#1c4c64', width=4)
draw.text((60, 70), 'SNAPSHACKLE TEST IMAGE', fill='#121a28')
stream = io.BytesIO()
image.save(stream, 'PNG')
image_b64 = base64.b64encode(stream.getvalue()).decode()

def _channel(value):
    value = value / 255
    return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4

def _contrast(foreground, background):
    def lum(rgb):
        return 0.2126 * _channel(rgb[0]) + 0.7152 * _channel(rgb[1]) + 0.0722 * _channel(rgb[2])
    lighter, darker = max(lum(foreground), lum(background)), min(lum(foreground), lum(background))
    return (lighter + 0.05) / (darker + 0.05)

def _rgb(value):
    return [int(part) for part in re.findall(r'\d+', value)[:3]]

def assert_audio_contrast(page, theme):
    """Record-sound controls and the recording announcement meet WCAG AA 4.5:1."""
    control = page.locator('#recordAudio').evaluate('''el => {
      function opaque(node) {
        while (node) {
          const bg = getComputedStyle(node).backgroundColor;
          const parts = bg.match(/[\\d.]+/g) || [];
          const alpha = parts.length === 4 ? parseFloat(parts[3]) : 1;
          if (alpha > 0.99) return bg;
          node = node.parentElement;
        }
        return getComputedStyle(document.body).backgroundColor;
      }
      const style = getComputedStyle(el);
      const label = document.querySelector('label[for="recordAudio"]');
      return {color: style.color, background: opaque(el), label: getComputedStyle(label).color, labelBackground: opaque(label)};
    }''')
    ratio = _contrast(_rgb(control['color']), _rgb(control['background']))
    assert ratio >= 4.5, (theme, 'record sound select', control, ratio)
    label_ratio = _contrast(_rgb(control['label']), _rgb(control['labelBackground']))
    assert label_ratio >= 4.5, (theme, 'record sound label', control, label_ratio)
    live = page.locator('#recordAudioLive').evaluate('''el => {
      el.hidden = false;
      el.textContent = 'Recording with sound: microphone';
      el.className = 'record-audio-live is-audible';
      const style = getComputedStyle(el);
      return {color: style.color, background: style.backgroundColor};
    }''')
    live_ratio = _contrast(_rgb(live['color']), _rgb(live['background']))
    assert live_ratio >= 4.5, (theme, 'recording announcement', live, live_ratio)
    page.locator('#recordAudioLive').evaluate('el => { el.hidden = true; el.textContent = ""; el.className = "record-audio-live"; }')

MOCK = r"""(imageBase64) => {
  const bytes=Uint8Array.from(atob(imageBase64), c=>c.charCodeAt(0));
  const originalFetch=window.fetch.bind(window);
  window.fetch=async (path,options={}) => {
    const url=String(path);
    if(url.startsWith('blob:'))return originalFetch(path,options);
    const json=(x,status=200)=>new Response(JSON.stringify(x),{status,headers:{'Content-Type':'application/json'}});
    if(window.__rejectSession)return json({error:'Invalid session'},403);
    if(url.startsWith('/api/heartbeat')&&window.__failHeartbeat)return json({error:'down'},503);
    if(url.startsWith('/api/events')&&window.__failPoll)return json({error:'down'},503);
    if(url.startsWith('/api/health'))return json({capture:true,ocr:false,version:'test'});
    if(url.startsWith('/api/screens'))return json({screens:[{name:'TEST',primary:true}]});
    if(url.startsWith('/api/windows'))return json({windows:[{Title:'Mock window',Id:123}]});
    if(url.startsWith('/api/capture')||url.startsWith('/api/region'))return new Response(bytes,{status:200,headers:{'Content-Type':'image/png','Server-Timing':'acquire;dur=11.2, encode;dur=25.4, selection;dur=0'}});
    if(url.startsWith('/api/library')&&options.method==='POST'){window.__library=bytes;return json({name:'SnapShackle-Mock.png'})}
    if(url.startsWith('/api/thumb/SnapShackle-')){window.__thumbRequests=(window.__thumbRequests||0)+1;return new Response(bytes,{status:200,headers:{'Content-Type':'image/jpeg'}})}
    if(url.startsWith('/api/library/SnapShackle-'))return new Response(window.__library||bytes,{status:200,headers:{'Content-Type':'image/png'}});
    if(url.startsWith('/api/library')&&(!options.method||options.method==='GET'))return json({items:window.__library?[{name:'SnapShackle-Mock.png',tags:[],note:'',modified:'2026-10-21T00:00:00'}]:[]});
    if(url.startsWith('/api/ocr'))return json({text:'Contact j.smith@corp.org or 757-555-0142 Starling',engine:'mock',lines:[{text:'Contact j.smith@corp.org or 757-555-0142',words:[{text:'Contact',x:60,y:100,w:70,h:20},{text:'j.smith@corp.org',x:140,y:100,w:160,h:20},{text:'or',x:310,y:100,w:20,h:20},{text:'757-555-0142',x:340,y:100,w:120,h:20}]},{text:'Starling',words:[{text:'Starling',x:60,y:200,w:80,h:20}]}]});
    if(url.startsWith('/api/settings')){if(options.method==='PUT'){window.__settings=JSON.parse(options.body);return json({...window.__settings,saved:true})}return json(window.__settings?{...window.__settings,saved:true}:{namePrefix:'SnapShackle',autoLibrary:false,recordFps:6,saved:false})}
    if(url.startsWith('/api/heartbeat')){const b=JSON.parse(options.body||'{}');(window.__beats=window.__beats||[]).push({...b,token:(options.headers||{})['X-SnapShackle-Token']});return json({autoStop:true,timeoutSeconds:20})}
    if(url.startsWith('/api/session/stop')){window.__stopIntent=(options.headers||{})['X-SnapShackle-Intent'];return json({stopped:true})}
    if(url.startsWith('/api/events')){const since=Number((url.match(/since=(\d+)/)||[])[1]||0);return json(window.__hotkey&&since<7?{events:[{id:7,type:'capture',name:'SnapShackle-Hot.png',source:'region'}],latest:7}:{events:[],latest:window.__hotkey?7:3})}
    return json({error:'not found'},404);
  };
  window.__beacons=[];
  navigator.sendBeacon=(url,blob)=>{blob.text().then(t=>window.__beacons.push({url,body:JSON.parse(t)}));return true};
}"""

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, executable_path=os.environ.get('SNAPSHACKLE_CHROMIUM') or os.environ.get('CUTTERMK_CHROMIUM') or None, args=['--no-sandbox'])
    page = browser.new_page(viewport={'width':1440,'height':950}, accept_downloads=True)
    errors = []
    page.on('pageerror', lambda error:errors.append(str(error)))
    html = (ROOT/'index.html').read_text(encoding='utf-8')
    # Load the same scripts, in the same order, as the real page.
    scripts = re.findall(r'<script[^>]*src="/assets/([a-z]+)\.js"', html)
    # ...and the same stylesheets (the Fleet tokens first, then the studio's).
    styles = re.findall(r'<link rel="stylesheet" href="/(assets/[a-z/]+\.css)"', html)
    html = re.sub(r'<script[^>]*src="[^"]+"[^>]*></script>', '', html)
    html = re.sub(r'<link[^>]*stylesheet[^>]*>', '', html)
    page.set_content(html)
    assert styles == ['assets/vendor/fleet/fleet.css','assets/styles.css'], styles
    for sheet in styles:
        page.add_style_tag(path=str(ROOT/sheet))
    page.evaluate(MOCK, image_b64)
    for name in scripts:
        page.add_script_tag(path=str(ROOT/'assets'/f'{name}.js'))

    assert page.locator('#tools button').count()==13, 'Tools failed to initialize'
    # Verify the capture path avoids Base64 FileReader conversion entirely.
    page.evaluate('''() => { window.__dataUrlReads=0;const original=FileReader.prototype.readAsDataURL;FileReader.prototype.readAsDataURL=function(...args){window.__dataUrlReads++;return original.apply(this,args)}}''')
    page.locator('#capture').click()
    page.wait_for_function('document.querySelector("#canvas").width===900')
    assert page.evaluate('window.__dataUrlReads')==0, 'Capture unexpectedly converted PNG to Base64'
    assert 'native 11 ms' in page.locator('#status').inner_text(), 'Per-stage timing was not shown'
    assert page.evaluate('window.__dataUrlReads')==0

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
    # A dialog owns keyboard input, even when focus is on a button instead of a text field.
    page.locator('#helpButton').click()
    page.locator('#closeHelp').focus()
    for key in ['Delete', 'Control+z', 'Control+y']:
        page.keyboard.press(key)
        page.wait_for_timeout(30)
        assert page.locator('#layers button').count()==2, key+' edited the canvas behind the dialog'
    page.keyboard.press('Escape')
    # Selects, rich-text fields and menus also own their editing shortcuts.
    page.evaluate('''() => {
      const box = document.createElement('div'); box.id = 'shortcut-fixture';
      box.innerHTML = '<select id="shortcut-select"><option>One</option></select><div contenteditable="true" id="shortcut-editable">Synthetic text</div><div role="menu"><button id="shortcut-menu">Menu item</button></div>';
      document.body.append(box);
    }''')
    for selector in ['#shortcut-select', '#shortcut-editable', '#shortcut-menu']:
        page.locator(selector).focus()
        for key in ['Delete', 'Control+z', 'Control+y']:
            page.keyboard.press(key)
            page.wait_for_timeout(30)
            assert page.locator('#layers button').count()==2, (selector,key,'edited the canvas')
    page.locator('#shortcut-fixture').evaluate('el => el.remove()')
    # Undo and redo still work when the editor owns focus.
    page.locator('#canvas').click(position={'x': 5, 'y': 5})
    page.keyboard.press('Control+z')
    page.wait_for_function('document.querySelectorAll("#layers button").length===1')
    page.keyboard.press('Control+y')
    page.wait_for_function('document.querySelectorAll("#layers button").length===2')
    assert page.locator('#projectSave').is_visible()
    with page.expect_download(timeout=8000) as project_download:
        page.locator('#projectSave').click()
    project = project_download.value
    import json
    saved = json.loads(Path(project.path()).read_text())
    assert saved['background'].startswith('data:image/png;base64,'), 'Portable project references a temporary blob URL'
    assert saved['width']==900
    # Portable project must round-trip after the temporary Blob URL disappears.
    page.locator('#tabWorkflows').click()
    page.locator('#clear').click()
    page.wait_for_function('document.querySelector("#canvas").width===1280')
    page.locator('#projectFile').set_input_files(project.path())
    page.wait_for_function('document.querySelector("#canvas").width===900')
    page.locator('#tabLayers').click()
    assert page.locator('#layers button').count()==2, 'Editable project did not restore its layers'

    with page.expect_download() as download:
        page.locator('#png').click()
    assert download.value.suggested_filename.endswith('.png')
    page.locator('#tabLibrary').click()
    page.locator('#librarySave').click()
    page.wait_for_function('document.querySelectorAll(".capture-card").length>0')
    page.wait_for_function('document.querySelector(".capture-card img").naturalWidth>0')
    assert page.evaluate('window.__thumbRequests')>=1, 'Small thumbnail API was not requested'
    # A hotkey capture made while the studio was in the background opens automatically.
    page.evaluate("document.querySelector('#canvas').width=10")
    page.evaluate('window.__hotkey=true')
    page.wait_for_function('document.querySelector("#status").textContent.includes("Hotkey capture opened")', timeout=6000)
    assert page.evaluate("document.querySelector('#canvas').width")==900, 'Hotkey capture was not loaded'
    # First run copies browser preferences to the host; saving goes to the host.
    page.wait_for_function('window.__settings && window.__settings.namePrefix==="SnapShackle"', timeout=6000)
    page.locator('#tabWorkflows').click()
    assert page.locator('#recordAudio').input_value()=='off', 'Record sound was not off by default'
    assert page.locator('label[for="recordAudio"]').inner_text().startswith('Record sound')
    assert page.locator('#recordMicRow').is_hidden()
    page.locator('#recordAudio').focus()
    assert page.evaluate('document.activeElement.id')=='recordAudio', 'Record sound control is not keyboard focusable'
    page.locator('#recordAudio').select_option('mic')
    assert page.locator('#recordMicRow').is_visible()
    page.locator('#recordMic').focus()
    assert page.evaluate('document.activeElement.id')=='recordMic', 'Microphone picker is not keyboard focusable'
    page.locator('#recordMicRefresh').focus()
    assert page.evaluate('document.activeElement.id')=='recordMicRefresh'
    page.locator('#recordAudio').select_option('both')
    page.evaluate('document.querySelector("#status").textContent=""')
    page.locator('#settingsSave').click()
    # "Preferences saved" is set after the host response is written back into the form.
    page.wait_for_function('document.querySelector("#status").textContent.includes("Preferences saved") && window.__settings.recordAudio==="both"', timeout=6000)
    page.locator('#recordAudio').select_option('off')
    page.evaluate('document.querySelector("#status").textContent=""')
    page.locator('#settingsSave').click()
    page.wait_for_function('document.querySelector("#status").textContent.includes("Preferences saved") && window.__settings.recordAudio==="off" && window.__settings.recordMicId===""', timeout=6000)
    page.locator('#prefix').fill('Ops')
    page.locator('#settingsSave').click()
    page.wait_for_function('window.__settings.namePrefix==="Ops"', timeout=6000)
    # Theme toggle switches to light and saves the choice to the host.
    assert page.evaluate("document.documentElement.dataset.theme") == 'dark'
    page.locator('#themeToggle').click()
    page.wait_for_function("document.documentElement.dataset.theme==='light' && window.__settings && window.__settings.theme==='light'", timeout=6000)
    assert page.evaluate("getComputedStyle(document.body).backgroundColor") == 'rgb(251, 250, 242)', 'Fleet Chart room tokens not applied'
    assert_audio_contrast(page, 'light')
    page.locator('#themeToggle').click()
    page.wait_for_function("document.documentElement.dataset.theme==='dark' && window.__settings.theme==='dark'", timeout=6000)
    assert_audio_contrast(page, 'dark')
    # Single-key tool shortcuts (ignored while typing in a field).
    page.locator('#canvas').click(position={'x': 5, 'y': 5})
    page.keyboard.press('a')
    assert page.locator('[data-tool="arrow"]').get_attribute('class') == 'tool active', 'A did not pick the arrow tool'
    page.locator('#tabWorkflows').click(); page.locator('#redactTerm').focus(); page.keyboard.press('r'); page.locator('#redactTerm').fill('')
    assert page.locator('[data-tool="arrow"]').get_attribute('class') == 'tool active', 'typing in a field changed the tool'
    page.locator('#canvas').click(position={'x': 5, 'y': 5})
    page.keyboard.press('v')
    # Icons rendered from the bundled set, not text glyphs.
    assert page.locator('#tools .tool svg.icon').count() == 13 and page.locator('#region svg.icon').count() == 1
    # Smart redaction: find, untick nothing, apply; then redact a typed word.
    page.locator('#tabLayers').click()
    before = page.locator('#layers button').count()
    page.locator('#tabWorkflows').click()
    page.locator('#redactFind').click()
    page.wait_for_function('document.querySelectorAll("#redactFindings input").length===2', timeout=6000)
    assert 'Redact 2 checked' in page.locator('#redactApply').inner_text()
    page.locator('#redactApply').click()
    page.locator('#tabLayers').click()
    assert page.locator('#layers button').count() == before + 2, 'redactions not added'
    pixel = page.evaluate("Array.from(document.querySelector('#canvas').getContext('2d').getImageData(220,110,1,1).data.slice(0,3))")
    assert pixel == [11, 11, 13], f'email not covered by a solid box: {pixel}'
    page.locator('#undo').click()
    page.wait_for_timeout(50)
    assert page.locator('#layers button').count() == before, 'undo did not remove both redactions in one step'
    page.locator('#tabWorkflows').click()
    page.locator('#redactTerm').fill('starling')
    page.locator('#redactTermApply').click()
    page.wait_for_function('document.querySelector("#status").textContent.includes("Redacted 1 instance")', timeout=6000)
    # Drag-to-crop keeps every annotation and moves them with the image.
    page.locator('#tabLayers').click()
    layers_before = page.locator('#layers button').count()
    assert layers_before >= 1
    page.locator('[data-tool="crop"]').click()
    box = page.locator('#canvas').bounding_box()
    scale = box['width'] / page.evaluate("document.querySelector('#canvas').width")
    page.mouse.move(box['x'] + 50*scale, box['y'] + 90*scale)
    page.mouse.down()
    page.mouse.move(box['x'] + 450*scale, box['y'] + 390*scale, steps=5)
    page.mouse.up()
    page.wait_for_function('document.querySelector("#status").textContent.includes("annotations kept")', timeout=6000)
    w, h = page.evaluate("[document.querySelector('#canvas').width, document.querySelector('#canvas').height]")
    assert abs(w-400) <= 3 and abs(h-300) <= 3, f'crop size {w}x{h}'
    assert page.locator('#layers button').count() == layers_before, 'crop dropped annotations'
    # The "Starling" redaction drawn at (60..140, 200..220) moved with the crop to about (10..90, 110..130).
    moved = page.evaluate("Array.from(document.querySelector('#canvas').getContext('2d').getImageData(50,120,1,1).data.slice(0,3))")
    assert moved == [11, 11, 13], f'annotation did not move with the crop: {moved}'
    page.locator('#undo').click()
    page.wait_for_function("document.querySelector('#canvas').width===900", timeout=6000)
    assert page.locator('#layers button').count() == layers_before, 'undo of crop lost annotations'
    # Lifecycle: the tab heartbeats with its own id and the session header; pagehide sends a beacon with the token in the body.
    page.wait_for_function('(window.__beats||[]).length>=1', timeout=6000)
    beat = page.evaluate('window.__beats[0]')
    assert beat['tab'] and beat['leaving'] is False and beat['token'] and 'session' not in beat, f'bad heartbeat {beat}'
    page.evaluate("window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:false}))")
    page.wait_for_function('window.__beacons.length===1', timeout=6000)
    beacon = page.evaluate('window.__beacons[0]')
    assert beacon['url'] == '/api/heartbeat' and beacon['body']['leaving'] is True and beacon['body']['session'] == beat['token'] and beacon['body']['tab'] == beat['tab'], f'bad beacon {beacon}'
    assert '?' not in beacon['url'], 'token must never travel in the query string'
    page.screenshot(path=str(ROOT/'tests/preview.png'), full_page=True)
    # End session (main navigation) stops the host after a confirmation and says so.
    page.once('dialog', lambda dialog: dialog.accept())
    page.locator('#endSession').click()
    page.wait_for_selector('.session-ended', timeout=6000)
    assert page.evaluate('window.__stopIntent') == 'end-session'
    ended = page.locator('.session-ended').inner_text()
    assert 'SnapShackle has stopped' in ended
    assert 'lost the SnapShackle session' not in ended
    assert page.locator('#reloadSession').inner_text() == 'Reload'
    page.locator('#reloadSession').focus()
    assert page.evaluate('document.activeElement && document.activeElement.id') == 'reloadSession'
    assert page.evaluate('document.title') == 'SnapShackle Studio (stopped)'
    assert not errors, 'JS errors: '+repr(errors)

    def boot_studio(prelude):
        extra = browser.new_page(viewport={'width':1440,'height':950})
        extra.on('pageerror', lambda error: errors.append('extra: '+str(error)))
        extra.set_content(html)
        for sheet in styles:
            extra.add_style_tag(path=str(ROOT/sheet))
        extra.evaluate(MOCK, image_b64)
        extra.evaluate(prelude)
        for name in scripts:
            extra.add_script_tag(path=str(ROOT/'assets'/f'{name}.js'))
        return extra

    def assert_session_lost(extra, label):
        extra.wait_for_selector('.session-ended', timeout=8000)
        text = extra.locator('.session-ended').inner_text()
        assert 'SnapShackle has stopped' in text, label
        assert 'lost the SnapShackle session' in text, label
        assert extra.locator('.session-ended').count() == 1, label
        button = extra.locator('#reloadSession')
        assert button.inner_text() == 'Reload', label
        assert extra.evaluate("document.querySelector('#reloadSession').tagName") == 'BUTTON', label
        button.focus()
        assert extra.evaluate('document.activeElement.id') == 'reloadSession', label
        assert extra.evaluate('document.title') == 'SnapShackle Studio (stopped)', label
        colors = button.evaluate('''el => {
          const style = getComputedStyle(el);
          return {color: style.color, background: style.backgroundColor};
        }''')
        ratio = _contrast(_rgb(colors['color']), _rgb(colors['background']))
        assert ratio >= 4.5, (label, colors, ratio)
        extra.evaluate("fetch('/api/health').catch(()=>{})")
        extra.wait_for_timeout(150)
        assert extra.locator('.session-ended').count() == 1, label+' stacked a second screen'

    lost = boot_studio('window.__rejectSession=true')
    assert_session_lost(lost, '403 Invalid session')
    lost.close()
    failed_beat = boot_studio('window.__failHeartbeat=true')
    assert_session_lost(failed_beat, 'failed heartbeat')
    failed_beat.close()
    failed_poll = boot_studio('window.__failPoll=true')
    assert_session_lost(failed_poll, 'failed poll')
    failed_poll.close()
    assert not errors, 'JS errors: '+repr(errors)
    print('PASS: browser startup, capture, annotations, undo/redo, duplicate, PNG export, loaded library preview, hotkey capture handoff, smart redaction, host-side settings, non-destructive crop, theme toggle, tool shortcuts, heartbeat/beacon, End session, lost session')
    browser.close()
