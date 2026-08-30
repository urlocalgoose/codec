#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
BUNDLE_ID = "sh.codie.codec.mobile"
SCHEME = "Codec"


TRACKS = [
    {
        "file": "The Codec Ensemble/Warm Circuits/01 - Tape Hiss.mp3",
        "title": "Tape Hiss",
        "artist": "The Codec Ensemble",
        "album": "Warm Circuits",
        "track_number": 1,
        "liked": True,
        "playlists": ["Drive Home", "Tape Tests"],
    },
    {
        "file": "The Codec Ensemble/Warm Circuits/02 - Motor Start.mp3",
        "title": "Motor Start",
        "artist": "The Codec Ensemble",
        "album": "Warm Circuits",
        "track_number": 2,
        "liked": False,
        "playlists": ["Drive Home"],
    },
    {
        "file": "The Codec Ensemble/Warm Circuits/03 - Flywheel.mp3",
        "title": "Flywheel",
        "artist": "The Codec Ensemble",
        "album": "Warm Circuits",
        "track_number": 3,
        "liked": True,
        "playlists": ["Tape Tests"],
    },
    {
        "file": "The Codec Ensemble/Warm Circuits/04 - Counter Roll.mp3",
        "title": "Counter Roll",
        "artist": "The Codec Ensemble",
        "album": "Warm Circuits",
        "track_number": 4,
        "liked": False,
        "playlists": ["Drive Home", "Shared Aux Set"],
    },
    {
        "file": "The Codec Ensemble/Night Panels/01 - VU Glow.mp3",
        "title": "VU Glow",
        "artist": "The Codec Ensemble",
        "album": "Night Panels",
        "track_number": 1,
        "liked": True,
        "playlists": ["Night Bus", "Shared Aux Set"],
    },
    {
        "file": "The Codec Ensemble/Night Panels/02 - Standby Lamp.mp3",
        "title": "Standby Lamp",
        "artist": "The Codec Ensemble",
        "album": "Night Panels",
        "track_number": 2,
        "liked": False,
        "playlists": ["Night Bus"],
    },
    {
        "file": "The Codec Ensemble/Night Panels/03 - Headroom.mp3",
        "title": "Headroom",
        "artist": "The Codec Ensemble",
        "album": "Night Panels",
        "track_number": 3,
        "liked": True,
        "playlists": ["Night Bus", "Shared Aux Set"],
    },
    {
        "file": "Dot Matrix Choir/Paper Sleeve/01 - Liner Notes.mp3",
        "title": "Liner Notes",
        "artist": "Dot Matrix Choir",
        "album": "Paper Sleeve",
        "track_number": 1,
        "liked": False,
        "playlists": ["Sunday Stack"],
    },
    {
        "file": "Dot Matrix Choir/Paper Sleeve/02 - B-Side.mp3",
        "title": "B-Side",
        "artist": "Dot Matrix Choir",
        "album": "Paper Sleeve",
        "track_number": 2,
        "liked": True,
        "playlists": ["Sunday Stack", "Tape Tests"],
    },
    {
        "file": "Dot Matrix Choir/Paper Sleeve/03 - Runout Groove.mp3",
        "title": "Runout Groove",
        "artist": "Dot Matrix Choir",
        "album": "Paper Sleeve",
        "track_number": 3,
        "liked": False,
        "playlists": ["Sunday Stack"],
    },
]


SCENARIOS = [
    ("01-home", "home", "oxide"),
    ("02-library", "library", "oxide"),
    ("03-playlist", "playlist", "oxide"),
    ("04-search", "search", "oxide"),
    ("05-now-playing", "player", "oxide"),
    ("06-queue", "queue", "oxide"),
    ("07-add-to-playlist", "add-to-playlist", "paper"),
    ("08-aux", "aux", "forest"),
    ("09-themes", "themes", "paper"),
    ("10-settings", "settings", "oxide"),
]


def run(args: list[str], *, cwd: Path = REPO, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    print("+", " ".join(args))
    result = subprocess.run(args, cwd=cwd, env=env, text=True, check=False)
    if check and result.returncode != 0:
        raise SystemExit(result.returncode)
    return result


def output(args: list[str], *, cwd: Path = REPO) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True)


def choose_port(preferred: int = 8899) -> int:
    for port in range(preferred, preferred + 50):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            try:
                sock.bind(("127.0.0.1", port))
            except OSError:
                continue
            return port
    raise RuntimeError("no local demo server port available")


def wait_for_health(base_url: str) -> None:
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(f"{base_url}/health", timeout=1) as response:
                if response.status == 200:
                    return
        except (OSError, urllib.error.URLError):
            time.sleep(0.25)
    raise RuntimeError(f"server did not become healthy: {base_url}")


def booted_simulator() -> str:
    explicit = os.environ.get("IPHONE_SIM_UDID")
    if explicit:
        return explicit

    data = json.loads(output(["xcrun", "simctl", "list", "devices", "booted", "--json"]))
    for devices in data.get("devices", {}).values():
        for device in devices:
            if device.get("state") == "Booted" and "iPhone" in device.get("name", ""):
                return device["udid"]

    data = json.loads(output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
    for runtime, devices in data.get("devices", {}).items():
        if "iOS" not in runtime:
            continue
        for device in devices:
            if device.get("isAvailable") and "iPhone" in device.get("name", ""):
                run(["xcrun", "simctl", "boot", device["udid"]], check=False)
                run(["xcrun", "simctl", "bootstatus", device["udid"], "-b"])
                return device["udid"]
    raise RuntimeError("no available iPhone simulator found")


def write_manifest(session: Path) -> Path:
    playlists: dict[str, list[dict[str, dict[str, str]]]] = {}
    manifest_tracks = []
    for index, track in enumerate(TRACKS, start=1):
        isrc = f"USCOD260{index:03d}"
        item = {
            "file": track["file"],
            "title": track["title"],
            "artist": track["artist"],
            "album": track["album"],
            "album_artist": track["artist"],
            "track_number": track["track_number"],
            "disc_number": 1,
            "year": 2026,
            "duration_ms": 24000,
            "explicit": False,
            "liked": track["liked"],
            "playlists": track["playlists"],
            "identifiers": {
                "isrc": isrc,
                "spotify_track_id": f"codec-demo-track-{index:03d}",
                "youtube_video_id": f"codec_demo_{index:03d}",
            },
            "source_urls": {
                "spotify": f"https://open.spotify.com/track/codec-demo-track-{index:03d}",
                "youtube": f"https://www.youtube.com/watch?v=codec_demo_{index:03d}",
            },
        }
        manifest_tracks.append(item)
        reference = {"identifiers": {"isrc": isrc}}
        for playlist in track["playlists"]:
            playlists.setdefault(playlist, []).append(reference)

    manifest = {
        "schema": "loud.import.v1",
        "source": {
            "name": "codec-blog-demo",
            "generated_at": "2026-08-28T12:00:00Z",
            "base_path": "files",
            "spotify_source": "blog-screenshots",
        },
        "tracks": manifest_tracks,
        "playlists": [
            {"name": name, "mode": "replace", "tracks": tracks}
            for name, tracks in playlists.items()
        ],
    }

    path = session / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    return path


def create_aux(base_url: str) -> None:
    request = urllib.request.Request(f"{base_url}/api/v1/aux", method="POST", data=b"{}")
    request.add_header("Content-Type", "application/json")
    try:
        urllib.request.urlopen(request, timeout=2).read()
    except (OSError, urllib.error.URLError):
        pass


def screenshot(udid: str, base_url: str, screenshots_dir: Path, name: str, scenario: str, theme: str) -> None:
    run(["xcrun", "simctl", "spawn", udid, "defaults", "write", BUNDLE_ID, "loud.serverURL", base_url])
    run(["xcrun", "simctl", "spawn", udid, "defaults", "write", BUNDLE_ID, "loud.serverToken", ""])
    run(["xcrun", "simctl", "spawn", udid, "defaults", "write", BUNDLE_ID, "loud.theme", theme])
    run(["xcrun", "simctl", "terminate", udid, BUNDLE_ID], check=False)

    env = os.environ.copy()
    env["SIMCTL_CHILD_CODEC_SCREENSHOT"] = scenario
    env["SIMCTL_CHILD_CODEC_SCREENSHOT_SERVER"] = base_url
    env["SIMCTL_CHILD_CODEC_SCREENSHOT_THEME"] = theme
    run(["xcrun", "simctl", "launch", "--terminate-running-process", udid, BUNDLE_ID], env=env)
    time.sleep(4.0 if name == "01-home" else 2.0)

    destination = screenshots_dir / f"{name}.png"
    if destination.exists():
        destination.unlink()
    run(["xcrun", "simctl", "io", udid, "screenshot", "--type", "png", "--mask", "black", str(destination)])


def main() -> int:
    if shutil.which("ffmpeg") is None:
        print("ffmpeg is required for fake MP3 generation", file=sys.stderr)
        return 1

    stamp = time.strftime("%Y%m%d-%H%M%S")
    session = REPO / "promo" / "blog-demo" / stamp
    files = session / "import" / "files"
    music_root = session / "music-root"
    server_data = session / "server-data"
    screenshots_dir = REPO / "promo" / "blog-screenshots"
    screenshots_dir.mkdir(parents=True, exist_ok=True)
    music_root.mkdir(parents=True, exist_ok=True)
    server_data.mkdir(parents=True, exist_ok=True)

    run([str(REPO / "scripts" / "make-demo-library.sh"), str(files)])
    manifest = write_manifest(session / "import")

    port = choose_port()
    base_url = f"http://127.0.0.1:{port}"
    server = subprocess.Popen(
        [
            "go",
            "run",
            "./cmd/codec-sync-server",
            "--addr",
            f"127.0.0.1:{port}",
            "--data",
            str(server_data),
            "--web",
            "",
        ],
        cwd=REPO / "sync-server",
        text=True,
    )

    try:
        wait_for_health(base_url)
        run([
            "cargo",
            "run",
            "--locked",
            "--manifest-path",
            "src-tauri/Cargo.toml",
            "--bin",
            "codec_import",
            "--",
            str(music_root),
            str(manifest),
            "--server",
            base_url,
        ])
        create_aux(base_url)

        udid = booted_simulator()
        run(["xcrun", "simctl", "bootstatus", udid, "-b"])
        run([
            "xcrun",
            "simctl",
            "status_bar",
            udid,
            "override",
            "--time",
            "9:41",
            "--operatorName",
            "Codec",
            "--wifiBars",
            "3",
            "--cellularBars",
            "4",
            "--batteryState",
            "charged",
            "--batteryLevel",
            "100",
        ], check=False)

        derived_data = REPO / "build" / "ios-blog-sim"
        run([
            "xcodebuild",
            "-quiet",
            "-project",
            "ios/CodecMobile/Codec.xcodeproj",
            "-scheme",
            SCHEME,
            "-configuration",
            "Debug",
            "-destination",
            f"id={udid}",
            "-derivedDataPath",
            str(derived_data),
            "build",
        ])

        app_bundle = derived_data / "Build" / "Products" / "Debug-iphonesimulator" / "Codec.app"
        run(["xcrun", "simctl", "install", udid, str(app_bundle)])

        for name, scenario, theme in SCENARIOS:
            screenshot(udid, base_url, screenshots_dir, name, scenario, theme)

        print(f"screenshots: {screenshots_dir}")
        for path in sorted(screenshots_dir.glob("*.png")):
            print(f"  {path}")
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=5)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
