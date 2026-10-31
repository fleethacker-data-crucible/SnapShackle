/* Converts router suggestions to editor objects. Run: node tests/aisuggest_test.js
   Pure functions, no browser and no network. */
const fs = require('fs');
const vm = require('vm');
const context = { window: {}, Math: Math, String: String, Number: Number, isFinite: isFinite };
vm.runInNewContext(fs.readFileSync(__dirname + '/../assets/aisuggest.js', 'utf8'), context);
const ai = context.window.SnapShackleAiSuggest;
function assert(condition, message) { if (!condition) throw Error(message || 'assertion failed'); }
function equal(actual, expected, message) { const a = JSON.stringify(actual), b = JSON.stringify(expected); if (a !== b) throw Error((message || 'not equal') + ': ' + a + ' vs ' + b); }

assert(JSON.stringify(ai.KINDS) === JSON.stringify(['redact', 'box', 'arrow', 'step', 'text']), 'kinds');
const s = (kind, extra) => Object.assign({ kind, x: 0.1, y: 0.2, w: 0.3, h: 0.1, label: 'why' }, extra || {});
equal(ai.toObject(s('redact'), 1000, 500, 1), { type: 'redact', x: 100, y: 100, x2: 400, y2: 150 }, 'redact');
equal(ai.toObject(s('box'), 1000, 500, 1), { type: 'rectangle', x: 100, y: 100, x2: 400, y2: 150 }, 'box');
equal(ai.toObject(s('arrow'), 1000, 500, 1), { type: 'arrow', x: 100, y: 100, x2: 250, y2: 125 }, 'arrow points at the middle of the region');
equal(ai.toObject(s('step'), 1000, 500, 4), { type: 'step', x: 250, y: 125, text: '4' }, 'step');
const text = ai.toObject(s('text', { label: 'Click here' }), 1000, 500, 1);
assert(text.type === 'text' && text.text === 'Click here' && text.y === 150 && text.font >= 14 && text.font <= 48, 'text');

const list = [s('step'), s('explode'), s('box', { w: 0 }), s('box', { x: 'a' }), s('step', { x: 0.5 }), null, s('redact', { w: NaN })];
const objects = ai.toObjects(list, 1000, 500, 3);
equal(objects.map(o => o.type), ['step', 'step'], 'only usable suggestions become objects');
equal(objects.map(o => o.text), ['3', '4'], 'step numbers continue from the counter');
const clamped = ai.toObject(s('box', { x: 0.9, y: 0.9, w: 0.9, h: 0.9 }), 1000, 500, 1);
assert(clamped.x2 === 1000 && clamped.y2 === 500, 'a box past the edge is clamped to the image');
assert(ai.describe(s('redact', { label: 'email' })) === 'Cover: email (10%, 20%)', 'describe: ' + ai.describe(s('redact', { label: 'email' })));
assert(ai.toObjects(null, 10, 10).length === 0, 'null list');
console.log('PASS: router suggestions become editor objects, clamped, numbered and filtered');
