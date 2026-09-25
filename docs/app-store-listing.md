# Codec App Store listing

On September 24, 2026, the user reported a Guideline 2.1 rejection requesting
additional information and a physical-device demonstration recording.
These files retain the listing copy and screenshot references; they are not a
live mirror of App Store Connect. Native work has resumed, and the September 25
release request authorizes a new App Store build; see
[current status](app-store-submission.md#current-status-and-native-release).
Local edits do not change the submitted listing or delivered image kit.

The copy source is [listing.en-US.json](../promo/app-store/listing.en-US.json). Screenshot captions are in [screenshots.json](../promo/app-store/screenshots.json). The package generator validates field lengths and produces individual text files plus `Copy/App-Store-Copy.txt`.

## Listing fields

| Field | Copy | Length |
| --- | --- | --- |
| App name | Keep the name already reserved in App Store Connect | Not yet confirmed locally; do not rename it |
| Subtitle | Self-hosted music player | 24/30 characters |
| Promotional text | Stream music from your own Codec server, download songs for offline listening, and organize playlists with custom artwork. | 122/170 characters |
| Keywords | `offline,library,playlists,visualizer,collection,audio,queue,artwork,streaming` | 77/100 UTF-8 bytes |
| Description | Text below | 1141/4,000 characters |
| Primary category | Music | Suggested selection |
| Marketing URL | https://codec.codie.sh/ | Live project site |
| Support URL | https://codec.codie.sh/support.html | Live support page |
| Privacy policy URL | https://codec.codie.sh/privacy.html | Live policy |
| What's New | Leave blank for the first App Store release | Not offered for a first release |

Codec is the brand. “Codec” alone was unavailable as an App Store name, so keep the user's existing reserved name and SKU. Native app version and server release version are separate; do not use the website's server release number as the app's version.

The linked project, support and privacy pages returned HTTP 200 on September 22, 2026. The site is `codec.codie.sh`; the personal music server is not a marketing destination.

Public support and private requests use **codie@codie.sh**. Verify the policy,
support contact and review-server access again before a future submission.

## Production privacy model

The user confirmed that production is self-host-only: users choose servers they
operate, and the developer collects no production user data. The native Release
app has no default developer backend, analytics/crash-reporting SDK or hidden
telemetry endpoint. **Data Not Collected** is the supported App Store answer for
this model. Build 7 removes the earlier collected-data entries while retaining
required-reason API and no-tracking declarations.

The isolated Apple review server is supplied only for review/testing; it is not
a built-in/default service or a managed-hosting offering. Its operator can access
and retain review device state, playback requests, content and logs. Keep this
exception explicit in the policy/reviewer notes rather than promising that no
network data is ever sent or stored. Managed hosting is future-only and requires
a fresh privacy/disclosure review before it is offered to users. See the
[source audit and retention details](app-store-submission.md#verified-privacy-behavior-and-policy-source-facts).

## Description

```text
Codec is a music player for iPhone and iPad that connects to a Codec server you host.

Stream your music collection or download songs to listen offline. Browse playlists, search your library, and manage what plays next.

Features
• Playlists with custom cover images
• Library search and liked songs
• Queue controls, shuffle, and repeat
• Offline playback of downloaded songs
• Background playback and Lock Screen controls
• Now Playing backgrounds that use album artwork
• A live visualizer with colors from the playing song’s artwork
• 33 light and dark color palettes
• Playback transfer between connected devices
• Pass the Aux sessions, so friends can browse and add songs to the queue

Your Codec server also includes a web player for accessing the same library in a browser.

Setup
Codec requires a Codec server and your own music files. Host the server on a computer or cloud server, add your music through its web interface, then connect the app with your server address and auth token. Music and a hosted catalog are not included.

Setup guide: https://codec.codie.sh/docs/hosting.html
Support: https://codec.codie.sh/support.html
```

## Screenshot upload order

Use the numbered PNGs in `Screenshots/`, in this order for each device. The images use actual app captures in Graphite with the isolated 100-song licensed collection. This collection is for demonstration and is not bundled with the app.

| Order | Headline | Caption |
| --- | --- | --- |
| 1 | Self hosted | Connect to your own Codec server. |
| 2 | Now playing | Playback controls and album artwork. |
| 3 | Playlists | Browse playlists with custom covers. |
| 4 | Offline listening | Download songs to listen offline. |
| 5 | Visualizer | Live audio visualization with artwork colors. |
| 6 | Color palettes | Choose a light or dark palette. |

| App Store Connect slot | Files | Dimensions |
| --- | --- | --- |
| iPhone 6.9-inch | `Screenshots/iphone-6.9/01…06.png` | 1320 × 2868 px |
| iPad 13-inch | `Screenshots/ipad-13/01…06.png` | 2064 × 2752 px |

There are six opaque RGB PNGs per device, plus the unframed raw captures as alternatives. Upload one set, not both. The overview image is for inspecting the set, not an App Store screenshot. The 1024px app icon is included for reference; the App Store icon comes from the app build. No video previews are included.

The screenshot sources are `~/.codec/app-store/20260922/screenshots-plain` and `marketing-capture/screenshots`. The latest complete copy-and-image handoff is `~/Desktop/Codec-App-Store-2026-09-22/Codec-App-Store-Kit.zip`. Earlier local marketing kits are historical copies and may contain older listing text.

Captures preserve real app UI. In the simulator, Now Playing displays speaker icons without the system volume-slider track; it has not been painted into the screenshot. Native source hashes and capture receipts are retained with the working assets. The package includes source credits and checksums; it excludes personal music, credentials, fixture servers and internal capture logs.

## Review notes and remaining account fields

A credential-free [App Review notes template](../promo/app-store/review-notes.template.txt) is included in `Copy/`. It explains the server URL/auth-token connection and how to test streaming, downloaded songs, the visualizer, palettes and playback transfer. Fill in the dedicated review-only token in App Store Connect's private fields. Do not use a personal-library token or put review credentials in the public description.

These account details must come from the owner or existing App Store Connect record, not invented copy:

- The reserved app name and existing SKU.
- Copyright owner and year, and actual review contact name, email and phone.
- Price, territories, release timing, age-rating questionnaire, privacy answers, content rights and export compliance for the selected build.
- Verify the public support page includes the owner's confirmed address, **codie@codie.sh**; App Review's private contact name and phone remain separate account fields.

The package does not select or upload a build, alter privacy declarations, or submit for review. Check the dedicated review server's authenticated audio and artwork access immediately before submission and keep it available throughout review.

## Apple references

Requirements checked September 22, 2026:

- [Product page guidance](https://developer.apple.com/app-store/product-page/) — app name and subtitle, screenshots and plain feature descriptions.
- [Platform version fields](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information/) — field limits, support contact, private review notes and first-release What's New behavior.
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/) — the accepted iPhone and iPad dimensions above.
- [Accurate metadata, guideline 2.3.3](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata) — screenshots show the app in use; text and image overlays are allowed.

Format validation does not constitute App Review approval. See [submission preparation](app-store-submission.md) for the separate account workflow and [packaging instructions](../promo/app-store/README.md) to reproduce the local kit.
