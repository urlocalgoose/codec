# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What Codec Is

Codec (formerly Loud) is a local-first music player/library manager built as a Tauri v2 desktop app (SvelteKit + Svelte 5 frontend, Rust backend), with a portable Go sync server that serves the same web UI as a mobile PWA and syncs libraries between devices, plus a native SwiftUI iOS app.

**Naming rule:** "Codec" is the brand (UI strings, app names, docs, code identifiers). The `loud.*` wire schemas, `.loud/` state folder, and `loud://` roots are historical compatibility IDs and MUST stay without a migration. New env vars, docs, storage keys, and generated names should use `codec.*` / `CODEC_*`; old `LOUD_*` and `loud.*` app preferences are read only as aliases.

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

2. **Go sync server** — `sync-server/`, module `codec-sync-server`, single dependency (`modernc.org/sqlite`, no cgo). One package split by concern: `server.go` (setup/routing/migrations), `hub.go` (SSE pub/sub), `handlers.go`, `store_library.go`, `store_playback.go`, `playback_v2.go` (playback state machine), `aux.go` (pass-the-aux sessions: join codes, scoped guest tokens, cross-server media grants), `auth_tokens.go` (short-lived stream URL tokens), `httputil.go`, `summaries.go`, `helpers.go`. Optional shared-token auth via `CODEC_AUTH_TOKEN` (legacy alias `LOUD_AUTH_TOKEN`; Basic for browsers, Bearer for API clients; `/health` and the static web shell stay public — join links must load the app).

3. **iOS app** — `ios/CodecMobile/` (SwiftPM + xcodeproj). Speaks the same v1/v2 API as the web client.

### Sync contracts

- `loud.sync.v1` — snapshot/push schema shared between Rust (`SYNC_SCHEMA` in `src-tauri/src/lib.rs`), the Go server, and `src/lib/sync.ts`. Changing it means touching all three.
- `loud.playback.v2` — shared playback state (queue/position/devices) over SSE; state machine in `sync-server/internal/server/playback_v2.go`, client in `src/lib/sync.ts`.
- `loud.import.v1` — import manifest for external downloaders, documented in `docs/codec-import-v1.md` with JSON schema at `docs/codec-import.schema.json`.

### Aux (shared listening)

The host starts an aux from Settings (desktop/web) and gets a 4-char code + QR; the join link carries the full server URL. Guests trade the code for a scoped token: they can browse, stream, and drive the shared queue, but never sync/upload/like/playlist (guest-blocked UI is gated by `guestMode` / `.hidden-for-guests`). Ending the aux revokes every guest token. Cross-server tracks ride on `loud.playback.v2` track refs (optional title/artist/media_url/artwork_url) backed by media grants (`POST /api/v1/media-grants`, 24h, scoped to the granted tracks). Server logic in `sync-server/internal/server/aux.go`; client flow in `src/routes/+page.svelte` (`joinAuxAsGuest`, `?aux=` param) + `src/lib/components/AuxModal.svelte`.

### UI conventions (desktop/web)

Read `docs/ui-system.md` before UI work. The current Codec style is not a generic app shell: it is theme-token driven, music-first, and tape-deck influenced.

- Desktop/web styling lives in `src/app.css`; Svelte components do not get `<style>` blocks.
- Use existing theme tokens (`--color-*`, `--button-*`, `--radius-*`) and existing primitives (`.ui-button`, `.title-icon-button`, `.queue-button`, `.app-modal`, `.modal-header`, `.modal-actions`).
- Buttons are raised physical controls: no outlines, fill differs from background, rest/hover/press/latched depth matters. Connected button stacks round only the outside corners.
- The bottom transport is the reference: play is wider and accent-filled; shuffle/repeat/play can latch down; skip/previous are momentary.
- Sidebar and list rows stay quiet. Selection is a muted active fill, not a bright rail. Track rows play on click; do not add play buttons to every row.
- Modals follow one pattern: `.modal-backdrop` > `.app-modal <name>-modal` > `header.modal-header` > scrollable body > `footer.modal-actions`. There is no bare `.modal` class.
- Aux should look like a Codec pass: logo/code/QR/theme/grain, with a high-contrast scan plate. Guests can browse/stream/control playback but cannot mutate library state.

For iOS, mirror the same visual language with SwiftUI and `CodecTheme` tokens (`theme.bg`, `theme.panel`, `theme.surface`, `theme.accent`, `theme.buttonShadow`, etc.). `NowPlayingView.swift`, `Components.swift`, and the Aux pass in `HomeView.swift` are the current references.

### Track identity

Cross-device matching uses a canonical identity chosen in priority order: `fingerprint`, then ISRC, MusicBrainz recording ID, Spotify track ID, YouTube video ID, then normalized title+artist+album (identity strings like `isrc:...`, `spotify:track:...`). Playlists and likes always reference canonical identities. See `docs/codec-import-v1.md`.

### API

The Go server's endpoints are listed in `docs/codec-sync.md` (`/api/v1/library`, `/api/v1/sync/*`, `/api/v1/tracks/{fingerprint}/*`, `/api/v2/playback*`). The server returns `Library` JSON matching the types in `src/lib/types.ts`.

### History note

An earlier Cloudflare Worker backend and its device-key `loud.sync.v3` protocol were removed (recoverable from git history). Cloudflare's only role is DNS/HTTPS/Tunnel in front of the Go server. Do not resurrect the worker.

## Docs to read before touching sync

`docs/codec-sync.md` (server + flows), `docs/secure-sync.md` (auth model), `docs/codec-import-v1.md` (import manifest and identity rules), `docs/modding.md` (where to change things), `DEPLOY.md` (publish path), `docs/device-friends-sharing-plan.md` (future auth/sharing plan).
