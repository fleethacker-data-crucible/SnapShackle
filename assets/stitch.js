/* Overlap-aware vertical image stitcher; works fully offline. */
(() => {
'use strict';
function imageData(image, width, height) {
  const c=document.createElement('canvas');c.width=width;c.height=height;c.getContext('2d',{willReadFrequently:true}).drawImage(image,0,0,width,height);
  return c.getContext('2d').getImageData(0,0,width,height).data;
}
function overlapPixels(a,b,w,hA,hB){
  const max=Math.min(Math.floor(hA*.60),Math.floor(hB*.60),Math.floor(Math.min(hA,hB)*.75));
  if(max<12)return 0;
  // Compare every 3rd candidate row in downsampled images to keep this bounded.
  const stride=Math.max(1,Math.ceil(w/130));
  let best={overlap:0,score:Infinity,signal:0};
  for(let rows=12;rows<=max;rows++){let difference=0,count=0,signal=0;
    for(let j=0;j<rows;j+=3){let iyA=hA-rows+j,iyB=j;
      for(let x=0;x<w;x+=stride){let k=(iyA*w+x)*4,m=(iyB*w+x)*4;
        difference+=Math.abs(a[k]-b[m])+Math.abs(a[k+1]-b[m+1])+Math.abs(a[k+2]-b[m+2]);
        signal+=Math.abs(a[k]-a[k+1])+Math.abs(a[k+1]-a[k+2]);count+=3;
      }
    }
    let score=difference/count;
    if(score<best.score)best={overlap:rows,score,signal:signal/count};
  }
  // Ignore low-information flat regions and noisy matches.
  return best.score<7.5&&best.signal>2.5?best.overlap:0;
}
async function stitch(tiles,{autoOverlap=true,maxPixels=90000000}={}){
  if(!tiles?.length)throw Error('No tiles to stitch');
  if(tiles.length>35)throw Error('At most 35 tiles may be stitched at once');
  const width=Math.max(...tiles.map(t=>t.width));
  const overlaps=[0];let last=tiles[0];
  for(let i=1;i<tiles.length;i++){
    let current=tiles[i],matched=0;
    if(autoOverlap&&current.width===last.width){
      const scale=Math.min(1,180/width),w=Math.max(1,Math.floor(width*scale)),
        ha=Math.max(1,Math.floor(last.height*scale)),hb=Math.max(1,Math.floor(current.height*scale));
      matched=Math.round(overlapPixels(imageData(last,w,ha),imageData(current,w,hb),w,ha,hb)/scale);
    }
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
window.LassoStitch={stitch};
})();