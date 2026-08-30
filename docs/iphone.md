# iPhone Setup

Codec has two phone paths.

## PWA

Run the sync server somewhere your phone can reach, then open the server URL in
Safari and add it to the Home Screen.

Use the server URL, not the Vite dev URL:

```text
https://YOUR_HOST
http://YOUR_MAC_IP:8787
```

If the server has `CODEC_AUTH_TOKEN`, enter the same token in the connection
screen. Public installs should use HTTPS.

## Native iOS App

```bash
open ios/CodecMobile/Codec.xcodeproj
```

Pick your connected iPhone in Xcode and run. The app stores its server URL,
token, theme, Aux state, and playback device ID under `codec.*` preferences.
Old `loud.*` preferences are still read so existing installs migrate cleanly.

Downloaded audio is stored in the app's Application Support folder under
`Codec/audio`. Existing `Loud/audio` downloads are moved there on launch when
the new folder does not exist.

## Expected Phone Behavior

- Browse and search the server library.
- Stream with range support.
- Download tracks for offline native playback.
- Control shared playback through `loud.playback.v2`.
- Join/start Aux when authenticated as host, or join as guest with a code.
