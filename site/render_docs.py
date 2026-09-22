"""Build static public guide pages from reviewed HTML fragments."""
import html
from html.parser import HTMLParser
from pathlib import Path

PAGES = {'loud': 'The Loud format', 'hosting': 'Hosting Codec', 'code': 'Codebase reference'}


class Headings(HTMLParser):
    def __init__(self):
        super().__init__()
        self.headings = []
        self.current = None

    def handle_starttag(self, tag, attrs):
        if tag == 'h2':
            ident = dict(attrs).get('id')
            if not ident:
                raise ValueError('Every guide h2 needs a stable id')
            self.current = [ident, '']

    def handle_data(self, text):
        if self.current is not None:
            self.current[1] += text

    def handle_endtag(self, tag):
        if tag == 'h2' and self.current is not None:
            self.headings.append(self.current)
            self.current = None


def render_docs(output):
    source = Path(__file__).resolve().parent
    exported = []
    for slug, title in PAGES.items():
        fragment_path = source / 'docs-content' / (slug + '.html')
        if fragment_path.is_symlink():
            raise ValueError('Guide sources must be regular files')
        fragment = fragment_path.read_text()
        fragment = fragment.replace('<pre>', '<pre tabindex="0" aria-label="Code example">')
        fragment = fragment.replace('<table>', '<table tabindex="0">')
        headings = Headings()
        headings.feed(fragment)
        ids = [item[0] for item in headings.headings]
        if not ids or len(ids) != len(set(ids)):
            raise ValueError('Guide heading ids must be present and unique')
        pages = ''.join(f'<a href="{name}.html"' + (' aria-current="page"' if name == slug else '') + f'>{label}</a>' for name, label in PAGES.items())
        toc = ''.join(f'<li><a href="#{html.escape(ident, quote=True)}">{html.escape(label)}</a></li>' for ident, label in headings.headings)
        page = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="theme-color" content="#101312"><title>{html.escape(title)} — Codec</title><link rel="icon" href="../assets/codec-mark.webp"><link rel="stylesheet" href="../style.css"><link rel="stylesheet" href="../docs.css"><script src="../code-copy.js" defer></script></head>
<body><a class="skip-link" href="#main">Skip to content</a>
<header class="site-header wrap"><a class="brand" href="../index.html" aria-label="Codec home"><img src="../assets/codec-mark.webp" alt="" width="44" height="44"><span>Codec</span></a><nav aria-label="Main navigation"><a href="../docs.html">Docs</a><a href="https://github.com/urlocalgoose/codec">GitHub <span aria-hidden="true">↗</span></a></nav></header>
<div class="docs-breadcrumb wrap"><a href="../docs.html">Documentation</a> / {html.escape(title)}</div>
<div class="doc-layout wrap"><aside class="doc-sidebar"><nav class="doc-pages" aria-label="Documentation guides">{pages}</nav><details class="doc-toc"><summary>On this page</summary><nav aria-label="Page contents"><ol>{toc}</ol></nav></details></aside>
<main class="doc-content" id="main">{fragment}</main></div>
<footer class="site-footer wrap"><a class="footer-brand" href="../index.html">Codec</a><nav aria-label="Footer navigation"><a href="../docs.html">Docs</a><a href="https://github.com/urlocalgoose/codec">GitHub</a><a href="../privacy.html">Privacy</a><a href="../support.html">Support</a></nav></footer></body></html>
'''
        destination = output / 'docs' / (slug + '.html')
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(page)
        exported.append(destination)
    return exported
