# Codec Sync

Codec has one server path: the portable Go server.

- It serves the Svelte app.
- It serves the JSON API.
- It serves MP3/artwork media with range support.
- It stores metadata and playback state in SQLite.
- It stores media blobs on disk.
- It can run on your Mac, a VPS, a home server, or behind Cloudflare.

Cloudflare is not the app server. If Cloudflare is used, it should sit in front
of this Go server for DNS, HTTPS, tunnel, and optional access control.

## Run The Server

```bash
bun run server:dev
```

That builds the Svelte app and starts the Go server at `:8787`.

On another device, open the URL printed by the server:

```text
http://YOUR-MAC-IP:8787
```

That is both the app and the sync API. Do not open a separate Vite mobile app
unless you are only debugging UI.

For a public server, put it behind HTTPS and start it with a token:

```bash
LOUD_AUTH_TOKEN='long-random-secret' ./codec-sync-server \
  --addr :8787 \
  --data /srv/loud \
  --web /srv/loud-web
```

With a token set, the server accepts HTTP Basic auth in the browser and Bearer
auth for API clients.

## Desktop Flow

1. Open Codec.
2. Open your local music folder.
3. Use the sync controls to upload metadata, MP3s, and cached artwork thumbnails.
4. On another desktop, enter the same server URL and click download.

Pulling from the server downloads missing MP3s into a temp import bundle,
imports them through the normal Codec importer, then applies playlist and liked
state by fingerprint. Existing tracks should not duplicate.

## Mobile / PWA Flow

1. Run the Go server on a machine reachable by your phone.
2. Open the server URL in Safari.
3. Add it to Home Screen.

The phone uses the same Svelte UI as desktop. It streams MP3s from the same
server with HTTP range support. Offline audio downloads for iOS still need a
dedicated download/cache UI because browser storage limits and range requests
are strict; the current service worker only caches the app shell.

## API Shape

Important endpoints:

```text
GET  /health
GET  /api/v1/library
GET  /api/v1/sync/snapshot
POST /api/v1/sync/push
PUT  /api/v1/tracks/{fingerprint}
PUT  /api/v1/tracks/{fingerprint}/liked
PUT  /api/v1/tracks/{fingerprint}/audio
GET  /api/v1/tracks/{fingerprint}/audio
PUT  /api/v1/tracks/{fingerprint}/artwork
GET  /api/v1/tracks/{fingerprint}/artwork
PUT  /api/v1/playback-session/{device_id}
GET  /api/v1/playback-session/latest
GET  /api/v2/playback
POST /api/v2/playback/commands
GET  /api/v2/playback/events
```

The server returns `Library` JSON compatible with the existing Svelte app types.
