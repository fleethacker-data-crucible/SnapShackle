/* SnapShackle Studio controller — browser APIs and local-only PowerShell routes. */
(() => {
'use strict';
const $=selector=>document.querySelector(selector);
const TOKEN='__SESSION_TOKEN__';
// Sets a button to an icon plus a label (used for buttons whose state changes, e.g. Record/Stop).
function setButton(el,iconName,label,live=false){el.innerHTML=SnapShackleIcons.icon(iconName)+'<span>'+label+'</span>';el.classList.toggle('is-live',live)}
const api=(path,options={})=>fetch(path,{...options,headers:{...options.headers,'X-SnapShackle-Token':TOKEN}});
const canvas=$('#canvas');
let librarySelection=null,recorder=null,recordStream=null,gifInterval=null,gifFrames=[],gifCanvas=null,stitchTiles=[],listURLs=[],scrollInterval=null,scrollStream=null,scrollVideo=null,scrollPrevious=null;
let settings={namePrefix:'SnapShackle',autoLibrary:false,recordFps:6,stayInTray:false,theme:(window.SnapShackleTheme?.choice)||'dark'};
// Preferences saved under earlier names (CutterMk, Lasso, SnipHero) are copied forward once to
// 'snapshackle-settings'; the old keys are left in place so an older build still finds them.
function migrateStorageKey(key,legacyKeys){try{const current=localStorage.getItem(key);if(current!==null)return current;for(const old of legacyKeys){const value=localStorage.getItem(old);if(value!==null){try{localStorage.setItem(key,value)}catch{}return value}}}catch{}return null}
try {const saved=migrateStorageKey('snapshackle-settings',['cuttermk-settings','lasso-settings','sniphero-settings']);settings={...settings,...JSON.parse(saved||'{}')};if(['CutterMk','SnipHero','Lasso'].includes(settings.namePrefix))settings.namePrefix='SnapShackle'}catch{}
function notify(message){$('#status').textContent=message}
function fail(error){console.error('[SnapShackle]',error);notify('⚠ '+(error?.message||error))}
function sanitizePrefix(s){return (s||'SnapShackle').replace(/[^a-z0-9_-]/gi,'').substring(0,30)||'SnapShackle'}
function downloadName(extension){return `${sanitizePrefix(settings.namePrefix)}-${new Date().toISOString().replace(/[:.]/g,'-')}.${extension}`}
function download(blob,name){const url=URL.createObjectURL(blob),link=document.createElement('a');link.href=url;link.download=name;document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),20000)}
function fileDataURL(file){return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(reader.error);reader.readAsDataURL(file)})}
function setFileName(name){$('#fileName').textContent=name||'Untitled image'}
function fitZoom(){const area=$('#canvasScroller');let fit=Math.max(25,Math.min(100,Math.floor((area.clientWidth-80)/canvas.width*100/5)*5));setZoom(fit)}
function setZoom(z){z=Math.max(25,Math.min(200,Number(z)||100));$('#zoom').value=z;$('#zoomLabel').textContent=z+'%';canvas.style.width=(canvas.width*z/100)+'px';canvas.style.height=(canvas.height*z/100)+'px'}
let lastLayersSignature='',lastCaptureTiming='No capture timed yet';
const editor=new SnapShackleEditor(canvas,(instance)=>{
  $('#dims').textContent=instance.canvas.width+' × '+instance.canvas.height;
  // Pointer movement redraws the canvas frequently. Rebuild layer buttons ONLY when
  // their contents or the selected layer changed, not for every pen/drag frame.
  const signature=instance.selected+'|'+instance.objects.map(o=>o.type+':'+(o.text||'')).join('|');
  if(signature===lastLayersSignature)return;
  lastLayersSignature=signature;
  const layerRoot=$('#layers');layerRoot.replaceChildren();
  for(let i=instance.objects.length-1;i>=0;i--){let object=instance.objects[i];let button=document.createElement('button');button.className=i===instance.selected?'active':'';
    button.textContent=`${i+1}. ${object.type}${object.type==='text'?': '+(object.text||'').slice(0,22):''}`;
    button.onclick=()=>{instance.selected=i;instance.render()};layerRoot.append(button)}
});
async function saveOriginalPng(blob){
  const r=await api('/api/library',{method:'POST',headers:{'Content-Type':'image/png'},body:blob});
  if(!r.ok)throw Error('Automatic library save failed');
  const info=await r.json();librarySelection=info.name;await refreshLibrary();
}
async function loadImage(src,name,{autoSave=true}={}){
  await editor.setBackground(src);setFileName(name||'Imported image');fitZoom();
  notify('Image ready — '+canvas.width+' × '+canvas.height);
  // Saving must never block displaying the screenshot. Reuse the original PNG
  // without re-encoding the canvas; defer disk I/O until after the UI can paint.
  if(autoSave&&settings.autoLibrary){
    const preserve=src instanceof Blob&&src.type==='image/png';
    setTimeout(()=>{(preserve?saveOriginalPng(src):saveLibrary()).catch(fail)},0);
  }
}
function parseServerTiming(header){
  const result={};for(const match of (header||'').matchAll(/([a-z]+);dur=([0-9.]+)/g))result[match[1]]=Number(match[2]);return result;
}
async function capture(endpoint){
  notify('Capturing desktop…');const start=performance.now();
  let response=await api(endpoint);
  if(!response.ok){let data=await response.json().catch(()=>({}));throw Error(data.cancelled?'Region capture cancelled':data.error||'Capture failed')}
  const blob=await response.blob(),received=performance.now(),method=response.headers.get('X-SnapShackle-Capture-Method');
  const timing=parseServerTiming(response.headers.get('Server-Timing'));
  await loadImage(blob,'Desktop capture');const ready=performance.now();
  const transfer=Math.round(received-start),decode=Math.round(ready-received);
  const native=Number.isFinite(timing.acquire)?`native ${Math.round(timing.acquire)} ms, PNG ${Math.round(timing.encode||0)} ms, `:'';
  const select=timing.selection>0?` (includes ${Math.round(timing.selection)} ms choosing region)`:'';
  const via=method==='PrintWindow'?' · window content (covering windows ignored)':method==='screen'?' · screen pixels (app did not support PrintWindow)':'';
  lastCaptureTiming=`${native}request/transfer ${transfer} ms, browser display ${decode} ms, ${Math.round(ready-start)} ms overall${select}${via}`;
  console.info('[SnapShackle] capture timing:',lastCaptureTiming,'image size:',Math.round(blob.size/1024),'KiB');
  const diagnostic=$('#diagnostics');
  if(diagnostic)diagnostic.textContent=diagnostic.textContent.replace(/Last screenshot:[^\n]*/, 'Last screenshot: '+lastCaptureTiming);
  notify('Screenshot ready · '+lastCaptureTiming);
}
async function refreshScreens(){try{let response=await api('/api/screens');if(!response.ok)throw Error('Screen query failed');let data=await response.json();$('#display').replaceChildren(new Option('All displays',''));(data.screens||[]).forEach((screen,index)=>$('#display').add(new Option('Display '+(index+1)+(screen.primary?' · primary':''),String(index))))}catch(e){fail(e)}}
async function refreshWindows(){try{let r=await api('/api/windows');if(!r.ok)throw Error('Window enumeration failed');let d=await r.json();$('#windows').replaceChildren(new Option('Choose window',''));for(let w of d.windows||[])$('#windows').add(new Option(w.Title||w.title||'Untitled',String(w.Id??w.id)))}catch(e){fail(e)}}
// Appends the chosen delay; a countdown in the status bar shows when the capture will fire.
function withDelay(endpoint){const delay=Number($('#delay')?.value||0);if(!delay)return endpoint;
  let left=delay;notify(`Capturing in ${left} s — switch to what you want to capture`);
  const tick=setInterval(()=>{left--;if(left>0)notify(`Capturing in ${left} s…`);else clearInterval(tick)},1000);
  return endpoint+(endpoint.includes('?')?'&':'?')+'delay='+delay}
$('#capture').onclick=()=>capture(withDelay('/api/capture'+($('#display').value!==''?'?screen='+encodeURIComponent($('#display').value):''))).catch(fail);
$('#region').onclick=()=>capture(withDelay('/api/region')).catch(fail);
$('#refreshWindows').onclick=refreshWindows;
$('#windowCapture').onclick=()=>{if(!$('#windows').value)return notify('Choose an application window first');capture(withDelay('/api/capture?window='+encodeURIComponent($('#windows').value))).catch(fail)};
async function getSharedScreen(){if(!navigator.mediaDevices?.getDisplayMedia)throw Error('Screen sharing unavailable in this browser or restricted by policy');return navigator.mediaDevices.getDisplayMedia({video:{frameRate:settings.recordFps},audio:false})}
async function videoFor(stream){let video=document.createElement('video');video.srcObject=stream;video.muted=true;await video.play();if(!video.videoWidth)await new Promise(r=>setTimeout(r,400));return video}
$('#browserCapture').onclick=async()=>{let stream;try{stream=await getSharedScreen();const video=await videoFor(stream),temp=document.createElement('canvas');temp.width=video.videoWidth;temp.height=video.videoHeight;temp.getContext('2d').drawImage(video,0,0);await loadImage(await new Promise(resolve=>temp.toBlob(resolve,'image/png')),'Browser capture')}catch(e){fail(e)}finally{stream?.getTracks().forEach(t=>t.stop())}};
// Each tool: icon, label and a single-key shortcut (works while the canvas page has focus, not in text fields).
const toolNames={select:['select','Select','V'],arrow:['arrow','Arrow','A'],rectangle:['rectangle','Rectangle','R'],ellipse:['ellipse','Ellipse','E'],line:['line','Line','L'],pen:['pen','Pen','P'],highlight:['highlight','Highlight','H'],text:['text','Text','T'],step:['step','Steps','N'],crop:['crop','Crop','C'],redact:['redact','Redact','X'],pixelate:['pixelate','Pixelate','Q'],blur:['blur','Blur','B']};
const toolKeys={};
for(let [tool,[iconName,title,key]] of Object.entries(toolNames)){let button=document.createElement('button');button.className='tool';
  button.innerHTML=SnapShackleIcons.icon(iconName)+'<span>'+title+'</span><span class="tool-key" aria-hidden="true">'+key+'</span>';button.title=title+' ('+key+')';button.dataset.tool=tool;button.setAttribute('aria-keyshortcuts',key);toolKeys[key.toLowerCase()]=button;
  button.onclick=()=>{editor.tool=tool;for(let b of $('#tools').children)b.classList.toggle('active',b===button);notify('Tool: '+title)};$('#tools').append(button)}
$('#tools').firstElementChild.click();
// Drag-to-crop keeps annotations editable; afterwards the select tool comes back.
editor.onCrop=(instance,error)=>{if(error)return fail(error);setFileName('Cropped image');fitZoom();$('#tools [data-tool="select"]').click();notify(`Cropped to ${canvas.width} × ${canvas.height} · annotations kept · Ctrl+Z to undo`)};
$('#color').oninput=e=>{editor.color=e.target.value;$('#colorHex').textContent=e.target.value.toUpperCase()};
$('#width').oninput=e=>{editor.width=+e.target.value;$('#widthLabel').textContent=editor.width+' px'};
$('#font').oninput=e=>{editor.font=+e.target.value;$('#fontLabel').textContent=editor.font+' px'};
$('#undo').onclick=()=>editor.undo().catch(fail);$('#redo').onclick=()=>editor.redo().catch(fail);
$('#deleteObject').onclick=()=>editor.deleteSelected();$('#duplicate').onclick=()=>editor.duplicateSelected();
$('#forward').onclick=()=>editor.layerSelected(1);$('#backward').onclick=()=>editor.layerSelected(-1);
$('#editText').onclick=()=>{const selected=editor.objects[editor.selected];if(!selected||!['text','step'].includes(selected.type))return notify('Select a text or step annotation first');const s=prompt('Edit annotation text',selected.text);if(s!==null)editor.changeSelected(o=>o.text=s)};
$('#crop').onclick=()=>{const entry=prompt('Crop image: x, y, width, height in pixels',`0, 0, ${canvas.width}, ${canvas.height}`);if(!entry)return;const parts=entry.split(',').map(Number);if(parts.length!==4||parts.some(v=>!Number.isFinite(v)))return notify('Invalid crop coordinates');editor.crop(...parts).then(()=>{setFileName('Cropped image');fitZoom();notify('Image cropped · annotations kept')}).catch(fail)};
$('#zoom').oninput=e=>setZoom(e.target.value);$('#zoomFit').onclick=fitZoom;
$('#clear').onclick=()=>loadImage('data:image/svg+xml;charset=utf-8,'+encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720"><rect width="100%" height="100%" fill="white"/></svg>'),'Blank image').catch(fail);
$('#import').onclick=()=>$('#file').click();$('#file').onchange=async e=>{try{let f=e.target.files?.[0];if(f){if(!f.type.startsWith('image/'))throw Error('Choose an image file');await loadImage(f,f.name)}}catch(ex){fail(ex)}finally{e.target.value=''}};
$('#projectSave').onclick=async()=>{try{const project=await editor.portableProject();download(new Blob([JSON.stringify(project)],{type:'application/json'}),downloadName('snapshackle.json'))}catch(e){fail(e)}};
$('#projectOpen').onclick=()=>$('#projectFile').click();$('#projectFile').onchange=async e=>{try{let f=e.target.files?.[0];if(f){if(f.size>60_000_000)throw Error('Project file too large');await editor.load(JSON.parse(await f.text()));setFileName(f.name);fitZoom();notify('Editable project loaded')}}catch(ex){fail(ex)}finally{e.target.value=''}};
$('#png').onclick=()=>editor.export('image/png').then(b=>{download(b,downloadName('png'));notify('PNG exported')}).catch(fail);
$('#jpg').onclick=()=>editor.export('image/jpeg').then(b=>{download(b,downloadName('jpg'));notify('JPEG exported')}).catch(fail);
$('#copy').onclick=async()=>{try{const png=await editor.export();await navigator.clipboard.write([new ClipboardItem({'image/png':png})]);notify('Image copied to clipboard')}catch(e){fail(e)}};
$('#helpButton').onclick=()=>$('#helpDialog').showModal();$('#closeHelp').onclick=()=>$('#helpDialog').close();
document.addEventListener('paste',async e=>{if(['INPUT','TEXTAREA'].includes(document.activeElement?.tagName))return;const pasted=[...(e.clipboardData?.files||[])].find(f=>f.type.startsWith('image/'));if(pasted){e.preventDefault();try{await loadImage(pasted,'Pasted image')}catch(ex){fail(ex)}}});
const scroller=$('#canvasScroller');['dragenter','dragover'].forEach(evt=>scroller.addEventListener(evt,e=>{e.preventDefault();$('#dropHint').hidden=false}));
scroller.addEventListener('dragleave',e=>{if(!scroller.contains(e.relatedTarget))$('#dropHint').hidden=true});
scroller.addEventListener('drop',async e=>{e.preventDefault();$('#dropHint').hidden=true;let f=[...(e.dataTransfer?.files||[])].find(x=>x.type.startsWith('image/'));if(f){try{await loadImage(f,f.name)}catch(ex){fail(ex)}}});
for(let tab of document.querySelectorAll('.tab'))tab.onclick=()=>{for(let t of document.querySelectorAll('.tab')){let active=t===tab;t.classList.toggle('active',active);t.setAttribute('aria-selected',active?'true':'false')}for(let p of document.querySelectorAll('.side-tab')){let active=p.id===tab.dataset.panel;p.hidden=!active;p.classList.toggle('active',active)}};
let searchTimeout=null,thumbnailObserver=null,thumbnailGeneration=0;
let thumbnailQueue=[],thumbnailActive=0;
function queueThumbnail(image,name,generation){
  thumbnailQueue.push({image,name,generation});
  pumpThumbnails();
}
function pumpThumbnails(){
  // Limit competing requests on SnapShackle's single-threaded local server.
  while(thumbnailActive<2&&thumbnailQueue.length){
    const job=thumbnailQueue.shift();if(job.generation!==thumbnailGeneration||!job.image.isConnected)continue;
    thumbnailActive++;
    api('/api/thumb/'+encodeURIComponent(job.name))
      .then(r=>r.ok?r.blob():Promise.reject(Error('Missing thumbnail')))
      .then(blob=>{
        if(job.generation!==thumbnailGeneration||!job.image.isConnected)return;
        const url=URL.createObjectURL(blob);listURLs.push(url);job.image.src=url;
      }).catch(()=>{}).finally(()=>{thumbnailActive--;pumpThumbnails()});
  }
}
async function refreshLibrary(){
  let root=$('#libraryItems');thumbnailGeneration++;thumbnailQueue=[];
  if(thumbnailObserver){thumbnailObserver.disconnect();thumbnailObserver=null}
  listURLs.forEach(u=>URL.revokeObjectURL(u));listURLs=[];root.replaceChildren();try{
  let response=await api('/api/library?q='+encodeURIComponent($('#librarySearch').value));if(!response.ok)throw Error('Library unavailable');let data=await response.json();let items=data.items||[];
  if(!items.length){root.innerHTML='<div class="empty">No captures found. Save a screenshot to get started.</div>';return}
  // The observer requests only visible thumbnail cards, not 32 full-size captures.
  const generation=thumbnailGeneration;
  if(typeof IntersectionObserver!=='undefined'){
    thumbnailObserver=new IntersectionObserver(entries=>{
      for(const entry of entries)if(entry.isIntersecting){
        thumbnailObserver?.unobserve(entry.target);
        const img=entry.target.querySelector('img');
        if(img&&entry.target.isConnected)queueThumbnail(img,entry.target.dataset.capture,generation);
      }
    },{root,rootMargin:'140px'});
  }
  for(let item of items.slice(0,90)){let button=document.createElement('button');button.className='capture-card'+(item.name===librarySelection?' active':'');button.dataset.capture=item.name;
    let preview=document.createElement('img');preview.alt='Capture thumbnail';preview.loading='lazy';let text=document.createElement('span'),name=document.createElement('b'),meta=document.createElement('small');name.textContent=item.name;meta.textContent=(item.textMatch?'Text in image matches · ':'')+((item.tags||[]).join(' · ')||new Date(item.modified).toLocaleDateString());text.append(name,meta);button.append(preview,text);root.append(button);
    button.onclick=async()=>{try{let r=await api('/api/library/'+encodeURIComponent(item.name));if(!r.ok)throw Error('Capture not found');let blob=await r.blob();await loadImage(blob,item.name,{autoSave:false});librarySelection=item.name;$('#tags').value=(item.tags||[]).join(', ');$('#note').value=item.note||'';for(let node of root.children)node.classList.toggle('active',node===button)}catch(ex){fail(ex)}};
    // Hidden cards incur no image decode or server work until scrolled into view.
    if(thumbnailObserver)thumbnailObserver.observe(button);
    else if(items.indexOf(item)<6)queueThumbnail(preview,item.name,generation);
  }
}catch(e){fail(e)}}
$('#libraryRefresh').onclick=refreshLibrary;$('#librarySearch').oninput=()=>{clearTimeout(searchTimeout);searchTimeout=setTimeout(refreshLibrary,200)};
async function saveLibrary(){let png=await editor.export();let r=await api('/api/library',{method:'POST',headers:{'Content-Type':'image/png'},body:png});if(!r.ok)throw Error('Could not save screenshot');let info=await r.json();librarySelection=info.name;notify('Saved '+info.name);await refreshLibrary()}
$('#librarySave').onclick=()=>saveLibrary().catch(fail);
$('#metadataSave').onclick=async()=>{if(!librarySelection)return notify('Choose a saved capture first');try{let r=await api('/api/library/'+encodeURIComponent(librarySelection),{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({tags:$('#tags').value.split(',').map(x=>x.trim()).filter(Boolean),note:$('#note').value})});if(!r.ok)throw Error('Could not save details');notify('Capture details updated');await refreshLibrary()}catch(e){fail(e)}};
$('#libraryDelete').onclick=async()=>{if(!librarySelection)return notify('Choose a saved capture first');if(!confirm('Delete '+librarySelection+' permanently?'))return;try{let r=await api('/api/library/'+encodeURIComponent(librarySelection),{method:'DELETE'});if(!r.ok)throw Error('Delete failed');librarySelection=null;$('#tags').value='';$('#note').value='';await refreshLibrary();notify('Capture deleted')}catch(e){fail(e)}};
$('#record').onclick=async()=>{
 if(gifInterval||scrollInterval)return notify('Finish GIF or scrolling capture before recording video');
 if(recorder){if(recorder.state!=='inactive')recorder.stop();return}
 try{recordStream=await getSharedScreen();const supported=['video/webm;codecs=vp9','video/webm;codecs=vp8','video/webm'].find(t=>MediaRecorder.isTypeSupported(t));if(!supported)throw Error('WebM recording not supported');
   const chunks=[];const stream=recordStream;recorder=new MediaRecorder(stream,{mimeType:supported});
   recorder.ondataavailable=e=>{if(e.data.size)chunks.push(e.data)};
   recorder.onstop=()=>{if(chunks.length)download(new Blob(chunks,{type:supported}),downloadName('webm'));stream.getTracks().forEach(t=>t.stop());recordStream=null;recorder=null;setButton($('#record'),'record','Record video');notify('WebM recording exported')};
   for(let track of stream.getVideoTracks())track.onended=()=>{if(recorder?.state==='recording')recorder.stop()};
   recorder.start(1000);setButton($('#record'),'stop','Stop recording',true);notify('Recording: use Stop to export WebM');
 }catch(e){recordStream?.getTracks().forEach(t=>t.stop());recordStream=null;recorder=null;fail(e)}
};
$('#gif').onclick=async()=>{
 if(recorder||scrollInterval)return notify('Finish video or scrolling capture before recording GIF');
 if(gifInterval){clearInterval(gifInterval);gifInterval=null;recordStream?.getTracks().forEach(t=>t.stop());recordStream=null;
   try{if(!gifFrames.length)throw Error('No recorded GIF frames');let blob=SnapShackleGif.encode(gifFrames,gifCanvas.width,gifCanvas.height,Math.round(1000/settings.recordFps));download(blob,downloadName('gif'));notify('Animated GIF exported · '+gifFrames.length+' frames')}catch(e){fail(e)}finally{gifFrames=[];setButton($('#gif'),'gif','GIF')}return}
 try{recordStream=await getSharedScreen();const video=await videoFor(recordStream);gifCanvas=document.createElement('canvas');const scale=Math.min(1,640/video.videoWidth,480/video.videoHeight);gifCanvas.width=Math.max(2,Math.round(video.videoWidth*scale));gifCanvas.height=Math.max(2,Math.round(video.videoHeight*scale));
   gifFrames=[];const ctx=gifCanvas.getContext('2d',{willReadFrequently:true});for(let track of recordStream.getVideoTracks())track.onended=()=>{if(gifInterval)$('#gif').click()};
   gifInterval=setInterval(()=>{if(gifFrames.length>=100){$('#gif').click();return}ctx.drawImage(video,0,0,gifCanvas.width,gifCanvas.height);gifFrames.push(ctx.getImageData(0,0,gifCanvas.width,gifCanvas.height).data.slice());notify('GIF recording · '+gifFrames.length+'/100 frames')},1000/settings.recordFps);
   setButton($('#gif'),'stop','Finish GIF',true);
 }catch(e){recordStream?.getTracks().forEach(t=>t.stop());recordStream=null;fail(e)}
};
function graySignature(ctx,width,height){
 const tmp=document.createElement('canvas');tmp.width=44;tmp.height=26;const c=tmp.getContext('2d',{willReadFrequently:true});c.drawImage(ctx.canvas,0,0,width,height,0,0,44,26);
 let rgba=c.getImageData(0,0,44,26).data,out=[];for(let i=0;i<rgba.length;i+=4)out.push((rgba[i]*3+rgba[i+1]*6+rgba[i+2])*.1);return out;
}
function signatureChange(a,b){if(!a)return Infinity;let sum=0;for(let i=0;i<a.length;i++)sum+=Math.abs(a[i]-b[i]);return sum/a.length}
$('#scrollAuto').onclick=async()=>{
 if(recorder||gifInterval)return notify('Finish your recording before scrolling capture');
 if(scrollInterval){clearInterval(scrollInterval);scrollInterval=null;scrollStream?.getTracks().forEach(t=>t.stop());scrollStream=null;scrollVideo=null;scrollPrevious=null;
   setButton($('#scrollAuto'),'scroll','Record scrolling views');notify('Automatic collection stopped — '+stitchTiles.length+' tiles ready to stitch');return}
 try {
   scrollStream=await getSharedScreen();scrollVideo=await videoFor(scrollStream);
   const cap=document.createElement('canvas');cap.width=scrollVideo.videoWidth;cap.height=scrollVideo.videoHeight;
   const ctx=cap.getContext('2d',{willReadFrequently:true});scrollPrevious=null;
   for(let track of scrollStream.getVideoTracks())track.onended=()=>{if(scrollInterval)$('#scrollAuto').click()};
   scrollInterval=setInterval(async()=>{
     try {
       if(stitchTiles.length>=25){$('#scrollAuto').click();return}
       ctx.drawImage(scrollVideo,0,0,cap.width,cap.height);
       const current=graySignature(ctx,cap.width,cap.height),change=signatureChange(scrollPrevious,current);
       if(change>4.2){scrollPrevious=current;stitchTiles.push(await createImageBitmap(cap));$('#stitchCount').textContent=stitchTiles.length+' tiles queued';notify('Scrolling view '+stitchTiles.length+' captured — scroll target to continue')}
     }catch(e){fail(e)}
   },550);
   setButton($('#scrollAuto'),'stop','Stop collecting',true);notify('Scroll the shared target; changed views are captured automatically')
 }catch(e){scrollStream?.getTracks().forEach(t=>t.stop());scrollStream=null;fail(e)}
};
$('#scrollAdd').onclick=async()=>{try{if(stitchTiles.length>=35)throw Error('Maximum 35 tiles');const blob=await editor.export();stitchTiles.push(await createImageBitmap(blob));$('#stitchCount').textContent=stitchTiles.length+' tiles queued';notify('Tile '+stitchTiles.length+' added — scroll the target and capture again')}catch(e){fail(e)}};
$('#scrollFinish').onclick=async()=>{try{let result=await SnapShackleStitch.stitch(stitchTiles,{autoOverlap:$('#alignOverlap').checked});for(let im of stitchTiles)im.close?.();stitchTiles=[];$('#stitchCount').textContent='0 tiles queued';await loadImage(result.canvas.toDataURL('image/png'),'Long screenshot');notify('Stitched '+result.overlaps.length+' tiles · overlap removed '+result.overlaps.reduce((a,b)=>a+b,0)+' px')}catch(e){fail(e)}};
// OCR the current image (annotations included). Native Windows OCR returns word boxes;
// the browser fallback returns line boxes only.
async function recognize(){
  const blob=await editor.export(),response=await api('/api/ocr',{method:'POST',headers:{'Content-Type':'image/png'},body:blob});
  if(response.ok){const r=await response.json();return {text:r.text||'',lines:r.lines||[],engine:'Windows native OCR'}}
  const nativeFailure=(await response.json().catch(()=>({}))).error||'Windows OCR failed';
  if(typeof TextDetector==='undefined')throw Error(nativeFailure+'; browser OCR is also unavailable');
  const found=await new TextDetector().detect(await createImageBitmap(blob));
  return {text:found.map(x=>x.rawValue).join('\n'),lines:SnapShackleRedact.fromTextDetector(found),engine:'Browser OCR'};
}
$('#ocr').onclick=async()=>{try{const r=await recognize();$('#ocrText').value=r.text;notify(r.engine+' complete')}catch(e){fail(e)}};
// Smart redaction: OCR, detect, let the person untick false positives, then cover with solid boxes.
let redactFindings=[];
function clampBox(b){return {x:Math.max(0,b.x),y:Math.max(0,b.y),x2:Math.min(canvas.width,b.x2),y2:Math.min(canvas.height,b.y2)}}
function applyRedactions(boxes){return editor.addObjects(boxes.map(b=>({type:'redact',...clampBox(b)})))}
function renderFindings(){
  const root=$('#redactFindings');root.replaceChildren();
  if(!redactFindings.length){root.textContent='No sensitive text found. OCR can miss small or stylised text.';$('#redactApply').hidden=true;return}
  redactFindings.forEach((f,i)=>{const row=document.createElement('label');row.className='redact-row';const box=document.createElement('input');box.type='checkbox';box.checked=true;box.dataset.index=i;
    const kind=document.createElement('b');kind.textContent=f.label;const text=document.createElement('span');text.textContent=f.text.length>36?f.text.slice(0,33)+'…':f.text;row.append(box,kind,text);root.append(row)});
  $('#redactApply').hidden=false;$('#redactApply').textContent=`Redact ${redactFindings.length} checked`;
}
$('#redactFind').onclick=async()=>{try{notify('Reading text…');const r=await recognize();redactFindings=SnapShackleRedact.detect(r.lines);renderFindings();
  notify(redactFindings.length?`Found ${redactFindings.length} item(s) to redact (${r.engine}). Untick any you want to keep.`:`No sensitive text found (${r.engine})`)}catch(e){fail(e)}};
$('#redactFindings').onchange=()=>{const n=[...$('#redactFindings').querySelectorAll('input:checked')].length;$('#redactApply').textContent=`Redact ${n} checked`};
$('#redactApply').onclick=()=>{const picked=[...$('#redactFindings').querySelectorAll('input:checked')].map(x=>redactFindings[+x.dataset.index]);
  const n=applyRedactions(picked.map(f=>f.box));redactFindings=[];$('#redactFindings').replaceChildren();$('#redactApply').hidden=true;
  notify(n?`Added ${n} solid redaction box(es). Undo removes them in one step.`:'Nothing selected')};
$('#redactTermApply').onclick=async()=>{try{const term=$('#redactTerm').value.trim();if(!term)return notify('Type a word or phrase to redact');
  notify('Reading text…');const r=await recognize();const hits=SnapShackleRedact.findText(r.lines,term);const n=applyRedactions(hits.map(h=>h.box));
  notify(n?`Redacted ${n} instance(s) of "${term}". Undo removes them in one step.`:`"${term}" was not found by ${r.engine}`)}catch(e){fail(e)}};
$('#copyOcr').onclick=()=>navigator.clipboard.writeText($('#ocrText').value).then(()=>notify('Text copied')).catch(fail);
function showSettings(){$('#prefix').value=settings.namePrefix;$('#autoLibrary').checked=settings.autoLibrary;$('#fps').value=settings.recordFps;$('#stayInTray').checked=!!settings.stayInTray;$('#theme').value=settings.theme;applyTheme(settings.theme)}
// Theme follows Lazarette: dark by default, light on request, or match Windows.
function applyTheme(choice){const theme=window.SnapShackleTheme?SnapShackleTheme.apply(choice):'dark';const toggle=$('#themeToggle');
  if(toggle){toggle.innerHTML=SnapShackleIcons.icon(theme==='light'?'moon':'sun');const next=theme==='light'?'dark':'light';toggle.title=toggle.ariaLabel='Switch to '+next+' theme'}}
$('#themeToggle').onclick=()=>{settings.theme=(window.SnapShackleTheme?.theme==='light')?'dark':'light';showSettings();saveSettings(false).catch(fail)};
$('#theme').onchange=()=>{settings.theme=$('#theme').value;applyTheme(settings.theme)};
function fromHost(saved){return {...settings,namePrefix:saved.namePrefix,autoLibrary:!!saved.autoLibrary,recordFps:saved.recordFps,stayInTray:!!saved.stayInTray,theme:saved.theme||settings.theme}}
// Settings are kept by the host (a port change would give the browser a new, empty storage origin).
async function loadSettings(){
  try{const r=await api('/api/settings');if(!r.ok)return;const saved=await r.json();
    if(saved.saved){settings=fromHost(saved)}
    else{await saveSettings(false)}  // First run: move browser-stored preferences to the host once.
    showSettings()}catch(e){console.warn('[SnapShackle] settings',e)}
}
async function saveSettings(announce=true){
  try{localStorage.setItem('snapshackle-settings',JSON.stringify(settings))}catch{}
  const r=await api('/api/settings',{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify(settings)});
  if(!r.ok)throw Error('Could not save preferences');const saved=await r.json();settings=fromHost(saved);
  if(announce){showSettings();notify('Preferences saved')}
}
$('#settingsSave').onclick=()=>{settings.namePrefix=sanitizePrefix($('#prefix').value);settings.autoLibrary=$('#autoLibrary').checked;settings.stayInTray=$('#stayInTray').checked;settings.recordFps=Math.max(2,Math.min(12,parseInt($('#fps').value,10)||6));settings.theme=$('#theme').value;saveSettings().catch(fail)};
showSettings();
document.addEventListener('keydown',event=>{
  if(['INPUT','TEXTAREA'].includes(document.activeElement?.tagName))return;
  const key=event.key.toLowerCase();if(event.ctrlKey&&key==='z'){event.preventDefault();editor.undo().catch(fail)}
  else if(event.ctrlKey&&key==='y'){event.preventDefault();editor.redo().catch(fail)}
  else if(event.key==='Delete')editor.deleteSelected();
  else if(event.ctrlKey&&event.shiftKey&&key==='s'){event.preventDefault();$('#region').click()}
  else if(event.ctrlKey&&event.shiftKey&&key==='p'){event.preventDefault();$('#projectSave').click()}
  else if(!event.ctrlKey&&!event.altKey&&!event.metaKey&&!document.querySelector('dialog[open]')&&toolKeys[key]&&document.activeElement?.tagName!=='SELECT'){event.preventDefault();toolKeys[key].click()}
});
const lifecycleText={tab:'stops when this tab closes',stay:'stays in the tray (--stay); Exit in the tray menu',tray:'stays in the tray (preference); Exit in the tray menu',env:'keeps running (SNAPSHACKLE_AUTO_STOP=0 or CUTTERMK_AUTO_STOP=0)'};
async function diagnostics(){let native='unknown',ocr='unavailable',dpi='unknown',keys='none',life='unknown';try{let r=await api('/api/health');if(r.ok){let d=await r.json();native=d.capture?'ready':'unavailable';if(d.version)$('.side-footer-version').textContent='v'+d.version;ocr=d.ocr?'available':'unavailable';dpi=d.dpi||'unknown';life=lifecycleText[d.lifecycle]||'unknown';
   const list=(d.hotkeys||[]).filter(h=>h.keys).map(h=>h.keys+' '+h.action);keys=list.length?list.join(', '):'none registered';const help=$('#globalHotkeys');if(help)help.textContent=keys}}catch{}
 $('#diagnostics').textContent='Windows capture: '+native+'\nDPI awareness: '+dpi+'\nGlobal hotkeys: '+keys+'\nSnapShackle session: '+life+'\nNative OCR: '+ocr+'\nBrowser record: '+(typeof MediaRecorder==='undefined'?'unavailable':'available')+'\nScreen share: '+(navigator.mediaDevices?.getDisplayMedia?'available':'unavailable')+'\nClipboard: '+(navigator.clipboard?'available':'unavailable')+'\nLast screenshot: '+lastCaptureTiming+'\nData remains on this computer.'}
// Hotkey captures happen while the browser is in the background; poll for them.
let lastEvent=null,eventsBusy=false;
async function openCapture(name,label){const r=await api('/api/library/'+encodeURIComponent(name));if(!r.ok)throw Error('Capture not found');await loadImage(await r.blob(),label||name,{autoSave:false});librarySelection=name}
async function pollEvents(){
  if(eventsBusy||document.hidden||sessionEnded)return;eventsBusy=true;
  try{const r=await api('/api/events?since='+(lastEvent??0));if(!r.ok)return;const d=await r.json();
    if(lastEvent===null){lastEvent=d.latest||0;return}
    const captures=(d.events||[]).filter(e=>e.type==='capture');lastEvent=Math.max(lastEvent,d.latest||0);
    if(captures.length){const latest=captures.at(-1);await openCapture(latest.name,'Hotkey capture');await refreshLibrary();notify('Hotkey capture opened · already copied to the clipboard and saved')}
  }catch(e){console.warn('[SnapShackle] events',e)}finally{eventsBusy=false}
}
setInterval(pollEvents,1500);document.addEventListener('visibilitychange',pollEvents);window.addEventListener('focus',pollEvents);
async function openFromHash(){const m=location.hash.match(/^#open=((?:SnapShackle|CutterMk|Lasso|SnipHero)-[A-Za-z0-9_.-]+\.png)$/);if(!m)return;history.replaceState(null,'',location.pathname);try{await openCapture(m[1],'Hotkey capture')}catch(e){fail(e)}}
window.addEventListener('hashchange',openFromHash);
// The studio tab owns the local server (and its tray icon and hotkeys): a heartbeat every 5 s and a
// "leaving" beacon on pagehide. SnapShackle stops about 5 s after the last open studio tab goes; a reload
// heartbeats again well inside that. Each page load has its own id, so with two tabs open, closing one
// keeps SnapShackle running.
let sessionEnded=false;
const tabId=(globalThis.crypto?.randomUUID?.()||(Math.random().toString(36).slice(2)+Date.now().toString(36))).replace(/[^A-Za-z0-9-]/g,'').slice(0,64);
function heartbeat(leaving=false){
  if(sessionEnded)return;
  try{api('/api/heartbeat',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({tab:tabId,leaving,hidden:document.hidden}),keepalive:true}).catch(()=>{})}catch{}
}
function leavingSignal(){
  if(sessionEnded)return;
  // sendBeacon is what browsers deliver during unload; it cannot set headers, so the token goes in the body (this route only).
  let sent=false;
  try{sent=!!navigator.sendBeacon?.('/api/heartbeat',new Blob([JSON.stringify({tab:tabId,leaving:true,session:TOKEN})],{type:'application/json'}))}catch{sent=false}
  if(!sent)heartbeat(true);
}
heartbeat();setInterval(()=>heartbeat(),5000);
window.addEventListener('pagehide',leavingSignal);
window.addEventListener('pageshow',event=>{if(event.persisted)heartbeat()});
document.addEventListener('visibilitychange',()=>heartbeat());
function showSessionEnded(){
  const screen=document.createElement('div');screen.className='session-ended';screen.setAttribute('role','alert');
  screen.innerHTML='<div><h1>SnapShackle has stopped</h1><p>The local server, tray icon and global hotkeys are off. Close this tab, or run Launch-SnapShackle.bat to start a new session.</p></div>';
  document.body.append(screen);document.title='SnapShackle Studio (stopped)';
}
$('#endSession').onclick=async()=>{
  if(!confirm('End this SnapShackle session? The local server, tray icon and global hotkeys stop. Unsaved edits in this tab are lost.'))return;
  try{const r=await api('/api/session/stop',{method:'POST',headers:{'Content-Type':'application/json','X-SnapShackle-Intent':'end-session'},body:'{}'});
    if(!r.ok){const d=await r.json().catch(()=>({}));throw Error(d.error||'Could not end the session')}
    sessionEnded=true;showSessionEnded()}catch(e){fail(e)}
};
refreshScreens();refreshWindows();refreshLibrary();diagnostics();fitZoom();openFromHash();pollEvents();loadSettings();
})();