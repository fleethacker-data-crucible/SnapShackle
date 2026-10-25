"""Render synthetic vertically overlapping screenshots in Chromium and verify stitching."""
import os
from pathlib import Path
from playwright.sync_api import sync_playwright

root = Path(__file__).resolve().parents[1]
# Uses Playwright's bundled Chromium unless CUTTERMK_CHROMIUM points at another binary.
executable = os.environ.get('CUTTERMK_CHROMIUM') or None

CASES = r'''async()=>{
  function tilesOf(original,starts,height){return starts.map(start=>{const t=document.createElement('canvas');t.width=original.width;t.height=height;t.getContext('2d').drawImage(original,0,start,original.width,height,0,0,original.width,height);return t})}
  const out={};
  // 1. Colourful gradient with white labels (the original synthetic case).
  {const o=document.createElement('canvas');o.width=320;o.height=720;const c=o.getContext('2d');
   for(let y=0;y<720;y++){c.fillStyle=`rgb(${y%229},${(y*3)%255},${(y*5)%245})`;c.fillRect(0,y,320,1)}
   for(let y=0;y<720;y+=49){c.fillStyle='#fff';c.font='bold 15px sans-serif';c.fillText('CUTTERMK SECTION '+y,10,y+17)}
   const r=await CutterMkStitch.stitch(tilesOf(o,[0,220,440],280));out.gradient={height:r.height,overlaps:r.overlaps}}
  // 2. A document: black text on white, full HD width. The old saturation check rejected this.
  {const o=document.createElement('canvas');o.width=1920;o.height=2400;const c=o.getContext('2d');
   c.fillStyle='#fff';c.fillRect(0,0,1920,2400);c.fillStyle='#111';c.font='22px serif';
   for(let y=30,i=0;y<2400;y+=31,i++)c.fillText('Paragraph line '+i+' of a long policy memo, with enough words to fill the width '+'x'.repeat(i%17),60+(i%5)*7,y);
   const r=await CutterMkStitch.stitch(tilesOf(o,[0,733,1466],934));out.document={height:r.height,overlaps:r.overlaps}}
  // 3. Two unrelated tiles must not be merged.
  {const a=document.createElement('canvas');a.width=400;a.height=300;const ca=a.getContext('2d');ca.fillStyle='#fff';ca.fillRect(0,0,400,300);ca.fillStyle='#000';ca.font='18px sans-serif';for(let y=20;y<300;y+=24)ca.fillText('alpha '+y,10,y);
   const b=document.createElement('canvas');b.width=400;b.height=300;const cb=b.getContext('2d');cb.fillStyle='#fff';cb.fillRect(0,0,400,300);cb.fillStyle='#000';cb.font='18px monospace';for(let y=31;y<300;y+=37)cb.fillText('zz '+(y*7),200,y);
   const r=await CutterMkStitch.stitch([a,b]);out.unrelated={height:r.height,overlaps:r.overlaps}}
  return out;
}'''

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, executable_path=executable, args=['--no-sandbox'])
    page = browser.new_page()
    page.set_content('<html><body></body></html>')
    page.add_script_tag(path=str(root / 'assets/stitch.js'))
    data = page.evaluate(CASES)
    print(data)
    assert data['gradient']['height'] == 720, 'gradient seams not exact'
    assert data['document']['height'] == 2400, 'black-on-white document seams not exact'
    assert data['document']['overlaps'] == [0, 201, 201], data['document']['overlaps']
    assert data['unrelated']['overlaps'] == [0, 0], 'unrelated tiles were merged'
    browser.close()
print('PASS: exact stitching for gradient and document pages; unrelated tiles kept apart')
