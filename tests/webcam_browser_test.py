"""Camera picture-in-picture in a real Chromium, using its built-in fake camera (no real camera, no screen).

1. The compositor draws a fake camera into the chosen corner of a synthetic "screen", the composite records,
   and stopping releases the camera.
2. The studio's Record video button, with the camera setting on, produces a recording and says the camera was on;
   with the camera refused, it still produces a recording and says why there is no camera picture.
Usage: python tests/webcam_browser_test.py   (Playwright; SNAPSHACKLE_CHROMIUM may point at a browser)
"""
import os
import re
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
ARGS = ['--no-sandbox', '--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream']

STAGE = '''async () => {
  const screen = document.createElement('canvas'); screen.width = 640; screen.height = 360;
  const sctx = screen.getContext('2d'); sctx.fillStyle = '#102030'; sctx.fillRect(0, 0, 640, 360);
  const screenStream = screen.captureStream(15);
  window.__paint = setInterval(() => { sctx.fillStyle = '#102030'; sctx.fillRect(0, 0, 640, 360); }, 50);
  const cameraStream = await navigator.mediaDevices.getUserMedia(SnapShackleWebcam.cameraConstraints(''));
  const camTrack = cameraStream.getVideoTracks()[0];
  const out = {};
  for (const corner of ['br', 'tl']) {
    const comp = await SnapShackleWebcam.createCompositor({screenStream, cameraStream: await navigator.mediaDevices.getUserMedia(SnapShackleWebcam.cameraConstraints('')), fps: 15, corner, size: 'large'});
    await new Promise(r => setTimeout(r, 600));
    comp.redraw();
    const c = comp.canvas, ctx = c.getContext('2d'), b = comp.box;
    const inside = Array.from(ctx.getImageData(b.x + b.w / 2 | 0, b.y + b.h / 2 | 0, 1, 1).data);
    const far = corner === 'br' ? [10, 10] : [c.width - 10, c.height - 10];
    const outside = Array.from(ctx.getImageData(far[0], far[1], 1, 1).data);
    // Many samples inside the box: the fake camera is a moving pattern, so it is never the flat screen colour.
    const px = ctx.getImageData(b.x + 4, b.y + 4, b.w - 8, b.h - 8).data;
    let differing = 0; for (let i = 0; i < px.length; i += 4) if (Math.abs(px[i] - 0x10) + Math.abs(px[i+1] - 0x20) + Math.abs(px[i+2] - 0x30) > 30) differing++;
    out[corner] = {box: b, inside, outside, fraction: differing / (px.length / 4), frames: comp.frames};
    if (corner === 'br') {
      const rec = new MediaRecorder(comp.stream, {mimeType: 'video/webm'}); const chunks = [];
      rec.ondataavailable = e => { if (e.data.size) chunks.push(e.data); };
      const done = new Promise(r => { rec.onstop = r; });
      rec.start(200); await new Promise(r => setTimeout(r, 1200)); rec.stop(); await done;
      out.recordedBytes = new Blob(chunks).size;
    }
    const tracks = comp.stream.getVideoTracks();
    comp.stop();
    out[corner].compositeEnded = tracks.every(t => t.readyState === 'ended');
  }
  clearInterval(window.__paint);
  out.cameraEnded = camTrack.readyState;
  return out;
}'''

MOCK = r"""() => {
  const json=(x,status=200)=>new Response(JSON.stringify(x),{status,headers:{'Content-Type':'application/json'}});
  window.fetch=async (path,options={}) => {
    const url=String(path);
    if(url.startsWith('/api/health'))return json({capture:true,ocr:false,version:'test'});
    if(url.startsWith('/api/screens'))return json({screens:[]});
    if(url.startsWith('/api/windows'))return json({windows:[]});
    if(url.startsWith('/api/settings')){if(options.method==='PUT'){window.__settings=JSON.parse(options.body);return json({...window.__settings,saved:true})}return json({...(window.__settings||{}),saved:!!window.__settings})}
    if(url.startsWith('/api/heartbeat'))return json({autoStop:true,timeoutSeconds:20});
    if(url.startsWith('/api/events'))return json({events:[],latest:0});
    if(url.startsWith('/api/library'))return json({items:[]});
    return json({error:'not found'},404);
  };
  navigator.sendBeacon=()=>true;
  // A synthetic "screen share": a canvas that keeps changing.
  const screen=document.createElement('canvas');screen.width=640;screen.height=360;const ctx=screen.getContext('2d');let n=0;
  window.__paint=setInterval(()=>{ctx.fillStyle=n++%2?'#203040':'#304050';ctx.fillRect(0,0,640,360)},40);
  window.__screenTracks=[];
  navigator.mediaDevices.getDisplayMedia=async()=>{const s=screen.captureStream(10);window.__screenTracks.push(...s.getTracks());return s};
}"""

def secure_blank(page):
    # Cameras need a secure context; http://localhost counts, about:blank does not.
    page.route('http://localhost/blank', lambda route: route.fulfill(status=200, content_type='text/html', body='<!doctype html><title>t</title>'))
    page.goto('http://localhost/blank')

def load_studio(page):
    secure_blank(page)
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

def studio_recording(browser, camera_error):
    page = browser.new_page(viewport={'width': 1440, 'height': 950}, accept_downloads=True)
    errors = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    load_studio(page)
    page.evaluate('''(camera_error) => {
      window.__cameraTracks = [];
      const real = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
      navigator.mediaDevices.getUserMedia = async (c) => {
        if (c.video && camera_error) { const e = new Error('no'); e.name = camera_error; throw e; }
        const s = await real(c); if (c.video) window.__cameraTracks.push(...s.getVideoTracks()); return s;
      };
    }''', camera_error)
    page.wait_for_function('document.querySelector("#tools") && document.querySelector("#tools").children.length===13')
    page.locator('#tabWorkflows').click()
    assert page.locator('#recordCamera').input_value() == 'off', 'Camera must be off by default'
    assert page.locator('#recordCameraRow').is_hidden()
    page.locator('#recordCamera').select_option('on')
    assert page.locator('#recordCameraRow').is_visible(), 'Camera options should show once the camera is on'
    page.locator('#recordCameraCorner').select_option('tl')
    page.locator('#recordCameraSize').select_option('small')
    page.locator('#settingsSave').click()
    page.wait_for_function('window.__settings && window.__settings.recordCamera==="on" && window.__settings.recordCameraCorner==="tl" && window.__settings.recordCameraSize==="small"', timeout=6000)
    page.locator('#record').click()
    if camera_error:
        page.wait_for_function('document.querySelector("#status").textContent.includes("no camera picture")', timeout=8000)
        assert page.locator('#recordAudioLive').is_hidden(), 'No camera, so nothing should announce a live camera'
    else:
        page.wait_for_function('document.querySelector("#status").textContent.includes("camera picture-in-picture on")', timeout=8000)
        live = page.locator('#recordAudioLive')
        assert live.is_visible() and 'Camera on' in live.inner_text(), 'A live camera must be announced'
    page.wait_for_timeout(1200)
    with page.expect_download(timeout=10000) as download:
        page.locator('#record').click()
    path = download.value.path()
    assert download.value.suggested_filename.endswith('.webm')
    assert Path(path).stat().st_size > 0, 'Recording is empty'
    page.wait_for_timeout(300)
    if not camera_error:
        states = page.evaluate('window.__cameraTracks.map(t => t.readyState)')
        assert states and all(s == 'ended' for s in states), 'Camera was not released: %s' % states
        assert 'camera' not in page.locator('#recordAudioLive').inner_text().lower() or page.locator('#recordAudioLive').is_hidden(), 'Live camera notice stayed after stop'
    assert page.evaluate('window.__screenTracks.every(t => t.readyState === "ended")'), 'Screen share was not released'
    assert not errors, errors
    page.close()

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, executable_path=os.environ.get('SNAPSHACKLE_CHROMIUM') or None, args=ARGS)
    page = browser.new_page()
    secure_blank(page)
    page.add_script_tag(path=str(ROOT / 'assets' / 'webcam.js'))
    out = page.evaluate(STAGE)
    page.close()
    br, tl = out['br'], out['tl']
    assert br['fraction'] > 0.5, ('camera not drawn bottom right', br)
    assert tl['fraction'] > 0.5, ('camera not drawn top left', tl)
    assert br['box']['x'] > 320 and br['box']['y'] > 180, br['box']
    assert tl['box']['x'] < 100 and tl['box']['y'] < 100, tl['box']
    assert max(abs(a - b) for a, b in zip(br['outside'][:3], [0x10, 0x20, 0x30])) < 8, ('screen corner should stay the screen colour', br['outside'])
    assert br['compositeEnded'] and tl['compositeEnded'], 'compositor.stop must end the composite track'
    assert out['recordedBytes'] > 0, 'composite did not record'
    studio_recording(browser, None)
    studio_recording(browser, 'NotAllowedError')
    browser.close()
print('PASS: camera picture-in-picture draws in the chosen corner, records, announces itself, releases the camera, and survives a refused camera')
