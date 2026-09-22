"""Release values shared by all generated project-site pages."""
import json
from pathlib import Path
import re

CONFIG_PATH = Path(__file__).with_name('release.json')
VERSION = re.compile(r'v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?\Z')
TOKEN = re.compile(r'\{\{\s*([a-z_]+)\s*\}\}')
KEYS = {'release_version', 'artwork_import_min_version'}


def load_release(path=CONFIG_PATH):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError('Site release configuration must be a regular file')
    values = json.loads(path.read_text())
    if not isinstance(values, dict) or set(values) != KEYS:
        raise ValueError('Site release configuration needs: ' + ', '.join(sorted(KEYS)))
    for key, value in values.items():
        if not isinstance(value, str) or not VERSION.fullmatch(value):
            raise ValueError(f'Invalid release tag for {key}')
    return values


def render_release(text, values):
    def substitute(match):
        key = match.group(1)
        if key not in values:
            raise ValueError(f'Unknown site release variable: {key}')
        return values[key]

    rendered = TOKEN.sub(substitute, text)
    if '{{' in rendered:
        raise ValueError('Unresolved site release variable')
    return rendered
