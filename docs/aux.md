# Using Aux

Aux shares a listening session without signing guests into your personal library.
The September 24 candidate includes the server, web and native implementation;
it remains local until a coordinated release is authorized.

## Start and join

Start Aux from Codec, choose the songs to share, then choose:

- **Shared speaker:** music stays on the host's selected device. Guests control
  the session without becoming an audio output.
- **Listen together:** participants can listen on separate devices. In a browser,
  tap **Listen on this device** to allow audio; muting that device doesn't pause
  everybody else.

Share the invitation link or QR code. Guests explicitly choose **Join in this
browser** or **Open in Codec**. No app installation or personal server is needed
to join in a browser. The app must support Aux v2. A join never replaces a saved
personal server connection.

Guests can pause, resume, skip, add shared songs, remove their own upcoming
requests, and reorder the entire upcoming queue. They cannot change the host's
volume/output or access personal playlists, likes, history or unshared songs.
The host can remove participants, rotate/revoke the invitation, or end Aux.
Invitations last 15 minutes; sessions and participant access last up to 24 hours.

## Personal music and the plus button

**Add from your library** lets a participant choose a song on their own server
when the host permits contributions. The source owner separately chooses whether
others may save a permanent copy; that permission is off by default.

The plus button checks for an exact fingerprint in your personal library. If it
is already present, you can add the existing song to a playlist without another
download or source copy permission. Otherwise, saving requires permission from
the source and stores a verified copy on your server before adding it to the
chosen playlist. Personal metadata, likes, covers and playlist order are retained.
If the playlist step fails, retry it without downloading the audio again.

On the web, personal login and playlist selection happen in a window on your own
server's origin. The Aux page receives neither its owner token nor its library
or playlist names. Native keeps the personal and guest connections separate.

## Limits and compatibility

Ordinary playback on the installed app still uses the existing owner APIs. Old
Aux invitations are deliberately retired: create a new invitation with updated
web/native clients after the server update. Both listening modes use a shared
server timeline; they are not sample-accurate multi-speaker audio synchronization.

Foreign sources and destinations must be reachable through public HTTPS on port
443. Production fetch rejects private/LAN/loopback addresses and redirects. The
local lab can test browser identity boundaries, playback, membership and existing
song playlist saves; isolated Go tests exercise new cross-server copies through
a test-only HTTPS transport. Audio already delivered to a listener cannot be
recalled when access ends.

See the [session protocol](aux-v2-protocol.md), [transfer protocol](aux-transfer-protocol.md),
[local testing guide](local-development.md), and [release checklist](release-checklist.md).
