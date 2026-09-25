#!/usr/bin/env python3
"""Persistent, private two-server Codec lab. Never deploys or reuses production auth.

All mutable data lives in this checkout's ignored .codec-dev directory. Servers
bind loopback; `share` optionally adds dedicated private Tailscale HTTPS ports.
"""
import argparse
import contextlib
import fcntl
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / ".codec-dev"
DEFAULT_BUNDLE = Path.home() / "Documents/S2Y/deployments/open-license-test-100"
SCHEMA = "codec.local-dev.v1"
PORTS = {"a": 8791, "b": 8792, "site": 9092}
HTTPS_PORTS = {"a": 8441, "b": 8442, "site": 8444}


def read_json(path, default=None):
    if path.is_symlink():
        raise RuntimeError(f"Refusing symlinked lab metadata: {path}")
    return json.loads(path.read_text()) if path.exists() else default


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    if path.is_symlink() or temporary.is_symlink():
        raise RuntimeError(f"Refusing symlinked lab metadata: {path}")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def capture(args):
    return subprocess.check_output(args, cwd=ROOT, text=True, stderr=subprocess.PIPE).strip()


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@contextlib.contextmanager
def lab_lock():
    if STATE.is_symlink():
        raise RuntimeError("Refusing a symlinked .codec-dev directory")
    STATE.mkdir(mode=0o700, exist_ok=True)
    STATE.chmod(0o700)
    # Reject nested links except the two intentionally managed public pointers.
    for folder in ("instances", "builds", "logs", "reports"):
        path = STATE / folder
        if path.is_symlink():
            raise RuntimeError(f"Refusing symlinked lab storage: {path}")
        path.mkdir(exist_ok=True)
    lock_path = STATE / "manager.lock"
    if lock_path.is_symlink():
        raise RuntimeError("Refusing symlinked lab lock")
    with lock_path.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Another local lab command is running; wait for it to finish") from None
        yield


def configuration():
    path = STATE / "config.json"
    config = read_json(path)
    if config is None:
        config = {"schema": SCHEMA, "repository": str(ROOT),
                  "instances": {name: {"port": port} for name, port in PORTS.items()}}
        write_json(path, config)
    if config.get("schema") != SCHEMA or config.get("repository") != str(ROOT):
        raise RuntimeError("Lab config belongs to a different checkout or schema")
    ports = [config["instances"][name]["port"] for name in PORTS]
    if len(set(ports)) != 3 or any(type(port) is not int or not 1024 <= port <= 65535 or port in (8787, 8788) for port in ports):
        raise RuntimeError("Choose three distinct local ports (1024–65535), excluding production forwarders 8787/8788")
    for name in PORTS:
        directory = instance_dir(name)
        if directory.is_symlink():
            raise RuntimeError("Refusing symlinked instance storage")
        directory.mkdir(mode=0o700, exist_ok=True)
        if name != "site":
            for path in (directory / "auth-token", directory / "data"):
                if path.is_symlink():
                    raise RuntimeError("Refusing symlinked instance data/auth")
            token_file = directory / "auth-token"
            if not token_file.exists():
                with token_file.open("x") as stream:
                    stream.write(secrets.token_urlsafe(32) + "\n")
            token_file.chmod(0o600)
    return config


def instance_dir(name):
    return STATE / "instances" / name


def token(name):
    path = instance_dir(name) / "auth-token"
    if instance_dir(name).is_symlink() or path.is_symlink() or not path.is_file():
        raise RuntimeError("Refusing symlinked or missing local auth")
    value = path.read_text().strip()
    if not value:
        raise RuntimeError("Local auth token is empty; refusing an unauthenticated server")
    return value


def origin(config, name):
    return f"http://127.0.0.1:{config['instances'][name]['port']}"


def get(config, name, path, authenticated=True):
    # Deliberately no arbitrary URL option or HTTP proxies/redirects for lab credentials.
    connection = http.client.HTTPConnection("127.0.0.1", config["instances"][name]["port"], timeout=10)
    headers = {"Authorization": "Bearer " + token(name)} if authenticated else {}
    try:
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        data = response.read()
        if response.status != 200:
            raise RuntimeError(f"Local {name} {path}: HTTP {response.status}")
        return json.loads(data)
    finally:
        connection.close()


def logged(args, name, cwd=ROOT, env=None):
    log = STATE / "logs" / f"{name}.log"
    print(f"Running {name}…", flush=True)
    with log.open("w") as output:
        result = subprocess.run(args, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"{name} failed; see {log}")


def source_digest(paths, tool=""):
    digest = hashlib.sha256(tool.encode())
    for path in sorted(paths):
        if path.is_symlink():
            raise RuntimeError(f"Build input is a symlink: {path}")
        digest.update(str(path.relative_to(ROOT)).encode() + b"\0")
        digest.update(bytes.fromhex(sha256(path)))
    return digest.hexdigest()


def server_source_digest():
    files = list((ROOT / "sync-server").rglob("*.go")) + [ROOT / "sync-server/go.mod", ROOT / "sync-server/go.sum"]
    return source_digest(files, capture(["go", "env", "GOVERSION"]))


def site_source_digest():
    files = [p for p in (ROOT / "site").rglob("*") if p.is_file()
             and not any(part in ("dist", "__pycache__", ".wrangler", "node_modules") or part.startswith(".site-build-")
                         for part in p.relative_to(ROOT / "site").parts)]
    return source_digest(files + list((ROOT / "docs").glob("*.schema.json")))


def publish_tree(source, destination, prepare=None):
    """Interrupted copies never become a reusable complete build directory."""
    if destination.is_symlink():
        raise RuntimeError("Refusing symlinked build cache")
    with tempfile.TemporaryDirectory(prefix=".pending-", dir=STATE / "builds") as temporary:
        staged = Path(temporary) / "output"
        shutil.copytree(source, staged)
        if prepare:
            prepare(staged)
        staged.rename(destination)


def switch_link(name, target):
    pointer = STATE / name
    if pointer.exists() and not pointer.is_symlink():
        raise RuntimeError(f"Managed pointer is not a symlink: {pointer}")
    temporary = STATE / (name + ".next")
    temporary.unlink(missing_ok=True)
    temporary.symlink_to(target)
    temporary.replace(pointer)


def build():
    builder = load_module("codec_local_builder", ROOT / "scripts/build-server-release.py")
    web_digest = builder.content_id()
    commit = capture(["git", "rev-parse", "HEAD"])
    bun = capture(["bun", "--version"])
    web_id = hashlib.sha256(f"{web_digest}:{commit}:{bun}".encode()).hexdigest()
    web_export = STATE / "builds" / ("web-" + web_id)
    if web_export.is_symlink():
        raise RuntimeError("Refusing symlinked build cache")
    if web_export.exists() and not (web_export / "web-build.json").exists():
        shutil.rmtree(web_export)  # Incomplete interrupted export; no published descriptor.
    if not web_export.exists():
        logged([sys.executable, "scripts/build-server-release.py", "--version", "local",
                "--web-only", "--web-output-dir", str(web_export)], "build-web")
    descriptor = read_json(web_export / "web-build.json")
    if not descriptor or descriptor["source_sha256"] != web_digest or descriptor["files"] != builder.web_files(web_export / "web"):
        raise RuntimeError("Cached local web artifact failed integrity verification")
    # Keep immutable chunks for old open tabs, just as the production updater does.
    runtime = STATE / "builds" / ("runtime-" + web_id)
    if runtime.is_symlink():
        raise RuntimeError("Refusing symlinked build cache")
    def retain_old_chunks(staged):
        old = STATE / "web"
        if old.exists():
            for source in (old / "_app/immutable").rglob("*"):
                if source.is_file():
                    destination = staged / source.relative_to(old)
                    if destination.exists():
                        if sha256(source) != sha256(destination):
                            raise RuntimeError("Immutable asset changed without a name change")
                    else:
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(source, destination)
    if not runtime.exists():
        publish_tree(web_export / "web", runtime, retain_old_chunks)

    server_digest = server_source_digest()
    server_dir = STATE / "builds" / ("server-" + server_digest)
    binary = server_dir / "codec-sync-server"
    if server_dir.is_symlink() or binary.is_symlink():
        raise RuntimeError("Refusing symlinked build cache")
    if binary.exists() and not (server_dir / "integrity.json").exists():
        binary.unlink()  # A successful build is reusable only after its receipt exists.
    if not binary.exists():
        server_dir.mkdir(exist_ok=True)
        logged(["go", "build", "-mod=readonly", "-trimpath", "-o", str(binary), "./cmd/codec-sync-server"],
               "build-server", ROOT / "sync-server")
        if server_source_digest() != server_digest:
            binary.unlink(missing_ok=True)
            raise RuntimeError("Server inputs changed during build; rerun local:up")
        write_json(server_dir / "integrity.json", {"sha256": sha256(binary)})
    if read_json(server_dir / "integrity.json", {}).get("sha256") != sha256(binary):
        raise RuntimeError("Cached local server binary failed integrity verification")

    site_digest = site_source_digest()
    site = STATE / "builds" / ("site-" + site_digest)
    if site.is_symlink():
        raise RuntimeError("Refusing symlinked build cache")
    if not site.exists():
        logged([sys.executable, "site/build.py"], "build-site")
        if site_source_digest() != site_digest:
            raise RuntimeError("Site inputs changed during build; rerun local:up")
        publish_tree(ROOT / "site/dist", site)
    switch_link("web", runtime)
    switch_link("site", site)
    candidate = {"schema": "codec.local-candidate.v1", "git_commit": commit,
                 "web_build_id": descriptor["build_id"], "web_export": str(web_export),
                 "server_binary": str(binary), "server_source_sha256": server_digest,
                 "server_binary_sha256": sha256(binary), "site_source_sha256": site_digest,
                 "built_at": int(time.time()), "release_approved": False}
    write_json(STATE / "candidate.json", candidate)
    return candidate


def process_identity(pid):
    try:
        started = capture(["ps", "-p", str(pid), "-o", "lstart="])
        command = capture(["ps", "-p", str(pid), "-o", "command="])
        return started, command
    except subprocess.CalledProcessError:
        return None


def running(name):
    record = read_json(instance_dir(name) / "process.json")
    if not record:
        return None
    expected = str(STATE / "site") if name == "site" else str(instance_dir(name) / "data")
    if type(record.get("pid")) is not int or record["pid"] <= 1 or record.get("ownership_argument") != expected:
        return None
    identity = process_identity(record["pid"])
    # The owned path must be a complete argument, not a prefix of somebody else's path.
    if identity and identity[0] == record["started"] and " " + expected + " " in " " + identity[1] + " ":
        return record
    return None


def stop_one(name):
    record = running(name)
    if record:
        os.kill(record["pid"], signal.SIGTERM)
        deadline = time.monotonic() + 8
        while running(name) and time.monotonic() < deadline:
            time.sleep(0.1)
        if running(name):
            raise RuntimeError(f"Local {name} did not stop; inspect its log before retrying")
    (instance_dir(name) / "process.json").unlink(missing_ok=True)


def require_free(port):
    occupied = f"Port {port} belongs to another process. Nothing was killed; choose a free port in .codec-dev/config.json"
    # On macOS SO_REUSEADDR may bind a specific address alongside an existing
    # wildcard listener. Check for a live TCP listener before the bind probe.
    with socket.socket() as client:
        client.settimeout(0.25)
        try:
            client.connect(("127.0.0.1", port))
        except ConnectionRefusedError:
            pass
        except OSError:
            raise RuntimeError(occupied) from None
        else:
            raise RuntimeError(occupied)
    with socket.socket() as listener:
        # Match Go/Python server restart semantics: a closed connection's
        # TIME_WAIT must not look like a live process still owning the port.
        # Never use SO_REUSEPORT, which could share a real listener's port.
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            listener.bind(("127.0.0.1", port))
            listener.listen(1)
        except OSError:
            raise RuntimeError(occupied) from None


def start_one(config, name, candidate):
    existing = running(name)
    identity = candidate["server_binary"] if name != "site" else sys.executable
    port = config["instances"][name]["port"]
    if existing and existing["binary"] == identity and existing["port"] == port:
        return False
    if existing and existing["port"] != port:
        require_free(port)
    stop_one(name)
    require_free(port)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("CODEC_", "LOUD_"))}
    if name == "site":
        owner_arg = str(STATE / "site")
        args = [sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1", "--directory", owner_arg]
    else:
        owner_arg = str(instance_dir(name) / "data")
        args = [identity, "--addr", f"127.0.0.1:{port}", "--data", owner_arg, "--web", str(STATE / "web")]
        env["CODEC_AUTH_TOKEN"] = token(name)
    with (instance_dir(name) / "server.log").open("ab") as log:
        child = subprocess.Popen(args, cwd=instance_dir(name), env=env, stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=log, start_new_session=True)
    process = process_identity(child.pid)
    if not process:
        raise RuntimeError(f"Local {name} exited immediately; inspect its server.log")
    write_json(instance_dir(name) / "process.json", {"pid": child.pid, "started": process[0],
               "ownership_argument": owner_arg, "binary": identity, "port": port})
    for _ in range(100):
        if child.poll() is not None:
            raise RuntimeError(f"Local {name} exited; inspect its server.log")
        try:
            if name == "site":
                with urllib.request.urlopen(origin(config, name) + "/", timeout=1) as response:
                    if response.status != 200:
                        raise OSError("Site not ready")
            else:
                get(config, name, "/api/v1/library")
            return True
        except (OSError, RuntimeError, http.client.HTTPException):
            time.sleep(0.1)
    raise RuntimeError(f"Local {name} failed startup; inspect its server.log")


def bundle_path(bundle, base, file):
    relative = PurePosixPath(base or ".") / file
    if relative.is_absolute() or ".." in relative.parts or "\\" in str(relative):
        raise RuntimeError("Demo bundle reference escapes its directory")
    path = bundle / str(relative)
    if any((bundle / Path(*relative.parts[:i])).is_symlink() for i in range(1, len(relative.parts) + 1)):
        raise RuntimeError("Demo bundle may not contain symlink references")
    if not path.is_file():
        raise RuntimeError(f"Missing demo file: {relative}")
    return path


def make_bundle(bundle):
    manifest_path = bundle_path(bundle, ".", "loud-import.json")
    manifest = read_json(manifest_path)
    if manifest.get("schema") != "loud.import.v1" or not manifest.get("tracks"):
        raise RuntimeError("Demo needs a nonempty loud.import.v1 manifest")
    files = {manifest_path}
    base = manifest.get("source", {}).get("base_path", ".")
    for entry in manifest["tracks"]:
        files.add(bundle_path(bundle, base, entry["file"]))
    for entry in manifest["tracks"] + manifest.get("playlists", []):
        if isinstance(entry.get("artwork"), dict):
            files.add(bundle_path(bundle, base, entry["artwork"]["file"]))
    for name, key in (("track-artwork.json", "tracks"), ("playlist-artwork.json", "playlists")):
        if not (bundle / name).exists():
            continue
        files.add(bundle_path(bundle, ".", name))
        sidecar = read_json(bundle / name)
        for entry in sidecar.get(key, []):
            files.add(bundle_path(bundle, sidecar.get("base_path", "."), entry["artwork"]["file"]))
    destination = STATE / "demo.loud.zip"
    temporary = destination.with_suffix(".tmp")
    print(f"Packing {len(manifest['tracks'])} demo songs and supplied artwork (local files only)…", flush=True)
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_STORED) as archive:
        for path in sorted(files):
            archive.write(path, path.relative_to(bundle).as_posix())
    temporary.replace(destination)
    return destination, len(manifest["tracks"])


def seed_one(config, name, archive, expected):
    print(f"Importing demo into local {name.upper()}…", flush=True)
    connection = http.client.HTTPConnection("127.0.0.1", config["instances"][name]["port"], timeout=120)
    try:
        with archive.open("rb") as stream:
            connection.request("POST", "/api/v1/import/bundle", body=stream,
                               headers={"Authorization": "Bearer " + token(name), "Content-Type": "application/zip",
                                        "Content-Length": str(archive.stat().st_size)})
            response = connection.getresponse()
            body = response.read()
        if response.status != 202:
            raise RuntimeError(f"Local {name} import upload failed: HTTP {response.status}")
        job_id = json.loads(body)["id"]
    finally:
        connection.close()
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        job = get(config, name, "/api/v1/import/jobs/" + job_id)
        if job["state"] == "done":
            if job["skipped"] or job["artwork_failed"] or job["artwork_missing"] or job["added"] + job["existing"] != expected:
                raise RuntimeError(f"Local {name} import was incomplete; inspect its import job before retrying")
            write_json(instance_dir(name) / "seed.json", {"expected_tracks": expected, "import": job,
                       "bundle_sha256": sha256(archive), "seeded_at": int(time.time())})
            return
        if job["state"] == "failed":
            raise RuntimeError(f"Local {name} demo import failed: {job.get('error', 'unknown')}")
        time.sleep(0.2)
    raise RuntimeError(f"Local {name} import still running; inspect local import status")


def up(config, bundle):
    needs_seed = [name for name in ("a", "b") if not (instance_dir(name) / "seed.json").exists()]
    if needs_seed and not (bundle / "loud-import.json").is_file():
        raise RuntimeError("Demo bundle not found. Run local:up -- --bundle /path/to/open-license-test-100")
    # Preflight all ports before starting anything; never kill somebody else's service.
    for name in PORTS:
        record = running(name)
        if not record or record["port"] != config["instances"][name]["port"]:
            require_free(config["instances"][name]["port"])
    candidate = build()
    for name in PORTS:
        start_one(config, name, candidate)
    if needs_seed:
        archive, expected = make_bundle(bundle.resolve())
        for name in needs_seed:
            seed_one(config, name, archive, expected)
        archive.unlink()  # No need to keep a third 600 MB audio copy after successful seeding.
    status(config)


def status(config):
    report = {"schema": SCHEMA, "instances": {}, "candidate": read_json(STATE / "candidate.json")}
    for name in PORTS:
        record = running(name)
        entry = {"url": origin(config, name), "running": bool(record)}
        if record and name != "site":
            try:
                library = get(config, name, "/api/v1/library")
                entry.update(tracks=len(library.get("tracks") or []), playlists=len(library.get("playlists") or []),
                             server_id=get(config, name, "/health", False).get("server_id"))
            except (OSError, RuntimeError) as error:
                entry["error"] = str(error)
        report["instances"][name] = entry
        suffix = f" — {entry['tracks']} tracks, {entry['playlists']} playlists" if "tracks" in entry else ""
        print(f"{name.upper():4} {'running' if record else 'stopped':7} {entry['url']}{suffix}")
    if report["candidate"]:
        print("Web: " + report["candidate"]["web_build_id"])
    shared = read_json(STATE / "share.json", {})
    for name, item in shared.items():
        print(f"Private HTTPS {name.upper()}: {item['url']} (requires Tailscale)")
    print("Auth: bun local:auth a / bun local:auth b (copies only the local token)")
    write_json(STATE / "status.json", report)
    return report


def share(config):
    ts = json.loads(capture(["tailscale", "status", "--json"]))
    if ts.get("BackendState") != "Running":
        raise RuntimeError("Connect Tailscale first")
    hostname = ts["Self"]["DNSName"].rstrip(".")
    current = json.loads(capture(["tailscale", "serve", "status", "--json"]))
    saved = read_json(STATE / "share.json", {})
    for name, port in HTTPS_PORTS.items():
        if not running(name):
            raise RuntimeError("Start the lab with local:up before sharing")
        key = f"{hostname}:{port}"
        expected = {"Handlers": {"/": {"Proxy": origin(config, name)}}}
        if current.get("AllowFunnel", {}).get(key):
            raise RuntimeError(f"Port {port} has public Funnel enabled; refusing it")
        actual = current.get("Web", {}).get(key)
        occupied = str(port) in current.get("TCP", {}) or actual is not None
        if occupied and (actual != expected or name not in saved or saved[name]["url"] != f"https://{key}"):
            raise RuntimeError(f"Tailscale port {port} already belongs to another service; it was not changed")
    for name, port in HTTPS_PORTS.items():
        subprocess.run(["tailscale", "serve", "--bg", f"--https={port}", origin(config, name)],
                       check=True, stdout=subprocess.DEVNULL)
        saved[name] = {"url": f"https://{hostname}:{port}", "target": origin(config, name), "port": port}
        write_json(STATE / "share.json", saved)
    status(config)


def unshare():
    saved = read_json(STATE / "share.json", {})
    if not saved:
        return
    current = json.loads(capture(["tailscale", "serve", "status", "--json"]))
    for name, item in list(saved.items()):
        key = item["url"].removeprefix("https://")
        actual = current.get("Web", {}).get(key)
        expected = {"Handlers": {"/": {"Proxy": item["target"]}}}
        if actual != expected:
            raise RuntimeError(f"Tailscale {name} config changed elsewhere; refusing to remove it")
        subprocess.run(["tailscale", "serve", f"--https={item['port']}", "off"], check=True, stdout=subprocess.DEVNULL)
        saved.pop(name)
        write_json(STATE / "share.json", saved)


def installed_client_check_command(binary, report, aux_v1_retirement=False):
    command = [sys.executable, "scripts/check-client-compatibility.py", "--server-binary", binary,
               "--report-dir", str(report)]
    if aux_v1_retirement:
        command.append("--aux-v1-retirement")
    return command


def check(config, browser=True, aux_v1_retirement=False):
    candidate = read_json(STATE / "candidate.json")
    if not candidate:
        raise RuntimeError("Run local:up first")
    current = load_module("codec_local_check_builder", ROOT / "scripts/build-server-release.py")
    if read_json(Path(candidate["web_export"]) / "web-build.json")["source_sha256"] != current.content_id():
        raise RuntimeError("Web source changed since local:up; rebuild the lab first")
    if candidate["server_source_sha256"] != server_source_digest():
        raise RuntimeError("Server source changed since local:up; rebuild the lab first")
    if candidate["site_source_sha256"] != site_source_digest():
        raise RuntimeError("Site source changed since local:up; rebuild the lab first")
    if candidate["server_binary_sha256"] != sha256(Path(candidate["server_binary"])):
        raise RuntimeError("Local server binary changed since local:up; rebuild the lab first")
    ids = []
    for name in ("a", "b"):
        record = running(name)
        if not record:
            raise RuntimeError("Both local servers must be running")
        if record["binary"] != candidate["server_binary"] or record["port"] != config["instances"][name]["port"]:
            raise RuntimeError("Running local servers do not match the candidate; rerun local:up")
        get(config, name, "/api/v1/library")
        ids.append(get(config, name, "/health", False)["server_id"])
    if ids[0] == ids[1] or token("a") == token("b"):
        raise RuntimeError("Local server identities or credentials are not isolated")
    report = STATE / "reports" / time.strftime("%Y%m%d-%H%M%S")
    report.mkdir()
    commands = [([sys.executable, "scripts/check-quick.py", "--report-dir", str(report / "quick")], "quick"),
                (installed_client_check_command(candidate["server_binary"], report / "installed-client", aux_v1_retirement), "installed-client"),
                ([sys.executable, "scripts/test-local-dev.py"], "lab-lifecycle-tests"),
                ([sys.executable, "site/test_release_config.py"], "site-tests")]
    if browser:
        commands.append((["node", "scripts/local-browser-smoke.mjs", "--output-dir", str(report / "browsers")], "browsers"))
    browser_env = os.environ.copy()
    playwright_module = os.environ.get("PLAYWRIGHT_MODULE") or config.get("playwright_module")
    if playwright_module:
        browser_env["PLAYWRIGHT_MODULE"] = playwright_module
    for command, name in commands:
        logged(command, "check-" + name, env=browser_env if name == "browsers" else None)
        shutil.copyfile(STATE / "logs" / ("check-" + name + ".log"), report / (name + ".log"))
    if (read_json(Path(candidate["web_export"]) / "web-build.json")["source_sha256"] != current.content_id()
            or candidate["server_source_sha256"] != server_source_digest()
            or candidate["site_source_sha256"] != site_source_digest()
            or candidate["server_binary_sha256"] != sha256(Path(candidate["server_binary"]))):
        raise RuntimeError("Candidate inputs changed while checks ran; rebuild and rerun before using this result")
    write_json(report / "result.json", {"passed": True, "candidate": candidate,
               "browsers_checked": browser, "physical_iphone_checked": False, "release_approved": False,
               "legacy_aux_retirement_declared": aux_v1_retirement, "legacy_aux_compatible": not aux_v1_retirement,
               "compatibility_scope": "owner APIs; explicit Aux v1 security retirement" if aux_v1_retirement else "full frozen installed-client API contract"})
    print(f"Local checks passed{' (owner APIs; Aux v1 intentionally retired)' if aux_v1_retirement else ''}. Report: {report}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    start = sub.add_parser("up", help="Build changed inputs, start both servers/site, seed once")
    start.add_argument("--bundle", type=Path, default=DEFAULT_BUNDLE)
    for command in ("stop", "status", "share", "unshare"):
        sub.add_parser(command)
    auth = sub.add_parser("auth", help="Copy a local token; never reads production credentials")
    auth.add_argument("instance", choices=("a", "b"))
    auth.add_argument("--show", action="store_true", help="Explicitly print the LOCAL token in your terminal")
    checks = sub.add_parser("check", help="Quick suite, old iOS client, lab safety, site, real browsers")
    checks.add_argument("--skip-browser", action="store_true", help="Partial check only; does not satisfy release checklist")
    checks.add_argument("--aux-v1-retirement", action="store_true", help="Declare intentional Aux v1 security cutoff; test unchanged owner APIs and require legacy Aux HTTP 410")
    args = parser.parse_args()
    os.umask(0o077)
    with lab_lock():
        config = configuration()
        if args.command == "up":
            up(config, args.bundle)
        elif args.command == "stop":
            for name in PORTS:
                stop_one(name)
            print("Local servers/site stopped. Test libraries and auth are preserved.")
        elif args.command == "status":
            status(config)
        elif args.command == "auth":
            value = token(args.instance)
            if args.show:
                print(value)
            elif shutil.which("pbcopy"):
                subprocess.run(["pbcopy"], input=value, text=True, check=True)
                print(f"Local {args.instance.upper()} token copied to clipboard.")
            else:
                raise RuntimeError("Clipboard helper unavailable; use auth a --show in your own terminal")
        elif args.command == "share":
            share(config)
        elif args.command == "unshare":
            unshare()
        elif args.command == "check":
            check(config, not args.skip_browser, aux_v1_retirement=args.aux_v1_retirement)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Local lab: {error}", file=sys.stderr)
        raise SystemExit(1)
