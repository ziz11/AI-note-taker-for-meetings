"""Dependency-free checks for the static project Pages site and installation guide."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlparse, urljoin, unquote
import re

ROOT = Path(__file__).resolve().parent
PAGES_URL = 'https://ziz11.github.io/Barkenson-Meeting-recorder-for-Mac/'
DOWNLOAD_URL = 'https://github.com/ziz11/Barkenson-Meeting-recorder-for-Mac/releases/download/v0.1.0-preview.1/Barkenson-0.1.0-build5-macOS.zip'


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__()
        self.path, self.ids, self.urls, self.tags = path, [], [], []
        self.html = path.read_text()
        self.feed(self.html)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.tags.append((tag, attrs))
        if 'id' in attrs:
            self.ids.append(attrs['id'])
        for key in ('src', 'href'):
            if key in attrs:
                self.urls.append(attrs[key])


pages = {path.name: Page(path) for path in ROOT.glob('*.html')}
assert 'installation.html' in pages, 'Installation guide missing'
for name, page in pages.items():
    page_url = PAGES_URL if name == 'index.html' else PAGES_URL + name
    assert 'AI-note-taker-for-meetings' not in page.html, 'Stale repository URL'
    assert len(page.ids) == len(set(page.ids)), f'Duplicate IDs: {name}'
    assert sum(tag == 'h1' for tag, _ in page.tags) == 1, name
    assert sum(tag == 'main' for tag, _ in page.tags) == 1, name
    assert any(tag == 'html' and a.get('lang') == 'en-GB' for tag, a in page.tags), name
    assert any(tag == 'meta' and a.get('name') == 'viewport' for tag, a in page.tags), name
    assert any(tag == 'link' and a.get('rel') == 'canonical' and a.get('href') == page_url for tag, a in page.tags), name
    assert not any(tag == 'script' for tag, _ in page.tags), 'No third-party scripts required'
    for tag, attrs in page.tags:
        if tag == 'img':
            assert 'alt' in attrs and attrs.get('width') and attrs.get('height'), attrs
    for url in page.urls:
        parsed = urlparse(url)
        if parsed.scheme:
            assert parsed.scheme == 'https', url
            continue
        assert not url.startswith('/'), f'Root-relative URL breaks project Pages: {url}'
        assert urljoin(page_url, url).startswith(PAGES_URL), f'URL escapes repository subpath: {url}'
        target = ROOT / unquote(parsed.path or name)
        if target.is_dir():
            target /= 'index.html'
        assert target.is_file(), f'Missing page/asset: {url}'
        if parsed.fragment:
            target_page = pages.get(target.name)
            assert target_page and parsed.fragment in target_page.ids, f'Missing anchor: {url}'
    for css_url in re.findall(r'url\([\'"]?([^\)\'" ]+)', (ROOT / 'style.css').read_text()):
        assert not css_url.startswith('/'), css_url
        assert (ROOT / css_url).is_file(), css_url

landing = pages['index.html']
assert sum(tag == 'details' for tag, _ in landing.tags) == 3, 'Keep three FAQs'
assert sum(tag == 'article' for tag, _ in landing.tags) == 4, 'Keep four benefits'
assert sum(tag == 'li' for tag, _ in landing.tags) == 3, 'Keep three steps'
assert sum(url == DOWNLOAD_URL for url in landing.urls) == 2, 'Use the verified ZIP for both download buttons'
assert './installation.html' in landing.urls, 'Link setup beside download'
assert not any('disabled' in attrs for _, attrs in landing.tags), 'Release exists; download must work'
assert 'chatgpt.site' not in landing.html, 'GitHub Pages is the primary host'
for stale in ['coming soon', 'in preparation', 'Screenshots pending', 'Recordly', 'Parakeet', 'certificate', 'Make yourself at home', 'The next chapter']:
    assert stale not in landing.html, f'Remove internal/stale landing text: {stale}'
for key, value in [('og:url', PAGES_URL), ('og:image', PAGES_URL + 'assets/social.png')]:
    assert any(tag == 'meta' and a.get('property') == key and a.get('content') == value for tag, a in landing.tags), key
assert (ROOT / '.nojekyll').is_file()
print(f'PASS: {len(pages)} pages, canonical GitHub Pages URLs, expected release download URLs, relative paths/assets, anchors, accessibility basics and concise structure')
