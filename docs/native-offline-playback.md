# Native connection and offline playback

The native iPhone app now treats downloaded audio as the playback source even
when the server is reachable. A lost connection suspends synchronization rather
than stopping local playback. The connection screen also uses the existing
Codec logo, theme colors, compact inputs, and an **Auth token** label without
the misleading “optional” qualifier.

## Audio and downloads

- A readable, nonempty local audio file takes priority over its remote URL,
  including a remote item prepared before that download finished. Downloaded
  playback does not request a streaming token or load remote audio.
- Offline play, pause, seek, next, repeat, and playback-queue edits work
  locally. Automatic advancement skips songs that are not downloaded. Tapping
  an unavailable song explains what is missing and preserves the current song
  and queue.
- Audio is kept in Application Support, with its original bytes. Files are
  excluded from backup and use protection that permits access while locked
  **after the first device unlock**. Missing, empty, or nonregular files cannot
  remain usable downloads through stale metadata.
- Download completions validate HTTP status and content type; an HTML error
  page is not accepted as audio. Cancelled and replaced transfers cannot
  restore old files through late callbacks. Existing background transfers are
  reattached after relaunch; transient failures retry with delays capped at
  60 seconds and resume data when available.
- Downloaded songs' cover art is pinned separately from the disposable image
  cache. Original image bytes survive cache pruning; removing one song does
  not delete artwork still pinned by another. Cover requests are limited to
  four at a time and failures retry after connection recovery.

“No remote audio” does not mean “no network traffic.” While online, Codec
continues to sync playback, library changes, and device presence. It may also
fetch missing artwork or complete downloads the user requested. Offline
library edits such as likes and playlist changes do not have a durable upload
queue.

## Connection handling

| Evidence | Status and response |
| --- | --- |
| No usable network path | Show **No network connection**, retain the library, and suspend sync and retry timers. Background downloads wait for connectivity. |
| DNS failure or timeout with a network path | Show **Can’t reach your server**. Wi-Fi alone cannot prove whether the server, tunnel, router, or internet failed. |
| HTTP 5xx | Show **Server temporarily unavailable** and retry. |
| HTTP 401/403 | Show **Check your auth token**. Stop automatic retries until the user addresses the credentials. |
| TLS/certificate failure or invalid address | Show the relevant correction prompt; do not bypass certificate checks or retry indefinitely. |

Server recovery uses one loop with delays of **2, 4, 8, 15, then 30 seconds**,
capped at 30 seconds between attempts. Restoring a network path triggers an
immediate validation. Obsolete library requests are cancelled and detached,
preserving the decoded library and ETag; a late response cannot replace the
new request or its cache. Library, health, and playback-control requests have
a 12-second timeout; audio streaming and background downloads have separate
policies.

Manual server changes, explicit disconnect, and Aux changes invalidate older
work. A failed replacement connection keeps retrying the selected replacement,
rather than silently returning to the previous server. Authentication failures
remain blocked across network loss and restoration.

## Reconnecting during music

If the server still matches the known playback owner and revision, Codec
publishes the latest local position and queue while keeping the same player
and item: no recovery-induced pause, seek, or song restart. An offline pause
stays paused, and reconnection does not play through an iOS interruption.

If another device changed the shared session, local listening and its queue
remain intact instead of overwriting that device. A conflict is retained for
an explicit playback-device choice. When there were no local edits, legitimate
remote transport changes still apply after recovery.

## Test coverage and physical checks

The app-hosted tests cover offline playback, connection recovery, download and
artwork handling, sync, continuity, lifecycle, and playlist recency. The Swift
package tests include late success and failure after library cancellation.
See the [native test guide](../ios/CodecMobile/Tests/README.md) for commands and
the distinction between package and app-hosted tests.

The native tests use isolated files, simulated network conditions, instrumented
players, and a generated WAV for the real playback smoke test. They verify
local asset selection and request counts; they do not measure audible gaps on
physical iPhone hardware.

For physical verification, play a downloaded song through airplane mode,
Wi-Fi/cellular transitions, server outages, lock/wake, notifications, and
reconnection. Also check an interrupted download across those transitions and
a real background relaunch. Record the tested build and device; installation
alone does not verify these behaviors or battery use.

See [the architecture map](app-architecture.md) for the distinction between
the native app, web PWA, import tooling and server, and
[the continuity checklist](native-playback-continuity.md) for audio-route and
interruption checks.
