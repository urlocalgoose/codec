#!/usr/bin/env python3
"""Exercise frozen App Store CodecKit against two disposable candidate servers.

This intentionally accepts no server URL or existing data directory. Every
mutation targets private temporary loopback servers, never the manual lab or a
deployed library. Requires macOS + Swift 6 and Go (unless --server-binary is set).
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import os
from pathlib import Path
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import wave
import zlib

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "scripts/client-compatibility"


def run(command: list[str], log: Path, *, cwd: Path = ROOT, timeout: int = 180) -> None:
    with log.open("wb") as output:
        result = subprocess.run(command, cwd=cwd, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"{Path(command[0]).name} failed; inspect {log}")


def request(base: str, path: str, token: str, *, method: str = "GET", body: bytes | None = None,
            content_type: str = "application/json") -> tuple[bytes, int]:
    req = urllib.request.Request(base + path, data=body, method=method, headers={
        "Authorization": f"Bearer {token}", "Content-Type": content_type,
    })
    with urllib.request.urlopen(req, timeout=3) as response:
        return response.read(), response.status


def free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def make_media() -> tuple[bytes, bytes]:
    """Small generated tone/PNG: no copyrighted music and no codec dependencies."""
    audio = io.BytesIO()
    with wave.open(audio, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(8000)
        wav.writeframes(b"".join(struct.pack("<h", int(2000 * math.sin(2 * math.pi * 440 * n / 8000))) for n in range(800)))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">2I5B", 4, 4, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress((b"\x00" + b"\x40\x90\xb0" * 4) * 4)) + chunk(b"IEND", b"")
    return audio.getvalue(), png


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-binary", type=Path, help="Test this candidate binary instead of building current Go sources")
    parser.add_argument("--report-dir", type=Path, default=ROOT / ".codec-dev/reports/client-compatibility")
    parser.add_argument("--aux-v1-retirement", action="store_true", help="Explicit security exception: require legacy Aux HTTP 410 while testing unchanged owner APIs; does not claim legacy Aux compatibility")
    args = parser.parse_args()
    if sys.platform != "darwin" or not shutil.which("swift"):
        parser.error("This gate compiles the actual frozen Swift client and requires macOS with Swift 6. A skip is not a pass.")
    report_dir = args.report_dir.expanduser().resolve()
    report_dir.mkdir(parents=True, exist_ok=True)
    # A failed rerun must not leave an earlier green release receipt behind.
    (report_dir / "report.json").write_text(json.dumps({"passed": False, "status": "running"}) + "\n")
    for phase in ("exercise", "after-restart"):
        (report_dir / f"{phase}.json").unlink(missing_ok=True)
    started = time.monotonic()
    contract = json.loads((PACKAGE / "contract.json").read_text())
    for relative, expected in contract["files"].items():
        actual = hashlib.sha256((PACKAGE / relative).read_bytes()).hexdigest()
        if actual != expected:
            raise RuntimeError(f"Frozen shipped-client source modified: {relative}; restore it instead of refreshing its hash")
    scratch = ROOT / ".codec-dev/cache/client-compatibility-swift"
    run(["swift", "build", "--package-path", str(PACKAGE), "--scratch-path", str(scratch)], report_dir / "swift-build.log")
    runner = scratch / "debug/client-compatibility"
    processes: list[subprocess.Popen] = []
    phases: list[dict] = []
    with tempfile.TemporaryDirectory(prefix="codec-client-compatibility-") as raw_temp:
        temp = Path(raw_temp)
        binary = args.server_binary.expanduser().resolve() if args.server_binary else temp / "codec-server"
        if args.server_binary:
            if not binary.is_file() or not os.access(binary, os.X_OK):
                raise RuntimeError("--server-binary must name an executable candidate server")
        else:
            run(["go", "build", "-o", str(binary), "./cmd/codec-sync-server"], report_dir / "go-build.log", cwd=ROOT / "sync-server")
        binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
        ports = [free_port(), free_port()]
        while ports[1] == ports[0]:
            ports[1] = free_port()
        bases = [f"http://127.0.0.1:{port}" for port in ports]
        tokens = [secrets.token_urlsafe(32), secrets.token_urlsafe(32)]
        audio, artwork = make_media()
        audio_file, artwork_file = temp / "tone.wav", temp / "cover.png"
        audio_file.write_bytes(audio)
        artwork_file.write_bytes(artwork)

        def start_servers() -> list[str]:
            identities = []
            for index in range(2):
                environment = dict(os.environ, CODEC_AUTH_TOKEN=tokens[index])
                environment.pop("LOUD_AUTH_TOKEN", None)
                with (temp / f"server-{index}.log").open("ab") as log:
                    process = subprocess.Popen([
                        str(binary), "--addr", f"127.0.0.1:{ports[index]}",
                        "--data", str(temp / f"data-{index}"), "--web", "",
                    ], cwd=temp, env=environment, stdout=log, stderr=subprocess.STDOUT)
                processes.append(process)
                deadline = time.monotonic() + 15
                while True:
                    if process.poll() is not None:
                        raise RuntimeError(f"Disposable server {index + 1} exited before readiness")
                    try:
                        health, _ = request(bases[index], "/health", tokens[index])
                        identities.append(json.loads(health)["server_id"])
                        break
                    except (urllib.error.URLError, OSError):
                        if time.monotonic() > deadline:
                            raise RuntimeError(f"Disposable server {index + 1} did not become ready")
                        time.sleep(0.05)
            return identities

        def stop_servers() -> None:
            for process in processes:
                if process.poll() is None:
                    process.terminate()
            for process in processes:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            processes.clear()

        try:
            initial_identities = start_servers()
            for index in range(2):
                for track_index in range(2):
                    fingerprint = hashlib.sha256(f"compat-server-{index}-track-{track_index}".encode()).hexdigest()
                    track = {
                        "fingerprint": fingerprint, "id": f"track_{fingerprint}",
                        "title": f"Server {index + 1} tone {track_index + 1}", "artist": "Generated fixture",
                        "album": "Protocol compatibility", "file_name": "tone.wav", "duration_seconds": 0.1,
                        "playlist_ids": [], "is_liked": False,
                    }
                    path = f"/api/v1/tracks/{fingerprint}"
                    request(bases[index], path, tokens[index], method="PUT", body=json.dumps(track).encode())
                    request(bases[index], path + "/audio", tokens[index], method="PUT", body=audio, content_type="audio/wav")
                    request(bases[index], path + "/artwork", tokens[index], method="PUT", body=artwork, content_type="image/png")

            for phase in ("exercise", "after-restart"):
                if phase == "after-restart":
                    stop_servers()
                    if start_servers() != initial_identities:
                        raise RuntimeError("Server identities changed after restart")
                config = {
                    "serverA": bases[0], "serverB": bases[1], "tokenA": tokens[0], "tokenB": tokens[1],
                    "audioFile": str(audio_file), "artworkFile": str(artwork_file), "phase": phase,
                    "reportFile": str(report_dir / f"{phase}.json"),
                    "allowAuxV1Retirement": args.aux_v1_retirement,
                }
                config_file = temp / "private-configuration.json"
                config_file.touch(mode=0o600)
                config_file.write_text(json.dumps(config))
                run([str(runner), str(config_file)], report_dir / f"{phase}.log", timeout=90)
                phases.append(json.loads((report_dir / f"{phase}.json").read_text()))
        finally:
            stop_servers()

    report = {
        "passed": True, "client": {key: contract[key] for key in ("version", "build", "sourceCommit", "files")},
        "candidateBinarySHA256": binary_hash, "elapsedSeconds": round(time.monotonic() - started, 2),
        "scope": "Two disposable loopback candidate servers; unchanged shipped Swift CodecKit over real HTTP",
        "checks": phases,
        "legacyAuxCompatible": not args.aux_v1_retirement,
        "intentionalBreakingChanges": (["Aux v1 creation/list/join retired with HTTP 410; existing guest sessions revoked; new Aux requires codec.aux.v2"] if args.aux_v1_retirement else []),
        "compatibilityScope": ("Unchanged iOS owner APIs with an explicit Aux v1 security retirement exception" if args.aux_v1_retirement else "Full frozen iOS API contract, including legacy Aux"),
        "limitations": ["Not an iOS UI or AVAudioSession test", "No physical-device sleep, Bluetooth, interruptions or cellular/TLS verification", "Synthetic tone and PNG verify HTTP transport, not codec decoding or every import format"],
    }
    (report_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    count = sum(len(phase["checks"]) for phase in phases)
    print(f"PASS ({'owner APIs; Aux v1 intentionally retired' if args.aux_v1_retirement else 'full frozen contract'}): iOS {contract['version']} ({contract['build']}) client, {count} checks, two candidate servers + restart, {report['elapsedSeconds']}s")
    print(f"Report: {report_dir / 'report.json'}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
