# App Store submission reference

## Current status and native release

On September 24, 2026, the user reported a rejection under Guideline 2.1,
Information Needed — New App Submission. Apple requests a physical-device
recording and written details covering purpose, setup/access, external services,
regions, and content rights in both the review reply and App Review Notes.
This is user-reported status, not a new live App Store Connect check.
The supplied message does not identify a specific crash or broken feature.
Existing simulator captures do not satisfy the physical-device recording request.
The user resumed local native work on September 24 for the connection-screen
explanation and Aux v2. The September 25 release request authorizes coordinated
server/web release and a new App Store build. Follow the verification and
release process in [AGENTS.md](../AGENTS.md) and the
[release checklist](release-checklist.md). Keep the everyday listening app and
its data intact; replacing it on the user's phone remains a later step.
Authorization and local build results do not establish a completed upload,
submission, approval, public release, or physical-device recording.

The previously uploaded and submitted native build was **1.4 (7)**, bundle identifier
`sh.codie.codec.mobile`. It corrects the privacy manifest for the confirmed
self-host-only production app while retaining required-reason API declarations.
Archive/export/upload receipts remain in the private App Store working files.
The current native candidate adds connection guidance, Aux v2, Keychain-backed
credentials and connection-scoped library caches. It must use a new build
number; these changes are absent from submitted build 7. Record the resulting
archive and upload receipts privately. Confirm the selected build and current
status in App Store Connect before submission or release; upload, submission,
approval and public release are separate events.

Graphite is the shipping default, including a fresh connection screen.
Preserve an existing user's saved palette. Release builds must exclude capture
switches, fixture credentials and DEBUG screenshot navigation.

## Verified privacy behavior and policy source facts

The user confirmed that the production app connects only to user-run servers;
the developer does not collect production users' data. The Release app has no
default developer backend, telemetry service or integrated collection SDK.
API and Aux requests use the selected server; audio and artwork use that server's
supplied URLs, which can include another participant's media host. Privacy and
Support are user-tapped external links, not automatic telemetry destinations.
Network synchronization with an independent user-run server is not, by itself,
developer collection under Apple's definition. Do not claim that Codec never
sends data: the following information is exchanged with or stored for the
user-selected server.

| Data | Purpose and implementation evidence |
| --- | --- |
| Persistent random installation UUID and device name | Playback device presence and transfer; `PlayerController.publishPresence`, `sync-server/internal/server/store_playback.go`. This is an app-generated identifier, not IDFA. |
| Current track, queue, history, playback position/state, transport commands, likes | Playback synchronization and library functionality; `PlayerController`, `sync-server/internal/server/playback_v2.go`, persisted playback state/command responses. |
| Playlist names and membership | User-created library content; `AppModel`, `CodecClient`, server library storage. |
| Chosen playlist cover images | Explicit system PhotosPicker selection → `AppModel.setPlaylistCover` → `CodecClient.setPlaylistArtwork`; image uploaded to the selected server. No broad photo-library access. |
| Connection address/token, preferences, cached library, audio and artwork | Kept locally for connection, display and offline playback. In the local candidate, owner and Aux tokens use bundle-scoped Keychain entries; legacy preference tokens migrate. Downloaded media uses the app's Application Support directory. Submitted build 1.4 (7) predates this change. |

No advertising SDK, analytics SDK, IDFA, ATT tracking, location, contacts, camera,
or microphone capture was found in the native app. It has no third-party package
dependencies. Background audio is for playback; local network permission is for
user-selected LAN servers. The OS photo picker grants only selected-image access.

For the confirmed production model, the App Store privacy answer is **Data Not
Collected**. Build 7's manifest has an empty `NSPrivacyCollectedDataTypes` array,
`NSPrivacyTracking=false`, and no tracking domains. The earlier four categories
in builds 5 and 6 were based on a developer-operated hosting assumption that does
not describe the production offering. Required-reason APIs still need their
declarations regardless of whether the developer collects data.

The isolated Apple review fixture is an exception to who operates the server:
the developer can access its test device state, playback requests, content and
logs. It is not a built-in/default backend or a public managed-hosting product.
Describe this review-only handling accurately in the policy and reviewer notes;
do not promise that fixture interactions are never retained. Possible managed
hosting is future-only. Before offering it to users, reassess data collection,
logging/retention, the public policy, App Store answers and the bundled manifest.

Retention: the server's two-minute presence cutoff filters its query results; it
does **not** delete stored device rows. Playback command responses are retained
in SQLite. Do not promise automatic deletion or a fixed retention period absent
an implemented policy. Disconnecting does not delete a server library. Deleting
an iOS installation removes its app container; server data is controlled by the
server operator. Users can remove their playlists/covers through library controls;
for developer-operated review-fixture removal requests, use **codie@codie.sh**,
the public support and private-contact address. Do not put auth tokens, private music names, or private screenshots in
public support issues.

Required API reasons:

| Category | Reason | Use |
| --- | --- | --- |
| UserDefaults | CA92.1 | App-only settings, connection details, playlist recency, generated device UUID. |
| File timestamps | C617.1 | Metadata for artwork cache pruning and downloaded files within the app container. |
| System boot time | 35F9.1 | Elapsed spectrum timing via CACurrentMediaTime; no timing sent for fingerprinting. |

The timestamp wrapper derives from `mach_absolute_time`; including its elapsed
time reason is deliberate. No disk-space or active-keyboard API use was found.
[Apple API reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype),
[data types](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype),
[collection definition](https://developer.apple.com/app-store/app-privacy-details/).

Submitted build 1.4 (7) stores its server tokens in UserDefaults. The current
candidate stores personal and Aux credentials in separate bundle-scoped
Keychain entries, available after first unlock on that device. Legacy preference
tokens are removed after successful migration to Keychain. Preferences and
non-secret connection details still use UserDefaults, so that API declaration
remains necessary. This source change does not update an already submitted or
installed binary; verify migration and persistence in the new native build.
The broad ATS exception preserves user-configured HTTP servers. Review notes
should explain that HTTPS is supported/recommended and users can connect to
their own HTTP-only music server; the isolated public review fixture uses HTTPS.
[Apple ATS guidance](https://developer.apple.com/documentation/security/preventing-insecure-network-connections).

## Screenshots

Use only `/Users/josephcody/Documents/S2Y/deployments/open-license-test-100`.
It contains 100 CC0 recordings and replacement museum covers with documented
source rights. Preserve its `CREDITS.md`, `licenses/manifest.json`, and verification
reports with the submission working files. No personal music library is used.

`scripts/capture-app-store-screenshots.py` imports that bundle into an empty local
library/server, creates separate iPhone 17 Pro Max and iPad Pro 13-inch simulators,
starts actual licensed playback, and captures the real Home, Library, Search,
Now Playing and Visualizer views. The server is stopped at the end. No physical
phone is installed, erased, or reconfigured. The app harness only routes to actual
views; the final screenshots must be visually reviewed for OS banners/loading.

Required sets are 6.9-inch iPhone (1320×2868) and 13-inch iPad (2064×2752), opaque
PNG/JPEG, one to ten screenshots per set. Current captures use full native pixels,
not resized desktop/web screenshots. [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).

Example build/capture (fresh output directory required):

```sh
xcodebuild -project ios/CodecMobile/Codec.xcodeproj -scheme Codec \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/codec-app-store-screenshots \
  CODE_SIGNING_ALLOWED=NO build

go -C sync-server build -o /tmp/codec-app-store-sync ./cmd/codec-sync-server

python3 scripts/capture-app-store-screenshots.py \
  --bundle /Users/josephcody/Documents/S2Y/deployments/open-license-test-100 \
  --app /tmp/codec-app-store-screenshots/Build/Products/Debug-iphonesimulator/Codec.app \
  --server /tmp/codec-app-store-sync \
  --output /tmp/codec-store-capture
```

## Screenshot kit and listing copy

Use the [editable listing reference](app-store-listing.md) and
[reproduction and packaging guide](../promo/app-store/README.md). The kit contains
six screenshots each for iPhone and iPad, raw native captures, listing copy,
credits and validation records. It excludes video previews. Labels are
**Self hosted**, **Now playing**, **Playlists**, **Offline listening**,
**Visualizer** and **Color palettes**.

Screenshot generation and packaging are local operations. They do not change
App Store Connect, and later local copy edits do not update an already submitted
listing. Validate dimensions, opacity, captions and actual app content before
an authorized replacement. Keep private libraries and credentials out of images.

## App Review connection and reviewer steps

Codec connects to a user-selected server. It does not bundle a music catalog,
sell tracks or require another app to use the review fixture. The review server
is **https://codec-review.codie.sh**, containing the separate licensed 100-song
collection. Its service, data and token are isolated from listening libraries;
see [separate review-service maintenance](ubuntu-deployment.md#maintain-the-separate-review-service).

Keep the review-only token in private App Store Connect sign-in/review fields,
never in source or screenshots. Provide **codie@codie.sh** as the support contact
and keep review access available throughout review. The fixture is not a
built-in/default backend; its operator can retain test interactions as described
in the privacy section above.

Reviewer steps:

1. On Welcome, choose **I have a server**. Paste the review server address and
   review-only token, then **Connect**. A saved connection skips Welcome.
2. Open Library → a playlist, and play a song. Open the mini player for transport,
   queue, repeat/shuffle, output transfer and download controls.
3. Open Visualizer while this device is playing. Expand it with the corner button.
4. Download a track; open Library → Downloaded to exercise offline playback.
5. For the new candidate, use Start Aux, choose a listening mode and songs to share.
   Open its invitation on a second updated app or browser. Verify guest controls
   and host removal. This step requires the matching Aux v2 review-server update;
   confirm the deployed review-server version and selected App Store build
   before describing this flow as available to the reviewer. Build 7 does not
   support Aux v2.

Before recording or resubmitting, build and physically test the candidate, update
the review fixture only in an authorized release, and revise reviewer notes to
explain private invitation-based listening and optional selected-song sharing.
Simulator captures are design/QA evidence, not Apple's requested physical-device
recording.

All supplied review recordings are CC0 and cover images are public-domain/CC0
Open Access images from The Met. They are replacement collection covers and
do not imply endorsement by the musicians or museum. Attach/share the credits
and source manifest if App Review requests proof of rights.

## Future update checklist

- Confirm the current app record, selected build, review status and user-approved
  release mode. Keep the bundle ID and SKU; increment the build number for a
  changed binary rather than reuploading an old one.
- Verify the actual Release artifact: signing, iPhone/iPad support, background
  audio, privacy resources, Graphite fallback, policy/support links and absence
  of DEBUG fixtures or credentials.
- Run the required native checks and installed-client compatibility gates in an
  isolated environment. Do not replace the listening app for routine testing.
- Check listing copy, screenshot content, contact details and review-server
  access. Any future managed-hosting offering needs a new privacy assessment.
- Revisit Apple's current privacy, age-rating, content-rights, export and
  territory/account requirements for the actual app and offering before an
  authorized submission. The saved App Store answers and bundled manifest are
  separate records.

For current platform requirements, consult [App Store Connect help](https://developer.apple.com/help/app-store-connect/)
and [App Review guidelines](https://developer.apple.com/app-store/review/guidelines/).
