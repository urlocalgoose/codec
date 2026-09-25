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

For development, use the isolated demo servers:

```bash
bun run local:up
```

This builds the web player and starts two persistent local servers on ports
8791 and 8792. Each address serves both the player and API. See
[local development](local-development.md) for credentials and private phone
access; `server:dev` is an alias for the same lab. Vite is only needed when
working directly on the frontend.

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
POST /api/v1/import/uploads
GET  /api/v1/import/uploads/{id}
PUT  /api/v1/import/uploads/{id}?offset={bytes}
POST /api/v1/import/uploads/{id}/complete
DELETE /api/v1/import/uploads/{id}
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

In the web app, open **Settings → Import music** and select a bundle ZIP.
Desktop browsers can also select **Import bundle folder** to package a manifest
with its audio, playlists, and artwork. Upload percentage, server processing
progress, and errors appear inside Settings; closing Settings leaves the same
progress available in the library. A completed upload becomes a server job, so
refreshing the page resumes checking that job rather than uploading it again.

ZIPs larger than 8 MiB use authenticated upload sessions. The browser creates a
session with `POST /api/v1/import/uploads` and `{"size": <total bytes>}`, sends
sequential pieces of at most 8 MiB with `PUT .../{id}?offset=<confirmed bytes>`,
then calls `POST .../{id}/complete` to start the import job. `GET .../{id}` returns
`{id, size, offset, chunk_size}` so a lost response can be reconciled before a
piece is retried. Completion is idempotent and returns the same job ID if its
response is retried. This keeps individual requests small enough for ordinary
proxy upload limits; server storage and the total bundle limit still apply.

If an older server returns 404 or 405 for upload sessions, bundles up to 64 MiB
fall back to the original single-request endpoint. Larger bundles ask for a
server update or the server import command. Existing clients can continue using
`POST /api/v1/import/bundle`; the new endpoints do not change their API.

An upload with no progress for 30 seconds reports the connection problem. You
can cancel an upload in Settings and choose the ZIP again. Cancellation stops
the upload; it does not undo an import job that the server has already started.
During server processing, temporary status failures show **Checking connection…**
with **Check again**. Status reads are sequential and time out after 15 seconds,
so a slow connection does not accumulate overlapping requests. Page-refresh
recovery applies to an acknowledged import job, not an unfinished upload.

Playlist edits are partial updates: `POST /api/v1/playlists` creates a playlist
from `{"name": "..."}`, and the `/tracks` endpoints add or remove one track by
fingerprint without replaying the whole playlist row. Reordering is different:
it replaces the supplied membership order, so clients must account for changes
made by another device rather than assuming every playlist edit is conflict-free.

Audio uploads remember their `Content-Type` (`audio/mpeg`, `audio/mp4`,
`audio/flac`, `audio/wav`) and serve it back on download; anything
unrecognized is stored as MP3, the historical default.


## Playback revisions

Playback commands may send an `If-Match` header containing the known revision.
A stale whole-queue replacement receives HTTP 409 rather than replacing a newer
queue. Clients refresh and ask for a retry; concurrent queue edits are not
silently merged. The optional revision is a header, not a new wire-schema field.
Older clients omitting it retain their existing behavior. Exercise delayed
commands, reconnects and concurrent edits against the isolated two-server lab.

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

## Aux v2 — scoped shared listening

See [the complete Aux v2 contract](aux-v2-protocol.md) for session creation,
invitations, participant credentials, listening modes, queue commands, scoped
media and event streams. See [selected-track sharing and durable saves](aux-transfer-protocol.md)
for personal-server grants, membership, copy permissions, playlist saves and
network limits. These APIs are separate from normal owner playback.

The legacy `/api/v1/aux` routes are intentionally retired with `410` and
`aux_update_required`. Old clients retain ordinary library/playback/download
support but need the new app for Aux. Old global `/api/v1/media-grants` and
foreign-track fields remain owner-authorized compatibility building blocks;
they do not authorize participation in an Aux v2 session.
