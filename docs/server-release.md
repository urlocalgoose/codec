# Codec server and web release

This package runs one Codec music server and its web interface on Linux. Choose
`linux-amd64` for an x86-64 host or `linux-arm64` for a 64-bit ARM host. It includes
the compiled server, built web files, systemd install/update tools, this guide,
import documentation, and the MIT license. No music or credentials are included.

Native iPhone/iPad builds are separate;
installing a server package does not update an installed app.

## Download and verify

Download an archive and its matching `.tar.gz.sha256` from the same
[Codec release](https://github.com/urlocalgoose/codec/releases). Obtain both from
a trusted source: checksums detect corruption, not an untrusted publisher.
Replace `VERSION` and the architecture below with the downloaded filename.

```sh
codec_archive=codec-server-VERSION-linux-amd64.tar.gz
sha256sum -c "${codec_archive}.sha256"
tar -xzf "$codec_archive"
cd "${codec_archive%.tar.gz}"
python3 deploy/ubuntu/runtime.py install "../${codec_archive}" \
  --sha256-file "../${codec_archive}.sha256" --verify-only
```

The verifier checks archive paths, file types, metadata, and every payload
checksum without installing or starting a service. Each archive has one top-level
directory containing `codec-sync-server`, `web/`, `release.json`, `SHA256SUMS`,
`deploy/`, `scripts/`, `docs/`, public format examples in `site/examples/`, and
`LICENSE`. `release.json` identifies the
version, architecture, source revision, and toolchains.

<a id="install-on-ubuntu"></a>

## Install on Linux with systemd

The guided installer needs Linux, systemd, root access and the standard
`useradd` account-management tool. Its deployment checks currently run on Ubuntu;
other Linux configurations need their own runtime verification. For a different
service manager, see [running the binary directly](#other-linux-setups-and-source).
Allow enough disk space for music, artwork, backups and future imports.
The prebuilt server needs no Go, Rust, Bun or Node installation. Install Python 3
and CA certificates using your distribution's package manager. For Debian/Ubuntu:

```sh
sudo apt-get update
sudo apt-get install -y python3 ca-certificates
```

From the extracted release directory, install the verified archive:

```sh
sudo scripts/ubuntu-install.sh "../${codec_archive}" \
  --sha256-file "../${codec_archive}.sha256"
```

This creates the `codec` service account, installs `codec.service`, and starts
an empty library. A fresh installation generates an auth token in a private
configuration file. To retain an existing server token during a migration,
add `--token-file /path/to/private-token` on first install. Read the configured
token in your own terminal with:

```sh
sudo /opt/codec/current/scripts/ubuntu-auth.sh
```

The helper reads the token without rotating it. Enter it with your server URL
on Codec’s connection screen. Keep it out of public issues, screenshots, and
logs. Check startup with `systemctl status codec` and `journalctl -u codec`.

### Address and HTTPS

The installed service listens on `127.0.0.1:8787`. Put a reverse proxy in front
of that loopback listener to reach it from other devices. For public hosting,
use your own domain and HTTPS; keep port 8787 private. The supplied
[`Caddyfile.example`](../deploy/ubuntu/Caddyfile.example) uses
`music.example.com` as a placeholder. Install Caddy using its
[official instructions](https://caddyserver.com/docs/install), replace the
hostname, validate the configuration, and reload Caddy.

Point the domain at your host and allow the ports your HTTPS proxy requires.
Preserve audio Range requests, authorization, forwarded host/protocol, and
streaming playback events. The Go server serves both the web interface and API;
no second web application process is needed.

### Files and data

| Location | Purpose |
| --- | --- |
| `/etc/codec/codec.env` | Private auth configuration. |
| `/var/lib/codec/` | Persistent SQLite library, audio, and artwork. |
| `/opt/codec/releases/` | Verified application releases. |
| `/opt/codec/current` | Active server release. |
| `/opt/codec/web/current/web/` | Active web interface and retained assets for open tabs. |
| `/var/backups/codec/` | Pre-update SQLite backups. |

Bring music in with the web interface’s **Settings → Import music**. See the
included [Loud format guide](codec-import-v1.md) and
[artwork/import reference](s2y-artwork-import.md). Importing is separate from
installing the application. When moving an existing server, preserve its complete
database/media and token using a consistent backup; do not copy only a live
SQLite main file and discard its WAL.

## Update an existing installation

Download and verify the new matching archive and checksum. From its extracted
directory, use the update wrapper with the new archive’s path:

```sh
sudo scripts/ubuntu-update.sh ../codec-server-NEXT-linux-amd64.tar.gz \
  --sha256-file ../codec-server-NEXT-linux-amd64.tar.gz.sha256
```

Updates preserve the existing token and data directory, back up SQLite while
the service is stopped, switch the application/web links, restart the service,
and check health. Old hashed web assets remain available to open browser tabs.
A failed health check restores the previous application links. This is a brief
service restart, and it does not restore an earlier database.

Keep separate backups of audio, artwork, and the database. Automatic update
backups cover SQLite only and are not automatically pruned. To return to a known
compatible application version, use the updater with that release’s trusted
archive and checksum; database restore is a separate operation.

## Other Linux setups and source

The server binary can also run directly with explicit `--addr`, `--data`, and
`--web` paths. Auth can come from `CODEC_AUTH_TOKEN`; omitting auth leaves the API
open. The packaged installer uses a systemd service and the paths documented
above. Direct installations can use their distribution's service manager and
chosen persistent data paths.

Source and release history are at [urlocalgoose/codec](https://github.com/urlocalgoose/codec).
We’re not accepting contributions or pull requests right now. The source is
available to read and use under the [MIT license](../LICENSE).
