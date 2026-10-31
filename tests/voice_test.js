/* Voice notes on annotations: recording rules, limits, release of the microphone, and clean-up of untrusted notes.
   Run: node tests/voice_test.js
   Uses fakes only: no browser, no microphone, nothing leaves the process. */
const fs = require('fs');
const vm = require('vm');
const context = { window: {}, Blob, btoa, Uint8Array, Math, String, Error, Object, Promise, isFinite, Number, console };
vm.runInNewContext(fs.readFileSync(__dirname + '/../assets/voice.js', 'utf8'), context);
const voice = context.window.SnapShackleVoice;

function assert(condition, message) { if (!condition) throw Error(message || 'assertion failed'); }
function equal(actual, expected, message) { const a = JSON.stringify(actual), b = JSON.stringify(expected); if (a !== b) throw Error((message || 'not equal') + ': ' + a + ' vs ' + b); }
async function rejects(promise, pattern, message) {
  let text = null;
  try { await promise; } catch (error) { text = error.message; }
  assert(text !== null && pattern.test(text), (message || 'should reject') + ' (got ' + text + ')');
}

// A fake microphone and recorder.
function makeEnv(options = {}) {
  const env = { stopped: 0, timers: [], clock: 1000, bytes: options.bytes || Uint8Array.from([1, 2, 3, 250, 251, 252]) };
  const track = { stop() { env.stopped++; } };
  env.getUserMedia = async () => { if (options.deny) { const e = new Error('no'); e.name = options.deny; throw e; } return { getTracks: () => [track] }; };
  env.MediaRecorder = class {
    constructor() { if (options.recorderThrows) throw new Error('no recorder'); this.state = 'inactive'; env.recorder = this; }
    start() { this.state = 'recording'; }
    stop() {
      if (this.state === 'inactive') return;
      this.state = 'inactive';
      this.ondataavailable({ data: new Blob([env.bytes]) });
      Promise.resolve().then(() => this.onstop());
    }
  };
  env.isTypeSupported = type => (options.types || ['audio/webm;codecs=opus']).includes(type);
  env.now = () => env.clock;
  env.setTimeout = (fn, ms) => { env.timers.push({ fn, ms }); return env.timers.length; };
  env.clearTimeout = () => {};
  return env;
}

(async () => {
  equal(voice.pickMime(t => t === 'audio/webm'), 'audio/webm', 'falls back to plain webm');
  equal(voice.pickMime(() => false), '', 'no supported type');
  equal(voice.LIMITS, { maxMs: 60000, maxBytes: 700000 }, 'limits');
  equal(voice.formatDuration(65000), '1:05', 'duration text');
  equal(voice.describe({ ms: 12000 }), 'Voice note 0:12', 'describe');
  equal(voice.describe(null), 'No voice note', 'describe none');

  // Refusals leave nothing open.
  await rejects(voice.start(makeEnv({ types: [] })), /cannot record/, 'unsupported browser');
  await rejects(voice.start(makeEnv({ deny: 'NotAllowedError' })), /not allowed/, 'permission refused');
  await rejects(voice.start(makeEnv({ deny: 'NotFoundError' })), /No microphone/, 'no microphone');
  const throwing = makeEnv({ recorderThrows: true });
  await rejects(voice.start(throwing), /could not start/, 'recorder cannot start');
  assert(throwing.stopped === 1, 'the microphone must be released when the recorder cannot start');

  // A normal recording: the note holds the bytes, and the microphone is released.
  const env = makeEnv();
  const session = await voice.start(env);
  assert(env.recorder.state === 'recording' && env.timers[0].ms === 60000, 'recording with a 60 s limit');
  env.clock += 3400;
  const note = await session.stop();
  assert(env.stopped === 1, 'the microphone must be released on stop');
  equal([note.mime, note.ms], ['audio/webm;codecs=opus', 3400], 'note mime and length');
  equal(Array.from(Buffer.from(note.data, 'base64')), [1, 2, 3, 250, 251, 252], 'the note keeps the recorded bytes');
  assert(voice.validate(note), 'a fresh note validates');
  assert(voice.toDataUrl(note).startsWith('data:audio/webm;codecs=opus;base64,'), 'data url');
  equal(voice.extensionFor(note), 'webm', 'extension');

  // The time limit stops the recording by itself and caps the length.
  const timed = makeEnv();
  const s2 = await voice.start(timed);
  timed.clock += 90000;
  timed.timers[0].fn();
  const capped = await s2.stop();
  assert(capped.ms === 60000 && timed.stopped === 1, 'auto-stop caps at 60 s and releases the microphone');

  // Cancel keeps nothing.
  const cancelled = makeEnv();
  const s3 = await voice.start(cancelled);
  equal(await s3.cancel(), null, 'cancel returns no note');
  assert(cancelled.stopped === 1, 'cancel releases the microphone');

  // Too big to keep.
  const big = makeEnv({ bytes: new Uint8Array(voice.LIMITS.maxBytes + 10) });
  const s4 = await voice.start(big);
  await rejects(s4.stop(), /too long/, 'oversized clip');
  assert(big.stopped === 1, 'oversized clip still releases the microphone');

  // Notes from a project file are untrusted.
  const good = { mime: 'audio/webm', ms: 2000, data: 'AQID' };
  assert(voice.validate(good), 'good note');
  for (const bad of [null, 'x', {}, { ...good, mime: 'text/html' }, { ...good, mime: 'audio/webm; <script>' }, { ...good, ms: -1 }, { ...good, ms: 1e9 }, { ...good, ms: NaN },
    { ...good, data: '' }, { ...good, data: 'not base64!' }, { ...good, data: 'A'.repeat(1000000) }, { ...good, data: 5 }]) {
    assert(!voice.validate(bad), 'accepted ' + JSON.stringify(bad).slice(0, 60));
  }
  equal(voice.sanitizeObject({ type: 'box', x: 1 }), { type: 'box', x: 1 }, 'object without a note is untouched');
  equal(voice.sanitizeObject({ type: 'box', voice: { ...good, extra: 'x' } }), { type: 'box', voice: good }, 'unknown fields are dropped from a note');
  equal(voice.sanitizeObject({ type: 'box', voice: { ...good, mime: 'text/html' } }), { type: 'box' }, 'a bad note is removed from its annotation');
  equal(voice.sanitizeObject(null), null, 'null');
  console.log('PASS: voice notes record locally with fakes, stop at the limit, release the microphone, and bad notes are dropped');
})().catch(error => { console.error('FAIL: ' + error.message); process.exit(1); });
