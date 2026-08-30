# Device Management, Friends, And Library Sharing Plan

This is a plan only. It is not implemented yet.

## Device Management

Goal: replace one shared token with named devices that can be approved,
revoked, and rotated without changing every client.

Server model:

- `devices`: id, display name, platform, public key, status, created at, last
  seen, revoked at.
- `device_sessions`: session token hash, device id, expires at, created IP/user
  agent summary.
- `device_invites`: short code, expires at, single-use approval payload.

Auth flow:

1. Existing owner token starts enrollment.
2. New device shows a code or QR with its generated public key.
3. Existing approved device confirms the name and key.
4. Server returns a device-scoped session token.
5. Device uses Bearer auth with its own token.

Rules:

- Store only token hashes server-side.
- Let the owner revoke one device without rotating every other device.
- Keep `CODEC_AUTH_TOKEN` as the bootstrap/admin recovery token.
- Device tokens should not be valid for Aux guest actions after revocation.

## Friend System

Goal: let known friends exchange music without giving them host/admin access.

Server model:

- `friends`: friend id, name, server URL, public key, trust status.
- `friend_invites`: code/link, expires at, public key, optional display name.
- `friend_permissions`: can receive shares, can send shares, optional quota.

Flow:

1. You create a friend invite.
2. Friend opens it on their Codec server/client.
3. Both servers exchange public keys and display fingerprints.
4. You approve the friend before any library data is accepted.

No global accounts. Friend identity is server-to-server plus key fingerprint.

## Sharing Songs Or Playlists

Goal: send someone tracks/playlists so they can import them into their own
library, outside Aux.

Share package:

- Manifest: `codec.share.v1`
- Sender server id and public key
- Tracks with Codec identity fields, metadata, playlist membership, and media
  URLs
- Optional playlist definitions
- Expiry and maximum download count
- Signature over the manifest

Server endpoints:

- `POST /api/v1/shares` creates a share from track fingerprints or playlists.
- `GET /api/v1/shares/{id}` returns signed metadata.
- `GET /api/v1/shares/{id}/tracks/{fingerprint}/audio` streams granted audio.
- `POST /api/v1/shares/{id}/accept` imports on the receiver.

Receiver behavior:

- Match by identifiers first, then normalized metadata.
- Existing tracks do not duplicate.
- New tracks import into `.loud/audio/Artist/Album/`.
- Playlists are created or merged by explicit user choice.

Security:

- Share grants are scoped to exact fingerprints.
- Grants expire.
- The receiver verifies the sender signature before importing.
- The UI shows sender name, server host, track count, total size, and expiry
  before accepting.
