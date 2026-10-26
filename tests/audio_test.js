/* Option wiring and video-only fallback for optional screen-recording sound.
   Run: node tests/audio_test.js
   Uses a fake display/mic/Web Audio surface. No browser, no network, no audio leaves the process. */
const fs = require('fs');
const vm = require('vm');
const context = { window: {}, console: console, WeakSet: WeakSet, Error: Error, Promise: Promise, String: String, Array: Array };
vm.runInNewContext(fs.readFileSync(__dirname + '/../assets/audio.js', 'utf8'), context);
const audio = context.window.SnapShackleAudio;

function assert(condition, message) { if (!condition) throw Error(message || 'assertion failed'); }
function assertEqual(actual, expected, message) {
  const left = JSON.stringify(actual), right = JSON.stringify(expected);
  if (left !== right) throw Error((message || 'not equal') + '\n  actual: ' + left + '\n  expected: ' + right);
}

function fakeTrack(kind, id) {
  return { kind: kind, id: id || kind, readyState: 'live', stop() { this.readyState = 'ended'; this.stopped = true; } };
}
function fakeStream(tracks) {
  return {
    tracks: tracks.slice(),
    getTracks() { return this.tracks.slice(); },
    getVideoTracks() { return this.tracks.filter(track => track.kind === 'video'); },
    getAudioTracks() { return this.tracks.filter(track => track.kind === 'audio'); }
  };
}
function createMediaStream(tracks) { return fakeStream(tracks); }
function FakeContext() { this.state = 'running'; this.sources = []; this.closed = false; }
FakeContext.prototype.resume = function () { return Promise.resolve(); };
FakeContext.prototype.close = function () { this.state = 'closed'; this.closed = true; return Promise.resolve(); };
FakeContext.prototype.createMediaStreamDestination = function () {
  const track = fakeTrack('audio', 'mixed');
  this.destinationTrack = track;
  return { stream: fakeStream([track]) };
};
FakeContext.prototype.createMediaStreamSource = function (stream) {
  const src = { stream: stream, connect(dest) { this.dest = dest; }, disconnect() { this.disconnected = true; } };
  this.sources.push(src);
  return src;
};
function namedError(name) { const error = Error(name); error.name = name; return error; }

(async () => {
  assertEqual(audio.MODES, ['off', 'system', 'mic', 'both']);
  assertEqual(audio.normalizeMode(undefined), 'off');
  assertEqual(audio.normalizeMode(''), 'off');
  assertEqual(audio.normalizeMode('nope'), 'off');
  assertEqual(audio.normalizeMode(' BOTH '), 'both');
  assertEqual(audio.normalizeMode('System'), 'system');
  assertEqual(audio.normalizeMicId(' abc<script> '), 'abcscript');
  assertEqual(audio.normalizeMicId('mic_01.default+=/-'), 'mic_01.default+=/-');
  assert(audio.normalizeMicId('x'.repeat(300)).length === 256, 'mic id was not truncated');

  assertEqual(audio.displayAttempts('off', 6), [{ video: { frameRate: 6 }, audio: false }]);
  assertEqual(audio.displayAttempts('mic', 6), [{ video: { frameRate: 6 }, audio: false }]);
  assertEqual(audio.displayAttempts('system', 8)[0], { video: { frameRate: 8 }, audio: true, systemAudio: 'include' });
  assertEqual(audio.mimeCandidates(false), audio.VIDEO_ONLY_MIME);
  assertEqual(audio.mimeCandidates(false), ['video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm']);
  assert(audio.mimeCandidates(true)[0] === 'video/webm;codecs=vp9,opus', 'opus was not preferred when sound is on');
  assertEqual(audio.recorderOptions('video/webm;codecs=vp9', false), { mimeType: 'video/webm;codecs=vp9' });
  assertEqual(audio.recorderOptions('video/webm;codecs=vp9,opus', true).audioBitsPerSecond, 128000);
  assertEqual(audio.onRecorderConstructError(false).retryVideoOnly, false);
  assertEqual(audio.onRecorderConstructError(true).retryVideoOnly, true);
  assert(/video only/.test(audio.onRecorderConstructError(true).message), 'construct fallback message missing');

  async function run(mode, hooks) {
    hooks = hooks || {};
    const video = fakeTrack('video', 'screen');
    const system = fakeTrack('audio', 'system');
    const micTrack = fakeTrack('audio', 'mic');
    const log = { display: [], mic: [] };
    const session = await audio.prepareRecording({
      mode: mode,
      fps: 6,
      micId: hooks.micId || '',
      audioContext: hooks.audioContext,
      createAudioContext: hooks.createAudioContext,
      createMediaStream: createMediaStream,
      getDisplayMedia: async constraints => {
        log.display.push(constraints);
        if (hooks.displayError) {
          const error = hooks.displayError.shift();
          if (error) throw error;
        }
        const tracks = [video];
        if (hooks.shareAudio) tracks.push(system);
        const stream = fakeStream(tracks);
        stream.fromDisplay = true;
        return stream;
      },
      getUserMedia: async constraints => {
        log.mic.push(constraints);
        if (hooks.micError) {
          const error = hooks.micError.shift();
          if (error) throw error;
        }
        return fakeStream([micTrack]);
      }
    });
    return { session: session, log: log, video: video, system: system, mic: micTrack };
  }

  const off = await run('off');
  assertEqual(off.log.display, [{ video: { frameRate: 6 }, audio: false }]);
  assertEqual(off.log.mic.length, 0);
  assertEqual(off.session.plan.mode, 'off');
  assertEqual(off.session.plan.hasAudio, false);
  assertEqual(off.session.plan.message, null);
  assertEqual(off.session.plan.liveText, '');
  assert(off.session.stream.fromDisplay === true, 'off mode must leave the display stream untouched');
  assertEqual(off.session.stream.getAudioTracks().length, 0);
  assert(off.session.stream.getVideoTracks()[0] === off.video, 'off mode dropped the video track');

  const silentShare = await run('system', { shareAudio: false });
  assertEqual(silentShare.log.mic.length, 0);
  assertEqual(silentShare.session.plan.hasAudio, false);
  assertEqual(silentShare.session.plan.liveText, 'Recording video only');
  assertEqual(silentShare.session.plan.message, 'Share audio was not turned on. This recording is video only.');
  assertEqual(silentShare.session.stream.getAudioTracks().length, 0);
  assert(silentShare.session.stream.getVideoTracks()[0] === silentShare.video, 'video track dropped during fallback');

  const systemOn = await run('system', { shareAudio: true });
  assertEqual(systemOn.log.mic.length, 0);
  assertEqual(systemOn.session.plan.message, null);
  assertEqual(systemOn.session.plan.liveText, 'Recording with sound: system audio');
  assert(systemOn.session.stream.getAudioTracks()[0] === systemOn.system, 'system audio track missing');

  const micOn = await run('mic');
  assertEqual(micOn.log.display[0].audio, false);
  assertEqual(micOn.session.plan.message, null);
  assertEqual(micOn.session.plan.liveText, 'Recording with sound: microphone');
  assert(micOn.session.stream.getAudioTracks()[0] === micOn.mic, 'microphone track missing');

  const declined = await run('mic', { micError: [namedError('NotAllowedError')] });
  assertEqual(declined.log.display[0].audio, false);
  assertEqual(declined.log.mic.length, 1);
  assertEqual(declined.session.plan.hasAudio, false);
  assertEqual(declined.session.plan.micDeclined, true);
  assertEqual(declined.session.plan.message, 'Microphone permission was declined. This recording is video only.');

  const exactMiss = await run('mic', { micId: 'gone', micError: [namedError('OverconstrainedError'), null] });
  assertEqual(exactMiss.log.mic.length, 2);
  assertEqual(exactMiss.log.mic[0].audio.deviceId.exact, 'gone');
  assertEqual(exactMiss.log.mic[1], { audio: true, video: false });
  assertEqual(exactMiss.session.plan.includeMic, true);
  assertEqual(exactMiss.session.plan.message, null);

  const deniedExact = await run('both', { micId: 'secret', shareAudio: true, micError: [namedError('NotAllowedError')] });
  assertEqual(deniedExact.log.mic.length, 1, 'a declined microphone must not prompt a second time');
  assertEqual(deniedExact.session.plan.includeSystem, true);
  assertEqual(deniedExact.session.plan.includeMic, false);
  assertEqual(deniedExact.session.plan.message, 'Microphone permission was declined. This recording has system audio only.');
  assert(deniedExact.session.stream.getAudioTracks()[0] === deniedExact.system, 'system track was not kept');

  const micOnly = await run('both', { shareAudio: false });
  assertEqual(micOnly.session.plan.includeMic, true);
  assertEqual(micOnly.session.plan.includeSystem, false);
  assertEqual(micOnly.session.plan.message, 'Share audio was not turned on. This recording has the microphone only.');
  assert(micOnly.session.stream.getAudioTracks()[0] === micOnly.mic, 'microphone track was not kept');

  const neither = await run('both', { shareAudio: false, micError: [namedError('NotAllowedError')] });
  assertEqual(neither.session.plan.hasAudio, false);
  assertEqual(neither.session.plan.message, 'Share audio was not turned on. Microphone permission was declined. This recording is video only.');

  const ctx = new FakeContext();
  const mixed = await run('both', { shareAudio: true, audioContext: ctx });
  assertEqual(mixed.session.plan.mix, true);
  assertEqual(mixed.session.plan.message, null);
  assertEqual(mixed.session.plan.liveText, 'Recording with sound: system audio and microphone');
  assert(mixed.session.stream.getAudioTracks().length === 1, 'mix did not produce one audio track');
  assert(mixed.session.stream.getAudioTracks()[0] === ctx.destinationTrack, 'mixed track was not used');
  assertEqual(ctx.sources.length, 2);
  mixed.session.cleanup();
  assert(ctx.closed, 'mix context was not closed');
  assert(mixed.system.stopped && mixed.mic.stopped, 'source audio tracks were left running after stop');
  assert(!mixed.video.stopped, 'cleanup stopped the video track');

  let constructed = 0;
  const unmixed = await run('both', {
    shareAudio: true,
    createAudioContext() { constructed++; return null; }
  });
  assertEqual(constructed, 1);
  assertEqual(unmixed.session.plan.mix, false);
  assertEqual(unmixed.session.plan.includeSystem, true);
  assert(/could not be mixed/.test(unmixed.session.plan.message), 'mix failure message missing');
  assertEqual(unmixed.session.plan.liveText, 'Recording with sound: system audio');

  const attempts = [];
  try {
    await audio.prepareRecording({
      mode: 'system',
      fps: 6,
      getDisplayMedia: async constraints => {
        attempts.push(constraints);
        throw namedError(attempts.length === 1 ? 'NotAllowedError' : 'ShouldNotRetry');
      },
      getUserMedia: async () => { throw Error('mic should not be requested'); }
    });
    throw Error('cancelled screen share was treated as success');
  } catch (error) {
    assertEqual(error.name, 'NotAllowedError');
    assertEqual(attempts.length, 1);
  }

  const retried = [];
  const unsupported = await audio.prepareRecording({
    mode: 'both',
    fps: 6,
    createMediaStream: createMediaStream,
    createMediaStream: createMediaStream,
    getDisplayMedia: async constraints => {
      retried.push(constraints);
      if (constraints.audio !== false) throw namedError('TypeError');
      return fakeStream([fakeTrack('video', 'screen')]);
    },
    getUserMedia: async () => fakeStream([fakeTrack('audio', 'mic')])
  });
  assertEqual(retried.length, 3);
  assertEqual(retried[2], { video: { frameRate: 6 }, audio: false });
  assertEqual(unsupported.plan.displayAudioUnsupported, true);
  assertEqual(unsupported.plan.message, 'This browser did not offer Share audio. This recording has the microphone only.');
  assertEqual(unsupported.plan.liveText, 'Recording with sound: microphone');

  const source = fs.readFileSync(__dirname + '/../assets/audio.js', 'utf8');
  assert(!/https?:\/\//.test(source), 'audio module must not reference a network URL');
  assert(!/\.mil\b/.test(source), 'audio module must not reference a .mil host');
  assert(!/fetch\(/.test(source), 'audio module must not upload');

  console.log('PASS: audio option wiring and video-only fallback');
})().catch(error => { console.error(error); process.exit(1); });
