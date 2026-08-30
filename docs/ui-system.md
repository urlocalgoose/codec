# Codec UI System

This is the source-of-truth guide for making Codec UI match the app that exists
now. It covers the Svelte desktop/web app and the SwiftUI iOS app.

Codec should feel like a quiet, native Apple music app on every platform:
simple flat surfaces, real album art, hairline strokes, low visual noise,
and theme colors carried through every screen. The web app mirrors the iOS
app's native language — not the other way around. (The older tape-deck
"raised key" skin is archived on the `deck-ui` git branch; do not revive it.)

## Core Shape

- Use the current theme tokens. Do not hardcode new colors in components.
- Keep layouts dense but calm: lists, toolbars, sidebars, sheets, and player
  controls. Avoid landing-page or dashboard patterns.
- Prefer fewer labels. A label must name state or an action the user can take.
- Rows play when tapped. Do not add a play button to every track row.
- Artwork is content, not decoration. Show it where it helps identify music.
- Use icons for compact actions. Desktop uses Lucide; iOS uses SF Symbols.
- Avoid outlines on buttons. Buttons are flat fills (accent for primary,
  surface for secondary) or bare tinted glyphs; press feedback is a small
  scale bounce, never 3D depth.

## Desktop / Web

Desktop and PWA UI lives in `src/lib/components/`; global styling lives in
`src/app.css`.

### Tokens

All styling goes through CSS custom properties:

- Color: `--color-bg`, `--color-panel`, `--color-panel-2`,
  `--color-surface`, `--color-text`, `--color-muted`, `--color-subtle`,
  `--color-accent`, `--color-danger`, `--button-bg`, `--button-shadow`
- Shape: `--radius-sm`, `--radius-md`, `--radius-button`
- Motion/depth: `--button-hover-y`, `--button-press-y`,
  `--button-latched-y`, `--button-shadow-rest`,
  `--button-shadow-pressed`, `--button-shadow-latched`

Themes are defined by `data-theme` blocks in `src/app.css` and listed in
`src/lib/themes.ts`. When adding UI, test more than one dark theme and at least
one light theme.

### Buttons

Use the existing classes:

- `.ui-button` for text/action buttons.
- `.ui-button.primary` for the main action in a group.
- `.ui-button.compact` inside modal footers and list toolbars.
- `.title-icon-button` for square icon buttons in headers.
- `.queue-button` for row-level queue actions.

Button behavior, the native way:

- Two filled archetypes: `.ui-button.primary` is an accent fill with
  `--button-primary-text`; plain `.ui-button` is a surface fill. Both are
  12px radius, weight 600, hover lightens the fill.
- Everything else is a bare glyph in a 40px+ hit target: `--color-muted` at
  rest, text on hover, accent when latched/active.
- Press feedback is `transform: scale(0.94)` (bigger controls bounce more),
  never translate-down or inset shadows.
- The deck-era tokens (`--button-shadow-*`, `--icon-inset-shadow*`,
  `--button-*-y`) are defined inert in `:root`; do not build new UI on them.
- Buttons stand apart with gaps; do not fuse them into connected stacks.

### Player

The bottom player is part of the shell's chrome:

- The shell background IS the chrome (`--color-panel`); the sidebar, topbar
  (search), player, and queue rail are transparent panels on it, so they read
  as one continuous ring of chrome wrapping the content. The topbar sits in
  its own shell grid row (a direct child of `.app-shell`, not inside
  `.content`), spanning the middle column like the player.
- The content view is a rounded window inset into that chrome: all four
  corners (24px) are the inverted curves that connect the bars to the rails,
  and a hairline ring (`inset 0 0 0 1px --color-line`) traces the window
  including the curves. The track table sits on `--color-panel-2` so it
  stays a step lighter than the chrome.
- The player sits only in the middle column, between the full-height sidebar
  and full-height queue rail — it never runs under the rails.
- `PlayerBar.svelte` renders three parts on that chrome: now playing,
  transport, and side controls.
- Transport controls are bare glyphs: skip keys in text color, play/pause
  the biggest glyph, shuffle/repeat subtle and tinted accent when latched.
- Progress and volume are native-style sliders: a thin (6px) rounded track,
  solid accent fill up to `--fill`, and a round white thumb.
- The device picker is a native pop-up button: surface fill, small chevrons,
  text color.

### Sidebar

`Sidebar.svelte` is source-list navigation, not a button wall:

- Keep the wordmark small.
- Primary nav and playlists are vertical stacks.
- Selected rows use a quiet active fill, not a bright side rail.
- Playlist counts are secondary.
- Aux code belongs in the footer and opens the Aux QR when hosted.
- Guest mode hides settings and mutation surfaces.

### Track Lists

`TrackList.svelte` owns the table/list pattern:

- The table fills the available width.
- Metadata sits directly above the table, not in a large repeated hero block.
- Header sort chips are clickable labels: Title, Album, Time.
- Play and Shuffle live above song lists except Queue.
- Track rows are clickable and keyboard playable.
- The current track's title reads in accent, and its duration is replaced by a
  three-bar equalizer (`.track-eq`) that animates while playing and freezes
  low when paused.
- Liked and playlist editing are row actions, hidden for Aux guests.

### Grids (Home, Albums, Artists)

Home tiles and the browse grids share one language, taken from the iOS Home:

- Flat two-line tiles: no card box, no raised chrome. The artwork is the tile.
- Artwork is full-width, square (`aspect-ratio: 1`), 14px radius with a
  hairline border; artists use the same tile with a circular portrait.
- Title is small and heavy (`0.92rem/800`), the second line is subtle
  (`0.8rem`); grid rhythm is 14px column gap / 18px row gap.
- Hover lifts the artwork 2px with a soft shadow; single-track tiles reveal a
  round accent play button pinned inside the artwork's corner.
- Artwork placeholders sit on `--color-panel-2` with a subtle glyph scaled to
  roughly a third of the tile.

### Visualizer

The Visualizer view (`VisualizerView.svelte`, nav id `visualizer`) is a
stylized scrolling spectrograph on a canvas filling the content window:
exponential frequency bands, scanline gaps, accent color with text-color
peaks, all read from the live theme tokens. It taps the `<audio>` element
through a lazily-built Web Audio graph (`ensureAnalyser` in `+page.svelte`);
the element carries `crossorigin="anonymous"` and both servers send CORS
headers on media so the analyser never silences playback. It only shows
signal when audio plays on this device.

### Modals

Copy the current app modal structure:

```svelte
<div class="modal-backdrop">
  <div class="app-modal feature-modal" role="dialog" aria-modal="true">
    <header class="modal-header">...</header>
    <div class="feature-body">...</div>
    <footer class="modal-actions">...</footer>
  </div>
</div>
```

Rules:

- Use `.app-modal`, not a bare `.modal`.
- Header has a small kicker, title, optional short description, and a
  `.title-icon-button` close button.
- Footer actions use `.ui-button compact`, with primary action last.
- Keep modal bodies scrollable when content can grow.
- Styling stays in `src/app.css`, not `<style>` blocks.

### Aux

Aux is the Codec equivalent of Jam.

- Host starts Aux from Settings and gets a 4-character code plus QR.
- Guests can browse, stream, register as a playback device, and control the
  shared queue.
- Guests cannot sync, upload, like, or edit playlists.
- The pass is a clean rounded plate carrying the theme through tint alone:
  logo tile, code in large monospace, QR on its own plate. No grain, no
  glint, no ticket chrome — same rule as iOS.
- Keep the QR scan area high contrast even when the surrounding pass is themed.

## iOS

The native app lives in `ios/CodecMobile/App`. It mirrors the desktop language,
but uses native SwiftUI patterns.

### Tokens

Use `CodecTheme` from `DesignTokens.swift`:

- Backgrounds: `theme.bg`, `theme.panel`, `theme.panel2`, `theme.surface`
- Text: `theme.text`, `theme.muted`, `theme.subtle`
- Action: `theme.accent`, `theme.accentText`, `theme.danger`
- Lines and depth: `theme.border`, `theme.line`, `theme.buttonShadow`,
  `theme.glint`

Never introduce raw colors in views unless the platform requires it for
something like QR contrast. Prefer converting theme colors to `UIColor` only at
the edge.

### Native Patterns

- Use `NavigationStack`, `TabView`, `List`, `Form`, `Menu`, `ShareLink`,
  sheets, and alerts where they fit.
- Use `.buttonStyle(.plain)` for icon controls that should disappear into the
  player.
- Use custom deck button styles only for explicit action clusters, like Aux
  Share/Copy.
- Use haptics on important transport state changes.
- Keep SF Symbols consistent in weight and size.

### Player

`NowPlayingView.swift` is the native player reference:

- Artwork is large and breathing: it scales with playback state.
- Transport is clean icon-only control, with shuffle/repeat accented when
  latched.
- Time uses monospaced digits and animated numeric transitions.
- The device picker shows the current playback target.
- Download, route picker, and queue actions stay secondary.

### Lists

`Components.swift` owns shared list primitives:

- `ArtworkView` handles authenticated artwork and caching.
- `TrackRow` is visual only.
- `PlayableTrackRow` wires tap, swipe, context menu, like, queue, and download.
- `CollectionActionHeader` provides Play, Shuffle, Download-all above lists.
- Use transparent list rows and theme line separators.

### Aux

`AuxSessionSheet` in `HomeView.swift` is the native Aux reference — and the
reference for the web too: no grain, no glint, no raised buttons, no ticket
chrome. Both platforms carry the theme through tint and background only.

- Settings and Aux live in a stock `Form` (`.scrollContentBackground(.hidden)`
  + `theme.bg`, rows on `theme.panel`).
- The Aux sheet is a QR on a plain rounded plate, the code in large
  monospaced type, and system `.borderedProminent` / `.bordered` buttons.
- The QR uses the theme's bg/text pair, lighter color as paper, so it stays
  scannable while themed.
- Join Aux is a standard alert with a text field.

## When Adding UI

1. Find the nearest existing component and copy its structure first.
2. Use existing tokens and primitives before adding any new class or SwiftUI
   style.
3. Decide if a button is momentary or latched, then apply the correct pressed
   behavior.
4. Check guest mode if the action mutates library state.
5. Verify desktop/PWA and iOS separately when the surface exists in both.

If a new visual rule is needed, update this file in the same change.
