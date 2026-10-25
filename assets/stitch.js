/* Overlap-aware vertical image stitcher; works fully offline.
   Overlaps are found in two passes: a coarse search on a ~180px-wide downscale,
   then an exact search at full resolution around the coarse answer. Matching uses
   luminance, so black-on-white text pages (the common case) stitch correctly. */
(() => {
'use strict';
function pixels(image, width, height) {
  const c=document.createElement('canvas');c.width=width;c.height=height;
  const ctx=c.getContext('2d',{willReadFrequently:true});ctx.drawImage(image,0,0,width,height);
  const rgba=ctx.getImageData(0,0,width,height).data,luma=new Float32Array(width*height);
  for(let i=0,j=0;j<luma.length;i+=4,j++)luma[j]=rgba[i]*.299+rgba[i+1]*.587+rgba[i+2]*.114;
  return luma;
}
// Mean absolute luminance difference between the bottom `rows` of A and the top `rows` of B,
// plus the detail (horizontal + vertical gradient) of that band in A. Flat bands have no detail.
function compare(a,b,w,hA,rows,rowStep,colStep){
  let difference=0,detail=0,count=0;
  for(let j=0;j<rows;j+=rowStep){
    const ya=(hA-rows+j)*w,yb=j*w,below=j+1<rows?w:0;
    for(let x=0;x+1<w;x+=colStep){
      const va=a[ya+x];
      difference+=Math.abs(va-b[yb+x]);
      detail+=Math.abs(va-a[ya+x+1])+Math.abs(va-a[ya+x+below]);
      count++;
    }
  }
  return count?{score:difference/count,detail:detail/count}:{score:Infinity,detail:0};
}
// Ratio of mismatch to detail: about 0 for a true match, near or above 1 for a wrong one.
// Using a ratio (not a raw difference) stops mostly-white bands from looking like matches.
function rank(r){return r.detail>0?r.score/r.detail:Infinity}
function scan(a,b,w,hA,from,to,rowStep,colStep){
  const out=[];
  for(let rows=Math.max(1,from);rows<=to;rows++){const r=compare(a,b,w,hA,rows,rowStep,colStep);out.push({overlap:rows,...r,ratio:rank(r)})}
  return out;
}
function maxOverlap(hA,hB){return Math.min(Math.floor(hA*.8),Math.floor(hB*.8))}
const MAX_RATIO=.2,MIN_DETAIL=1.5,CANDIDATES=8;
function findOverlap(last,current){
  const width=last.width,limit=maxOverlap(last.height,current.height);
  if(limit<12)return 0;
  const scale=Math.min(1,180/width),w=Math.max(2,Math.floor(width*scale)),
    ha=Math.max(2,Math.floor(last.height*scale)),hb=Math.max(2,Math.floor(current.height*scale));
  const coarse=scan(pixels(last,w,ha),pixels(current,w,hb),w,ha,Math.max(4,Math.floor(12*scale)),maxOverlap(ha,hb),1,1)
    .filter(c=>c.detail>MIN_DETAIL*.5).sort((x,y)=>x.ratio-y.ratio);
  // Repeating content (lines of text, table rows) gives several coarse minima; refine each.
  const picks=[];
  for(const c of coarse){if(picks.length>=CANDIDATES)break;if(picks.every(p=>Math.abs(p.overlap-c.overlap)>1))picks.push(c)}
  if(!picks.length)return 0;
  const a=pixels(last,width,last.height),b=pixels(current,width,current.height);
  const slack=Math.ceil(1/scale)+2,colStep=Math.max(1,Math.floor(width/480));
  let best=null;
  for(const c of picks){
    const guess=Math.round(c.overlap/scale);
    for(const r of scan(a,b,width,last.height,Math.max(12,guess-slack),Math.min(limit,guess+slack),1,colStep))
      if(r.detail>MIN_DETAIL&&(!best||r.ratio<best.ratio))best=r;
  }
  return best&&best.ratio<MAX_RATIO?best.overlap:0;
}
async function stitch(tiles,{autoOverlap=true,maxPixels=90000000}={}){
  if(!tiles?.length)throw Error('No tiles to stitch');
  if(tiles.length>35)throw Error('At most 35 tiles may be stitched at once');
  const width=Math.max(...tiles.map(t=>t.width));
  const overlaps=[0];let last=tiles[0];
  for(let i=1;i<tiles.length;i++){
    const current=tiles[i];
    const matched=autoOverlap&&current.width===last.width?findOverlap(last,current):0;
    overlaps.push(Math.min(matched,current.height-1));last=current;
  }
  const height=tiles.reduce((sum,t,i)=>sum+t.height-overlaps[i],0);
  if(width*height>maxPixels)throw Error('Combined capture is too large; use fewer tiles');
  const canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;
  const ctx=canvas.getContext('2d');ctx.fillStyle='white';ctx.fillRect(0,0,width,height);
  let y=0;
  for(let i=0;i<tiles.length;i++){
    const im=tiles[i],skip=overlaps[i];ctx.drawImage(im,0,skip,im.width,im.height-skip,0,y,im.width,im.height-skip);y+=im.height-skip;
  }
  return {canvas,overlaps,width,height};
}
window.CutterMkStitch={stitch,_findOverlap:findOverlap};
})();
