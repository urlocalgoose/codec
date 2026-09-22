#!/usr/bin/env python3
"""Optimize approved screenshots without changing their UI; no network access."""
import argparse
import hashlib
import html
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--screenshots', type=Path, required=True)
parser.add_argument('--credits', type=Path, required=True)
args = parser.parse_args()
site = Path(__file__).resolve().parent
assets = site / 'assets'
assets.mkdir(exist_ok=True)
icon = site.parent / 'ios/CodecMobile/App/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png'
images = [(f'iphone-6.9/{name}.png', f'iphone-{target}.webp', 660)
          for name, target in [('01-home', 'home'), ('02-library', 'library'),
                               ('07-search', 'search'), ('04-now-playing', 'now-playing'),
                               ('05-visualizer', 'visualizer'), ('03-downloaded', 'downloaded'),
                               ('06-palettes', 'palettes')]]
images.append(('ipad-13/01-home.png', 'ipad-home.webp', 1050))
for source_name, _, _ in images:
    if not (args.screenshots / source_name).is_file():
        raise SystemExit(f'Missing approved capture: {source_name}')
subprocess.run(['cwebp', '-quiet', '-q', '90', '-resize', '128', '128', str(icon), '-o', str(assets / 'codec-mark.webp')], check=True)
sources = []
for source_name, target_name, width in images:
    source = args.screenshots / source_name
    subprocess.run(['cwebp', '-quiet', '-q', '86', '-m', '6', '-resize', str(width), '0', str(source), '-o', str(assets / target_name)], check=True)
    sources.append({'source': source_name, 'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                    'asset': target_name, 'bytes': (assets / target_name).stat().st_size})
(assets / 'sources.json').write_text(json.dumps({'content': 'Licensed demonstration collection; actual native screenshots', 'images': sources}, indent=2) + '\n')

sections = []
in_list = False
for line in args.credits.read_text().splitlines():
    if line.startswith('# '):
        continue
    if line.startswith('- '):
        if not in_list:
            sections.append('<ul>')
            in_list = True
        text = line[2:]
        if ': https://' in text:
            label, destination = text.split(': https://', 1)
            url = 'https://' + destination.split(' ', 1)[0]
            sections.append(f'<li>{html.escape(label)} · <a href="{html.escape(url, quote=True)}">Source and license</a></li>')
        else:
            sections.append(f'<li>{html.escape(text)}</li>')
    else:
        if in_list:
            sections.append('</ul>')
            in_list = False
        if line.startswith('## '):
            sections.append(f'<h2>{html.escape(line[3:])}</h2>')
if in_list:
    sections.append('</ul>')
(site / 'credits.html').write_text('''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="theme-color" content="#101312"><title>Screenshot credits — Codec</title><link rel="icon" href="assets/codec-mark.webp"><link rel="stylesheet" href="style.css"></head>
<body><header class="site-header wrap"><a class="brand" href="index.html"><img src="assets/codec-mark.webp" alt="" width="44" height="44"><span>Codec</span></a><a href="index.html">Back to Codec</a></header>
<main class="credits-page wrap"><h1>Screenshot credits</h1><p>The real app screenshots show a separate demonstration collection. No music is included with Codec or this website.</p>
<p>The collection’s music is offered under <a href="https://creativecommons.org/publicdomain/zero/1.0/">CC0 1.0</a> by its creators. Replacement covers use public-domain artwork from <a href="https://www.metmuseum.org/hubs/open-access">The Met Open Access collection</a>. These artists and The Met do not endorse Codec. The source credits below cover the collection used for these captures.</p>
''' + '\n'.join(sections) + '\n</main></body></html>\n')
print(json.dumps({'images': len(sources), 'image_bytes': sum(item['bytes'] for item in sources)}))
