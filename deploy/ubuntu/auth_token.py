#!/usr/bin/env python3
"""Read the installed Codec token without sourcing a shell or modifying state.

The managed unit reads /etc/codec/codec.env. This reader deliberately supports
single-line systemd EnvironmentFile assignments and rejects multiline syntax.
Quoting follows systemd.exec's EnvironmentFile rules, not shell expansion or
JSON decoding: https://www.freedesktop.org/software/systemd/man/systemd.exec.html
"""

import argparse
import os
from pathlib import Path
import re
import stat
import sys


MAX_ENV_BYTES = 16384
VARIABLE_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
OUTSIDE_SPACE = " \t\r"


class AuthTokenError(Exception):
    """A fixed, credential-free error suitable for displaying to the operator."""


def assignment_value(raw):
    """Decode one physical line; never expand dollar signs or run commands."""
    result = []
    mode = "before"
    index = 0
    while index < len(raw):
        char = raw[index]
        if mode == "before":
            if char in OUTSIDE_SPACE:
                index += 1
                continue
            if char in "'\"":
                mode = char
                index += 1
                continue
            mode = "plain"
        elif mode in ("'", '"') and char == mode:
            mode = "before"
            index += 1
            continue

        if char == "\\" and mode != "'":
            index += 1
            if index == len(raw):
                raise AuthTokenError("Multiline or incomplete environment assignments are unsupported.")
            escaped = raw[index]
            if mode == '"' and escaped not in '\\"`$':
                result.append("\\")
            result.append(escaped)
        else:
            result.append(char)
        index += 1
    if mode in ("'", '"'):
        raise AuthTokenError("Multiline or incomplete environment assignments are unsupported.")
    return "".join(result)


def parse_environment(text):
    """Return the effective server token, preserving all interior characters.

    Codec trims outer whitespace on startup. We do the same after decoding;
    neither quotes nor backslashes are trimmed from the token itself.
    """
    if "\x00" in text or "\ufeff" in text:
        raise AuthTokenError("The environment file has unsupported contents.")
    tokens = []
    for line in text.split("\n"):
        line = line.rstrip("\r")
        stripped = line.lstrip(OUTSIDE_SPACE)
        if not stripped or stripped.startswith(("#", ";")):
            continue
        if "=" not in line:
            # systemd ignores standalone lines without an assignment.
            continue
        key, raw = line.split("=", 1)
        key = key.strip(OUTSIDE_SPACE)
        if not VARIABLE_NAME.fullmatch(key):
            raise AuthTokenError("The environment file has an invalid variable assignment.")
        # Validate other variables too, so a token-looking line cannot be read
        # from inside an unsupported multiline quoted value.
        value = assignment_value(raw)
        if key == "CODEC_AUTH_TOKEN":
            tokens.append(value)
    if len(tokens) != 1:
        raise AuthTokenError("The environment file must contain exactly one CODEC_AUTH_TOKEN assignment.")
    token = tokens[0].strip(" \t\r\n\v\f")
    if not token or any(ord(char) < 32 or ord(char) > 126 for char in token):
        raise AuthTokenError("The installed token must be a non-empty single line of printable ASCII.")
    return token


def read_token(path, expected_uid=None):
    """Read only a bounded private regular file, without following symlinks."""
    path = Path(path)
    if not path.is_absolute() or ".." in path.parts:
        raise AuthTokenError("The environment path is not a managed absolute path.")
    directory = descriptor = None
    try:
        # Resolve every directory using openat/O_NOFOLLOW. Checking a pathname
        # and subsequently opening it would allow a swapped symlink to escape.
        directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
        directory = os.open("/", directory_flags)
        for part in path.parts[1:-1]:
            child = os.open(part, directory_flags, dir_fd=directory)
            os.close(directory)
            directory = child
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=directory)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) not in (0o400, 0o600):
            raise AuthTokenError("codec.env must be a private regular file with mode 600 or 400.")
        if expected_uid is not None and metadata.st_uid != expected_uid:
            raise AuthTokenError("codec.env must be owned by the account managing this installation.")
        if metadata.st_size > MAX_ENV_BYTES:
            raise AuthTokenError("The environment file is too large.")
        with os.fdopen(descriptor, "rb") as stream:
            descriptor = None
            data = stream.read(MAX_ENV_BYTES + 1)
        if len(data) > MAX_ENV_BYTES:
            raise AuthTokenError("The environment file is too large.")
        try:
            text = data.decode("utf-8")
        except UnicodeError:
            raise AuthTokenError("The environment file is not valid UTF-8.") from None
        return parse_environment(text)
    except OSError:
        raise AuthTokenError("Cannot read the managed codec.env file; check installation, ownership, and permissions.") from None
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if directory is not None:
            os.close(directory)


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        # Do not echo arbitrary arguments that might contain a pasted token.
        self.print_usage(sys.stderr)
        self.exit(2, "Codec auth: Invalid arguments; run --help for usage.\n")


def main(argv=None):
    parser = SafeArgumentParser(description="Show the existing Codec server auth token without changing it.")
    parser.add_argument("--raw", action="store_true", help="Explicitly output only the token and newline, for a private clipboard pipe")
    parser.add_argument("--root-dir", type=Path, help="Read an isolated staged installation instead of the live system")
    args = parser.parse_args(argv)
    try:
        if not args.raw and (not sys.stdout.isatty() or not sys.stderr.isatty()):
            raise AuthTokenError("Interactive output requires a terminal. Use --raw explicitly for a private clipboard pipe.")
        if args.root_dir is not None:
            if args.root_dir.is_symlink():
                raise AuthTokenError("The staged root must be a real isolated directory.")
            root = args.root_dir.resolve(strict=True)
            if root == Path("/") or not root.is_dir():
                raise AuthTokenError("The staged root must be a real isolated directory, not /.")
        else:
            if os.geteuid() != 0:
                raise AuthTokenError("Reading the installed token requires root; run this command with sudo.")
            root = Path("/")
        token = read_token(root / "etc/codec/codec.env", expected_uid=os.geteuid())
        if args.raw:
            sys.stdout.write(token + "\n")
        else:
            sys.stdout.write("Codec auth token:\n" + token + "\n")
        sys.stdout.flush()
        return 0
    except AuthTokenError as error:
        print("Codec auth: " + str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError, RuntimeError):
        # Avoid path details, file contents, and chained traceback messages.
        print("Codec auth: Unable to read the managed installation.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
