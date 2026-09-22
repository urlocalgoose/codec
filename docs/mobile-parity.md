# Current native / mobile web parity

The current SwiftUI app on iOS 26.2 is the reference. This pass changes the web client at widths up to 980 px; it does not redesign or reinstall native iOS. The desktop shell remains separate.

## Screens and behavior

- Home uses the compact Codec header with Aux, palette and settings controls. Playlist order follows locally recorded recent playback for the selected server. Artwork cards, typography and spacing match the native dimensions.
- Search and Library retain their fixed headers. Search starts empty; a failed query reports no results. Library has compact playlist rows with 44 px covers, a creation button, and Liked Songs / Songs / Downloaded only.
- Floating glass tabs and the 56 px mini player use real browser safe areas. Scroll padding is derived from their combined height so the final row clears the controls, including browser viewports with no bottom safe area.
- Songs and playlist views use large collection titles, 86 px rows with 48 px covers, native toolbar actions, Play / Shuffle / Download controls, and touch context actions. Playlist membership, adding songs, cover upload, reorder and removal use the existing server APIs. Creating a playlist uses a compact centered prompt.
- Now Playing keeps its cover sharp. Its artwork-derived halo, color wash and immersive background fade through the native 24-second cycle. Artwork sampling and blur are cached; the animation changes opacity. Reduced motion uses a static halo. Hidden or covered players pause the animation.
- Queue has native grouped sections, Edit / Clear controls, swipe removal and reorder handles. Keyboard reordering follows the moved row. Large lists, Add Songs and queues render only visible rows plus overscan.
- Settings uses the native grouped server, Aux and reconnect sections. Palettes shows the actual 22 dark / 11 light previews. Aux uses the native QR layout and styled symbol, with copy/share controls. Connect uses the actual Codec logo and server/token fields, with no optional-token claim.

## Browser downloads and continuity

`web-downloads.ts` stores validated complete audio responses in a server-scoped CacheStorage namespace. Cache keys contain neither auth tokens nor signed media URLs. Playback checks the saved audio before requesting a streaming token, and repeated reads reuse a stable Blob URL. Already-playing media remains stable when a download finishes or is removed. Worker upgrades delete only obsolete app-shell caches and preserve saved music.

The browser regression exercises actual CacheStorage and a service-worker replacement. Offline reopening loads the cached shell and library, then plays downloaded audio without token or media requests. Browsers own their storage retention and may evict it; this is not the native background-download subsystem. AirPlay appears only when the browser exposes its real picker. Native system glass, OS status bars, keyboard and routing panels are platform UI, so their rendering is not claimed to be identical.

## Validation and review

Run from the repository root:

```sh
bun run check
bun run test:frontend
bun run build
node scripts/mobile-regression.mjs --build-dir build
node scripts/mobile-regression.mjs --build-dir build --browser webkit --viewports 390
node scripts/web-playback-regression.mjs build
node scripts/mobile-download-regression.mjs build
```

Supply `PLAYWRIGHT_MODULE` and (for Chromium) `PLAYWRIGHT_BROWSER_PATH` when using an externally installed Playwright runtime. See `scripts/mobile-regression.md` for fixture details. Tests isolate all library, credentials, audio and API traffic from the live server.

Native/web comparisons use Oxide and Paper with the same four-track fixture and native UIKit frame measurements. The common capture viewport is 402 × 874 with top62/bottom34 safe areas. The web capture harness reserves those areas without drawing fake OS chrome.

The frontend checks cover cached downloads, sync/token reuse, library lookup/order and playback continuation. The browser suite covers 2,000-song lists, 1,200-entry queues, empty-list transitions, final-row clearance, playlist and queue pointer/keyboard edits, real downloads, guest restrictions and desktop preservation. The audio continuity regression checks benign polling/context changes versus intentional remote seeks.

September 21 verification: **119 frontend tests passed**, with zero Svelte/TypeScript diagnostics and a successful production build. The full layout/interaction matrix passed in Chromium at 320/390/430/1440 px in Oxide and Paper (8 scenarios), and WebKit at 390 px in both palettes. Final 390 px replays cover the published controller changes. The isolated audio/download suites verify uninterrupted polling, deliberate seeks, worker updates preserving downloads, and offline Blob playback. An independent Vision QR reader decoded both palette variants of the Aux screenshot.

Final review also fixed credential changes during downloads, serialized order and membership writes, discarded library reads from before a playlist edit, and prevented retrying a failed first-song add from creating duplicate playlists. These race cases are covered by controller regressions.
