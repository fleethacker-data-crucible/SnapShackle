const fs=require('fs'),vm=require('vm');const context={window:{},Uint8Array,Blob,Map,Math,String,Number};
vm.runInNewContext(fs.readFileSync(__dirname+'/../assets/gif.js','utf8'),context);
(async()=>{
  const w=64,h=48,frames=[];
  for(let f=0;f<4;f++){const data=new Uint8ClampedArray(w*h*4);
    for(let y=0;y<h;y++)for(let x=0;x<w;x++){let i=(y*w+x)*4;data[i]=(x*9+f*17)%256;data[i+1]=(y*7+f*19)%256;data[i+2]=((x+y)*3+f*33)%256;data[i+3]=255}
    frames.push(data)}
  const blob=context.window.CutterMkGif.encode(frames,w,h,130);
  fs.writeFileSync(__dirname+'/sample.gif',Buffer.from(await blob.arrayBuffer()));
  console.log('GIF encoded',blob.size,'bytes');
})();