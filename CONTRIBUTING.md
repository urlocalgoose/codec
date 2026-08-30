# Contributing to Codec

Thanks for looking under the hood. The short version: four small codebases,
one contract, and focused test targets for each runtime.

## Setup

Prereqs: [Bun](https://bun.sh), [Rust](https://rustup.rs), [Go](https://go.dev),
and Xcode if you're touching the iOS app.

```bash
bun install
bun run check        # svelte-check + typescript
bun run test         # frontend (bun) + Rust tests
cd sync-server && go test ./...
cd ios/CodecMobile && swift test
```

`scripts/make-demo-library.sh demo-library` generates a small tagged library
so you can exercise everything without personal music.

## Ground rules

- **The wire contract is sacred.** `loud.sync.v1`, `loud.playback.v2`, and
  `loud.import.v1` (plus the `.loud/` state folder and `loud://` roots) keep
  their historical names and shapes; changing one means changing Rust, Go,
  TypeScript, and Swift together, with a migration story.
- **Logic lives where it's testable.** Frontend logic goes in `src/lib/*.ts`,
  not components; iOS API logic goes in `Sources/CodecKit`.
- **The desktop transport is a tape deck on purpose** — the play button
  latches, skips are momentary. Don't modernize it. The iOS app is
  deliberately native-feeling instead; that split is a decision, not drift.
- **Partial updates over row replacement.** Server writes that touch one
  field use dedicated endpoints (see `/tracks/{fingerprint}/liked`) — the
  full-track PUT replaces whole rows and will eat data.
- Match the style around you; comments explain constraints, not narration.

## Docs worth reading first

`docs/codec-sync.md` (server + flows), `docs/secure-sync.md` (auth model),
`docs/codec-import-v1.md` (import manifest + identity rules),
`docs/modding.md` (where to change things), `DEPLOY.md` (publish path), and
`CLAUDE.md` (architecture map).
