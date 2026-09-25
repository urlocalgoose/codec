# Codec App Store materials

The September 22, 2026 kit contains screenshots only, using real native Graphite
screens and the isolated 100-song licensed collection. Submitted build 1.4 (7)
received a user-reported App Review information request on September 24. Native
work resumed that day; the September 25 release request authorizes a new App
Store build. See [the submission reference](../../docs/app-store-submission.md)
and [repository workflow](../../AGENTS.md). The historical kit does not prove
the new candidate was uploaded or satisfy Apple's physical-device recording
request. These tools prepare local files only and do not report live App Store
Connect status.

## Current local artifacts

All generated files are outside the repository in
`~/.codec/app-store/20260922/`:

| Folder | Contents |
| --- | --- |
| `marketing-capture/screenshots` | Seven raw screenshots per device; the capture folder also retains licensed-media credits and verification receipts |
| `screenshots-plain` | Six captioned PNGs per device, editable rendered HTML, contact sheet and source hashes |
| `marketing-kit` | Screenshot gallery, `Codec-App-Store-Kit.zip`, and unpacked delivery files |

The latest full-copy handoff is on the Desktop at
`~/Desktop/Codec-App-Store-2026-09-22/`. It includes a refreshed gallery and ZIP,
all public listing fields in `Copy/App-Store-Copy.txt`, individual paste-ready
text files, a credential-free review-notes template, and the actual 1024px icon.
Older kit folders retain their historical copy. The current listing points to
the published `https://codec.codie.sh/` project site.

The six labels are **Self hosted**, **Now playing**, **Playlists**,
**Offline listening**, **Visualizer** and **Color palettes**. Screenshots are
opaque RGB PNG: iPhone 6.9-inch **1320×2868**, iPad 13-inch **2064×2752**.
See [Apple screenshot requirements](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).

The kit and gallery contain no videos. The retired promo recordings and preview
tools are not part of the current screenshot workflow.

## Edit and render

Edit screenshot labels and captions in `screenshots.json`; mirror those entries
in `listing.en-US.json`. Keep source filenames consistent. Edit listing text in
`listing.en-US.json`; the packager checks Apple's field limits and builds the
readable copy exports. Keep `docs/app-store-listing.md` aligned with the draft.

All native UI stays as captured. Apple permits text and image overlays when
screenshots show the app in use. Never recreate or invent app controls or library
content. [App Review guideline 2.3.3](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata).

Requirements: Node.js with Playwright/Chromium and Python 3.
Set `PLAYWRIGHT_MODULE` to an installed Playwright module path if it is not
available by package name. From the repository root:

```sh
node promo/app-store/render-screenshots.mjs \
  "$HOME/.codec/app-store/20260922/marketing-capture/screenshots" \
  "$HOME/.codec/app-store/20260922/screenshots-plain"

# The output must be fresh; use a staging folder for a rebuild.
python3 promo/app-store/package-assets.py \
  --posters "$HOME/.codec/app-store/20260922/screenshots-plain" \
  --capture "$HOME/.codec/app-store/20260922/marketing-capture" \
  --licensed-bundle /Users/josephcody/Documents/S2Y/deployments/open-license-test-100 \
  --output "$HOME/.codec/app-store/20260922/marketing-kit-next"
```

Review the staging output before replacing the active `marketing-kit` folder.
The package includes captioned images, raw captures, the app icon, full listing
copy, reviewer instructions, credits and SHA-256 checksums. It excludes videos,
private credentials, personal music,
fixture servers and internal capture logs. Validate the ZIP with
`python3 -m zipfile -t`. Serve only the kit directory, never the parent `.codec`
directory:

```sh
python3 -m http.server 9087 --bind 127.0.0.1 \
  --directory "$HOME/.codec/app-store/20260922/marketing-kit"
```

## Re-capture the app

Reuse the verified `marketing-capture/screenshots` for this copy-only revision.
For future captures, start with the isolated native workflow described in
[submission preparation](../../docs/app-store-submission.md#screenshots).
Capture Home, Now Playing, Library, Downloaded, Visualizer and Palettes with the
source filenames in `screenshots.json`. Complete actual downloads before taking
the Downloaded screenshot, and let real playback fill the visualizer.

Use dedicated capture simulators and the licensed 100-song collection. Never
point capture tools at a personal simulator, phone or music server. There is no
recording or video-export step in the current workflow. Capture controls compile
only under `#if DEBUG`; check their absence from any future distribution build.

## Review and publishing

Inspect all 12 screenshots at full size and thumbnail size, confirm source
rights, and check that the gallery and ZIP have no video files, players or links.
Local format validation is not App Review acceptance. Keep the existing App
Store name and SKU. Further uploads or release actions require separate
authorization; this workflow does not change the submitted app.

The separate website at `https://codec.codie.sh/` is built from
[`site/`](../../site/README.md). This workflow changes only the local App Store
kit, not the public website or music servers.
