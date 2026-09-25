# Platform support and remaining portability work

This is a source and local-build assessment from September 24, 2026, not a claim
that every platform has passed release or physical-device testing.

## What already travels between operating systems

The Go server serves the web player, API and media from one address. It uses
SQLite within the server process; running the web player does not require a
separate Node service. The current server cross-compiles with `CGO_ENABLED=0`
for Windows amd64, macOS arm64 and macOS amd64. These compile checks do not prove
Windows runtime behavior. The persistent local lab runs on macOS; packaged
deployment currently targets Linux amd64 and arm64.

The web player uses browser APIs rather than an installed operating-system
application. Its ordinary server connection is not restricted to Apple devices.
Chromium and WebKit are covered by the local browser checks; this is not a full
Firefox, Android, Windows or physical Safari test matrix. Folder selection,
background audio, media controls and Home Screen behavior still need coverage
on each supported browser/device. Optional WebKit audio-session integration has
a fallback and does not make it a Safari-only player.

## Gaps

| Area | Current limitation | Work needed |
| --- | --- | --- |
| Release downloads | `scripts/build-server-release.py` builds Linux executables and validates ELF files. The release workflow publishes Linux archives. | Add Windows/macOS artifact formats, checksums and platform-specific validation; include the same built web files. |
| Installation and updates | The guided installer needs Linux, root access and systemd; deployment checks currently run on Ubuntu. The hosting guide also covers running the same binary directly on other Linux setups. | Native per-platform setup, autostart, auth-token retrieval, update and rollback paths, with equivalent protection for credentials and data. |
| Existing setup wizard | `sync-server/cmd/codec-sync-server/setup.go` has older macOS/Linux/Windows login-start branches and desktop-app installation code. | Review and test these independently of the paused desktop GUI; login-start behavior is not a tested background service or updater. |
| Local development | `scripts/local-dev.py` imports Unix `fcntl`, calls `ps`, uses signals and managed symlinks. The default demo path assumes this developer's local fixture. | Portable locking/process management and a configurable fixture; validate Windows paths and permissions rather than weakening the safeguards. |
| Windows storage/security | The config writer assumes Unix `0600` protects the token; this does not establish a private Windows ACL. Uploaded media replacement uses rename while streaming can hold the destination open. Fingerprint filenames do not exclude Windows device names such as `CON`. | Establish private credential ACLs and validate reserved names and file replacement while streaming on actual Windows. These are source-identified risks; a Windows runtime reproduction was not performed. |
| Test gate | The full local check includes a macOS/Swift compatibility step. CI has Linux/macOS jobs, no Windows runtime job. | Split common server/web checks from Apple-specific checks; add actual Windows install/import/playback/restart/update coverage. Retain the unchanged-iOS-client compatibility gate for server releases. |
| Native apps | The SwiftUI app uses Apple playback, Keychain and UI frameworks and targets iPhone/iPad. | Android currently uses the web player. An Android native app would be separate client work, not a server portability fix. Desktop GUI distribution remains paused. |

The repository already has a `Dockerfile` and `docker-compose.yml` for the server
and web player. They run a Linux container with a persistent data volume. That is
an existing alternative to native installation, but it still requires a
compatible container runtime; this audit did not verify it on every host OS or
establish a maintained published image/update workflow.

The old setup wizard's desktop option is conditional on an adjacent desktop app
bundle, which current releases omit. Its branch that skips server installation
still instructs users to open that desktop app. This is a confirmed stale setup
instruction, not evidence that a tested desktop GUI is currently distributed.

## Suggested order

1. Make running the server equally straightforward on Linux, macOS and Windows:
   native packages and clear setup, with the container route documented as an
   alternative. Keep persistent data and credentials separate from application
   files on every platform.
2. Add runtime checks on those operating systems: import/reimport, custom cover
   replacement, streaming while updating media, restart, backup, update and
   rollback. Review file replacement, locking, symlink/hard-link and permission
   behavior on Windows before declaring support.
3. Make the local server/web lab portable while keeping iOS builds and device
   tests in their macOS-specific stage.
4. Expand browser/device coverage, then assess a native Android app separately.

Publishing packages, deploying a server and distributing a native app remain
separate release actions; see the [release checklist](release-checklist.md).
