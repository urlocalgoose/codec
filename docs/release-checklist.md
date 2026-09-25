# Local testing and coordinated releases

Development stays local until a candidate is ready and release is explicitly
authorized. Fixing a bug or passing a test is not permission to publish it.
This policy applies to server code, the web player, documentation and the
project website. It supersedes the earlier routine of deploying each web fix.

Use the persistent [two-server local environment](local-development.md) for
normal work. Optional phone tests use [Codec Test](local-test-app.md), leaving
the listening app installed. Local native work resumed on September 24 for
onboarding and Aux v2 after the App Review information request. The September 25
release request separately authorizes coordinated server/web release and a new
App Store build. Keep the everyday phone app installed until its later update
is authorized. Local testing and upload do not establish App Review approval or
a public native release; preserve all pending physical-device gates below.

## 1. Iterate locally

- [ ] Start both local demo servers. Confirm their distinct URLs and library
  directories before running imports or destructive test cases.
- [ ] Use only generated test media or the licensed demo bundle. Neither a
  production library nor a production token belongs in the local fixture.
- [ ] Use two independent browser profiles/devices when checking playback
  handoff and Aux. Two tabs can share browser storage and are not always two
  independent clients. A and B are independent servers, not two nodes sharing
  one library.
- [ ] Check the changed behavior, error/retry paths, and empty/offline states.
  Keep downloaded local music playing during disconnection and reconnection.
- [ ] Run affected quick checks while iterating; run the complete applicable
  release gates below before freezing a candidate.
- [ ] Keep code, commits and site previews local. Do not push branches or tags,
  publish a GitHub release, update production, or upload an app as a test step.

## 2. Freeze and verify one candidate

Use a reviewed local commit and a clean export/worktree for release packaging.
Do not delete or sweep unrelated work into the candidate merely to obtain a
clean checkout. Record the source commit, toolchain versions and check results.
If source changes after verification, create and verify a new candidate.

- [ ] `bun install --frozen-lockfile` succeeds with the pinned Bun version.
- [ ] `bun run check:quick` passes all web, server and contract scopes.
- [ ] `go -C sync-server mod verify`, `go -C sync-server vet ./...`, and
  `go -C sync-server test -race ./...` pass.
- [ ] `cargo test --locked --manifest-path src-tauri/Cargo.toml` passes for
  import/library code; desktop GUI distribution remains paused.
- [ ] `(cd ios/CodecMobile && swift test)` passes for the client/model contracts.
  Run app-hosted suites when their behavior is affected; this does not replace
  testing the already-shipped client against the candidate server.
- [ ] `python3 scripts/check-client-compatibility.py` passes using the frozen
  shipped client. Save its binary hash and report with this candidate's evidence.
  For the Aux v2 candidate, use the explicitly documented `--aux-v1-retirement`
  exception in [client compatibility](client-compatibility.md): ordinary owner
  APIs remain compatible, but legacy Aux requires an updated client and new invite.
- [ ] Run the relevant [browser regressions](../scripts/mobile-regression.md)
  in Chromium and WebKit against the candidate web build. Cover desktop and
  mobile widths, Graphite and a light palette, keyboard and touch behavior.
- [ ] Exercise real local-server playback, handoff, conflicting queue edits,
  Aux invite/join/add/revoke, reconnect, and server isolation. Mocked browser
  fixtures alone do not validate multi-device behavior.
- [ ] Complete [installed-client compatibility](client-compatibility.md),
  including an old open web tab/PWA and the currently installed native version.
  Missing device evidence is a pending gate, not a passing result.
- [ ] Run the Linux archive verifier and server/Caddy smoke check on a matching
  Linux architecture. CI coverage is documented in `ci.yml`; a macOS-only
  build is not evidence that the Linux runtime worked.
- [ ] For site changes: `python3 site/test_release_config.py` and
  `python3 site/build.py` pass. Preview desktop/mobile, links, code-copy buttons,
  image credits, metadata and 404s. Routing/header changes also need a local
  Wrangler runtime check; Python's preview server does not apply `_headers`.

Build the web artifact once and package that verified output. Use the final
intended release label before building; changing the label changes build IDs.
From a clean candidate checkout, for example:

```sh
codec_release_version=vX.Y.Z
codec_candidate_dir="$HOME/.codec/release-candidates/$codec_release_version"
mkdir -p "$codec_candidate_dir"
python3 scripts/build-server-release.py --version "$codec_release_version" \
  --web-only --web-output-dir "$codec_candidate_dir/checked-web"
python3 scripts/build-server-release.py --version "$codec_release_version" \
  --verified-web "$codec_candidate_dir/checked-web" \
  --output-dir "$codec_candidate_dir/packages"
```

Choose a new empty output directory for each candidate. The builder verifies
web source/configuration hashes, commit, toolchain, label, file set and file
checksums before reuse. It records a dirty checkout but does **not** reject one;
the clean-candidate release gate is therefore required. Preserve the exact
package bytes and site build being tested; do not silently rebuild during
rollout. Architecture-specific archives differ, but use the same source commit
and checked web artifact.

## 3. Prepare the release window

The required server destinations are:

| Destination | Role | Data rule |
| --- | --- | --- |
| `codec-review.codie.sh` | App Review/demo server; first deployment canary | Keep the licensed demo library and existing review login working |
| `music.codie.sh` | Personal listening server | Preserve music, playlists, likes, covers, token and playback |
| `anika.codie.sh` | Anika's listening server | Preserve its independent library, token and playback |
| `codec.codie.sh` | Static project site, if changed | No private music, server credentials or private screenshots |
| GitHub source/release | Public code and downloadable packages | Same reviewed commit and verified package bytes |

- [ ] The user has authorized this candidate's release, not merely local work.
- [ ] Confirm all required destinations are reachable and record their current
  build IDs, server versions and rollback targets before changing any of them.
- [ ] Make a consistent database backup and verify the existing media/artwork
  backup for server or schema changes. Never copy a live SQLite main file while
  discarding its WAL. Web-only changes do not mutate library state.
- [ ] Test schema migration and rollback against a disposable copy first. The
  previous binary must accept the migrated database or the release needs a
  separately tested recovery plan. Prefer additive migrations compatible with
  old clients; restoring a database can lose new user writes.
- [ ] Stage and checksum-verify the same candidate on all target hosts before
  activation. Check free space. Retain old immutable web assets for open tabs.
- [ ] Record the previous Cloudflare deployment if the site will change.
- [ ] Confirm the GitHub publication path will upload the already-verified
  archives. A different CI rebuild is a new candidate unless its bytes and
  metadata match and its required tests are recorded.
- [ ] Prepare release notes from actual changes. Set `site/release.json` in the
  candidate if the site's download version changes. Do not publish links to
  missing release assets.

## 4. Release in one window

GitHub, Cloudflare and the two server hosts cannot switch atomically. "Together"
means a coordinated, recorded release window, using one verified candidate,
with all gates complete first. It does not mean claiming identical timestamps.

1. Activate the review/demo canary. Use a web-only activation for a web-only
   change, preserving the running backend. Server updates briefly restart the
   service and must follow the verified Ubuntu update process.
2. Verify HTTPS, auth, health, library reads, representative cover rendering,
   audio Range responses, playback state/events, and candidate web build ID.
   Use local demo sessions for mutation tests; do not alter a reviewer's active
   queue or the production listening libraries as a smoke test.
3. Activate the same candidate on the two listening servers, verifying each
   before proceeding. Confirm installed native clients can reconnect without
   an update and old browser tabs can still fetch their hashed assets.
4. Once all server gates pass, push only the reviewed source commit/tag. The tag
   workflow creates an **unpublished draft**, running CI and attaching its own
   checked packages. Compare its hashes with the candidate already tested and
   deployed. If rebuild/toolchain metadata makes them differ, replace the draft
   assets with the exact verified candidate archives and checksums; otherwise
   those new bytes require a new verification record before promotion. Replace
   the draft's template notes with the actual changes and manually publish it
   after every gate passes. Record the commit and published archive hashes and
   verify download links. Do not silently substitute a fresh build.
5. Publish the already-reviewed `site/dist` if changed, after its referenced
   release assets are available. Verify live metadata, pages, examples and
   release references. Site-only releases still pair source publication with
   the verified site deployment; no server update is needed.
6. Record all final versions and results and report the release complete only
   when every included destination is verified. Native App Store/TestFlight
   uploads remain a separate, explicitly authorized process.

## 5. Stop or roll back on partial failure

- Stop promotion when the canary or any required host fails; do not leave later
  steps running in parallel. Do not publish a GitHub release announcing success
  or point the site to it while runtime verification is failing.
- Restore prior web/application links on already-updated hosts using their
  recorded compatible artifacts, then verify health and client connectivity.
  Keep rollback artifacts until the entire window is complete.
- The Ubuntu updater rolls back application links after a failed health check;
  it does not restore the database. Never automatically overwrite a live
  library to undo a software rollout.
- If an old binary cannot read the new database, stop and use the reviewed
  recovery plan. Explain the partial state and potential lost writes before
  any destructive restore; do not improvise on a listening library.
- If GitHub publication or site deployment fails after server activation,
  record the incomplete window. Retry only the prepared artifact publication
  when safe, or roll back the activated candidate. Restore prior site deployment
  if it points to unavailable assets. Do not claim all destinations are current.

## Readiness record

Keep one private record per candidate, without tokens or auth headers:

```text
Candidate label / source commit:
Scope: server / web / site (native distribution excluded)
Web build ID / web source SHA-256:
Archive SHA-256 per architecture / site build manifest hash:
Quick, race, schema, package, Linux smoke and browser results:
Local A/B + Aux + reconnect results:
Installed native version/build tested / device / result:
Old web/PWA build tested / result:
Pending gates and limitations:
Backups verified / previous application and web links:
Previous site deployment:
Release authorization:
Canary / music / Anika activation and verification results:
GitHub commit/tag / published archive hashes:
Site deployment and link verification:
Rollback or remaining partial state:
```

## What is automated today

`ci.yml` checks web, Go, schemas, deployment integrity, Rust import/library,
Swift models, the separate test-app identity and the frozen shipped client
against two candidate servers, then packages both Linux architectures with a shared checked web
build. `server-release.yml` prepares artifacts without deployment credentials.
`release.yml` creates a draft on a `v*` tag and cannot automatically publish it;
the tag's source is still public once pushed, so pushing remains release-gated.
Its attached CI packages are not automatically the local candidate; compare
or replace draft assets before manual publication as described above.
The Ubuntu installer validates archives, retains old web assets, backs up SQLite
on update and checks health with application-link rollback. The site build uses
an explicit public-file allowlist and one release-version configuration.

These tools do not perform a coordinated rollout across hosts, approve native
compatibility, or make GitHub and Cloudflare atomic. Browser fixtures are not
real-device coverage. A release is ready only when its recorded manual and
automated gates both pass; see the release workflow for its publication behavior.
