#!/usr/bin/env python3
"""Exercise an extracted Linux release against a disposable loopback library.

Run on the release's architecture, e.g. Ubuntu CI for linux-amd64. Never reads
host settings for storage/auth, modifies a real library, or prints its generated token.
"""

import argparse
import importlib.util
import io
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import wave


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("release", type=Path, help="Extracted release directory")
    parser.add_argument("--caddy", help="Run the packaged proxy configuration using this Caddy executable")
    args = parser.parse_args()
    release = args.release.resolve()
    with tempfile.TemporaryDirectory(prefix="codec-release-smoke-") as temporary:
        directory = Path(temporary)
        token = secrets.token_hex(32)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        base = f"http://127.0.0.1:{port}"
        # Every saved server setting is overridden explicitly; never change HOME.
        env = dict(os.environ, CODEC_AUTH_TOKEN=token)
        with (directory / "server.log").open("wb") as log:
            process = subprocess.Popen([
                str(release / "codec-sync-server"), "--addr", f"127.0.0.1:{port}",
                "--data", str(directory / "data"), "--web", str(release / "web"),
            ], cwd=directory, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
            try:
                for attempt in range(100):
                    if process.poll() is not None:
                        raise RuntimeError("Release server exited before health check")
                    try:
                        with urllib.request.urlopen(base + "/health", timeout=1) as response:
                            assert response.status == 200
                        break
                    except (OSError, urllib.error.URLError):
                        time.sleep(0.1)
                else:
                    raise RuntimeError("Release server failed its loopback health check")
                request = urllib.request.Request(base + "/api/v1/library", headers={"Authorization": f"Bearer {token}"})
                with urllib.request.urlopen(request, timeout=5) as response:
                    library = json.load(response)
                    assert library.get("tracks") in (None, []), "Expected an isolated empty library"
                try:
                    urllib.request.urlopen(base + "/api/v1/library", timeout=5)
                    raise AssertionError("Library endpoint accepted an unauthenticated request")
                except urllib.error.HTTPError as error:
                    assert error.code == 401
                with urllib.request.urlopen(base + "/", timeout=5) as response:
                    assert response.status == 200 and b"<html" in response.read().lower()
                with urllib.request.urlopen(base + "/service-worker.js", timeout=5) as response:
                    assert response.status == 200 and b"codec-app-" in response.read()
                if args.caddy:
                    # Make the JSON large enough to exercise compression, then add
                    # real WAV bytes so the proxy check verifies HTTP Range too.
                    fingerprint = "release-proxy-fixture"
                    track = {"id": "release-proxy-fixture-id", "fingerprint": fingerprint,
                             "path": "fixture.wav", "file_name": "fixture.wav", "title": "Synthetic " * 150,
                             "artist": "Deployment regression", "album": "Fixture", "playlist_ids": []}
                    request = urllib.request.Request(base + "/api/v1/tracks/" + fingerprint,
                        method="PUT", data=json.dumps(track).encode(),
                        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
                    with urllib.request.urlopen(request, timeout=5) as response:
                        assert response.status == 204
                    wav = io.BytesIO()
                    with wave.open(wav, "wb") as audio:
                        audio.setnchannels(1)
                        audio.setsampwidth(2)
                        audio.setframerate(8000)
                        audio.writeframes(b"\0\0" * 800)
                    audio_path = "/api/v1/tracks/" + fingerprint + "/audio"
                    request = urllib.request.Request(base + audio_path, method="PUT", data=wav.getvalue(),
                        headers={"Authorization": "Bearer " + token, "Content-Type": "audio/wav"})
                    with urllib.request.urlopen(request, timeout=5) as response:
                        assert response.status == 204
                    helper_path = Path(__file__).resolve().parents[1] / "deploy/ubuntu/verify_caddy.py"
                    spec = importlib.util.spec_from_file_location("codec_proxy_verification", helper_path)
                    helper = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(helper)
                    js = next(path for path in (release / "web").rglob("*.js") if path.stat().st_size > 512)
                    result = helper.verify_proxy(release / "deploy/ubuntu/Caddyfile.example", base, token,
                                                 audio_path, 1, caddy=args.caddy,
                                                 static_path="/" + js.relative_to(release / "web").as_posix())
                    print("Caddy proxy smoke passed: " + "; ".join(result["checks"]))
                print("Release smoke passed: startup, SQLite library, authentication, web shell, service worker")
            finally:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


if __name__ == "__main__":
    main()
