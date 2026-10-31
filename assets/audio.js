/* Optional sound for SnapShackle screen video. Local only: tracks stay in this browser
   and are muxed into the WebM file. Nothing here uploads audio or opens a socket.
   GIF, scrolling capture and stills do not use this module. */
(() => {
'use strict';
const MODES = ['off', 'system', 'mic', 'both'];
const VIDEO_ONLY_MIME = ['video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm'];
const WITH_AUDIO_MIME = ['video/webm;codecs=vp9,opus', 'video/webm;codecs=vp8,opus', 'video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm'];
// MP4 is H.264 (with AAC or Opus) written by the browser's own encoder. Edge and recent Chrome offer it;
// where MediaRecorder cannot, recording falls back to WebM and says so. Nothing is converted or shipped.
const MP4_VIDEO_ONLY_MIME = ['video/mp4;codecs=avc1.42E01E', 'video/mp4;codecs=avc1', 'video/mp4;codecs=avc3', 'video/mp4'];
const MP4_WITH_AUDIO_MIME = ['video/mp4;codecs=avc1.42E01E,mp4a.40.2', 'video/mp4;codecs=avc1,mp4a.40.2', 'video/mp4;codecs=avc1.42E01E,opus', 'video/mp4;codecs=avc1,opus', 'video/mp4;codecs=avc3,mp4a.40.2'];
const FORMATS = ['webm', 'mp4'];
const closedContexts = new WeakSet();

function normalizeMode(value) {
  const mode = String(value == null ? '' : value).trim().toLowerCase();
  return MODES.indexOf(mode) === -1 ? 'off' : mode;
}
function normalizeMicId(value) {
  return String(value == null ? '' : value).trim().replace(/[^A-Za-z0-9_+=./-]/g, '').slice(0, 256);
}
function wantsSystem(mode) { mode = normalizeMode(mode); return mode === 'system' || mode === 'both'; }
function wantsMic(mode) { mode = normalizeMode(mode); return mode === 'mic' || mode === 'both'; }
function errorName(error) { return String(error && error.name || ''); }
function isDecline(error) {
  const name = errorName(error);
  return name === 'NotAllowedError' || name === 'PermissionDeniedError' || name === 'SecurityError';
}
function isDeviceMiss(error) {
  const name = errorName(error);
  return name === 'NotFoundError' || name === 'OverconstrainedError' || name === 'DevicesNotFoundError' || name === 'NotReadableError';
}
// TypeError / NotSupportedError happen before the picker when a browser rejects a constraint.
function isUnknownConstraint(error) {
  const name = errorName(error);
  return name === 'TypeError' || name === 'NotSupportedError';
}
function normalizeFormat(value) {
  const format = String(value == null ? '' : value).trim().toLowerCase();
  return FORMATS.indexOf(format) === -1 ? 'webm' : format;
}
function mimeCandidates(hasAudio, format) {
  if (normalizeFormat(format) === 'mp4') return (hasAudio ? MP4_WITH_AUDIO_MIME : MP4_VIDEO_ONLY_MIME).slice();
  return (hasAudio ? WITH_AUDIO_MIME : VIDEO_ONLY_MIME).slice();
}
function extensionFor(mimeType) { return /^video\/mp4/i.test(String(mimeType || '')) ? 'mp4' : 'webm'; }
// Chooses what MediaRecorder will write. A wanted MP4 that the browser cannot write falls back to WebM
// (and says so); with no supported type at all, mime is null and the caller reports it.
function pickRecorderType(hasAudio, format, isTypeSupported) {
  const wanted = normalizeFormat(format);
  const supports = function (type) { try { return !!isTypeSupported(type); } catch (e) { return false; } };
  const first = mimeCandidates(hasAudio, wanted).filter(supports)[0] || null;
  if (first) return { mime: first, ext: extensionFor(first), format: wanted, fellBack: false, message: null };
  if (wanted === 'mp4') {
    const webm = mimeCandidates(hasAudio, 'webm').filter(supports)[0] || null;
    if (webm) return { mime: webm, ext: 'webm', format: 'webm', fellBack: true, message: 'This browser cannot write MP4 here, so this recording is WebM.' };
  }
  return { mime: null, ext: null, format: wanted, fellBack: false, message: null };
}
function recorderOptions(mimeType, hasAudio) {
  return hasAudio ? { mimeType: mimeType, audioBitsPerSecond: 128000 } : { mimeType: mimeType };
}
function onRecorderConstructError(hasAudio) {
  if (!hasAudio) return { retryVideoOnly: false, message: null };
  return { retryVideoOnly: true, message: 'Sound could not be added to the video file. This recording is video only.' };
}
function displayAttempts(mode, fps) {
  const video = { frameRate: fps };
  if (!wantsSystem(mode)) return [{ video: video, audio: false }];
  return [
    { video: video, audio: true, systemAudio: 'include' },
    { video: video, audio: true },
    { video: video, audio: false }
  ];
}
function micConstraints(deviceId) {
  const id = normalizeMicId(deviceId);
  return id ? { audio: { deviceId: { exact: id } }, video: false } : { audio: true, video: false };
}
function liveText(plan) {
  if (!plan || normalizeMode(plan.mode) === 'off') return '';
  if (plan.includeSystem && plan.includeMic) return 'Recording with sound: system audio and microphone';
  if (plan.includeSystem) return 'Recording with sound: system audio';
  if (plan.includeMic) return 'Recording with sound: microphone';
  return 'Recording video only';
}
function describeFallback(plan) {
  if (!plan || normalizeMode(plan.mode) === 'off') return null;
  const lostSystem = wantsSystem(plan.mode) && !plan.includeSystem;
  const lostMic = wantsMic(plan.mode) && !plan.includeMic;
  if (!lostSystem && !lostMic) return null;
  const parts = [];
  if (lostSystem) parts.push(plan.displayAudioUnsupported ? 'This browser did not offer Share audio.' : 'Share audio was not turned on.');
  if (lostMic) {
    if (plan.mixUnavailable) parts.push('Both sound sources could not be mixed in this browser.');
    else if (plan.micDeclined) parts.push('Microphone permission was declined.');
    else parts.push('The microphone was not available.');
  }
  let kept = 'This recording is video only.';
  if (plan.includeSystem && !plan.includeMic) kept = 'This recording has system audio only.';
  else if (plan.includeMic && !plan.includeSystem) kept = 'This recording has the microphone only.';
  return parts.join(' ') + ' ' + kept;
}
function seal(plan) {
  plan.mode = normalizeMode(plan.mode);
  plan.includeSystem = !!plan.includeSystem;
  plan.includeMic = !!plan.includeMic;
  plan.hasAudio = plan.includeSystem || plan.includeMic;
  plan.mix = plan.includeSystem && plan.includeMic;
  plan.micDeclined = !!plan.micDeclined;
  plan.displayAudioUnsupported = !!plan.displayAudioUnsupported;
  plan.message = plan.messageOverride || describeFallback(plan);
  plan.liveText = liveText(plan);
  return plan;
}
function videoOnlyPlan(mode, message) {
  return seal({ mode: mode, includeSystem: false, includeMic: false, messageOverride: message || 'This recording is video only.' });
}
function planCapture(input) {
  const mode = normalizeMode(input && input.mode);
  const micError = input && input.micError;
  const displayAudioCount = input && input.displayAudioCount || 0;
  const micTrackCount = input && input.micTrackCount || 0;
  return seal({
    mode: mode,
    includeSystem: wantsSystem(mode) && displayAudioCount > 0,
    includeMic: wantsMic(mode) && micTrackCount > 0,
    micDeclined: !!(micError && isDecline(micError)),
    displayAudioUnsupported: !!(input && input.displayAudioUnsupported)
  });
}
function trackStop(track) { try { track.stop(); } catch (e) { /* already ended */ } }
function liveTracks(tracks) { return (tracks || []).filter(track => track && track.readyState !== 'ended'); }
function streamFrom(tracks, factory) {
  if (typeof factory === 'function') return factory(tracks);
  return new MediaStream(tracks);
}
function closeContext(ctx) {
  if (!ctx || closedContexts.has(ctx)) return;
  closedContexts.add(ctx);
  try {
    const pending = ctx.close();
    if (pending && typeof pending.then === 'function') pending.catch(() => {});
  } catch (e) { /* context already closing */ }
}
function permissionText(error) {
  if (isDecline(error)) return 'Microphone permission was declined. Video can still be recorded without sound.';
  return 'The microphone list could not be read. Video can still be recorded without sound.';
}
function mixTracks(tracks, ctx, factory) {
  const dest = ctx.createMediaStreamDestination();
  const sources = tracks.map(track => {
    const src = ctx.createMediaStreamSource(streamFrom([track], factory));
    src.connect(dest);
    return src;
  });
  if (ctx.state === 'suspended' && typeof ctx.resume === 'function') {
    try {
      const pending = ctx.resume();
      if (pending && typeof pending.then === 'function') pending.catch(() => {});
    } catch (e) { /* resume can fail once the click gesture has ended */ }
  }
  const mixed = dest.stream.getAudioTracks()[0];
  return { track: mixed, sources: sources };
}
// Builds the MediaStream handed to MediaRecorder. Video tracks are left running;
// cleanup stops only the audio sources and the mix context.
function buildStream(displayStream, micStream, plan, options) {
  options = options || {};
  let systemTracks = plan.includeSystem ? liveTracks(displayStream.getAudioTracks()) : [];
  let micTracks = plan.includeMic && micStream ? liveTracks(micStream.getAudioTracks()) : [];
  if (!plan.includeSystem) liveTracks(displayStream.getAudioTracks()).forEach(trackStop);
  if (!plan.includeMic && micStream) micStream.getTracks().forEach(trackStop);
  const cleanups = [];
  let audioTracks = [];
  let ctx = options.audioContext || null;
  if (systemTracks.length && micTracks.length) {
    if (!ctx && typeof options.createAudioContext === 'function') ctx = options.createAudioContext();
    if (!ctx && typeof AudioContext === 'function') ctx = new AudioContext();
    if (!ctx || typeof ctx.createMediaStreamDestination !== 'function') {
      micTracks.forEach(trackStop);
      micTracks = [];
      plan.includeMic = false;
      plan.mixUnavailable = true;
      audioTracks = systemTracks.slice(0, 1);
    } else {
      const mixed = mixTracks(systemTracks.concat(micTracks), ctx, options.createMediaStream);
      if (!mixed.track) {
        micTracks.forEach(trackStop);
        micTracks = [];
        plan.includeMic = false;
        plan.mixUnavailable = true;
        audioTracks = systemTracks.slice(0, 1);
      } else {
        audioTracks = [mixed.track];
        const sourceTracks = systemTracks.concat(micTracks);
        cleanups.push(() => {
          mixed.sources.forEach(src => { try { src.disconnect(); } catch (e) { /* already disconnected */ } });
          sourceTracks.forEach(trackStop);
        });
      }
    }
  } else {
    audioTracks = systemTracks.concat(micTracks).slice(0, 1);
    const sourceTracks = systemTracks.concat(micTracks);
    cleanups.push(() => sourceTracks.forEach(trackStop));
  }
  seal(plan);
  const videoTracks = liveTracks(displayStream.getVideoTracks());
  const stream = audioTracks.length ? streamFrom(videoTracks.concat(audioTracks), options.createMediaStream) : (videoTracks.length ? streamFrom(videoTracks, options.createMediaStream) : displayStream);
  return {
    stream: stream,
    cleanup() {
      cleanups.forEach(fn => fn());
      audioTracks.forEach(trackStop);
      if (ctx) closeContext(ctx);
    }
  };
}
async function acquireMic(deviceId, getUserMedia) {
  if (typeof getUserMedia !== 'function') {
    const error = Error('Microphone capture is unavailable');
    error.name = 'NotSupportedError';
    return { stream: null, error: error };
  }
  const exact = normalizeMicId(deviceId);
  try {
    return { stream: await getUserMedia(micConstraints(exact)), error: null };
  } catch (error) {
    if (exact && isDeviceMiss(error) && !isDecline(error)) {
      try { return { stream: await getUserMedia(micConstraints('')), error: null }; }
      catch (retryError) { return { stream: null, error: retryError }; }
    }
    return { stream: null, error: error };
  }
}
async function captureDisplay(mode, fps, getDisplayMedia) {
  if (typeof getDisplayMedia !== 'function') throw Error('Screen sharing unavailable in this browser or restricted by policy');
  const attempts = displayAttempts(mode, fps);
  let lastError = null;
  for (let i = 0; i < attempts.length; i++) {
    try {
      const stream = await getDisplayMedia(attempts[i]);
      return { stream: stream, displayAudioUnsupported: wantsSystem(mode) && attempts[i].audio === false };
    } catch (error) {
      lastError = error;
      const more = i < attempts.length - 1;
      if (!more || !isUnknownConstraint(error)) throw error;
    }
  }
  throw lastError || Error('Screen sharing unavailable in this browser or restricted by policy');
}
async function prepareRecording(options) {
  options = options || {};
  const mode = normalizeMode(options.mode);
  const providedContext = options.audioContext || null;
  let displayStream = null;
  let micStream = null;
  try {
    const captured = await captureDisplay(mode, options.fps, options.getDisplayMedia);
    displayStream = captured.stream;
    if (mode === 'off') {
      return {
        stream: displayStream,
        plan: seal({ mode: 'off' }),
        cleanup() { if (providedContext) closeContext(providedContext); }
      };
    }
    let micError = null;
    if (wantsMic(mode)) {
      const mic = await acquireMic(options.micId, options.getUserMedia);
      micStream = mic.stream;
      micError = mic.error;
    }
    const plan = planCapture({
      mode: mode,
      displayAudioCount: liveTracks(displayStream.getAudioTracks()).length,
      micTrackCount: micStream ? liveTracks(micStream.getAudioTracks()).length : 0,
      micError: micError,
      displayAudioUnsupported: captured.displayAudioUnsupported
    });
    const built = buildStream(displayStream, micStream, plan, {
      audioContext: plan.mix ? providedContext : null,
      createAudioContext: options.createAudioContext,
      createMediaStream: options.createMediaStream
    });
    return {
      stream: built.stream,
      plan: plan,
      cleanup() {
        built.cleanup();
        if (providedContext) closeContext(providedContext);
      }
    };
  } catch (error) {
    try { if (displayStream) displayStream.getTracks().forEach(trackStop); } catch (e) { /* stream already stopped */ }
    try { if (micStream) micStream.getTracks().forEach(trackStop); } catch (e) { /* mic already stopped */ }
    if (providedContext) closeContext(providedContext);
    throw error;
  }
}

window.SnapShackleAudio = {
  MODES: MODES.slice(),
  VIDEO_ONLY_MIME: VIDEO_ONLY_MIME.slice(),
  normalizeMode: normalizeMode,
  normalizeMicId: normalizeMicId,
  wantsSystem: wantsSystem,
  wantsMic: wantsMic,
  isDecline: isDecline,
  FORMATS: FORMATS.slice(),
  normalizeFormat: normalizeFormat,
  extensionFor: extensionFor,
  pickRecorderType: pickRecorderType,
  mimeCandidates: mimeCandidates,
  recorderOptions: recorderOptions,
  onRecorderConstructError: onRecorderConstructError,
  displayAttempts: displayAttempts,
  micConstraints: micConstraints,
  liveText: liveText,
  planCapture: planCapture,
  videoOnlyPlan: videoOnlyPlan,
  prepareRecording: prepareRecording,
  closeContext: closeContext,
  permissionText: permissionText
};
})();
