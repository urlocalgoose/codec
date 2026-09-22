#!/usr/bin/env python3
"""Install a verified Codec server release; never restore a live database on rollback.

No third-party Python packages are required. --root-dir stages an isolated filesystem
without changing accounts, starting processes, or calling systemd. --verify-only
checks the release without changing the target at all.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import secrets
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
from urllib.error import URLError
from urllib.request import ProxyHandler, build_opener


MAX_FILES = 30_000
MAX_FILE_BYTES = 256 * 1024 * 1024
MAX_RELEASE_BYTES = 1024 * 1024 * 1024
VERSION = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}\Z")


class DeployError(Exception):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_relative(name):
    if not name or "\\" in name or any(ord(c) < 32 for c in name):
        raise DeployError("Invalid archive path")
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in ("", ".", "..") for part in name.split("/")):
        raise DeployError("Archive path escapes or ambiguously names the release")
    return path


def expected_digest(checksum, archive):
    if checksum.stat().st_size > 4096:
        raise DeployError("Archive checksum file is too large")
    lines = [line for line in checksum.read_text().splitlines() if line.strip()]
    if len(lines) != 1:
        raise DeployError("Use the release's individual .tar.gz.sha256 file")
    match = re.fullmatch(r"([a-fA-F0-9]{64}) [ *](.+)", lines[0])
    if not match or match[2] != archive.name:
        raise DeployError("Archive checksum filename does not match")
    return match[1].lower()


def unpack_verified(archive, checksum, destination):
    """Validate, manually extract only regular files/directories, then hash all files."""
    digest = expected_digest(checksum, archive)
    if sha256(archive) != digest:
        raise DeployError("Release archive checksum mismatch")
    names, files, total = set(), set(), 0
    top = None
    with tarfile.open(archive, "r:gz") as bundle:
        entries = []
        for entry in bundle:
            entries.append(entry)
            if len(entries) > MAX_FILES:
                raise DeployError("Too many release archive entries")
            name = entry.name.rstrip("/") if entry.isdir() else entry.name
            path = safe_relative(name)
            if name in names:
                raise DeployError("Duplicate release archive entry")
            names.add(name)
            if top is None:
                top = path.parts[0]
            if path.parts[0] != top:
                raise DeployError("Release must have one top-level directory")
            if not entry.isdir() and not entry.isfile():
                raise DeployError("Release links, devices, and other special files are forbidden")
            if entry.size < 0 or entry.size > MAX_FILE_BYTES:
                raise DeployError("Release file is too large")
            total += entry.size
            if total > MAX_RELEASE_BYTES:
                raise DeployError("Expanded release is too large")
            if entry.isfile():
                if len(path.parts) < 2:
                    raise DeployError("Release root must be a directory")
                files.add(PurePosixPath(*path.parts[1:]).as_posix())
        if not top:
            raise DeployError("Empty release archive")
        # No tar.extract: members cannot create links, apply ownership, or escape.
        for entry in entries:
            target = destination.joinpath(*PurePosixPath(entry.name).parts)
            if entry.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(entry) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output, 1024 * 1024)
                target.chmod(0o600)
    root = destination / top
    if ".archive-sha256" in files:
        raise DeployError("Release cannot supply the installer's private integrity marker")
    sums = root / "SHA256SUMS"
    if not sums.is_file() or sums.stat().st_size > 4 * 1024 * 1024:
        raise DeployError("Missing or oversized internal SHA256SUMS")
    recorded = {}
    for line in sums.read_text().splitlines():
        match = re.fullmatch(r"([a-fA-F0-9]{64}) [ *](.+)", line)
        if not match:
            raise DeployError("Malformed internal checksum manifest")
        name = safe_relative(match[2]).as_posix()
        if name in recorded or name == "SHA256SUMS":
            raise DeployError("Duplicate or recursive internal checksum entry")
        recorded[name] = match[1].lower()
    if set(recorded) != files - {"SHA256SUMS"}:
        raise DeployError("Internal checksums must cover every release file exactly once")
    for name, value in recorded.items():
        if sha256(root / name) != value:
            raise DeployError("Internal release checksum mismatch")
    metadata_path = root / "release.json"
    if not metadata_path.is_file() or metadata_path.stat().st_size > 32768:
        raise DeployError("Missing or oversized release.json")
    metadata = json.loads(metadata_path.read_text())
    if not isinstance(metadata, dict) or metadata.get("schema") != "codec.server-release.v1":
        raise DeployError("Unsupported release schema")
    version, arch = metadata.get("version", ""), metadata.get("arch")
    if not isinstance(version, str) or not VERSION.fullmatch(version):
        raise DeployError("Invalid release version")
    if metadata.get("os") != "linux" or arch not in ("amd64", "arm64"):
        raise DeployError("Expected a Linux amd64 or arm64 release")
    release_name = f"codec-server-{version}-linux-{arch}"
    if top != release_name or archive.name != release_name + ".tar.gz":
        raise DeployError("Release metadata and archive names disagree")
    required = ("codec-sync-server", "web/index.html", "deploy/ubuntu/codec.service")
    if any(name not in files for name in required):
        raise DeployError("Release is missing the server, web app, or service unit")
    (root / ".archive-sha256").write_text(digest + "\n")
    return root, metadata


def atomic_write(path, data, mode=0o600):
    descriptor, temporary = tempfile.mkstemp(prefix=".codec-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def atomic_link(path, target):
    temporary = path.parent / (".codec-link-" + secrets.token_hex(8))
    try:
        temporary.symlink_to(target)
        os.replace(temporary, path)
    finally:
        if temporary.is_symlink():
            temporary.unlink()


def no_symlink_parents(path, boundary):
    current = path
    while current != boundary:
        if current.is_symlink():
            raise DeployError("Managed deployment directories cannot be symlinks")
        current = current.parent
        if current == current.parent and current != boundary:
            raise DeployError("Managed path is outside deployment root")


class Systemd:
    def command(self, *arguments, check=True):
        # Do not echo environment values or systemctl status/journal output.
        return subprocess.run(["systemctl", *arguments], check=check,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def active(self):
        return self.command("is-active", "--quiet", "codec.service", check=False).returncode == 0

    def stop(self):
        self.command("stop", "codec.service")

    def reload(self):
        self.command("daemon-reload")

    def start(self):
        # A crash-looping candidate may exhaust StartLimitBurst before the
        # health deadline. Clear that failed state so the restored release can
        # start immediately instead of remaining rate-limited for a minute.
        self.command("reset-failed", "codec.service", check=False)
        self.command("restart", "codec.service")

    def enable(self):
        self.command("enable", "codec.service")

    def healthy(self, timeout):
        deadline = time.monotonic() + timeout
        opener = build_opener(ProxyHandler({}))
        while time.monotonic() < deadline:
            try:
                with opener.open("http://127.0.0.1:8787/health", timeout=2) as response:
                    payload = json.loads(response.read(16384))
                if self.active() and isinstance(payload, dict) and payload.get("ok") is True:
                    return True
            except (OSError, ValueError, URLError):
                pass
            time.sleep(0.5)
        return False


class StagingOnly:
    """Root-dir stages files only; it deliberately cannot start arbitrary binaries."""
    def active(self):
        return False

    def stop(self):
        pass

    def reload(self):
        pass

    def start(self):
        pass

    def enable(self):
        pass

    def healthy(self, timeout):
        return True


def ensure_account(data_path):
    import pwd
    try:
        account = pwd.getpwnam("codec")
    except KeyError:
        subprocess.run(["useradd", "--system", "--user-group", "--home-dir", "/var/lib/codec",
                        "--no-create-home", "--shell", "/usr/sbin/nologin", "codec"], check=True)
        account = pwd.getpwnam("codec")
    if account.pw_uid == 0:
        raise DeployError("The codec service account must not be root")
    # Do not walk/rewrite ownership of imported media on each release update.
    os.chown(data_path, account.pw_uid, account.pw_gid)


def prepare_environment(path, token_file=None):
    if path.exists() or path.is_symlink():
        if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
            raise DeployError("Existing codec.env must be a private regular file (chmod 600)")
        if token_file is not None:
            raise DeployError("Existing authentication is preserved; --token-file is for first install")
        if path.stat().st_size > 16384:
            raise DeployError("Environment file is too large")
        lines = path.read_text().splitlines()
        tokens = [line.split("=", 1)[1].strip() for line in lines
                  if line.startswith("CODEC_AUTH_TOKEN=")]
        if len(tokens) != 1 or tokens[0] in ("", "''", '""'):
            raise DeployError("codec.env must contain a non-empty CODEC_AUTH_TOKEN")
        try:
            pieces = shlex.split(tokens[0])
        except ValueError as error:
            raise DeployError("codec.env contains an invalid token assignment") from error
        if not pieces or not " ".join(pieces).strip():
            raise DeployError("codec.env must contain a non-empty CODEC_AUTH_TOKEN")
        return
    if token_file:
        if token_file.stat().st_size > 4096:
            raise DeployError("Token file is too large")
        token = token_file.read_text().rstrip("\r\n")
    else:
        token = secrets.token_urlsafe(48)
    if not token.strip() or any(ord(char) < 32 or ord(char) > 126 for char in token):
        raise DeployError("Token must be a non-empty single line of printable ASCII")
    atomic_write(path, ("# Private: do not commit or include in releases.\nCODEC_AUTH_TOKEN=" +
                        json.dumps(token) + "\n").encode(), 0o600)


def sqlite_backup(data_path, backup_dir):
    database = data_path / "codec-sync.sqlite"
    if not database.exists():
        return None
    if database.is_symlink() or not database.is_file():
        raise DeployError("Library database must be a regular file")
    backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup_dir.chmod(0o700)
    target = backup_dir / (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" +
                           secrets.token_hex(4) + ".sqlite")
    descriptor = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(descriptor)
    try:
        with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=60) as source:
            with sqlite3.connect(target) as output:
                source.backup(output)
                if output.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                    raise DeployError("Pre-update SQLite backup failed integrity check")
    except Exception:
        target.unlink(missing_ok=True)
        raise
    return target


def protect_release(root):
    executable_paths = {"codec-sync-server", "scripts/ubuntu-install.sh",
                        "scripts/ubuntu-update.sh", "scripts/ubuntu-auth.sh", "deploy/ubuntu/runtime.py"}
    for path in root.rglob("*"):
        if path.is_file():
            path.chmod(0o555 if path.relative_to(root).as_posix() in executable_paths else 0o444)
    for path in sorted((p for p in root.rglob("*") if p.is_dir()), reverse=True):
        path.chmod(0o555)
    root.chmod(0o555)


def build_runtime_web(release, web_base, old_web):
    """Keep old hashed assets available to tabs/PWAs without modifying the release.

    Files are read-only hardlinks to verified payloads (copies if the FS cannot link).
    Index/service-worker files always come from the new release. Only immutable
    assets survive across versions. The derived tree has its own provenance/hashes.
    """
    destination = web_base / "releases" / (release.name + "-" + secrets.token_hex(6))
    destination.mkdir()
    web = destination / "web"
    web.mkdir()
    hashes = {}
    sources = {}

    def add(source, relative, expected=None):
        if source.is_symlink() or not source.is_file():
            raise DeployError("Runtime web files must be regular files")
        digest = sha256(source)
        if expected is not None and expected != digest:
            raise DeployError("Retained web asset failed integrity verification")
        target = web / relative
        if target.exists():
            if sha256(target) != digest:
                raise DeployError("Immutable web asset name has different contents across releases")
            return
        target.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(source, target)
        except OSError:
            shutil.copyfile(source, target)
        target.chmod(0o444)
        if relative.startswith("_app/immutable/"):
            hashes[relative] = digest

    for source in (release / "web").rglob("*"):
        if source.is_file():
            add(source, source.relative_to(release / "web").as_posix())
    if old_web is not None:
        metadata = json.loads((old_web / "assets.json").read_text())
        old_hashes = metadata.get("immutable_files")
        if not isinstance(old_hashes, dict):
            raise DeployError("Missing prior web asset integrity manifest")
        sources.update(metadata.get("source_archives", {}))
        for name, digest in old_hashes.items():
            relative = safe_relative(name).as_posix()
            if not relative.startswith("_app/immutable/"):
                raise DeployError("Retained web file is not an immutable asset")
            source = old_web / "web" / relative
            no_symlink_parents(source.parent, old_web)
            add(source, relative, digest)
    sources[release.name] = (release / ".archive-sha256").read_text().strip()
    (destination / "assets.json").write_text(json.dumps({
        "schema": "codec.runtime-web.v1", "release": release.name,
        "source_archives": sources, "immutable_files": hashes,
    }, indent=2, sort_keys=True) + "\n")
    protect_release(destination)
    return destination


def deploy(root, unpacked, mode, token_file=None, backend=None, timeout=30, staging=False):
    if root.is_symlink():
        raise DeployError("Deployment root cannot be a symlink")
    root = root.resolve()
    if staging and root == Path("/"):
        raise DeployError("Staging requires an isolated directory, not the filesystem root")
    backend = backend or (StagingOnly() if staging else Systemd())
    base, data = root / "opt/codec", root / "var/lib/codec"
    etc, systemd = root / "etc/codec", root / "etc/systemd/system"
    backups = root / "var/backups/codec"
    web_base = base / "web"
    for path in (base / "releases", web_base / "releases", data, etc, systemd, backups):
        no_symlink_parents(path, root)
        path.mkdir(parents=True, exist_ok=True)
    etc.chmod(0o700)
    data.chmod(0o750)
    backups.chmod(0o700)
    current, previous, unit = base / "current", base / "previous", systemd / "codec.service"
    web_current = web_base / "current"
    if web_current.exists() and not web_current.is_symlink():
        raise DeployError("Current web deployment must be a managed symlink")
    old_web_link = os.readlink(web_current) if web_current.is_symlink() else None
    old_web = web_current.resolve() if old_web_link is not None else None
    if old_web is not None and (old_web.parent != web_base / "releases" or not old_web.is_dir()):
        raise DeployError("Current web symlink points outside the runtime web directory")
    if current.exists() and not current.is_symlink():
        raise DeployError("Current deployment must be a managed release symlink")
    old = os.readlink(current) if current.is_symlink() else None
    if old is not None:
        resolved = current.resolve()
        if resolved.parent != base / "releases" or not resolved.is_dir():
            raise DeployError("Current release symlink points outside the release directory")
    if mode == "install" and old is not None:
        raise DeployError("Codec is already installed; use ubuntu-update.sh")
    if mode == "update" and old is None:
        raise DeployError("No current release found; use ubuntu-install.sh first")
    if (old is None) != (old_web is None):
        raise DeployError("Server and runtime web release links must both be present or absent")
    if unit.is_symlink() or (unit.exists() and not unit.is_file()):
        raise DeployError("codec.service must be a regular file")
    prepare_environment(etc / "codec.env", token_file)
    if not staging:
        ensure_account(data)
    release = base / "releases" / unpacked.name
    if release.exists() or release.is_symlink():
        if release.is_symlink() or not release.is_dir():
            raise DeployError("Release path must be a real directory")
        expected = (unpacked / ".archive-sha256").read_text()
        marker = release / ".archive-sha256"
        if not marker.is_file() or marker.read_text() != expected:
            raise DeployError("A different build already uses this version; give it a new version")
        # Never silently reuse a corrupt installed release just because its marker matches.
        for source in unpacked.rglob("*"):
            if source.is_file():
                destination = release / source.relative_to(unpacked)
                no_symlink_parents(destination.parent, release)
                if destination.is_symlink() or not destination.is_file() or sha256(source) != sha256(destination):
                    raise DeployError("Existing release contents were changed")
    else:
        staged = Path(tempfile.mkdtemp(prefix=".stage-", dir=base / "releases"))
        try:
            shutil.copytree(unpacked, staged, dirs_exist_ok=True)
            protect_release(staged)
            # macOS also requires write permission on a directory being renamed;
            # keep the staging root writable until it has its permanent name.
            staged.chmod(0o755)
            os.replace(staged, release)
            release.chmod(0o555)
        finally:
            if staged.exists():
                staged.chmod(0o700)
                for path in staged.rglob("*"):
                    if path.is_dir():
                        path.chmod(0o700)
                shutil.rmtree(staged)
    runtime_web = build_runtime_web(release, web_base, old_web)
    old_unit = unit.read_bytes() if unit.exists() else None
    was_active = backend.active()
    switched = False
    web_switched = False
    unit_changed = False
    stopped = False
    backup = None
    try:
        if old is not None:
            backend.stop()
            stopped = True
        backup = sqlite_backup(data, backups)
        atomic_write(unit, (release / "deploy/ubuntu/codec.service").read_bytes(), 0o644)
        unit_changed = True
        atomic_link(current, str(Path("releases") / release.name))
        switched = True
        atomic_link(web_current, str(Path("releases") / runtime_web.name))
        web_switched = True
        backend.reload()
        backend.start()
        if not backend.healthy(timeout):
            raise DeployError("New release failed its local health check")
        backend.enable()
        if old is not None and (base / old).resolve() != release:
            atomic_link(previous, old)
            atomic_link(web_base / "previous", old_web_link)
    except BaseException as error:
        # Only binaries, static files, and the service definition roll back. Never
        # overwrite a database after a new binary may have accepted writes.
        try:
            if switched:
                backend.stop()
                if old is None:
                    current.unlink()
                else:
                    atomic_link(current, old)
            if web_switched:
                if old_web_link is None:
                    web_current.unlink()
                else:
                    atomic_link(web_current, old_web_link)
            if unit_changed:
                if old_unit is None:
                    unit.unlink(missing_ok=True)
                else:
                    atomic_write(unit, old_unit, 0o644)
            if switched or unit_changed:
                backend.reload()
            if old is not None and was_active and (stopped or switched):
                backend.start()
                if not backend.healthy(timeout):
                    raise DeployError("Previous binary also failed health checks; database was left untouched")
        except Exception as rollback_error:
            raise DeployError("Update failed and the previous service could not be restored; "
                              "database remains untouched. Inspect codec.service locally.") from rollback_error
        raise DeployError("Release was not activated; previous binaries restored where available. "
                          "Database was not rolled back.") from error
    return release, backup


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "update"))
    parser.add_argument("archive", type=Path)
    parser.add_argument("--sha256-file", type=Path, required=True)
    parser.add_argument("--token-file", type=Path, help="First install only; preserves the existing client token")
    parser.add_argument("--root-dir", type=Path, help="Stage isolated files only; no systemd or account changes")
    parser.add_argument("--verify-only", action="store_true", help="Verify without installing or running the release")
    parser.add_argument("--health-timeout", type=int, default=30)
    args = parser.parse_args(argv)
    def interrupted(signum, frame):
        raise DeployError("Deployment interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGHUP, interrupted)
    if not 1 <= args.health_timeout <= 300:
        parser.error("--health-timeout must be between 1 and 300 seconds")
    if args.action == "update" and args.token_file:
        parser.error("--token-file is for first install only")
    staging = args.root_dir is not None
    root = args.root_dir.absolute() if staging else Path("/")
    if staging and (root == Path("/") or root.is_symlink()):
        parser.error("--root-dir must be an isolated directory, not / or a symlink")
    root = root.resolve()
    if staging and root == Path("/"):
        parser.error("--root-dir resolves to /; use an isolated directory")
    if not args.verify_only and not staging:
        if platform.system() != "Linux" or os.geteuid() != 0:
            parser.error("Actual installation requires root on Linux; use --verify-only or --root-dir for local checks")
        if not shutil.which("systemctl") or not Path("/run/systemd/system").is_dir():
            parser.error("Actual installation requires a running systemd host")
    with tempfile.TemporaryDirectory(prefix="codec-verify-") as scratch:
        unpacked, metadata = unpack_verified(args.archive.absolute(), args.sha256_file.absolute(), Path(scratch))
        if args.verify_only:
            print("Verified " + unpacked.name + "; no target changes made.")
            return 0
        if not staging:
            host_arch = {"x86_64": "amd64", "aarch64": "arm64"}.get(platform.machine())
            if metadata["arch"] != host_arch:
                raise DeployError("Release architecture does not match this server")
        root.mkdir(parents=True, exist_ok=True)
        # Ubuntu provides /var/lock as a compatibility symlink to /run/lock.
        # Use the canonical runtime directory and retain strict confinement for
        # every managed path instead of weakening symlink validation.
        lock_dir = root / "run/lock"
        no_symlink_parents(lock_dir, root)
        lock_dir.mkdir(parents=True, exist_ok=True)
        lock_path = lock_dir / "codec-deploy.lock"
        descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            release, backup = deploy(root, unpacked, args.action, args.token_file,
                                     timeout=args.health_timeout, staging=staging)
        if staging:
            print("Staged " + release.name + " under " + str(root) + "; systemd was not run.")
        else:
            print("Activated " + release.name + "; local health check passed.")
        print("Authentication preserved in private /etc/codec/codec.env; token not printed.")
        auth_helper = root / "opt/codec/current/scripts/ubuntu-auth.sh"
        if auth_helper.is_file():
            command = ([str(auth_helper), "--root-dir", str(root)] if staging
                       else ["sudo", str(auth_helper)])
            print("To retrieve your auth token in a terminal: " + shlex.join(command))
        if backup:
            print("Pre-update SQLite backup: " + str(backup))
        return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (DeployError, OSError, ValueError, tarfile.TarError, subprocess.CalledProcessError) as error:
        # Never emit subprocess environment, token contents, or traceback locals.
        message = str(error) if isinstance(error, DeployError) else type(error).__name__
        print("Codec deployment failed: " + message, file=sys.stderr)
        sys.exit(1)
