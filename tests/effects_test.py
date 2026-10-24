"""Blur must soften content in place, not shift or scale it."""
import os
from pathlib import Path
from playwright.sync_api import sync_playwright

root = Path(__file__).resolve().parents[1]
executable = os.environ.get('LASSO_CHROMIUM') or None

CHECK = r'''async()=>{
  const canvas=document.createElement('canvas');document.body.append(canvas);
  const editor=new LassoEditor(canvas);
  // White 400x200 image with a 6px black bar at x=100..105.
  const src=document.createElement('canvas');src.width=400;src.height=200;const c=src.getContext('2d');
  c.fillStyle='#fff';c.fillRect(0,0,400,200);c.fillStyle='#000';c.fillRect(100,0,6,200);
  await editor.setBackground(await new Promise(r=>src.toBlob(r,'image/png')));
  editor.objects.push({type:'blur',x:40,y:40,x2:240,y2:160});editor.render(true);
  const row=editor.ctx.getImageData(0,100,400,1).data;let darkest=0,value=255;
  for(let x=0;x<400;x++){const v=row[x*4];if(v<value){value=v;darkest=x}}
  return {darkest,value};
}'''

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, executable_path=executable, args=['--no-sandbox'])
    page = browser.new_page()
    page.set_content('<html><body></body></html>')
    page.add_script_tag(path=str(root / 'assets/editor.js'))
    data = page.evaluate(CHECK)
    print(data)
    assert 100 <= data['darkest'] <= 105, f"blurred bar moved to x={data['darkest']}"
    assert data['value'] > 20, 'region was not blurred'
    browser.close()
print('PASS: blur stays aligned with the content it covers')
