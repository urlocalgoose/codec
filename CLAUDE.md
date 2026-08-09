# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Codec Is

Codec (formerly Loud) is a local-first music player/library manager built as a Tauri v2 desktop app (SvelteKit + Svelte 5 frontend, Rust backend), with a portable Go sync server that serves the same web UI as a mobile PWA and syncs libraries between devices, plus a native SwiftUI iOS app.

**Naming rule:** "Codec" is the brand (UI strings, app names, docs). The `loud.*` wire schemas, `.loud/` state folder, `loud://` roots, `LOUD_AUTH_TOKEN`, storage keys, and storage keys are historical and MUST stay — renaming them breaks existing libraries and synced devices. (Code identifiers were renamed to `Codec*` in 2026-08; only wire/storage names keep the prefix.)

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
cd ios/CodecMobile && swift test                      # iOS tests (runs on macOS)
```

## Architecture

Three clients speak one contract to one server:

1. **Tauri desktop app** — `src/` (frontend) + `src-tauri/` (Rust).
   - Rust core is `src-tauri/src/library/` (mod.rs holds types + public API; scan/ops/import/state/summaries/artwork/util/tests split per concern). App truth lives in `.loud/state.json` inside the user's music folder; new MP3s are copied to `.loud/audio/Artist/Album/`; likes and playlists are references to canonical tracks by fingerprint, never file copies.
   - `src-tauri/src/lib.rs` is Tauri commands + wiring only; `media_server.rs` is the token-per-path localhost stream server for the WebView; `sync_transfer.rs` moves MP3s/artwork to/from the sync server.
   - Frontend: `src/routes/+page.svelte` is the orchestrator (state + playback engine); markup lives in `src/lib/components/` (PlayerBar, TrackList, Sidebar, modals, etc. — Svelte 5 runes components); pure logic in `src/lib/*.ts` where the tests live. Keep new logic in `src/lib` so it stays testable. All styling is `src/app.css` (global, theme via `data-theme` attribute; themes defined in `src/lib/themes.ts` + app.css blocks).
   - **UI vibe is intentional**: tape-deck transport — the play button latches (`.play-button.active` stays pressed while playing), skip/prev are momentary. Don't "modernize" it.

2. **Go sync server** — `sync-server/`, module `codec-sync-server`, single dependency (`modernc.org/sqlite`, no cgo). One package split by concern: `server.go` (setup/routing/migrations), `hub.go` (SSE pub/sub), `handlers.go`, `store_library.go`, `store_playback.go`, `playback_v2.go` (playback state machine), `httputil.go`, `summaries.go`, `helpers.go`. Optional shared-token auth via `LOUD_AUTH_TOKEN` (Basic for browsers, Bearer for API clients; `/health` stays public).

3. **iOS app** — `ios/CodecMobile/` (SwiftPM + xcodeproj). Speaks the same v1/v2 API as the web client.

### Sync contracts

- `loud.sync.v1` — snapshot/push schema shared between Rust (`SYNC_SCHEMA` in `src-tauri/src/lib.rs`), the Go server, and `src/lib/sync.ts`. Changing it means touching all three.
- `loud.playback.v2` — shared playback state (queue/position/devices) over SSE; state machine in `sync-server/internal/server/playback_v2.go`, client in `src/lib/sync.ts`.
- `loud.import.v1` — import manifest for external downloaders, documented in `docs/loud-import-v1.md` with JSON schema at `docs/loud-import.schema.json`.

### Track identity

Cross-device matching uses a canonical identity chosen in priority order: `fingerprint`, then ISRC, MusicBrainz recording ID, Spotify track ID, YouTube video ID, then normalized title+artist+album (identity strings like `isrc:...`, `spotify:track:...`). Playlists and likes always reference canonical identities. See `docs/loud-import-v1.md`.

### API

The Go server's endpoints are listed in `docs/loud-sync.md` (`/api/v1/library`, `/api/v1/sync/*`, `/api/v1/tracks/{fingerprint}/*`, `/api/v2/playback*`). The server returns `Library` JSON matching the types in `src/lib/types.ts`.

### History note

An earlier Cloudflare Worker backend and its device-key `loud.sync.v3` protocol were removed (recoverable from git history). Cloudflare's only role is DNS/HTTPS/Tunnel in front of the Go server. Do not resurrect the worker.

## Docs to read before touching sync

`docs/loud-sync.md` (server + flows), `docs/secure-sync.md` (auth model), `docs/loud-import-v1.md` (import manifest and identity rules).
