# Modding Codec

Start with the [UI system](ui-system.md) for visual rules. This file maps the
source for reading or adapting Codec. We’re not accepting contributions or
pull requests right now; the source is available under the [MIT license](../LICENSE).

## Themes

- Svelte themes live in `src/app.css` and are listed in `src/lib/themes.ts`.
- Mobile layout and interaction styles live in `src/mobile*.css`.
- iOS themes are generated into `ios/CodecMobile/App/Themes.generated.swift`.
- Run `bun run gen:ios-themes` after changing theme tokens.
- Do not hardcode component colors. Use theme tokens.

## UI

- Web/PWA components live in `src/lib/components`.
- The main app orchestration is `src/routes/+page.svelte`.
- iOS shared view primitives live in `ios/CodecMobile/App/Views/Components.swift`.
- iOS app state lives in `ios/CodecMobile/App/AppModel.swift`.

Rows should play on tap. Transport controls use flat glyphs with theme tint for
active states and scale feedback when pressed. Guest-mode UI hides sync, upload,
like and playlist mutations; the server must enforce those restrictions too.

## Server/API

- Go server routes live in `sync-server/internal/server/server.go`.
- API handlers live in `handlers.go`, playback in `playback_v2.go`, Aux in
  `aux.go`, auth/request plumbing in `httputil.go` and `auth_tokens.go`.
- Keep `/api/v1` compatible unless you are deliberately creating a new version.

## Rust library and import CLI

- Library scanning/import/state code lives in `src-tauri/src/library`.
- The command-line importer is `src-tauri/src/bin/codec_import.rs`; server
  transfers live in `src-tauri/src/sync_transfer.rs`.
- These shared tools retain their existing `src-tauri/` paths. The
  [Loud format guide](codec-import-v1.md#how-to-import) explains CLI use.
- `.loud/state.json`, `loud://` paths, and `loud.*` schemas are compatibility
  protocol names. Do not rename them without a real migration.

## Checking changes

Run each command from the repository root:

```bash
bun run check
bun run test:frontend
bun run test:server
bun run test:rust
(cd ios/CodecMobile && swift test)
```

`swift test` covers CodecKit models and the API client. SwiftUI, playback, and
rendering use app-hosted Xcode tests; see the [native test guide](../ios/CodecMobile/Tests/README.md).
The [fast-check guide](fast-checks.md) describes the combined web, server, and
schema checks. Running these checks does not deploy a server or update an app.
