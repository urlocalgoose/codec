# Native performance

The native app avoids repeated work while browsing and keeps audio analysis
away from the UI thread. Performance changes should preserve the layout,
artwork quality, visualizer resolution, and playback behavior. This guide maps
the implementation to its regression tests and explains how to measure changes.

## Performance-sensitive paths

- Library, playlist and search rows share one resolved collection per body
  evaluation. Sorting the full song list or resolving every playlist member
  no longer happens once per visible row. Playlist mosaics stop after finding
  four distinct covers; custom playlist artwork needs no member traversal.
- Library updates reuse indexes, search text, and recent-song ordering when
  their inputs are unchanged. Playlist edits do not require rebuilding track
  metadata collections.
- Artwork originals remain on disk. ImageIO prepares decoded display-size
  bitmaps on the artwork actor before handing them to SwiftUI. A square 48pt
  row at 3× uses a 144px bitmap; full-size requests retain the original pixels.
  Rectangular covers retain enough pixels for a sharp square crop. Concurrent
  requests for different sizes share the original fetch.
- Artwork-derived atmosphere samples have a processed cache. A warm sample
  does not require loading the original image again; failed and cancelled
  requests cannot populate that cache with stale results.
- Artwork cache identity includes URL, authorization scope and display size.
  Existing offline pins migrate once to scoped filenames without losing their
  original bytes. Credentials are never written into filenames or pin indexes.
- Download progress observes individual tracks. Updating one transfer no longer
  invalidates every row or recalculates the downloaded collection. Downloaded
  counts and action availability still update on state transitions.
- Now Playing and the mini-player isolate playback-clock and download-progress
  rendering in small child views, keeping unrelated artwork and controls out of
  those body updates.
- The spectrum FFT runs on one coalesced serial worker. Neither the audio
  callback nor the display callback waits for that worker. The display keeps
  advancing history with the latest completed column.
- The Metal renderer uses a shared pipeline, full-float color lookup, and at
  most two contiguous texture uploads when catching up retained history.
  It pauses when hidden or covered by Now Playing. The history clock pauses
  in the background and continues lightweight sampling during foreground
  browsing. Artwork-derived colors and full screen pixels remain intact.

## Build configuration matters

Use `-configuration Release` for performance measurements. Debug uses Swift
`-Onone` and remains appropriate for interactive debugging and the standard
regression suite. Device testing uses the separate [Codec Test identity](local-test-app.md)
so the listening app's connection, downloads and data stay intact. Native work
resumed on September 24; the current release request authorizes a new App Store
build. Follow [AGENTS.md](../AGENTS.md) and the
[release checklist](release-checklist.md). An upload or simulator result does
not establish physical-device performance or authorize replacing the listening app.

## Regression coverage

`NativePerformanceTests` checks indexed playlist preview semantics and Swift
Observation invalidation across progress, completion, removal and failure.
Artwork tests cover eager off-main decoding, fetch coalescing, exact display
dimensions, auth isolation and offline-pin migration after restart. Spectrum
tests cover blocked analysis, uninterrupted history, silence decay, ring
wraparound, and actual Metal pixels against WebKit output.

`NativePerformanceTests` also checks playlist edit bursts without unnecessary
index, search-text, or sorting work. The 1,888-track edit workload checks that
playlist rename/cover/order changes, membership changes, acknowledgments and
rollback require no extra full index build, regenerated search text or recent
sort. Metadata updates, likes, equal-date ordering, duplicate identifiers and
album-only refreshes retain their own regression cases. These are work counts,
not a frame-rate claim.

`ArtworkAtmosphereTests` verifies processed sample reuse, retry after failure,
and cancellation behavior. A warm cached result must never call its lazy
original-image loader; a cached transparent image is distinct from a failed
request, which remains retryable.

`NativeScrollPerformanceTests` is an opt-in app-hosted workload using 1,888
synthetic songs, 28 playlists, generated covers, a slow local download and
synthetic PCM. It scrolls the actual Library, Songs, playlist and Search views,
and exercises Home and the visualizer. Results and screenshots are XCTest
attachments. Use a dedicated simulator and identical optimization settings
for before/after runs. Simulator cadence is not physical iPhone FPS.

## Measure a change

Follow the [native test guide](../ios/CodecMobile/Tests/README.md) to run the
standard app-hosted suite and enable `NativeScrollPerformanceTests` separately.
The performance workload is deliberately skipped in ordinary test runs.

- Compare identified before/after source builds with the same Release
  optimization, simulator, fixture, and scene sequence.
- Require an active scene and a mounted, unpaused Metal renderer. Inspect the
  exported screenshots; a hidden visualizer makes its CPU result invalid.
- Report main-thread CPU separately from total process CPU. Moving work off
  the main thread may improve responsiveness without reducing total CPU.
- Retain XCTest attachments and record run conditions with measurements.
  Work-count regressions show eliminated repeated work; a short simulator run
  does not establish a general scrolling speedup.

Display-link callback cadence is not presented-frame telemetry or evidence of
physical 120 Hz operation. Simulator results do not establish battery use,
sustained device frame pacing, or audible continuity. Verify those on physical
hardware, using the [playback continuity checklist](native-playback-continuity.md)
and [offline playback checks](native-offline-playback.md) where applicable.
