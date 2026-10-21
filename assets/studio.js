/* SnipHero Studio controller — browser APIs and local-only PowerShell routes. */
(() => {
'use strict';
const $=selector=>document.querySelector(selector);
const TOKEN='__SESSION_TOKEN__';
const api=(path,options={})=>fetch(path,{...options,headers:{...options.headers,'X-SnipHero-Token':TOKEN}});
const canvas=$('#canvas');
let librarySelection=null,recorder=null,recordStream=null,gifInterval=null,gifFrames=[],gifCanvas=null,stitchTiles=[],listURLs=[],scrollInterval=null,scrollStream=null,scrollVideo=null,scrollPrevious=null;
let settings={namePrefix:'SnipHero',autoLibrary:false,recordFps:6};
try {settings={...settings,...JSON.parse(localStorage.getItem('sniphero-settings')||'{}')}}catch{}
function notify(message){$('#status').textContent=message}
function fail(error){console.error('[SnipHero]',error);notify('⚠ '+(error?.message||error))}
function sanitizePrefix(s){return (s||'SnipHero').replace(/[^a-z0-9_-]/gi,'').substring(0,30)||'SnipHero'}
function downloadName(extension){return `${sanitizePrefix(settings.namePrefix)}-${new Date().toISOString().replace(/[:.]/g,'-')}.${extension}`}
function download(blob,name){const url=URL.createObjectURL(blob),link=document.createElement('a');link.href=url;link.download=name;document.body.append(link);link.click();link.remove();setTimeout(()=>URL.revokeObjectURL(url),20000)}
function fileDataURL(file){return new Promise((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(reader.error);reader.readAsDataURL(file)})}
function setFileName(name){$('#fileName').textContent=name||'Untitled image'}
function fitZoom(){const area=$('#canvasScroller');let fit=Math.max(25,Math.min(100,Math.floor((area.clientWidth-80)/canvas.width*100/5)*5));setZoom(fit)}
function setZoom(z){z=Math.max(25,Math.min(200,Number(z)||100));$('#zoom').value=z;$('#zoomLabel').textContent=z+'%';canvas.style.width=(canvas.width*z/100)+'px';canvas.style.height=(canvas.height*z/100)+'px'}
const editor=new SnipHeroEditor(canvas,(instance)=>{
  $('#dims').textContent=instance.canvas.width+' × '+instance.canvas.height;
  const layerRoot=$('#layers');layerRoot.replaceChildren();
  for(let i=instance.objects.length-1;i>=0;i--){let object=instance.objects[i];let button=document.createElement('button');button.className=i===instance.selected?'active':'';
    button.textContent=`${i+1}. ${object.type}${object.type==='text'?': '+(object.text||'').slice(0,22):''}`;
    button.onclick=()=>{instance.selected=i;instance.render()};layerRoot.append(button)}
});
async function loadImage(src,name,{autoSave=true}={}){await editor.setBackground(src);setFileName(name||'Imported image');fitZoom();notify('Image ready — '+canvas.width+' × '+canvas.height);if(autoSave&&settings.autoLibrary)await saveLibrary()}
async function capture(endpoint){notify('Capturing desktop…');let response=await api(endpoint);if(!response.ok){let data=await response.json().catch(()=>({}));throw Error(data.cancelled?'Region capture cancelled':data.error||'Capture failed')}
  await loadImage(await fileDataURL(await response.blob()),'Desktop capture')}
async function refreshScreens(){try{let response=await api('/api/screens');if(!response.ok)throw Error('Screen query failed');let data=await response.json();$('#display').replaceChildren(new Option('All displays',''));(data.screens||[]).forEach((screen,index)=>$('#display').add(new Option('Display '+(index+1)+(screen.primary?' · primary':''),String(index))))}catch(e){fail(e)}}
async function refreshWindows(){try{let r=await api('/api/windows');if(!r.ok)throw Error('Window enumeration failed');let d=await r.json();$('#windows').replaceChildren(new Option('Choose window',''));for(let w of d.windows||[])$('#windows').add(new Option(w.Title||w.title||'Untitled',String(w.Id??w.id)))}catch(e){fail(e)}}
$('#capture').onclick=()=>capture('/api/capture'+($('#display').value!==''?'?screen='+encodeURIComponent($('#display').value):'')).catch(fail);
$('#region').onclick=()=>capture('/api/region').catch(fail);
$('#refreshWindows').onclick=refreshWindows;
$('#windowCapture').onclick=()=>{if(!$('#windows').value)return notify('Choose an application window first');capture('/api/capture?window='+encodeURIComponent($('#windows').value)).catch(fail)};
async function getSharedScreen(){if(!navigator.mediaDevices?.getDisplayMedia)throw Error('Screen sharing unavailable in this browser or restricted by policy');return navigator.mediaDevices.getDisplayMedia({video:{frameRate:settings.recordFps},audio:false})}
async function videoFor(stream){let video=document.createElement('video');video.srcObject=stream;video.muted=true;await video.play();if(!video.videoWidth)await new Promise(r=>setTimeout(r,400));return video}
$('#browserCapture').onclick=async()=>{let stream;try{stream=await getSharedScreen();const video=await videoFor(stream),temp=document.createElement('canvas');temp.width=video.videoWidth;temp.height=video.videoHeight;temp.getContext('2d').drawImage(video,0,0);await loadImage(temp.toDataURL('image/png'),'Browser capture')}catch(e){fail(e)}finally{stream?.getTracks().forEach(t=>t.stop())}};
const toolNames={select:'↖ Select',arrow:'↗ Arrow',rectangle:'▢ Rectangle',ellipse:'◯ Ellipse',line:'╱ Line',pen:'✎ Pen',highlight:'▰ Highlight',text:'T Text',step:'① Steps',redact:'■ Redact',pixelate:'▦ Pixelate',blur:'◍ Blur'};
for(let [tool,title] of Object.entries(toolNames)){let button=document.createElement('button');button.className='tool';let parts=title.split(' ');button.innerHTML='<span class="tool-symbol">'+parts.shift()+'</span><span>'+parts.join(' ')+'</span>';button.title=title;button.dataset.tool=tool;
  button.onclick=()=>{editor.tool=tool;for(let b of $('#tools').children)b.classList.toggle('active',b===button);notify('Tool: '+title)};$('#tools').append(button)}
$('#tools').firstElementChild.click();
$('#color').oninput=e=>{editor.color=e.target.value;$('#colorHex').textContent=e.target.value.toUpperCase()};
$('#width').oninput=e=>{editor.width=+e.target.value;$('#widthLabel').textContent=editor.width+' px'};
$('#font').oninput=e=>{editor.font=+e.target.value;$('#fontLabel').textContent=editor.font+' px'};
$('#undo').onclick=()=>editor.undo().catch(fail);$('#redo').onclick=()=>editor.redo().catch(fail);
$('#deleteObject').onclick=()=>editor.deleteSelected();$('#duplicate').onclick=()=>editor.duplicateSelected();
$('#forward').onclick=()=>editor.layerSelected(1);$('#backward').onclick=()=>editor.layerSelected(-1);
$('#editText').onclick=()=>{const selected=editor.objects[editor.selected];if(!selected||!['text','step'].includes(selected.type))return notify('Select a text or step annotation first');const s=prompt('Edit annotation text',selected.text);if(s!==null)editor.changeSelected(o=>o.text=s)};
$('#crop').onclick=()=>{const entry=prompt('Crop image: x, y, width, height in pixels',`0, 0, ${canvas.width}, ${canvas.height}`);if(!entry)return;const parts=entry.split(',').map(Number);if(parts.length!==4||parts.some(v=>!Number.isFinite(v)))return notify('Invalid crop coordinates');editor.crop(...parts).then(()=>{setFileName('Cropped image');fitZoom();notify('Image cropped')}).catch(fail)};
$('#zoom').oninput=e=>setZoom(e.target.value);$('#zoomFit').onclick=fitZoom;
$('#clear').onclick=()=>loadImage('data:image/svg+xml;charset=utf-8,'+encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="720"><rect width="100%" height="100%" fill="white"/></svg>'),'Blank image').catch(fail);
$('#import').onclick=()=>$('#file').click();$('#file').onchange=async e=>{try{let f=e.target.files?.[0];if(f){if(!f.type.startsWith('image/'))throw Error('Choose an image file');await loadImage(await fileDataURL(f),f.name)}}catch(ex){fail(ex)}finally{e.target.value=''}};
$('#projectSave').onclick=()=>download(new Blob([JSON.stringify(editor.serialize())],{type:'application/json'}),downloadName('sniphero.json'));
$('#projectOpen').onclick=()=>$('#projectFile').click();$('#projectFile').onchange=async e=>{try{let f=e.target.files?.[0];if(f){if(f.size>60_000_000)throw Error('Project file too large');await editor.load(JSON.parse(await f.text()));setFileName(f.name);fitZoom();notify('Editable project loaded')}}catch(ex){fail(ex)}finally{e.target.value=''}};
$('#png').onclick=()=>editor.export('image/png').then(b=>{download(b,downloadName('png'));notify('PNG exported')}).catch(fail);
$('#jpg').onclick=()=>editor.export('image/jpeg').then(b=>{download(b,downloadName('jpg'));notify('JPEG exported')}).catch(fail);
$('#copy').onclick=async()=>{try{const png=await editor.export();await navigator.clipboard.write([new ClipboardItem({'image/png':png})]);notify('Image copied to clipboard')}catch(e){fail(e)}};
$('#helpButton').onclick=()=>$('#helpDialog').showModal();$('#closeHelp').onclick=()=>$('#helpDialog').close();
document.addEventListener('paste',async e=>{if(['INPUT','TEXTAREA'].includes(document.activeElement?.tagName))return;const pasted=[...(e.clipboardData?.files||[])].find(f=>f.type.startsWith('image/'));if(pasted){e.preventDefault();try{await loadImage(await fileDataURL(pasted),'Pasted image')}catch(ex){fail(ex)}}});
const scroller=$('#canvasScroller');['dragenter','dragover'].forEach(evt=>scroller.addEventListener(evt,e=>{e.preventDefault();$('#dropHint').hidden=false}));
scroller.addEventListener('dragleave',e=>{if(!scroller.contains(e.relatedTarget))$('#dropHint').hidden=true});
scroller.addEventListener('drop',async e=>{e.preventDefault();$('#dropHint').hidden=true;let f=[...(e.dataTransfer?.files||[])].find(x=>x.type.startsWith('image/'));if(f){try{await loadImage(await fileDataURL(f),f.name)}catch(ex){fail(ex)}}});
for(let tab of document.querySelectorAll('.tab'))tab.onclick=()=>{for(let t of document.querySelectorAll('.tab')){let active=t===tab;t.classList.toggle('active',active);t.setAttribute('aria-selected',active?'true':'false')}for(let p of document.querySelectorAll('.side-tab')){let active=p.id===tab.dataset.panel;p.hidden=!active;p.classList.toggle('active',active)}};
let searchTimeout=null;
async function refreshLibrary(){let root=$('#libraryItems');listURLs.forEach(u=>URL.revokeObjectURL(u));listURLs=[];root.replaceChildren();try{
  let response=await api('/api/library?q='+encodeURIComponent($('#librarySearch').value));if(!response.ok)throw Error('Library unavailable');let data=await response.json();let items=data.items||[];
  if(!items.length){root.innerHTML='<div class="empty">No captures found. Save a screenshot to get started.</div>';return}
  // Restrict preview fetches for responsiveness in large libraries.
  for(let item of items.slice(0,90)){let button=document.createElement('button');button.className='capture-card'+(item.name===librarySelection?' active':'');
    let preview=document.createElement('img');preview.alt='Capture thumbnail';preview.loading='lazy';let text=document.createElement('span'),name=document.createElement('b'),meta=document.createElement('small');name.textContent=item.name;meta.textContent=(item.tags||[]).join(' · ')||new Date(item.modified).toLocaleDateString();text.append(name,meta);button.append(preview,text);root.append(button);
    button.onclick=async()=>{try{let r=await api('/api/library/'+encodeURIComponent(item.name));if(!r.ok)throw Error('Capture not found');let blob=await r.blob();await loadImage(await fileDataURL(blob),item.name,{autoSave:false});librarySelection=item.name;$('#tags').value=(item.tags||[]).join(', ');$('#note').value=item.note||'';for(let node of root.children)node.classList.toggle('active',node===button)}catch(ex){fail(ex)}};
    // Fetch thumbnails lazily so the main UI is usable immediately.
    if(items.indexOf(item)<32)api('/api/library/'+encodeURIComponent(item.name)).then(r=>r.ok?r.blob():Promise.reject(Error('Missing thumb'))).then(blob=>{if(!button.isConnected)return;let url=URL.createObjectURL(blob);listURLs.push(url);preview.src=url}).catch(()=>{});
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
   recorder.onstop=()=>{if(chunks.length)download(new Blob(chunks,{type:supported}),downloadName('webm'));stream.getTracks().forEach(t=>t.stop());recordStream=null;recorder=null;$('#record').innerHTML='● <span>Record video</span>';notify('WebM recording exported')};
   for(let track of stream.getVideoTracks())track.onended=()=>{if(recorder?.state==='recording')recorder.stop()};
   recorder.start(1000);$('#record').innerHTML='■ <span>Stop recording</span>';notify('Recording: use Stop to export WebM');
 }catch(e){recordStream?.getTracks().forEach(t=>t.stop());recordStream=null;recorder=null;fail(e)}
};
$('#gif').onclick=async()=>{
 if(recorder||scrollInterval)return notify('Finish video or scrolling capture before recording GIF');
 if(gifInterval){clearInterval(gifInterval);gifInterval=null;recordStream?.getTracks().forEach(t=>t.stop());recordStream=null;
   try{if(!gifFrames.length)throw Error('No recorded GIF frames');let blob=SnipGif.encode(gifFrames,gifCanvas.width,gifCanvas.height,Math.round(1000/settings.recordFps));download(blob,downloadName('gif'));notify('Animated GIF exported · '+gifFrames.length+' frames')}catch(e){fail(e)}finally{gifFrames=[];$('#gif').innerHTML='◉ <span>GIF</span>'}return}
 try{recordStream=await getSharedScreen();const video=await videoFor(recordStream);gifCanvas=document.createElement('canvas');const scale=Math.min(1,640/video.videoWidth,480/video.videoHeight);gifCanvas.width=Math.max(2,Math.round(video.videoWidth*scale));gifCanvas.height=Math.max(2,Math.round(video.videoHeight*scale));
   gifFrames=[];const ctx=gifCanvas.getContext('2d',{willReadFrequently:true});for(let track of recordStream.getVideoTracks())track.onended=()=>{if(gifInterval)$('#gif').click()};
   gifInterval=setInterval(()=>{if(gifFrames.length>=100){$('#gif').click();return}ctx.drawImage(video,0,0,gifCanvas.width,gifCanvas.height);gifFrames.push(ctx.getImageData(0,0,gifCanvas.width,gifCanvas.height).data.slice());notify('GIF recording · '+gifFrames.length+'/100 frames')},1000/settings.recordFps);
   $('#gif').innerHTML='■ <span>Finish GIF</span>';
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
   $('#scrollAuto').textContent='▶ Record scrolling views';notify('Automatic collection stopped — '+stitchTiles.length+' tiles ready to stitch');return}
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
   $('#scrollAuto').textContent='■ Stop collecting';notify('Scroll the shared target; changed views are captured automatically')
 }catch(e){scrollStream?.getTracks().forEach(t=>t.stop());scrollStream=null;fail(e)}
};
$('#scrollAdd').onclick=async()=>{try{if(stitchTiles.length>=35)throw Error('Maximum 35 tiles');const blob=await editor.export();stitchTiles.push(await createImageBitmap(blob));$('#stitchCount').textContent=stitchTiles.length+' tiles queued';notify('Tile '+stitchTiles.length+' added — scroll the target and capture again')}catch(e){fail(e)}};
$('#scrollFinish').onclick=async()=>{try{let result=await SnipStitch.stitch(stitchTiles,{autoOverlap:$('#alignOverlap').checked});for(let im of stitchTiles)im.close?.();stitchTiles=[];$('#stitchCount').textContent='0 tiles queued';await loadImage(result.canvas.toDataURL('image/png'),'Long screenshot');notify('Stitched '+result.overlaps.length+' tiles · overlap removed '+result.overlaps.reduce((a,b)=>a+b,0)+' px')}catch(e){fail(e)}};
$('#ocr').onclick=async()=>{try{
    const blob=await editor.export(),response=await api('/api/ocr',{method:'POST',headers:{'Content-Type':'image/png'},body:blob});
    if(response.ok){let result=await response.json();$('#ocrText').value=result.text||'';notify('Windows native OCR complete');return}
    const nativeFailure=(await response.json().catch(()=>({}))).error||'Windows OCR failed';
    if(typeof TextDetector==='undefined')throw Error(nativeFailure+'; browser OCR is also unavailable');
    let image=await createImageBitmap(blob);const lines=await new TextDetector().detect(image);$('#ocrText').value=lines.map(x=>x.rawValue).join('\n');notify('Browser OCR complete');
  }catch(e){fail(e)}};
$('#copyOcr').onclick=()=>navigator.clipboard.writeText($('#ocrText').value).then(()=>notify('Text copied')).catch(fail);
$('#settingsSave').onclick=()=>{settings.namePrefix=sanitizePrefix($('#prefix').value);settings.autoLibrary=$('#autoLibrary').checked;settings.recordFps=Math.max(2,Math.min(12,parseInt($('#fps').value,10)||6));localStorage.setItem('sniphero-settings',JSON.stringify(settings));notify('Preferences saved')};
$('#prefix').value=settings.namePrefix;$('#autoLibrary').checked=settings.autoLibrary;$('#fps').value=settings.recordFps;
document.addEventListener('keydown',event=>{
  if(['INPUT','TEXTAREA'].includes(document.activeElement?.tagName))return;
  const key=event.key.toLowerCase();if(event.ctrlKey&&key==='z'){event.preventDefault();editor.undo().catch(fail)}
  else if(event.ctrlKey&&key==='y'){event.preventDefault();editor.redo().catch(fail)}
  else if(event.key==='Delete')editor.deleteSelected();
  else if(event.ctrlKey&&event.shiftKey&&key==='s'){event.preventDefault();$('#region').click()}
  else if(event.ctrlKey&&event.shiftKey&&key==='p'){event.preventDefault();$('#projectSave').click()}
});
async function diagnostics(){let native='unknown',ocr='unavailable';try{let r=await api('/api/health');if(r.ok){let d=await r.json();native=d.capture?'ready':'unavailable';ocr=d.ocr?'available':'unavailable'}}catch{}
 $('#diagnostics').textContent='Windows capture: '+native+'\nNative OCR: '+ocr+'\nBrowser record: '+(typeof MediaRecorder==='undefined'?'unavailable':'available')+'\nScreen share: '+(navigator.mediaDevices?.getDisplayMedia?'available':'unavailable')+'\nClipboard: '+(navigator.clipboard?'available':'unavailable')+'\nData remains on this computer.'}
refreshScreens();refreshWindows();refreshLibrary();diagnostics();fitZoom();
})();