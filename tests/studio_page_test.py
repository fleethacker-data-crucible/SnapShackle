"""The studio page helper removes external scripts and stylesheets.
Usage: python tests/studio_page_test.py
"""
from pathlib import Path

from studio_page import read_studio_document, strip_studio_markup

ROOT = Path(__file__).resolve().parents[1]
CALLERS = (
    'ai_ui_test.py',
    'browser_smoke.py',
    'layers_a11y_test.py',
    'layers_numeric_test.py',
    'redact_flow_test.py',
    'share_ui_test.py',
    'voice_browser_test.py',
    'webcam_browser_test.py',
)
SCRIPTS = (
    'theme', 'icons', 'editor', 'gif', 'stitch', 'redact', 'audio',
    'aisuggest', 'voice', 'webcam', 'studio',
)
STYLES = ('assets/vendor/fleet/fleet.css', 'assets/styles.css')


def removed_tags(html, scripts, styles):
    text = html
    for name in scripts:
        tag = '<script src="/assets/%s.js"></script>' % name
        assert tag in text, tag
        text = text.replace(tag, '')
    for path in styles:
        tag = '<link rel="stylesheet" href="/%s">' % path
        assert tag in text, tag
        text = text.replace(tag, '')
    return text


html = (ROOT / 'index.html').read_text(encoding='utf-8')
stripped, scripts, styles = read_studio_document(ROOT)
assert scripts == list(SCRIPTS), scripts
assert styles == list(STYLES), styles
assert stripped == removed_tags(html, scripts, styles)
assert '<script' not in stripped
assert 'stylesheet' not in stripped
# Favicon links are not stylesheets and stay in the page.
assert 'rel="icon"' in stripped

cases = (
    (
        '<p>before</p><script src="/assets/theme.js">alert(1)</script ><p>after</p>',
        '<p>before</p><p>after</p>',
        ['theme'],
        [],
    ),
    (
        '<script src="/assets/voice.js">alert(1)</script foo>',
        '',
        ['voice'],
        [],
    ),
    (
        '<script src="/assets/gif.js">alert(1)</script\t>',
        '',
        ['gif'],
        [],
    ),
    (
        '<script src="/assets/stitch.js">alert(1)</script\n>',
        '',
        ['stitch'],
        [],
    ),
    (
        '<SCRIPT src="/assets/webcam.js">alert(1)</SCRIPT >',
        '',
        ['webcam'],
        [],
    ),
    (
        '<script src="/assets/theme.js" defer></script>',
        '',
        ['theme'],
        [],
    ),
    (
        "<script src='/assets/audio.js'></script>",
        '',
        ['audio'],
        [],
    ),
    (
        '<script src="/assets/theme.js" />',
        '',
        ['theme'],
        [],
    ),
    (
        '<script src="/assets/theme.js">alert(1)</script foo="ok">',
        '',
        ['theme'],
        [],
    ),
    (
        '<script>var keep = 1;</script><link rel="icon" href="/x.ico">',
        '<script>var keep = 1;</script><link rel="icon" href="/x.ico">',
        [],
        [],
    ),
    (
        '<link href="/assets/styles.css" rel="stylesheet">',
        '',
        [],
        ['assets/styles.css'],
    ),
    (
        '<link rel="stylesheet" href="/assets/styles.css" />',
        '',
        [],
        ['assets/styles.css'],
    ),
    (
        '<script src="/extra.js"></script><script src="/assets/theme.js"></script>',
        '',
        ['theme'],
        [],
    ),
    (
        '<div>\n<script src="/assets/gif.js"></script >\n</div>',
        '<div>\n\n</div>',
        ['gif'],
        [],
    ),
    (
        '<link rel="stylesheet" href="/assets/styles.css"><script src="/assets/theme.js">alert(1)</script foo><b>ok</b>',
        '<b>ok</b>',
        ['theme'],
        ['assets/styles.css'],
    ),
)
for raw, expected, expect_scripts, expect_styles in cases:
    got, got_scripts, got_styles = strip_studio_markup(raw)
    assert got == expected, (raw, got)
    assert got_scripts == expect_scripts, (raw, got_scripts)
    assert got_styles == expect_styles, (raw, got_styles)
    assert 'alert' not in got

helper = (ROOT / 'tests' / 'studio_page.py').read_text(encoding='utf-8')
assert 'import re' not in helper and 're.sub' not in helper and 're.compile' not in helper
for name in CALLERS:
    source = (ROOT / 'tests' / name).read_text(encoding='utf-8')
    assert 'read_studio_document' in source, name
    assert 're.sub' not in source, name

print('PASS: studio page helper removes external scripts and stylesheets, including loose script end tags')
