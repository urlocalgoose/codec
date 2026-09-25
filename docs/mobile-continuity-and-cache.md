# Mobile continuity and caching

This reference covers interruption ordering, live sync, artwork reuse and
mobile browser controls. See the dedicated [native continuity guide](native-playback-continuity.md)
and [web continuity guide](web-playback-continuity.md) for transport behavior.

## Native interruption ordering

Audio-session observers already delivered on the main queue were deferring
their handlers through another task. A sync response arriving in that gap
could seek the player before the controller marked it interrupted. The
handlers now run synchronously on the main actor. A regression using real
NotificationCenter delivery failed before this correction and passes after it.

The app-hosted suite uses generated audio and the actual spectrum tap to check
that injected interruptions preserve the player/item without rewind. Physical
lock-button and audible notification behavior require separate device checks.

## Web sync and responsiveness

- Shared playback ownership survives a stale presence heartbeat; observing
  native playback sends no transport commands and requests no local audio.
  A delayed saved-session reply cannot overwrite newer playback state.
- Device discovery runs independently of playback reads. A slow presence
  endpoint cannot delay the current track, timeline, or ownership.
- Returning to the foreground cancels and supersedes a suspended snapshot
  request. Old completions cannot overwrite the new connection's state.
- Health, discovery, playback reads, and stream credentials have an eight-second
  deadline covering headers and response bodies. Library and audio transfers
  retain their own behavior.
- A saved session opened offline retries when the browser regains connectivity.
- Clock samples are anchored when received and retain the best observed
  server offset. A delayed event or deferred command response cannot reset the
  timeline to its transport delay. Track changes clamp against the new song's
  duration.
- A remote or paused visualizer cannot start a competing Web Audio session.
  Transferring playback to native suspends an existing browser audio context;
  transferring back resumes it for actual local playback. Sampling and drawing
  stop while paused, remote, or hidden, retaining history and the canvas.
  Hiding the page leaves the context running when it carries local audio.

## Artwork cache

`artwork-cache.ts` shares session-only blob URLs across lists, queue, Now Playing,
and artwork color extraction. Concurrent consumers coalesce requests. Warm
screen changes reuse images immediately; uncached lazy rows load near the
viewport.

The cache holds up to 96 idle/active entries or 24 MiB of encoded cover data,
evicting idle least-recently-used entries first. Active images are pinned, so
those limits can temporarily be exceeded. Ten-minute revalidation preserves
old URLs until their active consumers release them. Per-image acceptance is
limited to eight MiB. Image decoding remains managed by the browser.

Only Codec artwork access tokens are excluded from identity; server origin,
cover versions, and third-party signatures remain part of the key. Changing
the auth token clears the cache and aborts pending loads. Late replies cannot
restore the old credentials' images. This is not a persistent offline cache.

Library normalization now appends Codec artwork credentials only to known
artwork endpoints on the connected server. External image URLs retain their
own signatures and never receive Codec credentials. The browser fixture
exercises a second origin with CORS disabled as well as token rotation.

## Gestures, viewport, and volume

Now Playing accepts a downward pull from its artwork, title, and background
while scrolled to the top. Buttons, sliders, nested sheets, horizontal gestures,
and scrolling retain their normal behavior. Even a one-pixel downward start
claims the touch before Safari chooses native scrolling; visible dragging
starts after five pixels. Dismissal uses recent velocity, and cancelled drags
snap back.

Installed web apps size the shell and sheet from the layout viewport. Bottom
safe-area padding is applied to controls once; it does not subtract from the
screen background. Browser tabs retain dynamic viewport sizing. Desktop
WebKit fixtures cover injected standalone and safe-area geometry, not the
physical Home Screen compositor.

Mobile and wide web interfaces have no volume slider
or replacement volume row. Browser media gain is one, so an old saved slider
setting or another device's shared volume cannot silently attenuate playback.
Volume is controlled by the device/browser. The native iPhone app uses the system MPVolumeView.

## Retained checks

- `bun run test:frontend`, `bun run check`, `bun run build`
- `scripts/mobile-motion-regression.mjs`
- `scripts/mobile-handoff-regression.mjs`
- `scripts/web-playback-regression.mjs`
- `scripts/mobile-artwork-regression.mjs`
- `scripts/visualizer-artwork-regression.mjs`

Browser regressions run the compiled application against isolated local APIs
and generated media. They do not control production playback. Local timings
are not cellular performance measurements. Web publishing replaces assets,
HTML, and the service worker without restarting the music server.

Browser reports should record the candidate build, request counts, actual
engine/viewport and observed failures. Retained artwork cases verify that warm
navigation reuses covers, credential changes isolate caches, and a versioned
cover replacement fetches only the new content. Gesture, handoff and audio
fixtures cover the behaviors above.

See [native performance](native-performance.md) for measurement guidance and
the limits of simulator results.
