/* SnapShackle canvas object editor. No dependencies, no network calls. */
(() => {
'use strict';
const clone = value => JSON.parse(JSON.stringify(value));
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
const distance = (a,b) => Math.hypot(a.x-b.x,a.y-b.y);
class SnapShackleEditor {
  constructor(canvas, onChange=()=>{}) {
    this.canvas=canvas; this.ctx=canvas.getContext('2d',{alpha:false});
    this.onChange=onChange; this.background=null; this._img=null; this.objects=[];
    this.selected=-1; this.tool='select'; this.color='#ff465c'; this.width=4; this.font=26;
    this.zoom=1; this.counter=1; this.undoStack=[]; this.redoStack=[]; this.drag=null;
    this.maxHistory=35; this._blobUrls=new Set(); this.bind(); this.render();
  }
  state(){return {version:3,background:this.background,width:this.canvas.width,height:this.canvas.height,objects:clone(this.objects),counter:this.counter}}
  serialize(){return this.state()}
  saveHistory(previous=this.state()) {
    this.undoStack.push(previous);
    if(this.undoStack.length>this.maxHistory)this.undoStack.shift();
    this.redoStack=[];
    this.pruneBackgroundURLs();
  }
  pruneBackgroundURLs(){
    const active=new Set([this.background,...this.undoStack.map(x=>x.background),...this.redoStack.map(x=>x.background)]);
    for(const url of this._blobUrls)if(!active.has(url)){URL.revokeObjectURL(url);this._blobUrls.delete(url)}
  }
  // Data URL conversion happens only when the user explicitly saves an editable project.
  // Normal captures and editor history retain the compressed original Blob without Base64 copies.
  async portableProject(){
    const project=this.serialize();
    if(project.background?.startsWith('blob:')){
      if(!this._blobUrls.has(project.background))throw Error('Background image no longer available');
      const blob=await fetch(project.background).then(response=>response.blob());
      project.background=await new Promise((resolve,reject)=>{
        const reader=new FileReader();reader.onload=()=>resolve(reader.result);reader.onerror=()=>reject(reader.error);reader.readAsDataURL(blob);
      });
    }
    if(project.background?.length>60_000_000)throw Error('Editable project exceeds the 60 MB image limit. Export flattened PNG instead.');
    return project;
  }
  async restore(state){
    if(!state||![2,3].includes(state.version)||!Array.isArray(state.objects)||state.objects.length>2000||!Number.isInteger(state.width)||!Number.isInteger(state.height)||state.width<1||state.height<1||state.width*state.height>100000000) throw Error('Project format or image dimensions unsupported');
    let image=null;
    if(state.background){if(typeof state.background!=='string'||!(state.background.startsWith('data:image/')&&state.background.length<=60_000_000)&&!this._blobUrls.has(state.background))throw Error('Invalid background image');image=await this._image(state.background)}
    this.background=state.background||null; this._img=image; this.canvas.width=state.width;this.canvas.height=state.height;
    this.objects=clone(state.objects);this.counter=state.counter||1;this.selected=-1;this.drag=null;this.render();
  }
  async load(state){const prev=this.state();await this.restore(state);this.saveHistory(prev)}
  async undo(){if(!this.undoStack.length)return;let old=this.undoStack.pop(),current=this.state();await this.restore(old);this.redoStack.push(current)}
  async redo(){if(!this.redoStack.length)return;let next=this.redoStack.pop(),current=this.state();await this.restore(next);this.undoStack.push(current)}
  _image(src){return new Promise((resolve,reject)=>{let i=new Image();i.onload=()=>resolve(i);i.onerror=()=>reject(Error('Image cannot be loaded'));i.src=src})}
  async setBackground(source){
    let src=source,objectURL=null;
    if(source instanceof Blob){
      if(source.size>60_000_000)throw Error('Image file exceeds 60 MB');
      src=objectURL=URL.createObjectURL(source);
    }
    let image;
    try {
      image=await this._image(src);
      if(image.naturalWidth*image.naturalHeight>100000000)throw Error('Image is too large');
    } catch(error){if(objectURL)URL.revokeObjectURL(objectURL);throw error}
    const old=this.state();
    if(objectURL)this._blobUrls.add(objectURL);
    this.background=src;this._img=image;
    this.canvas.width=image.naturalWidth;this.canvas.height=image.naturalHeight;
    this.objects=[];this.selected=-1;this.counter=1;
    this.saveHistory(old);this.render();
  }
  point(e){const r=this.canvas.getBoundingClientRect();return {x:(e.clientX-r.left)*this.canvas.width/r.width,y:(e.clientY-r.top)*this.canvas.height/r.height}}
  bounds(o){
    if(o.type==='pen'||o.type==='highlight'){let p=o.points||[{x:o.x,y:o.y}];return {x:Math.min(...p.map(v=>v.x)),y:Math.min(...p.map(v=>v.y)),w:Math.max(1,Math.max(...p.map(v=>v.x))-Math.min(...p.map(v=>v.x))),h:Math.max(1,Math.max(...p.map(v=>v.y))-Math.min(...p.map(v=>v.y)))}}
    if(o.type==='text'){this.ctx.font=`700 ${o.font||26}px Segoe UI`;return {x:o.x,y:o.y-(o.font||26),w:Math.max(18,this.ctx.measureText(o.text||'').width),h:(o.font||26)*1.22}}
    if(o.type==='step')return {x:o.x-22,y:o.y-22,w:44,h:44};
    const x2=o.x2??o.x+1,y2=o.y2??o.y+1;
    return {x:Math.min(o.x,x2),y:Math.min(o.y,y2),w:Math.max(1,Math.abs(x2-o.x)),h:Math.max(1,Math.abs(y2-o.y))};
  }
  hit(p){for(let i=this.objects.length-1;i>=0;i--){let b=this.bounds(this.objects[i]),m=12;if(p.x>=b.x-m&&p.x<=b.x+b.w+m&&p.y>=b.y-m&&p.y<=b.y+b.h+m)return i}return -1}
  handles(o){let b=this.bounds(o);return [{name:'nw',x:b.x,y:b.y},{name:'ne',x:b.x+b.w,y:b.y},{name:'se',x:b.x+b.w,y:b.y+b.h},{name:'sw',x:b.x,y:b.y+b.h}]}
  onHandle(p,o){for(let h of this.handles(o))if(distance(h,p)<12)return h.name;return null}
  translate(o,dx,dy){o.x+=dx;o.y+=dy;if(typeof o.x2==='number'){o.x2+=dx;o.y2+=dy}if(o.points)o.points=o.points.map(p=>({x:p.x+dx,y:p.y+dy}))}
  resize(o,orig,handle,p){
    const b=this.bounds(orig),left=handle.includes('w')?p.x:b.x,top=handle.includes('n')?p.y:b.y,
      right=handle.includes('e')?p.x:b.x+b.w,bottom=handle.includes('s')?p.y:b.y+b.h;
    const rect={x:Math.min(left,right),y:Math.min(top,bottom),w:Math.max(2,Math.abs(right-left)),h:Math.max(2,Math.abs(bottom-top))};
    // Every drawn shape carries a one-point `points` list; only freehand strokes are scaled through it.
    if(orig.points&&(orig.type==='pen'||orig.type==='highlight')){o.points=orig.points.map(q=>({x:rect.x+(q.x-b.x)*rect.w/b.w,y:rect.y+(q.y-b.y)*rect.h/b.h}));o.x=rect.x;o.y=rect.y}
    else if(orig.type==='step'){o.x=rect.x+rect.w/2;o.y=rect.y+rect.h/2}
    else if(orig.type==='text'){o.x=rect.x;o.y=rect.y+rect.h;o.font=clamp(Math.round(rect.h/1.22),10,200)}
    else {o.x=rect.x;o.y=rect.y;o.x2=rect.x+rect.w;o.y2=rect.y+rect.h}
  }
  bind(){
    this.canvas.addEventListener('pointerdown',e=>{
      if(e.button!==0)return;
      const p=this.point(e);this.canvas.setPointerCapture(e.pointerId);
      if(this.tool==='select'){
        let handle=this.selected>=0?this.onHandle(p,this.objects[this.selected]):null;
        if(!handle)this.selected=this.hit(p);
        this.drag=this.selected<0?null:{kind:handle?'resize':'move',handle,start:p,before:this.state(),original:clone(this.objects[this.selected])};
        this.render();return;
      }
      if(this.tool==='text'||this.tool==='step'){
        const t=this.tool==='step'?String(this.counter++):prompt('Annotation text');
        if(t){let old=this.state();this.objects.push({type:this.tool,x:p.x,y:p.y,text:t,color:this.color,font:this.font,width:this.width});this.selected=this.objects.length-1;this.saveHistory(old);this.render()}return;
      }
      this.drag={kind:'draw',start:p,before:this.state(),object:{type:this.tool,x:p.x,y:p.y,x2:p.x,y2:p.y,width:this.width,color:this.color,points:[p]}};
    });
    this.canvas.addEventListener('pointermove',e=>{
      if(!this.drag)return;const p=this.point(e),d=this.drag;
      if(d.kind==='move'){const i=this.selected;if(i<0)return;let o=clone(d.original);this.translate(o,p.x-d.start.x,p.y-d.start.y);this.objects[i]=o}
      if(d.kind==='resize'){const i=this.selected;if(i<0)return;let o=clone(d.original);this.resize(o,d.original,d.handle,p);this.objects[i]=o}
      if(d.kind==='draw'){d.object.x2=p.x;d.object.y2=p.y;if(['pen','highlight'].includes(this.tool))d.object.points.push(p)}
      this.render();
    });
    this.canvas.addEventListener('pointerup',()=>{
      const d=this.drag;if(!d)return;
      if(d.kind==='draw'&&d.object.type==='crop'){
        const b=this.bounds(d.object);this.drag=null;this.render();
        if(b.w>4&&b.h>4)this.crop(b.x,b.y,b.w,b.h).then(()=>this.onCrop?.(this)).catch(e=>this.onCrop?.(this,e));
        return;
      }
      if(d.kind==='draw'){
        if(distance(d.start,{x:d.object.x2,y:d.object.y2})>2||d.object.points.length>2){this.objects.push(d.object);this.selected=this.objects.length-1;this.saveHistory(d.before)}
      }else if(JSON.stringify(d.original)!==JSON.stringify(this.objects[this.selected]))this.saveHistory(d.before);
      this.drag=null;this.render();
    });
    this.canvas.addEventListener('pointercancel',()=>{if(this.drag){if(this.drag.kind!=='draw')this.objects[this.selected]=this.drag.original;this.drag=null;this.render()}});
  }
  changeSelected(mutator){if(this.selected<0)return;const before=this.state();mutator(this.objects[this.selected]);this.saveHistory(before);this.render()}
  // Adds several objects as one undoable step (used by smart redaction).
  addObjects(list){if(!list?.length)return 0;const before=this.state();for(const o of list)this.objects.push(o);this.selected=-1;this.saveHistory(before);this.render();return list.length}
  deleteSelected(){if(this.selected<0)return;let before=this.state();this.objects.splice(this.selected,1);this.selected=-1;this.saveHistory(before);this.render()}
  duplicateSelected(){if(this.selected<0)return;let before=this.state(),o=clone(this.objects[this.selected]);this.translate(o,22,22);this.objects.push(o);this.selected=this.objects.length-1;this.saveHistory(before);this.render()}
  layerSelected(delta){let i=this.selected,j=i+delta;if(i<0||j<0||j>=this.objects.length)return;let before=this.state();[this.objects[i],this.objects[j]]=[this.objects[j],this.objects[i]];this.selected=j;this.saveHistory(before);this.render()}
  // Crops the background only and moves annotations with it, so they stay editable.
  async crop(x,y,w,h){
    x=Math.round(x);y=Math.round(y);w=Math.round(w);h=Math.round(h);
    const x0=clamp(x,0,this.canvas.width),y0=clamp(y,0,this.canvas.height);
    w=Math.min(x+w,this.canvas.width)-x0;h=Math.min(y+h,this.canvas.height)-y0;
    if(w<2||h<2||w*h>100000000)throw Error('Invalid crop dimensions');
    const old=this.state(),off=document.createElement('canvas');off.width=w;off.height=h;
    const ctx=off.getContext('2d');ctx.fillStyle='#fff';ctx.fillRect(0,0,w,h);if(this._img)ctx.drawImage(this._img,-x0,-y0);
    const blob=await new Promise((resolve,reject)=>off.toBlob(b=>b?resolve(b):reject(Error('Crop failed')),'image/png'));
    const url=URL.createObjectURL(blob);let image;
    try{image=await this._image(url)}catch(e){URL.revokeObjectURL(url);throw e}
    this._blobUrls.add(url);this._img=image;this.background=url;this.canvas.width=w;this.canvas.height=h;
    for(const o of this.objects)this.translate(o,-x0,-y0);
    this.selected=-1;this.saveHistory(old);this.render();
  }
  render(clean=false){
    const c=this.ctx,W=this.canvas.width,H=this.canvas.height;c.save();c.setTransform(1,0,0,1,0,0);c.clearRect(0,0,W,H);c.fillStyle='#fff';c.fillRect(0,0,W,H);
    if(this._img)c.drawImage(this._img,0,0,W,H);
    for(let o of this.objects)this.paint(c,o);
    if(this.drag?.kind==='draw')this.paint(c,this.drag.object);
    if(!clean&&this.selected>=0&&this.objects[this.selected])this.drawSelection(c,this.objects[this.selected]);
    c.restore();this.onChange(this);
  }
  paint(c,o){
    const b=this.bounds(o);c.save();c.strokeStyle=o.color||'#ff465c';c.fillStyle=o.color||'#ff465c';c.lineWidth=o.width||4;c.lineCap='round';c.lineJoin='round';
    switch(o.type){
      case 'rectangle': c.strokeRect(b.x,b.y,b.w,b.h);break;
      case 'ellipse':c.beginPath();c.ellipse(b.x+b.w/2,b.y+b.h/2,Math.max(1,b.w/2),Math.max(1,b.h/2),0,0,Math.PI*2);c.stroke();break;
      case 'line':case 'arrow':{
        c.beginPath();c.moveTo(o.x,o.y);c.lineTo(o.x2,o.y2);c.stroke();
        if(o.type==='arrow'){let a=Math.atan2(o.y2-o.y,o.x2-o.x),len=Math.max(12,(o.width||4)*4);c.beginPath();c.moveTo(o.x2,o.y2);c.lineTo(o.x2-len*Math.cos(a-0.5),o.y2-len*Math.sin(a-0.5));c.lineTo(o.x2-len*Math.cos(a+0.5),o.y2-len*Math.sin(a+0.5));c.closePath();c.fill()}break;
      }
      case 'pen':case 'highlight':{
        if(o.type==='highlight'){c.globalAlpha=0.3;c.lineWidth=Math.max(12,(o.width||4)*5)}
        let points=o.points||[];c.beginPath();points.forEach((p,i)=>i?c.lineTo(p.x,p.y):c.moveTo(p.x,p.y));c.stroke();break;
      }
      case 'text':c.font=`700 ${o.font||26}px Segoe UI, sans-serif`;c.fillText(o.text||'',o.x,o.y);break;
      case 'step':c.beginPath();c.arc(o.x,o.y,21,0,Math.PI*2);c.fill();c.strokeStyle='white';c.lineWidth=2;c.stroke();c.fillStyle='white';c.textAlign='center';c.textBaseline='middle';c.font='bold 22px Segoe UI';c.fillText(o.text||'1',o.x,o.y);break;
      case 'redact':c.fillStyle='#0b0b0d';c.fillRect(b.x,b.y,b.w,b.h);break;
      case 'crop':{const W=this.canvas.width,H=this.canvas.height;c.fillStyle='rgba(8,10,16,.55)';
        c.fillRect(0,0,W,b.y);c.fillRect(0,b.y+b.h,W,H-b.y-b.h);c.fillRect(0,b.y,b.x,b.h);c.fillRect(b.x+b.w,b.y,W-b.x-b.w,b.h);
        c.setLineDash([8,6]);c.strokeStyle='#fff';c.lineWidth=Math.max(1,W/900);c.strokeRect(b.x,b.y,b.w,b.h);c.setLineDash([]);break}
      case 'pixelate':case 'blur':this.paintEffect(c,b,o.type);break;
    }c.restore();
  }
  paintEffect(c,b,type){
    // Snapshot already-composited pixels BEFORE changing them. Re-rendering never compounds the effect.
    const x=clamp(Math.floor(b.x),0,this.canvas.width),y=clamp(Math.floor(b.y),0,this.canvas.height),
          w=Math.min(Math.ceil(b.w),this.canvas.width-x),h=Math.min(Math.ceil(b.h),this.canvas.height-y);
    if(w<2||h<2)return;
    const off=document.createElement('canvas');off.width=w;off.height=h;
    off.getContext('2d').drawImage(this.canvas,x,y,w,h,0,0,w,h);
    c.beginPath();c.rect(x,y,w,h);c.clip();
    if(type==='pixelate'){
      const mini=document.createElement('canvas');mini.width=Math.max(1,Math.ceil(w/14));mini.height=Math.max(1,Math.ceil(h/14));
      mini.getContext('2d').drawImage(off,0,0,mini.width,mini.height);c.imageSmoothingEnabled=false;c.drawImage(mini,x,y,w,h);c.imageSmoothingEnabled=true;
    }else{
      // Sample a margin around the region at 1:1 scale so the blur has real neighbours at its
      // edges. (Stretching the snapshot into a larger box shifted and scaled the content.)
      const pad=18,W=this.canvas.width,H=this.canvas.height,sx=Math.max(0,x-pad),sy=Math.max(0,y-pad),
            sw=Math.min(W,x+w+pad)-sx,sh=Math.min(H,y+h+pad)-sy,wide=document.createElement('canvas');
      wide.width=sw;wide.height=sh;wide.getContext('2d').drawImage(this.canvas,sx,sy,sw,sh,0,0,sw,sh);
      c.filter='blur(9px)';c.drawImage(wide,sx,sy);c.filter='none';
    }
  }
  drawSelection(c,o){const b=this.bounds(o);c.save();c.setLineDash([6,5]);c.strokeStyle='#31c5ff';c.lineWidth=2;c.strokeRect(b.x-5,b.y-5,b.w+10,b.h+10);c.setLineDash([]);for(const p of this.handles(o)){c.fillStyle='#fff';c.fillRect(p.x-5,p.y-5,10,10);c.strokeRect(p.x-5,p.y-5,10,10)}c.restore()}
  async export(type='image/png'){
    // Render without selection handles; always restore the selected view even if conversion fails.
    this.render(true);
    try {const blob=await new Promise((resolve,reject)=>this.canvas.toBlob(v=>v?resolve(v):reject(Error('Image export failed')),type,0.92));return blob}
    finally {this.render(false)}
  }
}
window.SnapShackleEditor=SnapShackleEditor;
})();