"""Fast checks that one release edit updates the complete static site."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

from release_config import load_release, render_release

SITE = Path(__file__).resolve().parent


class SiteReleaseTests(unittest.TestCase):
    def test_release_bump_builds_consistent_pages_and_preserves_preview_on_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'site'
            shutil.copytree(SITE, source, ignore=shutil.ignore_patterns('dist', '__pycache__'))
            (root / 'docs').mkdir()
            for name in ('codec-import.schema.json', 's2y-track-artwork.schema.json', 's2y-playlist-artwork.schema.json'):
                shutil.copyfile(SITE.parent / 'docs' / name, root / 'docs' / name)
            values = load_release()
            previous = values['release_version']
            version = 'v999.42.7'
            values['release_version'] = version
            (source / 'release.json').write_text(json.dumps(values))
            homepage = source / 'index.html'
            homepage.write_text(homepage.read_text().replace('</main>', '<p>{{ release_version }}</p></main>'))
            result = subprocess.run([sys.executable, str(source / 'build.py')], capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout)['release_version'], version)
            output = source / 'dist'
            hosting = (output / 'docs/hosting.html').read_text()
            reference = (output / 'docs/code.html').read_text()
            for text in (hosting, reference):
                tags = re.findall(r'github\.com/urlocalgoose/codec/releases/(?:tag|download)/([^/"<\s]+)', text)
                self.assertTrue(tags)
                self.assertEqual(set(tags), {version})
                self.assertNotIn(previous, text)
            for arch in ('amd64', 'arm64'):
                archive = f'codec-server-{version}-linux-{arch}.tar.gz'
                self.assertIn(f'/download/{version}/{archive}', hosting)
                self.assertIn(f'/download/{version}/{archive}.sha256', hosting)
            self.assertIn(f'sha256sum -c codec-server-{version}-linux-amd64.tar.gz.sha256', hosting)
            self.assertIn(f'./codec-server-{version}-linux-amd64/scripts/ubuntu-install.sh', hosting)
            self.assertIn(f'/path/to/codec-server-{version}-linux-amd64.tar.gz', hosting)
            self.assertIn(f'<p>{version}</p>', (output / 'index.html').read_text())
            self.assertIn(values['artwork_import_min_version'] + ' or later', (output / 'docs/loud.html').read_text())
            for page in output.rglob('*.html'):
                self.assertNotIn('{{', page.read_text(), str(page))
            self.assertFalse((output / 'release.json').exists())
            self.assertFalse((output / 'release_config.py').exists())

            before = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in output.rglob('*') if p.is_file()}
            fragment = source / 'docs-content/hosting.html'
            fragment.write_text(fragment.read_text() + '<p>{{ release_typo }}</p>')
            failure = subprocess.run([sys.executable, str(source / 'build.py')], capture_output=True, text=True)
            self.assertNotEqual(failure.returncode, 0)
            after = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in output.rglob('*') if p.is_file()}
            self.assertEqual(after, before)

    def test_public_templates_do_not_hardcode_release_tags(self):
        for page in [*SITE.glob('*.html'), *(SITE / 'docs-content').glob('*.html')]:
            self.assertIsNone(re.search(r'\bv\d+\.\d+\.\d+', page.read_text()), str(page))

    def test_configuration_rejects_unsafe_tags_and_missing_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            config = Path(tmp) / 'release.json'
            for invalid in ('../v1.2.3', 'v1.2.3/extra', 'v1.2.3"', 'v1.2.3$(echo bad)', '', None):
                with self.subTest(value=invalid):
                    config.write_text(json.dumps({**load_release(), 'release_version': invalid}))
                    with self.assertRaises(ValueError):
                        load_release(config)
            config.write_text(json.dumps({'release_version': 'v1.2.3'}))
            with self.assertRaises(ValueError):
                load_release(config)
            config.write_text(json.dumps({**load_release(), 'release_version': 'v1.2.3-rc.1'}))
            self.assertEqual(load_release(config)['release_version'], 'v1.2.3-rc.1')

    def test_unknown_or_unfinished_variables_fail(self):
        for text in ('{{ release_typo }}', '{{ release_version', '{{ bad-key }}'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                render_release(text, load_release())


if __name__ == '__main__':
    unittest.main()
