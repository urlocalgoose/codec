# Web performance

## Queue rendering

`QueueRail.svelte` now uses the existing `VirtualRows` component for the manual
and source sections, at the existing 58-pixel row height. Its position keys reuse
visible slots and support repeated songs; callbacks still receive their global
queue positions. The page mounts the rail only above the same 1140-pixel CSS
breakpoint. The player, artwork resolution, colors, queue order and audio engine
are unchanged. The separate Swift native app is unaffected by this web change.

Keyboard traversal explicitly mounts the next row's small neighborhood before
focusing it. This preserves Tab and Shift+Tab across virtual windows, both
controls in manual queue entries, and the manual/source boundary. A regression
caught focus leaving the list without this handling; it is included in the
retained browser checks.

The isolated regression fixture uses 2,000 generated songs and a remote
playback owner. It verifies zero queue rows below the desktop breakpoint,
bounded visible rows above it, row reuse on the next revision, and no warm
artwork requests or local audio requests while observing remote playback.
These are DOM/request bounds, not an FPS or audible-latency guarantee.

## Artwork, sync and playback

[Mobile continuity and cache](mobile-continuity-and-cache.md) covers shared
artwork requests, cache limits, credential isolation and foreground recovery.
[Playback continuity](web-playback-continuity.md) covers hidden-page audio,
media controls and transport deadlines. [Data efficiency](data-efficiency.md)
describes library compression/revalidation and request reuse.

## Reproduce checks

Build the candidate and use the isolated fixtures described in
[browser regression](../scripts/mobile-regression.md):

```sh
bun run check
bun run test:frontend
bun run build
node scripts/mobile-regression.mjs --browser chromium --viewports 390,1024,1440 --themes graphite,paper
node scripts/mobile-regression.mjs --browser webkit --viewports 390,1024,1440 --themes graphite,paper
node scripts/web-playback-regression.mjs build /tmp/codec-web-playback-report.json
```

Queue cases include keyboard traversal across virtual windows and sections,
deeply scrolled removal/playback, repeated manual entries, pointer reorder and
breakpoint changes. The audio fixture distinguishes routine sync from an
intentional seek and keeps hidden-visualizer sampling separate from audio.
Use the [performance plan](performance-plan.md) for measurements beyond these
regressions. Store dated reports privately rather than treating old test counts
or temporary artifact paths as current results.
