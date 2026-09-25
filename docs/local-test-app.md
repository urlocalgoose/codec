# Codec Test

Codec Test is a separate development install for the local test servers. It can
live beside the everyday Codec app on the same phone. Building or installing it
does not upload anything to TestFlight or App Store Connect.

| | Everyday Codec | Codec Test |
| --- | --- | --- |
| Xcode scheme | `Codec` | `Codec Test` |
| Build configuration | `Release` | `LocalTest` |
| Bundle identifier | `sh.codie.codec.mobile` | `sh.codie.codec.mobile.test` |
| Home Screen name | Codec | Codec Test |
| Aux URL scheme | `codec://` | `codec-test://` |
| App Store archive | Existing release workflow | Excluded from archiving; `SKIP_INSTALL=YES` |

The test configuration uses optimized Swift code, the same app sources and the
same capabilities. Its only runtime difference is accepting `codec-test://`
instead of `codec://` Aux links. Production `Info.plist`, `Codec` scheme, Debug
and Release settings are unchanged.

## Simulator

Start the persistent local servers first; see [local development](local-development.md).
From the repository root:

```sh
python3 scripts/local-dev.py up
python3 scripts/local-test-app.py simulator
python3 scripts/local-dev.py auth a
```

The last command copies server A's token to the clipboard without printing it.
In **Codec Test**, connect to `http://127.0.0.1:8791` and paste the token. For B,
use port `8792` and `auth b`. These are the default ports; `local-dev.py status`
shows the configured values. The Simulator's paste command can transfer the
Mac clipboard if automatic clipboard sharing is disabled.

The script creates or reuses **Codec Local Test**, a dedicated simulator. It
never selects whichever simulator happens to be booted. Later runs rebuild and
update only Codec Test, preserving its settings, downloads and library cache.
Simulator builds use local ad-hoc signing (`CODE_SIGN_IDENTITY=-`) so the
app can exercise Keychain storage. No Apple account, device provisioning or
App Store upload is involved. Unsigned simulator builds cannot verify this path.

Xcode build output lives in `.codec-dev/ios/simulator.log`; DerivedData remains
in `.codec-dev/ios/DerivedData` for incremental builds.

```sh
# Build without booting or installing anything.
python3 scripts/local-test-app.py simulator --build-only

# Fast identity/configuration guard, without a build.
python3 scripts/local-test-app.py check

# App-hosted regressions on the dedicated simulator and test app identity.
python3 scripts/local-test-app.py test
```

App-hosted tests can change the test app's saved state. Use the normal connection
screen again afterward if needed. They cannot use the everyday app's sandbox.
The ordinary `Codec` scheme remains available for release build verification;
do not use it to install development updates over the everyday app.

## Phone

Use the local lab's private Tailscale HTTPS address. On a phone, `127.0.0.1`
points at that phone, not this Mac. Run `bun local:share` to expose the existing
loopback servers through dedicated Tailscale HTTPS ports: A uses `8441`, B uses
`8442`, and the site uses `8444`. The command prints the private URLs; both Mac
and phone must be connected to Tailscale. There is no public sharing or LAN
bind change. `bun local:unshare` removes only the lab's private routes.

Find the physical device identifier with `xcrun devicectl list devices`. Install
only when that phone is explicitly intended for testing:

```sh
python3 scripts/local-test-app.py device \
  --id YOUR_DEVICE_UDID \
  --team YOUR_DEVELOPMENT_TEAM_ID \
  --allow-provisioning
```

The first install may need `--allow-provisioning` so Xcode can register and sign
the separate development app. It does not upload a build for review. Later
builds can omit it when a valid development profile is already available.
Developer Mode and a trusted, connected phone are required. `--build-only`
builds without installing. The script checks the built bundle identifier and
URL scheme before any install and has no archive/export/upload operation.

Connect **Codec Test** to A or B using the Mac's address and the matching local
token. Leave everyday **Codec** connected to the listening server. Use only
demo media/local tokens in the test app. Switching test servers happens through
the normal connection controls; never paste production credentials into tests.

## Storage and Aux isolation

Personal and Aux participant credentials use separate Keychain accounts in a
service scoped to the app's bundle identifier, with device-only accessibility
after first unlock. Existing personal tokens migrate out of UserDefaults only
after a successful Keychain write. Codec Test and everyday Codec do not share
an App Group or Keychain access group.

Personal library snapshots are scoped by server and principal. The old shared
`library.json` cache is discarded because its principal cannot be verified;
the personal server rebuilds it on connection. Aux catalogs stay in memory,
separate from the personal library. Artwork cache keys include the scoped URL
and authorization. Saved Aux identity/role metadata is separate from the saved
personal server and is revalidated before a listener resumes. Leaving Aux or
losing access removes the participant credential and stops its listener.

Aux uses the same `MPVolumeView` system volume control as Now Playing, so its
slider follows the iPhone's hardware buttons and current audio route. Local
mute affects only this listener; neither control sends a shared pause or changes
another participant's volume.

The personal owner event stream discovers Aux immediately on `aux_changed` and
reconnect, including while the existing playback engine keeps the app active
in the background. Its discovery fallback is 30 seconds while the stream is
healthy and 3 seconds otherwise; returning to the foreground also checks.
Attaching Aux stops the ordinary stream, and its participant listener continues
to poll only the scoped session. Queued callbacks and late discovery responses
cannot attach a session from a replaced personal connection.

Playback device identity and downloads remain in the app's own container.
Background download sessions are scoped to the owning application; the existing
session name does not make the two apps share download state.

Codec Test deliberately does **not** register the production `codec://` scheme.
Local web builds use `codec-test://` for their Aux “open app” handoff, so a local
invite opens Codec Test instead of everyday Codec. Production web builds retain
`codec://`. The local build's version begins with `local-`; this reserved build
label controls that choice. V2 links use `codec-test://aux-v2` with the server
and invitation. Opening a link presents a confirmation screen; only **Join Aux**
or **Join and listen** exchanges it for a participant credential. Legacy
four-character codes require a new invitation. Owner tokens, participant tokens
and invitation secrets never belong in checked-in screenshots, logs or docs.

The Aux v2 local verification run passed 36 CodecKit tests, the 171-test hosted
suite (one existing optional performance test skipped), and six focused Aux
cases including an actual create/append/resume/end pass against server B. An
optional `AuxNativeCaptureTests` fixture accepts only loopback server B and the
Codec Test build; without its private sandbox fixture it skips. Private local
receipts and screenshots live under `.codec-dev/reports/aux-v2/`. Simulator
checks do not establish physical iPhone interruption, lock-screen, background
audio or handoff behavior; that device verification remains pending.

## Existing-phone compatibility before release

A newly compiled Codec Test validates today's native source against candidate
servers. It does **not** prove that an already-installed App Store build still
works without an update.

Keep the last shipped/review build and its source/build manifest. Each server
release must pass the older-client API contract checks and a manual check with
that unchanged binary on a separate QA device or an existing simulator binary
built from that revision. An App Store device archive cannot run in Simulator;
do not call a rebuilt current-source test app the old build. Do not change the
daily listening app's connection just to satisfy a test checklist.

On that unchanged client against local candidate servers, check connection and
library refresh, new songs/covers/playlists, likes and playlist edits, streaming
and range seeking, downloads/offline playback, reconnect, playback ownership
and queue sync. Aux v1 deliberately retires unsafe guest access; older clients
must show an update-required response while ordinary owner APIs remain compatible. Record the actual client version/build and
server revision tested. A failure blocks the server release until backward
compatibility is restored or an explicit rollout plan is agreed.

If production `Info.plist` capabilities change later, update
`App/LocalTest-Info.plist` too. The configuration guard requires parity except
for the test display name and URL registration; review new shared-storage
entitlements before adding them.
