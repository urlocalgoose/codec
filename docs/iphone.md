# iPhone Setup

Codec has two phone paths.

For development, use the [two local demo servers](local-development.md) and
the separate [Codec Test install](local-test-app.md). Do not replace the app
used for listening or change its server connection to run development tests.

## First connection

Fresh iOS and web installs open a short welcome screen:

- **I have a server** opens the server address and auth token form.
- **I need to set one up** explains where the server runs and links to the
  [setup guide](https://codec.codie.sh/docs/hosting.html). Return to Codec and
  choose **I have my server details** after setup.
- **I'm confused** introduces Codec as open source and self-hosted, explains
  what that means and why someone would use it, then gives the steps to start
  a server. **Open setup guide** links directly to hosting instructions;
  **I have a server** opens the connection form.

Back returns to the welcome screen without clearing typed connection details.
Existing connections still reconnect directly; connection errors open the form
so users can correct their details. Aux invitation links retain their separate
join screen. Setup links open the website; they do not install or provision a
server from the phone.

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

For local testing, select **Codec Test**, or use `bun local:ios simulator`.
Physical installs require an explicit device and signing team as described in
the test-app guide. Keep **Codec** for deliberately authorized release builds.
The app stores its server URL, theme, non-secret Aux state, and playback device
ID under `codec.*` preferences. Owner and Aux credentials use separate
bundle-scoped Keychain entries. Legacy preference tokens migrate on launch;
server/principal cache scopes keep guest and owner libraries separate.
Old `loud.*` preferences are still read so existing installs migrate cleanly.

Downloaded audio is stored in the app's Application Support folder under
`Codec/audio`. Existing `Loud/audio` downloads are moved there on launch when
the new folder does not exist.

## Expected Phone Behavior

- Browse and search the server library.
- Stream with range support.
- Download tracks for offline native playback.
- Control shared playback through `loud.playback.v2`.
- Start Aux as an owner, or join an invitation with a separate guest credential.
  Choose Shared speaker or Listen together; see [Using Aux](aux.md).
