# Safari and Home Screen viewport — September 23, 2026

Implemented and verified in browser fixtures and the iOS 26.2 simulator.
Physical iPhone verification remains a separate check; simulator results do
not establish physical-device behavior.

## Behavior

The normal shell uses an independently measured CSS viewport: `100dvh` for a
browser tab and `100vh` for an installed Home Screen app. The latter is selected
by either the standalone display-mode query or Safari's `navigator.standalone`.
Controls reserve the home-indicator inset inside that full background, once.

Previously, an undersized `visualViewport.height` shortened the whole shell even
with no keyboard. It could also retain a keyboard offset after focus ended.
The helper now uses VisualViewport height and panning only for a focused text
editor. Pinch zoom keeps the existing layout. A hidden CSS measurement element
and ResizeObserver handle toolbar changes even without a window resize event;
the observer, element, and listeners are cleaned up on unmount.

The document and body must also use `--app-layout-height`, not `height:100%`.
The actual iOS 26.2 installed-web-app simulator reproduced a percentage root
height of 812 pixels while `100vh` and the app shell were 874. With root/body
overflow hidden, this clipped the navigation's 840-pixel bottom at 812. Setting
the root/body to the same CSS layout height restored the full painted area;
innerHeight, VisualViewport, and `100dvh` then reported 874. This was document
clipping, not an inaccessible OS region. Keep the root height independent of
the keyboard's smaller shell height so focused content is not clipped again.

The bottom controls keep their existing pill shapes. A background fade softens
scrolling artwork underneath them and fills the home-indicator area. Scrollable
content reserves the measured control height plus 12 pixels, so the last item
can clear both the player and navigation.

Files: `src/lib/mobile-viewport.ts`, `src/mobile-shell-parity.css`.

## Evidence and limits

WebKit has a report of installed apps exposing a VisualViewport height with safe
areas already removed, while `100vh` covers the full area. This supports avoiding
that measurement as the normal installed shell height; it does not establish
which exact iOS behavior caused the supplied screenshots.
[WebKit issue 254868](https://bugs.webkit.org/show_bug.cgi?id=254868).

The full background and inset controls follow WebKit's documented
`viewport-fit=cover` and safe-area model.
[WebKit safe-area guidance](https://webkit.org/blog/7929/designing-websites-for-iphone-x/).

Verified locally:

- 13 viewport unit/lifecycle tests, including stale height, keyboard dismissal,
  independent CSS resizing, and observer cleanup.
- Eight browser scenarios: Chromium and WebKit, browser and standalone flags,
  Graphite and Paper. Each covers 13 geometry cases with independent CSS and
  visual measurements; no page errors or failed assertions. The root-clipping
  regression fails on the previous local build and passes with matched root
  and shell heights, including during keyboard shrink/panning.
- Home's final tile clears controls by 28 pixels; Library and Search's final
  row by at least 12 pixels. Representative screenshots were inspected.
- The existing WebKit motion fixture passes 50 checks across Graphite and
  Paper, including Now Playing/Queue geometry, safe areas, resizing, gestures,
  focus restoration, and reduced motion.
- Web type checking, frontend tests, and the relevant browser regressions pass.

Actual simulator before/after geometry and screenshots were retained privately.
The fixed candidate was cold-launched in the installed web app; the complete
navigation renders with the intended 34-pixel home-indicator inset. Temporary
geometry instrumentation was removed before final verification.

Real simulator Safari also covers Home, Search, and Library with a 714-pixel
browser viewport and tab bottom at 702, leaving the intended 12 pixels. Those
navigation checks used programmatic button activation; the automated input
focus did not show a software keyboard in this simulator, so keyboard resize
coverage remains the synthetic browser fixture rather than an iOS keyboard
claim. Physical-device verification is still required before release.

Build the frontend, then run with Playwright available:

```sh
bun run build
node scripts/mobile-regression.mjs --build-dir build \
  --viewport-only true --viewports 390 --themes graphite,paper \
  --browser webkit --display-mode standalone
```

Repeat with `--display-mode browser` and `--browser chromium`. The fixture
injects geometry and generates its own media; it does not emulate Safari chrome
or the iOS Home Screen compositor.

For physical-device verification, open an isolated demo server on an iPhone
both in Safari and from
the Home Screen. Check expanded/collapsed browser controls, rotation, Search
keyboard opening/dismissal, Now Playing/Queue sheets, lock/return, and final
items on Home/Library/Search. The background must reach the bottom while
controls remain clear of the home indicator, with no additional blank strip.
Use an isolated test library, not a personal listening server.
