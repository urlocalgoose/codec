# Codec UI System

This is the source-of-truth guide for making Codec UI match the app that exists
now. It covers the Svelte desktop/web app and the SwiftUI iOS app.

Codec should feel like a quiet music app with tape-deck hardware instincts:
simple surfaces, real album art, raised physical controls, low visual noise,
and theme colors carried through every screen.

## Core Shape

- Use the current theme tokens. Do not hardcode new colors in components.
- Keep layouts dense but calm: lists, toolbars, sidebars, sheets, and player
  controls. Avoid landing-page or dashboard patterns.
- Prefer fewer labels. A label must name state or an action the user can take.
- Rows play when tapped. Do not add a play button to every track row.
- Artwork is content, not decoration. Show it where it helps identify music.
- Use icons for compact actions. Desktop uses Lucide; iOS uses SF Symbols.
- Avoid outlines on buttons. Buttons are raised by fill, shadow, and press
  depth, not borders.

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

Raised button behavior is part of the identity:

- Resting buttons use `--button-shadow-rest`.
- Hover moves down slightly, usually `--button-hover-y`.
- Active press moves to `--button-press-y`.
- Latched buttons, like play while playing, shuffle, repeat, or selected
  controls, stay down at `--button-latched-y`.
- Icons use `--icon-inset-shadow` or `--icon-inset-shadow-primary`.

Buttons next to each other should usually connect into one stack, especially
transport controls. The outside corners round; internal edges are square with
only a quiet separator.

### Player

The bottom player is the strongest visual pattern:

- `PlayerBar.svelte` renders a three-part footer: now playing, transport,
  and side controls.
- `.transport-buttons` is a connected button stack.
- The play button is wider and accent-filled.
- Shuffle/repeat latch visually when active.
- The progress and volume controls should feel like hardware slots, not
  generic form controls. The slot shows an accent band up to the current
  position (`--fill`), with a raised key for the thumb.
- The device picker is a recessed accent readout (like the aux chip), not a
  raised key: it tells you where sound goes; it is not a transport control.

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
- The QR should feel like a Codec pass: logo, code, QR, theme colors, and
  restrained grain/glint. Avoid a naked QR in a generic white box.
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

`AuxSessionSheet` in `HomeView.swift` is the native Aux reference. iOS does
NOT get the desktop pass treatment - no grain, no glint, no deck-raised
buttons, no ticket chrome. The deck/pass aesthetic is desktop/web identity;
iOS carries the theme through tint and background only.

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
