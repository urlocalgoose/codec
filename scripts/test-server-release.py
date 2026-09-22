#!/usr/bin/env python3
"""Package integrity regressions. Standard library only; no production access."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import tarfile
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("release_builder", Path(__file__).with_name("build-server-release.py"))
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class ReleasePackageTests(unittest.TestCase):
    def web_fixture(self, directory):
        web = directory / "source-web"
        (web / "_app").mkdir(parents=True)
        (web / "index.html").write_text("<html>Codec</html>")
        (web / "service-worker.js").write_text("const cache = 'fixture-build';")
        (web / "_app/version.json").write_text('{"version":"fixture-build"}')
        identity = {
            "schema": "codec.web-build.v1", "version": "preview", "git_commit": "fixture-commit",
            "source_sha256": "a" * 64, "bun_version": "1.3.13",
            "build_id": "fixture-build", "source_date_epoch": 1234567890,
        }
        artifact = directory / "artifact"
        builder.export_web_artifact(web, artifact, identity)
        return artifact, identity

    def test_web_artifact_reuses_only_exact_source_commit_toolchain_and_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            artifact, identity = self.web_fixture(Path(temporary))
            self.assertEqual(builder.verify_web_artifact(artifact, identity), artifact / "web")
            for field in ("source_sha256", "git_commit", "bun_version", "version", "build_id", "source_date_epoch"):
                changed = dict(identity, **{field: "different"})
                with self.subTest(field=field), self.assertRaisesRegex(ValueError, "does not match"):
                    builder.verify_web_artifact(artifact, changed)

    def test_web_artifact_rejects_missing_extra_changed_or_linked_payload(self):
        for change in ("missing", "extra", "changed", "symlink"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                artifact, identity = self.web_fixture(Path(temporary))
                index = artifact / "web/index.html"
                if change == "missing":
                    index.unlink()
                elif change == "extra":
                    (artifact / "web/unexpected.js").write_text("extra")
                elif change == "changed":
                    index.write_text("different content")
                else:
                    index.unlink()
                    index.symlink_to(Path(temporary) / "source-web/index.html")
                with self.assertRaises(ValueError):
                    builder.verify_web_artifact(artifact, identity)

    def test_web_artifact_checks_embedded_svelte_cache_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            artifact, identity = self.web_fixture(Path(temporary))
            (artifact / "web/_app/version.json").write_text('{"version":"stale-build"}')
            # Even internally self-consistent file checksums cannot substitute
            # an old build ID and silently reuse the wrong service-worker cache.
            manifest = dict(identity, files=builder.web_files(artifact / "web"))
            (artifact / "web-build.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, "different Svelte/PWA build ID"):
                builder.verify_web_artifact(artifact, identity)

    def test_archive_is_reproducible_and_checksums_cover_every_regular_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            stage = directory / "codec-server-test-linux-amd64"
            (stage / "web").mkdir(parents=True)
            (stage / "codec-sync-server").write_bytes(b"synthetic binary")
            (stage / "codec-sync-server").chmod(0o755)
            (stage / "web" / "index.html").write_text("<h1>Codec</h1>")
            (stage / "web" / "SHA256SUMS").write_text("ordinary nested asset")
            builder.write_checksums(stage)
            first, second = directory / "first.tar.gz", directory / "second.tar.gz"
            builder.write_archive(stage, first, 1234567890)
            # Local checkout timestamps/ownership must not change the artifact.
            for path in stage.rglob("*"):
                os.utime(path, (1777777777, 1777777777))
            builder.write_archive(stage, second, 1234567890)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with tarfile.open(first) as archive:
                sums = archive.extractfile(f"{stage.name}/SHA256SUMS").read().decode()
                expected = dict(line.split("  ", 1)[::-1] for line in sums.splitlines())
                actual = {}
                for member in archive.getmembers():
                    self.assertEqual(member.mtime, 1234567890)
                    self.assertEqual(member.uid, 0)
                    self.assertFalse(member.issym() or member.islnk())
                    if member.isfile() and member.name != f"{stage.name}/SHA256SUMS":
                        relative = member.name.removeprefix(stage.name + "/")
                        actual[relative] = hashlib.sha256(archive.extractfile(member).read()).hexdigest()
                self.assertEqual(actual, expected)
                self.assertEqual(archive.getmember(f"{stage.name}/codec-sync-server").mode, 0o755)
            (stage / "web" / "index.html").write_text("changed")
            builder.write_checksums(stage)
            builder.write_archive(stage, second, 1234567890)
            self.assertNotEqual(first.read_bytes(), second.read_bytes())

    def test_symlinks_and_unsafe_filenames_cannot_enter_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            stage = Path(temporary) / "stage"
            stage.mkdir()
            secret = Path(temporary) / "outside"
            secret.write_text("fixture outside payload")
            link = stage / "leak"
            link.symlink_to(secret)
            with self.assertRaisesRegex(ValueError, "regular files"):
                list(builder.files_under(stage))
            with self.assertRaisesRegex(ValueError, "symbolic link"):
                builder.write_archive(stage, Path(temporary) / "out.tar.gz", 1)
            link.unlink()
            (stage / "bad\nname").write_text("fixture")
            with self.assertRaisesRegex(ValueError, "Unsafe release filename"):
                list(builder.files_under(stage))

    def test_static_elf_architecture_and_interpreter_are_checked(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "binary"
            header = bytearray(120)
            header[:6] = b"\x7fELF\x02\x01"
            struct.pack_into("<H", header, 18, 62)
            struct.pack_into("<Q", header, 32, 64)
            struct.pack_into("<HH", header, 54, 56, 1)
            path.write_bytes(header)
            builder.validate_elf(path, "amd64")
            with self.assertRaisesRegex(ValueError, "not arm64"):
                builder.validate_elf(path, "arm64")
            struct.pack_into("<I", header, 64, 3)
            path.write_bytes(header)
            with self.assertRaisesRegex(ValueError, "dynamic interpreter"):
                builder.validate_elf(path, "amd64")
            path.write_bytes(b"not ELF")
            with self.assertRaisesRegex(ValueError, "64-bit"):
                builder.validate_elf(path, "amd64")


if __name__ == "__main__":
    unittest.main()
