# Mobile web regression fixture

Build the current frontend, then run the browser checks:

```sh
bun run build
node scripts/mobile-regression.mjs
```

The script imports `playwright` from the test environment and uses its installed
Chromium by default. For a separately installed runtime/browser:

```sh
PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs \
PLAYWRIGHT_BROWSER_PATH=/path/to/chromium \
node scripts/mobile-regression.mjs --output-dir /tmp/codec-mobile-review
```

Both settings also accept `--playwright-module` and `--browser-path` arguments.
Optional `--base-url http://127.0.0.1:5173` tests an already running local frontend;
otherwise the script serves `build/` itself on an available loopback port.
`--build-dir`, `--viewports 320,390,430,1024,1440`, `--themes oxide,paper`, and
`--headed true` and `--browser chromium|webkit` are supported. WebKit uses its Playwright-managed browser and ignores `PLAYWRIGHT_BROWSER_PATH`. Both light and dark themes run by default.

For focused checks, use one of `--interaction-only true`, `--viewport-only true`,
`--download-only true`, or `--profile-only true`. Use `--display-mode standalone` with the
viewport mode to exercise the installed-app contract. Pass `--viewports 390 --themes graphite` for a focused run; the ordinary matrix
remains available for widths/themes.

The interaction mode checks finger-following swipes, vertical direction lock,
cancellation, accessible queue moves, and continuous edge scrolling beyond the
mounted rows. Chromium additionally checks trusted touch pointer capture through
CDP. The viewport mode simulates safe-area changes, keyboard geometry, viewport sizes,
and installation flags; it checks the final row in Songs and Search.
The download mode checks visible response failures, progress inside modal sheets,
cancellation, persisted audio, two-transfer concurrency, and no cache-key rescan
per saved song. WebKit uses an isolated temporary persistent browser profile for
CacheStorage persistence; no user profile is opened.

Profile mode reports mounted rows, DOM changes, artwork requests, interaction
readiness time, and long tasks where the browser exposes them. Compare the same
browser/fixture sequentially; these are host-browser observations, not physical
phone frame rates. On September 22, the published v0.1.6 baseline already kept
2,000-song lists and 1,200-item queues bounded, with no extra artwork requests
when advancing a track. The changes target broken gestures, screen geometry,
stalled requests, and download feedback rather than claiming a list-speed gain
unsupported by those measurements.

All API calls use generated fixtures: 2,000 songs, custom playlist artwork,
a collage playlist, and a revision-checked playback server. Requests to other
origins are blocked. No production credentials, library, or server are used.

Coverage:

- Empty Liked Songs → Songs and empty search → populated results, deeply scrolled.
- Two queue actions while the first is held in flight, verifying successive
  revisions and preserving both edits.
- Home, Search, Library, Visualizer, artwork loading, and mobile Now Playing → Queue.
- Bounded queue rendering and deep scrolling with a 2,000-song source and a
  1,200-song manual queue; correct move/remove indices after virtualization.
- Desktop queue virtualization, no rail mounted at its hidden 1024px breakpoint,
  next-track row reuse without warm artwork requests, repeated manual songs,
  pointer reorder and deeply scrolled keyboard remove/play with global indices.
- Native mobile Library structure, theme-aware toolbar titles, sort menu, and no hidden desktop queue mounted on mobile.
- Tab/Shift+Tab traverse desktop virtual windows and the manual/source boundary;
  duplicate entries and global queue indices remain intact.
- Final-row clearance above floating controls at the end of a 2,000-track list.
- Pointer and repeated-keyboard playlist reordering, song removal, and virtualized Add Songs.
- Actual CacheStorage audio download, Downloaded count/list, removal, and credential-free cache keys.
- Aux guest controls omit owner-only playlist, like, and download actions.
- Screenshots at 320, 390, 430, 1024, and 1440 pixels; browser errors and row counts in
  `report.json`. The process exits unsuccessfully if assertions fail.

The fixture supplies a short generated WAV for download verification and keeps playback paused. It verifies layout, navigation, list rendering, cache operations, and command ordering. It does not measure audio latency or cross-device behavior over a real network.

For audio continuity, `node scripts/web-playback-regression.mjs [build-dir]
[report.json]` runs a separate isolated fixture using a real HTML audio element,
generated WAV, and persistent SSE stream. It checks routine polling, the first
poll after a new revision, context-only updates with decoder lag, and deliberate
remote seeks. It accepts the same `PLAYWRIGHT_MODULE` and
`PLAYWRIGHT_BROWSER_PATH` environment variables. No production API is contacted.
See [the playback investigation](../docs/web-playback-continuity.md).

Current native-parity runs also support `--browser webkit` (install the Playwright WebKit runtime first). On September 21 the matrix passed Chromium at 320/390/430/1440 px and WebKit at 390 px, both Oxide and Paper. Native reference screenshots use 402×874 with explicit 62/34 px safe areas; ordinary browser regression viewports use their actual zero safe areas.

`node scripts/mobile-download-regression.mjs [build-dir] [report.json]` separately tests actual CacheStorage, service-worker upgrades, offline shell/library reopening, streaming-to-download continuity and deleting active downloads. It uses generated audio and local server fixtures only. No live credentials or music are needed.

`node scripts/mobile-motion-regression.mjs --build-dir build` runs a separate
WebKit fixture in Graphite and Paper. It samples real animation frames for Now
Playing, nested Queue, and New Playlist entrance/dismissal, including closing a
sheet before its entrance finishes. It checks keyboard focus restoration,
pointer versus keyboard outlines, reduced motion, and 10 seconds of artwork
animation without replacing the artwork layers. Touch-event cases cover
artwork/title/background dismissal, recent downward flick velocity, snap-back
and cancellation, untouched sliders/buttons, nested Queue isolation, and
ordinary upward or already-scrolled content. The first theme also exercises
the installed-app viewport path with a simulated standalone flag; both themes
use explicit 62/34px safe areas and check sheet/shell bottom coverage on resize. The
fixture generates its own small library and cover image, uses no production
credentials, and accepts the same `PLAYWRIGHT_MODULE`, `--browser`, `--themes`,
`--output-dir`, and `--base-url` options. Frame timings describe the test browser
on the host computer; they are not a physical-iPhone performance measurement.

The gesture cases dispatch TouchEvents because Playwright has no cross-browser
touchscreen swipe API. They validate actual WebKit handlers and rendered state;
physical touch arbitration and the iOS Home Screen compositor still require
an installed-PWA device check. The viewport fixture does not emulate Safari's
OS-level safe-area bugs.
