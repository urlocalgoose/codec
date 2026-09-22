# Native regression tests

Run API/model tests on macOS from `ios/CodecMobile`:

```sh
swift test
```

Run the actual app/controller, audio spectrum, and WebKit/Metal parity tests
with the checked-in `Codec` scheme. Choose an installed iPhone simulator from
`xcrun simctl list devices available`, for example:

Use a dedicated test simulator, not the simulator used for normal listening.
App-hosted tests can change the host's saved connection and cached library even
though XCTest startup keeps its production server connection idle.

```sh
xcodebuild -project Codec.xcodeproj -scheme Codec \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath /tmp/codec-native-tests \
  test CODE_SIGNING_ALLOWED=NO
```

`NativeSyncTests` exercises the real `PlayerController` and `AppModel` against
an in-memory transport, including rapid queue edits, another device changing
the queue, failed command dependencies, and recovery after a foreground
network failure. XCTest startup leaves the app's saved server connection idle.
No production account, physical phone, or running sync server is required.

`PlaybackContinuityTests` drives the real controller with an instrumented
AVPlayer and an isolated transport. It checks unnecessary seeks/session
activations, delayed command acknowledgements, interruption resume intent,
device ownership, stale callbacks, and immediate local next/repeat behavior.
`NativeLifecycleTests` covers notification/overlay transitions, foreground
refresh coalescing, offline recovery, and mutation refreshes.
`PlaybackEngineSmokeTests` decodes a generated local silent WAV with a real
AVPlayer and spectrum tap, then verifies playback progress across injected
route events and unchanged snapshots without rebuilding the player/item.

`OfflinePlaybackTests` (in `PlaybackContinuityTests.swift`) exercises local-file
selection, zero offline control/streaming requests, skipping unavailable songs,
local controls, and recovery without replacing/seeking/pausing the player. It
also checks ownership/revision conflicts, commands during recovery, interrupted
resume intent, and stale server snapshots after an unacknowledged local play.
`ConnectionRecoveryTests` covers no-path versus server/auth/TLS failures,
bounded retries, immediate path restoration, manual server replacement,
disconnect cancellation, and first-connect outages.
`DownloadStoreTests` uses isolated directories and a controlled URL protocol
to cover file validity, original bytes, duplicate requests, stale completion
callbacks, retry after outages, pinned artwork, and cache pruning.
`PlaylistRecencyTests` checks explicit playlist identity, server-scoped history,
and recording remote plays only after acknowledgement. Its offline playback
fixture uses a valid local WAV.

The macOS `LibraryRefreshTests` also covers explicit cancellation of a stalled
library request. A transport that ignores cancellation delivers late successes
and failures; neither may clear a replacement request or overwrite its ETag.

`AudioSpectrumRegression` also holds the display snapshot lock while invoking
the audio callback: audio must return without waiting, leave the PCM untouched,
and recover spectrum sampling on the next callback.

The spectrum tests cover FFT scaling, stereo downmix, retained history,
display sampling, and native-rendered pixels compared with WebKit canvas.
Simulator display cadence is a regression check, not a measurement of
physical-device battery use or sustained frame pacing.

`NativePerformanceTests` verifies that download progress invalidates only its
own row, collection counts change only when membership changes, and indexed
playlist artwork previews preserve order and respond to library refreshes.
The artwork regressions also check eager off-main decoding, shared original
requests across display sizes, auth-scoped caches and legacy offline pins.
The follow-up tests verify a 1,888-track playlist edit burst without rebuilding
indexes, lowercasing unchanged search text or re-sorting recent songs, while
keeping metadata and Observation correct. `ArtworkAtmosphereTests` also verifies
that a warm processed sample needs no original image load, failed loads remain
retryable and cancellation cannot cache stale colors.

`NativeScrollPerformanceTests` is deliberately skipped in ordinary runs. It
hosts the actual Library, Songs, playlist, Search, Home and visualizer with
1,888 synthetic tracks, 28 playlists, local artwork, active spectrum analysis
and a slow download. For a comparison, build with `-configuration Release
ENABLE_TESTABILITY=YES SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG`, then set
`CODEC_RUN_SCROLL_PERFORMANCE=1`, `CODEC_PERF_LABEL=before` (or `after`), and
`CODEC_SCREENSHOT_SEARCH=Song` in the generated xctestrun target's
`EnvironmentVariables`. Run that file with `test-without-building
-only-testing:CodecNativeTests/NativeScrollPerformanceTests`. Preserve its
`__TESTROOT__` paths if copying it elsewhere. Results and screenshots are
XCTest attachments. The harness explicitly sets an active scene and verifies
the mounted Metal view is unpaused; a hidden renderer is not a valid comparison.

Use normal Release builds for everyday phone installs. The `DEBUG` compilation
condition above only makes the existing screenshot query hook available in the
test fixture; it is not needed in the phone build. See
[`docs/native-performance.md`](../../../docs/native-performance.md).

For physical-device checks, see
[`docs/native-playback-continuity.md`](../../../docs/native-playback-continuity.md)
and [`docs/native-offline-playback.md`](../../../docs/native-offline-playback.md).
These describe listening and recovery checks that require physical hardware;
package and simulator tests do not establish those outcomes.
