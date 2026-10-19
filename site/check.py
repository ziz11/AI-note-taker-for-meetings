"""Dependency-free checks for a buildless project Pages site."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse
import re

ROOT = Path(__file__).resolve().parent
class Page(HTMLParser):
    def __init__(self):
        super().__init__()
        self.ids, self.urls, self.tags = [], [], []
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.tags.append((tag, attrs))
        if 'id' in attrs:
            self.ids.append(attrs['id'])
        for key in ('src', 'href'):
            if key in attrs:
                self.urls.append(attrs[key])
page = Page()
page.feed((ROOT / 'index.html').read_text())
assert len(page.ids) == len(set(page.ids)), 'Duplicate IDs'
assert sum(tag == 'h1' for tag, _ in page.tags) == 1
assert any(tag == 'html' and a.get('lang') == 'en-GB' for tag, a in page.tags)
assert any(tag == 'meta' and a.get('name') == 'viewport' for tag, a in page.tags)
assert not any(tag == 'script' for tag, _ in page.tags), 'No third-party scripts required'
for url in page.urls:
    parsed = urlparse(url)
    if parsed.scheme:
        assert parsed.scheme == 'https', url
        continue
    assert not url.startswith('/'), f'Root-relative URL breaks project Pages: {url}'
    if parsed.fragment:
        assert parsed.fragment in page.ids, f'Missing anchor: {url}'
    if parsed.path and parsed.path != './':
        assert (ROOT / parsed.path).is_file(), f'Missing asset: {url}'
for url in re.findall(r'url\([\'"]?([^\)\'" ]+)', (ROOT / 'style.css').read_text()):
    assert not url.startswith('/'), url
    assert (ROOT / url).is_file(), url
assert (ROOT / '.nojekyll').exists()
assert (ROOT / 'assets/social.png').is_file()
assert any(tag == 'button' and 'disabled' in a for tag, a in page.tags)
assert not any('/releases/download/' in url for url in page.urls), 'Verify an actual release before enabling downloads'
print(f'PASS: language, landmarks, anchors, {len(page.urls)} links/assets, relative paths, metadata and pending download')
