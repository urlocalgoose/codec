# Secure Sync

The secure path is the portable Go server with optional auth, not a separate
Cloudflare Worker implementation.

## Current Server Auth

The Go server can run open for local LAN/Tailscale development, or protected
with one shared token:

```bash
CODEC_AUTH_TOKEN='long-random-secret' ./codec-sync-server \
  --addr :8787 \
  --data /srv/codec \
  --web /srv/codec-web
```

When a token is set:

- The web app collects the token on its connect screen and sends it as a
  Bearer header. Direct navigation to an API URL still gets an HTTP Basic
  prompt (token as the password); API fetches never trigger the browser's
  native login dialog.
- API clients may use `Authorization: Bearer <token>`.
- Clients that cannot set headers (`<audio>` elements, EventSource/SSE) use
  `POST /api/v1/auth/stream-token` to mint a short-lived `stream_...` token,
  then send that as `?access_token=<stream-token>`.
- Older clients may still send the main shared token as `?access_token=...`,
  but publishing setups should use current clients so long-lived tokens do not
  ride in media URLs.
- The request log prints only path, status, bytes, and duration. It never
  prints query strings, so access tokens stay out of the app server logs.
- `/health` stays public so uptime checks and tunnels can verify the server.
- The static app shell is public so join links can load; API data, artwork,
  and audio media are protected by the same server.

The web interface and native iPhone/iPad app accept a server URL and auth token
on their connection screens; use the same value as the server’s `CODEC_AUTH_TOKEN`.

For public use, this must sit behind HTTPS. Cloudflare can provide DNS, HTTPS,
Tunnel, and Access in front of the Go server, but Cloudflare is not a second
sync backend. Configure any reverse proxy/CDN logs to omit query strings,
because media and SSE URLs can contain short-lived stream tokens.

## Storage

- SQLite stores tracks, playlists, playback devices, playback commands, and
  global playback state.
- Disk stores media blobs under the server data directory.
- The Svelte app is served from the built `build/` directory.
- Old `loud-sync.sqlite` databases are renamed to `codec-sync.sqlite` on
  startup when the new file does not already exist.

## History

An earlier Cloudflare Worker sync backend (with a device-key `loud.sync.v3`
protocol) was removed; it lives in git history if ever needed. The product
path is:

```text
Svelte UI -> Go server -> SQLite + media directory
```

The web interface, mobile PWA, and native iPhone/iPad app use the same server
contract.


## Aux guests (`codec.aux.v2`)

Aux is a separate authorization and playback domain. A host explicitly selects
shared songs and a listening mode. Each join exchanges a strong, 15-minute invite
for a distinct participant credential; sessions end after 24 hours. Guests can
pause/resume/skip, append selected music, remove their own pending requests and
reorder the entire upcoming queue. They cannot transfer output, set host volume,
replace personal queues or read/mutate personal library data.

The server checks scope on every command and media request. Host media uses a
separate scoped token, never the owner credential in a URL. Session event streams
contain only revision invalidations and end notifications. End/removal revokes
future requests and live session streams; already delivered audio cannot be
recalled. Cross-server tracks stream through the host with the same participant
checks. Saving requires separate source permission and destination-owner access.

Web guest storage is separate from the saved owner login. Personal-library
selection opens on the personal server's own origin; checked `postMessage`
responses return only the selected song capability or minimal operation result.
Native owner and participant secrets use separate bundle-scoped Keychain entries;
library caches are scoped by server and principal.

The old `/api/v1/aux` creation/join routes now return `410 aux_update_required`;
old guest credentials are revoked during upgrade. Owner APIs remain unchanged.
The public static shell and invitation preview do not authenticate a browser.
See the [wire contract](aux-v2-protocol.md), [transfer security and limits](aux-transfer-protocol.md),
and [historical security findings](aux-security-review.md).
