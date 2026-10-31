"""MP4 recording in a real browser: the format choice reaches MediaRecorder and the bytes are MP4.

Records a short synthetic canvas (no screen is captured) through SnapShackleAudio.pickRecorderType.
Runs against installed Microsoft Edge, then Google Chrome, because Playwright's bundled Chromium has no
H.264 encoder. If neither can write MP4 the MP4 assertions are skipped with a message, and the WebM
fallback is still checked. Usage: python tests/mp4_record_test.py
"""
import sys
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
AUDIO = (ROOT / 'assets' / 'audio.js').read_text(encoding='utf-8')

RECORD = '''async (format) => {
  const canvas = document.createElement('canvas'); canvas.width = 320; canvas.height = 180;
  const ctx = canvas.getContext('2d');
  const stream = canvas.captureStream(15);
  const pick = SnapShackleAudio.pickRecorderType(false, format, t => MediaRecorder.isTypeSupported(t));
  if (!pick.mime) return {pick, bytes: null};
  const recorder = new MediaRecorder(stream, SnapShackleAudio.recorderOptions(pick.mime, false));
  const chunks = []; recorder.ondataavailable = e => { if (e.data.size) chunks.push(e.data); };
  const stopped = new Promise(r => { recorder.onstop = r; });
  recorder.start(200);
  for (let i = 0; i < 20; i++) { ctx.fillStyle = i % 2 ? '#38bde1' : '#ff465c'; ctx.fillRect(0, 0, 320, 180); await new Promise(r => setTimeout(r, 100)); }
  recorder.stop(); await stopped;
  const blob = new Blob(chunks, {type: pick.mime});
  const head = new Uint8Array(await blob.slice(0, 16).arrayBuffer());
  return {pick, size: blob.size, type: blob.type, head: Array.from(head)};
}'''

def run(playwright, channel):
    try:
        browser = playwright.chromium.launch(channel=channel, headless=True)
    except Exception as error:  # channel not installed
        return None, str(error).splitlines()[0]
    page = browser.new_page()
    page.goto('about:blank')
    page.add_script_tag(content=AUDIO)
    out = {fmt: page.evaluate(RECORD, fmt) for fmt in ('mp4', 'webm')}
    version = browser.version
    browser.close()
    return (version, out), None

def main():
    tested = None
    with sync_playwright() as p:
        for channel in ('msedge', 'chrome'):
            result, error = run(p, channel)
            if result:
                tested = (channel, result)
                if result[1]['mp4']['pick']['ext'] == 'mp4':
                    break
        if not tested:
            print('SKIP: no installed Edge or Chrome to test MP4 recording in')
            return 0
    channel, (version, out) = tested
    webm = out['webm']
    assert webm['pick']['ext'] == 'webm' and webm['size'] > 0, webm
    assert webm['head'][:4] == [0x1A, 0x45, 0xDF, 0xA3], 'WebM should start with the EBML header: %s' % webm['head']
    mp4 = out['mp4']
    if mp4['pick']['ext'] != 'mp4':
        assert mp4['pick']['fellBack'] and mp4['head'][:4] == [0x1A, 0x45, 0xDF, 0xA3], mp4
        print('SKIP: %s %s cannot write MP4; the WebM fallback was verified instead' % (channel, version))
        return 0
    assert mp4['size'] > 0, mp4
    assert bytes(mp4['head'][4:8]) == b'ftyp', 'MP4 should start with an ftyp box: %s' % mp4['head']
    assert mp4['pick']['fellBack'] is False, mp4
    print('PASS: %s %s wrote a real MP4 (%d bytes, %s) and a WebM' % (channel, version, mp4['size'], mp4['pick']['mime']))
    return 0

if __name__ == '__main__':
    sys.exit(main())
