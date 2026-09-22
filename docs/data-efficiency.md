# Speed and data efficiency

The HTTP measurements below describe a September 21 historical baseline with
1,013 tracks; they are not current hosting statistics. See
[native performance](native-performance.md) for native measurement guidance and
[import support](s2y-artwork-import.md) for collection imports.
Audio files, artwork resolution and playback quality remain unchanged.

## Findings and measured improvement

The earlier 928 KB observation described the local origin. The public
Cloudflare endpoint already compressed a full library response to 158,323
bytes. Its actual defect was revalidation: Cloudflare returned a weak ETag,
but the old origin only accepted an exact strong-tag match. Sending the
returned tag fetched another 157,138-byte body with status 200.

| Check | Previous behavior / plain response | Updated deployed server |
| --- | ---: | ---: |
| Origin library, requesting gzip | 928,119 bytes, uncompressed | 157,761 bytes, gzip; 83.0% less |
| Public unchanged library using returned weak ETag | 200, 157,138 bytes | 304, zero body bytes |
| Warm origin library GET, gzip requested | Median 14.181 ms; p95 14.684 ms | Median 0.196 ms; p95 0.333 ms |
| Current playback snapshot, plain versus gzip | 52,959 bytes | 14,239 bytes, gzip; 73.1% less |
| Library integrity | 1,013 tracks, 10 exposed playlists | Matches, excluding origin and scan timestamp |

The origin timing comparison used HTTP keep-alive, three warm-ups and 20
sequential samples on the development Mac. It shows warm loopback behavior,
not cellular latency, cold-start time, concurrent capacity, or time until
audible playback. The first measured origin library request after rollout was
46.67 ms; the warm result does not establish a cold-load improvement. Isolated
staging also measured a 0.183 ms warm median before deployment.

After deployment, the public full-library gzip response was 157,782 bytes,
with a 65.093 ms median and 152.919 ms p95 across 20 warm samples. The earlier
public latency sample was too small for a comparable speedup claim. Public
revalidation now passes for weak tags, strong tags, lists, and `*`. Body-byte
counts exclude HTTP headers and connection overhead. Public and local JSON
sizes differ partly because their media URLs differ.

## What changed

- **Library validators:** weak and strong `If-None-Match` forms, lists, and `*`
  work across compression proxies. Unchanged reads return 304 before SQLite
  work. Responses use `private, no-cache` and `Vary: Accept-Encoding`.
- **Server cache:** immutable JSON and precompressed bytes are reused by
  library generation, public base URL, and endpoint. The cache holds at most
  four entries and 16 MiB of payload bytes. Mutations invalidate it; a write
  overlapping a snapshot prevents that snapshot from entering the cache.
  Authentication still runs before cached bodies or validators are served.
- **Other JSON:** large playback snapshots and command/queue responses are
  compressed too. Small replies avoid compression work, writers are reused,
  and `gzip;q=0` is honored. SSE, media/ranges, exports, and credential replies
  retain their existing transport behavior.
- **Client refreshes:** events deliver changes immediately. With a healthy
  stream, presence stays at 30 seconds and device/playback/library safety
  reads move to five minutes. Disconnects retain the 30-second fallback;
  reconnect and foreground handling reconcile without waiting five minutes.
  Stalled streams have a 45-second native / 60-second web health threshold,
  evaluated by the presence loop. Recovering sync does not restart local audio.
  Failed reads and failed library invalidations leave validation due for the
  next presence tick; only successful reconciliation earns the longer interval.
  A library 304 counts as success. Old connection callbacks cannot mark a new
  connection fresh or discard its pending refresh.
- **Unchanged UI data:** web 304 responses reuse normalized library objects;
  unchanged refreshes avoid repeat library processing and IndexedDB writes.
  Concurrent routine reads share work; a mutation during a read still requests
  a follow-up. Native library refreshes retain their existing coalescing.

The deterministic healthy-stream test models **480 → 156 routine HTTP
requests/client/hour**, a **67.5% reduction**: 120 presence writes plus 12
reads each for devices, playback, and library. Those snapshot GETs fall 90%.
Three continuously active clients therefore model 337,000 rather than
1,037,000 routine requests per 30 days. These are cadence estimates, excluding
startup, media, commands, token renewal, event-stream bytes, reconnects, timer
throttling, and background suspension; they are not measured billing totals.

A separate synthetic 1,000-track benchmark produced 799,612 JSON bytes and
73,938 gzip bytes. Repeated scan/summarize/encode/gzip took about 13.05 ms and
10.68 MB allocations per request; a warm cached gzip response took about
0.98 µs and 464 allocated bytes. This benchmark discards network output and
measures server computation only. The HTTP measurements above are more
representative of the local request path.

## Reproduce verification

From the repository root:

```sh
cd sync-server
go test -race ./...
go vet ./...
go test ./internal/server -run '^$' -bench BenchmarkLibraryResponse -benchmem -v
```

Client checks, also from the repository root:

```sh
bun run test:frontend
bun run check
bun run build
cargo test --manifest-path src-tauri/Cargo.toml
cd ios/CodecMobile
swift test
```

Use the checked-in `Codec` Xcode scheme for simulator tests as described in
[the native test guide](../ios/CodecMobile/Tests/README.md). This pass verified
88 frontend tests, 62 targeted native tests, 25 Swift package tests, 12 Rust
tests, and the complete Go race suite plus vet. Coverage includes stream
failure/stalls/reconnect, stale in-flight responses, queue/playback continuity,
compression negotiation, proxy validators, cache invalidation, URL isolation,
authorization, and overlapping library writes.

For a read-only wire check against an authorized local server, the script below
reads an explicitly selected token file without printing it or storing library contents.
Set `CODEC_REVIEW_URL` to your test endpoint and `CODEC_REVIEW_TOKEN_FILE` to
your private token file before running it.

```sh
python3 - <<'PY'
import http.client, json, os, pathlib, statistics, time, urllib.parse
url = urllib.parse.urlsplit(os.environ["CODEC_REVIEW_URL"])
token = pathlib.Path(os.environ["CODEC_REVIEW_TOKEN_FILE"]).read_text().strip()
connection = (http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection)(url.hostname, url.port, timeout=15)
def read(encoding, etag=None):
    headers = {"Authorization": "Bearer " + token, "Accept-Encoding": encoding}
    if etag: headers["If-None-Match"] = etag
    start = time.perf_counter()
    connection.request("GET", url.path.rstrip("/") + "/api/v1/library", headers=headers)
    response = connection.getresponse()
    size = len(response.read())
    return response.status, size, response.getheader("ETag"), (time.perf_counter() - start) * 1000
for encoding in ("identity", "gzip"):
    for _ in range(3): read(encoding)
    samples = [read(encoding) for _ in range(20)]
    times = sorted(row[3] for row in samples)
    print(json.dumps({"encoding": encoding, "status": samples[-1][0], "body_bytes": samples[-1][1], "median_ms": round(statistics.median(times), 3), "p95_ms": round(times[18], 3)}))
status, size, _, _ = read("gzip", samples[-1][2])
print(json.dumps({"case": "unchanged", "status": status, "body_bytes": size}))
connection.close()
PY
```

The final check now reports `304` and `0` on both the origin and public URL.
Both also passed real-library checks for unauthorized access (401), audio
HEAD, a 65,536-byte audio range (206), and initial uncompressed SSE events.
The origin honors `gzip;q=0`; the Cloudflare public path still returned gzip
for that header in this probe. That remaining proxy behavior is outside the
origin negotiation fix. No library, database, or credentials are included in
this document.
