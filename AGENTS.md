# Codec development and releases

## Default to local work

- Develop and test against the isolated local environment in
  `docs/local-development.md`. Its two demo servers are separate from listening
  libraries, production credentials, and the App Review server.
- An instruction to fix, test, preview, or finish a change does not authorize a
  production deployment, GitHub push, tag/release publication, or project-site
  publication. Earlier standing instructions to ship every fix are superseded
  by this local-first workflow. Wait for the user to say the candidate is ready
  to release. Complete the local implementation and verification first.
- Never use `music.codie.sh`, `anika.codie.sh`, or `codec-review.codie.sh` as a
  development fixture. Do not change their libraries, playback, or Aux sessions
  to test a feature. Keep private music, auth tokens, and private host access details out of
  commits, screenshots, public artifacts, and logs.
- Do not push to GitHub to obtain a routine test run. Local commits and local
  checks are sufficient during development. Review existing uncommitted work;
  never blanket-stage unrelated files.

## Native app and compatibility

- On September 24, 2026, the user resumed native development for connection-screen
  guidance and Aux v2 after the App Review information request. App Store uploads,
  resubmission, and production releases still require explicit authorization.
- Optional device testing uses the separate Codec Test identity described in
  `docs/local-test-app.md`. Preserve the installed listening app, its downloads,
  settings, keychain, and production connection. Installing a test build is not
  an App Store/TestFlight upload or permission to replace the listening app.
- Server/web updates must work with the already-installed native app without
  requiring a new app version. Run the compatibility checks and record which
  released client was exercised; see `docs/client-compatibility.md`. Newly built
  Swift tests alone are not proof that the shipped app remains compatible.

## Release gate

- Follow `docs/release-checklist.md`. A release uses one reviewed source commit
  and the verified candidate artifacts. Keep a readiness record outside the
  public repository with test results, hashes, backup/rollback targets, and
  per-destination results; never record credentials in it.
- Once release is authorized, coordinate GitHub, both listening servers, the
  review demo, and any changed project-site content in one release window.
  Cross-provider publication is not atomic: use the canary, failure, and
  rollback procedure instead of claiming simultaneous activation.
- Preserve libraries and credentials. Web-only activation should not restart
  the audio server. Native binary distribution requires separate explicit
  authorization and is not part of a server/web release.
