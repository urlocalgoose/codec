# Modding Codec

Start with `docs/ui-system.md` for visual rules. This file is the practical map
for safe app changes.

## Themes

- Svelte themes live in `src/app.css` and are listed in `src/lib/themes.ts`.
- iOS themes are generated into `ios/CodecMobile/App/Themes.generated.swift`.
- Run `bun run gen:ios-themes` after changing theme tokens.
- Do not hardcode component colors. Use theme tokens.

## UI

- Desktop/PWA components live in `src/lib/components`.
- The main app orchestration is `src/routes/+page.svelte`.
- iOS shared view primitives live in `ios/CodecMobile/App/Views/Components.swift`.
- iOS app state lives in `ios/CodecMobile/App/AppModel.swift`.

Rows should play on tap. Transport controls use raised or latched deck-button
states. Guest-mode UI must hide sync, upload, like, and playlist mutation.

## Server/API

- Go server routes live in `sync-server/internal/server/server.go`.
- API handlers live in `handlers.go`, playback in `playback_v2.go`, Aux in
  `aux.go`, auth/request plumbing in `httputil.go` and `auth_tokens.go`.
- Keep `/api/v1` compatible unless you are deliberately creating a new version.

## Rust/Desktop Core

- Tauri command wiring lives in `src-tauri/src/lib.rs`.
- Library scanning/import/state code lives in `src-tauri/src/library`.
- `.loud/state.json`, `loud://` paths, and `loud.*` schemas are compatibility
  protocol names. Do not rename them without a real migration.

## Before Shipping A Change

```bash
bun run check
bun test
cd sync-server && go test ./...
cd ios/CodecMobile && swift test
cargo test --manifest-path src-tauri/Cargo.toml
```
