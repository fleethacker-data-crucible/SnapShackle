/* Voice notes on annotations. Local only: the microphone is opened when the person presses Record, the sound is
   kept as a short Opus/WebM clip on the annotation in this browser (and in an editable project they save), and
   nothing here uploads audio or opens a socket. The microphone is released as soon as recording stops. */
(() => {
'use strict';
const LIMITS = { maxMs: 60000, maxBytes: 700000 };
const MIME_CANDIDATES = ['audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus', 'audio/ogg'];
const ALLOWED_MIME = /^audio\/(webm|ogg)(;codecs=opus)?$/;
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/;

function pickMime(isSupported) {
  for (const type of MIME_CANDIDATES) { try { if (isSupported(type)) return type; } catch (e) { /* try the next */ } }
  return '';
}
function formatDuration(ms) {
  const s = Math.max(0, Math.round(ms / 1000));
  return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0');
}
function describe(note) { return note ? 'Voice note ' + formatDuration(note.ms) : 'No voice note'; }
// A note is {mime, ms, data}: data is base64 of the audio bytes. Anything that does not fit is dropped, because a
// project file is untrusted input.
function validate(note) {
  if (!note || typeof note !== 'object') return false;
  if (typeof note.mime !== 'string' || !ALLOWED_MIME.test(note.mime)) return false;
  if (typeof note.ms !== 'number' || !isFinite(note.ms) || note.ms < 0 || note.ms > LIMITS.maxMs + 1500) return false;
  if (typeof note.data !== 'string' || !note.data.length || note.data.length > Math.ceil(LIMITS.maxBytes * 4 / 3) + 8 || !BASE64.test(note.data)) return false;
  return true;
}
function sanitizeObject(object) {
  if (!object || typeof object !== 'object' || !('voice' in object)) return object;
  const copy = Object.assign({}, object);
  if (validate(copy.voice)) copy.voice = { mime: copy.voice.mime, ms: Math.round(copy.voice.ms), data: copy.voice.data };
  else delete copy.voice;
  return copy;
}
function toDataUrl(note) { return 'data:' + note.mime + ';base64,' + note.data; }
function extensionFor(note) { return /ogg/.test(note.mime) ? 'ogg' : 'webm'; }
function bytesToBase64(bytes) {
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}
function permissionText(error) {
  const name = error && error.name;
  if (name === 'NotAllowedError' || name === 'SecurityError') return 'The microphone was not allowed, so no voice note was recorded.';
  if (name === 'NotFoundError' || name === 'OverconstrainedError') return 'No microphone was found, so no voice note was recorded.';
  return 'The microphone could not be opened, so no voice note was recorded.';
}

// Starts a recording. `env` supplies the browser pieces so tests can use fakes:
//   { getUserMedia, MediaRecorder, isTypeSupported, now, setTimeout, clearTimeout }
// Returns { stop(): Promise<note>, cancel(), live: true }. Rejects with a plain-language Error when the microphone is
// refused or recording is unsupported. The microphone tracks are always stopped.
async function start(env) {
  const mime = pickMime(env.isTypeSupported);
  if (!mime) throw Error('This browser cannot record voice notes.');
  let stream;
  try { stream = await env.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: true }, video: false }); }
  catch (error) { throw Error(permissionText(error)); }
  const release = () => { try { stream.getTracks().forEach(t => t.stop()); } catch (e) { /* already stopped */ } };
  let recorder;
  try { recorder = new env.MediaRecorder(stream, { mimeType: mime, audioBitsPerSecond: 24000 }); }
  catch (error) { release(); throw Error('This browser could not start recording a voice note.'); }
  const chunks = []; let size = 0, cancelled = false, timer = null;
  const startedAt = env.now();
  const finished = new Promise((resolve, reject) => {
    recorder.ondataavailable = e => { if (e.data && e.data.size) { chunks.push(e.data); size += e.data.size; } };
    recorder.onerror = () => { release(); reject(Error('Recording the voice note failed.')); };
    recorder.onstop = async () => {
      release();
      if (timer !== null) env.clearTimeout(timer);
      if (cancelled) { resolve(null); return; }
      try {
        const blob = new Blob(chunks, { type: mime });
        if (blob.size > LIMITS.maxBytes) { reject(Error('That voice note is too long to keep. Record a shorter one.')); return; }
        const note = { mime: mime, ms: Math.min(LIMITS.maxMs, env.now() - startedAt), data: bytesToBase64(new Uint8Array(await blob.arrayBuffer())) };
        if (!validate(note)) { reject(Error('The recording could not be kept.')); return; }
        resolve(note);
      } catch (error) { reject(Error('The recording could not be kept.')); }
    };
  });
  recorder.start(500);
  timer = env.setTimeout(() => { if (recorder.state !== 'inactive') recorder.stop(); }, LIMITS.maxMs);
  return {
    live: true,
    done: finished,
    stop() { if (recorder.state !== 'inactive') recorder.stop(); return finished; },
    cancel() { cancelled = true; if (recorder.state !== 'inactive') recorder.stop(); else release(); return finished; }
  };
}

window.SnapShackleVoice = { LIMITS, pickMime, formatDuration, describe, validate, sanitizeObject, toDataUrl, extensionFor, permissionText, start };
})();
