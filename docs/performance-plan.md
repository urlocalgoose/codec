# Performance verification plan

Preserve the current interface, artwork quality, visualizer output and
installed-client compatibility. Optimize measured repeated work and network
waste before changing rendering quality or infrastructure. Native work resumed
on September 24. Use the separate test identity for device measurements and
preserve the everyday listening app during the authorized release work.

Current behavior is documented in [native performance](native-performance.md),
[web performance](web-performance.md), [data efficiency](data-efficiency.md),
and [deployment validation](deployment-validation.md). Keep measurements and
release receipts outside the repository; a historical pass does not establish
performance for a later build.

## Common measurement rules

Use the same library fixture and Release optimization before and after. Record
cold/warm startup separately; run several samples with the same device, display
rate and power state. Synthetic simulator workloads reveal regressions and CPU
cost; they do not prove physical iPhone FPS, battery life or audible continuity.

Measure main-thread time, slow frames/hitches, process memory, CPU, artwork/API
request counts and bytes, audio-item replacements/seeks, and command/state
latency. Keep private fixtures out of source/releases. Avoid restarting the live
music server during isolated performance work.

## Native pass

The [native implementation](native-performance.md) avoids repeated list/index
work and moves image decoding/FFT work away from the main thread. Regressions
measure the eliminated operations; physical frame pacing still needs an actual
device measurement.

Next checks:

1. Profile actual Library, songs, playlists, Search, Home and the active
   visualizer in the optimized app. Find remaining main-thread work and broad
   Observation invalidations; verify frame delivery rather than callback count.
2. Exercise artwork reuse, download progress, cached/offline browsing and full
   screen transitions while audio plays. Check enter/exit fullscreen, live
   appearance changes and text fallback. Downloaded audio must not stream.
3. Check lock/wake, notifications, Bluetooth/headphone changes, reconnects and
   rapid controls. Ordinary UI/lifecycle refreshes must not reload, pause or
   seek the active item without a playback reason.
4. Run focused regressions for each fix, the app-hosted suite, and identical
   before/after workloads. Use a signed Release [Codec Test build](local-test-app.md)
   for device measurements without replacing the listening app.

Pass criteria: no output/quality regression, no newly redundant audio operation,
bounded memory under repeated navigation, fewer measured stalls or less CPU for
the targeted workload. Physical listening and frame pacing remain separately
reported when a device is unavailable.

## Web / PWA pass

Profile mobile Safari/WebKit and desktop Chromium using
the existing isolated fixture suites. Include an installed PWA viewport.

1. Measure initial load/hydration, tab transitions, large-list scrolling,
   opening/dismissing Now Playing and visible/hidden visualizer CPU.
2. Check decoded artwork reuse and request deduplication. Warm screen changes
   should not redownload unchanged covers or recreate the active audio source.
3. Verify local downloads, no-network startup, server outage versus lost service,
   bounded reconnects, auth refresh, and foreground sync reconciliation.
4. Compare server bytes/requests for cold load, unchanged warm load, navigation,
   playback controls and steady listening. Compression and 304 validation must
   survive the actual reverse proxy. Keep high-frequency sync out of list renders.
5. Test service-worker updates and release changes with open tabs and audio
   playing; avoid blank views or missing old asset chunks during rollout.

Pass criteria: no playback regression, no redundant warm artwork/audio loads,
smaller or unchanged request/byte budgets, bounded memory/CPU, and measured
improvement for targeted interactions. HTTP latency is not audible-start time.

## Hosting and release verification

The Ubuntu pipeline must preserve the existing database/media/identity during
migration. Test TLS, SSE, Range requests, weak ETags, import/export and restore on
the actual host before DNS cutover. Choose instance size from measured CPU,
memory, disk workspace and transfer usage; a move alone is not a performance fix.
See [Ubuntu deployment](ubuntu-deployment.md).
