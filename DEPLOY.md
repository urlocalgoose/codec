# Deploy Codec

Codec deploys as one Go sync server plus the built Svelte app. Cloudflare can
sit in front for DNS, HTTPS, and tunneling, but the app server is still the Go
binary.

For Linux, at home or on a cloud host such as Lightsail, follow the [server release and installation
guide](docs/server-release.md). It packages the server and website together,
keeps the library outside releases, and provides checksum validation and health
checks with application rollback for systemd installations. Other Linux setups
can run the same binary with their own service manager. Building artifacts does
not deploy to AWS.

After deployment, retrieve the existing login token over SSH with
`sudo /opt/codec/current/scripts/ubuntu-auth.sh`. The
[Linux installation guide](docs/server-release.md#install-on-linux-with-systemd)
explains token setup and retrieval. Install/update logs keep the token hidden.

The documentation index is [here](docs/README.md). Historical hosting prices and
benchmarks are not deployment acceptance results.

## Build

```bash
bun run build
cd sync-server
go build -o codec-sync-server ./cmd/codec-sync-server
```

## Run

```bash
CODEC_AUTH_TOKEN='replace-with-a-long-random-value' ./codec-sync-server \
  --addr :8787 \
  --data /srv/codec \
  --web /srv/codec-web
```

`CODEC_AUTH_TOKEN` is the publish-facing env var. `LOUD_AUTH_TOKEN` still works
as a legacy alias, but do not use it in new deploys.

The data directory contains:

- `codec-sync.sqlite` plus SQLite WAL files
- `audio/` media blobs
- `artwork/` managed original cover images (including imported JPEG/PNG)

Back up the whole data directory while the server is stopped, or use SQLite's
online backup tooling for the database and copy media after.

## Docker

```bash
docker compose --env-file /private/path/codec.env up --build -d
```

The compose file requires `CODEC_AUTH_TOKEN`, binds the published port to
loopback and stores data in the `codec-data` Docker volume. The private env file
contains the token; never commit it. Put the HTTPS proxy on the host in front
of port 8787. `.dockerignore` limits build context to application source.

## HTTPS

Do not expose plain HTTP on the public internet. Put one of these in front:

- Cloudflare Tunnel
- Caddy
- nginx
- a provider load balancer

Proxy rules:

- Forward `Host` and `X-Forwarded-Proto`.
- Support long-lived GET responses for SSE at `/api/v2/playback/events`.
- Support range requests for `/api/v1/tracks/*/audio`.
- Do not log query strings. Current clients use short-lived `stream_...`
  tokens in media/SSE URLs, and old clients may put the main token there.

## Local macOS service updates

For a locally built binary managed by `launchd`, apply an explicit ad-hoc
signature before installation:

```bash
codesign --force --sign - --identifier sh.codie.codec.sync-server ./codec-sync-server
codesign --verify --strict ./codec-sync-server
```

Keep the previous executable and an online SQLite backup, then atomically
replace the installed executable. Reload the LaunchAgent with `launchctl
bootout` followed by `bootstrap` and `kickstart`, using its existing plist and
label. Merely restarting an already registered job can retain the old binary's
launch constraints and reject the replacement. Verify `/health` immediately;
restore the previous binary and reload the job if startup fails. These signing
steps are for local development, not a substitute for signing distributed
releases.

After an efficiency update, verify authenticated library revalidation through
the public proxy, as well as directly against the origin. An unchanged library
must return `304` with no body when sent the exact returned ETag. See
[data-efficiency.md](docs/data-efficiency.md) for measurements and regression
checks.

## Smoke Test

```bash
curl https://YOUR_HOST/health
curl -H "Authorization: Bearer $CODEC_AUTH_TOKEN" https://YOUR_HOST/api/v1/library
```

Then open `https://YOUR_HOST` in a computer or phone browser, connect with the same token,
and confirm artwork, playback, Aux, and "Playing on..." all work.
