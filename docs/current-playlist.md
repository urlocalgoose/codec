# Current playlist on Home

Native and web Home show a compact **Playing from** row above Playlists when
playback has a known source playlist. The row contains its current cover or
album-art mosaic, name and chevron. Tapping it opens that playlist; it does not
change playback or start the playlist again. Paused playback says **Paused from**.
The same row is available on desktop web.

The label follows explicit playback origin, not the page currently open, the
most recently played playlist, or the playlists containing the current song.
Two playlists can contain identical tracks and still have distinct origins.

## Source lifecycle

- Starting a playlist with Play/Shuffle, or starting a different song from it,
  records that playlist's ID. Liked Songs uses its actual library playlist ID.
- Pause/resume, next/previous, repeat, shuffle, manual queue additions, queued
  interludes and device transfer keep the source playlist.
- Existing same-song row taps still toggle pause/resume. They retain the actual
  queue's source, even when that row is on another playlist's page. Use that
  playlist's Play/Shuffle action to explicitly start its collection.
- Starting a new generic collection (for example an album or search results)
  clears playlist origin. Opening/browsing a different collection does not.
- The UI resolves the saved ID against the current library. Renaming or changing
  a cover updates the row. Deleting a playlist, an unknown ID, no current track,
  or absent provenance hides it without leaving an empty placeholder.
- Native offline recovery retains the local origin. Web local session restore
  retains it too. A server switch clears the prior server's origin.

Web shuffle-off also preserves the active source membership rather than
replacing it with songs on the currently visible page. Its deterministic
recently-added ordering matches the existing native unshuffle behavior.

## Sync compatibility

Playback v2 adds optional `context.playlist_id`, a server-local playlist ID.
The server normalizes blank IDs to absent. It retains this field through
transport/queue commands, SSE, persistence and restart. An explicit replacement
context without the field clears previous origin; it must not inherit a stale
playlist ID. Web's saved `loud.playback.v1` session also accepts optional
`playlist_id`. No protocol/schema version bump is required.

Older clients continue to decode and play normally. They do not send playlist
origin, so playback started from an older client may have no indicator. The
updated server and clients are required to exchange the new field; existing
sessions without it acquire an origin on the next explicit playlist start.
The app deliberately avoids guessing a name for those sessions.

See the [playback provenance API contract](codec-sync.md) for wire details.

## Verification

On September 21, 2026:

- Svelte/TypeScript check and 213 frontend tests pass. New tests exercise actual
  page controller functions for explicit source switches, overlapping playlist
  membership, generic-source clearing, Liked Songs, manual queue edits,
  shuffle membership, incoming context, legacy data and saved sessions.
- Release native app build and 155 hosted tests pass (one optional performance
  benchmark skipped); all 28 Swift package tests pass. Tests include offline
  recovery, handoff and metadata-only changes without audio reload/pause/seek.
- Go vet and the full race suite pass, including provenance through commands,
  stale contexts, retries, persistence/restart, SSE and v1 session round trips.
- All eight browser scenarios pass: WebKit/Chromium × Graphite/Paper ×
  mobile/desktop. Seventy-two behavior checks include actual canvas-rendered
  cover colors, SSE changes and real generated audio continuing during playlist
  navigation, with no extra playback command, reload or audio request.
- Linux amd64 and arm64 packages build and pass installer integrity validation.
- The complete quick web/server/contracts check takes 5.13 seconds with local
  compiler/dependency caches warm.

Browser regression command (isolated fixtures, generated audio, no real account):

```sh
bun run build
PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs \
  node scripts/playing-playlist-regression.mjs --build-dir build \
  --browser webkit --themes graphite,paper --viewports 390,1440 \
  --output-dir /tmp/codec-playing-playlist-webkit
```

Repeat with `--browser chromium`; provide `PLAYWRIGHT_BROWSER_PATH` if needed.
Screenshots from these runs and the native simulator use synthetic music and
covers. Simulator tests do not establish physical-phone performance.
