# Ubuntu deployment validation

This is a local validation record and a repeatable test procedure. It does not
represent a GitHub Actions run, an AWS deployment, DNS cutover, public TLS
issuance, or migration of the current music library. All test media and tokens
are synthetic; no production data is mounted into the test containers.

## Coverage

Run against disposable synthetic data; never mount a listening library into a
test container. Record the commit, artifact hashes, Linux architecture, toolchain
and actual check results in the private release readiness record.

- Deployment unit tests cover archive/path validation, file hashes, private
  credentials, retained web assets and failed-upgrade transaction boundaries.
- The real systemd fixture exercises install, update, failed health checks,
  crash-loop rollback and preservation of database writes across code rollback.
- The Caddy fixture uses the packaged configuration to check text/JSON gzip,
  uncompressed audio Range responses and immediate uncompressed SSE.
- Release checks verify payload metadata, checksums, static Linux architecture
  and the packaged server with authentication and synthetic media.
- Docker validation checks non-root execution and persistence across restart;
  reproducibility comparisons require identical source and toolchains.
- Auth-reader checks verify token retrieval without logging credentials, changing
  their private file or starting a stopped service.

Passing archive validation does not prove runtime behavior on a second
architecture. Record which architecture actually ran each process/systemd test.
Do not treat old test counts or expired temporary reports as current evidence.

## Run the focused checks

```bash
python3 -m unittest discover -s deploy/ubuntu -p 'test_*.py'
python3 scripts/test-server-release.py
python3 scripts/build-server-release.py --version validation-VERSION

# Extract a verified release matching this Linux host's architecture first.
python3 scripts/smoke-server-release.py /path/to/extracted-release \
  --caddy /usr/bin/caddy
```

CI installs Caddy in the Linux release job and runs this last check against
the packaged server, static web assets and Caddyfile. The smoke library and
credentials live only in a temporary directory.

For the complete systemd transaction test, build a disposable integration
image and start it without publishing any host ports:

```bash
docker build -f deploy/ubuntu/Dockerfile.test -t codec-ubuntu-deploy-test:local .

docker run -d --name codec-deployment-test \
  --privileged --cgroupns=host --tmpfs /run --tmpfs /run/lock \
  --security-opt label=disable \
  --mount type=bind,src="$PWD/dist/server",dst=/artifacts,readonly \
  --mount type=bind,src="$PWD/deploy/ubuntu",dst=/runtime,readonly \
  codec-ubuntu-deploy-test:local

docker exec codec-deployment-test python3 /runtime/verify_systemd.py \
  /artifacts/codec-server-validation-VERSION-linux-ARCH.tar.gz \
  --report /tmp/systemd-validation.json

docker exec codec-deployment-test python3 /runtime/verify_caddy.py \
  --config /opt/codec/current/deploy/ubuntu/Caddyfile.example \
  --report /tmp/caddy-validation.json

docker cp codec-deployment-test:/tmp/systemd-validation.json ./systemd-validation.json
docker cp codec-deployment-test:/tmp/caddy-validation.json ./caddy-validation.json
docker rm -f codec-deployment-test
```

Replace `ARCH` with the Docker host's Linux architecture. The systemd script
refuses to run outside Docker or over an already installed Codec service. The
privileged container is a test host; it is not the production deployment model.

## Boundaries

These checks verify a single-instance update with a brief service restart.
They do not promise uninterrupted streaming during that restart. Caddy tests
use local HTTP; actual certificate issuance, DNS, firewall rules, storage
capacity, remote backups, and current-phone continuity still require checks
during the real migration described in [the Ubuntu runbook](ubuntu-deployment.md).

Byte-for-byte packaging repeatability requires the same source and toolchains.
An artifact built before subsequent performance edits remains a validation
artifact, not a claim that those later edits were deployed. Production releases
must use a reviewed commit and a fresh full build.

Retain the resulting receipts outside the public repository. Follow the
[release checklist](release-checklist.md) for candidate scope, installed-client
compatibility, destination checks and rollback. These instructions do not
represent a completed deployment or authorize one.
