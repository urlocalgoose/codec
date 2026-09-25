#!/usr/bin/env python3
"""Safety/lifecycle regressions for the persistent local lab; no real lab/prod data."""
import importlib.util
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("local_dev", Path(__file__).with_name("local-dev.py"))
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


class LocalLabTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="codec-lab-tests-")
        self.root = Path(self.temporary.name)
        self.state_patch = patch.object(lab, "STATE", self.root / ".codec-dev")
        self.state_patch.start()
        with lab.lab_lock():
            self.config = lab.configuration()

    def tearDown(self):
        self.state_patch.stop()
        self.temporary.cleanup()

    def test_distinct_private_tokens_stay_the_same_after_reinitialization(self):
        before = [lab.token(name) for name in ("a", "b")]
        self.assertNotEqual(*before)
        self.assertEqual((lab.STATE.stat().st_mode & 0o777), 0o700)
        for name in ("a", "b"):
            self.assertEqual(((lab.instance_dir(name) / "auth-token").stat().st_mode & 0o777), 0o600)
        lab.configuration()
        self.assertEqual(before, [lab.token(name) for name in ("a", "b")])

    def test_foreign_configuration_rejected(self):
        self.config["repository"] = "/not-this-checkout"
        lab.write_json(lab.STATE / "config.json", self.config)
        with self.assertRaisesRegex(RuntimeError, "different checkout"):
            lab.configuration()

    def test_duplicate_or_production_forwarder_ports_rejected(self):
        for port in (8791, 8787, 8788, 0):
            self.config["instances"]["b"]["port"] = port
            lab.write_json(lab.STATE / "config.json", self.config)
            with self.assertRaises(RuntimeError):
                lab.configuration()

    def test_symlinked_auth_and_data_rejected_without_modifying_target(self):
        external = self.root / "personal-token"
        external.write_text("leave this alone")
        local = lab.instance_dir("a") / "auth-token"
        local.unlink()
        local.symlink_to(external)
        with self.assertRaisesRegex(RuntimeError, "symlinked"):
            lab.configuration()
        self.assertEqual(external.read_text(), "leave this alone")

    def test_symlinked_state_rejected(self):
        target = self.root / "personal"
        target.mkdir()
        fake = self.root / "fake-state"
        fake.symlink_to(target)
        with patch.object(lab, "STATE", fake), self.assertRaises(RuntimeError):
            with lab.lab_lock():
                self.fail("should not enter")

    def test_active_port_refuses_to_start_or_kill_other_process(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            with self.assertRaisesRegex(RuntimeError, "Nothing was killed"):
                lab.require_free(listener.getsockname()[1])

    def test_restart_allows_time_wait_from_closed_listener(self):
        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
            listener.listen(1)
            with socket.create_connection(("127.0.0.1", port), timeout=1) as client:
                accepted, _ = listener.accept()
                with accepted:
                    accepted.settimeout(1)
                    # The server actively closes, leaving its local port in
                    # TIME_WAIT after the client acknowledges and closes.
                    accepted.shutdown(socket.SHUT_WR)
                    self.assertEqual(client.recv(1), b"")
                    client.shutdown(socket.SHUT_WR)
                    self.assertEqual(accepted.recv(1), b"")
        with socket.socket() as plain_probe:
            with self.assertRaises(OSError):
                plain_probe.bind(("127.0.0.1", port))
        lab.require_free(port)

    def test_reusable_live_listener_still_rejected(self):
        for host in ("127.0.0.1", "0.0.0.0"):
            with self.subTest(host=host), socket.socket() as listener:
                listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                listener.bind((host, 0))
                listener.listen(1)
                port = listener.getsockname()[1]
                with self.assertRaisesRegex(RuntimeError, "Nothing was killed"):
                    lab.require_free(port)
                # Drain the preflight connection before exercising the small
                # test backlog again. The original listener remains usable.
                listener.settimeout(1)
                accepted, _ = listener.accept()
                accepted.close()
                with socket.create_connection(("127.0.0.1", port), timeout=1) as client:
                    accepted, _ = listener.accept()
                    accepted.close()

    def test_stale_or_reused_pid_never_killed(self):
        owner = str(lab.instance_dir("a") / "data")
        for identity in (("different start", "server --data " + owner), ("prior start", "personal music server"),
                         ("prior start", "server --data " + owner + "-personal"), None):
            lab.write_json(lab.instance_dir("a") / "process.json",
                           {"pid": 1234, "started": "prior start", "ownership_argument": owner})
            with patch.object(lab, "process_identity", return_value=identity), patch.object(lab.os, "kill") as kill:
                lab.stop_one("a")
                kill.assert_not_called()

    def test_empty_or_foreign_process_ownership_never_killed(self):
        for owner in ("", "/personal/server", str(lab.STATE)):
            lab.write_json(lab.instance_dir("a") / "process.json",
                           {"pid": 1234, "started": "start", "ownership_argument": owner})
            with patch.object(lab, "process_identity", return_value=("start", "server " + owner)), patch.object(lab.os, "kill") as kill:
                lab.stop_one("a")
                kill.assert_not_called()

    def test_changed_port_preflight_does_not_stop_existing_lab(self):
        with patch.object(lab, "running", return_value={"binary": "old", "port": 8700}), \
             patch.object(lab, "require_free", side_effect=RuntimeError("occupied")), patch.object(lab, "stop_one") as stop:
            with self.assertRaisesRegex(RuntimeError, "occupied"):
                lab.start_one(self.config, "a", {"server_binary": "new"})
            stop.assert_not_called()

    def test_failed_tree_copy_never_publishes_and_retry_succeeds(self):
        source = self.root / "source"
        source.mkdir()
        (source / "index.html").write_text("complete")
        destination = lab.STATE / "builds/runtime-test"
        def fail(_):
            raise RuntimeError("interrupted")
        with self.assertRaisesRegex(RuntimeError, "interrupted"):
            lab.publish_tree(source, destination, fail)
        self.assertFalse(destination.exists())
        self.assertFalse(list((lab.STATE / "builds").glob(".pending-*")))
        lab.publish_tree(source, destination)
        self.assertEqual((destination / "index.html").read_text(), "complete")

    def test_metadata_links_cannot_modify_external_files(self):
        target = self.root / "outside"
        target.write_text("private")
        linked = lab.STATE / "unsafe.json"
        linked.symlink_to(target)
        with self.assertRaisesRegex(RuntimeError, "symlinked"):
            lab.read_json(linked)
        with self.assertRaisesRegex(RuntimeError, "symlinked"):
            lab.write_json(linked, {})
        linked.unlink()
        linked.with_suffix(".json.tmp").symlink_to(target)
        with self.assertRaisesRegex(RuntimeError, "symlinked"):
            lab.write_json(linked, {})
        self.assertEqual(target.read_text(), "private")

    def test_check_rejects_stale_server_or_site_before_testing(self):
        exported = lab.STATE / "builds/web-test"
        exported.mkdir()
        lab.write_json(exported / "web-build.json", {"source_sha256": "web"})
        candidate = {"web_export": str(exported), "server_source_sha256": "server", "site_source_sha256": "site"}
        lab.write_json(lab.STATE / "candidate.json", candidate)
        for server, site, message in (("changed", "site", "Server source"), ("server", "changed", "Site source")):
            with patch.object(lab, "load_module", return_value=SimpleNamespace(content_id=lambda: "web")), \
                 patch.object(lab, "server_source_digest", return_value=server), \
                 patch.object(lab, "site_source_digest", return_value=site), patch.object(lab, "logged") as logged:
                with self.assertRaisesRegex(RuntimeError, message):
                    lab.check(self.config)
                logged.assert_not_called()

    def test_check_aux_retirement_requires_explicit_cli_option(self):
        for enabled in (False, True):
            argv = ["local-dev.py", "check", "--skip-browser"]
            if enabled:
                argv.append("--aux-v1-retirement")
            with self.subTest(enabled=enabled), patch.object(sys, "argv", argv), patch.object(lab, "check") as check:
                lab.main()
                check.assert_called_once_with(self.config, False, aux_v1_retirement=enabled)

    def test_compatibility_command_preserves_strict_default_and_forwards_exception(self):
        for enabled in (False, True):
            command = lab.installed_client_check_command("/fixture/candidate", self.root / "report", enabled)
            self.assertEqual(command.count("--aux-v1-retirement"), int(enabled))
            self.assertEqual(command[command.index("--server-binary") + 1], "/fixture/candidate")
            self.assertEqual(command[command.index("--report-dir") + 1], str(self.root / "report"))

    def test_stop_preserves_test_library_and_credentials(self):
        directory = lab.instance_dir("a") / "data"
        directory.mkdir()
        sentinel = directory / "library.db"
        sentinel.write_bytes(b"persistent test state")
        before = lab.token("a")
        lab.stop_one("a")
        self.assertEqual(sentinel.read_bytes(), b"persistent test state")
        self.assertEqual(lab.token("a"), before)

    def test_bundle_references_cannot_escape(self):
        bundle = self.root / "demo"
        bundle.mkdir()
        outside = self.root / "private.mp3"
        outside.write_bytes(b"private")
        (bundle / "link.mp3").symlink_to(outside)
        for base, name in ((".", "../private.mp3"), ("..", "private.mp3"),
                           (".", str(outside)), (".", "link.mp3"), (".", "..\\private.mp3")):
            with self.assertRaises(RuntimeError):
                lab.bundle_path(bundle, base, name)

    def test_bundle_packages_only_supplied_references_and_sidecars(self):
        bundle = self.root / "demo"
        (bundle / "audio").mkdir(parents=True)
        (bundle / "art").mkdir()
        (bundle / "audio/one.mp3").write_bytes(b"test audio")
        (bundle / "art/one.jpg").write_bytes(b"test art")
        (bundle / "unrelated-secret.txt").write_text("never pack this")
        manifest = {"schema": "loud.import.v1", "source": {"base_path": "."},
                    "tracks": [{"file": "audio/one.mp3", "fingerprint": "one"}], "playlists": []}
        (bundle / "loud-import.json").write_text(json.dumps(manifest))
        (bundle / "track-artwork.json").write_text(json.dumps({"base_path": "art", "tracks": [
            {"fingerprint": "one", "artwork": {"file": "one.jpg"}}]}))
        archive, count = lab.make_bundle(bundle)
        self.assertEqual(count, 1)
        with lab.zipfile.ZipFile(archive) as output:
            self.assertEqual(set(output.namelist()), {"loud-import.json", "track-artwork.json", "audio/one.mp3", "art/one.jpg"})

    def test_share_never_overwrites_existing_route_or_uses_funnel(self):
        config = {"Self": {"DNSName": "lab.example.ts.net."}, "BackendState": "Running"}
        existing = {"TCP": {"8441": {"HTTPS": True}}, "Web": {"lab.example.ts.net:8441": {
            "Handlers": {"/": {"Proxy": "http://127.0.0.1:8080"}}}}}
        with patch.object(lab, "capture", side_effect=[json.dumps(config), json.dumps(existing)]), \
             patch.object(lab, "running", return_value=True), patch.object(lab.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "another service"):
                lab.share(self.config)
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
