"""Filesystem/transaction tests, including failed upgrades that have written to SQLite.

These use a fake service controller: CI must separately exercise real systemd on
Ubuntu. No test changes the host's service, credentials, or library.
"""

import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import tarfile
import tempfile
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location("codec_runtime", Path(__file__).with_name("runtime.py"))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


class Service:
    def __init__(self, active=False, health=(True,), on_start=None):
        self.was_active = active
        self.health = iter(health)
        self.on_start = on_start
        self.calls = []

    def active(self):
        return self.was_active

    def stop(self):
        self.calls.append("stop")

    def reload(self):
        self.calls.append("reload")

    def start(self):
        self.calls.append("start")
        if self.on_start:
            self.on_start()

    def enable(self):
        self.calls.append("enable")

    def healthy(self, timeout):
        self.calls.append("health")
        return next(self.health)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="codec-runtime-test-")
        self.base = Path(self.temporary.name)
        self.root = self.base / "ubuntu"
        self.root.mkdir()
        self.count = 0

    def tearDown(self):
        # Installed releases are intentionally read-only; only make this test's
        # private directories writable so TemporaryDirectory can remove fixtures.
        for path in self.base.rglob("*"):
            if not path.is_symlink() and path.is_dir():
                path.chmod(0o700)
        self.temporary.cleanup()

    def archive(self, version="v1", changes=None, extras=(), metadata=None, unhashed=()):
        self.count += 1
        folder = self.base / f"artifact-{self.count}"
        folder.mkdir()
        name = f"codec-server-{version}-linux-amd64"
        descriptor = {"schema": "codec.server-release.v1", "version": version,
                      "os": "linux", "arch": "amd64"}
        if metadata:
            descriptor.update(metadata)
        files = {
            "codec-sync-server": ("binary-" + version).encode(),
            "web/index.html": ("index-" + version).encode(),
            "web/sw.js": ("worker-" + version).encode(),
            f"web/_app/immutable/entry/{version}.js": ("javascript-" + version).encode(),
            "deploy/ubuntu/codec.service": ("unit-" + version).encode(),
            "release.json": json.dumps(descriptor).encode(),
        }
        if changes:
            files.update(changes)
        sums = "".join(hashlib.sha256(data).hexdigest() + "  " + path + "\n"
                       for path, data in sorted(files.items()) if path not in unhashed)
        files["SHA256SUMS"] = sums.encode()
        archive = folder / (name + ".tar.gz")
        with tarfile.open(archive, "w:gz") as output:
            for path, data in files.items():
                entry = tarfile.TarInfo(name + "/" + path)
                entry.size = len(data)
                output.addfile(entry, io.BytesIO(data))
            for entry, data in extras:
                output.addfile(entry, io.BytesIO(data) if data is not None else None)
        checksum = folder / (archive.name + ".sha256")
        checksum.write_text(runtime.sha256(archive) + "  " + archive.name + "\n")
        return archive, checksum

    def unpack(self, archive, checksum):
        target = self.base / f"unpacked-{self.count}"
        target.mkdir()
        return runtime.unpack_verified(archive, checksum, target)[0]

    def install(self, version="v1", **kwargs):
        archive, checksum = self.archive(version, **kwargs)
        unpacked = self.unpack(archive, checksum)
        service = Service()
        release, backup = runtime.deploy(self.root, unpacked, "install", backend=service, staging=True)
        self.assertIsNone(backup)
        return release, unpacked, service

    def database(self):
        path = self.root / "var/lib/codec/codec-sync.sqlite"
        with sqlite3.connect(path) as connection:
            connection.execute("CREATE TABLE IF NOT EXISTS songs (name TEXT)")
            connection.execute("INSERT INTO songs VALUES ('before upgrade')")
        return path

    def test_release_verification_and_private_install(self):
        release, _, service = self.install()
        self.assertEqual((release / "codec-sync-server").stat().st_mode & 0o777, 0o555)
        self.assertEqual((release / "web/index.html").stat().st_mode & 0o777, 0o444)
        environment = self.root / "etc/codec/codec.env"
        self.assertEqual(environment.stat().st_mode & 0o777, 0o600)
        self.assertIn("CODEC_AUTH_TOKEN=", environment.read_text())
        self.assertEqual((self.root / "opt/codec/current").resolve(), release)
        self.assertEqual(service.calls, ["reload", "start", "health", "enable"])

    def test_auth_helper_remains_executable_in_read_only_release(self):
        release, _, _ = self.install(changes={
            "scripts/ubuntu-auth.sh": b"#!/bin/sh\nexit 0\n",
            "deploy/ubuntu/auth_token.py": b"# synthetic helper\n",
        })
        self.assertEqual((release / "scripts/ubuntu-auth.sh").stat().st_mode & 0o777, 0o555)
        self.assertEqual((release / "deploy/ubuntu/auth_token.py").stat().st_mode & 0o777, 0o444)

    def test_bad_archive_checksum_rejected_before_extraction(self):
        archive, checksum = self.archive()
        checksum.write_text("0" * 64 + "  " + archive.name + "\n")
        with self.assertRaisesRegex(runtime.DeployError, "checksum mismatch"):
            self.unpack(archive, checksum)

    def test_checksum_filename_must_match(self):
        archive, checksum = self.archive()
        checksum.write_text(runtime.sha256(archive) + "  other.tar.gz\n")
        with self.assertRaisesRegex(runtime.DeployError, "filename does not match"):
            self.unpack(archive, checksum)

    def test_unhashed_payload_is_rejected(self):
        archive, checksum = self.archive(unhashed=("web/index.html",))
        with self.assertRaisesRegex(runtime.DeployError, "cover every release file"):
            self.unpack(archive, checksum)

    def test_inner_hash_is_checked_even_with_valid_outer_hash(self):
        archive, checksum = self.archive()
        with tarfile.open(archive, "r:gz") as source:
            entries = [(item, source.extractfile(item).read()) for item in source]
        with tarfile.open(archive, "w:gz") as output:
            for item, data in entries:
                if item.name.endswith("/web/index.html"):
                    data = b"tampered-index"
                    item.size = len(data)
                output.addfile(item, io.BytesIO(data))
        checksum.write_text(runtime.sha256(archive) + "  " + archive.name + "\n")
        with self.assertRaisesRegex(runtime.DeployError, "Internal release checksum mismatch"):
            self.unpack(archive, checksum)

    def test_unsafe_members_are_rejected(self):
        for name in ("../escape", "/etc/evil", "codec-server-v1-linux-amd64/../../escape",
                     "codec-server-v1-linux-amd64/a\\b", "codec-server-v1-linux-amd64/a//b",
                     "codec-server-v1-linux-amd64/./evil", "second-root/evil"):
            with self.subTest(name=name):
                entry = tarfile.TarInfo(name)
                entry.size = 1
                archive, checksum = self.archive(extras=((entry, b"x"),))
                with self.assertRaises(runtime.DeployError):
                    self.unpack(archive, checksum)
        self.assertFalse((self.base / "escape").exists())

    def test_links_devices_and_duplicate_members_are_rejected(self):
        for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.CHRTYPE, tarfile.FIFOTYPE):
            with self.subTest(kind=kind):
                entry = tarfile.TarInfo("codec-server-v1-linux-amd64/unsafe")
                entry.type = kind
                entry.linkname = "/etc/passwd"
                archive, checksum = self.archive(extras=((entry, None),))
                with self.assertRaisesRegex(runtime.DeployError, "special files are forbidden"):
                    self.unpack(archive, checksum)
        entry = tarfile.TarInfo("codec-server-v1-linux-amd64/web/index.html")
        entry.size = 1
        archive, checksum = self.archive(extras=((entry, b"x"),))
        with self.assertRaisesRegex(runtime.DeployError, "Duplicate"):
            self.unpack(archive, checksum)

    def test_release_metadata_must_match_archive(self):
        for value in ({"version": "../escape"}, {"arch": "arm64"}, {"os": "darwin"},
                      {"schema": "unexpected.v1"}):
            with self.subTest(metadata=value):
                archive, checksum = self.archive(metadata=value)
                with self.assertRaises(runtime.DeployError):
                    self.unpack(archive, checksum)

    def test_expansion_and_member_limits_are_checked(self):
        archive, checksum = self.archive()
        with mock.patch.object(runtime, "MAX_FILE_BYTES", 2):
            with self.assertRaisesRegex(runtime.DeployError, "file is too large"):
                self.unpack(archive, checksum)
        archive, checksum = self.archive()
        with mock.patch.object(runtime, "MAX_FILES", 2):
            with self.assertRaisesRegex(runtime.DeployError, "Too many"):
                self.unpack(archive, checksum)

    def test_successful_update_preserves_database_media_auth_and_old_web_assets(self):
        release, _, _ = self.install()
        database = self.database()
        media = self.root / "var/lib/codec/audio/song.mp3"
        media.parent.mkdir()
        media.write_bytes(b"existing music")
        environment = self.root / "etc/codec/codec.env"
        original_environment = environment.read_bytes()
        original_release_files = sorted(str(p.relative_to(release)) for p in release.rglob("*"))
        archive, checksum = self.archive("v2")
        service = Service(active=True)
        new_release, backup = runtime.deploy(self.root, self.unpack(archive, checksum), "update",
                                              backend=service, staging=True)
        self.assertEqual((self.root / "opt/codec/current").resolve(), new_release)
        self.assertEqual((self.root / "opt/codec/previous").resolve(), release)
        self.assertEqual(environment.read_bytes(), original_environment)
        self.assertEqual(media.read_bytes(), b"existing music")
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        with sqlite3.connect(backup) as connection:
            self.assertEqual(connection.execute("SELECT name FROM songs").fetchall(), [("before upgrade",)])
        web = self.root / "opt/codec/web/current/web"
        self.assertEqual((web / "index.html").read_bytes(), b"index-v2")
        self.assertEqual((web / "sw.js").read_bytes(), b"worker-v2")
        self.assertEqual((web / "_app/immutable/entry/v1.js").read_bytes(), b"javascript-v1")
        self.assertEqual((web / "_app/immutable/entry/v2.js").read_bytes(), b"javascript-v2")
        self.assertEqual(sorted(str(p.relative_to(release)) for p in release.rglob("*")), original_release_files)
        self.assertEqual(service.calls, ["stop", "reload", "start", "health", "enable"])
        self.assertTrue(database.exists())

    def test_failed_update_restores_code_and_web_but_never_rolls_back_live_database(self):
        old, _, _ = self.install()
        database = self.database()
        old_web = (self.root / "opt/codec/web/current").resolve()
        starts = 0
        def accepted_write():
            nonlocal starts
            starts += 1
            if starts == 1:
                with sqlite3.connect(database) as connection:
                    connection.execute("INSERT INTO songs VALUES ('accepted by new binary')")
        service = Service(active=True, health=(False, True), on_start=accepted_write)
        archive, checksum = self.archive("v2")
        with self.assertRaisesRegex(runtime.DeployError, "Database was not rolled back"):
            runtime.deploy(self.root, self.unpack(archive, checksum), "update", backend=service, staging=True)
        self.assertEqual((self.root / "opt/codec/current").resolve(), old)
        self.assertEqual((self.root / "opt/codec/web/current").resolve(), old_web)
        self.assertEqual((self.root / "etc/systemd/system/codec.service").read_bytes(), b"unit-v1")
        with sqlite3.connect(database) as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM songs").fetchone()[0], 2)
        backup = next((self.root / "var/backups/codec").glob("*.sqlite"))
        with sqlite3.connect(backup) as connection:
            self.assertEqual(connection.execute("SELECT COUNT(*) FROM songs").fetchone()[0], 1)
        self.assertEqual(service.calls, ["stop", "reload", "start", "health", "stop", "reload", "start", "health"])

    def test_interrupted_upgrade_rolls_back_too(self):
        old, _, _ = self.install()
        service = Service(active=True)
        def interrupt_once():
            service.on_start = None
            raise KeyboardInterrupt()
        service.on_start = interrupt_once
        archive, checksum = self.archive("v2")
        with self.assertRaises(runtime.DeployError):
            runtime.deploy(self.root, self.unpack(archive, checksum), "update", backend=service, staging=True)
        self.assertEqual((self.root / "opt/codec/current").resolve(), old)

    def test_failure_before_link_switch_restores_old_service_unit(self):
        old, _, _ = self.install()
        service = Service(active=True)
        archive, checksum = self.archive("v2")
        with mock.patch.object(runtime, "atomic_link", side_effect=OSError("simulated disk error")):
            with self.assertRaises(runtime.DeployError):
                runtime.deploy(self.root, self.unpack(archive, checksum), "update", backend=service, staging=True)
        self.assertEqual((self.root / "opt/codec/current").resolve(), old)
        self.assertEqual((self.root / "etc/systemd/system/codec.service").read_bytes(), b"unit-v1")
        self.assertEqual(service.calls, ["stop", "reload", "start", "health"])

    def test_existing_version_cannot_silently_change(self):
        self.install()
        archive, checksum = self.archive(changes={"codec-sync-server": b"different binary"})
        service = Service(active=True)
        with self.assertRaisesRegex(runtime.DeployError, "different build already uses this version"):
            runtime.deploy(self.root, self.unpack(archive, checksum), "update", backend=service, staging=True)
        self.assertEqual(service.calls, [])

    def test_bad_backup_leaves_old_service_running(self):
        old, _, _ = self.install()
        (self.root / "var/lib/codec/codec-sync.sqlite").write_bytes(b"not sqlite")
        service = Service(active=True)
        archive, checksum = self.archive("v2")
        with self.assertRaises(runtime.DeployError):
            runtime.deploy(self.root, self.unpack(archive, checksum), "update", backend=service, staging=True)
        self.assertEqual((self.root / "opt/codec/current").resolve(), old)
        self.assertEqual(service.calls, ["stop", "start", "health"])

    def test_service_and_web_symlinks_cannot_escape(self):
        self.install()
        current = self.root / "opt/codec/current"
        current.unlink()
        current.symlink_to(self.base)
        archive, checksum = self.archive("v2")
        with self.assertRaisesRegex(runtime.DeployError, "outside the release directory"):
            runtime.deploy(self.root, self.unpack(archive, checksum), "update", staging=True)

    def test_immutable_name_collision_rejected_before_service_is_stopped(self):
        self.install()
        archive, checksum = self.archive("v2", changes={"web/_app/immutable/entry/v1.js": b"changed"})
        service = Service(active=True)
        with self.assertRaisesRegex(runtime.DeployError, "different contents"):
            runtime.deploy(self.root, self.unpack(archive, checksum), "update", backend=service, staging=True)
        self.assertEqual(service.calls, [])

    def test_imported_token_is_private_and_never_printed(self):
        archive, checksum = self.archive()
        token_file = self.base / "private-token"
        secret = "test-only-not-a-real-credential_$#quote\"slash\\"
        token_file.write_text(secret + "\n")
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            runtime.main(["install", str(archive), "--sha256-file", str(checksum),
                          "--root-dir", str(self.root), "--token-file", str(token_file)])
        self.assertNotIn(secret, output.getvalue())
        line = (self.root / "etc/codec/codec.env").read_text().splitlines()[1]
        self.assertEqual(json.loads(line.split("=", 1)[1]), secret)

    def test_token_injection_and_world_readable_existing_environment_rejected(self):
        token_file = self.base / "bad-token"
        token_file.write_text("a\nOTHER=value")
        target = self.base / "codec.env"
        with self.assertRaises(runtime.DeployError):
            runtime.prepare_environment(target, token_file)
        target.write_text('CODEC_AUTH_TOKEN="existing"\n')
        target.chmod(0o644)
        with self.assertRaisesRegex(runtime.DeployError, "private regular file"):
            runtime.prepare_environment(target)
        target.chmod(0o600)
        target.write_text('CODEC_AUTH_TOKEN="   "\n')
        with self.assertRaisesRegex(runtime.DeployError, "non-empty"):
            runtime.prepare_environment(target)

    def test_verify_only_does_not_create_target_or_launch_service(self):
        archive, checksum = self.archive()
        target = self.base / "never-created"
        with contextlib.redirect_stdout(io.StringIO()), mock.patch.object(runtime.Systemd, "start") as start:
            runtime.main(["install", str(archive), "--sha256-file", str(checksum),
                          "--root-dir", str(target), "--verify-only"])
        self.assertFalse(target.exists())
        start.assert_not_called()

    def test_main_handles_ubuntu_var_lock_compatibility_symlink(self):
        archive, checksum = self.archive()
        (self.root / "var").mkdir()
        (self.root / "run/lock").mkdir(parents=True)
        compatibility_link = self.root / "var/lock"
        compatibility_link.symlink_to("../run/lock")
        with contextlib.redirect_stdout(io.StringIO()):
            runtime.main(["install", str(archive), "--sha256-file", str(checksum),
                          "--root-dir", str(self.root)])
        self.assertTrue(compatibility_link.is_symlink())
        self.assertTrue((self.root / "run/lock/codec-deploy.lock").is_file())
        self.assertTrue((self.root / "opt/codec/current").is_symlink())

    def test_main_rejects_noncanonical_lock_directory_escape(self):
        archive, checksum = self.archive()
        (self.root / "run").mkdir()
        outside = self.base / "outside-lock"
        outside.mkdir()
        (self.root / "run/lock").symlink_to(outside)
        with self.assertRaisesRegex(runtime.DeployError, "cannot be symlinks"):
            runtime.main(["install", str(archive), "--sha256-file", str(checksum),
                          "--root-dir", str(self.root)])
        self.assertFalse((outside / "codec-deploy.lock").exists())

    def test_main_rejects_filesystem_root_aliases_before_unpacking_or_writing(self):
        archive, checksum = self.archive()
        ancestor_alias = self.base / "root-ancestor-alias"
        ancestor_alias.symlink_to("/usr")
        candidates = [Path("/usr/.."), ancestor_alias / ".."]
        # /tmp is itself a symlink on macOS, where /tmp/.. resolves to /private.
        # Ubuntu's literal /tmp/.. case is covered on Linux without a mock.
        if Path("/tmp/..").resolve() == Path("/"):
            candidates.append(Path("/tmp/.."))
        for target in candidates:
            with self.subTest(target=str(target)):
                with contextlib.redirect_stderr(io.StringIO()), mock.patch.object(runtime, "unpack_verified") as unpack:
                    with mock.patch.object(runtime, "deploy") as deploy:
                        with self.assertRaises(SystemExit):
                            runtime.main(["install", str(archive), "--sha256-file", str(checksum),
                                          "--root-dir", str(target)])
                    deploy.assert_not_called()
                unpack.assert_not_called()

    def test_direct_staging_cannot_target_canonical_filesystem_root(self):
        service = Service()
        with self.assertRaisesRegex(runtime.DeployError, "filesystem root"):
            runtime.deploy(Path("/usr/.."), self.base / "unused", "install", backend=service, staging=True)
        self.assertEqual(service.calls, [])


if __name__ == "__main__":
    unittest.main()
