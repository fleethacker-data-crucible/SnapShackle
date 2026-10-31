/* Turns the router's annotation suggestions into editor objects. Pure functions: no network, no DOM.
   The host asks the router and cleans the reply (modules/Router.ps1); positions arrive as fractions of the image. */
(() => {
'use strict';
const KINDS = ['redact', 'box', 'arrow', 'step', 'text'];
const LABELS = { redact: 'Cover', box: 'Box', arrow: 'Arrow', step: 'Step', text: 'Caption' };
const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
const px = v => Math.round(v * 10) / 10;
// Suggestions from the host are trusted only for shape: anything off is skipped, not repaired.
function usable(s) {
  return !!s && KINDS.includes(s.kind) && ['x', 'y', 'w', 'h'].every(k => typeof s[k] === 'number' && isFinite(s[k])) && s.w > 0 && s.h > 0;
}
function describe(s) {
  return (LABELS[s.kind] || s.kind) + (s.label ? ': ' + String(s.label).slice(0, 80) : '') + ' (' + Math.round(s.x * 100) + '%, ' + Math.round(s.y * 100) + '%)';
}
// One suggestion as one editor object in image pixels; step numbers continue from `counter`.
function toObject(s, width, height, counter) {
  const x = px(clamp(s.x, 0, 1) * width), y = px(clamp(s.y, 0, 1) * height);
  const x2 = px(clamp(s.x + s.w, 0, 1) * width), y2 = px(clamp(s.y + s.h, 0, 1) * height);
  switch (s.kind) {
    case 'redact': return { type: 'redact', x, y, x2, y2 };
    case 'box': return { type: 'rectangle', x, y, x2, y2 };
    case 'arrow': return { type: 'arrow', x, y, x2: px((x + x2) / 2), y2: px((y + y2) / 2) };
    case 'step': return { type: 'step', x: px((x + x2) / 2), y: px((y + y2) / 2), text: String(counter) };
    default: return { type: 'text', x, y: y2, text: String(s.label || 'Note').slice(0, 80), font: clamp(Math.round((y2 - y) / 1.22), 14, 48) };
  }
}
function toObjects(list, width, height, firstStep) {
  let counter = firstStep || 1;
  return (list || []).filter(usable).map(s => toObject(s, width, height, s.kind === 'step' ? counter++ : counter));
}
window.SnapShackleAiSuggest = { KINDS, usable, describe, toObject, toObjects };
})();
