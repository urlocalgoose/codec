# Local development

Run the real Go server and built web player locally before changing a listening
server. The lab has two independent servers, a project-site preview, and an
optional separate **Codec Test** app. It never reuses production credentials,
connects to a production library, publishes source, or uploads an app.

## Everyday commands

From the repository root, with the pinned Bun/Go versions installed:

```sh
bun local:up
bun local:auth a
bun local:check
```

`up` builds changed inputs and starts background processes. The first run imports
the licensed demo bundle into each empty local server. Subsequent runs reuse
unchanged builds and retain test playlists, likes, downloads on clients, tokens
and server identities. After editing code, run `up` again; it updates the web
and restarts only a local backend whose binary changed. Refresh the browser to
load the new page. There is no need to reimport the demo or sign in each time.

The older `bun server`, `bun server:dev` and `bun dev:mobile` shortcuts also
start this lab. They no longer start a server on the production-forwarder port.

`auth a` copies only A's local token to the Mac clipboard. Connect the web player
to its own local address using that token. `auth b` copies B's token. On a machine
without `pbcopy`, explicitly run `python3 scripts/local-dev.py auth a --show` in
your terminal. Tokens are not included in status output, URLs, screenshots or
Git. Use distinct browser profiles/contexts when acting as separate devices.

| Service | Default address | Purpose |
| --- | --- | --- |
| A | `http://127.0.0.1:8791` | Main local owner/listener |
| B | `http://127.0.0.1:8792` | Independent owner/library for cross-server tests |
| Site | `http://127.0.0.1:9092` | Built static project website |

A and B each have their own SQLite database, copied demo media/artwork, token,
playback ownership and Aux sessions. They are not replicas. A is not a proxy to
the personal server. **Port 8787 is not the lab** and may forward production.

```sh
bun local:status
bun local:stop
bun local:up
```

`stop` stops only processes whose recorded identities still match this lab.
It preserves all data and refuses to kill a different process occupying a port.
The services survive closing the terminal, but are not installed as login
services. After restarting the Mac, use `up` again. The Mac must remain awake
for phone testing to reach these local services.

## One-time setup and storage

Application dependencies use `bun install --frozen-lockfile`. The first web
build also checks the pinned Bun version. Python 3.11+ is required. The quick
schema checks need the existing isolated environment:

```sh
python3 -m venv ~/.cache/codec-checks
~/.cache/codec-checks/bin/python3 -m pip install jsonschema==4.26.0
```

By default the fixture is `~/Documents/S2Y/deployments/open-license-test-100`.
For another checkout/machine, supply that bundle's actual location on first run:

```sh
bun local:up --bundle /path/to/open-license-test-100
```

The source bundle is read-only. Seeding packages only its manifest, referenced
audio and supplied artwork/sidecars, then uses the real authenticated server
bundle-import endpoint. It does not fetch provenance URLs or include adjacent
private collections. Missing/skipped media or failed/missing supplied artwork
fails setup instead of reporting success. A successful seed is recorded and
not repeated. With the 100-song fixture, each server has 100 tracks, 13 ordinary
playlists and the server's Liked Songs playlist. Two independent media copies
need roughly 1.2 GB, plus builds/caches; seeding briefly needs an extra bundle copy.

Everything generated lives in ignored `.codec-dev/`, private to this checkout:

```text
.codec-dev/
├── config.json          ports and checkout identity; no auth
├── candidate.json       current local source/build identity
├── instances/
│   ├── a/               data/, auth-token, process/seed records, server.log
│   ├── b/               independent data and auth
│   └── site/            preview process record and log
├── builds/              cached binaries/web/site outputs
├── web, site            pointers to active preview files
├── ios/                 dedicated simulator state and incremental builds
├── cache/               unchanged-client compilation cache
├── logs/                build/check logs
└── reports/             test results; never a release approval
```

If a default port is occupied, stop the lab and edit its value in
`.codec-dev/config.json`, then run `up`. The three ports must be different; 8787
and 8788 are rejected to avoid existing production forwarders. This command
does not overwrite `~/.codec/server.json`, use its data path, or reuse its token.
The Go executable still reads its normal startup configuration, but every lab
launch explicitly overrides its address, data path, web path and token.
Build caches can grow across revisions. Stop the lab before manually removing
old build directories; retain the active targets and leave `instances/` alone.

## Phone, Safari and Home Screen testing

For phone access without a public test deployment, use private Tailscale HTTPS:

```sh
bun local:share
```

The command prints three private URLs using this Mac's Tailscale hostname and
ports **8441** (A), **8442** (B) and **8444** (site). Sign into the same tailnet on
the phone. These proxies forward to the loopback lab. HTTPS allows testing PWA
service workers, browser storage and Add to Home Screen behavior under a secure
origin. An ordinary LAN HTTP URL does not reproduce those browser features.

Only these dedicated ports are managed. The helper refuses existing conflicting
routes and public Funnel settings. It never runs `tailscale serve reset`, uses
Funnel, or alters existing 443/8443 services. `bun local:unshare` removes only
unchanged routes created by this lab. `stop` preserves the proxy settings for
next time; while the lab is stopped those URLs have no live backend.

Use the real HTTPS URL (not `127.0.0.1`) on a phone. Each origin has independent
web/PWA storage, so do not add a production URL as the test Home Screen app.
In Safari, test browser chrome/safe areas separately from the Home Screen PWA.
Headless WebKit does not reproduce iOS chrome, audio interruptions or suspension.

For optional native testing:

```sh
bun local:ios simulator
bun local:ios test
```

See [Codec Test](local-test-app.md) for an explicit device install command. It
uses a separate bundle identity and **Codec Test** name, so the listening app,
its connection and downloaded songs remain separate. It never uploads to
TestFlight/App Store Connect. Local web builds use `codec-test://` for Aux app
handoffs; production builds keep `codec://`. The `local-` build-label prefix is
reserved for the lab and must never be published as a production web artifact.

## What to exercise

- **One server, two devices:** connect a desktop browser and Codec Test/mobile
  browser to A. Play/pause/seek, change tracks, queue/dequeue/reorder, like songs,
  edit playlists, switch active player and reconnect. Only the active player
  should stream audio; the controller must reflect its state.
- **Two independent servers:** connect another profile/device to B. A's likes,
  playlists, ownership and current song must not change B. A's owner token
  must not authenticate to B.
- **Aux:** start an invite on A, join from a separate guest context and queue a
  song. Test restricted guest permissions and ending/revoking the session.
  Test both Shared speaker and Listen together, guest pause/skip, own-request
  removal, whole-queue reorder, and owner output preservation. A guest must never
  request the ordinary owner library or playback API. Use B's own-origin popup
  to test exact membership and existing-song playlist saves. Production foreign
  fetch requires public HTTPS on port 443; HTTP/loopback/private Tailscale sources
  are deliberately rejected. Cross-server download success is exercised by Go
  tests using two isolated servers behind a synthetic HTTPS transport available
  only in `_test.go`. Identical A/B catalogs are not proof of a new audio copy.
- **Offline/reconnect:** download demo songs, stop the relevant local server or
  disable connectivity on the test device, then restore it. Check cached library,
  local playback, next/seek, status, recovery and absence of redundant streaming.
- **Updates:** retain an old web tab/PWA, run a new local build, and check its
  requests and recovery. Old immutable assets are retained. Confirm the unchanged
  installed-client gate before shipping a server change.
- **Site:** preview the built pages at desktop/mobile widths, including links,
  examples, copy buttons, image credits and link-preview metadata. Python's
  local server does not apply Cloudflare `_headers` or routing rules; use the
  separate Wrangler check for changes to those rules.

## Automated gates

`bun local:check` refuses stale source/build state and requires both local
servers. It runs the parallel quick checks, the **unchanged iOS 1.4 (7)** client
against two disposable candidate servers, local manager safety tests, site
version tests and real-server browser smoke checks. It writes a dated report
under `.codec-dev/reports/`. Any failing command fails the run.

The Aux v2 candidate intentionally retires legacy Aux. To verify this candidate
while keeping the installed owner's library/playback contract, declare the
security exception explicitly:

```sh
bun local:check --aux-v1-retirement
```

The option is forwarded to the disposable installed-client gate and recorded in
the local result. It requires legacy Aux create/list/join to return 410; it does
**not** claim build 7 Aux still works. Without it, `bun local:check` retains the
strict frozen expectations and fails at that deliberate incompatibility. The
three frozen client source files and their hashes remain unchanged. Record the
Aux cutoff, revoked invitations and safe browser/new-app join path as a release
exception; passing this scoped check does not authorize release. See the
[declared retirement policy](client-compatibility.md#declared-aux-v1-security-retirement).
Use `--skip-browser --aux-v1-retirement` only for an explicitly partial check.

The browser smoke uses Playwright with Chromium and WebKit. Install it once in
a private tooling directory, or point `PLAYWRIGHT_MODULE` to an existing
`playwright/index.mjs` installation; see [browser test setup](../scripts/mobile-regression.md).
Keep that environment setting in your shell so later checks need no setup.
Alternatively set `playwright_module` in `.codec-dev/config.json` to the installed
module's absolute path; the lab reuses it on every check. This Mac is already
configured, so `bun local:check` needs no extra environment arguments.
The browser test is allowed to change **local A's playback**, then leave it
paused; it cleans up its test playlists, likes and Aux sessions. Do not use it
while listening through the lab. It has no arbitrary remote-server URL option.

For feedback without browsers, `bun local:check --skip-browser` explicitly
records a partial run. It does **not** satisfy release readiness. Swift client
compatibility requires macOS/Swift; it runs on the macOS CI job as well. The
same client tests compile from a fixed copy of build 7, with hash checks, rather
than compiling today's client and calling it backwards compatibility.

Actual phone sleep/Bluetooth/cellular behavior, old installed-app UI, old PWA
update behavior and Linux/proxy deployment need their separate checks. Passing
the fast local gate does not claim those manual/release checks passed. Use the
[compatibility guide](client-compatibility.md) and [release checklist](release-checklist.md).

## Shipping

Nothing in `local:*` pushes to GitHub, SSHes into AWS, publishes the site, changes
the review demo, or uploads an app. Production releases happen only after the
candidate is ready and release is explicitly authorized. The checklist ties the
same verified source/artifacts to both listening servers, the review demo,
GitHub and any changed website within one release window. These separate
services cannot publish atomically; partial failures stop promotion and use the
documented rollback procedure.
