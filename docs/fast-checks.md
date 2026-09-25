# Fast checks and verified build reuse

Run quick checks from the repository root before the complete release pipeline:

```sh
bun run check:quick
```

The independent web, server and contract checks run in parallel. Each scope
stops on its first failing command; any failure makes the overall command fail.
The output includes elapsed times and a private directory containing per-scope
logs and `timings.json`. Nothing is deployed and no live library is used.

The schema checks need `jsonschema`. Prepare an isolated environment once:

```sh
python3 -m venv ~/.cache/codec-checks
~/.cache/codec-checks/bin/python3 -m pip install jsonschema==4.26.0
```

The quick runner finds that environment automatically. Alternatively set
`CODEC_SCHEMA_PYTHON` to an existing Python executable with the schema test
dependencies installed. Application dependencies still use `bun install
--frozen-lockfile`; the quick runner does not update dependency versions.

Choose scopes explicitly when iterating on one area:

```sh
bun run check:quick -- --scope web
bun run check:quick -- --scope server --scope contracts
bun run check:quick -- --serial --report-dir /tmp/codec-check-comparison
bun run check:quick -- --list
```

| Scope | Checks |
| --- | --- |
| Web | Svelte/TypeScript checking and all `src/lib` tests |
| Server | `go vet ./...` and `go test ./...`, reusing Go's valid build/test cache |
| Contracts | Import schemas, release packaging/integrity tests, Ubuntu deployment tests |

Quick checks do not replace the release gates. CI still runs the server race
suite, locked Rust tests, Swift CodecKit tests, the production web build,
Linux cross-compilation, archive validation and server/Caddy smoke checks.
Native app-hosted renderer/controller tests are separate from CodecKit; the
CodecKit CI job does **not** verify the native Metal palette. Use a dedicated
simulator and the commands in [native regression tests](../ios/CodecMobile/Tests/README.md).
For a narrow native renderer iteration, append
`-only-testing:CodecNativeTests/WebVisualizerParityTests` and the appropriate
other affected test classes to the documented `xcodebuild test` command. The
complete native suite remains necessary before a phone release.

## Build the web app once

The web CI job builds with frozen dependencies and exports `checked-release-web`.
The Linux packaging job downloads that artifact from the **same workflow run**.
Before reuse, the builder checks:

- The current web source/configuration/lockfile digest and Git commit.
- The pinned Bun version, release label, source timestamp and PWA build ID.
- The exact file set and SHA-256 checksum of every built file.
- The embedded Svelte version, so an older service worker cannot be mistaken
  for the current build.

Source changes, corrupted/extra/missing files and symlinks fail verification.
Changes during the original build also fail instead of exporting mixed inputs.
Checksums verify this trusted CI handoff; they do not establish the provenance
of an arbitrary artifact downloaded elsewhere.

The same path is available locally:

```sh
python3 scripts/build-server-release.py --version preview-test \
  --web-only --web-output-dir /tmp/codec-preview-web
python3 scripts/build-server-release.py --version preview-test \
  --verified-web /tmp/codec-preview-web
```

Use a new empty export directory for each build. If the web source changes,
build/export again. Plain `bun run release:server -- --version VERSION` still
performs a complete build. The former unverified `--skip-web-build` option was
removed.

CI caches Bun's package downloads, alongside the existing Go/Rust caches.
Newer runs cancel superseded branch/PR checks; tag release checks are not
cancelled this way. All release checks stay enabled.

## Measuring feedback time

The quick runner writes per-scope durations and logs. Compare the same source,
toolchains and warm/cold caches when measuring a change. Verified web reuse
avoids a duplicate frontend build; it does not skip integrity validation.
Store candidate-specific timings with the private release readiness record
rather than copying old test counts into the current instructions.
