# Codec

Your music, your files, your server. Codec is an open-source, folder-first music
ecosystem: a desktop player, a portable sync server, a mobile web app, and an
iOS app — all speaking one simple contract, all backed by real MP3 files you
own.

No accounts. No cloud lock-in. Your library is a folder of MP3s; app truth
(likes, playlists, metadata fixes) lives in a `.loud/state.json` file inside
that folder. Everything else syncs through one small Go server you can run
anywhere.

## The pieces

| Piece | Stack | What it does |
| --- | --- | --- |
| **Desktop app** | Tauri 2 + Svelte 5 (Rust core) | Scans a music folder, plays locally, edits likes/playlists, pushes/pulls the sync server |
| **Sync server** | Go + SQLite, single binary | Serves the web app, the JSON API, and MP3/artwork with HTTP range support |
| **Mobile / web** | The same Svelte app, served by the server | Full player in any browser; add to Home Screen for a PWA |
| **iOS app** | SwiftUI | Native client that streams from the sync server |

## Quick start

Prereqs: [Bun](https://bun.sh), [Rust](https://rustup.rs) (desktop app),
[Go](https://go.dev) (sync server), Xcode (iOS app).

### Desktop

```bash
bun install
bun run tauri dev
```

Pick a music folder. Any folder of MP3s works; direct subfolders become
playlists, nested folders are scanned for tracks.

### Sync server

```bash
bun run server:dev
```

That builds the web app and starts the server on `:8787`. It prints the URLs
to open — the same URL is the web app, the API, and the sync target.

### Phone (PWA)

Open the server URL in your phone's browser (use your machine's LAN or
Tailscale address, not localhost) and add it to your Home Screen.

### iOS (native)

```bash
open ios/LoudMobile/LoudMobile.xcodeproj
```

Build to your device with Xcode, then paste your server URL into the app.

## Running the server for real

The server is one binary with three flags and one environment variable:

```bash
cd sync-server
go build -o codec-sync-server ./cmd/codec-sync-server

LOUD_AUTH_TOKEN='long-random-secret' ./codec-sync-server \
  --addr :8787 \
  --data /srv/loud \
  --web /srv/loud-web
```

- `--addr` — listen address (default `:8787`)
- `--data` — where SQLite state and media blobs live (default `./loud-sync-data`)
- `--web` — the built Svelte app to serve (default: the repo's `build/`; run `bun run build` first)
- `LOUD_AUTH_TOKEN` (or `--auth-token`) — optional shared secret. When set,
  browsers get HTTP Basic auth, API clients send `Authorization: Bearer <token>`,
  and only `/health` stays public.

It runs anywhere Go runs: a Mac in your closet, a VPS, a Raspberry Pi. For
public access, put HTTPS in front — a Cloudflare Tunnel, Caddy, nginx, or any
reverse proxy. The server has no provider-specific code.

## How sync works

Tracks are identified by a canonical fingerprint (ISRC, MusicBrainz ID,
Spotify/YouTube ID, or normalized title+artist+album — in that priority
order), so the same song never duplicates across devices. Playlists and likes
are references to canonical tracks, never file copies.

- Desktop ⇄ server: uploads/downloads real MP3s, artwork thumbnails, and
  metadata (`loud.sync.v1`)
- Any client ⇄ server: shared playback state — queue, position,
  play/pause, and cross-device transfer ("Playing on…") via
  `loud.playback.v2` over SSE

See [docs/loud-sync.md](docs/loud-sync.md) for the API surface.

## Importing music from other tools

Downloaders can hand Codec a `loud.import.v1` manifest (JSON + MP3s) and Codec
will import new tracks, match existing ones by identity, and apply likes and
playlists. Spec: [docs/loud-import-v1.md](docs/loud-import-v1.md), JSON schema:
[docs/loud-import.schema.json](docs/loud-import.schema.json).

## Development

```bash
bun run dev          # Vite dev server (UI only, port 1420)
bun run tauri dev    # full desktop app
bun run server:dev   # build web app + run Go server on :8787
bun run check        # svelte-check
bun run test         # frontend (bun) + Rust tests
cd sync-server && go test ./...          # Go server tests
cd ios/LoudMobile && swift test          # iOS sync client tests
```

Repo layout:

```
src/                  Svelte app (routes, lib, components)
src-tauri/            Rust core: scanning, import, state, media server
sync-server/          Go sync server (SQLite + media on disk)
ios/LoudMobile/       SwiftUI iOS app
docs/                 contracts and guides
```

## A note on names

Codec used to be called Loud. The wire schemas (`loud.sync.v1`,
`loud.playback.v2`, `loud.import.v1`), the `.loud/` state folder, and the
`LOUD_AUTH_TOKEN` variable keep the original prefix so existing libraries and
synced devices never break. Treat them as protocol identifiers, not branding.

## License

MIT
