#!/usr/bin/env python3
"""Destructive-to-fixture integration test: run only in a fresh disposable container.

Requires systemd, Python, the reviewed runtime.py, and a matching Linux archive.
Refuses to run without /.dockerenv or if /opt/codec/current already exists.
Never mount production data into the test container. See deployment-validation.md.
"""

import argparse
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import sqlite3
import struct
import subprocess
import tarfile
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener, ProxyHandler
import wave
import zlib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if not Path("/.dockerenv").is_file() or Path("/opt/codec/current").exists():
        parser.error("Use a fresh disposable Docker container with no installed Codec release")
    spec = importlib.util.spec_from_file_location("codec_runtime", Path(__file__).with_name("runtime.py"))
    runtime = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runtime)
    archive = args.archive.resolve()
    scratch = Path(tempfile.mkdtemp(prefix="codec-systemd-fixture-"))
    unpacked, metadata = runtime.unpack_verified(archive, Path(str(archive) + ".sha256"), scratch)
    token = None
    opener = build_opener(ProxyHandler({}))
    checks = []

    def api(path, method="GET", data=None, headers=None, port=8787, authenticated=True):
        request_headers = dict(headers or {})
        if authenticated and token:
            request_headers["Authorization"] = "Bearer " + token
        if isinstance(data, (dict, list)):
            data = json.dumps(data).encode()
            request_headers["Content-Type"] = "application/json"
        request = Request(f"http://127.0.0.1:{port}" + path, data=data, method=method, headers=request_headers)
        try:
            response = opener.open(request, timeout=3)
        except HTTPError as error:
            response = error
        with response:
            body = response.read()
            return response.status, dict(response.headers), body

    def decoded(path, **kwargs):
        status, _, body = api(path, **kwargs)
        assert 200 <= status < 300, (path, status)
        return json.loads(body)

    def command(script, bundle, **kwargs):
        return subprocess.run(["bash", str(unpacked / "scripts" / script), str(bundle),
                               "--sha256-file", str(bundle) + ".sha256", *kwargs.pop("extra", [])],
                              text=True, capture_output=True, **kwargs)

    # Import a synthetic existing credential, including every printable ASCII
    # character, to test systemd quoting and current-client migration together.
    token_file = scratch / "synthetic-auth-token"
    expected_token = "fixture-" + "".join(chr(code) for code in range(32, 127)) + "-  existing"
    token_file.write_text(expected_token + "\n")
    token_file.chmod(0o600)
    installed = command("ubuntu-install.sh", archive, extra=["--token-file", str(token_file)])
    assert installed.returncode == 0, installed.stderr
    environment_before = Path("/etc/codec/codec.env").read_bytes()
    token = json.loads(next(line.split("=", 1)[1] for line in environment_before.decode().splitlines()
                            if line.startswith("CODEC_AUTH_TOKEN=")))
    assert token == expected_token, "Installation changed the existing credential"
    token_file.unlink()
    assert token not in installed.stdout + installed.stderr
    assert Path("/etc/codec/codec.env").stat().st_mode & 0o077 == 0
    assert subprocess.run(["systemctl", "is-active", "--quiet", "codec.service"]).returncode == 0
    server_id = decoded("/health")["server_id"]
    assert api("/api/v1/library", authenticated=False)[0] == 401
    checks.append("Packaged installer starts hardened systemd service with private authentication")

    auth_helper = "/opt/codec/current/scripts/ubuntu-auth.sh"
    assert "sudo " + auth_helper in installed.stdout

    def verify_auth_helper():
        hidden = subprocess.run([auth_helper], text=True, capture_output=True)
        assert hidden.returncode != 0 and hidden.stdout == ""
        assert token not in hidden.stderr and "terminal" in hidden.stderr
        retrieved = subprocess.run([auth_helper, "--raw"], text=True, capture_output=True)
        assert retrieved.returncode == 0 and retrieved.stderr == ""
        assert retrieved.stdout == token + "\n", "Packaged helper did not return the configured token"
        assert Path("/etc/codec/codec.env").read_bytes() == environment_before

    verify_auth_helper()
    subprocess.run(["systemctl", "stop", "codec.service"], check=True)
    verify_auth_helper()
    assert subprocess.run(["systemctl", "is-active", "--quiet", "codec.service"]).returncode != 0
    subprocess.run(["systemctl", "start", "codec.service"], check=True)
    assert runtime.Systemd().healthy(5)
    assert api("/api/v1/library")[0] == 200
    checks.append("Packaged auth helper retrieves a working token, refuses noninteractive display, and reads without starting a stopped service")

    audio_output = io.BytesIO()
    with wave.open(audio_output, "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(8000)
        audio.writeframes(b"\0\0" * 800)
    audio_bytes = audio_output.getvalue()
    def png_chunk(kind, contents):
        return struct.pack(">I", len(contents)) + kind + contents + struct.pack(">I", zlib.crc32(kind + contents))
    png = (b"\x89PNG\r\n\x1a\n" + png_chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)) +
           png_chunk(b"IDAT", zlib.compress(b"\0\x40\x80\xc0\xff")) + png_chunk(b"IEND", b""))
    ids = ["deployment-existing-a", "deployment-existing-b"]
    for index, fingerprint in enumerate(("deployment-test-a", "deployment-test-b")):
        track = {"id": ids[index], "fingerprint": fingerprint, "path": "fixture.wav", "file_name": "fixture.wav",
                 "title": "Deployment fixture " + str(index), "artist": "Synthetic test", "album": "Fixture",
                 "playlist_ids": [], "size_bytes": len(audio_bytes), "is_liked": index == 0}
        assert api("/api/v1/tracks/" + fingerprint, "PUT", track)[0] == 204
        assert api("/api/v1/tracks/" + fingerprint + "/audio", "PUT", audio_bytes,
                   {"Content-Type": "audio/wav"})[0] == 204
        assert api("/api/v1/tracks/" + fingerprint + "/artwork", "PUT", png,
                   {"Content-Type": "image/png"})[0] == 204
    playlist = decoded("/api/v1/playlists", method="POST", data={"name": "Synthetic deployment playlist"})
    playlist_id = playlist["id"]
    ordered = [ids[1], ids[0]]
    assert api("/api/v1/playlists/" + playlist_id + "/tracks", "PUT", {"track_ids": ordered})[0] == 200
    assert api("/api/v1/playlists/" + playlist_id + "/artwork", "PUT", png,
               {"Content-Type": "image/png"})[0] == 204

    def verify_library():
        assert decoded("/health")["server_id"] == server_id
        status, headers, body = api("/api/v1/library")
        assert status == 200
        library = json.loads(body)
        assert {track["id"] for track in library["tracks"]} == set(ids)
        assert next(track for track in library["tracks"] if track["id"] == ids[0])["is_liked"]
        assert next(item for item in library["playlists"] if item["id"] == playlist_id)["track_ids"] == ordered
        assert api("/api/v1/library", headers={"If-None-Match": headers["Etag"]})[0] == 304
        status, _, body = api("/api/v1/tracks/deployment-test-a/audio", headers={"Range": "bytes=2-15"})
        assert status == 206 and body == audio_bytes[2:16]
        assert api("/api/v1/tracks/deployment-test-a/artwork")[2] == png
        assert api("/api/v1/playlists/" + playlist_id + "/artwork")[2] == png
        assert Path("/etc/codec/codec.env").read_bytes() == environment_before
        verify_auth_helper()
        return library

    verify_library()
    checks.append("Exact track IDs, playlist order, likes, audio Range, original PNG covers, auth and ETags verified")
    old_asset = sorted((unpacked / "web/_app/immutable").rglob("*.js"))[0]
    old_url = "/" + old_asset.relative_to(unpacked / "web").as_posix()
    old_bytes = old_asset.read_bytes()

    def fixture_archive(version, fail_health=False, crash_loop=False):
        target = scratch / f"codec-server-{version}-linux-{metadata['arch']}"
        shutil.copytree(unpacked, target)
        (target / ".archive-sha256").unlink()
        descriptor = dict(metadata, version=version)
        (target / "release.json").write_text(json.dumps(descriptor))
        (target / old_asset.relative_to(unpacked)).unlink()
        (target / "web/_app/immutable/deployment-new.js").write_text("// synthetic upgrade fixture\n")
        if fail_health:
            unit = target / "deploy/ubuntu/codec.service"
            unit.write_text(unit.read_text().replace("--addr 127.0.0.1:8787", "--addr 127.0.0.1:8788"))
        if crash_loop:
            unit = target / "deploy/ubuntu/codec.service"
            # Remain alive long enough for Type=simple's initial start job to
            # succeed; a synchronous start failure rolls back before any retry.
            lines = ["ExecStart=/usr/bin/timeout 0.2 /usr/bin/sleep 10" if line.startswith("ExecStart=") else line
                     for line in unit.read_text().splitlines()]
            unit.write_text("\n".join(lines).replace("RestartSec=3", "RestartSec=100ms")
                            .replace("StartLimitBurst=5", "StartLimitBurst=2") + "\n")
        files = sorted(path for path in target.rglob("*") if path.is_file() and path.name != "SHA256SUMS")
        (target / "SHA256SUMS").write_text("".join(runtime.sha256(path) + "  " + path.relative_to(target).as_posix() + "\n" for path in files))
        bundle = target.with_name(target.name + ".tar.gz")
        with tarfile.open(bundle, "w:gz") as output:
            output.add(target, arcname=target.name)
        Path(str(bundle) + ".sha256").write_text(runtime.sha256(bundle) + "  " + bundle.name + "\n")
        return bundle

    good = fixture_archive("systemd-good-fixture")
    updated = command("ubuntu-update.sh", good)
    assert updated.returncode == 0, updated.stderr
    assert "sudo " + auth_helper in updated.stdout and token not in updated.stdout + updated.stderr
    expected_release = Path("/opt/codec/current").resolve()
    expected_web = Path("/opt/codec/web/current").resolve()
    assert api(old_url)[2] == old_bytes
    assert not (expected_release / "web" / old_url.lstrip("/")).exists()
    verify_library()
    checks.append("Real systemd update preserves library/auth and serves old hashed asset absent from incoming release")
    bad = fixture_archive("systemd-health-failure-fixture", fail_health=True)
    process = subprocess.Popen(["bash", str(unpacked / "scripts/ubuntu-update.sh"), str(bad),
                                "--sha256-file", str(bad) + ".sha256", "--health-timeout", "5"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    deadline = time.monotonic() + 15
    wrote = False
    while process.poll() is None and time.monotonic() < deadline:
        try:
            if api("/health", port=8788)[0] == 200:
                assert api("/api/v1/tracks/deployment-test-b/liked", "PUT", {"liked": True}, port=8788)[0] == 200
                wrote = True
                break
        except (OSError, URLError):
            pass
        time.sleep(0.05)
    stdout, stderr = process.communicate(timeout=30)
    assert wrote, "Failed-version process did not receive the synthetic write"
    assert process.returncode != 0 and "Database was not rolled back" in stderr
    assert token not in stdout + stderr
    assert Path("/opt/codec/current").resolve() == expected_release
    assert Path("/opt/codec/web/current").resolve() == expected_web
    library = verify_library()
    assert next(track for track in library["tracks"] if track["id"] == ids[1])["is_liked"]
    assert api(old_url)[2] == old_bytes
    backups = sorted(Path("/var/backups/codec").glob("*.sqlite"))
    assert len(backups) >= 2
    for backup in backups:
        assert backup.stat().st_mode & 0o077 == 0
        with sqlite3.connect(backup) as connection:
            assert connection.execute("PRAGMA quick_check").fetchone()[0] == "ok"
    checks.append("Failed health check restores code/web/service; write accepted by failed version remains in live SQLite")
    checks.append("Private pre-update SQLite snapshots pass quick_check; original bytes and identities survive rollback")
    # A candidate which crashes can hit systemd's start limiter before its
    # health deadline. Rollback must clear that limiter and recover immediately.
    crashing = fixture_archive("systemd-crash-loop-fixture", crash_loop=True)
    def rate_limit_events():
        journal = subprocess.check_output(["journalctl", "-u", "codec.service", "--no-pager", "-o", "json"], text=True)
        # Ubuntu 24.04 retains Result=exit-code after the start limiter fires.
        # Observe the manager's actual refusal, not a version-specific Result.
        return sum(1 for line in journal.splitlines()
                   if json.loads(line).get("MESSAGE", "").endswith("Start request repeated too quickly."))
    previous_limits = rate_limit_events()
    process = subprocess.Popen(["bash", str(unpacked / "scripts/ubuntu-update.sh"), str(crashing),
                                "--sha256-file", str(crashing) + ".sha256", "--health-timeout", "3"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    stdout, stderr = process.communicate(timeout=15)
    assert rate_limit_events() > previous_limits, "Crash-loop fixture did not reach the actual systemd start limiter"
    assert process.returncode != 0 and "Database was not rolled back" in stderr
    assert token not in stdout + stderr
    assert Path("/opt/codec/current").resolve() == expected_release
    assert Path("/opt/codec/web/current").resolve() == expected_web
    assert next(track for track in verify_library()["tracks"] if track["id"] == ids[1])["is_liked"]
    checks.append("Rollback recovers immediately after systemd refuses further crash-loop starts")
    checks.append("Auth retrieval stays executable and returns the same credential after updates and both rollback paths")
    # Restore the real packaged application for any subsequent proxy tests.
    restored = command("ubuntu-update.sh", archive)
    assert restored.returncode == 0, restored.stderr
    verify_library()
    request = Request("http://127.0.0.1:8787/api/v2/playback/events", headers={"Authorization": "Bearer " + token})
    with opener.open(request, timeout=3) as stream:
        first = stream.readline()
        assert b"event:" in first or b":" in first
    checks.append("SSE responds promptly after restore to the original packaged application")
    report = {"os": Path("/etc/os-release").read_text(), "archive": archive.name,
              "archive_sha256": runtime.sha256(archive), "release": metadata,
              "checks": checks, "tracks": 2, "synthetic_only": True,
              "systemd_active": subprocess.run(["systemctl", "is-active", "--quiet", "codec.service"]).returncode == 0}
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": len(checks), "report": str(args.report), "synthetic_only": True}))


if __name__ == "__main__":
    main()
