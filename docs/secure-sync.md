# Secure Sync

The secure path is the portable Go server with optional auth, not a separate
Cloudflare Worker implementation.

## Current Server Auth

The Go server can run open for local LAN/Tailscale development, or protected
with one shared token:

```bash
LOUD_AUTH_TOKEN='long-random-secret' ./loud-sync-server \
  --addr :8787 \
  --data /srv/loud \
  --web /srv/loud-web
```

When a token is set:

- Browser access uses HTTP Basic auth.
- API clients may use `Authorization: Bearer <token>`.
- `/health` stays public so uptime checks and tunnels can verify the server.
- The app, API, artwork, and audio media are protected by the same server.

For public use, this must sit behind HTTPS. Cloudflare can provide DNS, HTTPS,
Tunnel, and Access in front of the Go server, but Cloudflare is not a second
sync backend.

## Storage

- SQLite stores tracks, playlists, playback devices, playback commands, and
  global playback state.
- Disk stores media blobs under the server data directory.
- The Svelte app is served from the built `build/` directory.

## History

An earlier Cloudflare Worker sync backend (with a device-key `loud.sync.v3`
protocol) was removed; it lives in git history if ever needed. The product
path is:

```text
Svelte UI -> Go server -> SQLite + media directory
```

Desktop, mobile PWA, and any later native app should speak to that same server
contract.
