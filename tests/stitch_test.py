"""Render synthetic vertically overlapping screenshots in Chromium and verify stitching."""
from pathlib import Path
from playwright.sync_api import sync_playwright
root=Path(__file__).resolve().parents[1]
with sync_playwright() as p:
 browser=p.chromium.launch(headless=True,executable_path='/usr/bin/chromium',args=['--no-sandbox'])
 page=browser.new_page();page.set_content('<html><body></body></html>');page.add_script_tag(path=str(root/'assets/stitch.js'))
 data=page.evaluate('''async()=>{
  const original=document.createElement('canvas');original.width=320;original.height=720;
  const ctx=original.getContext('2d');for(let y=0;y<720;y++){ctx.fillStyle=`rgb(${y%229},${(y*3)%255},${(y*5)%245})`;ctx.fillRect(0,y,320,1)}
  for(let y=0;y<720;y+=49){ctx.fillStyle='#fff';ctx.font='bold 15px sans-serif';ctx.fillText('SNIPHERO SECTION '+y,10,y+17)}
  const tiles=[];for(let start of [0,220,440]){let tile=document.createElement('canvas');tile.width=320;tile.height=280;tile.getContext('2d').drawImage(original,0,start,320,280,0,0,320,280);tiles.push(tile)}
  const result=await SnipStitch.stitch(tiles,{autoOverlap:true});return {height:result.height,overlaps:result.overlaps};
 }''')
 print(data)
 assert abs(data['height']-720)<15,'Seam overlap was not identified'
 browser.close()