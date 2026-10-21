"""Headless Chromium integration test without external network or application server.
This test explicitly mocks the PowerShell local API; it does not verify Windows capture.
"""
import base64
import io
from pathlib import Path
from PIL import Image, ImageDraw
from playwright.sync_api import sync_playwright
ROOT=Path(__file__).resolve().parents[1]
im=Image.new('RGB',(900,580),'#f3f5fa')
d=ImageDraw.Draw(im);d.rectangle((50,45,400,300),fill='#38bde1',outline='#1c4c64',width=4);d.text((60,70),'SNIPHERO TEST IMAGE',fill='#121a28')
b=io.BytesIO();im.save(b,'PNG');png64=base64.b64encode(b.getvalue()).decode()
with sync_playwright() as p:
 browser=p.chromium.launch(headless=True,executable_path='/usr/bin/chromium',args=['--no-sandbox'])
 page=browser.new_page(viewport={'width':1440,'height':950},accept_downloads=True)
 errors=[];page.on('pageerror',lambda error:errors.append(str(error)))
 html=(ROOT/'index.html').read_text()
 import re
 html=re.sub(r'<script[^>]*src="[^"]+"[^>]*></script>','',html)
 html=re.sub(r'<link[^>]*stylesheet[^>]*>','',html)
 page.set_content(html)
 page.add_style_tag(path=str(ROOT/'assets/styles.css'))
 page.evaluate("(imageBase64)=>{const bytes=Uint8Array.from(atob(imageBase64),c=>c.charCodeAt(0));window.fetch=async(path,options={})=>{\n const url=String(path), json=(x,status=200)=>new Response(JSON.stringify(x),{status,headers:{'Content-Type':'application/json'}});\n if(url.startsWith('/api/health'))return json({capture:true,ocr:false,version:'test'});\n if(url.startsWith('/api/screens'))return json({screens:[{name:'TEST',primary:true}]});\n if(url.startsWith('/api/windows'))return json({windows:[{Title:'Mock window',Id:123}]});\n if(url.startsWith('/api/capture')||url.startsWith('/api/region'))return new Response(bytes,{status:200,headers:{'Content-Type':'image/png'}});\n if(url.startsWith('/api/library')&&options.method==='POST'){window.__library=bytes;return json({name:'SnipHero-Mock.png'})}\n if(url.startsWith('/api/library')&&(!options.method||options.method==='GET'))return json({items:window.__library?[{name:'SnipHero-Mock.png',tags:[],note:'',modified:'2026-10-21T00:00:00'}]:[]});\n if(url.startsWith('/api/library/SnipHero-'))return new Response(window.__library||bytes,{status:200,headers:{'Content-Type':'image/png'}});\n if(url.startsWith('/api/ocr'))return json({error:'Unavailable'},501);\n return json({error:'not found'},404);\n};}",png64)
 for name in ['editor','gif','stitch','studio']:
  page.add_script_tag(path=str(ROOT/'assets'/f'{name}.js'))
 assert page.locator('#tools button').count()==12,'Tool buttons did not initialize'
 page.locator('#capture').click()
 page.wait_for_function('document.querySelector("#canvas").width===900')
 page.locator('[data-tool="rectangle"]').click()
 bbox=page.locator('#canvas').bounding_box()
 page.mouse.move(bbox['x']+30,bbox['y']+35)
 page.mouse.down();page.mouse.move(bbox['x']+210,bbox['y']+175,steps=4);page.mouse.up()
 assert page.locator('#layers button').count()==1,'Annotation not created'
 page.locator('#undo').click();page.wait_for_timeout(50)
 assert page.locator('#layers button').count()==0,'Undo failed'
 page.locator('#redo').click();page.wait_for_timeout(50)
 assert page.locator('#layers button').count()==1,'Redo failed'
 page.locator('#tabLayers').click();page.locator('#layers button').first.click();page.locator('#duplicate').click();assert page.locator('#layers button').count()==2
 page.locator('#tabLayers').click();assert page.locator('#projectSave').is_visible()
 with page.expect_download() as info:page.locator('#png').click()
 assert info.value.suggested_filename.endswith('.png')
 page.locator('#tabLibrary').click();page.locator('#librarySave').click()
 
 try:page.wait_for_function('document.querySelectorAll(".capture-card").length>0',timeout=2500)
 except Exception: print('DEBUG',page.locator('#status').inner_text(), 'errors',errors, 'lib',page.evaluate('!!window.__library'), 'html',page.locator('#libraryItems').inner_html());raise
 assert not errors,'Browser errors: '+repr(errors)
 print('PASS: browser startup, capture, annotations, undo/redo, duplicate, export, library')
 page.screenshot(path=str(ROOT/'tests/preview.png'),full_page=True)
 browser.close()