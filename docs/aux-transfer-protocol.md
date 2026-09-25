# Aux selected-track sharing and durable save

These endpoints extend `codec.aux.v2`. Ordinary owner APIs remain unchanged.
An Aux participant credential cannot mint source grants, inspect personal
membership, or import into a destination. All of those operations require the
respective personal server's owner credential.

## Source authorization

Owner `POST /api/v2/aux/grants` takes:

```json
{"fingerprint":"selected-song","session_id":"aux_…","session_origin":"https://host.example","destination_origin":"https://host.example","allow_copy":false}
```

`allow_copy` defaults to false. The grant selects one existing source record and
binds the exact logical fingerprint, independently computed SHA-256 and byte
length of its audio and optional artwork, session ID/origin, destination origin,
and an expiry no later than the 24-hour session. Derived copy tickets expire
within 15 minutes. The source checks the host's public session-liveness
endpoint before minting, resolving, and serving media. Stored credentials are
hashed. Expired/revoked grants are reclaimed when issuing new ones, and each
source permits at most 5,000 live grants. Owner `DELETE /api/v2/aux/grants` with `{"token":"auxg_…"}` revokes the
capability and all derived copy tickets. An ended session stops new media and
copy requests; already delivered audio cannot be recalled.

The response contains `source_origin`, `token`, the request fields,
`expires_at`, `sha256`, `size_bytes`, `audio_type`, optional
`artwork_sha256`/`artwork_size_bytes`, and `track` with only title, artist, album,
and optional duration. It also contains derived `media_url` and optional
`artwork_url`. Private IDs, paths, playlists, likes, source URLs and history are
excluded.

Append a foreign song using the session command's fingerprint and
`grant:{source_origin,token}`. The host explicitly enables foreign contributions.
It resolves the capability directly with the source before admitting the entry;
guest media URLs, substituted fingerprints and mismatched sessions are refused.
The host retains the original reference only in its private session record.
State/catalog responses contain host session media URLs and no source capability.
The host validates each participant before proxying a bounded audio/artwork
request; owner credentials are never forwarded to the source.

Participant `POST /api/v2/aux/sessions/{id}/tracks/{fingerprint}/copy-grant`
with `{"destination_origin":"https://personal.example"}` returns a copy reference
bound to that destination and the requesting participant. The source checks
`/status?participant_id=…` at resolution and media requests; removing a member
revokes these new requests while the rest of the session continues.
Host-catalog songs additionally require the host's `allow_saves` option. A
foreign contributor's own `allow_copy` remains authoritative.

Public `POST /api/v2/aux/grants/resolve` takes the scoped `token`, `session_id`,
`session_origin`, `destination_origin`, and `purpose` (`listen` or `copy`). A
copy request requires explicit source permission and receives a derived ticket
bound to the actual destination. This endpoint never accepts an owner credential
from another origin. GET/HEAD source media uses only the scoped token in `access_token`; participants
listen through their authenticated host proxy rather than receiving the original
source token.

## Personal membership and copy

Destination-owner `GET /api/v2/aux/membership/{fingerprint}` returns exact
fingerprint membership: `present`, `repair` (metadata exists but usable audio is
missing), or `absent`, plus the local track ID when known. Request failure is
unknown membership; clients must not translate failure into `absent`. An existing
copy can be appended to a personal playlist with owner
`POST /api/v2/aux/membership/{fingerprint}/playlist` and `{"playlist_id":"…"}`.
This resolves the actual local track ID and needs no source sharing permission.

Destination-owner `POST /api/v2/aux/transfers` takes:

```json
{"operation_id":"client-unique-id","grant":{"source_origin":"https://source.example","token":"auxg_…"},"session_id":"aux_…","session_origin":"https://host.example","playlist_id":"optional-local-playlist"}
```

The server verifies source authorization, stages bounded audio/artwork, checks
both hashes and exact sizes, and commits a complete local record. Existing
metadata, likes, local IDs, audio and covers are preserved; missing media is
repaired. The source does not receive the destination owner's token or playlist
selection. A different logical fingerprint creates a separate record.

Response: `{operation_id,fingerprint,track_id,status,playlist_added}`. `status`
is `saved` or `playlist_failed`. A copy commits before playlist membership is
appended. Membership is deduplicated, existing order is preserved, and liked
playlists are not implicitly modified. Retry the same operation ID after
`playlist_failed`: only the local playlist step runs, including after source
expiry/offline or a destination restart. Reusing an ID for another source grant
fails. Request cancellation before commit removes staged files and creates no
partial track. A disconnect after commit can be resolved by replaying the ID.
Completed personal copies survive session end and source revocation.

## Browser boundary and network limits

The invitation origin asks the user only for their personal server address.
`src/lib/aux-transfer.ts` opens that origin in a popup with a 256-bit return state.
The popup performs authentication, catalog/playlist selection, and personal
writes locally. `postMessage` returns only a selected grant or minimal operation
result; origin, popup identity, state, message type and fingerprint are checked.
The popup checks membership before asking the opener for a copy ticket; existing
personal songs work even when the source disallows copies. The staged request
contains only the originally selected fingerprint, with the same strict state,
origin and popup checks. Private playlist names and owner tokens are never
returned. Popups close/cancel
without changing the saved personal connection.

Production server fetch requires HTTPS on port 443. Each request resolves DNS,
rejects every nonpublic/special address, and dials the checked IP directly with
TLS name verification. Proxies and redirects are disabled; response headers,
JSON/body sizes, content lengths and total transfer time are bounded. LAN-only
sources fail explicitly rather than bypassing this policy. The isolated tests
map synthetic HTTPS origins to two local servers using a transport defined only
in `_test.go`; no production setting enables that transport.

Tests cover both Aux modes, wrong fingerprint/session/copy permission, source
expiry/revocation/end/offline, owner-only destination writes, byte changes,
missing-audio repair, preserved metadata/likes/covers/audio, concurrent retries,
playlist-only retry without the source, destination reopen, cancellation,
destination-bound tickets, SSRF address/redirect policy and popup result privacy.
