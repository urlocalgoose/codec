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
CODEC_AUTH_TOKEN='long-random-secret' ./codec-sync-server \
  --addr :8787 \
  --data /srv/codec \
  --web /srv/codec-web
```

With a token set, the server accepts HTTP Basic auth in the browser and Bearer
auth for API clients.

## Additive Headless Imports

Use an empty staging music folder for a prepared import bundle, then merge it
into the server with the CLI. Authentication is read from a file (or
`CODEC_AUTH_TOKEN`), and is never included in the JSON report:

```bash
cargo run --manifest-path src-tauri/Cargo.toml --bin codec_import -- \
  /path/to/staging-library /path/to/bundle/codec-import.json \
  --server http://127.0.0.1:8787 --token-file /private/path/token \
  --report /path/to/import-report.json
```

Server imports are additive by default; `--merge` is an optional explicit
spelling. This path does **not** call the snapshot replacement endpoint:

- Tracks match by exact fingerprint. Existing metadata is retained; only new
  tracks receive metadata and missing audio is uploaded.
- Likes are a union: incoming likes may add likes but cannot remove existing
  ones.
- Regular playlists match by their exact trimmed name. Ambiguous duplicate
  names abort before any server writes. New playlists use the ID returned by
  the server; existing playlist IDs and ordered memberships are retained, with
  only missing tracks appended in incoming order.
- Original sidecar images are uploaded with their actual MIME type, without
  JPEG re-encoding. External sidecars support JPEG and PNG up to 12 MiB,
  8192 pixels on either edge, and 16,777,216 pixels total. Playlist covers upload after the destination playlist is
  created. Existing destination covers are preserved using HEAD checks and
  conditional PUTs. A failed HEAD never authorizes an overwrite. Servers with
  conditional-upload support also protect against a concurrent cover edit;
  older servers preserve covers observed by HEAD but cannot close that race.

`track-artwork.json` and `playlist-artwork.json` use the S2Y artwork sidecar
schemas described in [S2Y artwork import](s2y-artwork-import.md). Artwork is
applied by exact track fingerprint or destination playlist name, including
already-matched tracks. No mobile app update is required: uploads use the
existing library, audio, and artwork API endpoints.

The report contains local import details, successful track fingerprints,
server track matched/added counts, media transferred/already-present counts,
track and playlist artwork uploaded/downloaded/present/missing/failed counts,
playlist creation/membership counts, likes added, failures, and source-to-server
playlist ID mappings. The CLI exits unsuccessfully if any import or transfer
fails and still writes the report when requested. Re-running the command skips
completed media and memberships.

For a restart/rescan check or an artwork/audio round trip:

```bash
codec_import /path/to/staging-library --scan --report /path/to/scan.json
codec_import /path/to/receiving-library --download \
  --server http://127.0.0.1:8787 --token-file /private/path/token \
  --report /path/to/download.json
```

The CLI download applies server playlist and liked state to the local library. The additive preservation guarantee above applies to
imports **into the server**.

## Mobile / PWA Flow

1. Run the Go server on a machine reachable by your phone.
2. Open the server URL in Safari.
3. Add it to Home Screen.

Mobile browsers use the same Svelte web app as larger screens. It streams audio from the same
server with HTTP range support. Explicit browser downloads keep audio in
CacheStorage and play it through local Blob URLs; the service worker caches the
app shell rather than every streamed song. Browser storage can be evicted and is
separate from the Swift app’s managed downloads. See
[mobile continuity and cache](mobile-continuity-and-cache.md).

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
PUT  /api/v1/playlists/{id}/artwork
GET  /api/v1/playlists/{id}/artwork
DELETE /api/v1/playlists/{id}/artwork
GET  /api/v1/export
POST /api/v1/import/bundle
GET  /api/v1/import/jobs/{id}
PUT  /api/v1/playlists/{id}
POST /api/v1/playlists
DELETE /api/v1/playlists/{id}
POST /api/v1/playlists/{id}/tracks
DELETE /api/v1/playlists/{id}/tracks/{fingerprint}
POST /api/v1/aux
GET  /api/v1/aux
DELETE /api/v1/aux/{code}
POST /api/v1/aux/join
POST /api/v1/auth/stream-token
PUT  /api/v1/playlists/{id}/tracks
POST /api/v1/media-grants
PUT  /api/v1/playback-session/{device_id}
GET  /api/v1/playback-session/latest
GET  /api/v2/playback
POST /api/v2/playback/commands
GET  /api/v2/playback/events
```

The server returns `Library` JSON compatible with the existing Svelte app types.

`POST /api/v1/auth/stream-token` requires normal host auth and returns a
short-lived token for media and playback-event URLs. It is accepted only for
GET/HEAD audio, artwork, and playback SSE endpoints.

`PUT /api/v1/playlists/{id}/artwork` stores a custom playlist cover (raw image
body); the library payload then carries `artwork_url` on that playlist. Covers
live beside track artwork on disk, keyed by playlist id, so they survive
snapshot pushes.

`GET /api/v1/export` streams the whole library as a zip: a `loud.import.v1`
manifest (`codec-import.json`) plus every audio file under `files/`. Import it
on any other Codec — identity matching skips songs the receiver already has.

`POST /api/v1/import/bundle` takes a `.loud.zip` as the raw body and answers
`202 {"id"}`; the server unpacks and applies it in the background. Poll
`GET /api/v1/import/jobs/{id}` for `{state, total, done, current, added,
existing, skipped, playlist_adds, liked}` — progress lives server-side, so a
client can refresh and resume watching by id.

Playlist edits are partial updates: `POST /api/v1/playlists` creates a playlist
from `{"name": "..."}`, and the `/tracks` endpoints add or remove one track by
fingerprint without replaying the whole playlist row. Reordering is different:
it replaces the supplied membership order, so clients must account for changes
made by another device rather than assuming every playlist edit is conflict-free.

Audio uploads remember their `Content-Type` (`audio/mpeg`, `audio/mp4`,
`audio/flac`, `audio/wav`) and serve it back on download; anything
unrecognized is stored as MP3, the historical default.


## Playback playlist origin

The shared `loud.playback.v2` state and commands accept an optional
`context.playlist_id`. Clients set it to the destination library playlist ID
when starting playback from that playlist, including Liked Songs. This is the
source the user chose, not a guess based on which playlists contain the current
song. For example:

```json
{
  "playlist_id": "playlist-destination-id",
  "playback_source": [{"id": "track-id", "path": "/music/song.mp3", "fingerprint": "track-fingerprint"}],
  "playback_index": 0,
  "queued_tracks": [],
  "play_history": [],
  "shuffle": false,
  "repeat": "off"
}
```

The ID stays attached to the source through next/previous, pause/resume, seek,
shuffle, repeat, queue edits, playback transfer, SSE snapshots, and server
restart. A manually queued song does not change the source playlist. Queue
replacements must include the current ID if they retain the same source.
An explicit replacement context without `playlist_id` clears the previous
origin; this includes older clients and playback started from search, an album,
or the whole library. Missing, null, and blank IDs all mean unknown.

The server treats this as playback metadata and does not require the playlist
to still exist. Clients resolve the ID against their current library to display
the current playlist name and cover; they hide the playlist entry if unavailable
or deleted. Renaming a playlist therefore does not leave an old name in playback
state. Existing phone versions remain compatible with the optional field.
The `loud.playback.v1` saved-session payload can also include `playlist_id`;
the server preserves that JSON extension without changing the schema version.

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
