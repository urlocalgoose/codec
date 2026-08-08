# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Loud Is

Loud is a local-first music player/library manager built as a Tauri v2 desktop app (SvelteKit + Svelte 5 frontend, Rust backend), with a portable Go sync server that serves the same web UI as a mobile PWA and syncs libraries between devices.

## Commands

Bun is the package manager and JS test runner.

```bash
bun run dev              # Vite dev server only (UI debugging, port 1420)
bun run tauri dev        # Full desktop app (Rust + frontend)
bun run server:dev       # Build web UI, then run Go sync server on :8787 (mobile/PWA flow)
bun run build            # vite build -> build/
bun run check            # svelte-check + typescript

bun run test             # frontend (bun test) + rust tests
bun test src/lib/sync.test.ts                        # single frontend test file
bun test -t "name"                                   # filter by test name
cargo test --manifest-path src-tauri/Cargo.toml      # rust tests
cargo test --manifest-path src-tauri/Cargo.toml some_test_name   # single rust test
cd sync-server && go test ./...                      # Go server tests (NOT in `bun run test`)
cd ios/LoudMobile && swift test                      # iOS LoudSecureSync tests (runs on macOS)
```

Note: `bun test` with no args also picks up `cloudflare/*.test.mjs` alongside `src/lib/*.test.ts`.

## Architecture

Three active pieces speak one shared contract; one piece is parked:

1. **Tauri desktop app** — `src/` (frontend) + `src-tauri/` (Rust).
   - `src-tauri/src/library.rs` (~2400 lines) is the core: scans a user-selected music folder, imports `loud.import.v1` manifests, and persists app truth in `.loud/state.json` inside that folder. New MP3s are copied to `.loud/audio/Artist/Album/`; likes and playlists are references to canonical tracks by fingerprint, never file copies.
   - `src-tauri/src/lib.rs` defines the Tauri commands, a filesystem watcher, and a small local media HTTP server (token-per-path) that streams audio/artwork to the webview.
   - Almost all UI lives in one file: `src/routes/+page.svelte` (~6000 lines). Pure logic is extracted into `src/lib/` (`library.ts`, `sync.ts`, `secure-sync.ts`, `types.ts`) where the tests live. Keep new logic in `src/lib` so it stays testable.

2. **Go sync server** — `sync-server/`, module `loud-sync-server`, single dependency (`modernc.org/sqlite`, no cgo). Serves the built Svelte app from `build/`, the JSON API, and media with HTTP range support. SQLite for metadata/playback state, disk for media blobs. Optional shared-token auth via `LOUD_AUTH_TOKEN` (Basic for browsers, Bearer for API clients; `/health` stays public). Nearly all logic is in `internal/server/server.go`.

3. **iOS app** — `ios/LoudMobile/`, SwiftPM. `Sources/LoudSecureSync` implements the device-key (P-256) secure sync client mirrored by `src/lib/secure-sync.ts` on the web side.

4. **Cloudflare Worker** — `cloudflare/` is **parked**. Per `docs/secure-sync.md`, do not extend it; Cloudflare's role is only DNS/HTTPS/Tunnel/Access in front of the Go server.

### Sync contracts

- `loud.sync.v1` — snapshot/push schema shared between the Rust side (`SYNC_SCHEMA` in `src-tauri/src/lib.rs`), the Go server, and `src/lib/sync.ts`. Changing it means touching all three.
- `loud.sync.v3` — secure sync (device enrollment with P-256 keys) in `src/lib/secure-sync.ts` and `ios/LoudMobile/Sources/LoudSecureSync`.
- `loud.import.v1` — import manifest for external downloaders, documented in `docs/loud-import-v1.md` with JSON schema at `docs/loud-import.schema.json`.

### Track identity

Cross-device matching uses a canonical identity chosen in priority order: `fingerprint`, then ISRC, MusicBrainz recording ID, Spotify track ID, YouTube video ID, then normalized title+artist+album (identity strings like `isrc:...`, `spotify:track:...`). Playlists and likes always reference canonical identities. See `docs/loud-import-v1.md`.

### API

The Go server's endpoints are listed in `docs/loud-sync.md` (`/api/v1/library`, `/api/v1/sync/*`, `/api/v1/tracks/{fingerprint}/*`, `/api/v2/playback*`). The server returns `Library` JSON matching the types in `src/lib/types.ts`.

## Docs to read before touching sync

`docs/loud-sync.md` (server + flows), `docs/secure-sync.md` (auth model and why the Worker is parked), `docs/loud-import-v1.md` (import manifest and identity rules).
