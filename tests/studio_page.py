"""Studio page markup for the Chromium tests.

The tests open index.html with no server, so script and stylesheet tags that
point at /assets are taken out and the caller attaches those files from disk.
The tags are found with html.parser. A regular expression that only allows
a bare </script> misses end tags a browser still closes, such as </script >
and </script foo>.
"""
from html.parser import HTMLParser
from pathlib import Path


def read_studio_document(root):
    """Return index.html with external scripts and stylesheets removed.

    The second value is the asset script names, in document order. The third
    is the stylesheet paths under /assets, without the leading slash.
    """
    html = (Path(root) / 'index.html').read_text(encoding='utf-8')
    return strip_studio_markup(html)


def strip_studio_markup(html):
    """Remove external script elements and stylesheet links from html."""
    parser = _StudioMarkup(html)
    parser.feed(html)
    parser.close()
    return parser.result()


def _attr(attrs, name):
    for key, value in attrs:
        if key == name and value:
            return value
    return None


def _asset_script_name(src):
    prefix = '/assets/'
    suffix = '.js'
    if not src.startswith(prefix) or not src.endswith(suffix):
        return None
    name = src[len(prefix):-len(suffix)]
    if name and all('a' <= char <= 'z' for char in name):
        return name
    return None


def _asset_style_path(href):
    if not href.startswith('/assets/') or not href.endswith('.css'):
        return None
    path = href[1:]
    middle = path[len('assets/'):-len('.css')]
    if middle and all(char == '/' or 'a' <= char <= 'z' for char in middle):
        return path
    return None


class _StudioMarkup(HTMLParser):
    def __init__(self, html):
        HTMLParser.__init__(self, convert_charrefs=False)
        self._html = html
        self.scripts = []
        self.styles = []
        self._cuts = []
        self._script_at = None
        self._script_closed = False

    def set_cdata_mode(self, elem, escapable=False):
        # Older Python only treats </script> with whitespace before '>' as the
        # end of a script. Stay in normal parsing so any other characters
        # before '>' still close the element.
        return None

    def result(self):
        text = self._html
        for start, end in sorted(self._cuts, reverse=True):
            text = text[:start] + text[end:]
        return text, self.scripts, self.styles

    def _offset(self):
        line, column = self.getpos()
        if line == 1:
            return column
        newline = -1
        for _ in range(line - 1):
            newline = self._html.find('\n', newline + 1)
        return newline + 1 + column

    def parse_endtag(self, i):
        start = self._offset()
        end = HTMLParser.parse_endtag(self, i)
        if self._script_closed:
            self._script_closed = False
            if end >= 0 and self._script_at is not None:
                self._cuts.append((self._script_at, start + (end - i)))
            self._script_at = None
        return end

    def handle_startendtag(self, tag, attrs):
        if self._script_at is not None:
            return
        if tag != 'script':
            self.handle_starttag(tag, attrs)
            return
        src = _attr(attrs, 'src')
        text = self.get_starttag_text() or ''
        if not src or not text:
            return
        name = _asset_script_name(src)
        if name:
            self.scripts.append(name)
        start = self._offset()
        self._cuts.append((start, start + len(text)))

    def handle_starttag(self, tag, attrs):
        if self._script_at is not None:
            return
        if tag == 'script':
            src = _attr(attrs, 'src')
            if not src:
                return
            name = _asset_script_name(src)
            if name:
                self.scripts.append(name)
            self._script_at = self._offset()
            return
        if tag != 'link':
            return
        text = self.get_starttag_text()
        if not text or 'stylesheet' not in text:
            return
        href = _attr(attrs, 'href')
        if href:
            path = _asset_style_path(href)
            if path:
                self.styles.append(path)
        start = self._offset()
        self._cuts.append((start, start + len(text)))

    def handle_endtag(self, tag):
        if tag == 'script' and self._script_at is not None:
            self._script_closed = True
