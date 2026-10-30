/* Optional webcam picture-in-picture for SnapShackle screen video. Local only: the camera stream stays in
   this browser, is drawn onto the recording canvas and is never uploaded. GIF, stills and scrolling
   capture do not use this module. Off until chosen under Workflows, Settings. */
(() => {
'use strict';
const MODES = ['off', 'on'];
const CORNERS = ['br', 'bl', 'tr', 'tl'];
const SIZES = { small: 0.18, medium: 0.25, large: 0.33 };
const CAMERA_ID_PATTERN = /[^A-Za-z0-9_+=./-]/g;

function normalizeMode(value) {
  const mode = String(value == null ? '' : value).trim().toLowerCase();
  return MODES.indexOf(mode) === -1 ? 'off' : mode;
}
function normalizeCorner(value) {
  const corner = String(value == null ? '' : value).trim().toLowerCase();
  return CORNERS.indexOf(corner) === -1 ? 'br' : corner;
}
function normalizeSize(value) {
  const size = String(value == null ? '' : value).trim().toLowerCase();
  return Object.prototype.hasOwnProperty.call(SIZES, size) ? size : 'medium';
}
function normalizeCameraId(value) {
  return String(value == null ? '' : value).trim().replace(CAMERA_ID_PATTERN, '').slice(0, 256);
}
// Where the camera picture goes on a screen of the given size: width is a fraction of the screen width,
// height follows the camera's own shape, and the picture is never taller than half the screen.
function layout(corner, size, screenW, screenH, camW, camH) {
  const sw = Math.max(2, Math.round(screenW)), sh = Math.max(2, Math.round(screenH));
  const ratio = camW > 0 && camH > 0 ? camH / camW : 3 / 4;
  let w = Math.max(2, Math.round(sw * SIZES[normalizeSize(size)]));
  let h = Math.max(2, Math.round(w * ratio));
  if (h > sh / 2) { h = Math.max(2, Math.round(sh / 2)); w = Math.max(2, Math.round(h / ratio)); }
  const margin = Math.max(4, Math.round(Math.min(sw, sh) * 0.02));
  const c = normalizeCorner(corner);
  const x = c === 'bl' || c === 'tl' ? margin : sw - w - margin;
  const y = c === 'tl' || c === 'tr' ? margin : sh - h - margin;
  return { x: Math.max(0, x), y: Math.max(0, y), w: w, h: h, margin: margin };
}
function cameraConstraints(deviceId) {
  const id = normalizeCameraId(deviceId);
  const video = { width: { ideal: 640 }, height: { ideal: 480 }, frameRate: { ideal: 30 } };
  if (id) video.deviceId = { exact: id };
  return { video: video, audio: false };
}
function describeCameraError(error) {
  const name = String(error && error.name || '');
  if (name === 'NotAllowedError' || name === 'PermissionDeniedError' || name === 'SecurityError') return 'Camera permission was declined, so this recording has no camera picture.';
  if (name === 'NotFoundError' || name === 'DevicesNotFoundError' || name === 'OverconstrainedError') return 'No matching camera was found, so this recording has no camera picture.';
  if (name === 'NotReadableError') return 'The camera is in use by another app, so this recording has no camera picture.';
  return 'The camera could not be opened, so this recording has no camera picture.';
}
// Asks for the camera. Never throws: a refusal comes back as { stream: null, message } so recording can go on without it.
async function openCamera(getUserMedia, deviceId) {
  try {
    if (typeof getUserMedia !== 'function') throw Object.assign(new Error('Camera capture is unavailable'), { name: 'NotSupportedError' });
    const stream = await getUserMedia(cameraConstraints(deviceId));
    if (!stream || !stream.getVideoTracks || !stream.getVideoTracks().length) {
      if (stream && stream.getTracks) stream.getTracks().forEach(function (t) { try { t.stop(); } catch (e) { /* already stopped */ } });
      return { stream: null, message: describeCameraError({ name: 'NotFoundError' }) };
    }
    return { stream: stream, message: null };
  } catch (error) {
    return { stream: null, message: describeCameraError(error) };
  }
}
function stopTracks(stream) {
  if (!stream || !stream.getTracks) return;
  stream.getTracks().forEach(function (track) { try { track.stop(); } catch (e) { /* already stopped */ } });
}
async function playable(doc, stream) {
  const video = doc.createElement('video');
  video.muted = true;
  video.playsInline = true;
  video.srcObject = stream;
  await video.play();
  if (!video.videoWidth) await new Promise(function (resolve) { setTimeout(resolve, 400); });
  return video;
}
function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}
// Draws one frame: the screen, then the camera in its corner with a rounded edge and a thin brass border.
function drawFrame(ctx, screenVideo, cameraVideo, box, mirror) {
  const c = ctx.canvas;
  ctx.drawImage(screenVideo, 0, 0, c.width, c.height);
  const radius = Math.max(4, Math.round(Math.min(box.w, box.h) * 0.08));
  ctx.save();
  roundRect(ctx, box.x, box.y, box.w, box.h, radius);
  ctx.clip();
  if (mirror) { ctx.translate(box.x + box.w, box.y); ctx.scale(-1, 1); ctx.drawImage(cameraVideo, 0, 0, box.w, box.h); }
  else ctx.drawImage(cameraVideo, box.x, box.y, box.w, box.h);
  ctx.restore();
  ctx.save();
  ctx.lineWidth = 2;
  ctx.strokeStyle = '#d6b25e';
  roundRect(ctx, box.x + 1, box.y + 1, box.w - 2, box.h - 2, radius);
  ctx.stroke();
  ctx.restore();
}
// Mixes a screen stream and a camera stream into one canvas stream (video only; the caller adds the audio tracks).
// options: screenStream, cameraStream, fps, corner, size, mirror (default true), document, createMediaStream
async function createCompositor(options) {
  const doc = options.document || document;
  const fps = Math.max(2, Math.min(30, Math.round(options.fps || 10)));
  const screenVideo = await playable(doc, options.screenStream);
  const cameraVideo = await playable(doc, options.cameraStream);
  const canvas = doc.createElement('canvas');
  canvas.width = Math.max(2, screenVideo.videoWidth || 1280);
  canvas.height = Math.max(2, screenVideo.videoHeight || 720);
  const ctx = canvas.getContext('2d');
  const box = layout(options.corner, options.size, canvas.width, canvas.height, cameraVideo.videoWidth, cameraVideo.videoHeight);
  const mirror = options.mirror !== false;
  let timer = null, stopped = false, frames = 0;
  function tick() {
    if (stopped) return;
    try { drawFrame(ctx, screenVideo, cameraVideo, box, mirror); frames++; } catch (e) { /* a frame not ready yet */ }
  }
  tick();
  timer = setInterval(tick, 1000 / fps);
  const captured = canvas.captureStream(fps);
  const tracks = captured.getVideoTracks();
  const stream = typeof options.createMediaStream === 'function' ? options.createMediaStream(tracks) : new MediaStream(tracks);
  return {
    stream: stream,
    canvas: canvas,
    box: box,
    get frames() { return frames; },
    redraw: tick,
    // Stops the timer, the composite track and the camera. The screen stream belongs to the caller.
    stop: function () {
      stopped = true;
      if (timer !== null) { clearInterval(timer); timer = null; }
      stopTracks(captured);
      stopTracks(options.cameraStream);
      try { screenVideo.srcObject = null; cameraVideo.srcObject = null; } catch (e) { /* already detached */ }
    }
  };
}
function liveText(on) { return on ? 'Camera on: picture-in-picture' : ''; }

window.SnapShackleWebcam = {
  MODES: MODES.slice(),
  CORNERS: CORNERS.slice(),
  SIZES: Object.keys(SIZES),
  normalizeMode: normalizeMode,
  normalizeCorner: normalizeCorner,
  normalizeSize: normalizeSize,
  normalizeCameraId: normalizeCameraId,
  layout: layout,
  cameraConstraints: cameraConstraints,
  describeCameraError: describeCameraError,
  openCamera: openCamera,
  createCompositor: createCompositor,
  drawFrame: drawFrame,
  liveText: liveText
};
})();
