# Deploy Codec

Codec deploys as one Go sync server plus the built Svelte app. Cloudflare can
sit in front for DNS, HTTPS, and tunneling, but the app server is still the Go
binary.

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
- `artwork/` resized artwork blobs

Back up the whole data directory while the server is stopped, or use SQLite's
online backup tooling for the database and copy media after.

## Docker

```bash
CODEC_AUTH_TOKEN='replace-with-a-long-random-value' docker compose up --build -d
```

The compose file stores data in the `codec-data` Docker volume.

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

## Smoke Test

```bash
curl https://YOUR_HOST/health
curl -H "Authorization: Bearer $CODEC_AUTH_TOKEN" https://YOUR_HOST/api/v1/library
```

Then open `https://YOUR_HOST` on desktop and phone, connect with the same token,
and confirm artwork, playback, Aux, and "Playing on..." all work.
