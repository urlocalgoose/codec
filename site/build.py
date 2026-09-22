#!/usr/bin/env python3
"""Copy only public, reviewed site files into the static hosting directory."""
import json
from pathlib import Path
import shutil
import tempfile
from render_docs import render_docs

source = Path(__file__).resolve().parent
output = source / 'dist'
files = ['index.html', 'style.css', 'docs.html', 'docs.css', 'code-copy.js', 'credits.html', '404.html', '_headers',
         'privacy.html', 'support.html', 'legal.css',
         'examples/loud-import.json', 'examples/track-artwork.json', 'examples/playlist-artwork.json',
         'examples/artwork/cover.jpg', 'examples/CREDITS.txt',
         'assets/codec-mark.webp', 'assets/ipad-home.webp']
files += [f'assets/iphone-{name}.webp' for name in ('home', 'library', 'search', 'now-playing', 'visualizer', 'downloaded', 'palettes')]
for name in files:
    file = source / name
    if file.is_symlink() or not file.is_file():
        raise SystemExit(f'Missing regular public asset: {name}')
with tempfile.TemporaryDirectory(prefix='.site-build-', dir=source) as temporary:
    stage = Path(temporary) / 'public'
    for name in files:
        destination = stage / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / name, destination)
    generated = render_docs(stage)
    for name in ['codec-import.schema.json', 's2y-track-artwork.schema.json', 's2y-playlist-artwork.schema.json']:
        schema = source.parent / 'docs' / name
        if schema.is_symlink() or not schema.is_file():
            raise SystemExit(f'Missing regular schema: {name}')
        destination = stage / 'schemas' / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(schema, destination)
        generated.append(destination)
    public_files = [stage / name for name in files] + generated
    report = {'public_files': len(public_files), 'bytes': sum(file.stat().st_size for file in public_files), 'output': 'site/dist'}
    # A bad fragment or missing schema must not remove the working preview.
    if output.exists():
        shutil.rmtree(output)
    stage.rename(output)
print(json.dumps(report))
