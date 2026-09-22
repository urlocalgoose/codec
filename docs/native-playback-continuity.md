# Native playback continuity

The native playback controller preserves ongoing audio through routine sync,
scene changes, and notifications while respecting actual iOS interruptions.
This guide describes the safeguards, regression tests, and physical-device
checks. See [offline playback](native-offline-playback.md) for connection
recovery and downloaded audio.

## Changes

| Area | Finding | Change |
| --- | --- | --- |
| Audio callback | The visualizer acquired a blocking lock also held by the display thread. A preempted display thread could hold up audio. | The tap tries the lock once and skips only that visual snapshot under contention. It never changes playback PCM. Work is bounded to the newest 2,048 frames. |
| Scene lifecycle | Every transition to active refreshed the library and reconciled playback, including notification/overlay returns and initial connection. | Refresh only after an actual background visit, coalesce foreground tasks, and reuse a library fetched within 15 seconds. Mutation/event refreshes still force a fresh fetch. |
| Sync snapshots | Every newer state could hard-seek to a server clock and reconfigure/reactivate the audio session. Queue/repeat/shuffle changes rebase that clock without requesting a seek. | Compare clock trajectories at a common server instant. Preserve ongoing audio for context-only changes and acknowledged local commands; apply real remote seeks and ownership changes. |
| Interruptions | Any loaded track could resume after an interruption, even if already paused or owned by another device. Temporary pauses also generated shared pause/play echoes. | Remember local playback intent, defer engine changes while interrupted, honor pause/route loss/ownership, and synchronize the final resumed position. |
| Old callbacks | A queued progress callback from a replaced player could mark the new track paused. | Require current-player identity and keep progress callbacks out of shared pause decisions. Natural-end callbacks also verify current playback intent. |
| Track changes | Automatic next/repeat waited for the sync server response. | Advance/repeat locally, then send the resulting command. Final-track Next pauses the actual engine. |
| Lock screen | Full Now Playing dictionaries were rewritten four times a second. | Publish transport changes and rate/duration changes; the system advances elapsed time itself. |

The Now Playing behavior follows Apple's
[elapsed-time documentation](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfopropertyelapsedplaybacktime).
Interruption and headphone-disconnect behavior follows
[handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
and [responding to route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes).

## Verification scope

Controller tests inject transport and AVPlayer instrumentation so unintended
play/pause/seek/session activation calls are observable. They simulate
interruption and route notifications; they do not simulate iPhone audio
hardware or a real incoming call. Run the app-hosted suite with the commands in
the [native test guide](../ios/CodecMobile/Tests/README.md).

The spectrum tests verify lock contention, untouched audio samples, recovery,
FFT scaling, stereo downmix, retained history, and native/WebKit rendering
parity. Source changes preserve the existing visualizer design and app layout.

The real AVPlayer smoke test decodes a generated local WAV through the spectrum
tap and checks playback progress across injected route and snapshot events
while retaining the same player and item. Native/WebKit tests compare rendered
pixels. These are continuity and rendering regressions, not physical
audio-underrun or sustained frame-pacing measurements.

Preparing the next AVPlayerItem is not a guarantee that it has buffered audio.
This change removes server-round-trip delay at track boundaries; it does not
claim sample-accurate gapless playback or eliminate genuine network starvation.

## Physical-device follow-up

Use a Release build on a physical iPhone, with a downloaded track first and
then a streamed track. Repeat with the speaker and headphones.

- Play with the screen locked for at least a minute, wake the screen several
  times, and unlock. Listen for a gap or repeated/skipped phrase.
- Receive ordinary notification banners and open/close Notification Center
  and Control Center. Playback should continue unless iOS actually interrupts
  the audio session.
- Start and end a real audio interruption. A previously playing song should
  resume when the system permits it. A previously paused song must stay paused.
- Disconnect headphones during playback and during an interruption. Playback
  should pause and must not unexpectedly resume through the speaker.
- Edit the queue/repeat mode from the web app while the phone plays. Those
  changes must not seek. A deliberate web seek or playback transfer must work.
- Test natural next/repeat with a slow connection, then a brief network outage.
  Record any actual buffering separately from a transport pause or seek.

Record the tested build and device when performing these checks. A successful
build or installation alone does not establish physical wake/notification
continuity, sustained battery use, or audio-underrun behavior.
