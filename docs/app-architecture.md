# How the parts of Codec fit together

Codec has **one server and two listening interfaces**: the native iPhone/iPad
app and the web player. The Go server serves both the web UI and the music API
from the same address. The web UI has its own source code, but it does not need
a second production server.

```text
          iPhone/iPad app              Web / PWA
              SwiftUI                   Svelte
                  \                       /
                       your server address
                             |
                HTTPS proxy or private network
                             |
                      Go Codec server
                     /       |        \
             Library data   Audio    Built web UI
              + playback   + covers  (HTML / JS / CSS)
```

The diagram shows an optional network layer. A device on the same network can
connect directly to the Go server’s local address. Public hosting needs HTTPS;
Cloudflare Tunnel and Caddy are supported options, not required app backends.

| Piece | What it does | Code in this repository |
| --- | --- | --- |
| **Go server** | Stores the shared library, playlists, likes, and playback state. Serves audio, cover art, live updates, and the web UI. | `sync-server/` |
| **Web UI / PWA** | Runs in Safari or another browser. Adding it to the Home Screen still uses the web app. Fetches music and sync state from the Go server. | `src/`; generated website in `build/` |
| **Native iPhone/iPad app** | Installed SwiftUI app with native audio playback, downloaded songs, cached library, and cached artwork. Connects to the same Go API. | `ios/CodecMobile/` |
| **Rust library and import CLI** | Reads local music files and Loud manifests, maintains a local import library, and transfers music to or from the server. This is separate from the listening interfaces. | `src-tauri/src/library/`, `src-tauri/src/bin/codec_import.rs`, and `src-tauri/src/sync_transfer.rs` |
| **Hosting / network layer** | Makes the Go server reachable. May be a private network, HTTPS reverse proxy, or Cloudflare Tunnel. It does not store the music library. | Deployment configuration outside the app |

The native app has its **own UI and its own installed version**. Publishing a
new website does not update the native app. Updating the Go server can improve
all clients, provided their shared API remains compatible.

The web PWA caches its interface for offline startup. Explicit web downloads
store audio separately in browser CacheStorage and play through local Blob URLs;
the service worker does not indiscriminately cache API responses or streams.
Browser storage can be evicted and differs from the native app's managed files.
A download in the native app is not a download in Safari: each app has its own
storage. See [mobile continuity and cache](mobile-continuity-and-cache.md).

## What needs to be running?

| What you are doing | What you need |
| --- | --- |
| Streaming an undownloaded song on iPhone | Reachable Go server and a working network path. Any configured tunnel or proxy must also be running. |
| Playing a song already downloaded in the native iPhone app | The downloaded file on that iPhone. Neither the server nor internet access should be needed for the audio. |
| Browsing the native app offline | Its saved library and artwork already cached on that iPhone. New server changes become available after reconnection. |
| Syncing playlists, likes, or playback across devices | Reachable Go server. Offline listening should continue independently of these sync requests. |
| Using the web app to stream | Reachable Go server; it serves both the page and the music. |
| Preparing a local import with the Rust CLI | The CLI, manifest, and referenced local files. Transferring that library to a server also needs a reachable server. |

Downloading first matters: seeing a song in the library does not mean its audio
is stored on the phone. A server outage and a phone without service both prevent
streaming; downloaded playback should work in either case. A phone can have
Wi-Fi while the server or its tunnel is unavailable, so those states need
different status messages and reconnection handling.

## Hosting and updates

The Go server runs independently of the clients and import CLI. It serves the
built web files, API, audio and artwork from one address. The selected data directory
stores SQLite and managed media; keep it outside the application release folder
and include it in backups. Its actual location depends on setup.

The server release bundles the Go executable, built web files, and an
Linux/systemd installer. Its service can run without a signed-in user.
The [hosting guide](https://codec.codie.sh/docs/hosting.html) explains setup;
the [server release guide](server-release.md) covers archive verification,
installation, auth-token retrieval, updates, and persistent storage. Other
setups can run the Go binary with explicit data and web paths.

Building source, installing a server release, publishing new web assets, and
installing a Swift app update are separate operations. Keep their API contracts
compatible. Updating the server or website does not install a new phone binary.
Local design-preview and Vite servers are development tools; playback does not
require them.

## Importing and moving are different

S2Y prepares `loud.import.v1`, audio and artwork. Importers merge those records
into the current server through exact track fingerprints and destination
playlist IDs. Web/mobile web can upload bundles; the Rust CLI can import locally
and merge. The native app consumes the resulting ordinary library API. See the
[import format](codec-import-v1.md). Moving hosting instead copies the complete
current server database/media and retains its identity; it is not another S2Y
import or a new empty library.
