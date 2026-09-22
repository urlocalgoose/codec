#!/usr/bin/env python3
"""Check the real Caddy proxy against verify_systemd.py's synthetic container."""

import argparse
import gzip
import json
from pathlib import Path
import subprocess
import socket
import tempfile
import time
from urllib.request import Request, build_opener, ProxyHandler
from urllib.error import URLError


def verify_proxy(config_path, upstream_base, token, audio_path, expected_tracks, caddy="caddy", static_path=None):
    """Exercise the packaged configuration, changing only its local addresses."""
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    proxy_base = f"http://127.0.0.1:{port}"
    config = ("{\n\tadmin off\n}\n" + Path(config_path).read_text()
              .replace("music.example.com {", proxy_base + " {")
              .replace("127.0.0.1:8787", upstream_base.removeprefix("http://")))
    checks = []
    opener = build_opener(ProxyHandler({}))
    with tempfile.TemporaryDirectory(prefix="codec-caddy-test-") as temporary:
        path = Path(temporary) / "Caddyfile"
        path.write_text(config)
        subprocess.run([caddy, "validate", "--config", str(path), "--adapter", "caddyfile"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        with (Path(temporary) / "proxy.log").open("w") as log:
            process = subprocess.Popen([caddy, "run", "--config", str(path), "--adapter", "caddyfile"], stdout=log, stderr=log)
            try:
                for attempt in range(100):
                    try:
                        with opener.open(proxy_base + "/health", timeout=1) as response:
                            assert response.status == 200
                        break
                    except URLError:
                        time.sleep(0.05)
                else:
                    raise AssertionError("Caddy did not start")

                def request(path, headers=None):
                    values = {"Authorization": "Bearer " + token}
                    values.update(headers or {})
                    return opener.open(Request(proxy_base + path, headers=values), timeout=3)

                with request("/", {"Accept-Encoding": "gzip"}) as response:
                    assert response.headers.get("Content-Encoding") == "gzip"
                    assert b"<html" in gzip.decompress(response.read())
                checks.append("HTML compressed with gzip through Caddy")
                if static_path:
                    with request(static_path, {"Accept-Encoding": "gzip"}) as response:
                        assert response.headers.get("Content-Encoding") == "gzip"
                        assert len(gzip.decompress(response.read())) >= 512
                    checks.append("JavaScript compressed with gzip through Caddy")
                with request("/api/v1/library", {"Accept-Encoding": "gzip"}) as response:
                    assert response.headers.get("Content-Encoding") == "gzip"
                    assert len(json.loads(gzip.decompress(response.read()))["tracks"]) == expected_tracks
                checks.append("JSON stays single encoded and decodable")
                with request(audio_path, {"Range": "bytes=0-15", "Accept-Encoding": "gzip"}) as response:
                    assert response.status == 206 and response.read().startswith(b"RIFF")
                    assert response.headers.get("Content-Encoding") is None
                checks.append("Audio Range remains 206 and uncompressed")
                with request("/api/v2/playback/events", {"Accept-Encoding": "gzip"}) as response:
                    assert response.headers.get("Content-Encoding") is None
                    assert "text/event-stream" in response.headers.get("Content-Type")
                    assert response.readline()
                checks.append("SSE streams immediately without compression")
            finally:
                process.terminate()
                process.wait(timeout=5)
    report = {"caddy": subprocess.check_output([caddy, "version"], text=True).strip(),
              "checks": checks, "public_tls_tested": False}
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if not Path("/.dockerenv").is_file():
        parser.error("Only run in the disposable deployment verification container")
    token = json.loads(next(line.split("=", 1)[1] for line in Path("/etc/codec/codec.env").read_text().splitlines()
                            if line.startswith("CODEC_AUTH_TOKEN=")))
    report = verify_proxy(args.config, "http://127.0.0.1:8787", token,
                          "/api/v1/tracks/deployment-test-a/audio", 2)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"passed": len(report["checks"]), "public_tls_tested": False}))


if __name__ == "__main__":
    main()
