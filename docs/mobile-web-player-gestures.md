# Mobile web player gestures and viewport

Now Playing accepts a downward pull from its artwork, song text, empty space,
or grabber. The first downward touch movement is cancelled before Safari can
claim it for scrolling; visible dragging begins after 5px. A short pull snaps
back, a sufficiently long or fast downward pull dismisses, and cancellation or
a second finger resets the sheet. Release clicks cannot accidentally dismiss
a sheet that has just snapped back.

Buttons, links, inputs, device selection, editable content, and explicit
`data-sheet-no-drag` regions keep their own interactions. Upward/horizontal
movement and gestures beginning in scrolled content remain native scrolling.
The nested Queue does not drag its parent player. Touch listeners are removed
when each sheet unmounts.

The regular browser layout uses `100dvh`; standalone mode uses `100vh`.
An independent CSS layout probe sizes the document root and shell so stale
WebKit percentage heights cannot clip the bottom controls. VisualViewport
shrinks the shell only while an editable control has focus; pinch zoom retains
the layout. Safe-area padding is applied inside the sheet once. The login form
retains document scrolling. See [the viewport contract](mobile-web-viewport.md)
for implementation and regression details.

## Verification

```sh
PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs \
  node scripts/mobile-motion-regression.mjs --build-dir build
```

The fixture exercises the gestures, modal motion/focus, reduced motion, and
viewport resizing in WebKit with Graphite and Paper. It supplies explicit
62/34px safe areas and a standalone flag for its installed-app layout scenario.
TouchEvents reach the real WebKit handlers, but are dispatched by the fixture;
the test does not emulate physical iOS gesture arbitration or the Home Screen
compositor. Both still need checking on an actual installed iPhone web app.

References: [WebKit safe-area guidance](https://webkit.org/blog/7929/designing-websites-for-iphone-x/),
[Safari touch event handling](https://developer.apple.com/library/archive/documentation/AppleApplications/Reference/SafariWebContent/HandlingEvents/HandlingEvents.html),
and [WebKit installed viewport issue](https://bugs.webkit.org/show_bug.cgi?id=254868).
