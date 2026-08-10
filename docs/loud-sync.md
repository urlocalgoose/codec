# Codec Sync

Codec has one server path: the portable Go server.

- It serves the Svelte app.
- It serves the JSON API.
- It serves audio (MP3, M4A, FLAC, WAV) and artwork media with range support.
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
3. Use the sync controls to upload metadata, audio files, and cached artwork thumbnails.
4. On another desktop, enter the same server URL and click download.

Pulling from the server downloads missing audio files into a temp import bundle,
imports them through the normal Codec importer, then applies playlist and liked
state by fingerprint. Existing tracks should not duplicate.

## Mobile / PWA Flow

1. Run the Go server on a machine reachable by your phone.
2. Open the server URL in Safari.
3. Add it to Home Screen.

The phone uses the same Svelte UI as desktop. It streams audio from the same
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
PUT  /api/v1/playlists/{id}
POST /api/v1/playlists
DELETE /api/v1/playlists/{id}
POST /api/v1/playlists/{id}/tracks
DELETE /api/v1/playlists/{id}/tracks/{fingerprint}
POST /api/v1/aux
GET  /api/v1/aux
DELETE /api/v1/aux/{code}
POST /api/v1/aux/join
PUT  /api/v1/playlists/{id}/tracks
POST /api/v1/media-grants
PUT  /api/v1/playback-session/{device_id}
GET  /api/v1/playback-session/latest
GET  /api/v2/playback
POST /api/v2/playback/commands
GET  /api/v2/playback/events
```

The server returns `Library` JSON compatible with the existing Svelte app types.

Playlist edits are partial updates: `POST /api/v1/playlists` creates a playlist
from `{"name": "..."}`, and the `/tracks` endpoints add or remove one track by
fingerprint without replaying the whole playlist row — so two devices editing
the same playlist never clobber each other.

Audio uploads remember their `Content-Type` (`audio/mpeg`, `audio/mp4`,
`audio/flac`, `audio/wav`) and serve it back on download; anything
unrecognized is stored as MP3, the historical default.


## Aux (`loud.aux.v1`) — shared listening

The host mints a 4-character code (`POST /api/v1/aux`); guests trade it for
a scoped token at the public `POST /api/v1/aux/join` (the web app does this
automatically for `/?aux=CODE` links and the QR the host shows). Guest
tokens can browse, stream, register as playback devices, and drive the
shared `loud.playback.v2` queue — nothing else. Ending the session kills
its guest tokens instantly.

### Cross-server aux (media grants)

Two Codec servers jam without ever dialing each other. A queued track from
another server rides in the `loud.playback.v2` track reference with
optional `title`, `artist`, `media_url`, and `artwork_url` fields; clients
that cannot resolve the fingerprint locally play the granted URL directly.
The guest's own server mints those URLs via `POST /api/v1/media-grants`
`{"fingerprints": [...]}` → a `grant_…` token valid 24h for GET
audio/artwork on exactly those tracks.
