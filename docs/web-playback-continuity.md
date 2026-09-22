# Web playback continuity

Routine synchronization must preserve an already-playing audio source. Stream-token renewal and context-only snapshots must not reload or seek the song; explicit remote seeks must still work.


## Cause and correction

`refreshPlaybackDevices` intentionally reevaluates playback once per revision
after loading the devices list, to detect a departed playback owner. When SSE
or a command response has already applied that revision, its first subsequent
poll still forces a same-revision reapplication. Later identical polls skip it.

The earlier token helper minted another stream token every time a track URL
was resolved. The full URL comparison then treated that token change as a new
song and called `audio.load()`. This clears the current media pipeline and can
fetch the whole song again. Queue/shuffle updates triggered the same path.

The current implementation caches/coalesces stream credentials and compares
audio identity without the credential query parameter. Token renewal does not
replace an already-loaded audio source.

A second issue affected routine reconciliation: even with a stable source,
routine snapshots sought to the server clock whenever local audio lagged by
more than 0.75 seconds. Decoder startup or buffering can create that difference
without any user asking to seek. The correction compares successive server
clock trajectories at the same instant. Context-only updates and same-revision
reconciliation preserve ongoing audio; an actual remote seek still applies.
Already-playing audio also avoids redundant `play()` calls.

## Browser reproduction

The probe serves the actual compiled web application against an isolated local
API, generated PCM WAV, persistent SSE stream, and changing fixture stream
tokens. It instruments real Chromium media calls/events. It does not contact
production APIs, use real credentials, or change anyone's playback.

| Scenario | Earlier implementation | Corrected implementation |
| --- | --- | --- |
| Three already-evaluated same-revision polls | No reload or seek | No reload or seek |
| Queue/shuffle-only revision with two seconds of local playback lag | Reload, seek, emptied, waiting | No reload, seek, emptied, or waiting |
| First poll after that new revision | Reload, seek, emptied, waiting | No reload, seek, emptied, or waiting |
| Deliberate remote seek to 45 seconds | Reloads source as well as seeking | One seek; retains source |

The corrected fixture uses one audio request and one stream-token
request throughout. The old fixture ends with ten media requests and eight
token requests, including browser range requests. These synthetic request
counts demonstrate redundant work; they are not a billing estimate.

Run the retained check after building, using the same optional Playwright
environment variables documented in [mobile regression](../scripts/mobile-regression.md):

```sh
bun run build
node scripts/web-playback-regression.mjs build /tmp/codec-web-playback-report.json
```

The probe asserts uninterrupted benign updates and a working intentional seek.
The source controller regressions independently verify a forced snapshot no
longer jumps 17 to 20 seconds, and a context-only clock rebase no longer jumps
27 to 30 seconds.

## Server transport

Audio uses Go `http.ServeContent`; database lookups finish before streaming,
JSON compression excludes audio/ranges/SSE, and no periodic server write
deadline is configured. Stream-token expiry is checked when a request starts;
it does not stop an already-authorized response.

## Cross-device protection

An independent native review found a conditional ownership race: if the web
app took over during a phone interruption before the phone received that
update, an automatic phone pause/resume could reclaim shared playback.
Local transport writes now carry a revision guard, and queued system actions
cannot undo an acknowledged transfer. Explicit remote controls and transfers
still work. Five tests cover the ownership protection.

Validation: 91 frontend tests, zero type-check errors/warnings, 68 targeted
native tests, 26 Swift package tests, Go race tests, and Rust tests passed.
Physical listening and notification behavior remain separate device checks.

## Headphone and system media controls — September 22, 2026

The web audio element handled a headphone pause locally, but its pause/play
listeners never sent the corresponding shared playback command. Other clients
kept showing the previous state, and reconciliation could restart the audio.

The web controller now registers explicit MediaSession play/pause actions and
publishes real external audio events as revision-guarded commands for the local
speaker, using the element's actual position. Repeated actions are idempotent.
App-generated media events are counted and consumed after their asynchronous
delivery, preventing feedback from UI commands or remote reconciliation. Source
loads discard those expectations along with the old browser media tasks;
natural track endings and media errors retain their existing handlers.

System controls cannot claim another device's session, including during an
outgoing transfer before its acknowledgment arrives. Real hardware events remain
accepted while a local play promise is buffering. The browser releases its
MediaSession metadata/state when playback belongs to another device.

Validation: all 235 frontend tests and type checking passed in 4.78 seconds.
The new `scripts/web-media-controls-regression.mjs` reproduces the old bug in
both Chromium and WebKit, then passes ten scenarios per engine with the fix:
external pause/resume, repeated commands, registered MediaSession callbacks,
rapid pause/play with a delayed acknowledgment, remote updates, source changes,
pending/settled transfers, stale events, and natural track completion. It uses
generated audio and two isolated browser clients connected by real SSE. Existing
playback continuity tests also pass without routine reloads or seeks. These
checks exercise real media events and registered system callbacks; they do not
press a physical Bluetooth headphone button.
