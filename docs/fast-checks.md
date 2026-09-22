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

## Local timing evidence

On September 21, 2026, with dependencies and compiler caches already warm:

| Local command | Wall time |
| --- | ---: |
| All quick scopes in parallel | 5.04 s |
| Web check + 206 tests, within that run | 5.04 s |
| Server vet + cached tests, within that run | 0.49 s |
| Schemas + package + deployment tests, within that run | 0.82 s |
| Fresh web export | 7.95 s |
| Both Linux packages using the verified web export | 2.83 s |
| Both Linux packages building web again | 10.81 s |

Verified reuse avoided 7.98 seconds of duplicate work in the local packaging
step. Artifact upload/download overhead on GitHub is not included; these are
local observations, not hosted CI or production latency claims. The exported
web and the subsequent fresh build had identical bytes for all 21 web files
in both architectures' packages.

The full validation also passed locked Rust tests (112), Go module verification,
vet and race tests, schema tests (6), release integrity tests (6), Ubuntu
deployment unit tests (24), and workflow lint. An actual arm64 Ubuntu container
ran the packaged server and Caddy against synthetic data with external
networking disabled: authentication, SQLite, the web shell, service worker,
HTML/JavaScript/JSON compression, uncompressed audio Range responses and
immediate SSE all passed. Both Linux archives passed installer verification;
this local process smoke used arm64, while CI runs its configured amd64 check.

Detailed logs, artifact comparisons and timings are saved locally under
`/tmp/codec-fast-pipeline-20260921/`. A deliberately failing quick-check run
returned failure and stopped its affected scope, verifying that parallel
execution does not hide failing checks.
