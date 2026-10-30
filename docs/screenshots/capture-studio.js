// Captures the README screenshots of the SnapShackle Studio with Playwright Chromium, in both Fleet
// themes: Night watch (dark) and Chart room (light), at 1440x900.
// No Windows host needed: the page and its assets are served straight from this repo, and every
// /api/* call is answered with synthetic demo data (an invented app window drawn on a canvas, an
// empty library). Nothing from your own screen, library or settings appears in the images.
//   node docs/screenshots/capture-studio.js
'use strict';
const fs=require('node:fs');
const path=require('node:path');
const {chromium}=require('playwright');

const ROOT=path.resolve(__dirname,'..','..');
const VERSION=fs.readFileSync(path.join(ROOT,'VERSION'),'utf8').trim();
const ORIGIN='http://127.0.0.1:8768';
const TYPES={'.html':'text/html','.js':'text/javascript','.css':'text/css','.png':'image/png','.ico':'image/x-icon','.svg':'image/svg+xml','.woff2':'font/woff2','.woff':'font/woff','.ttf':'font/ttf'};

// Draws an invented app window (title bar, a list of text lines, a chart card) as the demo capture.
async function demoCapture(browser){
 const page=await browser.newPage();
 const b64=await page.evaluate(()=>{
  const c=document.createElement('canvas');c.width=1200;c.height=760;const g=c.getContext('2d');
  g.fillStyle='#f3f5fa';g.fillRect(0,0,1200,760);
  g.fillStyle='#1f2937';g.fillRect(0,0,1200,56);
  g.fillStyle='#ffffff';g.strokeStyle='#cbd2dc';g.lineWidth=2;
  g.fillRect(40,90,520,310);g.strokeRect(40,90,520,310);
  g.fillRect(620,90,540,610);g.strokeRect(620,90,540,610);
  g.fillStyle='#9aa3b1';[380,355,330,305,280,255,230,205,180].forEach((w,i)=>g.fillRect(70,120+i*24,w,10));
  g.fillStyle='#38bde1';g.fillRect(650,120,480,180);
  return c.toDataURL('image/png').split(',')[1];
 });
 await page.close();
 return Buffer.from(b64,'base64');
}

async function route(page,png,theme){
 await page.route(ORIGIN+'/**',async r=>{
  const url=new URL(r.request().url());
  const p=url.pathname;
  const json=(x,status=200)=>r.fulfill({status,contentType:'application/json',body:JSON.stringify(x)});
  if(p.startsWith('/api/')){
   if(p==='/api/health')return json({capture:true,ocr:true,version:VERSION,dpi:'per-monitor v2',lifecycle:'tab'});
   if(p==='/api/screens')return json({screens:[{name:'DISPLAY1',primary:true}]});
   if(p==='/api/windows')return json({windows:[]});
   if(p==='/api/capture'||p==='/api/region')return r.fulfill({status:200,contentType:'image/png',body:png});
   if(p==='/api/library')return json({items:[]});
   if(p==='/api/settings')return json({namePrefix:'SnapShackle',autoLibrary:false,recordFps:6,theme,saved:true});
   if(p==='/api/heartbeat')return json({autoStop:true,timeoutSeconds:20});
   if(p==='/api/events')return json({events:[],latest:0});
   return json({error:'not found'},404);
  }
  const file=path.join(ROOT,p==='/'?'index.html':decodeURIComponent(p));
  if(!file.startsWith(ROOT)||!fs.existsSync(file))return r.fulfill({status:404,body:''});
  let body=fs.readFileSync(file);
  if(p==='/')body=body.toString('utf8').replace('__SNAPSHACKLE_VERSION__',VERSION);
  return r.fulfill({status:200,contentType:TYPES[path.extname(file)]||'application/octet-stream',body});
 });
}

(async()=>{
 const browser=await chromium.launch();
 try{
  const png=await demoCapture(browser);
  for(const [theme,name] of [['dark','night-watch'],['light','chart-room']]){
   const context=await browser.newContext({viewport:{width:1440,height:900},deviceScaleFactor:1,colorScheme:theme});
   await context.addInitScript(t=>{try{localStorage.setItem('snapshackle-theme',t)}catch{}},theme);
   const page=await context.newPage();
   const errors=[];page.on('pageerror',e=>errors.push(String(e)));
   await route(page,png,theme);
   await page.goto(ORIGIN+'/');
   await page.waitForFunction(()=>document.querySelectorAll('#tools button').length>0);
   await page.click('#capture');
   await page.waitForFunction(()=>document.querySelector('#canvas').width===1200);
   // One annotation, so the editor shows a selected object with its handles.
   await page.click('[data-tool="arrow"]');
   const box=await page.locator('#canvas').boundingBox();
   const k=box.width/1200;
   await page.mouse.move(box.x+710*k,box.y+700*k);await page.mouse.down();
   await page.mouse.move(box.x+520*k,box.y+400*k,{steps:6});await page.mouse.up();
   await page.click('[data-tool="rectangle"]');
   await page.mouse.move(0,0);
   await page.waitForFunction(t=>document.documentElement.dataset.theme===t,theme);
   await page.waitForTimeout(600);
   if(errors.length)throw Error('Page errors: '+errors.join('; '));
   await page.screenshot({path:path.join(__dirname,'studio-'+name+'.png')});
   await context.close();
  }
 }finally{await browser.close();}
})().catch(err=>{console.error(err);process.exit(1)});
