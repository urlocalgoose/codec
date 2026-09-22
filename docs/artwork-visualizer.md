# Artwork-colored visualizer

The web and native visualizers use colors actually present in the song's cover.
They do not snap colors to a preset rainbow, add complementary hues, boost
saturation, or recolor artwork to match the selected theme. Gray covers stay
gray; a cover with one or two distinct colors keeps those colors. Energy still
uses separate color bands, with no gradient between neighboring bands.

## Extracting the colors

Now Playing and the visualizer share one cached 48×48 artwork sample. The
visualizer selects up to four representative source pixels separately from
Now Playing's existing warm/cool/deep averages. Its extraction is the same in
TypeScript (`artwork-spectrum.ts`) and Swift (`ArtworkAtmosphere.swift`):

1. Unpremultiply visible pixels where necessary and round to RGB bytes.
2. Group them into three-bit-per-channel buckets. Within each bucket, choose
   the actual pixel nearest its mean; never use the mean as an invented color.
3. Keep buckets supported by at least two pixels and 0.2% of the visible sample.
   If none qualify, use the available buckets. Consider up to 128 populated
   buckets, ordered deterministically by population then RGB.
4. Start with the most common representative. Choose subsequent colors by
   their distance from the existing selection, stopping at four or when the
   remaining colors are too similar. This retains small real highlights
   rather than repeatedly favoring a large dark background.

The final ink bytes are those sampled pixels. Light/dark themes can reverse
their brightness order but never change their RGB values. Fewer than four
colors repeat across the four energy bands. A single-color cover therefore
shows energy through opacity rather than gaining unrelated colors.

| FFT byte | Band |
| --- | --- |
| 0–63 | First |
| 64–127 | Second |
| 128–203 | Third |
| 204–255 | Fourth |

Values at or below 0.02 remain silent/background. Opacity varies continuously
as `(byte / 255)^0.55`, preserving fine energy detail. The existing canvas
background retains its 16% deep-artwork tint over the selected theme. Rendered
pixels are consequently the actual source ink composited over that background;
low-opacity pixels are not expected to equal opaque cover pixels. Exact ink
fidelity does not imply a minimum contrast ratio for every possible cover.

When artwork is missing, inaccessible, or still loading, only the theme's
existing accent/text colors are used for new columns. New samples stop using
the previous track's palette immediately; already recorded columns keep it.
Late requests cannot replace a newer cover. Native artwork changes
also use the new inks immediately for new samples, avoiding temporary hues from
interpolation between two different covers. Now Playing's animated background
is unchanged.

## Performance and rendering

Extraction runs once per cached artwork, not per frame. The web caches up to
12 samples and prepares its 256-entry color lookup on appearance changes;
the opacity table is shared. Native extraction runs on the existing background
actor and uses a shared opacity lookup in Metal. Both reuse the same loader, identity,
processed image and cache as Now Playing; rotated access tokens do not trigger
repeat web extraction, and changed artwork versions receive a new identity.

Each recorded column keeps its own four artwork inks and background. A song
change, delayed artwork response, or theme change affects only new columns.
The old song's colors continue scrolling left unchanged; they are never
repainted with the new song's palette. If artwork arrives late, the loading
interval keeps its recorded fallback colors and subsequent columns use the art.

The color history belongs to the sampler, so fullscreen resizing, tab changes
and renderer recreation retain mixed-song trails. An appearance observer stays
mounted with playback on both platforms, keeping colors current while browsing
Home or Library. Native rejects stale artwork completions by generation, even
when rapidly switching A → B → A.

Storage is bounded by the existing 1,600-column ring. Web columns share immutable
palette references; native stores five RGBA values per column (80 bytes,
128,000 bytes per full ring) and uploads matching intensity/color rows together.
Old values are overwritten only when their columns leave the retained window.
There is no per-frame artwork processing or unbounded palette log. FFT data,
resolution, scrolling, fullscreen geometry and display cadence remain unchanged.

## Verification

The September 21, 2026 artwork-fidelity correction includes:

- Source-pixel provenance tests for four-color, two-color, single-color,
  grayscale, pastel, dark and textured-minority-accent covers. Bucket averages
  that do not occur in the artwork are explicitly rejected as ink values.
- Tests across all 33 web themes and every native theme: a theme can reorder
  the sampled colors but cannot recolor them.
- Real WebKit/Chromium canvas tests on Graphite and Paper. Expected output is
  independently computed from the supplied source colors, measured background
  and opacity. The former rainbow implementation fails these assertions.
- Checks for delayed/failed/missing artwork, stale responses, shared extraction,
  cached revisits, continuous audio and fullscreen changes.
- Independent native Metal/WebKit pixel comparisons and identity-guard tests.

Run the quick gates, then build once for browser verification:

```sh
bun run check:quick
bun run build
PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs \
  CODEC_TEST_BROWSER=webkit CODEC_TEST_THEME=graphite \
  node scripts/visualizer-artwork-regression.mjs build /tmp/codec-art-fidelity-webkit
```

Repeat with `CODEC_TEST_THEME=paper` and `CODEC_TEST_BROWSER=chromium`; set
`PLAYWRIGHT_BROWSER_PATH` for a non-default Chromium executable. Native tests
are `ArtworkAtmosphereTests` and `WebVisualizerParityTests` in the existing
Codec scheme; see the [native test guide](../ios/CodecMobile/Tests/README.md).
Use a dedicated test simulator. Simulator regressions do not measure physical
phone frame pacing or battery use.

## Artwork-fidelity regression results

- 222 frontend tests pass; the full quick gates complete in 5.34 seconds with
  warm development caches.
- Four browser/theme runs pass all 48 checks; maximum source-color composite
  error is one RGB byte, with no JavaScript errors or artwork-triggered audio
  reload/pause.
- The native pass ran 161 hosted tests (one opt-in benchmark skipped) and all
  28 CodecKit tests. After refining small-accent selection, all 25 focused
  artwork/native-renderer tests pass again; WebKit/Metal error is at most one
  byte per channel.

These results do not claim a new physical-phone performance measurement.

## Color-history verification

The subsequent September 21, 2026 change records appearance alongside each
column. Regression tests exercise red → green → blue song changes, including
each song's background, delayed artwork, ring wrap, fullscreen, renderer
remounting and song changes while browsing Home.

- 227 frontend tests pass. The full quick gates complete in 5.33 seconds with
  warm development caches.
- Chromium and WebKit on Graphite and Paper pass 17 checks each (68 total),
  with no browser errors. The preceding artwork-fidelity build fails the new
  retained-history assertion: it leaves no red columns after changing to green.
- The native Release suite runs 166 tests with zero failures and one optional
  benchmark skipped. It checks actual Metal pixels, backgrounds, ring wrap,
  resize/remount, and RootView/Home recording through rapid A → B → A changes.
  All 13 focused tests pass after the final stale-task cancellation guard.

The browser history fixtures use controlled animation frames to make column
boundaries reproducible; they verify rendering correctness, not frame rate.
