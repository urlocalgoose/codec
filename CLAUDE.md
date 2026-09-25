# Working on Codec

Follow [AGENTS.md](AGENTS.md) for local testing, release authorization, native
review holds, and installed-client compatibility. This file maps the source;
it does not override those rules.

## Product and commands

Codec is a self-hosted Go music server with a Svelte web/PWA player and a
separate SwiftUI iPhone/iPad app. The server serves the web player and API from
one address. Desktop GUI distribution is paused. The shared library and import
CLI in `src-tauri/` remain supported tooling; keep their tests.

Bun is the package manager and frontend test runner:

```sh
bun install --frozen-lockfile
bun run local:up                 # Two isolated demo servers and site preview
bun run local:check              # Local candidate checks
bun run local:stop               # Stop the lab, retain its data
bun run dev                      # Vite UI development
bun run build                    # Static web player in build/
bun run check:quick              # Parallel web, Go and contract checks
bun run test:frontend
bun run test:server
bun run test:rust
(cd ios/CodecMobile && swift test)  # CodecKit models/client, not app-hosted tests
```

`server:dev`, `server`, and `dev:mobile` are aliases for the isolated local lab.
See [local development](docs/local-development.md) and the
[native test guide](ios/CodecMobile/Tests/README.md) for the separate app-hosted
suite. Do not use listening servers or personal libraries as test fixtures.

## Source map

- `src/routes/+page.svelte`: web orchestration and playback. Components live in
  `src/lib/components/`; reusable logic and its tests live in `src/lib/`.
- `src/app.css`: shared web styles and theme definitions. `src/mobile*.css`
  contains the mobile layout, player, library and gesture styles.
  `src/lib/themes.ts` lists palettes.
- `sync-server/internal/server/`: Go routing, SQLite library state, media,
  playback commands and SSE, imports and Aux. `playback_v2.go` owns the shared
  playback state machine; `aux_v2.go` owns scoped sessions; `aux_transfer.go` owns selected-track sharing
  and durable saves. `aux_sessions.go` retires unsafe legacy guest access.
- `ios/CodecMobile/`: SwiftUI app and CodecKit API models/client. App-hosted
  playback/rendering tests are separate from the Swift package tests.
- `src-tauri/src/library/`: local import library, scanning, identity, artwork,
  likes and playlists. `src-tauri/src/bin/codec_import.rs` is the CLI;
  `sync_transfer.rs` transfers libraries. Existing bridge/desktop code is not
  a current distribution target.
- `site/`: static project website, documentation and release metadata. The site
  is `codec.codie.sh`; listening servers are not project/marketing destinations.
- `deploy/ubuntu/` and `scripts/build-server-release.py`: verified server/web
  packaging, persistent data isolation, install/update/rollback tooling.

## Contracts and identity

"Codec" is the product name. Keep `loud.*` wire schemas, `.loud/` local state
and `loud://` identifiers compatible; renaming requires a migration. Use
`CODEC_*` / `codec.*` for new configuration while preserving supported legacy
aliases.

- `loud.sync.v1`: Rust, Go, web and native library/snapshot contract.
- `loud.playback.v2`: shared queue, playback position, devices and SSE state.
- `loud.import.v1`: external import manifest; see
  [the format reference](docs/codec-import-v1.md) and its JSON Schema.

Server merge matches exact fingerprints, preserves existing records, unions
likes and appends missing playlist members. Identity derivation for records
without a fingerprint belongs to the importer; do not fuzzy-merge distinct
supplied fingerprints. Playlists and likes reference canonical tracks rather
than copied audio. Repeated entries of one track within a playlist collapse.

## UI and playback

[The UI system](docs/ui-system.md) is the visual reference. Preserve the current
native appearance: flat themed controls, restrained borders, compact lists and
artwork. Do not restore the older raised tape-deck button styling.

Use existing tokens and components, keep styles in the shared CSS files, and
verify both light and dark palettes. Browser focus must remain visible for
keyboard users. Match mobile layouts and gestures while respecting browser and
native platform limitations. Artwork visualizer colors come from the song's
image; new colors apply to new history columns, never recolor old ones.

Keep ordinary library refreshes, navigation and presence checks separate from
audio ownership and intentional transport commands. Downloads take precedence
over streaming. See [web continuity](docs/web-playback-continuity.md),
[native continuity](docs/native-playback-continuity.md), and
[offline playback](docs/native-offline-playback.md).

## Auth and Aux

The server accepts configured owner authentication and restricted media tokens;
`/health` and the static web shell remain public. Review
[the actual security model](docs/secure-sync.md) before changing credentials or
permissions. UI hiding is not an authorization boundary.

Aux v2 is implemented locally in the server, web player and native app. It uses
separate guest credentials, explicitly shared catalogs, Shared speaker and Listen
together modes, and an independent timeline. Guests cannot access owner playback,
libraries, playlists, likes, history or device registries. See the [wire contract](docs/aux-v2-protocol.md)
and [selected-track transfer contract](docs/aux-transfer-protocol.md).
The [historical review](docs/aux-security-review.md) explains the retired v1 risks.
Old Aux invitations deliberately return update-required; ordinary owner APIs stay
compatible. Coordinate updated server/web/native deployment before advertising Aux.

## Reference

Start with [the docs index](docs/README.md). Before changing sync/imports, read
[the API](docs/codec-sync.md), [security](docs/secure-sync.md),
[import format](docs/codec-import-v1.md), and
[installed-client compatibility](docs/client-compatibility.md).
