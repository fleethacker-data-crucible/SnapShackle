"""Browser storage copy-forward: preferences saved under the CutterMk keys reach the SnapShackle
keys, and the old keys are left in place (so an older build on the same origin still finds them).
Also checks that the studio still starts when localStorage throws."""
import os
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
ORIGIN = 'http://127.0.0.1:8765'
executable = os.environ.get('SNAPSHACKLE_CHROMIUM') or os.environ.get('CUTTERMK_CHROMIUM') or None

# The studio talks to the host; answer every API call with an empty, harmless reply.
FETCH_MOCK = """() => {
  const json = (v) => new Response(JSON.stringify(v), {status: 200, headers: {'Content-Type': 'application/json'}});
  window.fetch = async (url) => {
    url = String(url);
    if (url.startsWith('/api/settings')) return json({saved: false});
    if (url.startsWith('/api/library')) return json({items: []});
    if (url.startsWith('/api/events')) return json({events: [], latest: 0});
    if (url.startsWith('/api/heartbeat')) return json({autoStop: true, timeoutSeconds: 20});
    return json({});
  };
  navigator.sendBeacon = () => true;
}"""


def serve(route):
    path = route.request.url[len(ORIGIN):].split('?', 1)[0]
    if path == '/':
        body = (ROOT / 'index.html').read_text(encoding='utf-8')
        route.fulfill(status=200, content_type='text/html', body=body)
    elif path.startswith('/assets/') and (ROOT / path.lstrip('/')).is_file():
        kind = 'text/css' if path.endswith('.css') else 'application/javascript'
        route.fulfill(status=200, content_type=kind, body=(ROOT / path.lstrip('/')).read_text(encoding='utf-8'))
    else:
        route.fulfill(status=404, body='')


with sync_playwright() as p:
    browser = p.chromium.launch(headless=True, executable_path=executable, args=['--no-sandbox'])

    # 1) Copy forward from the CutterMk keys; old keys stay.
    context = browser.new_context()
    context.route(ORIGIN + '/**', serve)
    context.add_init_script(FETCH_MOCK)
    context.add_init_script("""if (!sessionStorage.getItem('seeded')) {
      sessionStorage.setItem('seeded', '1');
      localStorage.setItem('cuttermk-settings', JSON.stringify({namePrefix: 'MyShots', recordFps: 9}));
      localStorage.setItem('cuttermk-theme', 'light');
    }""")
    page = context.new_page()
    page.goto(ORIGIN + '/')
    page.wait_for_function("document.documentElement.dataset.theme")
    store = page.evaluate("() => Object.fromEntries(Object.keys(localStorage).map(k => [k, localStorage.getItem(k)]))")
    assert store.get('cuttermk-theme') == 'light', store
    assert store.get('snapshackle-theme') == 'light', store
    assert page.evaluate("document.documentElement.dataset.theme") == 'light', 'migrated theme not applied'
    assert 'cuttermk-settings' in store and 'snapshackle-settings' in store, store
    import json
    migrated = json.loads(store['snapshackle-settings'])
    assert migrated.get('namePrefix') == 'MyShots' and migrated.get('recordFps') == 9, migrated
    assert json.loads(store['cuttermk-settings']) == {'namePrefix': 'MyShots', 'recordFps': 9}, 'old settings key was changed'

    # 2) Runs once: once the SnapShackle key exists, a changed CutterMk key is ignored.
    page.evaluate("() => { localStorage.setItem('cuttermk-theme', 'dark'); localStorage.setItem('snapshackle-theme', 'light'); }")
    page.reload()
    page.wait_for_function("document.documentElement.dataset.theme")
    assert page.evaluate("document.documentElement.dataset.theme") == 'light', 'the CutterMk key overrode the SnapShackle key'
    context.close()

    # 3) Storage that throws (blocked site data) must not stop the studio from starting.
    context = browser.new_context()
    context.route(ORIGIN + '/**', serve)
    context.add_init_script(FETCH_MOCK)
    context.add_init_script("""Object.defineProperty(window, 'localStorage', {get() { throw new DOMException('blocked', 'SecurityError'); }});""")
    page = context.new_page()
    errors = []
    page.on('pageerror', lambda e: errors.append(str(e)))
    page.goto(ORIGIN + '/')
    page.wait_for_function("document.querySelectorAll('#tools button').length === 13")
    assert page.evaluate("document.documentElement.dataset.theme") == 'dark'
    assert not errors, errors
    context.close()
    browser.close()

print('PASS: cuttermk-* storage keys copied forward to snapshackle-* once, old keys kept; studio starts with storage blocked')
