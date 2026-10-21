/* Small offline animated GIF89a encoder. 3-3-2 RGB quantization and GIF LZW. */
window.SnipGif={encode(frames,width,height,delay=120){
 const bytes=[],u8=n=>bytes.push(n&255),u16=n=>{u8(n);u8(n>>8)},str=s=>{for(const c of s)u8(c.charCodeAt(0))};
 str('GIF89a');u16(width);u16(height);u8(0xf7);u8(0);u8(0);
 for(let i=0;i<256;i++){u8(((i>>5)&7)*255/7);u8(((i>>2)&7)*255/7);u8((i&3)*85)}
 u8(0x21);u8(0xff);u8(11);str('NETSCAPE2.0');u8(3);u8(1);u16(0);u8(0);
 for(const rgba of frames){u8(0x21);u8(0xf9);u8(4);u8(0);u16(Math.max(2,Math.round(delay/10)));u8(0);u8(0);u8(0x2c);u16(0);u16(0);u16(width);u16(height);u8(0);u8(8);
  const indices=new Uint8Array(width*height);for(let i=0;i<indices.length;i++){let p=i*4;indices[i]=(rgba[p]&224)|((rgba[p+1]&224)>>3)|(rgba[p+2]>>6)}
  const min=8,clear=256,end=257;let dict=new Map(),next=258,size=9,acc=0,bits=0,out=[];
  function emit(code){acc|=code<<bits;bits+=size;while(bits>=8){out.push(acc&255);acc>>>=8;bits-=8}}
  function reset(){dict.clear();next=258;size=9;emit(clear)}
  reset();let prev=String(indices[0]);for(let i=1;i<indices.length;i++){let v=indices[i],key=prev+','+v;if(dict.has(key)){prev=key;continue}let code=prev.includes(',')?dict.get(prev):Number(prev);emit(code);if(next<4096){dict.set(key,next++);if(next===(1<<size)&&size<12)size++}else{reset()}prev=String(v)}emit(prev.includes(',')?dict.get(prev):Number(prev));emit(end);if(bits)out.push(acc&255);
  for(let i=0;i<out.length;i+=255){let part=out.slice(i,i+255);u8(part.length);for(let v of part)u8(v)}u8(0);
 }
 u8(0x3b);return new Blob([new Uint8Array(bytes)],{type:'image/gif'});
}};