# Aux v2 wire contract

Protocol `codec.aux.v2`; intentionally replaces unsafe Aux v1. All JSON snake_case.
Owner APIs outside Aux remain unchanged. Legacy Aux creation/join returns 410
`aux_update_required`; existing v1 credentials are revoked on upgrade.

## Authentication and lifetime

Owner bearer authorizes management and host participation. Public POST
`/api/v2/aux/join` exchanges `{ "invite_secret": "...", "display_name": "Guest" }`
for `{ "schema":"codec.aux.v2", "session_id":"...", "participant_id":"...",
"participant_token":"...", "expires_at":123, "state": State }`.
Each exchange issues a different credential. No owner credential is returned.
Guest requests use `Authorization: Bearer participant_token`. Invites expire in
15 minutes; sessions and credentials expire after 24 hours. Times `expires_at`
are Unix seconds, timeline times ending `_ms` are Unix milliseconds.

GET `/api/v2/aux/capabilities` is public and returns schema and modes.
POST `/api/v2/aux/invitation` is public, takes `{invite_secret}`, and returns
`{schema,host_name,mode,expires_at}` without joining. Invitation links should carry
the secret in a fragment and remove it from browser history after exchange.

## Host management

POST `/api/v2/aux/sessions` owner body:
`{ "mode":"shared_speaker"|"listen_together", "host_device_id":"...",
"host_name":"...", "catalog_fingerprints":["..."], "allow_saves":false,
"allow_contributions":false }`.
Catalog selection is explicit, at most 10,000 songs. The selected device must be the
current active owner output when there is one. Existing playback/current position
is seeded into the Aux timeline and output ownership is preserved. The current
track must belong to the selected catalog. Existing pending queue entries are
included only if selected. No private history/source is copied.
Returns 201 `{schema,session_id,invite_secret,invite_expires_at,state}`.

GET `/api/v2/aux/sessions` owner returns `{schema,sessions:[State]}`.
DELETE `/api/v2/aux/sessions/{id}` owner ends session, 204.
POST `/api/v2/aux/sessions/{id}/invite` owner rotates invitation and returns
`{schema,invite_secret,invite_expires_at}`. Existing members remain authorized.
DELETE same `/invite` revokes invitation only, 204.
DELETE `/api/v2/aux/sessions/{id}/members/{participant_id}` owner removes a guest;
guests can delete only themselves (leave). Returns 204.

## Session state and media

GET `/api/v2/aux/sessions/{id}/state` returns State, with `Cache-Control: no-store`.
Prefer the scoped revision stream below; fallback polling at 1500–2000 ms while
visible is supported. Suspend while hidden and catch up on return.
State is:
```
{
  "schema":"codec.aux.v2", "session_id":"...", "mode":"listen_together",
  "host_name":"...", "role":"guest", "participant_id":"...",
  "expires_at":123, "revision":1, "server_time_ms":123000,
  "status":"playing", "position_seconds":12.5, "anchor_time_ms":123000,
  "current":Entry|null, "queue":[Entry], "allow_saves":false,
  "allow_contributions":false
}
```
Host responses additionally contain `host_device_id`, a session-bound `media_token`
scoped only to this session’s audio/artwork GET/HEAD and revision event stream, and
`members:[{participant_id,display_name,joined_at,expires_at}]`. Guest responses do
not disclose device identifiers or participant names. Queue ownership identifiers
are opaque participant IDs; the host participant ID is `host`.
Entry is `{entry_id,participant_id,track:Track}`.
Track is `{fingerprint,title,artist,album,duration_seconds,media_url,artwork_url}`;
`duration_seconds` is numeric (0 if unknown); artwork_url may be empty.
Media URLs are server-produced relative `/api/v2/aux/sessions/{id}/tracks/{fp}/audio`
and `/artwork`. GET/HEAD accept the participant bearer; HTML audio/img may append
`?access_token=participant_token` only to these same-origin Aux media URLs or the revision stream.
GET `/api/v2/aux/sessions/{id}/catalog` returns `{schema,tracks:[Track]}`.
No paths, playlists, likes, history, private sources or owner device inventory.

`position_seconds` is materialized at `server_time_ms`; `anchor_time_ms` equals
that response time. Estimate current position by adding elapsed server time only
when status=playing. `status` is playing, paused, or stopped. Server alone advances
at known track duration; local ended/pause/mute lifecycle never sends commands.
Seek listener when drift exceeds 1.25s; reconnect uses latest state. Shared speaker
guests never play audio. Listen together plays independently after explicit user
gesture. Host selected output and listeners pause global playback publications
while attached to Aux. Host other devices may control but do not become output.

## Commands

POST `/api/v2/aux/sessions/{id}/commands` takes
`{command_id,kind,expected_revision?,fingerprint?,entry_id?,entry_ids?,grant?}` and returns
State. command_id is a unique client ID (max 100 bytes); retries reuse it.
Kinds: `pause`, `resume`, `next`, `append`, `remove`, `reorder`.
Append uses fingerprint from catalog. Remove uses pending entry_id and guests may
remove only their own. Reorder requires expected_revision and an exact permutation
of every upcoming entry_id; current is excluded. next requires expected_revision
to prevent delayed retries from skipping a newer current track. Other commands
may omit revision; if supplied it must match. Conflicts return 409 and clients
refresh instead of silently retrying stale skip/reorder. Unsupported/extra fields
(including device_id, URLs, volume and queue snapshots) return 400. Guest cannot
select output, seek, previous, shuffle/repeat, change volume, replace queue, or
invoke global library/playback/device/auth endpoints. Host may remove any pending
entry. Resume with no current promotes first queued entry. Empty queue stops.

Bounds: 32 participants, 200 pending entries, 25 guest pending entries, 16 KiB
command bodies (owner creation is bounded to 2 MiB for a 10,000-song selection), bounded per-IP invitation and per-principal command rates.
All session mutations are serialized and persisted. Duplicate command IDs with
a different body are 409; idempotence is scoped to session + participant.

## Cross-server selected sharing

See [Aux transfer protocol](aux-transfer-protocol.md) for source grants and durable
save. An external `append` supplies `{fingerprint,grant:{source_origin,token}}`;
the host verifies the source manifest before accepting it. The host must have
explicitly enabled `allow_contributions`. Raw media/artwork URLs are never
accepted. State/catalog strip original grant credentials and rewrite external
media to the same-origin Aux session proxy. Source credentials are not forwarded
to listeners and guest credentials are not forwarded to source servers.

POST `/api/v2/aux/sessions/{id}/tracks/{fingerprint}/copy-grant` with
`{destination_origin}` issues `{source_origin,token}` for a selected song when
its source owner allows copies. This child capability is bound to the exact
session, participant and personal destination; it expires in at most 15 minutes.
The personal destination uses its independent owner authorization to import.
The original source grant is kept server-side; removed members cannot rescope
child grants or make fresh proxy media requests. Session and participant
liveness is checked on source child use. Already delivered/buffered bytes cannot
be recalled. Share permissions do not prevent recording delivered audio.

## Revision events

GET `/api/v2/aux/sessions/{id}/events` accepts the participant credential or the
host session media token (bearer or `access_token` for EventSource). It sends
`event: aux_changed` with `data: {"revision":N}` on initial attachment and when
the canonical revision changes; clients then fetch their authorized state.
`event: ended` with `{}` means the session or credential is no longer live.
The stream sends a comment keepalive every 15 seconds and rechecks participant
revocation and known-duration advancement every second while connected.
It contains no global events, queue data, member names or device information.
Two event streams per principal are allowed. Use the server clock from the last
state response for smooth local position; do not fetch state on every local tick.

## Expiry and compatibility cutoff

Legacy creation/list/join explicitly returns HTTP 410 with `aux_update_required`.
Upgrade deletes legacy Aux sessions and credentials, preserving the owner token,
ordinary library/playback APIs, and all library files. Hosts must create new Aux
invitations. Historical permissive Aux tests are replaced by explicit denial
regressions; this is an intentional legacy Aux cutoff, never a claim that legacy
Aux clients passed the new protocol. The frozen owner compatibility gate remains
required for ordinary owner features.

Ending Aux preserves the selected owner output and volume and restores paused
owner playback at the final local Aux song/position. If the final song belonged
to another server, owner playback becomes stopped because session grants expire.
An `aux_changed` event on the existing owner playback event hub tells updated
owner clients to discover sessions; older owner clients ignore the event.

Unknown duration (0) requires manual Next because the server cannot infer an end
from one listener's local lifecycle. Clients never publish a local ended event
as a shared Next. Command receipts live until session end and are bounded to
20,000 accepted commands per session; retries preserve the original actor scope.
