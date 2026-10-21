/* Dependency-free GIF89a encoder. Fixed-width LZW packets with periodic clear codes.
   A conservative approach: larger than optimized GIFs, but valid across decoders. */
(() => {
'use strict';
window.SnipGif={encode(frames,width,height,delay=150){
 if(!Number.isInteger(width)||!Number.isInteger(height)||width<1||height<1||width>640||height>480||!frames.length||frames.length>100)throw Error('GIF dimensions or frame count exceed safe limits');
 const parts=[],write=n=>parts.push(n&255),write16=n=>{write(n);write(n>>>8)},writeStr=s=>{for(let i=0;i<s.length;i++)write(s.charCodeAt(i))};
 writeStr('GIF89a');write16(width);write16(height);write(0xF7);write(0);write(0);
 for(let i=0;i<256;i++){write(Math.round(((i>>5)&7)*255/7));write(Math.round(((i>>2)&7)*255/7));write((i&3)*85)}
 write(0x21);write(0xFF);write(11);writeStr('NETSCAPE2.0');write(3);write(1);write16(0);write(0);
 for(const rgba of frames){
  if(rgba.length!==width*height*4)throw Error('Incorrect GIF frame dimensions');
  write(0x21);write(0xF9);write(4);write(0);write16(Math.max(2,Math.round(delay/10)));write(0);write(0);
  write(0x2C);write16(0);write16(0);write16(width);write16(height);write(0);write(8);
  let result=[],acc=0,bits=0;const emit=code=>{acc|=(code<<bits);bits+=9;while(bits>=8){result.push(acc&255);acc>>>=8;bits-=8}};
  const clear=256,end=257;emit(clear);
  for(let i=0;i<width*height;i++){
   // Clear before the decoder's dictionary reaches a 10-bit code width.
   if(i!==0&&i%200===0)emit(clear);
   const p=i*4;emit((rgba[p]&0xE0)|((rgba[p+1]&0xE0)>>>3)|(rgba[p+2]>>>6));
  }
  emit(end);if(bits)result.push(acc&255);
  for(let pos=0;pos<result.length;pos+=255){const block=result.slice(pos,pos+255);write(block.length);for(let v of block)write(v)}write(0);
 }
 write(0x3B);return new Blob([Uint8Array.from(parts)],{type:'image/gif'});
}};
})();