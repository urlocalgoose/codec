# Ubuntu / Lightsail deployment

Each Codec library runs in one Go process serving its API, media and built
Svelte website. The Swift app and web player connect to that API. The Ubuntu
deployment uses systemd for Codec and Caddy as its reverse proxy. Production needs no Bun, Node,
Rust, Go compiler, Docker daemon, or separate web application service.

## Deployment boundaries

The reusable installer manages one Codec service and its data directory. Separate
libraries may run as separate services on one host or on independent hosts. Each
must keep its own database, media, token and service account. Shared executable
or web directories do not make their libraries shared.

Keep host addresses, deployment counts, migration receipts and rollback targets
in a private readiness record, not in this reusable guide. The
[release checklist](release-checklist.md) identifies the listening and review
destinations and how to coordinate updates. Detect shared web paths before a
web-only update: one symlink switch can affect several services at once.

The static project site at `codec.codie.sh` is separate from the listening
servers and does not hold their music or credentials.

## Layout and release contract

```text
/etc/codec/codec.env                     private server token
/var/lib/codec/                          persistent SQLite, audio, artwork
/var/backups/codec/*.sqlite              private pre-update database backups
/opt/codec/releases/codec-server-VERSION-linux-ARCH/   installed release
/opt/codec/current -> releases/...       active executable release
/opt/codec/web/current/web/               runtime web view + retained old assets
/etc/systemd/system/codec.service       service definition
/etc/caddy/Caddyfile                     hostname and reverse proxy
```

A release archive is named `codec-server-VERSION-linux-ARCH.tar.gz`, where
`ARCH` is `amd64` or `arm64`. Its same-named top-level directory contains
`codec-sync-server`, `web/`, `release.json`, `SHA256SUMS`, deployment tooling,
license and this guide. The adjacent `.tar.gz.sha256` verifies the archive;
internal checksums verify its payload. Installers reject unsafe paths, links,
incorrect platform/architecture, and checksum mismatches before switching.

Checksums detect corruption; they do not authenticate an untrusted download.
Obtain both archive and checksum from the reviewed CI release or another trusted
channel.

The archive contains application code only. Tokens, SQLite files, user audio,
private images, local test fixtures and the S2Y source bundle do not belong in
release artifacts. Persistent data stays outside release directories.

A new installation starts with an empty library unless a separate migration or
import is explicitly performed. Deploying with music is a data operation; it
does not change the reusable release archive. Copy an existing server's database
and managed media when moving that library, or use the additive importer for a
new collection. Never put a personal library in a public release or review app.

## Build and CI

Use the Bun version in `package.json` and Go version in `.go-version`. Build on
the development machine or CI, not on a small production VM. Dependency lock
files are used; generated assets and the server binary ship together.

```bash
bun run release:server -- --version VERSION
```

The release workflow runs checks before producing Linux amd64/arm64 archives
in `dist/server/`. Review the workflow's publication mode and follow the
[release checklist](release-checklist.md) before creating tags or publishing
artifacts. Building a package does not activate it on a server. Desktop GUI
packages are not a current release target. See the workflow and builder help
for exact switches:

```bash
python3 scripts/build-server-release.py --help
```

Local packaging can record a dirty working tree for testing. Use a reviewed,
committed revision for production releases; version/commit/toolchain metadata
in `release.json` identifies what was built. Archive ordering, ownership and
timestamps are normalized, and the PWA build ID derives from release and source
content. Exact byte reproducibility requires the same inputs and toolchains,
including the Python/zlib versions recorded in the release manifest.

CI builds the web app once in the checked web job, then passes its
`checked-release-web` artifact to Linux packaging in the same workflow run.
The builder checks the source digest, commit, Bun version, release label,
embedded PWA build ID and every file's checksum before reusing it. Source
changes, missing/extra files and altered assets fail verification. It does not
trust an arbitrary existing `build/` directory; `--skip-web-build` was removed.
See [fast checks and verified build reuse](fast-checks.md) for local commands
and the distinction between fast feedback and the complete release gates.

## Prepare a new Ubuntu host

Use a supported Ubuntu LTS image and choose the archive matching `uname -m`:
`x86_64` → `amd64`, `aarch64` → `arm64`. Check disk capacity against the current
media tree, artwork, SQLite, backups, release history and temporary imports.
A compressed import archive, extracted source, staging copies and backups can
multiply the space needed for a music collection.
No particular instance price or capacity is assumed here.

For a direct public HTTPS deployment, attach a static IP before pointing the public hostname at the instance.
Allow public TCP 80/443, restrict SSH to your administration addresses, and
keep Codec's 8787 port private. Lightsail's firewall applies to the public
address; the service also binds to loopback. See the official
[AWS static-IP guide](https://docs.aws.amazon.com/lightsail/latest/userguide/lightsail-create-static-ip.html)
and [Lightsail firewall documentation](https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-firewall-and-port-mappings-in-amazon-lightsail.html).

Install runtime tools:

```bash
sudo apt-get update
sudo apt-get install -y python3 ca-certificates curl rsync sqlite3
```

Install Caddy using its [official Ubuntu package instructions](https://caddyserver.com/docs/install#debian-ubuntu-raspbian).
The package provides a systemd service. Use the supplied Caddyfile example,
replace its example hostname, validate it, then reload Caddy. DNS and ports
80/443 must reach that host for normal automatic certificate issuance.

Caddy forwards to `127.0.0.1:8787`. Preserve Range requests, authentication,
forwarded host/protocol and library ETags. Do not buffer request bodies or
compress audio/ZIP files. Caddy immediately flushes SSE responses by default;
no blanket buffering override is necessary. The supplied configuration compresses
HTML/CSS/JavaScript/JSON and SVG, while excluding audio, ZIPs and event streams. The configuration omits request
access logs so credential-bearing legacy URL queries are not written to them.
See [Caddy reverse proxy behavior](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy).

## Install and update

Transfer the reviewed archive, its `.sha256`, and the installer tooling over
SSH with host-key verification. Keep the auth token in a private file; never
paste it into a command argument, release archive, CI log, or repository.
For migration, retain the existing token so current phone connections keep
working. The first install can accept `--token-file`; ordinary updates retain
the configured token. Omitting `--token-file` on a fresh installation generates
a private token file without printing the token. Use the existing token when
moving the current library. Automatic SQLite backups are not automatically
pruned; manage retention with a deliberate backup policy.

```bash
sudo scripts/ubuntu-install.sh codec-server-VERSION-linux-amd64.tar.gz \
  --sha256-file codec-server-VERSION-linux-amd64.tar.gz.sha256 \
  --token-file /private/path/codec-token

sudo scripts/ubuntu-update.sh codec-server-NEXT-linux-amd64.tar.gz \
  --sha256-file codec-server-NEXT-linux-amd64.tar.gz.sha256
```

Run `--verify-only` to validate an archive without installing it. `--root-dir`
is an isolated filesystem test mode, not a way to start another production
server. Consult `--help` for the exact interface. The updater automatically
restores the prior code/web links when startup fails; to deliberately return
to a known compatible release, run the updater with that older archive and
its trusted checksum.

The updater installs a versioned release, constructs a separate runtime web
view, switches the executable/web symlinks, restarts Codec, and checks health. Its pre-update backup covers SQLite while
the service is stopped; it does not duplicate the entire audio/artwork tree.
Previous hashed web assets remain available to open tabs; verified release
payloads stay unchanged. Retained assets are not automatically pruned until a
client-retention policy makes that safe. Failed health checks restore the previous
application release. This **does not roll back the database**: app rollback
and data restore are distinct. Future schema changes must preserve rollback
compatibility or document a separate migration/restore procedure.

Inspect service status with `systemctl status codec` and `journalctl -u codec`.
Routine updates need a brief service restart; SSE reconnects and audio clients
must tolerate it. This is not a zero-downtime deployment promise.

These installer/update commands manage **`codec.service` only**. The review
service shares its code paths but needs the separate maintenance steps below.

## Retrieve the auth token after deployment

After installation, the installer prints the retrieval command. SSH into the
Ubuntu host and run:

```bash
sudo /opt/codec/current/scripts/ubuntu-auth.sh
```

Or run it directly from your Mac with an SSH terminal:

```bash
ssh -t ubuntu@YOUR_HOST 'sudo /opt/codec/current/scripts/ubuntu-auth.sh'
```

Enter that token with your server's HTTPS address in Codec's connection screen.
This reads the configured `CODEC_AUTH_TOKEN` from the private
`/etc/codec/codec.env` used by the service. It does not generate or rotate a
token, restart Codec, or change the library. It also works while the service
is stopped. Keep the existing token during migration so current phone
connections continue working.

For direct copying to your Mac's clipboard without displaying it, use the
explicit raw-output mode over SSH. This requires the admin's noninteractive
sudo access; an SSH/sudo failure leaves the clipboard unchanged:

```bash
if codec_auth="$(ssh ubuntu@YOUR_HOST 'sudo -n /opt/codec/current/scripts/ubuntu-auth.sh --raw')"; then
  printf '%s' "$codec_auth" | pbcopy
fi
unset codec_auth
```

Normal retrieval requires a terminal. `--raw` deliberately allows a private
pipe and emits only the token; do not send that output into deployment logs.
Install/update logs continue to contain the retrieval command, never the token.
The helper is packaged with each release and remains executable after install.
The active-release path follows successful updates and rollback automatically.
No public token-retrieval endpoint is added to the website.

The reader supports the installer's quoted token and single-line systemd
assignments without shell evaluation. Missing/ambiguous configuration, unsafe
file permissions or unsupported multiline values produce a value-free error;
the helper never guesses another token or modifies the file.


## Move the current library without replacing it

The migration copies the existing authoritative data directory; it does not
re-import S2Y into an empty server. Keep the same server identity, fingerprints,
playlist IDs/order, likes, original media, and auth token. Keep the public
hostname if practical so existing phone configuration remains valid.

1. Verify the active Mac service configuration and take an online SQLite
   backup plus media backup. Do not copy a live SQLite main file alone and
   discard its WAL. Record library identity/counts, ordered memberships and
   representative audio/artwork hashes.
2. Prepare the Ubuntu installation privately. Seed-copy audio and artwork over
   SSH while the current server is still available. Keep enough free space for
   the complete transfer and backup; preserve filenames and bytes.
3. Schedule a short write freeze. Stop the old service, create a clean final
   database copy and perform the final media synchronization. Only one server
   may accept library or playback writes during cutover. A local CLI staging
   root or the S2Y source bundle is not a substitute for the live server data.
4. The installer starts Codec immediately, so first stop the destination with
   `sudo systemctl stop codec`. Restore into `/var/lib/codec` while it is stopped;
   never copy a database/WAL over the running destination. Set ownership with
   `sudo chown -R codec:codec /var/lib/codec` after the one-time restore. Do this
   before making the new host public. Database rows can contain absolute media paths from
   the Mac; use the verified media-path relocation behavior and test original
   file retrieval after copying. `TestDataDirectoryRelocationPreservesLibraryMediaAndExport`
checks restart, server identity, metadata/likes/order, original covers, audio
Range reads and export after the old absolute paths are removed. Never edit
identities to match the new path.
5. Start Codec privately and verify the same server ID, exact fingerprint set,
   playlist IDs/order, liked state, audio Range responses, image hashes/MIME,
   authenticated library 304 responses and live SSE updates. Open the current
   phone build and verify downloads still play without streaming.
6. Point the existing public hostname to the new host, verify HTTPS and the
   same checks externally, then monitor playback and reconnects. Keep the old
   data backup until the new host is accepted. If reverting, choose one
   authoritative dataset; do not enable both writers or discard new writes.

If media relocation is not verified by tests for a particular historical
server version, stop before DNS cutover and fix/test that compatibility. The
runbook does not authorize speculative SQL rewrites on the live collection.

## Keeping an existing Cloudflare hostname during migration

The direct Caddy HTTPS setup above remains suitable for a hostname pointed at
the instance's static IP. An existing Cloudflare Tunnel can instead retain the
public hostname while a new, separately named AWS tunnel is prepared. Keep the
old hostname routed to its old tunnel until the final database is copied and
the destination is verified. Two independently writable library copies must
not be connected as replicas of one tunnel.

For this topology, Cloudflare terminates public HTTPS and `cloudflared` connects
to a Caddy listener bound to loopback. The listener must accept the public Host
header; an address such as `http://127.0.0.1:8786` adds a host matcher and can
return an empty response for the public hostname. Use a hostless listener with
an explicit loopback bind:

```caddyfile
http://:8786 {
    bind 127.0.0.1
    # Keep the text-only encode matcher from Caddyfile.example here.
    reverse_proxy 127.0.0.1:8787 {
        # Only for this HTTPS-tunnel-only, loopback-bound topology.
        header_up X-Forwarded-Proto https
    }
}
```

Without preserving the public scheme, Caddy's default forwarded headers can
make Codec return HTTP artwork/audio URLs inside an HTTPS library response.
Verify the returned absolute URLs as well as HTTP status, image decoding, audio
Range, gzip, conditional library requests and live event delivery. Do not fix a
test by rewriting insecure returned URLs to HTTPS in the test client.

Use an independent service account, data directory, token and loopback port for
the Apple review library. Both services can share the installed release binary;
they must not share the database, credentials or media directory. The reviewer
service contains only the validated open-license 100-song collection. Its
credentials belong in private App Store Connect review notes. Source credits
can be public; private configuration and verification working files cannot.

At cutover, freeze writes to the old library, copy its final SQLite snapshot and
changed media, verify identities and ordered memberships, then change the
hostname's tunnel route. Keep an original backup for recovery. A local SSH
forwarder can retain the old localhost address while using the single AWS
database; it must not restart the old writable server in parallel.

See [Cloudflare's locally managed tunnel guide](https://developers.cloudflare.com/tunnel/features/locally-managed-tunnels/create-local-tunnel/)
and [Caddy forwarded-header behavior](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy#defaults).

## Maintain the separate review service

A separate review service can use user/group `codec-review` and these paths:

```text
/etc/systemd/system/codec-review.service
/etc/codec-review/codec.env              review token; root-owned, mode 0600
/var/lib/codec-review/                  review SQLite, audio and artwork
```

Its command is:

```text
/opt/codec/current/codec-sync-server --addr 127.0.0.1:8788 --data /var/lib/codec-review --web /opt/codec/web/current/web
```

`ubuntu-update.sh` stops, backs up, restarts and checks only `codec.service`.
It does not manage the review database or unit. Before a shared-code update,
back up the review database and media separately. After a successful update,
explicitly restart `codec-review.service`, check `systemctl status codec-review`
and `journalctl -u codec-review`, and verify its local health endpoint and public
authenticated library/audio/artwork access. Switching the common executable
symlink does not replace a running review process. Apply the same separate
review checks after rolling back shared code.

```bash
sudo systemctl restart codec-review.service
curl --fail http://127.0.0.1:8788/health
```

Keep review backups outside both live data directories, for example in a new
root-only dated directory under `/var/backups/codec-review`. SQLite's online
backup operation can create a database snapshot without copying a live main
file and losing its WAL:

```bash
sudo sqlite3 /var/lib/codec-review/codec-sync.sqlite \
  ".backup '/var/backups/codec-review/REVIEW-BACKUP/codec-sync.sqlite'"
```

Create the private backup directory first. Also copy the review `audio/` and
`artwork/` directories into that same backup. For a consistent database/media
restore point, pause review imports and edits during the copy, or briefly stop
only `codec-review.service` while making the complete backup. Check SQLite
integrity and media hashes, store a copy outside the VM, and test restoration
in an isolated directory. Schedule backups deliberately and record the policy
privately. An original import bundle or empty installation directory is not a
backup of later reviewer changes.

The auth retrieval helper reads only `/etc/codec/codec.env` for personal music.
It does not retrieve the review token. The review service reads its separate
`/etc/codec-review/codec.env`; keep that credential private and use it only for
the review server and App Store Connect review access.

## Backups and cost controls

Application release rollback does not protect music or SQLite. Maintain
consistent database/media backups outside the VM, and periodically restore a
backup into a separate directory to prove it works. Lightsail snapshots can
supplement this, but a snapshot policy must be deliberately enabled and tested;
see [AWS snapshot documentation](https://docs.aws.amazon.com/lightsail/latest/userguide/understanding-snapshots-in-amazon-lightsail.html).

Keep media quality unchanged. Use API compression/revalidation, cached artwork,
local downloaded playback, bounded retries and event-driven refreshes to reduce
transfer and CPU. Avoid redundant ZIP uploads for large collections: the CLI
additive merge sends missing files individually. See [data efficiency](data-efficiency.md)
and the [performance plan](performance-plan.md) for measurements and next work.

## Validation record

See [deployment validation](deployment-validation.md) for the isolated Ubuntu,
systemd transaction, proxy, archive and Docker checks, plus commands to repeat
them. CI runs the real packaged Caddy configuration against synthetic data.
Local package checks and Linux smoke tests do not establish a deployed AWS
instance, working DNS/TLS, remote SSH access, provider costs or physical-phone
performance. Those must be checked during the actual migration.
