/* Lasso smart redaction: finds sensitive text in OCR results and returns boxes to cover.
   Input is OCR lines: [{text, words:[{text,x,y,w,h}]}] in image pixels. Runs fully offline. */
(() => {
'use strict';
function luhn(digits){let sum=0,odd=false;for(let i=digits.length-1;i>=0;i--){let d=+digits[i];if(odd){d*=2;if(d>9)d-=9}sum+=d;odd=!odd}return sum%10===0}
// Order matters: earlier kinds win when two matches overlap (an SSN is not also a phone number).
const KINDS=[
  {kind:'email',label:'Email',re:/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g},
  {kind:'ssn',label:'SSN',re:/(?<!\d)\d{3}-\d{2}-\d{4}(?!\d)/g},
  {kind:'card',label:'Card number',re:/(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)/g,check:m=>{const d=m.replace(/\D/g,'');return d.length>=13&&d.length<=19&&luhn(d)}},
  {kind:'dodid',label:'DoD ID',re:/(?<!\d)\d{10}(?!\d)/g},
  {kind:'phone',label:'Phone',re:/(?<![\d-])(?:\+?1[\s.-]?)?\(?\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}(?![\d-])/g},
  {kind:'ip',label:'IP address',re:/(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])/g,check:m=>m.split('.').every(o=>+o<=255)}
];
// Joins a line's words with single spaces and remembers where each word sits in that string.
function layout(line){
  const words=(line.words&&line.words.length?line.words:[{text:line.text||'',x:line.x,y:line.y,w:line.w,h:line.h}]).filter(w=>w&&typeof w.text==='string');
  let text='',spans=[];
  for(const w of words){if(text)text+=' ';spans.push({start:text.length,end:text.length+w.text.length,word:w});text+=w.text}
  return {text,spans};
}
function boxFor(spans,start,end,pad){
  let x0=Infinity,y0=Infinity,x1=-Infinity,y1=-Infinity;
  for(const s of spans)if(s.start<end&&s.end>start&&Number.isFinite(s.word.x)){const w=s.word;x0=Math.min(x0,w.x);y0=Math.min(y0,w.y);x1=Math.max(x1,w.x+w.w);y1=Math.max(y1,w.y+w.h)}
  if(!Number.isFinite(x0))return null;
  return {x:Math.floor(x0-pad),y:Math.floor(y0-pad),x2:Math.ceil(x1+pad),y2:Math.ceil(y1+pad)};
}
function scanLines(lines,patterns,pad){
  const found=[];
  for(const line of lines||[]){
    const {text,spans}=layout(line);const taken=[];
    for(const p of patterns){
      p.re.lastIndex=0;let m;
      while((m=p.re.exec(text))){
        if(!m[0]){p.re.lastIndex++;continue}
        const start=m.index,end=start+m[0].length;
        if(p.check&&!p.check(m[0]))continue;
        if(taken.some(t=>t.start<end&&t.end>start))continue;
        const box=boxFor(spans,start,end,pad);if(!box)continue;
        taken.push({start,end});found.push({kind:p.kind,label:p.label,text:m[0],box});
      }
    }
  }
  return found;
}
// Every built-in kind of sensitive text in the OCR result.
function detect(lines,{pad=3}={}){return scanLines(lines,KINDS,pad)}
// Every occurrence of a word or phrase, ignoring case.
function findText(lines,term,{pad=3}={}){
  const t=String(term||'').trim();if(!t)return [];
  const re=new RegExp(t.replace(/[.*+?^${}()|[\]\\]/g,'\\$&').replace(/\s+/g,'\\s+'),'gi');
  return scanLines(lines,[{kind:'term',label:'"'+t+'"',re}],pad);
}
// Turns browser TextDetector results (line boxes only) into the OCR line shape.
function fromTextDetector(results){return (results||[]).map(r=>{const b=r.boundingBox||{};return {text:r.rawValue||'',words:[{text:r.rawValue||'',x:b.x,y:b.y,w:b.width,h:b.height}]}})}
window.LassoRedact={detect,findText,fromTextDetector,kinds:KINDS.map(k=>({kind:k.kind,label:k.label}))};
})();
