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

The desktop app and iOS app both have an optional auth-token field next to
the server URL; set it to the same value as `CODEC_AUTH_TOKEN`.

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

Desktop, mobile PWA, and any later native app should speak to that same server
contract.


## Aux guests (`loud.aux.v1`)

Aux sessions are shared listening: the host mints a short code
(`POST /api/v1/aux`, host token required), and guests trade the code for a
scoped guest token at the public `POST /api/v1/aux/join`. Guest tokens can
read the library, stream media, and use the shared `loud.playback.v2`
queue/commands - nothing else (no sync, uploads, likes, playlist edits, or
aux management; those return 403). Ending the session
(`DELETE /api/v1/aux/{code}`) invalidates its guest token immediately.

To make join links work, the static web app shell is served without auth;
every `/api` route (including all media) remains token-protected.
