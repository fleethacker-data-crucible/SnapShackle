/* Option wiring, picture-in-picture layout and camera-refusal handling for the webcam module.
   Run: node tests/webcam_test.js
   Uses fakes only: no browser, no camera, nothing leaves the process. */
const fs = require('fs');
const vm = require('vm');
const context = { window: {}, console: console, Error: Error, Promise: Promise, String: String, Object: Object, Math: Math, setTimeout: setTimeout };
vm.runInNewContext(fs.readFileSync(__dirname + '/../assets/webcam.js', 'utf8'), context);
const cam = context.window.SnapShackleWebcam;

function assert(condition, message) { if (!condition) throw Error(message || 'assertion failed'); }
function assertEqual(actual, expected, message) {
  const left = JSON.stringify(actual), right = JSON.stringify(expected);
  if (left !== right) throw Error((message || 'not equal') + '\n  actual: ' + left + '\n  expected: ' + right);
}
function fakeTrack(kind) { return { kind: kind, readyState: 'live', stop() { this.readyState = 'ended'; } }; }
function fakeStream(tracks) {
  return { getTracks() { return tracks.slice(); }, getVideoTracks() { return tracks.filter(t => t.kind === 'video'); } };
}
function named(name) { const e = new Error(name); e.name = name; return e; }

(async () => {
  // Off by default, and anything unknown falls back to the safe choice.
  assertEqual(cam.normalizeMode(undefined), 'off');
  assertEqual(cam.normalizeMode('ON'), 'on');
  assertEqual(cam.normalizeMode('always'), 'off');
  assertEqual(cam.normalizeCorner('TL'), 'tl');
  assertEqual(cam.normalizeCorner('middle'), 'br');
  assertEqual(cam.normalizeSize('Large'), 'large');
  assertEqual(cam.normalizeSize('huge'), 'medium');
  assertEqual(cam.normalizeCameraId('bad id <cam>'), 'badidcam');
  assertEqual(cam.normalizeCameraId('x'.repeat(400)).length, 256);

  // Constraints: video only, never audio; a chosen device is exact.
  assertEqual(cam.cameraConstraints('').audio, false);
  assertEqual(cam.cameraConstraints('').video.deviceId, undefined);
  assertEqual(cam.cameraConstraints('abc').video.deviceId, { exact: 'abc' });

  // Layout: each corner sits inside the frame with a margin, the picture keeps the camera's shape,
  // and a size never covers more than half the height.
  const sw = 1920, sh = 1080;
  const br = cam.layout('br', 'medium', sw, sh, 640, 480);
  assertEqual([br.w, br.h], [480, 360]);
  assertEqual([br.x + br.w + br.margin, br.y + br.h + br.margin], [sw, sh]);
  const tl = cam.layout('tl', 'small', sw, sh, 640, 480);
  assertEqual([tl.x, tl.y], [tl.margin, tl.margin]);
  const tr = cam.layout('tr', 'small', sw, sh, 640, 480);
  assertEqual([tr.x + tr.w + tr.margin, tr.y], [sw, tr.margin]);
  const bl = cam.layout('bl', 'small', sw, sh, 640, 480);
  assertEqual([bl.x, bl.y + bl.h + bl.margin], [bl.margin, sh]);
  for (const corner of cam.CORNERS) for (const size of cam.SIZES) for (const [w, h] of [[1920, 1080], [800, 600], [320, 180], [1080, 1920]]) {
    const r = cam.layout(corner, size, w, h, 640, 480);
    assert(r.x >= 0 && r.y >= 0 && r.x + r.w <= w && r.y + r.h <= h, `outside frame: ${corner} ${size} ${w}x${h} ${JSON.stringify(r)}`);
    assert(r.h <= Math.ceil(h / 2) + 1, `too tall: ${corner} ${size} ${w}x${h}`);
  }
  const tall = cam.layout('br', 'large', 1080, 1920, 480, 640);
  assert(tall.h > tall.w, 'a portrait camera stays portrait');
  const unknown = cam.layout('br', 'medium', 1920, 1080, 0, 0);
  assertEqual(unknown.h / unknown.w, 0.75, 'unknown camera shape falls back to 4:3');

  // Opening the camera: success, and every refusal is a message, never a throw.
  const good = fakeStream([fakeTrack('video')]);
  let asked;
  const opened = await cam.openCamera(async c => { asked = c; return good; }, 'dev1');
  assert(opened.stream === good && opened.message === null);
  assertEqual(asked.video.deviceId, { exact: 'dev1' });
  for (const [name, text] of [['NotAllowedError', /declined/], ['NotFoundError', /No matching camera/], ['NotReadableError', /in use/], ['AbortError', /could not be opened/]]) {
    const r = await cam.openCamera(async () => { throw named(name); }, '');
    assert(r.stream === null && text.test(r.message), name + ' -> ' + r.message);
    assert(/no camera picture/.test(r.message), 'the message says the recording continues without a picture');
  }
  const noApi = await cam.openCamera(undefined, '');
  assert(noApi.stream === null && /could not be opened/.test(noApi.message));
  const audioOnly = fakeStream([fakeTrack('audio')]);
  audioOnly.getVideoTracks = () => [];
  const empty = await cam.openCamera(async () => audioOnly, '');
  assert(empty.stream === null, 'a stream with no video track is not a camera');

  assertEqual(cam.liveText(true), 'Camera on: picture-in-picture');
  assertEqual(cam.liveText(false), '');

  const source = fs.readFileSync(__dirname + '/../assets/webcam.js', 'utf8');
  assert(!/https?:\/\//.test(source), 'webcam module must not reference a network URL');
  assert(!/fetch\(|XMLHttpRequest|WebSocket|sendBeacon/.test(source), 'webcam module must not upload');
  console.log('PASS: webcam options, picture-in-picture layout and camera refusal handling');
})().catch(error => { console.error(error); process.exit(1); });
