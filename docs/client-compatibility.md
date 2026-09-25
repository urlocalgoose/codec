# Installed app compatibility

A server or web release must work with the app people already have. Uploading a
new iOS build is neither a prerequisite nor a substitute for this check. Keep
the current listening app installed during testing; the separate **Codec Test**
app is for candidate native code, not proof that the installed version works.

## Run the gate

On a Mac with Swift 6 and Go:

```sh
python3 scripts/check-client-compatibility.py
```

The script builds the candidate Go server and the **unchanged client code from
iOS 1.4 (7)**. It starts two disposable servers bound to `127.0.0.1`, with separate
random ports, tokens, databases and generated tone/image fixtures. It exercises
real HTTP, restarts both servers, checks persistence, then removes the fixtures.
It does not connect to production, change the persistent local demo libraries,
reuse deployment tokens, or install/upload an app. All server storage, address,
web and authentication settings are explicitly overridden for these fixtures.

Build caches are retained under `.codec-dev/cache/client-compatibility-swift`.
The report and build logs are written to
`.codec-dev/reports/client-compatibility/`. A nonzero exit or missing/false
`passed` result fails the release gate. An unsupported platform is an error,
never a successful skip. A failed rerun invalidates the previous success receipt.

## Declared Aux v1 security retirement

The Aux v2 candidate deliberately retires the unsafe shared guest credential and
legacy global-playback permissions. **iOS 1.4 (7) Aux is not compatible with this
candidate.** Its ordinary owner account/library/playback/download APIs remain
supported. The default gate above retains every original expectation and fails
at legacy Aux creation (HTTP 410); that failure must not be presented as a full
compatibility pass.

The authorized Aux redesign has a separate, explicit verification mode:

```sh
python3 scripts/check-client-compatibility.py --aux-v1-retirement
```

This mode still verifies and compiles the same three byte-for-byte frozen client
files. Only the harness policy changes: its unchanged legacy create/list/join
methods must receive 410, including after restart. Owner media grants and
cross-server queue compatibility are still exercised using the frozen owner
client. The report labels the tested scope as owner APIs with a declared Aux v1
security retirement, sets `legacyAuxCompatible` to `false`, and lists the
intentional breaking change. It does not claim legacy guest permissions, v2
Aux behavior, or physical-device compatibility passed. The v2 server/browser/native
suites cover the replacement protocol separately.

A release readiness record must carry this exception explicitly: old Aux
invitations and session credentials are revoked, hosts need new invitations,
and build 7 users use the safe browser join path or a separately released app
that supports v2. The command is verification, not permission to release. The
strict gate and original frozen contract remain available without the flag.

CI declares this exception in both the job/step names and the command. A green
installed-client job verifies the frozen owner APIs and enforced Aux v1
retirement; it does not mean build 7 supports Aux v2. Keep the full compatibility
report with the release evidence so the exception remains visible.

Optional arguments:

```sh
python3 scripts/check-client-compatibility.py \
  --server-binary /absolute/path/to/candidate/codec-server \
  --report-dir /absolute/path/to/private/release-evidence/client-compatibility
```

The binary must run on the test Mac. The report records its SHA-256. For an
Ubuntu release, also run the Go/server checks and Ubuntu artifact checks in the
[release checklist](release-checklist.md); this harness alone does not prove a
Linux package will start. No argument accepts a remote server URL or an existing
library directory, so destructive fixture operations cannot be redirected to a
listening deployment.

## What is frozen

`scripts/client-compatibility/contract.json` records version `1.4`, build `7`,
bundle ID `sh.codie.codec.mobile`, and source commit
`7b7bd23fefefebfeb6ddcd7e6b1170c08ab48127`. The three files under
`scripts/client-compatibility/Sources/CodecKit/` are byte-for-byte copies from that
commit. Their SHA-256 values were checked against the private source manifest
recorded with the September 22, 2026 App Store upload:

| File | SHA-256 |
| --- | --- |
| `CodecClient.swift` | `a88ecc63ac37a113f931cd6e96b16fd22f47c3362cd8af02dba79ed7738477be` |
| `Models.swift` | `474b1db2c40ed49ea3151174e903fe95c9b9db32056a9229305c7b1160aec299` |
| `PlaybackModels.swift` | `68d99dec542943c6f8e5c345964e9521ec3a5f3f66bf84c3f5764034e2e6c46b` |

Each run verifies these hashes before compiling. The private original manifest
is not needed on another developer's Mac. These copies are test fixtures, not
the application's current dependency. Do not edit them to make a server change
pass, and do not automatically refresh them from the working native sources.

When another iOS version ships, add a separately named frozen contract and keep
testing every supported installed version. Changing the supported baseline is an
explicit release decision; never silently drop the previous app from the matrix.

## Coverage

The compatibility runner uses the frozen `CodecClient` methods and actual
network responses, rather than source-text assertions or mocks:

- Health/schema discovery, separate server identities, owner authentication,
  rejected missing credentials, and credentials that cannot cross servers.
- Library JSON decoding, real conditional requests and HTTP 304 reuse through
  the shipped `LibraryCache`; library changes invalidate that cached response.
- Server-provided audio/artwork URLs, origin-scoped authorization, full audio
  downloads, exact byte-range responses, PNG MIME type and original image bytes.
- Playlist creation, add, reorder, remove, cover upload, like/unlike, and playlist
  deletion that preserves tracks and likes. Server B remains unchanged while A
  is edited.
- Device presence, current playlist origin, playback state, monotonic revisions,
  command retry idempotency, stale queue conflict protection, initial SSE state
  and subsequent live playback events decoded by the shipped models.
- Empty-server playback. Build 7 recognizes the exact JSON sentinel `null`;
  adding a trailing newline makes that client attempt to decode a nonoptional
  playback object. The server preserves the compatible response and has a Go
  regression test for the exact wire bytes.
- In the default strict contract: Aux create/list/join, guest streaming and queue commands, denied guest library
  edits, scoped media grants from B added to A's queue, no owner-token forwarding,
  and immediate guest revocation when a session ends.
- Adding new music after the old client has already cached its library. Its
  existing SSE payload decoder sees the library event; the same client instance
  refreshes and streams the added track without an app update.
- Both servers restart with the same identity, playlist membership, likes, cover
  bytes, shared playback and remote media grants. Ended Aux stays ended.

Media-grant creation is a raw owner HTTP request in the harness because build
7's `CodecClient` does not expose that endpoint as a named method. The resulting
foreign-track reference, queue command and response decoding still use its
unchanged models. SSE line framing and media transfers use Foundation around the
old client's requests/headers/models, as the app does; they do not execute the
entire SwiftUI application.

## Rules for candidate changes

- Keep existing endpoint paths, field names/types/defaults and required response
  values usable by supported clients. New JSON fields can be additive; removing
  or changing a field needs a compatible versioned path or server fallback.
- Preserve auth behavior, media range requests, MIME types, conditional library
  requests and existing playback concurrency semantics. A `200` response alone
  does not establish compatibility.
- Keep old clients able to read newly imported tracks and custom playlist covers.
  Do not introduce an app-update requirement to use an existing server account.
- Run this gate after the final server change and attach its report to the same
  candidate's release evidence. Rerun when the candidate binary changes.
- When a gate finds a mismatch, fix the candidate server or explicitly postpone
  the incompatible feature. The declared Aux v1 security retirement above is an
  intentional, separately reported exception; it does not relax owner API
  compatibility. Do not rewrite frozen client files or waive an undeclared
  failure because the newest simulator build passes.

## What still needs device and browser testing

This checks the shipped **protocol implementation**, not every behavior of the
installed binary. It cannot establish SwiftUI layout, AVPlayer codec decoding,
local downloads, AVAudioSession interruptions, Bluetooth/headphone handling,
sleep/background continuity, cellular recovery, TLS or Safari/Home Screen layout.
Use the two persistent demo servers for those interactions, with the unchanged
released app in a simulator or a separate test device where available. Keep the
everyday listening app and its production connection untouched. Record a manual
check as pending if that exact old binary/device is unavailable; do not replace
it with a new test app and describe it as old-client coverage.

The generated tone and small PNG keep the automated gate quick and independent
of private music. The persistent lab's licensed demo collection covers realistic
audio, artwork, scrolling and two-browser Aux sessions. See
[local development](local-development.md) and
[the test app](local-test-app.md).
