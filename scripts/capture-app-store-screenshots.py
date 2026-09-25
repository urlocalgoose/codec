#!/usr/bin/env python3
"""Capture actual native views against an isolated, open-license review library.

Build the Debug simulator app first; DEBUG-only navigation hooks open the real
views and actual playback. Nothing connects to or changes a personal server.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.request

REPO = Path(__file__).resolve().parents[1]
BUNDLE = "sh.codie.codec.mobile"
SCENES = [("01-home", "home"), ("02-library", "library"),
          ("03-search", "search"), ("04-now-playing", "player"),
          ("05-visualizer", "visualizer")]


def run(args: list[str], **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--server", type=Path, required=True)
    parser.add_argument("--importer", type=Path, default=REPO / "src-tauri/target/release/codec_import")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--theme", default="graphite", help="Native theme identifier (default: graphite)")
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    if (root / "server-data").exists():
        raise SystemExit("Use a fresh output folder to guarantee an isolated library.")
    bundle = args.bundle.resolve()
    assert (bundle / "licenses/manifest.json").is_file()
    manifest = bundle / "loud-import.json"
    assert len(json.loads(manifest.read_text())["tracks"]) == 100
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    base = f"http://127.0.0.1:{port}"
    log = (root / "server.log").open("w")
    server = subprocess.Popen([str(args.server), "--addr", f"127.0.0.1:{port}",
                               "--data", str(root / "server-data"), "--web", "",
                               "--auth-token", ""], stdout=log, stderr=log)
    devices = []
    try:
        for _ in range(80):
            try:
                with urllib.request.urlopen(base + "/health", timeout=1):
                    break
            except OSError:
                if server.poll() is not None:
                    raise RuntimeError("Isolated server exited; see server.log")
                time.sleep(.25)
        else:
            raise RuntimeError("Isolated server did not become ready")
        (root / "music-root").mkdir()
        run([str(args.importer), str(root / "music-root"), str(manifest),
             "--server", base, "--report", str(root / "import-report.json")])
        with urllib.request.urlopen(base + "/api/v1/library") as response:
            library = json.load(response)
        assert len(library["tracks"]) == 100, "Screenshots require the verified 100-song library"
        runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-2"
        device_types = [
            ("iphone-6.9", "iPhone 17 Pro Max", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max"),
            ("ipad-13", "iPad Pro", "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB"),
        ]
        for family, device_name, device_type in device_types:
            udid = subprocess.check_output(["xcrun", "simctl", "create",
                device_name, device_type, runtime], text=True).strip()
            devices.append({"family": family, "udid": udid})
            run(["xcrun", "simctl", "boot", udid])
            run(["xcrun", "simctl", "bootstatus", udid, "-b"])
            # A new simulator may announce Apple Intelligence after boot. Wait
            # for this system banner to expire before taking product captures.
            time.sleep(35)
            run(["xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41",
                 "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
                 "--cellularMode", "active", "--cellularBars", "4",
                 "--batteryState", "charged", "--batteryLevel", "100"])
            run(["xcrun", "simctl", "install", udid, str(args.app)])
            destination = root / "screenshots" / family
            destination.mkdir(parents=True)
            env = os.environ.copy()
            env.update({"SIMCTL_CHILD_CODEC_SCREENSHOT": "home",
                "SIMCTL_CHILD_CODEC_SCREENSHOT_SERVER": base,
                "SIMCTL_CHILD_CODEC_SCREENSHOT_THEME": args.theme,
                "SIMCTL_CHILD_CODEC_SCREENSHOT_SEARCH": "Zane",
                "SIMCTL_CHILD_CODEC_SCREENSHOT_TRACK": "aura horizon",
                "SIMCTL_CHILD_CODEC_SCREENSHOT_PLAYBACK": "1"})
            run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE], env=env)
            time.sleep(12)
            # Capture Home after the first real playback/connection has settled.
            for name, scenario in SCENES[1:] + SCENES[:1]:
                env["SIMCTL_CHILD_CODEC_SCREENSHOT"] = scenario
                run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE], env=env)
                # Allow real audio, decoded artwork, and the spectrum trail to settle.
                time.sleep(12 if scenario == "visualizer" else 7)
                run(["xcrun", "simctl", "io", udid, "screenshot", "--type", "png",
                     "--mask", "black", str(destination / (name + ".png"))])
            run(["xcrun", "simctl", "terminate", udid, BUNDLE])
            run(["xcrun", "simctl", "shutdown", udid])
        (root / "capture-receipt.json").write_text(json.dumps({
            "bundleIdentifier": BUNDLE, "library": str(bundle), "tracks": 100,
            "server": "isolated loopback server, stopped after capture",
            "devices": devices, "screens": [s[0] for s in SCENES],
            "theme": args.theme,
            "rendering": "Actual native app views; actual licensed audio playback; no mock player state",
            "configuration": "Debug simulator build; screenshot navigation excluded from Release",
        }, indent=2) + "\n")
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
        log.close()
    print(root / "screenshots")


if __name__ == "__main__":
    main()
