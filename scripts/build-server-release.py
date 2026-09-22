#!/usr/bin/env python3
"""Build reproducible, data-free Linux server + web release archives.

Requires the versions in package.json:packageManager and .go-version, plus Python
3.11+. Does not connect to or deploy a server. The output directory contains
one .tar.gz and .tar.gz.sha256 per architecture and aggregate SHA256SUMS.
"""

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import struct
import subprocess
import tarfile
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
VERSION_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}\Z")
RUNTIME_FILES = (
    "deploy/ubuntu/runtime.py",
    "deploy/ubuntu/auth_token.py",
    "deploy/ubuntu/codec.service",
    "deploy/ubuntu/Caddyfile.example",
    "scripts/ubuntu-install.sh",
    "scripts/ubuntu-update.sh",
    "scripts/ubuntu-auth.sh",
)
DOCUMENTS = (
    "LICENSE",
    # Public, portable instructions only. Operational histories and local
    # validation reports must not enter downloadable application archives.
    "docs/server-release.md",
    "docs/codec-import-v1.md",
    "docs/codec-import.schema.json",
    "docs/s2y-artwork-import.md",
    "docs/s2y-playlist-artwork.schema.json",
    "docs/s2y-track-artwork.schema.json",
    # Keep the import guide's relative example links usable inside the archive.
    "site/examples/loud-import.json",
    "site/examples/track-artwork.json",
    "site/examples/playlist-artwork.json",
    "site/examples/artwork/cover.jpg",
    "site/examples/CREDITS.txt",
)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def capture(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def files_under(directory):
    if directory.is_symlink():
        raise ValueError(f"Refusing symbolic link: {directory}")
    for path in sorted(directory.rglob("*")):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError(f"Release payload must contain regular files/directories: {path}")
        if path.is_file():
            if "\n" in path.name or "\r" in path.name or "\\" in path.name:
                raise ValueError(f"Unsafe release filename: {path}")
            yield path


def copy_file(source, destination, executable=False):
    if source.is_symlink() or not source.is_file():
        raise ValueError(f"Missing or non-regular release input: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(0o755 if executable else 0o644)


def validate_elf(path, arch):
    """Verify a 64-bit static Linux ELF, including no runtime interpreter."""
    with path.open("rb") as stream:
        header = stream.read(64)
        if len(header) != 64 or header[:6] != b"\x7fELF\x02\x01":
            raise ValueError("Expected a 64-bit little-endian ELF server")
        if struct.unpack_from("<H", header, 18)[0] != {"amd64": 62, "arm64": 183}[arch]:
            raise ValueError(f"Server executable is not {arch}")
        offset = struct.unpack_from("<Q", header, 32)[0]
        entry_size, count = struct.unpack_from("<HH", header, 54)
        if entry_size < 56 or count == 0:
            raise ValueError("Missing ELF program headers")
        for index in range(count):
            stream.seek(offset + index * entry_size)
            entry = stream.read(entry_size)
            if len(entry) != entry_size:
                raise ValueError("Truncated ELF program headers")
            if struct.unpack_from("<I", entry)[0] == 3:
                raise ValueError("Release executable requires a dynamic interpreter; build with CGO_ENABLED=0")


def content_id():
    digest = hashlib.sha256()
    paths = []
    for folder in ("src", "static"):
        paths.extend(files_under(ROOT / folder))
    paths.extend(ROOT / name for name in ("package.json", "bun.lock", "svelte.config.js", "vite.config.js", "tsconfig.json"))
    for path in sorted(paths):
        digest.update(str(path.relative_to(ROOT)).encode() + b"\0")
        digest.update(bytes.fromhex(sha256(path)))
    return digest.hexdigest()


def web_files(web):
    """A closed set of regular files, never symlinks or a partial web build."""
    if not (web / "index.html").is_file() or not (web / "service-worker.js").is_file():
        raise ValueError("Missing web build; expected index.html and service-worker.js")
    return {path.relative_to(web).as_posix(): sha256(path) for path in files_under(web)}


def export_web_artifact(web, destination, identity):
    if destination.exists() or destination.is_symlink():
        raise ValueError("Web artifact destination already exists; choose an empty destination")
    files = web_files(web)
    destination.mkdir(parents=True)
    for name in files:
        copy_file(web / name, destination / "web" / name)
    manifest = dict(identity, files=files)
    (destination / "web-build.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def verify_web_artifact(artifact, identity):
    """Accept only the exact source/toolchain/build identity and hashed file set.

    CI downloads this artifact from its own successful web job. This verifies
    that handoff; checksums alone do not authenticate an arbitrary third party.
    """
    descriptor = artifact / "web-build.json"
    if artifact.is_symlink() or descriptor.is_symlink() or not descriptor.is_file() or descriptor.stat().st_size > 4 * 1024 * 1024:
        raise ValueError("Missing or unsafe web-build.json")
    manifest = json.loads(descriptor.read_text())
    if not isinstance(manifest, dict) or any(manifest.get(key) != value for key, value in identity.items()):
        raise ValueError("Web artifact does not match this source, commit, Bun version or release label")
    web = artifact / "web"
    if web_files(web) != manifest.get("files"):
        raise ValueError("Web artifact file set or checksum mismatch")
    version_file = web / "_app/version.json"
    if not version_file.is_file() or json.loads(version_file.read_text()).get("version") != identity["build_id"]:
        raise ValueError("Web artifact has a different Svelte/PWA build ID")
    return web


def write_checksums(stage):
    entries = [f"{sha256(path)}  {path.relative_to(stage).as_posix()}\n" for path in files_under(stage) if path != stage / "SHA256SUMS"]
    (stage / "SHA256SUMS").write_text("".join(entries))


def write_archive(stage, archive, epoch):
    """Normalize ordering, owners, modes and timestamps (including gzip header)."""
    with archive.open("wb") as output:
        with gzip.GzipFile(filename="", mode="wb", fileobj=output, mtime=epoch, compresslevel=9) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as tar:
                paths = [stage, *sorted(stage.rglob("*"))]
                for path in paths:
                    if path.is_symlink():
                        raise ValueError(f"Refusing symbolic link: {path}")
                    info = tar.gettarinfo(str(path), arcname=path.relative_to(stage.parent).as_posix())
                    if not (info.isdir() or info.isfile()):
                        raise ValueError(f"Unsupported archive member: {path}")
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = epoch
                    info.mode = 0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644
                    if info.isfile():
                        with path.open("rb") as source:
                            tar.addfile(info, source)
                    else:
                        tar.addfile(info)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Release label, e.g. v1.5.0 or preview-abc123")
    parser.add_argument("--arch", choices=("amd64", "arm64", "all"), default="all")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist" / "server")
    parser.add_argument("--web-only", action="store_true", help="Build/export web assets only; requires --web-output-dir")
    parser.add_argument("--web-output-dir", type=Path, help="Export web assets with exact-source identity and file checksums")
    parser.add_argument("--verified-web", type=Path, help="Reuse an exported exact-source web artifact after full verification")
    args = parser.parse_args()
    if args.web_only and not args.web_output_dir:
        parser.error("--web-only requires --web-output-dir")
    if args.verified_web and (args.web_only or args.web_output_dir):
        parser.error("--verified-web cannot be combined with web export options")
    if not VERSION_PATTERN.fullmatch(args.version) or ".." in args.version:
        parser.error("Version must be a simple release label without paths or '..'")
    package = json.loads((ROOT / "package.json").read_text())
    bun_expected = package.get("packageManager", "").removeprefix("bun@")
    go_expected = (ROOT / ".go-version").read_text().strip()
    bun_version = capture("bun", "--version")
    go_version = None if args.web_only else capture("go", "env", "GOVERSION").removeprefix("go")
    if bun_version != bun_expected or (not args.web_only and go_version != go_expected):
        parser.error(f"Use Bun {bun_expected} and Go {go_expected}; found Bun {bun_version}, Go {go_version}")
    commit = capture("git", "rev-parse", "HEAD")
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH") or capture("git", "show", "-s", "--format=%ct", "HEAD"))
    if not 0 <= epoch <= 0xFFFFFFFF:
        parser.error("SOURCE_DATE_EPOCH must fit a gzip timestamp (0..4294967295)")
    dirty = bool(capture("git", "status", "--porcelain", "--untracked-files=normal"))
    source_digest = content_id()
    build_id = f"{args.version}-{commit[:12]}-{source_digest[:12]}"
    env = dict(os.environ, SOURCE_DATE_EPOCH=str(epoch), CODEC_BUILD_ID=build_id)
    web_identity = {
        "schema": "codec.web-build.v1", "version": args.version, "git_commit": commit,
        "source_sha256": source_digest, "bun_version": bun_version,
        "build_id": build_id, "source_date_epoch": epoch,
    }
    if args.verified_web:
        web = verify_web_artifact(args.verified_web, web_identity)
        print("Verified exact-source web artifact; no web rebuild needed")
    else:
        subprocess.run(["bun", "install", "--frozen-lockfile"], cwd=ROOT, env=env, check=True)
        subprocess.run(["bun", "run", "--bun", "build"], cwd=ROOT, env=env, check=True)
        if content_id() != source_digest:
            parser.error("Web source changed during the build; retry after source changes finish")
        web = ROOT / "build"
        web_files(web)
    if args.web_output_dir:
        export_web_artifact(web, args.web_output_dir, web_identity)
        verify_web_artifact(args.web_output_dir, web_identity)
        print(f"Exported verified web artifact: {args.web_output_dir}")
    if args.web_only:
        return
    args.output_dir.mkdir(parents=True, exist_ok=True)
    architectures = ("amd64", "arm64") if args.arch == "all" else (args.arch,)
    archive_sums = []
    with tempfile.TemporaryDirectory(prefix="codec-server-release-") as temporary:
        for arch in architectures:
            name = f"codec-server-{args.version}-linux-{arch}"
            stage = Path(temporary) / name
            stage.mkdir()
            subprocess.run([
                "go", "build", "-mod=readonly", "-trimpath", "-buildvcs=false", "-ldflags=-s -w -buildid=",
                "-o", str(stage / "codec-sync-server"), "./cmd/codec-sync-server",
            ], cwd=ROOT / "sync-server", env=dict(env, CGO_ENABLED="0", GOOS="linux", GOARCH=arch, GOAMD64="v1", GOARM64="v8.0"), check=True)
            (stage / "codec-sync-server").chmod(0o755)
            validate_elf(stage / "codec-sync-server", arch)
            for path in files_under(web):
                copy_file(path, stage / "web" / path.relative_to(web))
            for name in (*RUNTIME_FILES, *DOCUMENTS):
                copy_file(ROOT / name, stage / name, executable=name.endswith(".sh"))
            metadata = {
                "schema": "codec.server-release.v1", "version": args.version,
                "os": "linux", "arch": arch, "git_commit": commit, "git_dirty": dirty,
                "source_date_epoch": epoch,
                "toolchains": {"bun": bun_version, "go": go_version, "python": platform.python_version(), "zlib": zlib.ZLIB_RUNTIME_VERSION},
                "web_build_id": build_id,
                "web_source_sha256": source_digest, "web_reused": bool(args.verified_web),
            }
            (stage / "release.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
            write_checksums(stage)
            archive = args.output_dir / f"{stage.name}.tar.gz"
            write_archive(stage, archive, epoch)
            digest_line = f"{sha256(archive)}  {archive.name}\n"
            archive.with_name(archive.name + ".sha256").write_text(digest_line)
            archive_sums.append(digest_line)
            print(f"Built {archive} ({archive.stat().st_size:,} bytes)")
    (args.output_dir / "SHA256SUMS").write_text("".join(archive_sums))


if __name__ == "__main__":
    main()
