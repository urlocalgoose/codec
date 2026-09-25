# Aux security review and proposed contract

Status: historical findings and design decisions from September 23, 2026.
On September 24 the user authorized implementation in server, web and native.
The replacement implementation is documented in [Aux v2](aux-v2-protocol.md) and
[selected-track sharing](aux-transfer-protocol.md). Release status belongs in
the candidate's private readiness record, not this historical audit.
The findings below describe the retired v1 code, not the new local runtime.
Line references identify the code inspected during that review. Testing used only
isolated fixtures and local demo servers, never listening or App Review servers.

## What the reviewed v1 server permitted

A guest receives a separate session credential, **not the owner's credential**.
That distinction is real at the API boundary: guest attempts to change likes,
create playlists, perform snapshot sync, export the library, create another Aux
session, mint stream tokens, or mint media grants receive `403`. See
`sync-server/internal/server/httputil.go:374` and
`sync-server/internal/server/aux_sessions.go:94`.

However, the guest's allowed surface is much broader than a queue invitation:

| Confirmed behavior | Evidence | Impact |
| --- | --- | --- |
| Every playback v2 command is allowed, including `transfer`, `pause`, `seek`, `next`, `previous`, `volume`, `set_shuffle`, `set_repeat`, and full `set_queue` replacement. | `aux_sessions.go:103`; `handlers.go:561`; `playback_v2.go:176` | A guest can take playback away from the host, change host volume, or clear the queue. Requested shared pause/resume/skip must be permitted through a scoped session operation, not this unrestricted command surface. This supports the reported failure mechanism; it does not prove which command occurred on the real devices. |
| `GET /api/v1/library` returns the same full collection as an owner request; every track's audio GET is allowed. | `aux_sessions.go:99`; `library_response.go:123`; `store_library.go:17`; `types.go:47` | Guest access reveals unqueued songs, private playlist names/memberships, likes, and stored source metadata. Hiding these controls in the UI would not protect the API. |
| Guests can list device IDs/names/playback and PUT any device ID, including the host's ID. | `aux_sessions.go:105`; `handlers.go:441`; `store_playback.go:54` | A guest can overwrite another device's presence/name/status. Client-supplied IDs are not bound to a guest identity. |
| The invitation contains a four-character code, with 31 possible characters: 923,521 possibilities (about 19.8 bits). The application has no join rate limiter. | `aux_sessions.go:21`, `:29`, `:163`; complete middleware chain at `server.go:143` | Online guessing is not adequately bounded by the application. A proxy's unverified external controls cannot be relied on as the security boundary. |
| Codes and guest tokens have no expiry. `created_at` is stored but not checked. Every join returns the same token. | `aux_sessions.go:44`, `:55`, `:82`, `:163`; `server.go:246` | There is no individual guest removal, per-guest accountability, or automatic end. The invite and token survive restart and owner-token rotation until the session is deleted. |
| Guest-supplied `media_url` and `artwork_url` are trimmed but otherwise accepted into shared playback. | `playback_v2.go:409`; `types.go:141` | Untrusted URLs enter the host playback graph. No server-side fetch occurred in the reproduction; client-side fetching, scheme/origin validation, redirect handling, and credential attachment require a separate client review. |
| Playlist-artwork GET and track-audio HEAD are denied to guests although track GET and full-library browse are allowed. | `aux_sessions.go:94`; `server.go:109` | The scope is inconsistent and can break images or clients which probe media with HEAD. This is not a reason to grant all routes. |

The first five rows are design/security blockers for the next Aux release. The
current server boundary prevents library mutations; it does not provide the
session-only privacy and playback ownership users reasonably expect.

## Why the browser can look fully signed in

The web client stores the joined guest token in the same persistent credential
slot used for an ordinary server connection. `joinAuxAsGuest` assigns it to
`syncTokenDraft` and calls `loadRemoteLibrary`; that calls `saveSyncServerUrl`,
which writes `codec.syncToken` and the server address. By contrast, `guestMode`
and `auxCode` exist only in page memory and reset on a fresh load. A normal
reload without the invitation query can therefore retain a valid guest token
while showing the owner-style interface. Owner-only API writes still fail;
this is a lost UI role plus excessive guest read access, not proof that the
owner token was disclosed. See `src/routes/+page.svelte:236`, `:534`, `:818`,
`:1131`, and `:2953`.

This was reproduced in a fresh WebKit profile against a temporary Aux session
on local test server A. Immediately after joining, the stored credential
matched the guest token and did not match the owner token; **Leave Aux** was
visible and **Import music** was hidden. Navigating to the plain root URL and
reloading kept that same guest token but removed **Leave Aux** and exposed
**Import music** and **Start Aux**. The temporary session was revoked afterward.
The role-loss reproduction did not require or demonstrate an owner-token leak.

The app handoff also uses a 1.5-second timer and checks `document.hidden` only
when that timer finishes (`src/routes/+page.svelte:2957`). It does not record a
successful handoff or cancel the browser join permanently. If Safari suspends
that timer while the app is open and resumes it after Safari becomes visible,
the browser can run its join fallback on return. That timing is a code-supported
explanation requiring a physical iOS reproduction; it is not an observed trace
of the user's original incident.

The resulting new design must preserve the saved personal connection, persist
and revalidate the participant role separately, and show an explicit choice of
browser versus a supported app. It must not infer a failed app launch from a
timer or silently establish a second browser session on return.

The reviewed v1 native client persisted its guest role and saved/restored the previous
server and token on join/leave (`ios/CodecMobile/App/AppModel.swift:595`, `:659`).
Joining itself does not send a playback-transfer command. That is separate
from the confirmed server permission which allows a later guest command to
take over output. At the time of this review, owner/guest credentials lived in
UserDefaults (`:32`, `:54`), and guest and personal libraries shared one
`library.json` cache (`:648`, `:1109`). The current candidate addresses these
findings with separate bundle-scoped Keychain entries and personal library
caches scoped by server and principal; see [credential storage](local-test-app.md).
Submitted build 1.4 (7) predates those changes. These are source findings, not
evidence of a live credential disclosure or native cache leak in the incident.

## Protections that are already present

- The guest bearer token is generated from 24 cryptographically random bytes.
  Its strength does not compensate for an indefinitely valid, guessable join
  code which retrieves it.
- Ending an Aux session deletes its token. New guest API requests then receive
  `401`; active playback event streams close when authorization changes.
  `aux_sessions.go:63`, `httputil.go:402`, `handlers.go:623`.
- Cross-server media grants are limited to listed track fingerprints and expire
  after 24 hours. They cannot change library or playback data.
  `aux_sessions.go:190`.
- The application request logger omits query strings, Authorization headers,
  and request bodies. The example Caddy configuration omits access logs because
  media/SSE URLs can contain tokens. `httputil.go:338`;
  `deploy/ubuntu/Caddyfile.example:17`. This does not establish the log policy of
  every reverse proxy or third-party service.

There are limits to revocation: an already delivered or buffered audio file
cannot be recalled. Existing media responses are ordinary file streams, not
continuously authorized responses (`handlers.go:293`). Independent cross-server
media grants remain valid after an Aux session ends because they currently have
no session relationship. Local reproduction confirmed this distinction.

## Guest experience — agreed direction and remaining choices

The user has selected two modes, chosen by the host when creating Aux:

- **Shared speaker:** everyone controls the music playing on the host's one
  selected device. Joining guests do not start a second local audio player.
- **Listen together:** the host and guests hear the same session on their own
  devices. Joining never transfers playback away from or automatically pauses
  the host.

In both modes, guests can explicitly **pause, resume, and skip the shared
music**, add songs, remove their own pending requests, and **rearrange the entire
upcoming queue**. Reordering does not change the currently playing song or grant
permission to remove another person's requests. Guest seek, previous,
shuffle/repeat, host output selection, and host volume control have not been
approved; they must not be bundled into permission to pause/resume/skip. Other
security defaults and lifetimes below remain proposals.

1. The host starts an Aux session, chooses **Shared speaker** or **Listen
   together**, and sees exactly which catalog is shared. The current host
   output remains active and selected in either mode.
2. An invitation opens a dedicated **Join Aux** page identifying the host, mode,
   and permissions, including that shared pause/resume/skip affect the session.
   It does not log the browser into a full server account or silently change a
   saved personal server connection.
3. Guests can continue in the browser with no Codec app, account, or self-hosted
   server required. Opening Codec is an explicit alternative only when that app
   version supports the safe session protocol.
4. A joined guest sees now playing, the shared queue, and only the catalog the
   host selected for sharing. Private playlists, likes, complete listening
   history, internal paths, source URLs, and device names are not part of the
   guest response.
5. Shared speaker guests use session controls without starting local audio. In
   Listen together, a guest starts their independent listener through an
   explicit join/listen gesture where the browser requires it. In both modes,
   an intentional shared pause/resume/skip updates one session timeline: it
   affects the host speaker, and all participants in Listen together. Local
   mute/volume, a suspended or disconnected listener, and local audio lifecycle
   events do not send shared transport commands. A rejoining listener catches
   up to the current timeline instead of rewinding or pausing everyone.
6. A visible **Leave Aux** closes the guest session and restores their personal
   connection if present. The host can remove an individual guest, revoke an
   invitation, or end the whole session. All are distinct operations.

Proposed defaults, not yet implemented:

| Action | Host | Guest |
| --- | --- | --- |
| See now playing/shared queue | Yes | Yes |
| Browse/search explicitly shared catalog | Yes | Yes |
| Add a song at the end of the queue | Yes | Yes, with per-guest limits |
| Remove own pending requests | Yes | Yes |
| Rearrange the entire upcoming queue | Yes | Yes; currently playing song is excluded |
| Remove another guest's request or clear queue | Yes | No |
| Change the currently playing song through queue reorder | No | No |
| Shared pause/resume/skip | Yes | Yes, in both modes; updates the session, not output ownership |
| Shared seek/previous/shuffle/repeat | Yes | Not approved; excluded from initial guest permissions |
| Mute/change volume on own listener | Yes | Yes in Listen together; affects only that listener |
| Transfer host output, change host/system volume | Yes | No |
| Select Aux mode and host output | Yes | No |
| Listen locally | Yes | In Listen together only; Shared speaker uses the host's output |
| Contribute songs from own Codec server | Yes | Yes; share selected songs, not the personal login |
| Check whether a shared song is in own library | Yes | Yes, privately against the personal library |
| Save a shared song to own library or playlist | Yes | Yes with source sharing permission and personal destination authorization |
| Inspect private playlists/likes/history/device inventory | Yes | No |
| Change library, playlists, covers, likes, settings or credentials | Yes | No |
| Invite/manage/remove participants | Yes | No by default |

Whether guests should browse the entire song catalog, a selected playlist, or
only suggest songs by search is a product decision. The privacy-safe default is
an explicitly shared catalog, with separate minimized response types. A host
can choose broader song browsing without exposing private playlists or likes.

## Songs from personal servers and saving shared songs

User-requested behavior: members with their own Codec connection can queue
songs from their own server, see whether a shared song is already in their
personal library, and save a missing song to that library or to a chosen
personal playlist. This applies in either Aux playback mode. It is design
work only; none of the following is implemented by this review.

### Simple interface

- In the song picker, **Aux** and **Your library** separate the shared catalog
  from the member's private collection. Selecting a personal song for the
  queue shares that selected song; it does not expose the entire collection.
- Now Playing and queue rows have a compact library button, separate from
  the existing queue action. Its label and accessible name describe the
  personal destination; a plus must not ambiguously mean queue and save.

| Personal library state | Button/status | Tap behavior |
| --- | --- | --- |
| Song is absent | Plus, **Save to your library** | Small sheet: **Save to library** or **Add to playlist…** |
| Song is already present | Checkmark, **In your library** | Open personal playlist picker; do not import another copy |
| Saving | Progress, **Saving…** | Show the ongoing operation; repeated taps reuse it |
| Save failed | **Couldn't save · Retry** | Retry safely without duplicate tracks or playlist membership |
| Personal server unavailable or membership unknown | **Check your library** | Explain/retry the connection; never claim the song is absent |
| No personal connection | **Connect your library** in the song menu | Optional connection flow; listening and queue participation still work without one |

Choosing **Add to playlist…** for a missing song saves it to the personal
library first, then appends it to the selected personal playlist. One user
action starts both steps. The picker contains only that person's playlists;
it clearly identifies the destination. An already-present song goes straight
to the membership step. Success can read **Saved to Library** or
**Added to [playlist]**. Saving does not automatically like the song, change
the shared queue, or change playback.

### What saving means

This is a durable copy of the audio, artwork, and permitted metadata on the
recipient's own server. It continues working after Aux ends; an expiring source
URL or an entry in the device's temporary playback cache is not a successful
save. Downloading onto a phone is a separate existing action.

Library membership is checked using the exact Codec fingerprint against the
personal server, not by matching titles or artist names. Track IDs and playlist
IDs are local to each server. A different encoding/master with a different
fingerprint must not silently replace a personal track. Preserve existing
metadata, likes, artwork, and playlist order for matched tracks. A known record
without usable media needs a repair/save state, not a claim that audio is saved.

The existing fingerprint is a logical track identifier, not a content checksum:
imports may use an explicit fingerprint, an external identifier, or a metadata
hash (`sync-server/internal/server/import.go:543`, `:604`). An exact fingerprint
match is Codec's membership rule, not proof of identical audio bytes. A copy
grant must separately bind a validated content hash/size and selected source
record; never trust a guest's fingerprint claim to overwrite an existing file.

The match result is personal UI state; do not publish the member's library,
playlist names, or listening history to the Aux host or other participants.
The owner uses their personal authority only for writes to their own server;
an Aux credential alone can never import into or edit anyone's private library.

Proposed source permission: **Allow others to save songs I share** belongs to
each contributing owner, not just the session host. Make that choice explicit
when sharing personal songs. The default and presentation remain a product
decision. Queuing grants session listening; it should not silently grant a
whole-library export. Saving uses a narrowly scoped authorization for the
selected track and destination. This permission limits Codec's built-in save
feature; it cannot prevent a listener from retaining audio already delivered.

### Trust, efficiency, and failure handling

- Maintain the personal server connection alongside Aux rather than replacing
  it with the session server. Private credentials, caches, and playlists remain
  scoped to that connection. Leaving Aux does not lose either saved music or
  personal settings.
- A native trusted client can hold both connections separately. On the web,
  do not ask someone to type their personal owner token into another person's
  server-hosted page: that page's code can read it. The personal library/save
  operation must run at their own server's origin or in another trusted client.
  Cross-origin handoff exchanges only scoped requests/grants, validates exact
  origins and request state, and never transfers the personal owner token.
  This remains true even if the remote page looks identical to Codec.
- Batch personal membership lookups for the current song/upcoming queue and
  reuse the personal library index. Do not download the source audio or refetch
  entire remote libraries just to decide whether to display a plus.
- Reuse the destination's existing track before starting any transfer. Copy
  once, with bounded concurrency and progress; saving must not interrupt audio
  or cause every listener to download another copy automatically.
- Prefer a bounded server transfer where connectivity permits, without routing
  a full file through the phone. A remote URL cannot become an unrestricted
  server fetch: validate source identity, redirects, network destinations,
  sizes, timeouts, and media integrity; never forward owner credentials.
  LAN/Tailscale-only origins need an explicit reachable route or a separately
  designed trusted-client transfer, not arbitrary private-network fetching.
- Persist a resumable/idempotent save operation. Commit a complete validated
  track before adding destination playlist membership. If the copy succeeds
  but the playlist step fails, show **Saved to library; couldn't add to
  playlist** and retry only that step. Never overwrite a playlist snapshot.
- Define the authorization boundary around session end and source departure.
  Proposed behavior: no new saves after permission expires; an already accepted
  authorized transfer may finish within a short, bounded transfer lifetime.
  Failed/expired transfers remain explicit failures. A completed personal copy
  is independent of the Aux session and is not deleted on leave/revocation.

Required local coverage before implementation is considered complete: A queues
a song from B; both playback modes can play it; A privately finds an exact local
match or imports it; choose a playlist directly; repeated taps/concurrent saves
do not duplicate; wrong-content claims and expired permissions fail; metadata
and existing covers are preserved; playlist-only retry works; source offline,
destination offline, session end, and reload produce honest status; no owner
token or private playlist data crosses into another member's origin. Use two
isolated servers and distinct owner/guest contexts, never production libraries.

### Existing implementation reuse and gaps

The server already issues owner-authorized, track-scoped media grants, and
clients understand foreign audio/artwork references. These grants currently
last 24 hours and have no session binding, recipient binding, individual revoke
endpoint, or explicit copy permission. They are playback building blocks, not
a complete durable-save protocol. No production client flow currently mints
those grants to implement personal-server queue contributions or shared-song
save; those controls need new implementation and tests.

Do not implement Save by blindly chaining the existing metadata/audio PUT
routes. Metadata upsert currently replaces metadata and liked state on an
existing fingerprint (`store_library.go:90`), while audio upload replaces the
file (`httputil.go:20`). The bundle import's existing-track branch
(`import.go:371`) is a better additive precedent. The new operation must
atomically recheck destination identity, preserve existing content and user
state, stage/verify missing media, resolve the actual destination track ID,
then append optional playlist membership without clearing or reordering it.

The current web settings form permits server/token entry during a guest
session (`src/lib/components/MobileSettings.svelte`). The page stores that
credential on its own origin, and `sync.ts` maintains one global token. This
is why the proposed feature cannot simply reuse the existing reconnect form
on the invite host. It needs independent connection identities plus an
own-origin/trusted-client authorization flow. This is source evidence of an
unsafe integration path, not a claim that anyone stole a token in the incident.

## Proposed implementation boundaries

- Use a high-entropy invitation secret (at least 128 random bits) for links. If
  short codes remain, make them short-lived and rate-limited by source and
  server, with bounded attempts and optional host approval. Do not regard a
  hidden URL or unpredictable server address as protection.
- Exchange the invitation for a unique, expiring participant credential. Store
  credential hashes server-side, bind credentials to session/member/role, and
  make expiry and revocation server-enforced. Give the host a participant list.
- Invite expiry, participant expiry, idle session expiry, and total session
  lifetime are distinct. Suggested starting points: 15-minute invitation, 24-
  hour maximum session with host renewal, participant access never longer than
  its session. Exact durations need agreement.
- Add a dedicated Aux queue operation instead of accepting arbitrary global
  playback commands. Use server-assigned request IDs and participant ownership;
  append/remove operations must not replace another client's stale snapshot.
  Give participants an explicit reorder capability covering all upcoming entry
  IDs. Validate that a reorder preserves membership, excludes the current song,
  and never removes another person's entry; use revision/conflict handling so a
  reorder racing with song advancement cannot move the playing track back into
  the queue. Ownership still governs removal, even when reorder is shared.
- Add explicit session-scoped pause/resume/skip operations for all authorized
  participants in either mode. Their actor is the participant credential, not
  an arbitrary `device_id` or selected playback target. These operations cannot
  attach a new current track, change volume/output, or carry an unrelated queue
  snapshot. Use command IDs and revision handling to prevent duplicate skips
  from retries. Do not infer seek/previous/shuffle/repeat permissions from this
  shared transport capability.
- Owner output selection remains owner-only. Model synchronized listeners
  separately from that output instead of reusing global `active_device_id`.
  Never trust `device_id` or `target_device_id` supplied by a guest to select or
  impersonate an owner's device.
- Persist the host-selected mode and publish one canonical session timeline.
  Authorized host and guest pause/resume/skip operations update it. Shared
  speaker drives only the host's selected output; Listen together drives
  independent listener players. Define track transitions, server-clock offset,
  tolerable drift, reconnect/catch-up, local mute, and suspended-browser recovery
  explicitly. Guest device presence and local player lifecycle events cannot
  issue shared transport commands. Queue reordering changes only upcoming
  playback, not the timeline for the current song.
- Keep guest credentials and cached guest data separate from the owner's
  persistent login. Joining, canceling, returning from the app, reloading,
  leaving, and revocation must each preserve that separation. Permission is
  never derived only from a local `guestMode` boolean.
- Use explicit response and cache scopes. A minimized guest library cannot
  share owner response bytes, ETags, persisted browser caches, or service-worker
  entries. Include authenticated principal/session/permission version in any
  applicable cache key; clear scoped caches on leave/revoke.
- Keep secrets out of URL queries where possible. Strip an invitation from
  visible history after exchange; use a restrictive referrer policy. Browser
  and app handoff must not put owner credentials into deep links. Inspect the
  whole proxy/CDN/diagnostic path before claiming secrets never appear in logs.
- For cross-server sharing, use selected-track, session-bound grants, validate
  permitted URL schemes/origins and redirects, and never forward an owner's
  Authorization header to an arbitrary media host. Host consent is needed
  before guests cause their devices to contact another server. That remote
  server necessarily sees the listener IP and media requests.
- There is no technical promise of “stream but impossible to save”: a device
  allowed to receive audio can retain those bytes. Do not describe hidden
  download buttons as content protection.
- Add strict small request/queue/member limits and throttles to the guest
  surface. Current generic JSON allowance is 32 MiB; global command responses
  are persisted per command ID (`server.go:26`, `playback_v2.go:129`). Bounds
  should apply before expensive parsing/work and not impair normal owner
  library import.

## Installed iOS 1.4 (7) and rollout

Owner playback, library, download, and sync APIs must remain compatible with
the installed app. A safer Aux contract does not justify changing those APIs or
requiring an update just to listen to personal music.

Old Aux clients, however, cannot safely be granted owner-like command access to
preserve a broken interaction. Keep a safe browser join path available for
everyone and stop automatically handing new invites to unsupported app
versions. Add a versioned Aux protocol/capability check; legacy joins must
either receive only permissions the server can safely enforce or clearly stay
in the browser. Do not silently fall back to broader credentials on `403`.

The installed app's single-active-device Aux implementation cannot be assumed
to support mode-aware sessions, separate synchronized listeners, scoped shared
transport, or the new reorder capability.
Keep ordinary owner use working, route new guest joins to the compatible web
experience, and make unsupported Aux features explicit instead of exposing
controls which only fail after a tap. A later native release can opt into the
new listener and queue protocol after its own local verification and separate
authorization; no native change is part of this UI/review task.

Before a future coordinated release, define how existing indefinite sessions
are expired/revoked and tell hosts that old invitations will need replacing.
Revoke session-specific credentials without rotating the owner's token or
interrupting ordinary music playback. No existing live sessions were changed
by this review.

## Verification performed and required

Read-only source review plus a temporary Go module copy with synthetic data:

- Full guest catalog/audio read, mutation/export denials, missing artwork/HEAD
  permissions, shared guest token, host device spoof, every global playback
  command, and arbitrary URL acceptance were reproduced.
- A 10-year fake-clock advance, SQLite reopen, and changed owner token left the
  original invite/guest credential valid.
- Fifty local invalid joins returned `404` without throttling. This is evidence
  of the application behavior, not a brute-force attempt on any external host.
- Session end denied subsequent guest API requests while an independent media
  grant still worked. Existing `TestAuxGuestScope` and
  `TestSyncRevocationClosesGuestStream` passed alongside the isolated audit test.
- No production tokens, private music, or production traffic were used as
  evidence; fixture credentials were kept out of the report.

The separate local WebKit reproduction described above confirms the web UI
role-loss behavior after leaving the invitation URL. Physical iOS app-switch
timing remains unverified; the browser fallback race is a source-level finding.

Before implementing/releasing: agree the guest contract; test the permission
matrix through raw API requests as well as UI; use two isolated local servers
and owner/guest browser contexts; repeat on Safari and Home Screen; test app
installed/not installed and unsupported app versions; prove join/leave never
changes host audio output or a personal connection; verify Shared speaker never
starts guest audio and Listen together never steals host output; verify explicit
guest pause/resume/skip updates the session while listener sleep/reconnect/mute
does not; test stale tabs, restart,
invitation sharing, revocation, expiry, cancellation, concurrent queue writes,
and cross-server grants. Test every expanded permission independently and run
the released-client compatibility suite. These tests must pass locally before
any coordinated release is authorized.
